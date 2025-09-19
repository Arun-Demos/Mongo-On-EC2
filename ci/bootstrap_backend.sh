#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source ./.awscreds

: "${TF_STATE_BUCKET_PARAM:?TF_STATE_BUCKET_PARAM not set}"
: "${TF_STATE_TABLE_PARAM:?TF_STATE_TABLE_PARAM not set}"
: "${AWS_REGION_PARAM:?AWS_REGION_PARAM not set}"

BUCKET="${TF_STATE_BUCKET_PARAM}"
TABLE="${TF_STATE_TABLE_PARAM}"
REGION="${AWS_REGION_PARAM}"

# S3 bucket idempotent
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "[OK] State bucket exists: $BUCKET"
else
  echo "[CREATE] S3 bucket: $BUCKET"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET"
  else
    aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

# DynamoDB table idempotent
if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  echo "[OK] Lock table exists: $TABLE"
else
  echo "[CREATE] DynamoDB table: $TABLE"
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  aws dynamodb wait table-exists --table-name "$TABLE"
fi
