#!/bin/bash
# Build AutoHub from LibreChat + our config, reading every secret from Parameter Store at runtime,
# and every piece of dealership content from S3. Safe to re-run (redeploy = run this again).
set -euo pipefail
source /opt/autohub/ops/autohub.conf
export AWS_DEFAULT_REGION="$REGION"
exec 9>/var/lock/autohub-start.lock; flock 9

APP=/opt/autohub/LibreChat
OPS=/opt/autohub/ops
LOG=/var/log/autohub/deploy.log
mkdir -p /var/log/autohub
log() { echo "$(date -Is) [deploy] $*" | tee -a "$LOG"; }
p()   { aws ssm get-parameter --name "$PARAM_PREFIX/$1" --with-decryption --query Parameter.Value --output text; }
popt(){ p "$1" 2>/dev/null || echo "$2"; }

if [ ! -d "$APP/.git" ]; then
  log "cloning LibreChat (MIT licence, https://github.com/LibreChat-AI/LibreChat)"
  git clone --depth 1 https://github.com/LibreChat-AI/LibreChat.git "$APP"
fi
cd "$APP"
BUILD=$(git rev-parse --short HEAD)

log "syncing dealership content from s3://$BUCKET/content/"
mkdir -p /opt/autohub/content
aws s3 sync "s3://$BUCKET/content/" /opt/autohub/content/ --delete

# ---- .env built from the example + Parameter Store; never committed anywhere ----
DOMAIN=$(popt domain "http://localhost:3080")
MODEL=$(popt gemini_model "gemini-2.5-flash")
cp .env.example .env.new
setenv() { grep -v "^$1=" .env.new > .env.tmp || true; printf '%s=%s\n' "$1" "$2" >> .env.tmp; mv .env.tmp .env.new; }
setenv HOST 0.0.0.0
setenv PORT 3080
setenv UID 1000
setenv GID 1000
setenv DOMAIN_CLIENT "$DOMAIN"
setenv DOMAIN_SERVER "$DOMAIN"
setenv APP_TITLE "AutoHub Assistant"
setenv CUSTOM_FOOTER "AutoHub Assistant · build $BUILD · demo data only, all vehicles and prices are invented · based on LibreChat (MIT)"
setenv ENDPOINTS google
setenv GOOGLE_KEY "$(p gemini_api_key)"
setenv GOOGLE_MODELS "$MODEL"
setenv CREDS_KEY "$(p creds_key)"
setenv CREDS_IV "$(p creds_iv)"
setenv JWT_SECRET "$(p jwt_secret)"
setenv JWT_REFRESH_SECRET "$(p jwt_refresh_secret)"
setenv MEILI_MASTER_KEY "$(p meili_master_key)"
setenv ALLOW_REGISTRATION "$(popt allow_registration true)"
setenv ALLOW_SOCIAL_LOGIN false
setenv ALLOW_EMAIL_LOGIN true
setenv DEBUG_LOGGING true
# Owned by uid 1000: the LibreChat container runs as 1000 and must be able to read it (incident INC-01).
install -m 600 -o 1000 -g 1000 .env.new .env && rm -f .env.new

# ---- librechat.yaml: our branding + domain prompt + content pulled from S3 ----
CFG_VERSION=$(grep -m1 -E '^version:' librechat.example.yaml | awk '{print $2}' || true)
python3 - "$OPS/librechat.template.yaml" librechat.yaml "${CFG_VERSION:-1.2.1}" "$MODEL" /opt/autohub/content <<'PY'
import sys, pathlib
tpl, out, version, model, content_dir = sys.argv[1:6]
text = pathlib.Path(tpl).read_text()
docs = []
for f in sorted(pathlib.Path(content_dir).glob("*.md")):
    docs.append(f.read_text().rstrip())
content = "\n\n".join(docs)
indented = "\n".join(("          " + line) if line.strip() else "" for line in content.splitlines())
text = text.replace("__VERSION__", version).replace("__MODEL__", model).replace("__CONTENT__", indented)
pathlib.Path(out).write_text(text)
PY

# ---- compose override: mount config + logo, ship MongoDB logs to CloudWatch ----
mkdir -p branding
cp "$OPS/branding/autohub.svg" branding/autohub.svg
cat > docker-compose.override.yml <<EOF
services:
  api:
    volumes:
      - type: bind
        source: ./librechat.yaml
        target: /app/librechat.yaml
      - ./branding/autohub.svg:/app/client/dist/assets/autohub.svg:ro
      - ./branding/autohub.svg:/app/client/dist/assets/logo.svg:ro
    depends_on: !override
      - mongodb
      - meilisearch
  rag_api:
    profiles: ["rag-disabled"]
  vectordb:
    profiles: ["rag-disabled"]
  admin-panel:
    profiles: ["admin-disabled"]
  mongodb:
    logging:
      driver: awslogs
      options:
        awslogs-region: $REGION
        awslogs-group: /autohub/mongodb
        awslogs-create-group: "true"
EOF

# Pre-create Meilisearch's data dir as uid 1000, or Docker creates it as root and search crash-loops.
MEILI_DIR=$(grep -o "meili_data_v[0-9.]*" docker-compose.yml | head -1)
mkdir -p logs images uploads data-node "${MEILI_DIR:-meili_data}"
chown -R 1000:1000 logs images uploads data-node "${MEILI_DIR:-meili_data}"

log "starting containers (build $BUILD, model $MODEL, domain $DOMAIN)"
docker compose up -d --remove-orphans
docker compose restart api >/dev/null 2>&1 || true
log "deployed build $BUILD"
