#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source ./.awscreds

: "${ACTION:?ACTION not set}"
: "${INFRA_DIR:?INFRA_DIR not set}"

cd "${INFRA_DIR}"

# Destroy path: minimal vars, no refresh
if [[ "${ACTION}" == "destroy" ]]; then
  : "${AWS_REGION_PARAM:?AWS_REGION_PARAM not set}"
  TFVARS_MIN=""
  TFVARS_MIN+=" -var=aws_region=${AWS_REGION_PARAM}"
  TFVARS_MIN+=" -var=vpc_id=destroy"
  TFVARS_MIN+=" -var=subnet_id=destroy"
  TFVARS_MIN+=" -var=backup_bucket_name=destroy"
  TFVARS_MIN+=" -var=assume_role_arn=${ASSUME_ROLE_ARN:-}"
  terraform plan -destroy -refresh=false -out=tfplan $TFVARS_MIN
  terraform apply -auto-approve tfplan
  exit 0
fi

# Plan/Apply path — require AMI
if [[ -z "${LINUX_AMI_ID:-}" ]]; then
  echo "[ERR] LINUX_AMI_ID is required for plan/apply." >&2
  exit 1
fi

# Ingest input vars
TFVARS=""
TFVARS+=" -var=aws_region=${AWS_REGION_PARAM}"
TFVARS+=" -var=assume_role_arn=${ASSUME_ROLE_ARN:-}"

# Networking
TFVARS+=" -var=vpc_id=${VPC_ID}"
TFVARS+=" -var=subnet_id=${SUBNET_ID}"
TFVARS+=" -var=ssh_ingress_cidr=${SSH_CIDR}"

if [[ -n "${EKS_NODE_SG_ID:-}" ]]; then
  TFVARS+=" -var=eks_node_sg_id=${EKS_NODE_SG_ID}"
fi

# Parse ALLOWED_CIDRS list into HCL list
if [[ -n "${ALLOWED_CIDRS:-}" ]]; then
  CLEAN="$(echo "${ALLOWED_CIDRS}" | tr -d ' ')"
  LIST=$(awk -v s="$CLEAN" 'BEGIN{n=split(s,a,","); printf("[" ); for(i=1;i<=n;i++){printf("%s\"%s\"", (i>1?",":""), a[i])} printf("]") }')
  TFVARS+=" -var=allowed_cidrs=${LIST}"
fi

# EC2 & AMI
TFVARS+=" -var=instance_name=${INSTANCE_NAME}"
TFVARS+=" -var=instance_type=${INSTANCE_TYPE}"
if [[ -n "${KEY_NAME:-}" ]]; then TFVARS+=" -var=key_name=${KEY_NAME}"; else TFVARS+=" -var=key_name=null"; fi
TFVARS+=" -var=linux_ami_id=${LINUX_AMI_ID}"

# Mongo / exposure
TFVARS+=" -var=mongo_version=${MONGO_VERSION}"
TFVARS+=" -var=public_access=${PUBLIC_ACCESS}"

# Volumes
TFVARS+=" -var=root_volume_gb=${ROOT_VOLUME_GB}"
TFVARS+=" -var=data_volume_gb=${DATA_VOLUME_GB}"

# Backups
TFVARS+=" -var=backup_bucket_name=${BACKUP_BUCKET}"
TFVARS+=" -var=backup_prefix=${BACKUP_PREFIX}"
TFVARS+=" -var=backup_cron='${BACKUP_CRON}'"
TFVARS+=" -var=backup_retention_days=${RETENTION_DAYS}"

terraform plan -out=tfplan $TFVARS
if [[ "${ACTION}" == "apply" ]]; then
  terraform apply -auto-approve tfplan
fi
