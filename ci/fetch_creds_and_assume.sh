#!/usr/bin/env bash
set -euo pipefail

# Required env from Jenkins parameters
: "${AWS_REGION_PARAM:?AWS_REGION_PARAM not set}"

# Optional inputs
ASSUME_ROLE_ARN_RAW="${ASSUME_ROLE_ARN:-}"             # can be full role ARN, 12-digit acct id, user ARN, or empty
ASSUME_ROLE_NAME="${ASSUME_ROLE_NAME:-TerraformDeployRole}"

# Conjur secret content is injected by Jenkins withCredentials
: "${AWS_DYNAMIC_SECRET_JSON:?AWS_DYNAMIC_SECRET_JSON not provided by Jenkins withCredentials}"

# --- 1) Base session from Conjur secret (support nested or flat fields) ---
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

echo "[INFO] Caller identity (Conjur creds / base):"
aws sts get-caller-identity

# --- 2) Normalize target role input ---
normalize_role_arn() {
  local raw="$1"
  local role_name="$2"

  if [[ -z "$raw" ]]; then
    echo ""
    return 0
  fi

  # Full role ARN?
  if [[ "$raw" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
    echo "$raw"; return 0
  fi

  # Plain 12-digit account id?
  if [[ "$raw" =~ ^[0-9]{12}$ ]]; then
    echo "arn:aws:iam::${raw}:role/${role_name}"; return 0
  fi

  # User ARN? derive account id and build role arn with provided role_name
  if [[ "$raw" =~ ^arn:aws:iam::([0-9]{12}):user/.+ ]]; then
    local acct="${BASH_REMATCH[1]}"
    echo "arn:aws:iam::${acct}:role/${role_name}"; return 0
  fi

  # Anything else → invalid
  echo "__INVALID__"
}

# Prefer explicit ASSUME_ROLE_ARN (raw), else ROLE_HINT (if it’s a role arn and different)
ROLE_TO_ASSUME="$(normalize_role_arn "${ASSUME_ROLE_ARN_RAW}" "${ASSUME_ROLE_NAME}")"

if [[ -z "$ROLE_TO_ASSUME" ]]; then
  # Only consider ROLE_HINT if it looks like a role ARN and differs from current identity
  if [[ -n "$ROLE_HINT" && "$ROLE_HINT" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
    CURRENT_ARN="$(aws sts get-caller-identity --query Arn --output text || true)"
    if [[ "$CURRENT_ARN" != "$ROLE_HINT" ]]; then
      ROLE_TO_ASSUME="$ROLE_HINT"
    fi
  fi
fi

if [[ "$ROLE_TO_ASSUME" == "__INVALID__" ]]; then
  echo "[ERR] ASSUME_ROLE_ARN must be one of:
  - Full ROLE ARN: arn:aws:iam::<12-digit-acct>:role/<RoleName>
  - 12-digit account id: <12-digit-acct> (uses ASSUME_ROLE_NAME='${ASSUME_ROLE_NAME}')
  - USER ARN: arn:aws:iam::<12-digit-acct>:user/<UserName> (derives role using ASSUME_ROLE_NAME)
Given: '${ASSUME_ROLE_ARN_RAW}'" >&2
  exit 2
fi

# --- 3) Optional cross-account hop ---
if [[ -n "$ROLE_TO_ASSUME" ]]; then
  echo "[INFO] Assuming role: ${ROLE_TO_ASSUME}"
  CREDS="$(aws sts assume-role --role-arn "${ROLE_TO_ASSUME}" --role-session-name "jenkins-mongo-tf")"

  export AWS_ACCESS_KEY_ID="$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)"
  export AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)"
  export AWS_SESSION_TOKEN="$(echo "$CREDS" | jq -r .Credentials.SessionToken)"

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
  echo "[INFO] No role assumption requested (using base Conjur creds)."
fi
