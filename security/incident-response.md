# Troubleshooting and incident response

Three scenarios, each answered against what this repo built: ECS Fargate in private subnets with no NAT, VPC endpoints, a customer-managed KMS key, three single-purpose IAM roles, and GitHub OIDC pinned to a GitHub Environment. See `architecture/decisions.md` and `security/vulnerability-policy.md`.

## Scenario A: Trivy blocks on a Critical in the base image

The team says the app works and wants to ship. That is not the question. A vulnerability almost never shows up as a functional bug, so "it works" tells us nothing about risk. The gate stays closed until there is evidence.

### Investigation

1. Confirm the finding. Check that the package is really in the image and the installed version is really affected. Don't trust the scanner alone.
2. Check reachability. Is the vulnerable library loaded by the running process? Is the vulnerable function reachable from a request?
3. Check exposure. This service sits behind a public ALB, so anything reachable from HTTP counts as internet-facing.
4. Check for a fix. Is there a patched package or a rebuilt base image? Trivy's `FixedVersion` column and the distro tracker answer this.

This repo hit exactly this case. The hardened image scans with 1 Critical and 6 High, all in Debian's `libssl3` 3.0.18 inside the distroless base.

| Question | Answer | Evidence |
|---|---|---|
| In the image? | Yes, distroless ships it | `evidence/task4/trivy-after.txt` |
| Loaded by the app? | No. Node 22 statically links its own OpenSSL 3.5.4. `/proc/1/maps` shows no `libssl` or `libcrypto` | `evidence/task4/libssl-reachability.txt` |
| Critical CVE applicable? | No. CVE-2026-31789 is a 32-bit-only overflow and the image is x64 | same file |
| Fix upstream? | Debian has it. Distroless hasn't rebuilt yet | `FixedVersion` in the report |

### Likely root causes

The base image is older than the distro patch, or upstream (here, distroless) hasn't published a rebuild yet. Less often: a stale digest pin that never got bumped, or a dependency pulling in a package the app doesn't need.

### Corrective actions

1. If a patched base exists, bump the digest, rebuild, rescan. This is the default and usually takes minutes.
2. If no patch exists, cut the surface: switch base (Chainguard, a newer distro release), or remove the component if the app doesn't need it.
3. If risk remains, add a compensating control: a WAF rule for the exploit pattern, tighter security groups, or a narrower IAM boundary.
4. Only then consider an exception, and only with all five parts the policy requires: evidence, a named owner, an approver who isn't asking to ship, an expiry (30 days max for Critical), and a record in `.trivyignore.yaml`.

The exception lives in the repo and goes through review like code:

```yaml
vulnerabilities:
  - id: CVE-2026-31789
    statement: "32-bit only (image is x64); system libssl3 is not loaded by Node"
    expired_at: 2026-11-07
```

When `expired_at` passes, Trivy stops honouring the entry and the gate blocks again on its own. Nobody has to remember. Dependabot watches the base digest, and the bump PR deletes the exception in the same change.

### Release decision

| Situation | Decision |
|---|---|
| Finding confirmed, reachable, internet-facing, no fix | Release waits. Mitigate or roll back to the last clean image |
| Fix exists | Release waits for the rebuild. It's faster than writing an exception |
| Not reachable, evidence attached, approved | Ship with a time-boxed exception |

Authorization comes from the security lead, not the developer who wants to ship and not me alone. The production GitHub Environment already needs a required reviewer, so the approval is recorded on the run. I've rejected vendor-proposed fixes before when they would have broken production. The reverse also holds: a business deadline does not override an exploitable Critical.

## Scenario B: ECS Fargate task can't retrieve its secret

### Investigation

Start with what ECS already tells you. A task that dies before the container runs leaves a `stoppedReason` on the stopped task, and that string usually names the layer.

```sh
aws ecs list-tasks --cluster orders-production --desired-status STOPPED
aws ecs describe-tasks --cluster orders-production --tasks <task-id> \
  --query 'tasks[].{reason:stoppedReason,containers:containers[].reason}'
aws ecs describe-services --cluster orders-production --services orders-api \
  --query 'services[].events[:10]'
```

A typical message is `ResourceInitializationError: unable to pull secrets or registry auth`, followed by either `AccessDeniedException` (IAM or KMS) or a timeout (network). That split decides where to look next. CloudWatch Logs will usually be empty, because the container never started. Empty logs plus a `ResourceInitializationError` is itself a signal.

Then walk the layers in order.

| Layer | What to check |
|---|---|
| Which role | The secret is injected by the ECS agent at start using the task execution role. The task role is only for the app at runtime. A common mistake is granting the task role and leaving the execution role without access |
| IAM on the execution role | `secretsmanager:GetSecretValue` on the exact secret ARN. ECS references can include a JSON key or version suffix, so check the ARN pattern matches |
| Secret resource policy | An explicit deny or a condition (source VPC, principal org) that blocks the role |
| KMS | The role needs `kms:Decrypt` on the key, and the key policy must also allow it, either by naming the role or by delegating to account IAM (this repo's key delegates). Both must allow |
| Network | No NAT here, so the task can only reach AWS through interface endpoints. Needed: `secretsmanager`, `ecr.api`, `ecr.dkr`, `logs`, plus the S3 gateway endpoint for image layers. Each needs private DNS enabled and a security group allowing 443 from the task SG |
| Task definition | Secret ARN typo, wrong region, or a secret that was deleted or is pending deletion |

On KMS and the network: the ECS agent doesn't call KMS itself. Secrets Manager decrypts on the role's behalf, so the role's KMS permissions are checked but no `kms` endpoint is needed for this path. A `kms` endpoint is needed only if the app calls KMS directly.

### Isolating it without admin

Read-only inspection plus the IAM policy simulator answers almost every question above. None of it changes anything.

```sh
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<account-id>:role/orders-production-task-execution \
  --action-names secretsmanager:GetSecretValue kms:Decrypt \
  --resource-arns arn:aws:secretsmanager:ap-southeast-3:<account-id>:secret:<name> \
                  arn:aws:kms:ap-southeast-3:<account-id>:key/<key-id>

aws secretsmanager get-resource-policy --secret-id <secret-arn>
aws kms get-key-policy --key-id <key-id> --policy-name default

aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values=<vpc-id> \
  --query 'VpcEndpoints[].{svc:ServiceName,dns:PrivateDnsEnabled,sg:Groups[].GroupId,state:State}'
aws ec2 describe-security-groups --group-ids <endpoint-sg-id>
```

The simulator evaluates identity policies. It doesn't fully evaluate the key policy or the secret resource policy, which is why I read those two separately. CloudTrail fills the gap: a `GetSecretValue` or `Decrypt` event with `errorCode: AccessDenied` from the execution role proves the request reached AWS and was refused. No event at all points at the network.

To test the network path, run a throwaway task in the same subnet and security group with a small image that resolves `secretsmanager.ap-southeast-3.amazonaws.com` and opens a TLS connection to it. If the name resolves to a public IP, private DNS is off. If it resolves to a private IP and times out, it's the endpoint security group. Stop the task afterwards.

None of this needs admin. The `ProdReadOnly` SSO permission set covers the reads and the simulator. The fix itself goes through Terraform and the pipeline, not a console edit.

### Likely root causes

1. Permission added to the task role instead of the execution role.
2. KMS key policy neither names the execution role nor delegates to account IAM, so IAM allows it but the key refuses.
3. `secretsmanager` endpoint missing, private DNS off, or its security group doesn't allow 443 from the task SG.
4. Secret ARN in the task definition doesn't match the IAM resource (suffix, region, rotated or recreated secret).

### Corrective actions

Grant exactly the missing permission on exactly the one resource, through Terraform. Add the key policy statement if that was the gap. Add or fix the endpoint and its SG rule. Redeploy and confirm the task reaches `RUNNING`. Then add a deploy smoke check that fails the pipeline if the new task stops with `ResourceInitializationError`, so the next one is caught in staging.

## Scenario C: Unexpected API calls from the pipeline principal

Contain first, investigate second. Keep the evidence intact while doing it.

### Immediate containment

The deploy role is assumed through GitHub OIDC, so there's no long-lived key to rotate. The risk is live STS sessions, which keep working until they expire even after you change policies that only affect new sessions. Kill them with an inline explicit deny on the role, conditioned on token issue time:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Deny",
    "Action": "*",
    "Resource": "*",
    "Condition": { "DateLessThan": { "aws:TokenIssueTime": "<now-iso8601>" } }
  }]
}
```

This is what the console's "Revoke active sessions" button writes. Explicit deny beats every allow, so existing sessions die at once. Then stop new sessions: set the production Environment to block deploys, and if needed tighten the trust policy so nothing can assume the role while we look.

If a static access key were involved, deactivate it. Don't delete it. Don't delete the role either. Deleting the principal loses the link between the identity and its history, and the key ID is evidence.

If the calls created anything active (new users, keys, roles, instances), deny or disable those too before going further.

### Investigation

1. Preserve evidence. The org CloudTrail writes to the log archive bucket in the security account under Object Lock, so prod admin can't erase it. Export the relevant time window and record the query used.
2. Scope the blast radius by principal and time. Quick look with `lookup-events`, full picture with Athena over the trail:

```sh
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=<session-name> \
  --start-time <t0> --end-time <t1>
```

```sql
SELECT eventtime, eventname, eventsource, awsregion, sourceipaddress, useragent, errorcode
FROM cloudtrail_logs
WHERE useridentity.arn LIKE 'arn:aws:sts::<account-id>:assumed-role/orders-production-github-deploy/%'
  AND eventtime BETWEEN '<t0>' AND '<t1>'
ORDER BY eventtime;
```

3. Look for persistence and escalation first: `iam:Create*`, `AttachRolePolicy`, `PutRolePolicy`, `CreateAccessKey`, `UpdateAssumeRolePolicy`, `iam:PassRole` to anything other than the two task roles, task definitions pointing at a new image or role.
4. Look for spread and data access: calls in regions we don't use, `GetSecretValue`, S3 reads, ECR pulls of other repos, `ecs:RunTask`.
5. Check the source. `sourceIPAddress` and `userAgent` should match GitHub-hosted runners. The session name maps to a workflow run.
6. Check the GitHub side. Which workflow run requested the token, which commit, who pushed it, and who approved the production Environment. Look for a changed workflow file, a new or repinned third-party action, or a compromised dependency that ran during the build. Actions in this repo are pinned to commit SHAs for exactly this reason.

Decide which of two stories fits. Credentials compromised: someone outside the pipeline used a token. Permissions abused: the pipeline itself ran malicious code (poisoned action, dependency, or merged workflow change) with its legitimate role. The second is more likely with OIDC, and the fix lives in the repo, not in AWS.

### Likely root causes

1. A compromised or repinned GitHub Action or build dependency running with the job's OIDC token.
2. A workflow change that widened what the job does, merged without enough review.
3. A trust policy looser than intended (wildcard `sub`, missing Environment pin), letting another repo or branch assume the role.
4. A benign cause: a new deploy step nobody documented. Rule this out early, but only with evidence.

### Recovery

1. Remove whatever the attacker created. Revert policy changes from the Terraform state, not from memory.
2. Rotate every secret the role could reach or could have exposed. The deploy role can't read the app secret, but a task definition it registered could have, so rotate the DB password anyway if a rogue task ran.
3. Redeploy a known-good image by digest from before the window, through the pipeline.
4. Restore the trust policy scoped tighter: `sub` pinned to `repo:<org>/<repo>:environment:production`, `aud` fixed, and only then remove the deny.
5. Confirm with a clean CloudTrail window after recovery.

### Corrective actions

Write the blameless postmortem with the timeline from CloudTrail and GitHub. Add an EventBridge rule on IAM writes by the deploy role, since it should never make any. Tighten CODEOWNERS on `.github/workflows/`. Keep `iam:PassRole` scoped to the two task roles. In my current work on a regulated multi-account AWS setup, the lesson that keeps repeating is that the log account being out of reach of prod admin is what makes the investigation possible at all.
