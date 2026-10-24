# Task 2: CI/CD security pipeline

Pipeline: `.github/workflows/pipeline.yml` (GitHub Actions). Runs on every pull request to `main` and every push to `main`.

```
validate · sast · sca · secrets · iac        (parallel, all must pass)
        ↓
build  →  image.tar
        ↓
container-scan · dast                         (parallel, on the same image.tar)
        ↓  push to main only
publish  →  deploy-staging  →  deploy-production (required reviewer)
```

## Security gates

| # | Stage | Tool | What it checks | Fails the pipeline when |
|---|---|---|---|---|
| 1 | Source validation | `npm test`, `terraform fmt -check`, `terraform validate` | Unit tests, Terraform formatting and syntax | Any test or check fails |
| 2 | SAST | Semgrep (`p/owasp-top-ten`, `p/nodejs`, `p/secrets`) | Insecure code patterns in `app/` | Any finding (`--error`) |
| 3 | SCA | Trivy `fs` | Known CVEs in dependencies from `package-lock.json` | Any High or Critical |
| 4 | Secret scanning | Gitleaks | Secrets in every commit of the git history | Any finding |
| 5 | IaC scanning | Checkov | Terraform and Dockerfile misconfigurations | Any failed check that isn't skipped with a reason |
| 6 | Image build | Docker | Builds once, tagged with the commit SHA, saved as an artifact | Build error |
| 7 | Container scanning | Trivy `image` | OS packages, npm packages, secrets and misconfig inside the built image | Any Critical, or any High with a fix available |
| 8 | DAST | OWASP ZAP baseline | Passive checks against the running container: headers, information leaks, cookies | Any WARN or FAIL |
| 9 | Deployment approval | GitHub Environment `production` | A named reviewer must approve; only `main` can deploy | Not approved |

SonarQube is the suggested SAST tool. Semgrep is used instead because it needs no server, and the gate logic is the same: a finding fails the build.

Lower severities don't block. They're handled by `security/vulnerability-policy.md`: Medium within 90 days, Low at the next base-image bump. The nightly workflow (`.github/workflows/nightly-scan.yml`) rescans `main` and opens or updates one GitHub issue per High and Critical finding, so tracking isn't left to memory.

## Design choices behind the gates

- **Scan what you ship.** `publish` pushes the exact `image.tar` that `container-scan` and `dast` tested. Nothing is rebuilt after scanning.
- **Scans run on PRs, publishing doesn't.** Unmerged code is scanned but never pushed or deployed.
- **No stored cloud credentials.** Deploy jobs get an OIDC token (`id-token: write`) and assume a role whose trust policy only accepts this repo and that GitHub Environment. A staging token can't assume the production role.
- **Least privilege per job.** The workflow default is `contents: read`. Only `publish` gets `packages: write`, only the deploy jobs get `id-token: write`, and only the nightly scan gets `issues: write`.
- **Pinned supply chain.** Every action is pinned to a commit SHA, every tool image to a version, and the Gitleaks binary is checked against its published SHA-256. Dependabot opens PRs to bump them.
- **Secrets stay out of logs.** Gitleaks runs with `--redact`, registry logins use `--password-stdin`, and the app never logs `process.env`. The only value passed in CI is a dummy `DB_PASSWORD` for the DAST container.

## False positives and accepted risks

A finding is never silenced by editing the pipeline. Every suppression lives in a reviewed file, in the repo, with a reason:

| Tool | Where | Format |
|---|---|---|
| Trivy | `.trivyignore.yaml` | CVE id, `statement` (the evidence), `expired_at` |
| Checkov | Inline `# checkov:skip=<ID>:<reason>` on the resource | Reason required |
| Semgrep | `# nosemgrep: <rule-id>` on the line | Reason in the PR |
| Gitleaks | `.gitleaksignore` (finding fingerprint) | Only for test fixtures |
| ZAP | `rules.tsv` with `IGNORE` | Reason in the PR |

Two kinds of entries go there:

- **False positive:** the finding is wrong, for example a test fixture that looks like a key. One reviewer is enough.
- **Accepted risk:** the finding is real but not exploitable here, or has a compensating control. That needs the full exception process in `security/vulnerability-policy.md`: evidence, owner, an approver who isn't the requester, and an expiry. When it expires, the gate blocks again.

Live example: `.trivyignore.yaml` holds 6 libssl3 CVEs from the distroless base image, expiring 2026-11-07. The evidence that Node never loads that library is in `evidence/task4/libssl-reachability.txt`.

## Evidence

- Green run with every gate passing and production waiting for approval: `evidence/task2/01-*.webp` to `04-*.webp`
- A PR that adds a vulnerable dependency and a hardcoded key, blocked by the SCA and secrets gates: `evidence/task2/05-*.webp`
- Scan reports for every run are downloadable as workflow artifacts (`sast-report`, `sca-report`, `secrets-report`, `iac-report`, `container-scan-report`, `dast-report`)
