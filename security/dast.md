# DAST and OWASP Top 10

Tool: OWASP ZAP. Target: only this repo's own app, in CI or in the staging account. Nothing else is ever scanned.

## What runs today

The `dast` job in `.github/workflows/pipeline.yml` runs on every pull request and every push to main.

1. It loads the exact image built earlier in the same run (`image.tar`), so ZAP tests the bytes that would ship.
2. It creates a private Docker network on the runner (`docker network create dast`) and starts the app on it with a dummy `DB_PASSWORD`.
3. It runs ZAP baseline (`ghcr.io/zaproxy/zaproxy:2.17.0`, `zap-baseline.py`) against `http://app:8080/api/orders/1`.
4. It uploads `zap.html` and `zap.json` as the `dast-report` artifact, even when the scan fails.

The job is called without `-I`, so any WARN or FAIL fails it. `publish` needs `dast`, so nothing reaches the registry or staging without a clean scan.

The gate found real issues. The first local baseline run against the app reported 2 warnings:

| ZAP rule | Finding | Fix in `app/src/app.js` |
|---|---|---|
| 10021 | `X-Content-Type-Options` header missing | `X-Content-Type-Options: nosniff` on every response |
| 10055 | CSP: Failure to Define Directive with No Fallback | `default-src 'none'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'` |

Two more changes came out of it. `Cache-Control: no-store`, because order data shouldn't sit in a shared cache. A JSON 404 handler, because Express's default 404 page set its own CSP and overrode ours. `x-powered-by` was already disabled, so rule 10037 passes. After the fix: 61 PASS, 0 WARN, 0 FAIL.

## 1. How the app is made available in a safe test environment

Per pull request: the container runs on the CI runner, on a Docker network that only the app and ZAP share. No port is published to the host. It has no real database and no real secrets. When the job ends, the runner is thrown away.

Nightly (design, not built): the full scan targets staging. Staging is a separate AWS account (`architecture/decisions.md`), a scaled-down copy of prod, and named there as the DAST target. It holds no production data and no production credentials. The image in staging is the same digest that passed the PR gates.

## 2. Which DAST checks run automatically

| Scan | When | Target | What it does |
|---|---|---|---|
| ZAP baseline | Every PR and push to main | CI container | Spiders, then passive rules only: headers, cookies, info leaks, error pages. No attack payloads. About a minute. |
| ZAP full scan (not built) | Nightly | Staging | Spider plus active scan: SQL injection, XSS, path traversal, command injection, SSRF probes. 20+ minutes. |
| ZAP API scan (not built) | Nightly, once an OpenAPI spec exists | Staging | `zap-api-scan.py` imports the spec, so every endpoint and parameter gets attacked, not only what the spider finds. |

Baseline goes on every PR because it's passive and fast. The active scan sends real payloads and takes too long for a PR, so it runs nightly against staging.

## 3. How authentication is handled during testing

The app has no authentication today. `/health` and `/api/orders/:id` are public. This is the design for when auth exists.

1. One dedicated, non-privileged test user per environment, created in staging only. It never exists in prod.
2. Its credentials live in a GitHub Environment secret on `staging`. Never in the repo, never in the ZAP plan file.
3. A login step before the scan calls the login endpoint and gets a token.
4. The token goes into every ZAP request as a header, either with the replacer (`-z "-config replacer.full_list(0).matchstr=Authorization ..."`) or with a ZAP Automation Framework plan that uses script-based or JSON-based authentication, so ZAP can log in again if the session expires.
5. The plan defines a logged-in indicator (for example a 200 on `/api/me`). If ZAP is logged out, the scan fails instead of passing on login pages.
6. Run the same scan twice: unauthenticated, then authenticated as the test user, plus a second test user who owns different orders. Any response that differs where it shouldn't is a broken access control finding.

## 4. Which findings block a release

Same rules as `security/vulnerability-policy.md`, mapped to ZAP risk levels.

| ZAP risk | Gate |
|---|---|
| High | Blocks |
| Medium | Blocks if it's on an exposed path (reachable through the ALB). Otherwise a tracked ticket, 90 days |
| Low, Informational | Tracked, doesn't block |

The PR baseline today is stricter than this: it fails on any WARN. That works while the app is small and the result is clean.

DAST false positives are common. Each one is handled with a ZAP rules file (`rules.tsv`): the rule ID, `IGNORE` or `WARN`, and a comment with the reason and an owner. The file is reviewed in a PR like code. A blocking finding that is real but can't be fixed yet goes through the policy's exception process (evidence, owner, approver, expiry).

## 5. How security testing is kept away from production

1. Target allowlist. ZAP is only ever pointed at the CI hostname `app` or the staging hostname. The production hostname is not in any scan config.
2. No production credentials. The `dast` job runs with `contents: read` only and no `id-token` permission. It cannot get an AWS token at all.
3. The production deploy role is reachable only from the GitHub Environment `production`, which needs a required reviewer. Only the deploy job uses it. A staging token can't assume it, because the OIDC `sub` claim doesn't match.
4. Staging holds no production data, so an active scan that writes or deletes records damages nothing real.
5. Active scans are rate-limited (ZAP thread count and delay per request) so they don't take staging down for other users.
6. Staging has the same WAF as prod. If it blocks the scanner, the scanner's IP gets a rule in count mode, so the app behind the WAF still gets tested. Prod WAF rules stay in block mode.
7. Only test what we own. This app and these accounts are ours. No third-party URL goes into a scan.

## OWASP Top 10 risks for this app

### A01 Broken Access Control

`/api/orders/:id` is a textbook IDOR shape: change the number, get someone else's order.

- Detect: the authenticated vs unauthenticated comparison in section 3, plus a test with user B requesting user A's order IDs. Both run against staging in the nightly scan.
- Mitigate: object-level authorization on every lookup (the order must belong to the caller), deny by default, and a unit test that asserts the 403.

### A03 Injection

The id comes straight from the URL. Once the app talks to the database, that is the injection point.

- Detect early: Semgrep with `p/owasp-top-ten` and `p/nodejs` in the `sast` job flags string-built queries before merge.
- Prove it: ZAP active scan in staging sends real SQL injection payloads. A hit there means exploitable, not theoretical.
- Mitigate: input validation already in the app (`Number.isInteger(id) && id > 0`, else 400), parameterized queries, and AWS WAF managed rules on the ALB blocking common payloads at the edge.

### A05 Security Misconfiguration

- Detect: ZAP baseline header checks on every PR. This is where the 2 real findings above came from. Checkov on Terraform and the Dockerfile in the `iac` job. Trivy image misconfig scanning in `container-scan`.
- Mitigate: secure headers set once in middleware, `x-powered-by` off, a JSON 404 instead of framework default pages, and infra defaults fixed in Terraform rather than in the console.

### A06 Vulnerable and Outdated Components

- Detect: Trivy on the lockfile (`sca` job) and on the built image (`container-scan`). The nightly scan catches CVEs published after the image was built.
- Mitigate: block per the vulnerability policy, Dependabot bump PRs, and rebuild and redeploy rather than patching running containers.

## Not built yet

1. The nightly full active scan against staging, and the API scan seeded from an OpenAPI spec.
2. Authenticated scanning, because the app has no auth to test.
3. The `rules.tsv` file. The baseline is clean today, so there is nothing to tune yet.
4. Staging itself. The Terraform supports it (`environment = "staging"`), but nothing is applied, so the nightly scan has no target yet.
