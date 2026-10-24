# Task 4: Container and application security

App: `app/`, a minimal Express API (`/health`, `/api/orders/:id`). Image: `app/Dockerfile`.
`app/Dockerfile.before` is the naive version, kept only as the baseline for comparison.

## Result

| | Before | Hardened |
|---|---|---|
| Base | `node:22` (full Debian, floating tag) | distroless `nodejs22-debian12:nonroot`, pinned by digest |
| Size | 410 MB | 53 MB |
| Critical / High CVEs | 30 / 626 | 1 / 6 (one package, not loaded; see policy) |
| User | root | uid 65532 |
| Shell, npm, apt, curl | all present | none |
| Secret in image | `ENV DB_PASSWORD` (Trivy DS-0031 CRITICAL) | none |

Full numbers: `evidence/task4/scan-summary.md`.

## Requirement → how → evidence

| Requirement | How | Evidence |
|---|---|---|
| Minimal, trusted base image | Google distroless, chosen after scanning 4 candidates (slim, alpine, distroless, Chainguard). Alpine's High findings were mostly npm itself. Chainguard's free tier can't hold Node 22 | `scan-summary.md` |
| Non-root | `USER 65532:65532`, numeric so the runtime can verify it. App code is owned by root, so the process can't rewrite it | `runtime-checks.txt` §3, §5 |
| No unnecessary packages or tools | Multi-stage: npm and the build toolchain stay in the build stage. The runtime has no shell, so `docker exec sh` fails and an attacker has no tools to work with | `runtime-checks.txt` §4 |
| Dependency version control | Exact version in `package.json`, `package-lock.json` committed, `npm ci` installs only what the lock says, `--omit=dev --ignore-scripts`. Both base images pinned by `sha256` digest | `app/Dockerfile` |
| Container vulnerability scanning | Trivy: OS and npm packages, secrets, image misconfig. Same scan runs as a gate in the pipeline (Task 2) | `trivy-before-critical.txt`, `trivy-after.txt` |
| Secure configuration | `DB_PASSWORD` is injected at container start, by ECS from Secrets Manager in AWS (Task 1). The app refuses to start without it and never logs it | `runtime-checks.txt` §1, §2 |
| No secrets in layers | Allowlist `.dockerignore`, so `.env` and `.git` can't enter the build context. No secret in `ENV`/`ARG`. Checked with `docker history`, image config, and Trivy's secret scanner | `runtime-checks.txt` §6 |

## Trade-offs accepted

- **No shell means harder debugging.** `ECS Exec` has nothing to run. For an incident, run the same digest from the `:debug-nonroot` distroless variant in staging instead of adding a shell to prod.
- **A digest pin doesn't update itself.** Without automation it goes stale, which is worse than a floating tag. Dependabot (`docker` ecosystem) opens the bump PR, and the pipeline scans it like any other change.
- **No Docker `HEALTHCHECK`.** ECS ignores it, so the health check lives in the ALB target group and the ECS task definition. Trivy's DS-0026 (LOW) is accepted for that reason.

Note: `.dockerignore` now allowlists only `package*.json` and `src/`, so a rebuild of `Dockerfile.before` would no longer copy `.env` in. The baseline numbers were captured before the allowlist existed.
