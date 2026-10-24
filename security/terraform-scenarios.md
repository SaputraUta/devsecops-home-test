# Terraform and IAM security

The Terraform in `terraform/` builds the Task 1 design for one environment at a time (`environment = staging` or `production`). It's validated and scanned, not applied.

| Requirement | How |
|---|---|
| Scoped resources | Every resource is named `orders-<env>-*` and tagged by the provider's `default_tags` |
| Least privilege | Three IAM roles, each limited to specific ARNs (`iam.tf`) |
| Encryption at rest | One KMS key with rotation for RDS, the DB secret, ECR and all log groups |
| Restricted network | Public, private and isolated subnets, no NAT, VPC endpoints, security groups chained ALB → app → DB |
| Secrets | RDS creates and stores the DB password in Secrets Manager. It never appears in code, variables or state |
| Environment separation | One account and one state file per environment |
| IaC scanning | Checkov on every PR, plus one custom policy |

Results: `terraform validate` passes. Checkov: 183 passed, 0 failed, 1 skipped (Multi-AZ is off in staging to save cost). Files in `evidence/task3/`.

## Scenario A: `"Action": "*", "Resource": "*"`

Why it's dangerous: it's full admin. If the pipeline is compromised, through a bad dependency or a stolen token, the attacker owns the account. With `iam:*` they can also create new users and keys and keep their access after we find them.

What I do instead:

- **Separate roles.** A deploy role for the pipeline, a task execution role for ECS to start the container, and a task role for the app (empty, because the app doesn't call AWS).
- **Specific resources.** The deploy role can push to one ECR repo and update one ECS service. Only two actions stay on `*` because AWS doesn't support narrowing them (`ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition`).
- **Limited PassRole.** The deploy role can only pass the two task roles, and only to ECS. With `PassRole` on `*`, the pipeline could attach an admin role to a task.
- **Short-lived credentials.** GitHub Actions gets temporary credentials through OIDC, valid for one hour. No access keys exist.
- **Cross-account.** Each account has its own deploy role, and the trust policy only accepts tokens from this repo and the matching GitHub Environment. A staging job can't assume the production role.

Example policy for the production deploy role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"],
      "Resource": "arn:aws:ecr:ap-southeast-3:<account-id>:repository/orders-production" },
    { "Effect": "Allow", "Action": ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
      "Resource": "arn:aws:ecs:ap-southeast-3:<account-id>:service/orders-production/orders-api" },
    { "Effect": "Allow", "Action": "iam:PassRole",
      "Resource": ["arn:aws:iam::<account-id>:role/orders-production-task-execution", "arn:aws:iam::<account-id>:role/orders-production-task"],
      "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } } }
  ]
}
```

## Scenario B: database open to 0.0.0.0/0

`security/examples/scenario-b-public-db/main.tf` is a bad change on purpose: a public RDS instance, not encrypted, with port 5432 open to the internet.

How the pipeline stops it:

1. The change comes in as a PR. The `iac` job runs Checkov, and nothing gets built or deployed while it fails.
2. Checkov fails it on 10 checks, including a public database (`CKV_AWS_17`), no encryption (`CKV_AWS_16`) and the open port (`CKV2_ORDERS_1`). Output: `evidence/task3/checkov-scenario-b-public-db.txt`.
3. Production only deploys from `main`, after approval.

Checkov's built-in rules only flag `0.0.0.0/0` on ports 22, 3389, 80 and "all ports", so 5432 open to the world would pass. I added a custom policy (`security/checkov-policies/no-public-ingress-except-https.yaml`): anything open to the internet must be port 443.

If someone skipped the pipeline, AWS Config rules or an SCP at the account level would still catch it.

## Scenario C: password in Terraform variables and state

Terraform state stores every value in plain text, including passwords. `sensitive = true` only hides the value in the terminal, not in state.

Handle the exposure:

1. Rotate the password now, in the database itself.
2. Find who could have read it: who has access to the state bucket, CI logs, local copies. If state or a `.tfvars` file was ever committed to git, remove it from history too, but rotating is what actually fixes it.
3. Check the database logs for unexpected logins.

Fix it for good:

- Let RDS manage the password (`manage_master_user_password = true`, as in `terraform/main.tf`). Terraform only knows the secret's ARN, and the app gets the value from Secrets Manager.
- For other secrets, use Terraform's write-only arguments or ephemeral resources, which never get saved to state.
- Keep state in an encrypted S3 bucket with versioning, no public access, and a bucket policy that only allows the deploy role and break-glass admin.
- `*.tfstate` and `*.tfvars` are in `.gitignore`, and Gitleaks scans every commit.
