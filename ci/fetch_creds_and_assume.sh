#!/usr/bin/env bash
set -euo pipefail

# Inputs from Jenkins
: "${AWS_REGION_PARAM:?AWS_REGION_PARAM not set}"
TARGET_ACCOUNT_ID="${TARGET_ACCOUNT_ID:-}"
TARGET_ROLE_NAME="${TARGET_ROLE_NAME:-TerraformDeployRole}"

# Conjur secret content is injected by Jenkins withCredentials
: "${AWS_DYNAMIC_SECRET_JSON:?AWS_DYNAMIC_SECRET_JSON not provided by Jenkins withCredentials}"

# --- 1) Base session from Conjur secret (supports nested/flat) ---
AKID=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.access_key_id // .AccessKeyId')
SKEY=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.secret_access_key // .SecretAccessKey')
STOK=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.session_token // .SessionToken')
ROLE_HINT=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.role_arn // .RoleArn // empty')

if [[ -z "$AKID" || -z "$SKEY" || -z "$STOK" ]]; then
  echo "[ERR] Missing AWS creds in dynamic secret" >&2
  exit 1
fi

cat > .awscreds <<EOF
export AWS_ACCESS_KEY_ID=$AKID
export AWS_SECRET_ACCESS_KEY=$SKEY
export AWS_SESSION_TOKEN=$STOK
export AWS_DEFAULT_REGION=${AWS_REGION_PARAM}
EOF
# shellcheck disable=SC1091
source ./.awscreds

echo "[INFO] Caller identity (base):"
BASE_ID_JSON=$(aws sts get-caller-identity)
echo "$BASE_ID_JSON"
BASE_ACCT=$(echo "$BASE_ID_JSON" | jq -r .Account)

# --- 2) Decide if we should assume a role ---
ROLE_TO_ASSUME=""

# 2a) If the secret explicitly includes a role_arn, prefer that.
if [[ -n "$ROLE_HINT" && "$ROLE_HINT" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
  CURRENT_ARN=$(echo "$BASE_ID_JSON" | jq -r .Arn)
  if [[ "$CURRENT_ARN" != "$ROLE_HINT" ]]; then
    ROLE_TO_ASSUME="$ROLE_HINT"
    echo "[INFO] Using role_arn from Conjur secret: ${ROLE_TO_ASSUME}"
  fi
fi

# 2b) Else, if TARGET_ACCOUNT_ID is set & different, build a standard role ARN in that account.
if [[ -z "$ROLE_TO_ASSUME" && -n "$TARGET_ACCOUNT_ID" && "$TARGET_ACCOUNT_ID" != "$BASE_ACCT" ]]; then
  ROLE_TO_ASSUME="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/${TARGET_ROLE_NAME}"
  echo "[INFO] Will assume into target account via: ${ROLE_TO_ASSUME}"
fi

# --- 3) Assume role if needed ---
if [[ -n "$ROLE_TO_ASSUME" ]]; then
  echo "[INFO] Assuming role: ${ROLE_TO_ASSUME}"
  CREDS=$(aws sts assume-role --role-arn "${ROLE_TO_ASSUME}" --role-session-name "jenkins-mongo-ec2")
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)
  cat > .awscreds <<EOF
export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN
export AWS_DEFAULT_REGION=${AWS_REGION_PARAM}
EOF
  # shellcheck disable=SC1091
  source ./.awscreds

  echo "[INFO] Caller identity (assumed):"
  aws sts get-caller-identity
else
  echo "[INFO] No role assumption requested; using base Conjur creds."
fi
