# Helpers for running commands on the instance through SSM Run Command (no SSH, no open port 22).
# Sourced by other scripts after config.env.

wait_for_ssm() {
  echo "   waiting for the instance to register with Systems Manager..."
  for _ in $(seq 1 40); do
    if [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ]; then
      echo "   online"; return 0
    fi
    sleep 15
  done
  echo "   instance never came online in SSM - check the EC2 console" >&2; return 1
}

# run_remote "shell command"  -> runs as root on the instance, prints output, returns its status
run_remote() {
  local cid status
  cid=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
    --timeout-seconds 1800 --comment "autohub ops" \
    --parameters "$(jq -cn --arg c "$1" '{commands:[$c], executionTimeout:["1800"]}')" \
    --query Command.CommandId --output text)
  echo "   running on $INSTANCE_ID: $1"
  while true; do
    sleep 5
    status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Pending|InProgress|Delayed) continue ;; esac
    break
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
    --query StandardErrorContent --output text | grep . >&2 || true
  echo "   status: $status   (command id $cid)"
  [ "$status" = "Success" ]
}
