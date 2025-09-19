#!/usr/bin/env bash
set -euo pipefail

# Inputs from Jenkins parameters/env
: "${AWS_REGION_PARAM:?AWS_REGION_PARAM not set}"
ASSUME_ROLE_ARN="${ASSUME_ROLE_ARN:-}"

# Conjur secret content is in env AWS_DYNAMIC_SECRET_JSON
: "${AWS_DYNAMIC_SECRET_JSON:?AWS_DYNAMIC_SECRET_JSON not provided by Jenkins withCredentials}"

AKID=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.access_key_id // .AccessKeyId')
SKEY=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.secret_access_key // .SecretAccessKey')
STOK=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.session_token // .SessionToken')

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
aws sts get-caller-identity

if [[ -n "${ASSUME_ROLE_ARN}" ]]; then
  echo "[INFO] Assuming role: ${ASSUME_ROLE_ARN}"
  CREDS=$(aws sts assume-role --role-arn "${ASSUME_ROLE_ARN}" --role-session-name "jenkins-mongo-tf")
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
fi
