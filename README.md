# AutoHub Assistant — operations repository (SAM10)

AutoHub Assistant is a help desk for a **fictional** pre-owned car dealership. It is a reskin of
[LibreChat](https://github.com/LibreChat-AI/LibreChat) (MIT licence, author Danny Avila and contributors),
connected to Google Gemini (free tier). All vehicles, prices, people and contact details are invented.

**Live:** https://dd56jth94yne6.cloudfront.net · region **ap-southeast-2 (Sydney)** · sign-ups closed.
What was deployed, measured and fixed is in [`EVIDENCE.md`](EVIDENCE.md).

## Architecture

```
Customer browser ──HTTPS──► CloudFront (free TLS, no caching)
                               │ HTTP :3080 (security group allows CloudFront only)
                               ▼
                 EC2 t3.small (2 GB + 2 GB swap), Amazon Linux 2023, encrypted 30 GB gp3, Elastic IP
                 Docker: LibreChat api · MongoDB · Meilisearch  (RAG + admin panel disabled to fit 2 GB)
                   │ at start: reads secrets from SSM Parameter Store (SecureString)
                   │ at start: reads dealership content from S3 content/  ──► system prompt
                   │ every 6 h: mongodump ──► S3 backups/ (versioned, kept 8 days)
                   │ every 5 min: health check ──► CloudWatch metric
                   ▼
                 Gemini API (Google, outside AWS) — receives only invented demo data
CloudWatch: agent metrics (mem, disk) + log groups (14-day retention) + 7 alarms ──► SNS ──► email
CloudTrail: account activity · AWS Budgets: cost alert
```

## Files

| File | What it does |
|---|---|
| `config.env` | Settings — **edit `ALERT_EMAIL` first** |
| `01-foundation.sh` | Budget, SNS, S3 buckets, CloudTrail, secrets, IAM role, security group, upload |
| `02-launch-ec2.sh` | EC2 instance + Elastic IP |
| `03-cloudfront.sh` | HTTPS via CloudFront, sets the public URL |
| `04-monitoring.sh` | Log retention, 7 alarms, dashboard |
| `ops.sh` | `status`, `redeploy`, `backup`, `restore-verify`, `restore-live`, `close-registration` |
| `app/request-log.sh` | One JSON line per answered question to CloudWatch `/autohub/app` (runs after each health check) |
| `app/eval.py` | 30-question quality evaluation |
| `docs/`, `site/` | Project website (GitHub Pages) and its source |
| `PRESENTATION.md` | Script for the recorded presentation |
| `app/` | Runs on the server: bootstrap, start script, LibreChat config template, automations, CloudWatch agent config, logo |
| `content/` | Dealership info and inventory (invented) — uploaded to S3, read by the app |

No file in this repository contains a key or password. Every secret lives in Parameter Store under `/autohub/`.

## Run order (about 60–90 minutes, mostly waiting)

**0. In the AWS console first (5 min)**
1. Do not use the root user. IAM → Users → create your own user with console access → attach
   `AdministratorAccess` → sign in as that user.
2. Enable **MFA** on that user (and on root). Screenshot: evidence E-12.
3. Get a Gemini API key from Google AI Studio. Keep it in AI Studio — never paste it into chat, code or git.

**1. Open CloudShell** (the `>_` icon in the console top bar, region **Asia Pacific (Sydney)**).
Actions → Upload file → `autohub-ops.zip`, then:

```bash
unzip -o autohub-ops.zip && cd autohub-ops && chmod +x *.sh
nano config.env          # set ALERT_EMAIL (and GEMINI_MODEL if AI Studio shows a different name)
./01-foundation.sh       # asks for the Gemini key with hidden input
```
Confirm the **AWS Notification** email (click the link), or no alarm will reach you.

```bash
./02-launch-ec2.sh
./03-cloudfront.sh       # waits for the server, prints https://xxxx.cloudfront.net
```
Wait 10–15 minutes, open the URL, **Sign up**, create your account, ask a question. Then:

```bash
./ops.sh close-registration
./04-monitoring.sh
./ops.sh status          # screenshot this: containers, disk, timers
```

## Evidence you can produce tonight

| Brief item | How |
|---|---|
| E-02 URL, HTTPS | the CloudFront URL |
| E-06 dashboard | CloudWatch → Dashboards → `autohub-operations` (after ~1 h of data) |
| E-07 alarms | CloudWatch → Alarms (7 alarms) |
| E-08 real alert | see *Prove an alert arrives* below |
| E-09 request log | CloudWatch → Log groups → `/autohub/app` (LibreChat debug log) and `/autohub/automation` |
| E-10 backups | `./ops.sh backup`, then `aws s3 ls s3://<bucket>/backups/mongo/` |
| E-11 restore | see *Restore test* below |
| E-13 secrets | Systems Manager → Parameter Store → `/autohub/*` (values hidden) |
| E-14 automations | `./ops.sh status` timers + `/autohub/automation` log lines with timestamps |

### Prove an alert arrives (real, not simulated)
```bash
# Stop the app for ~12 minutes; the health check fails, autohub-assistant-down fires and emails you.
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/autohub/LibreChat && docker compose stop api"]'
# ...wait for the email, screenshot it with date/time visible, then bring it back:
./ops.sh redeploy
```
(`source config.env` first so `$INSTANCE_ID` is set.) The OK email afterwards is a bonus screenshot.

### Restore test
1. In AutoHub, start a chat titled **RESTORE MARKER** and ask anything.
2. `./ops.sh backup` — note the S3 key it prints.
3. Delete the RESTORE MARKER chat in the UI.
4. `./ops.sh restore-verify` — shows live vs restored counts (the restored copy has one more conversation).
5. `./ops.sh restore-live` — restores into the real database (a safety copy is taken first).
6. Log in: RESTORE MARKER is back. Screenshot + the command output. The script prints seconds taken — use it for RTO.

RPO: up to 6 hours of chats (backup interval). RTO: measure it with step 5, plus ~15 minutes if the whole
server had to be rebuilt with `02-launch-ec2.sh`.

## Replace the Gemini key (runbook: docs/automation.html#runbook)
Create the new key in AI Studio first and keep the old one until this succeeds. In CloudShell:
```bash
cd ~/autohub-ops && source ./config.env
read -rsp 'Paste the NEW Gemini key ONCE, then Enter: ' K; echo; K=$(echo -n "$K" | tr -d '[:space:]')
C=$(curl -s -o /dev/null -w '%{http_code}' -H "x-goog-api-key: $K" https://generativelanguage.googleapis.com/v1beta/models)
[ "$C" = 200 ] && aws ssm put-parameter --name /autohub/gemini_api_key --type SecureString --value "$K" --overwrite >/dev/null \
  && echo "KEY SAVED" && ./ops.sh redeploy || echo "NOT SAVED (HTTP $C)"; unset K
```
Then delete the old key in AI Studio. Change the model with
`aws ssm put-parameter --name /autohub/gemini_model --type String --value <model> --overwrite && ./ops.sh redeploy`.

## Quality evaluation
`python3 /opt/autohub/ops/eval.py [model]` on the instance (or `run_remote` from CloudShell) scores 30 labelled questions.
It uses the same free-tier quota as the live app, so run it rarely, or against another model (INC-05).

## Website
The project website is in `docs/` (GitHub Pages: Settings → Pages → Deploy from branch → `main` / `docs`).
Edit pages in `site/pages/*.html`, then `python3 site/build.py`.

## Honest limitations of this setup
- CloudFront → EC2 is plain HTTP inside AWS's network; the security group only admits CloudFront, but
  any CloudFront distribution (not just ours) could reach port 3080. Fix: a secret origin header.
- One instance, one AZ: if it dies, the site is down until rebuilt (no high availability, by choice — cost).
- The health check proves the site responds, not that answers are correct.
- Gemini free tier: low rate limits (429 errors under load) and Google may use free-tier prompts to improve
  its products — which is why only invented data goes in.

## Tear down at the end of term
CloudFront (disable, then delete) · terminate the instance · release the Elastic IP · delete the security group,
alarms, dashboard, log groups, trail, SNS topic, budget · empty and delete both buckets · delete `/autohub/*`
parameters · delete the Gemini API key in AI Studio.

## Contribution log
| Date | Who | What |
|---|---|---|
| 2026-11-08 | Reighfer Joshua Bondoc (solo) | AWS setup scripts, deployment |

AI assistance: Claude (Anthropic) drafted these scripts; I ran, checked and corrected them against the AWS
console and command output. (Edit this to describe exactly what you verified.)
