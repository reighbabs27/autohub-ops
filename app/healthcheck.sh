#!/bin/bash
# AUTOMATION 2 (every 5 min, systemd timer): is AutoHub answering, locally AND through CloudFront/HTTPS?
# Publishes AutoHub/HealthCheckOK (1/0) and AutoHub/HealthCheckLatencyMs; logs a timestamped line.
source /opt/autohub/ops/autohub.conf
export AWS_DEFAULT_REGION="$REGION"
LOG=/var/log/autohub/healthcheck.log

check() { curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 "$1" || true; }

read -r LCODE LTIME <<<"$(check http://127.0.0.1:3080/health)"
DOMAIN=$(aws ssm get-parameter --name "$PARAM_PREFIX/domain" --query Parameter.Value --output text 2>/dev/null || true)
if [ -n "$DOMAIN" ] && [[ "$DOMAIN" == https://* ]]; then
  read -r PCODE PTIME <<<"$(check "$DOMAIN/health")"
else
  PCODE=$LCODE; PTIME=$LTIME
fi
LCODE=${LCODE:-000}; PCODE=${PCODE:-000}; PTIME=${PTIME:-15}

OK=0
[ "$LCODE" = "200" ] && [ "$PCODE" = "200" ] && OK=1
MS=$(awk -v t="$PTIME" 'BEGIN{printf "%d", t*1000}')

aws cloudwatch put-metric-data --namespace AutoHub --metric-data \
  "[{\"MetricName\":\"HealthCheckOK\",\"Value\":$OK,\"Unit\":\"Count\"},{\"MetricName\":\"HealthCheckLatencyMs\",\"Value\":$MS,\"Unit\":\"Milliseconds\"}]"

echo "$(date -Is) health ok=$OK local_http=$LCODE public_http=$PCODE latency_ms=$MS" >> "$LOG"

# Request log runs right after each health check (see request-log.sh)
/opt/autohub/ops/request-log.sh || true
