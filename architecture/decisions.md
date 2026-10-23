# Design decisions

Each entry: what we picked, what we rejected, and why.

## Compute: ECS Fargate
- Rejected: EC2, ECS on EC2, EKS.
- With Fargate, AWS patches the host, and each task runs in its own isolated micro-VM.
- ECS on EC2 has a trap: tasks can reach the instance metadata service and use the host's IAM role unless you block it.
- EKS adds a cluster to secure (API access, RBAC, pod IAM) and about $73/month for the control plane. Worth it with many services and a platform team, not for one API.

## Edge: WAF attached directly to the ALB
- Rejected: CloudFront + WAF. This is an API, so there's no caching benefit.
- Rejected: NLB. WAF can't attach to an NLB, because an NLB doesn't decrypt TLS and never sees the HTTP request.
- Limit to know: WAF on an ALB inspects only the first 8 KB of the request body.

## Private egress: VPC endpoints, no NAT
- Rejected: NAT gateway. It lets tasks reach any address on the internet.
- Fargate only needs ECR, Secrets Manager, CloudWatch Logs and S3, and the endpoints cover all four.
- Patching means rebuilding the image in CI and redeploying. Running containers are never updated in place.
- Cost: about $7/month per interface endpoint per AZ, so roughly $60/month total. That's more than one NAT gateway. We accept it for security.
- If the app ever calls third-party APIs: add a NAT plus AWS Network Firewall with a domain allowlist.

## Subnets: 3 tiers (public / private / isolated)
- With no NAT, the private and isolated tiers both have no route out today. The security groups do the real work.
- The isolated tier keeps the DB closed if someone adds a NAT later. Subnets are free, and RDS needs a DB subnet group anyway.

## Accounts: prod, staging, security
- The security account holds the org CloudTrail and the log archive bucket (Object Lock). An attacker with prod admin can't delete it.
- Staging is a scaled-down copy and the DAST target, so security testing never touches prod.
- At larger scale, split security into log-archive and security-tooling accounts (the AWS Control Tower default).
- Only prod is built in Terraform. The other two accounts are documented, not built.

## Log bucket encryption: SSE-S3
- Forced: ALB access logs don't support SSE-KMS.
- For logs, the threat is deletion, not reading. Object Lock covers deletion.

## Secrets: ECS injects them as env vars at container start (option A)
- The task definition holds only the secret's ARN. The ECS agent fetches the value with the task execution role, which needs `secretsmanager:GetSecretValue` on that secret and `kms:Decrypt` on that key. The KMS key policy must also allow the role.
- Rejected: the app calls Secrets Manager itself (option B). B lets the app pick up a rotated secret without a restart, but it needs SDK code, caching and agreement with the dev team on how secrets are loaded.
- Security is about equal. An attacker who can run code in the container gets the password either way.
- Trade-off we accept: a rotated secret takes effect only after a redeploy.
- Rule: never log environment variables.

## IAM roles: three, each with one job
| Role | Used by | Allowed |
|---|---|---|
| Deploy role | GitHub Actions | Push to one ECR repo, register a task definition, update one ECS service, `iam:PassRole` on the two task roles only |
| Task execution role | ECS agent | Pull the image, read one secret plus `kms:Decrypt` on its key, write logs |
| Task role | App code | Nothing today, because the app makes no AWS calls |

- `iam:PassRole` is scoped to the two task role ARNs and to `ecs-tasks.amazonaws.com`. On `*`, a compromised pipeline could attach an admin role to a task and take over the account.
- `ecr:GetAuthorizationToken` and `ecs:RegisterTaskDefinition` don't support resource-level permissions, so they stay on `*`.

## Pipeline credentials: GitHub OIDC, no stored keys
- The trust policy checks `sub = repo:SaputraUta/devsecops-home-test:environment:<env>` and `aud = sts.amazonaws.com`.
- There's one GitHub Environment per target, each mapped to its own deploy role in its own account:
  - `staging`: auto-deploys on merge to main.
  - `production`: needs a required reviewer and is limited to the main branch. The job gets no OIDC token until it's approved.
- A staging token can't assume the prod role, because the `sub` claim doesn't match.

## Human access to prod: SSO, read-only by default, break-glass for admin
- IAM Identity Center with MFA. No IAM users and no access keys in prod.
- The daily permission set is `ProdReadOnly`. Prod changes go only through the approved pipeline.
- A break-glass admin permission set exists. Using it is recorded by CloudTrail and fires an EventBridge rule that alerts the security team through SNS.
- Root user: MFA on, no access keys ever, credentials in a vault. With Organizations, use centralized root access to remove member-account root credentials.
- SCP guardrails on prod: deny creating IAM users or access keys, deny disabling CloudTrail or GuardDuty, deny regions we don't use.
- Nobody holds standing admin. Elevated access is break-glass only, and every use alerts the security team. At scale, replace break-glass with just-in-time elevation (AWS TEAM).

## Task 1 risks: architecture only (pipeline risks belong to Task 2)
| # | Risk | Mitigation |
|---|---|---|
| 1 | DB or app reachable from the internet | Only the ALB is public. App and DB sit in private/isolated subnets, and each SG allows only the tier in front of it. |
| 2 | Web attacks on the public ALB (SQL injection, bots, floods) | WAF with AWS managed rules plus rate limiting |
| 3 | A role with too much power | Three single-purpose roles. The deploy role can only pass the two task roles. |
| 4 | Secret leaked from code or image | Secrets Manager + KMS. Config holds only the ARN, and the value is injected at start. |
| 5 | Stolen disk, snapshot or backup | RDS and secrets encrypted with a customer-managed KMS key, plus TLS in transit |
| 6 | Compromised container sends data out | No NAT, so there's no internet route. It can only reach AWS through VPC endpoints. |
| 7 | Unauthorized human access to prod | SSO + MFA, read-only daily, break-glass admin with an alert |
| 8 | Attacker deletes logs to hide | Org CloudTrail to the security account, Object Lock |
