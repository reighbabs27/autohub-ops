# Presentation script and recording guide — AutoHub Assistant

Reighfer Joshua V. Bondoc · BSIT-4A · 19-1290-764 · SAM 10 FINAL PROJECT
Target length **6–7 minutes** (the brief allows 5–8). Speak in your own words; the "Say" column is a guide, not something to read word for word.

## 1. Before you record (10 minutes)

**Tools.** Any screen recorder with your microphone:
- Windows Game Bar: `Win+Alt+R` to start and stop.
- OBS Studio (free): Display Capture plus Mic, 1080p, output MP4.
- Loom (free, 5 min limit on the free plan, so OBS or Game Bar is safer).

**Open these tabs in this order** (so you only click from left to right):
1. The website: `https://reighbabs27.github.io/autohub-ops/` (or `docs/index.html` opened locally if Pages is not live yet)
2. AutoHub: `https://dd56jth94yne6.cloudfront.net`, signed in, on a **new chat**
3. CloudWatch → Dashboards → `autohub-operations`, time range **12h**
4. CloudWatch → Alarms → All alarms
5. Gmail, with the "ALARM: autohub-assistant-down" email from 9 Nov **already open** (nothing else visible)
6. CloudShell, already in the `autohub-ops` folder (`cd ~/autohub-ops`)
7. S3 → `autohub-content-…` → `backups/mongo/`

**Never show on screen:**
- Parameter Store **values** (the list of names is fine, never click "Show decrypted value")
- Google AI Studio API keys, the `.env` file, or any `export`/`cat` of secrets
- Your Gmail inbox list, the AWS account menu, or passwords

**Checklist:**
- [ ] Health check is green: in CloudShell run `./ops.sh status`, and it should say `ok=1`
- [ ] Ask one question in AutoHub to warm it up (the first answer can be slow)
- [ ] Notifications off (Windows Focus assist / Do not disturb)
- [ ] Browser zoom 110–125% so text is readable on video
- [ ] Do a 10-second test recording and listen to the sound

## 2. The script

| Time | Show on screen | Say (in your own words) |
|---|---|---|
| 0:00–0:30 | Website home page | "Good day, I'm Reighfer Joshua V. Bondoc of BSIT-4A, and this is my SAM 10 final project, AutoHub Assistant: a help desk for a made-up used-car dealership. I took LibreChat, an open-source chat app, reskinned it, deployed it on AWS, and ran it like a real service: monitoring, backups, security, automation and incidents. All data is invented." |
| 0:30–1:30 | AutoHub tab: ask **"Which SUVs do you have under 1,000,000 pesos?"**, then **"I earn 25,000 pesos a month. Will I be approved for a loan on the Fortuner?"** | "This is the reskin: own name and logo, and the footer shows the build and a demo-data notice. The answer comes only from our inventory in S3. AH-1027 and AH-1031 are the only two SUVs under a million. When I ask about a loan, it refuses to decide. That is a rule in the system prompt, because the system must not make decisions about people." |
| 1:30–2:30 | Website → **Infrastructure** diagram | "Walk the numbers one to seven: CloudFront for HTTPS, one EC2 t3.small running LibreChat, MongoDB and search in Docker, secrets from Parameter Store, content from S3, and the Gemini model outside AWS. Only CloudFront can reach port 3080 and there is no SSH. I administer it through Systems Manager." |
| 2:30–3:30 | CloudWatch dashboard → Alarms list → the Gmail ALARM email | "The dashboard shows requests, errors, response time, CPU, disk and memory, health and backups. Seven alarms email me. To prove it, I stopped the app at 01:07 UTC. The alarm fired at 01:16 and this email arrived. That is nine minutes to detect, and I fixed it four minutes forty seconds after the alarm. It went back to OK at 01:26." |
| 3:30–4:30 | CloudShell: `./ops.sh status`, then the S3 `backups/mongo/` tab, then website → **Monitoring · Backup · Security** → Backup | "Two automations run on systemd timers: a health check every five minutes and a database backup every six hours. Here are the scheduled backups at 18:00 and midnight. I restored the newest backup into a throw-away database: 74 documents, the counts matched, in 32 seconds. RPO is six hours. RTO is about a minute for the data and about twenty minutes for the whole server." |
| 4:30–5:30 | Website → **Automation & incident** (INC-01, then the runbook) | "The fault: after the first deploy the site showed plain LibreChat. The file on the server was right, but inside the container the settings were empty. Root cause: my deploy script wrote `.env` as root with mode 600, and the app runs as user 1000, so it could not read it. The same bug made the search service crash-loop. The fix is in the deploy script, so every rebuild gets it. This is the runbook for replacing the API key, which I wrote after two key incidents." |
| 5:30–6:15 | Website → **Results**, then **Well-Architected** | "Before and after: answer quality went from 0 out of 30 to 29 out of 30, or 97 percent, on the same 30 labelled questions, scored by the same script, now on gemini-3.1-flash-lite. Health checks passed 107 of 110 times, and the only failures were my planned outage. Well-Architected: cost and operations are good, reliability is adequate because it is one instance by choice. The first gap I would fix is least-privilege console access." |
| 6:15–6:45 | Website → **Next steps**, then the system card limitations | "Next I would add an alarm on failed answers, because the health check missed the key incident: the site was up but the model was failing. Limitations: one server, free-tier rate limits, and customers must confirm prices with staff. Thank you." |

If you run short, cut the CloudShell part (show the S3 backups only). If you run long, shorten the infrastructure walk-through.

## 3. After recording

1. Trim the start and end (Windows Photos → Video editor, or Clipchamp). Keep it between 5 and 8 minutes.
2. Upload to YouTube with visibility **Unlisted**, title "AutoHub Assistant — SAM 10 Final Project — Bondoc".
3. Copy the video ID, the part after `watch?v=` (for `https://www.youtube.com/watch?v=abc123XYZ` the ID is `abc123XYZ`).
4. In `site/pages/index.html`, replace `VIDEO_ID` with that ID and delete the grey note paragraph under the video.
5. Run `python3 site/build.py`, then `git add -A && git commit -m "Add presentation video" && git push`.
6. Open the website and check the video plays.

## 4. Screenshots only you can take

This one is still shown as "Screenshot to add" boxes on the website. Save them with exactly these names in `docs/img/`, then rebuild and push:

| File | What to capture |
|---|---|
| `e12-mfa.png` | Your sign-in's MFA page (for example Google account → Security → 2-Step Verification "On"). Hide phone numbers. If you cannot show MFA, delete that figure from `site/pages/operations.html`, because the text already explains the federated sign-in. |
