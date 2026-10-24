# Task 3: Terraform and AWS IAM security

Terraform: `terraform/` (`main.tf`, `network.tf`, `iam.tf`, `variables.tf`, `outputs.tf`). It builds the Task 1 design for one environment, and `var.environment` (`staging` or `production`) selects the account and names. It was validated and scanned, not applied.

| Requirement | Where |
|---|---|
| AWS provider, scoped resources | `main.tf` provider with `default_tags`; every resource named `orders-<env>-*` |
| IAM least privilege | `iam.tf`: three roles, each scoped to specific ARNs |
| Encryption at rest | One customer-managed KMS key with rotation for RDS, the DB secret, Performance Insights, ECR and every log group |
| Restricted network access | 3 subnet tiers, no NAT, VPC endpoints, security groups chained ALB → app → DB (`network.tf`) |
| Secure secret handling | `manage_master_user_password = true`: RDS generates the password in Secrets Manager. It never appears in code, variables, plan or state |
| Tagging, environment separation | `default_tags` (Project, Environment, ManagedBy, Owner); one state file and one account per environment |
| Automated IaC scanning | Checkov in the `iac` job on every PR, with a custom policy in `security/checkov-policies/` |
| Remote state | S3 backend, encrypted with KMS, native S3 lock file (`use_lockfile`), see `terraform/backend.hcl.example` |

Evidence: `evidence/task3/terraform-validate.txt`, `evidence/task3/checkov-terraform.txt` (183 passed, 0 failed, 1 skipped with a reason).

Validate and scan locally:

```bash
cd terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
cd .. && checkov --config-file .checkov.yaml -d . --framework terraform dockerfile
```

## Scenario A: overly permissive IAM (`"Action": "*", "Resource": "*"`)

**Why it's dangerous**

- It's account admin. If the pipeline is compromised (a malicious dependency, a hijacked action, a stolen token), the attacker owns the whole account.
- `iam:*` lets the role create users, access keys and new admin roles, so it can keep access even after it's found.
- There's no separation between deploying and running. The same power is used for a routine image push.
- Any mistake in a deploy script, such as a wrong `delete-*` call, has no limit on what it can break.

**Safer approach, as built in `terraform/iam.tf`**

| Control | How |
|---|---|
| Resource-level permissions | The deploy role can push to one ECR repo ARN and update one ECS service ARN. Only `ecr:GetAuthorizationToken` and `ecs:RegisterTaskDefinition` stay on `*`, because AWS doesn't support resource-level permissions for them |
| No privilege escalation | `iam:PassRole` only on the two task role ARNs, and only to `ecs-tasks.amazonaws.com`. On `*`, the pipeline could attach an admin role to a task |
| Separate deploy and runtime roles | Deploy role (GitHub Actions), task execution role (ECS agent: pull image, read one secret, write logs), task role (app code: no permissions, because the app makes no AWS calls) |
| Short-lived credentials | GitHub OIDC. The trust policy requires `aud = sts.amazonaws.com` and `sub = repo:<owner>/<repo>:environment:<env>`. Sessions last at most 1 hour, and no access key exists |
| Cross-account | One deploy role per account. A staging token can't assume the production role, because the `sub` claim names the environment. Production's GitHub Environment requires a reviewer, so the job gets no token until approval |

Added at org level: an SCP denying `iam:CreateUser`, `iam:CreateAccessKey`, and disabling CloudTrail or GuardDuty. A permissions boundary on any role the pipeline can create would cap it further.

Deploy role policy (rendered from `iam.tf`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrAuthHasNoResourceLevelPermission", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "PushToThisRepoOnly", "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"],
      "Resource": "arn:aws:ecr:ap-southeast-3:<account-id>:repository/orders-production" },
    { "Sid": "TaskDefinitionsHaveNoResourceLevelPermission", "Effect": "Allow", "Action": ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"], "Resource": "*" },
    { "Sid": "UpdateThisServiceOnly", "Effect": "Allow", "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
      "Resource": "arn:aws:ecs:ap-southeast-3:<account-id>:service/orders-production/orders-api" },
    { "Sid": "PassOnlyTheTwoTaskRoles", "Effect": "Allow", "Action": "iam:PassRole",
      "Resource": ["arn:aws:iam::<account-id>:role/orders-production-task-execution", "arn:aws:iam::<account-id>:role/orders-production-task"],
      "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } } }
  ]
}
```

## Scenario B: database reachable from 0.0.0.0/0

`security/examples/scenario-b-public-db/main.tf` is a deliberately bad change: an RDS instance with `publicly_accessible = true`, no encryption, and a security group open on 5432 to `0.0.0.0/0`.

**How it's blocked before deployment**

1. The change arrives as a PR. The `iac` job runs Checkov on every PR, and `build` depends on it, so nothing is built or deployed while it's red.
2. Checkov fails it on 10 checks (`evidence/task3/checkov-scenario-b-public-db.txt`), including:
   - `CKV_AWS_17`: RDS is publicly accessible
   - `CKV_AWS_16`: RDS not encrypted at rest
   - `CKV2_ORDERS_1`: security group accepts `0.0.0.0/0` on a port other than 443
3. Production apply only happens from `main`, after the PR passed, behind the `production` approval.

**The gap I found:** Checkov's built-in checks flag `0.0.0.0/0` only on ports 22, 3389, 80 and "all ports". Port 5432 open to the world passes on its own. So I added a custom policy, `security/checkov-policies/no-public-ingress-except-https.yaml`: any security group or ingress rule that accepts `0.0.0.0/0` or `::/0` must be port 443. It's loaded through `.checkov.yaml`, so the pipeline enforces it.

Defense in depth if the code gate were bypassed: an SCP or AWS Config rule (`rds-instance-public-access-check`, `restricted-common-ports`) detects or denies it at the account level. At org scale, OPA or Sentinel on the plan JSON is the stronger version of this rule.

## Scenario C: password in Terraform variables and state

State stores every resource attribute in plain JSON, including `password`. `sensitive = true` only hides it from CLI output, not from state.

**Handle the existing exposure first**

1. Treat the password as compromised. Rotate it now, in the database, not just in Terraform.
2. Find who could read it: state bucket access logs and CloudTrail `GetObject` on the state key, CI logs, anyone with a local copy. If the state or a `.tfvars` file was ever committed, scrub the history (`git filter-repo`) and force-push, but rotation is the real fix.
3. Review DB logs for logins from unexpected sources since the exposure.

**Secure the secret**

- Let RDS own it: `manage_master_user_password = true` (as in `terraform/main.tf`). RDS generates the password and stores it in Secrets Manager, encrypted with the KMS key, with rotation. Terraform only knows the secret's ARN. The app gets it through the ECS task definition's `secrets` block, which also only holds the ARN.
- For secrets Terraform must pass in, use write-only arguments or ephemeral resources (Terraform 1.10+). Those values never get written to plan or state.

**Prevent further exposure**

- State in S3 with SSE-KMS, versioning, Block Public Access, and a bucket policy that allows only the deploy role and break-glass admin. State lives in the security account, not with the workload.
- `.gitignore` already excludes `*.tfstate` and `*.tfvars`, and Gitleaks scans every commit.
- `sensitive = true` on any remaining secret variable or output, to keep it out of logs.
- Checkov flags hardcoded secrets in `.tf` files (`CKV_SECRET_*`).
