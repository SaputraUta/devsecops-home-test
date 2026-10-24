# Troubleshooting and incident response

## Scenario A: Trivy reports a Critical in the base image, the team wants to deploy

1. I check the finding first. Is the package really in the image, and is our version really affected?
2. I check if it matters for us. Does the app actually use that library? Is the service reachable from the internet?
3. I look for a patched base image. If there is one, we bump it, rebuild and rescan. That's usually quicker than any discussion.
4. If there's no patch yet, I check whether our existing controls (WAF rules, network rules) already block the known exploit. If they don't, I add a rule for it, or move to a base image that isn't affected.
5. The app working fine doesn't change the decision. Vulnerabilities usually don't break anything until someone uses them.
6. If we can show it can't be exploited here, it can ship with an exception: written evidence, an owner, an expiry date, and approval from the security lead, not from the team that wants to ship. When it expires the pipeline blocks again.
7. If it can be exploited and there's no fix or workaround, the release waits.

This happened in this repo. Trivy found a Critical in `libssl3` inside the distroless image. Node never loads that library, I checked it on the running container (`evidence/task4/libssl-reachability.txt`). So it's an exception in `.trivyignore.yaml` that expires on 2026-11-07, and the rule is in `security/vulnerability-policy.md`.

## Scenario B: ECS Fargate task can't get its secret from Secrets Manager

1. I open the stopped task in the ECS console and read the stopped reason. It usually says either access denied or a timeout.
2. Access denied means a permission problem. I check, in this order:
   - The right role. The secret is fetched by the **task execution role** when the container starts. The **task role** is only for the app after it runs. Putting the permission on the task role is the most common mistake.
   - The execution role has `secretsmanager:GetSecretValue` on that exact secret.
   - The secret's own resource policy doesn't deny it.
   - If the secret uses a customer-managed KMS key: the role has `kms:Decrypt`, and the key policy also allows it. Both have to allow.
3. A timeout means a network problem. Tasks in a private subnet need a way to reach Secrets Manager: a NAT gateway, or a `secretsmanager` VPC endpoint with private DNS on and a security group that allows 443 from the task.
4. CloudWatch logs are usually empty here, because the container never started. ECS service events and CloudTrail are more useful. If CloudTrail shows the call was denied, it's permissions. If there's no call at all, it never reached AWS, so it's the network.
5. I don't need admin for any of this. Reading the role, the secret policy, the key policy and the endpoints is read-only access. The IAM policy simulator can test "can this role call GetSecretValue on this secret" without changing anything.
6. The fix goes through Terraform and the pipeline, not a manual console change, so it's reviewed and doesn't drift.

## Scenario C: CloudTrail shows unexpected API calls from the pipeline's IAM principal

**First, check if it's expected**
1. Find who owns the role, a team or a person, and ask them right away: did they run this, and did they expect it? A new deploy step or a manual run can explain it.
2. If they can explain it, I confirm with the run logs and close it. If nobody can, I treat it as a compromise.

**Contain**
1. Stop the principal from doing more. If it's an access key, deactivate it (don't delete it, it's evidence). If it's a role, revoke its active sessions.
2. Pause deployments so the pipeline can't get new credentials while we look.
3. If the calls created anything (new users, keys, roles, resources), disable those too.

**Investigate**
1. Keep the evidence safe. CloudTrail should go to a separate log account where prod admins can't delete it.
2. List everything that principal did in the time window: which API calls, which regions, from which IP.
3. Look for signs of persistence first: new IAM users, access keys, roles, or changed policies. Then look for data access, like secrets or S3 reads.
4. Check the pipeline side: which run made the calls, which commit, who merged it, and whether a workflow, action or dependency changed recently.
5. Decide which case it is: the credentials leaked and someone else used them, or the pipeline itself ran bad code with its normal permissions.

**Recovery**
1. Remove whatever was created and revert changed policies.
2. Rotate every secret that principal could reach.
3. Redeploy a known-good image.
4. Tighten the role before re-enabling it, then confirm CloudTrail looks clean.

**Prevent it next time**
- Use short-lived OIDC credentials instead of stored access keys, as the pipeline here does.
- Scope the deploy role to only what deploy needs, with `iam:PassRole` limited to the task roles.
- Alert on any IAM change made by the pipeline role, since it should never make one.
- Require a second person to approve any change to the pipeline files (`.github/workflows/`).
