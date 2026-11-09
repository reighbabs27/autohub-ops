#!/bin/bash
# AUTOMATION 1 (every 6 h, systemd timer): dump the LibreChat MongoDB database to S3.
# S3 lifecycle keeps backups 8 days (brief: at least 7). Publishes AutoHub/BackupSucceeded = 1 or 0.
set -uo pipefail
source /opt/autohub/ops/autohub.conf
export AWS_DEFAULT_REGION="$REGION"
LOG=/var/log/autohub/backup.log
TS=$(date -u +%Y%m%dT%H%M%SZ)
FILE=/var/tmp/LibreChat-$TS.archive.gz
KEY="backups/mongo/LibreChat-$TS.archive.gz"
RESULT=0

finish() {
  aws cloudwatch put-metric-data --namespace AutoHub --metric-name BackupSucceeded --value "$RESULT" --unit Count
  rm -f "$FILE"
}
trap finish EXIT

if docker exec chat-mongodb mongodump --db LibreChat --archive --gzip > "$FILE" 2>>"$LOG" \
   && [ -s "$FILE" ] \
   && aws s3 cp "$FILE" "s3://$BUCKET/$KEY" --only-show-errors; then
  RESULT=1
  echo "$(date -Is) backup OK s3://$BUCKET/$KEY size=$(stat -c %s "$FILE")B" | tee -a "$LOG"
else
  echo "$(date -Is) backup FAILED for $KEY" | tee -a "$LOG"
  exit 1
fi
