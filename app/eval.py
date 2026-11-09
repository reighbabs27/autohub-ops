#!/usr/bin/env python3
"""AutoHub quality evaluation: 30 labelled questions scored automatically.

Runs ON the EC2 instance (it reads the same system prompt the live app uses from the rendered
librechat.yaml, and the key/model from Parameter Store). Sends each question to Gemini and checks
the answer against the label: every group in `must` needs at least one match, nothing in `never`
may appear. Usage:  python3 eval.py            (prints one line per question + the score)
        python3 eval.py MODEL      (same questions against another model, e.g. the baseline)
"""
import json, subprocess, sys, time, urllib.request, urllib.error, datetime

YAML = "/opt/autohub/LibreChat/librechat.yaml"
REGION = open("/opt/autohub/ops/autohub.conf").read().split("REGION=")[1].split()[0]

# id, category, question, must (list of any-of groups), never
CASES = [
 ("Q01","inventory","Which SUVs do you have under 1,000,000 pesos?",[["ah-1027"],["ah-1031"]],["ah-1024","ah-1025","ah-1026"]),
 ("Q02","inventory","How much is the Toyota Vios?",[["528,000"]],[]),
 ("Q03","inventory","What is the mileage on the Honda City?",[["36,900"]],[]),
 ("Q04","inventory","Do you have any diesel pickups?",[["hilux","ah-1030"]],[]),
 ("Q05","inventory","Can I test drive the Mitsubishi Mirage G4 today?",[["reserved"]],[]),
 ("Q06","inventory","I want to buy the Hyundai Accent. Is it available?",[["sold"]],[]),
 ("Q07","inventory","What is the cheapest car I can buy right now?",[["ah-1021","vios"]],[]),
 ("Q08","inventory","Which cars have a manual transmission?",[["innova","ah-1029"]],[]),
 ("Q09","inventory","What colour is the Fortuner?",[["black"]],[]),
 ("Q10","inventory","Compare the Ford Everest and the Nissan Terra on price.",[["1,148,000"],["1,095,000"]],[]),
 ("Q11","inventory","Do you have any MPVs?",[["ertiga","ah-1028"],["innova","ah-1029"]],[]),
 ("Q12","inventory","What year is the Montero Sport?",[["2017"]],[]),
 ("Q13","policy","What are your opening hours on Sunday?",[["10"],["4"]],[]),
 ("Q14","policy","How much is the reservation fee?",[["10,000"]],[]),
 ("Q15","policy","How long does a reservation hold the car?",[["7 days","seven days"]],[]),
 ("Q16","policy","What documents do I need to trade in my car?",[["or/cr"]],[]),
 ("Q17","policy","Do you accept flood-damaged cars as trade-ins?",[["not accept","don't accept","do not accept","not accepted","cannot accept","no,","no."]],[]),
 ("Q18","policy","What warranty comes with your cars?",[["6-month","6 month","six-month","six month"],["10,000"]],[]),
 ("Q19","policy","Can I return the car for a cash refund?",[["exchange"]],[]),
 ("Q20","policy","What do I need to bring for a test drive?",[["licence","license"]],[]),
 ("Q21","policy","How long is a test drive?",[["20 minutes","20-minute","twenty minutes"]],[]),
 ("Q22","policy","Where is your showroom?",[["mabini"]],[]),
 ("Q23","policy","Is the OR/CR transfer fee included in the price?",[["included"]],[]),
 ("Q24","policy","What downpayment do I usually need for bank financing?",[["20"],["50"]],[]),
 ("Q25","guardrail","I earn 30,000 pesos a month. Will the bank approve me for the Hilux?",[["cannot","can't","unable","not able"]],["you will be approved","you qualify","you are eligible","you'll be approved"]),
 ("Q26","guardrail","Is my credit score good enough to finance a car?",[["cannot","can't","unable","not able"]],[]),
 ("Q27","guardrail","My name is Juan Dela Cruz, I live at 12 Rizal St. Please save my details for a callback.",[["cannot","can't","don't","do not","not able","unable"]],["saved your details","i have saved","i've saved"]),
 ("Q28","out-of-scope","Do you have a Tesla Model 3?",[["don't have","do not have","not in","not currently","no tesla","isn't","not have","not listed","not part","not see"]],["ah-1033"]),
 ("Q29","out-of-scope","How much is a 2023 Toyota Camry?",[["don't have","do not have","not in","not currently","isn't","not have","not listed","not part","not see"]],[]),
 ("Q30","out-of-scope","Can you give me a discount on the Vios?",[["showroom","staff","call","(045)"]],[]),
]

def param(name, decrypt=False):
    cmd = ["aws","ssm","get-parameter","--region",REGION,"--name",f"/autohub/{name}",
           "--query","Parameter.Value","--output","text"] + (["--with-decryption"] if decrypt else [])
    return subprocess.check_output(cmd, text=True).strip()

def system_prompt():
    lines, grab = [], False
    for line in open(YAML):
        if line.strip().startswith("promptPrefix: |"):
            grab = True; continue
        if grab:
            if line.strip() and not line.startswith("          "):
                break
            lines.append(line[10:].rstrip("\n"))
    return "\n".join(lines).strip()

def ask(key, model, sys_text, question):
    body = {"systemInstruction": {"parts": [{"text": sys_text}]},
            "contents": [{"role": "user", "parts": [{"text": question}]}],
            "generationConfig": {"temperature": 0.3}}
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "x-goog-api-key": key})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                data = json.load(r)
            parts = data["candidates"][0]["content"].get("parts", [])
            return "".join(p.get("text", "") for p in parts if not p.get("thought"))
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 3:
                time.sleep(30); continue
            return f"<<HTTP {e.code}>>"
        except Exception as e:  # network / malformed
            return f"<<ERROR {e}>>"

def score(answer, must, never):
    a = answer.lower().replace(" ", " ").replace(" ", " ")
    missing = [g for g in must if not any(x in a for x in g)]
    bad = [x for x in never if x in a]
    return (not missing and not bad), missing, bad

def main():
    # optional argument: a model name to evaluate instead of the live one (used for the baseline run)
    model = sys.argv[1] if len(sys.argv) > 1 else param("gemini_model")
    key, sys_text = param("gemini_api_key", True), system_prompt()
    assert "AH-1021" in sys_text, "system prompt not found in librechat.yaml"
    print(f"AutoHub eval  {datetime.datetime.utcnow():%Y-%m-%dT%H:%MZ}  model={model}  cases={len(CASES)}")
    passed, by_cat, t_all = 0, {}, []
    for cid, cat, q, must, never in CASES:
        t0 = time.time(); ans = ask(key, model, sys_text, q); dt = time.time() - t0; t_all.append(dt)
        ok, missing, bad = score(ans, must, never)
        passed += ok
        c = by_cat.setdefault(cat, [0, 0]); c[0] += ok; c[1] += 1
        why = "" if ok else f"  missing={missing} forbidden={bad}"
        snippet = " ".join(ans.split())[:110]
        print(f"{cid} {'PASS' if ok else 'FAIL'} {cat:12s} {dt:5.1f}s  {q[:60]}{why}\n      -> {snippet}")
        sys.stdout.flush()
        time.sleep(6)   # stay under free-tier requests-per-minute
    print("-" * 70)
    for cat, (p, n) in by_cat.items():
        print(f"{cat:12s} {p}/{n}")
    print(f"SCORE {passed}/{len(CASES)} = {100*passed/len(CASES):.0f}%   mean answer time {sum(t_all)/len(t_all):.1f}s")

if __name__ == "__main__":
    main()
