#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source ./.awscreds

: "${INFRA_DIR:?INFRA_DIR not set}"
: "${TF_STATE_BUCKET_PARAM:?TF_STATE_BUCKET_PARAM not set}"
: "${TF_STATE_TABLE_PARAM:?TF_STATE_TABLE_PARAM not set}"
: "${TF_STATE_KEY_PARAM:?TF_STATE_KEY_PARAM not set}"
: "${AWS_REGION_PARAM:?AWS_REGION_PARAM not set}"

if [[ ! -d "${INFRA_DIR}" ]]; then
  echo "[ERR] INFRA_DIR '${INFRA_DIR}' not found in $(pwd)" >&2
  ls -la
  exit 2
fi

cd "${INFRA_DIR}"

cat > backend_override.hcl <<EOF
bucket         = "${TF_STATE_BUCKET_PARAM}"
key            = "${TF_STATE_KEY_PARAM}"
region         = "${AWS_REGION_PARAM}"
dynamodb_table = "${TF_STATE_TABLE_PARAM}"
encrypt        = true
EOF

terraform init -reconfigure -backend-config=backend_override.hcl
terraform validate
