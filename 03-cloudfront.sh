#!/bin/bash
# 03 - CloudFront in front of EC2: free HTTPS on https://xxxx.cloudfront.net, no caching (chat is dynamic).
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
source ./lib-remote.sh

if [ -z "${DIST_ID:-}" ]; then
  say "Creating CloudFront distribution -> $ORIGIN_DNS:3080"
  CFG=$(mktemp)
  cat > "$CFG" <<EOF
{
  "CallerReference": "autohub-$(date +%s)",
  "Comment": "AutoHub Assistant (SAM10)",
  "Enabled": true,
  "PriceClass": "PriceClass_200",
  "HttpVersion": "http2",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "autohub-ec2",
    "DomainName": "$ORIGIN_DNS",
    "CustomOriginConfig": {
      "HTTPPort": 3080, "HTTPSPort": 443,
      "OriginProtocolPolicy": "http-only",
      "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 5,
      "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
    }}]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "autohub-ec2",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
    "Compress": false
  }
}
EOF
  read -r DIST_ID DIST_DOMAIN < <(aws cloudfront create-distribution --distribution-config "file://$CFG" \
    --query 'Distribution.[Id,DomainName]' --output text)
  save_state DIST_ID "$DIST_ID"
  save_state DIST_DOMAIN "$DIST_DOMAIN"
  aws cloudfront tag-resource --resource "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DIST_ID" \
    --tags 'Items=[{Key=Project,Value=SAM10},{Key=Team,Value=autohub}]'
fi
echo "   $DIST_ID  https://$DIST_DOMAIN"

say "Telling LibreChat its public URL"
aws ssm put-parameter --name "$PARAM_PREFIX/domain" --type String --value "https://$DIST_DOMAIN" --overwrite >/dev/null

wait_for_ssm
run_remote "/opt/autohub/ops/start-autohub.sh"

say "Done. CloudFront takes 5-15 minutes to deploy worldwide."
echo "   Open https://$DIST_DOMAIN , click Sign up, create YOUR account."
echo "   Then close sign-ups:  ./ops.sh close-registration"
echo "   Next: ./04-monitoring.sh"
