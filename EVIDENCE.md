# AutoHub Assistant — deployment evidence and incident log

All times UTC (Philippines/Shanghai = UTC+8). Account 482882341880, region ap-southeast-2 (Sydney).
Screenshot each item for the website; the command output below is what you should see.

## Deployed resources (2026-11-08)

| Resource | Value |
|---|---|
| Public URL (HTTPS, CloudFront) | https://dd56jth94yne6.cloudfront.net (distribution E3SG8RUFGFD2RI) |
| EC2 instance | i-0e4895bb0aab93848, t3.small, Amazon Linux 2023, encrypted 30 GB gp3, IMDSv2 required |
| Origin | ec2-15-134-40-92.ap-southeast-2.compute.amazonaws.com:3080 (Elastic IP), security group admits CloudFront prefix list only, no SSH |
| Content + backups bucket | autohub-content-482882341880-ap-southeast-2 (private, SSE, versioned, backups expire after 8 days) |
| Audit | CloudTrail `autohub-trail` → autohub-trail-482882341880-ap-southeast-2 (90-day expiry) |
| Secrets | Parameter Store `/autohub/*` — gemini_api_key, creds_key, creds_iv, jwt_secret, jwt_refresh_secret, meili_master_key (SecureString) |
| Model | Google `gemini-3.1-flash-lite` (free tier); was `gemini-3.5-flash` until INC-05 |
| Alerts | SNS `autohub-alerts` → rjoshuapogi27@gmail.com (confirmed 2026-11-09) · Budget `autohub-monthly` $10 |
| Monitoring | 7 CloudWatch alarms, dashboard `autohub-operations`, log groups `/autohub/{app,mongodb,automation,deploy}` at 14 days |
| LibreChat build | f4154b6 (shown in the footer) |

## Automations (ran unattended overnight)

| Automation | Schedule | Evidence |
|---|---|---|
| Health check (local + through CloudFront) | every 5 min (systemd timer) | `2026-11-09T00:25:03 health ok=1 local_http=200 public_http=200 latency_ms=714` … every 5 min |
| MongoDB backup to S3 | 00/06/12/18 UTC (systemd timer) | `2026-11-09T00:00:04 backup OK …/LibreChat-20261109T000000Z.archive.gz size=11030B` |

## Restore test (WS-C)

`./ops.sh restore-verify` at 2026-11-09T00:46, using backup `LibreChat-20261109T004552Z.archive.gz`:

```
74 document(s) restored successfully. 0 document(s) failed to restore.
LIVE database:   users=1 conversations=2 messages=6
RESTORED copy:   users=1 conversations=2 messages=6
finished in 32 s
```
- **RPO:** ≤ 6 h (backup interval). **RTO (data):** 32 s measured; ~15 min more if the instance itself must be rebuilt with `02-launch-ec2.sh`.

## Functional tests (2026-11-09 ~01:06)

1. "Which SUVs do you have under 1,000,000 pesos?" → table with exactly AH-1027 Honda BR-V (685,000) and
   AH-1031 Montero Sport (898,000), the only two available SUVs under 1 M in `content/02-inventory.md`. ✔
2. "I earn 25,000 pesos a month. Will I be approved for a loan on the Fortuner?" → "I cannot approve, deny, or
   estimate your loan eligibility…", quotes AH-1024 at 1,385,000 and refers to staff. Guardrail holds. ✔

## Incident log

### INC-01 — App ignored its configuration (2026-11-08 ~16:18)
- **Symptom:** site showed "LibreChat" instead of "AutoHub Assistant", no sign-up link, `/api/config` reported
  `serverDomain: http://localhost:3080`, `registrationEnabled: false`.
- **Investigation:** `.env` on the host had the right values; `docker exec LibreChat printenv APP_TITLE` was empty.
  The compose file bind-mounts `./.env` into `/app/.env`; the container runs as uid 1000, but our deploy script
  wrote `.env` as root with mode 600 → the app could not read it and silently fell back to defaults.
- **Fix:** `install -m 600 -o 1000 -g 1000 .env.new .env` in `start-autohub.sh`, redeploy.
- **Verified:** `/api/config` → `"appTitle":"AutoHub Assistant"`, `serverDomain` = CloudFront URL, sign-up page loads.
- **Same root cause, second symptom:** Meilisearch crash-looped with `Permission denied (os error 13)` because
  Docker created `meili_data_v1.35.1` as root. Fix: pre-create it as uid 1000. Verified: container `Up`, listening on 7700.
- **Lesson:** containers that run as non-root need every bind-mounted path owned by that uid; check `docker logs`
  and `printenv` inside the container, not just the file on the host.

### INC-02 — Assistant could not answer: invalid API key, then retired model (2026-11-09 00:40–01:06)
- **Symptom 1:** chat showed `400 API key not valid`. Stored key length was 4 characters (a mistyped value at the
  hidden prompt). A later attempt stored 106 characters — the key pasted twice because hidden input shows nothing.
- **Fix 1:** key prompt now strips whitespace and calls Google's `models` endpoint before saving; only HTTP 200 is stored.
  Stored key then tested HTTP 200.
- **Symptom 2:** `404 This model models/gemini-2.5-flash is no longer available to new users`.
- **Investigation:** listed models available to the key, sent a one-line `generateContent` test → `gemini-3.5-flash -> 200`.
- **Fix 2:** `/autohub/gemini_model` = `gemini-3.5-flash`, redeploy. Verified by the functional tests above.
- **Lesson:** validate a secret at the moment it is entered; pin and test the model name against the provider, since
  provider-side retirements break a deployment that has not changed.
- **Security note:** one key was pasted into a chat by mistake; it was deleted and replaced (rotation).

### INC-03 — Planned fault injection for the alarm test (2026-11-09 01:07:05)
- Stopped the LibreChat container (`docker compose stop api`) to prove monitoring catches an outage.
- Expected: health check fails at 01:10 and 01:15 → `autohub-assistant-down` → ALARM email; restart → OK email.
- Result: health check failed 01:10:04, 01:15:03, 01:20:03 (public_http=504); alarm OK→ALARM 01:16:03; recovered 01:20:45 (public health 200).
- **Time to detect 8 min 58 s; time to fix after alarm 4 min 42 s.**

### INC-04 — Key rotation broke the assistant (2026-11-09 ~01:10–01:34)
- The key pasted into a chat was the production key; deleting it (correctly) made every answer fail with 401.
- Found by the evaluation run (~01:28). New key saved through the validating prompt 01:33:48, redeployed 01:34:02.
- Prevention: runbook "Rotate / replace the Gemini API key" — save the new key before deleting the old.

### INC-05 — Evaluation exhausted the model's free daily quota (2026-11-09 01:34–01:47)
- 503 then 429 `GenerateRequestsPerDayPerProjectPerModel-FreeTier` on gemini-3.5-flash; production shares key and model.
- Fixed 01:47:17: `/autohub/gemini_model` = `gemini-3.1-flash-lite` (own quota, tested 200), redeploy; 01:48 test answer correct.
- Prevention: `eval.py MODEL` to evaluate another model; next step a separate key/project for testing.

## Request log (WS-B.4)
`app/request-log.sh` writes one JSON line per answered question (question, ok, duration_ms, model, build) to
CloudWatch `/autohub/app` stream `<instance>-requests`. Backfill 9 Nov: 4 failed answers on gemini-2.5-flash
(00:33–01:01), then successful answers on the fixed configuration (01:06 onwards).
