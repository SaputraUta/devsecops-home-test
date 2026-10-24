# Scan results

| Scan | Result | File |
|---|---|---|
| Trivy image, before hardening (`node:22`, root) | 30 Critical, 626 High, secret in `ENV` (DS-0031) | `task4/trivy-before-critical.txt` |
| Trivy image, hardened (distroless, nonroot) | 1 Critical, 6 High, all in unloaded `libssl3`, excepted until 2026-11-07 | `task4/trivy-after.txt`, `task4/scan-summary.md` |
| libssl3 reachability | Not loaded by the Node process | `task4/libssl-reachability.txt` |
| Runtime checks | uid 65532, no shell/npm/curl, code not writable, no secret in layers | `task4/runtime-checks.txt` |
| Terraform validate | Valid | `task3/terraform-validate.txt` |
| Checkov, repo Terraform + Dockerfile | 183 passed, 0 failed, 1 skipped (Multi-AZ, reason inline) | `task3/checkov-terraform.txt` |
| Checkov, Scenario B public database | 10 failed, including `CKV_AWS_17`, `CKV_AWS_16`, `CKV2_ORDERS_1` | `task3/checkov-scenario-b-public-db.txt` |
| Pipeline on `main` | All gates green, production paused for approval, approved, simulated deploy | `task2/01` to `04` |
| Pipeline on a bad PR | `sca` failed (lodash CVE-2021-23337), `secrets` failed (hardcoded key), build skipped | `task2/05` to `07` |
| ZAP baseline | First run: 2 WARN (10021, 10055). After header fix: 61 PASS, 0 WARN | `dast-report` artifact on each run, `security/dast.md` |
| Semgrep | 112 rules, 0 findings | `sast-report` artifact on each run |
| Gitleaks, full history | No leaks | `secrets-report` artifact on each run |
