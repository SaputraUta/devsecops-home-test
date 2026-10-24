# DAST and OWASP Top 10

Tool: OWASP ZAP. I only scan this app, in CI or in the staging account.

## What runs in the pipeline today

The `dast` job runs on every PR and every push to main. It starts the image that was just built on a private Docker network on the CI runner, with a dummy `DB_PASSWORD`, and runs a ZAP baseline scan against it. The report is uploaded as the `dast-report` artifact. Any warning fails the job, and nothing gets published if it fails.

The first run found 2 warnings: `X-Content-Type-Options` missing and an incomplete Content-Security-Policy. I added both headers in `app/src/app.js` and a JSON 404 page (Express's default 404 was overriding the CSP). The scan now passes: 61 PASS, 0 WARN.

## 1. Safe test environment

- On every PR: the app runs only inside the CI runner, on a Docker network shared with ZAP and nothing else. No real database, no real secrets. The runner is thrown away after the job.
- Nightly (planned): the full scan runs against staging, a separate AWS account with no production data and no production credentials. It runs the same image that passed the PR checks.

## 2. Checks that run automatically

| Scan | When | What it does |
|---|---|---|
| Baseline | Every PR and push to main | Crawls the app and checks responses: security headers, cookies, error pages, information leaks. Sends no attacks. About 1 minute |
| Full scan (planned) | Nightly, against staging | Sends real attack payloads: SQL injection, XSS, path traversal, command injection. 20+ minutes |
| API scan (planned) | Nightly, once there's an OpenAPI spec | Same as the full scan, but tests every endpoint listed in the spec instead of only what the crawler finds |

The baseline is fast and harmless, so it runs on every PR. The full scan is slow and sends attacks, so it runs at night against staging only.

## 3. Authentication

The app has no login today. When it does:

- A dedicated test user exists in staging only, with minimal permissions.
- Its password is stored as a GitHub Environment secret, not in the repo.
- Before the scan, the pipeline logs in and gives ZAP the token, so every request is sent as that user.
- ZAP is told how to recognise a logged-out response, so the scan fails instead of quietly testing the login page.
- I run the scan twice, as a logged-out visitor and as the test user, plus a second user. If user B can see user A's data, that's broken access control.

## 4. What blocks a release

| ZAP risk | Action |
|---|---|
| High | Blocks |
| Medium | Blocks if it's on a public path, otherwise tracked with a 90-day fix |
| Low, Informational | Tracked |

The PR baseline is stricter for now and fails on any warning, because the app is small and clean. False positives go into a ZAP rules file with the reason, reviewed in a PR. A real finding that can't be fixed yet goes through the exception process in `security/vulnerability-policy.md`.

## 5. Keeping production safe

- ZAP is only pointed at the CI container or the staging hostname. The production URL isn't in any scan config.
- The DAST job has no AWS credentials at all. Only the deploy jobs can get them, and production needs an approval.
- Staging has no real data, so an active scan that writes junk does no damage.
- Active scans are rate-limited so they don't take staging down.
- I only scan systems I own or have written permission to test.

## OWASP Top 10 risks for this app

| Risk | Why it applies | How I detect it | How I mitigate it |
|---|---|---|---|
| A01 Broken Access Control | `/api/orders/:id`: change the number, maybe get someone else's order | Authenticated scans with two users in staging | Check that the order belongs to the caller on every request, deny by default |
| A03 Injection | The id comes from the URL and will end up in a database query | Semgrep in the `sast` job catches unsafe query code. The ZAP full scan proves if it's exploitable | Input validation (the app already rejects non-integer ids), parameterised queries, AWS WAF SQL injection rules |
| A05 Security Misconfiguration | Missing headers, framework banners, bad infra defaults | ZAP baseline (found 2 real issues), Checkov on Terraform and the Dockerfile, Trivy image config scan | Headers set in one middleware, `x-powered-by` off, infra settings fixed in Terraform |
| A06 Vulnerable Components | Old libraries and base image packages | Trivy on the lockfile and the image, plus the nightly rescan | Pipeline blocks per policy, Dependabot bump PRs |

## Not built yet

- The nightly full scan and API scan, because staging isn't deployed.
- Authenticated scanning, because the app has no login.
- The ZAP rules file, because there are no false positives to tune yet.
