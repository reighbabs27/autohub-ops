#!/bin/bash
# Restore test for WS-C.
#   restore-test.sh verify       restore the newest backup into a THROW-AWAY MongoDB container, compare counts
#   restore-test.sh live [key]   restore a backup INTO the running database (safety copy taken first),
#                                then restart the app so you can log in and see the restored chats
set -euo pipefail
source /opt/autohub/ops/autohub.conf
export AWS_DEFAULT_REGION="$REGION"
MODE=${1:-verify}
KEY=${2:-}
LOG=/var/log/autohub/restore.log
say() { echo "$(date -Is) [restore-$MODE] $*" | tee -a "$LOG"; }

if [ -z "$KEY" ]; then
  KEY="backups/mongo/$(aws s3 ls "s3://$BUCKET/backups/mongo/" | sort | tail -1 | awk '{print $4}')"
fi
FILE=/var/tmp/restore.archive.gz
say "using s3://$BUCKET/$KEY"
aws s3 cp "s3://$BUCKET/$KEY" "$FILE" --only-show-errors

count() {  # count <container>
  docker exec "$1" mongosh --quiet --eval '
    const d = db.getSiblingDB("LibreChat");
    ["users","conversations","messages"].forEach(c => print(c + "=" + d.getCollection(c).countDocuments()));'
}

START=$(date +%s)
if [ "$MODE" = "verify" ]; then
  IMG=$(docker inspect chat-mongodb --format '{{.Config.Image}}')
  docker rm -f autohub-restore-test >/dev/null 2>&1 || true
  docker run -d --name autohub-restore-test "$IMG" >/dev/null
  for _ in $(seq 1 30); do docker exec autohub-restore-test mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break; sleep 2; done
  docker exec -i autohub-restore-test mongorestore --archive --gzip < "$FILE" 2>&1 | tail -2
  say "LIVE database:";      count chat-mongodb         | tee -a "$LOG"
  say "RESTORED copy:";      count autohub-restore-test | tee -a "$LOG"
  docker rm -f autohub-restore-test >/dev/null
elif [ "$MODE" = "live" ]; then
  SAFE=/var/tmp/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).archive.gz
  docker exec chat-mongodb mongodump --db LibreChat --archive --gzip > "$SAFE"
  aws s3 cp "$SAFE" "s3://$BUCKET/backups/pre-restore/$(basename "$SAFE")" --only-show-errors
  say "safety copy saved to backups/pre-restore/$(basename "$SAFE")"
  say "before:"; count chat-mongodb | tee -a "$LOG"
  docker exec -i chat-mongodb mongorestore --drop --archive --gzip < "$FILE" 2>&1 | tail -2
  (cd /opt/autohub/LibreChat && docker compose restart api >/dev/null)
  say "after:";  count chat-mongodb | tee -a "$LOG"
  rm -f "$SAFE"
else
  echo "usage: $0 verify | live [s3-key]"; exit 1
fi
rm -f "$FILE"
say "finished in $(( $(date +%s) - START )) s (use this for RTO)"
