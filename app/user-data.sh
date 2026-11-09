#!/bin/bash
# EC2 bootstrap (runs once at first boot). __BUCKET__ and __REGION__ are filled in by 02-launch-ec2.sh.
set -euxo pipefail
exec > >(tee -a /var/log/autohub-bootstrap.log) 2>&1

BUCKET="__BUCKET__"
REGION="__REGION__"
export AWS_DEFAULT_REGION="$REGION"

dnf install -y docker git amazon-cloudwatch-agent jq

# t3.small has 2 GB RAM: add 2 GB swap so MongoDB + Meilisearch + LibreChat fit.
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Rotate container logs so they can never fill the disk (see the disk-full runbook).
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
systemctl enable --now docker

mkdir -p /opt/autohub/ops /var/log/autohub
cat > /opt/autohub/ops/autohub.conf <<EOF
REGION=$REGION
BUCKET=$BUCKET
PARAM_PREFIX=/autohub
EOF

aws s3 sync "s3://$BUCKET/app/" /opt/autohub/ops/
chmod +x /opt/autohub/ops/*.sh

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/autohub/ops/cwagent.json

/opt/autohub/ops/start-autohub.sh

cp /opt/autohub/ops/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now autohub-health.timer autohub-backup.timer
echo "$(date -Is) bootstrap complete"
