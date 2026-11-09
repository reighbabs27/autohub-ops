#!/bin/bash
# 01 - Account foundation. Run in AWS CloudShell, signed in as YOUR IAM user (MFA on), never root.
# Creates: budget alert, SNS alert topic, content bucket, CloudTrail, secrets in Parameter Store,
#          EC2 IAM role, security group (CloudFront-only), and uploads app + content to S3.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

say "1/8 Budget alert: \$${MONTHLY_BUDGET_USD}/month -> $ALERT_EMAIL"
try aws budgets create-budget --region us-east-1 --account-id "$ACCOUNT_ID" \
  --budget "{\"BudgetName\":\"autohub-monthly\",\"BudgetLimit\":{\"Amount\":\"$MONTHLY_BUDGET_USD\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
  --notifications-with-subscribers "[
    {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":50,\"ThresholdType\":\"PERCENTAGE\"},
     \"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$ALERT_EMAIL\"}]},
    {\"Notification\":{\"NotificationType\":\"FORECASTED\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":100,\"ThresholdType\":\"PERCENTAGE\"},
     \"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$ALERT_EMAIL\"}]}]"

say "2/8 SNS topic for alarms"
TOPIC_ARN=$(aws sns create-topic --name autohub-alerts \
  --tags Key=Project,Value=SAM10 Key=Team,Value=autohub --query TopicArn --output text)
save_state TOPIC_ARN "$TOPIC_ARN"
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
     --query "Subscriptions[?Endpoint=='$ALERT_EMAIL']" --output text | grep -q .; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
  echo "   >>> Check $ALERT_EMAIL and CLICK the AWS confirmation link, or no alarm email will arrive."
else
  echo "   subscription exists"
fi

make_bucket() {
  if aws s3api head-bucket --bucket "$1" 2>/dev/null; then echo "   $1 exists"; return; fi
  if [ "$AWS_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$1" >/dev/null
  else aws s3api create-bucket --bucket "$1" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null; fi
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "$1" \
    --tagging 'TagSet=[{Key=Project,Value=SAM10},{Key=Team,Value=autohub}]'
  echo "   created $1"
}

say "3/8 Content + backup bucket (private, encrypted, versioned)"
make_bucket "$BUCKET"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules":[
    {"ID":"keep-db-backups-8-days","Filter":{"Prefix":"backups/"},"Status":"Enabled",
     "Expiration":{"Days":8},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
    {"ID":"old-content-versions-30-days","Filter":{"Prefix":"content/"},"Status":"Enabled",
     "NoncurrentVersionExpiration":{"NoncurrentDays":30}}]}'

say "4/8 CloudTrail (who did what, in $AWS_REGION)"
make_bucket "$TRAIL_BUCKET"
aws s3api put-bucket-lifecycle-configuration --bucket "$TRAIL_BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-90","Filter":{"Prefix":""},"Status":"Enabled","Expiration":{"Days":90}}]}'
aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" --policy "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Sid\":\"AclCheck\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"cloudtrail.amazonaws.com\"},
    \"Action\":\"s3:GetBucketAcl\",\"Resource\":\"arn:aws:s3:::$TRAIL_BUCKET\"},
   {\"Sid\":\"Write\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"cloudtrail.amazonaws.com\"},
    \"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$TRAIL_BUCKET/AWSLogs/$ACCOUNT_ID/*\",
    \"Condition\":{\"StringEquals\":{\"s3:x-amz-acl\":\"bucket-owner-full-control\"}}}]}"
try aws cloudtrail create-trail --name autohub-trail --s3-bucket-name "$TRAIL_BUCKET" \
  --tags-list Key=Project,Value=SAM10 Key=Team,Value=autohub
aws cloudtrail start-logging --name autohub-trail

say "5/8 Secrets -> Parameter Store (SecureString). Nothing is written to disk or git."
put_secure() { aws ssm put-parameter --name "$PARAM_PREFIX/$1" --type SecureString --value "$2" --overwrite >/dev/null; }
put_plain()  { aws ssm put-parameter --name "$PARAM_PREFIX/$1" --type String       --value "$2" --overwrite >/dev/null; }
has_param()  { aws ssm get-parameter --name "$PARAM_PREFIX/$1" >/dev/null 2>&1; }

if ! has_param gemini_api_key; then
  # Paste ONCE, then Enter: input is hidden, so a second paste doubles the key (incident INC-02).
  read -rsp "   Paste your Gemini API key ONCE (input is hidden), then press Enter: " GK; echo
  GK=$(echo -n "$GK" | tr -d '[:space:]')
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "x-goog-api-key: $GK" \
    https://generativelanguage.googleapis.com/v1beta/models)
  if [ "$CODE" != "200" ]; then
    unset GK; echo "   Google rejected that key (HTTP $CODE). Nothing saved - run this script again."; exit 1
  fi
  put_secure gemini_api_key "$GK"; unset GK
  echo "   Google accepted the key; stored gemini_api_key"
fi
gen() { has_param "$1" || { put_secure "$1" "$(openssl rand -hex "$2")"; echo "   generated $1"; }; }
gen creds_key 32           # LibreChat needs 64 hex chars
gen creds_iv 16            # 32 hex chars
gen jwt_secret 32
gen jwt_refresh_secret 32
gen meili_master_key 16
put_plain gemini_model "$GEMINI_MODEL"
has_param allow_registration || put_plain allow_registration "true"
echo "   parameters under $PARAM_PREFIX:"
aws ssm get-parameters-by-path --path "$PARAM_PREFIX" --query 'Parameters[].[Name,Type]' --output table

say "6/8 IAM role for the EC2 instance (least privilege)"
try aws iam create-role --role-name autohub-ec2-role \
  --tags Key=Project,Value=SAM10 Key=Team,Value=autohub \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name autohub-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name autohub-ec2-role --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam put-role-policy --role-name autohub-ec2-role --policy-name autohub-app-access --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Sid\":\"ReadOwnParams\",\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameter\",\"ssm:GetParameters\",\"ssm:GetParametersByPath\"],
    \"Resource\":\"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter$PARAM_PREFIX/*\"},
   {\"Sid\":\"DecryptViaSSMOnly\",\"Effect\":\"Allow\",\"Action\":\"kms:Decrypt\",\"Resource\":\"*\",
    \"Condition\":{\"StringEquals\":{\"kms:ViaService\":\"ssm.$AWS_REGION.amazonaws.com\"}}},
   {\"Sid\":\"ListBucket\",\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::$BUCKET\"},
   {\"Sid\":\"ReadAppAndContent\",\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",
    \"Resource\":[\"arn:aws:s3:::$BUCKET/app/*\",\"arn:aws:s3:::$BUCKET/content/*\",\"arn:aws:s3:::$BUCKET/backups/*\"]},
   {\"Sid\":\"WriteBackupsOnly\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/backups/*\"}]}"
try aws iam create-instance-profile --instance-profile-name autohub-ec2-profile
if [ "$(aws iam get-instance-profile --instance-profile-name autohub-ec2-profile --query 'length(InstanceProfile.Roles)')" = "0" ]; then
  aws iam add-role-to-instance-profile --instance-profile-name autohub-ec2-profile --role-name autohub-ec2-role
fi

say "7/8 Security group: port 3080 open to CloudFront ONLY, no SSH (use Session Manager)"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" != "None" ] || { echo "No default VPC in $AWS_REGION - create one in the VPC console (Actions > Create default VPC)"; exit 1; }
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=autohub-web Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name autohub-web --vpc-id "$VPC_ID" \
    --description "AutoHub: LibreChat reachable only from CloudFront" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=SAM10},{Key=Team,Value=autohub}]' \
    --query GroupId --output text)
  PL_ID=$(aws ec2 describe-managed-prefix-lists \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "[{\"IpProtocol\":\"tcp\",\"FromPort\":3080,\"ToPort\":3080,\"PrefixListIds\":[{\"PrefixListId\":\"$PL_ID\",\"Description\":\"CloudFront origin-facing only\"}]}]" >/dev/null
fi
save_state SG_ID "$SG_ID"
echo "   $SG_ID"

say "8/8 Upload app scripts and dealership content to S3"
aws s3 sync ./app "s3://$BUCKET/app/" --delete
aws s3 sync ./content "s3://$BUCKET/content/" --delete

say "Done. Next: ./02-launch-ec2.sh   (remember to confirm the SNS email)"
