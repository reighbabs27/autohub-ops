#!/bin/bash
# 02 - Launch the EC2 instance that runs LibreChat (AutoHub). Encrypted disk, IMDSv2, Elastic IP.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

if [ -n "${INSTANCE_ID:-}" ] && aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
     --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null | grep -qE 'running|pending|stopped'; then
  echo "Instance $INSTANCE_ID already exists - not launching another."; exit 0
fi

say "Rendering bootstrap script"
UD=$(mktemp)
sed -e "s|__BUCKET__|$BUCKET|g" -e "s|__REGION__|$AWS_REGION|g" app/user-data.sh > "$UD"

say "Launching $INSTANCE_TYPE (Amazon Linux 2023)"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile Name=autohub-ec2-profile \
  --security-group-ids "$SG_ID" \
  --user-data "file://$UD" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=autohub-app},{Key=Project,Value=SAM10},{Key=Team,Value=autohub}]' \
    'ResourceType=volume,Tags=[{Key=Name,Value=autohub-root},{Key=Project,Value=SAM10},{Key=Team,Value=autohub}]' \
  --query 'Instances[0].InstanceId' --output text)
save_state INSTANCE_ID "$INSTANCE_ID"
echo "   $INSTANCE_ID"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

say "Elastic IP (so the address - and CloudFront's origin - survive a stop/start)"
ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=autohub-eip},{Key=Project,Value=SAM10},{Key=Team,Value=autohub}]' \
  --query AllocationId --output text)
save_state ALLOC_ID "$ALLOC_ID"
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null
sleep 5
ORIGIN_DNS=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
save_state ORIGIN_DNS "$ORIGIN_DNS"
echo "   origin: $ORIGIN_DNS"

say "Done. Bootstrap (Docker, LibreChat, CloudWatch agent) takes ~6-10 minutes."
echo "   Watch it: EC2 console > autohub-app > Connect > Session Manager, then:"
echo "     sudo tail -f /var/log/autohub-bootstrap.log"
echo "   Then run ./03-cloudfront.sh (it waits for the instance to be ready)."
