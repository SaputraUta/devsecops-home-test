# Container and application security

The app is in `app/`, a small Express API. The image is built from `app/Dockerfile`. `app/Dockerfile.before` is the usual "it works" version, kept only to compare against.

| | Before | After |
|---|---|---|
| Base image | `node:22` (full Debian) | distroless `nodejs22-debian12:nonroot`, pinned by digest |
| Size | 410 MB | 53 MB |
| Critical / High CVEs | 30 / 626 | 1 / 6 (one library the app never loads) |
| Runs as | root | uid 65532 |
| Shell, npm, curl | yes | none |
| Password in image | yes (`ENV DB_PASSWORD`) | no |

## Requirements

| Requirement | How | Evidence |
|---|---|---|
| Minimal, trusted base | Google distroless. I scanned 4 options: slim had 67 High, Alpine still ships npm (11 High), Chainguard's free tier can't pin Node 22 | `evidence/task4/scan-summary.md` |
| Non-root | `USER 65532`. App files are owned by root, so the app can't change its own code | `evidence/task4/runtime-checks.txt` |
| No extra tools | Two-stage build. npm stays in the build stage, the final image has no shell or package manager | `runtime-checks.txt` |
| Version control | Exact version in `package.json`, committed lockfile, `npm ci`. Base images pinned by digest, updated by Dependabot | `app/Dockerfile` |
| Vulnerability scanning | Trivy before and after, and as a gate in the pipeline | `evidence/task4/trivy-*.txt` |
| Secure config | `DB_PASSWORD` comes from an environment variable, set by ECS from Secrets Manager. The app won't start without it | `runtime-checks.txt` |
| No secrets in layers | `.dockerignore` only lets in `package.json`, the lockfile and `src/`, so `.env` can't get copied. Checked with `docker history` and Trivy | `runtime-checks.txt` |

## Trade-offs

- No shell makes debugging harder. For an incident, run the distroless `:debug` variant of the same image in staging.
- A pinned digest doesn't update itself. Dependabot opens the PR when a new image comes out.
- There's no Docker `HEALTHCHECK`, because ECS ignores it. The health check is in the ALB and the ECS task definition.
