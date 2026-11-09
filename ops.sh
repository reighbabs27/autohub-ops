#!/bin/bash
# Day-to-day operations from CloudShell. Every command's output is good evidence for the website.
#   ./ops.sh status              what is running, versions, disk, last automation runs
#   ./ops.sh redeploy            push app/ and content/ to S3 and restart AutoHub with them
#   ./ops.sh backup              run a MongoDB backup now
#   ./ops.sh restore-verify      restore the latest backup into a throw-away container and compare counts
#   ./ops.sh restore-live [key]  REAL restore into the running database (takes a safety copy first)
#   ./ops.sh close-registration  stop new sign-ups after you created your account
#   ./ops.sh open-registration
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
source ./lib-remote.sh

case "${1:-}" in
  status)
    run_remote "cd /opt/autohub/LibreChat && echo BUILD \$(git rev-parse --short HEAD) && docker compose ps --format 'table {{.Name}}\t{{.Status}}' && df -h / && free -m && echo '--- last health checks' && tail -3 /var/log/autohub/healthcheck.log && echo '--- last backups' && tail -3 /var/log/autohub/backup.log && systemctl list-timers 'autohub-*' --no-pager" ;;
  redeploy)
    aws s3 sync ./app "s3://$BUCKET/app/" --delete
    aws s3 sync ./content "s3://$BUCKET/content/" --delete
    run_remote "aws s3 sync s3://$BUCKET/app/ /opt/autohub/ops/ --region $AWS_REGION && chmod +x /opt/autohub/ops/*.sh && cp /opt/autohub/ops/systemd/* /etc/systemd/system/ && systemctl daemon-reload && /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/autohub/ops/cwagent.json && /opt/autohub/ops/start-autohub.sh" ;;
  backup)          run_remote "/opt/autohub/ops/backup-mongo.sh" ;;
  restore-verify)  run_remote "/opt/autohub/ops/restore-test.sh verify" ;;
  restore-live)    run_remote "/opt/autohub/ops/restore-test.sh live ${2:-}" ;;
  close-registration)
    aws ssm put-parameter --name "$PARAM_PREFIX/allow_registration" --type String --value false --overwrite >/dev/null
    run_remote "/opt/autohub/ops/start-autohub.sh" ;;
  open-registration)
    aws ssm put-parameter --name "$PARAM_PREFIX/allow_registration" --type String --value true --overwrite >/dev/null
    run_remote "/opt/autohub/ops/start-autohub.sh" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
