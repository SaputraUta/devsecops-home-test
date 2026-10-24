# CI/CD security pipeline

Pipeline: `.github/workflows/pipeline.yml`. It runs on every PR to `main` and every push to `main`.

```
validate · sast · sca · secrets · iac          run in parallel, all must pass
        ↓
build → image.tar
        ↓
container-scan · dast                           both test the same image.tar
        ↓  push to main only
publish → deploy-staging → deploy-production    production needs approval
```

## Security gates

| Stage | Tool | Fails when |
|---|---|---|
| Source validation | `npm test`, `terraform fmt` and `validate` | A test or check fails |
| SAST | Semgrep (OWASP Top 10, Node.js, secrets rules) | Any finding |
| SCA | Trivy on `package-lock.json` | Any High or Critical |
| Secret scanning | Gitleaks on the full git history | Any secret |
| IaC scanning | Checkov on Terraform and the Dockerfile, plus a custom rule | Any failed check without a written reason |
| Image build | Docker | Build error |
| Container scanning | Trivy on the built image | Any Critical, or a High that has a fix |
| DAST | ZAP baseline against the running container | Any warning |
| Deployment approval | GitHub Environment `production` | Nobody approves |

SonarQube is the suggested SAST tool. I used Semgrep because it doesn't need a server, and it blocks the build the same way.

Medium and Low findings don't block. They follow `security/vulnerability-policy.md`, and a nightly job (`nightly-scan.yml`) rescans `main` and opens a GitHub issue for every High or Critical so they get tracked.

## Other choices

- The image that gets published is the exact file that was scanned. Nothing is rebuilt after scanning.
- PRs get scanned but never published or deployed.
- No cloud keys are stored in GitHub. Deploy jobs get short-lived AWS credentials through OIDC.
- Each job only gets the permissions it needs. The default is read-only.
- Every action is pinned to a commit SHA, and the Gitleaks download is checked against its published checksum. Dependabot keeps them updated.
- Secrets don't reach the logs: Gitleaks redacts its output, registry logins read the password from stdin, and the app never logs its environment.

## False positives and accepted risks

Findings are never silenced by editing the pipeline. Every exception lives in a file in the repo, with a reason, and goes through a PR:

| Tool | Where |
|---|---|
| Trivy | `.trivyignore.yaml`, with a reason and an expiry date |
| Checkov | `# checkov:skip=<ID>:<reason>` on the resource |
| Semgrep | `# nosemgrep` on the line, with the reason in the PR |
| Gitleaks | `.gitleaksignore`, for test fixtures only |
| ZAP | a rules file, with the reason in the PR |

A false positive (the tool is wrong) needs one reviewer. An accepted risk (the finding is real but can't be exploited here) needs the full exception process in the vulnerability policy: evidence, an owner, approval from the security lead, and an expiry date.

Example: `.trivyignore.yaml` has 6 `libssl3` CVEs from the base image, expiring 2026-11-07. Proof that Node never loads that library: `evidence/task4/libssl-reachability.txt`.

## Evidence

- Green run, production waiting for approval, then approved: `evidence/task2/01` to `04`
- A PR with a vulnerable library and a hardcoded key, blocked by SCA and Gitleaks: `evidence/task2/05` to `07`
- Every run's scan reports are downloadable as artifacts in the Actions tab
