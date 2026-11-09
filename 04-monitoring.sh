#!/bin/bash
# 04 - Log retention, 7 alarms emailing you, and the CloudWatch dashboard.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

say "Log groups with 14-day retention (not 'Never expire')"
for g in /autohub/app /autohub/mongodb /autohub/automation /autohub/deploy; do
  try aws logs create-log-group --log-group-name "$g" --tags Project=SAM10,Team=autohub
  aws logs put-retention-policy --log-group-name "$g" --retention-in-days 14
done

alarm() {  # name description namespace metric stat comparison threshold period evals datapoints missing dims...
  local name=$1 desc=$2 ns=$3 metric=$4 stat=$5 cmp=$6 thr=$7 period=$8 evals=$9 dp=${10} missing=${11}; shift 11
  local dims=()
  if [ $# -gt 0 ]; then dims=(--dimensions "$@"); fi
  aws cloudwatch put-metric-alarm --alarm-name "$name" --alarm-description "$desc" \
    --namespace "$ns" --metric-name "$metric" --statistic "$stat" \
    --comparison-operator "$cmp" --threshold "$thr" --period "$period" \
    --evaluation-periods "$evals" --datapoints-to-alarm "$dp" --treat-missing-data "$missing" \
    --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN" \
    --tags Key=Project,Value=SAM10 Key=Team,Value=autohub \
    "${dims[@]}"
  echo "   alarm: $name"
}
I="Name=InstanceId,Value=$INSTANCE_ID"

say "Alarms -> SNS -> $ALERT_EMAIL"
alarm autohub-cpu-high "CPU > 85% for 10 min: stuck process or runaway loop" \
  AWS/EC2 CPUUtilization Average GreaterThanThreshold 85 300 2 2 missing "$I"
alarm autohub-status-check-failed "EC2 status check failing: look at the instance" \
  AWS/EC2 StatusCheckFailed Maximum GreaterThanThreshold 0 60 2 2 missing "$I"
alarm autohub-memory-high "Memory > 90% for 5 min: container may be OOM-killed" \
  CWAgent mem_used_percent Average GreaterThanThreshold 90 300 1 1 missing "$I"
alarm autohub-disk-high "Root disk > 85%: chat logs/backups filling the disk. Runbook: disk-full" \
  CWAgent disk_used_percent Average GreaterThanThreshold 85 300 1 1 missing "$I"
alarm autohub-assistant-down "Health check failing for 10 min (site down, or CloudFront->EC2 path broken)" \
  AutoHub HealthCheckOK Minimum LessThanThreshold 1 300 2 2 breaching
alarm autohub-slow-response "Average health-check response > 3 s over 15 min" \
  AutoHub HealthCheckLatencyMs Average GreaterThanThreshold 3000 300 3 3 notBreaching
alarm autohub-backup-missed "No successful MongoDB backup for 7 hours (backups run every 6 h)" \
  AutoHub BackupSucceeded Sum LessThanThreshold 1 3600 7 7 breaching

say "Dashboard: autohub-operations"
DASH=$(mktemp)
cat > "$DASH" <<EOF
{"widgets":[
 {"type":"text","x":0,"y":0,"width":24,"height":3,"properties":{"markdown":"## AutoHub Assistant - operations\\nThresholds: CPU 85%/10 min and memory 90% leave headroom before the 2 GB t3.small (plus 2 GB swap) starts killing containers; disk alarms at 85% (checked every 5 min, not hourly) because chat logs and backups can fill 30 GB quickly; health check must pass through CloudFront every 5 min; answers slower than 3 s feel broken to a customer; a backup must succeed every 6 h so RPO stays under 6 h."}},
 {"type":"metric","x":0,"y":3,"width":8,"height":6,"properties":{"title":"Requests (CloudFront)","region":"us-east-1","view":"timeSeries","stat":"Sum","period":300,
   "metrics":[["AWS/CloudFront","Requests","DistributionId","$DIST_ID","Region","Global"]]}},
 {"type":"metric","x":8,"y":3,"width":8,"height":6,"properties":{"title":"Error rate % (CloudFront 4xx/5xx)","region":"us-east-1","view":"timeSeries","stat":"Average","period":300,
   "metrics":[["AWS/CloudFront","5xxErrorRate","DistributionId","$DIST_ID","Region","Global"],["AWS/CloudFront","4xxErrorRate","DistributionId","$DIST_ID","Region","Global"]]}},
 {"type":"metric","x":16,"y":3,"width":8,"height":6,"properties":{"title":"Response time ms (health check via HTTPS)","region":"$AWS_REGION","view":"timeSeries","stat":"Average","period":300,
   "metrics":[["AutoHub","HealthCheckLatencyMs"]],"annotations":{"horizontal":[{"label":"alarm 3 s","value":3000}]}}},
 {"type":"metric","x":0,"y":9,"width":8,"height":6,"properties":{"title":"CPU %","region":"$AWS_REGION","view":"timeSeries","stat":"Average","period":300,
   "metrics":[["AWS/EC2","CPUUtilization","InstanceId","$INSTANCE_ID"]],"annotations":{"horizontal":[{"label":"alarm","value":85}]}}},
 {"type":"metric","x":8,"y":9,"width":8,"height":6,"properties":{"title":"Disk used % and memory used %","region":"$AWS_REGION","view":"timeSeries","stat":"Average","period":300,
   "metrics":[["CWAgent","disk_used_percent","InstanceId","$INSTANCE_ID"],["CWAgent","mem_used_percent","InstanceId","$INSTANCE_ID"]],"yAxis":{"left":{"min":0,"max":100}}}},
 {"type":"metric","x":16,"y":9,"width":8,"height":6,"properties":{"title":"Health OK (1=up) and backups succeeded","region":"$AWS_REGION","view":"timeSeries","period":300,
   "metrics":[["AutoHub","HealthCheckOK",{"stat":"Minimum"}],["AutoHub","BackupSucceeded",{"stat":"Sum"}]]}},
 {"type":"alarm","x":0,"y":15,"width":24,"height":4,"properties":{"title":"Alarms","alarms":[
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-cpu-high",
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-status-check-failed",
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-memory-high",
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-disk-high",
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-assistant-down",
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-slow-response",
   "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:autohub-backup-missed"]}}
]}
EOF
aws cloudwatch put-dashboard --dashboard-name autohub-operations --dashboard-body "file://$DASH" >/dev/null
echo "   https://$AWS_REGION.console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#dashboards/dashboard/autohub-operations"

say "Done. To get your real alert email (evidence E-08), see README 'Prove an alert arrives'."
