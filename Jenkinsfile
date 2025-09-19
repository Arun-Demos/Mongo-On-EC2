pipeline {
  agent {
    kubernetes {
      defaultContainer 'runner'
      yaml """
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins
  containers:
    - name: runner
      image: docker.io/arunrana1214/tf-aws-runner:latest
      command: ["/bin/cat"]
      tty: true
      resources:
        requests:
          cpu: "500m"
          memory: "1Gi"
        limits:
          cpu: "2"
          memory: "3Gi"
"""
    }
  }

  options {
    ansiColor('xterm')
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    # Where your TF code lives IN THIS REPO
    INFRA_DIR       = "infra"

    # State backend defaults (can be overridden in params)
    AWS_REGION      = "us-east-1"
    TF_STATE_BUCKET = "starai-mongo-tfstate-bucket"
    TF_STATE_TABLE  = "tf-locks-mongo"
    TF_STATE_KEY    = "mongo-ec2/terraform.tfstate"

    TERRAFORM_VERSION = "1.9.5"
  }

  parameters {
    choice (name: 'ACTION', choices: ['plan','apply','destroy'], description: 'Terraform action')

    # Conjur dynamic AWS creds id
    string(name: 'CONJUR_AWS_CRED_ID', defaultValue: 'data-dynamic-Starai', description: 'Conjur dynamic secret')

    # Target Account/Region (informational + fed to TF)
    string(name: 'AWS_ACCOUNT_ID', defaultValue: '111122223333', description: 'Target AWS account (informational)')
    string(name: 'AWS_REGION_PARAM', defaultValue: 'us-east-1', description: 'Target region (also used for backend config)')

    # Backend specifics (override if needed)
    string(name: 'TF_STATE_BUCKET_PARAM', defaultValue: 'starai-mongo-tfstate-bucket', description: 'S3 bucket for tfstate')
    string(name: 'TF_STATE_TABLE_PARAM',  defaultValue: 'tf-locks-mongo', description: 'DynamoDB table for state locks')
    string(name: 'TF_STATE_KEY_PARAM',    defaultValue: 'mongo-ec2/terraform.tfstate', description: 'tfstate object key')

    # Networking / access
    string(name: 'VPC_ID',        defaultValue: '', description: 'VPC ID')
    string(name: 'SUBNET_ID',     defaultValue: '', description: 'Subnet ID (prefer private)')
    string(name: 'EKS_NODE_SG_ID',defaultValue: '', description: 'EKS node SG allowed to 27017 (optional)')
    string(name: 'SSH_CIDR',      defaultValue: '0.0.0.0/0', description: 'SSH ingress CIDR (tighten for prod)')
    string(name: 'ALLOWED_CIDRS', defaultValue: '', description: 'Comma-separated extra CIDRs for 27017 (optional)')

    # EC2 & images
    string(name: 'INSTANCE_NAME', defaultValue: 'mongodb-ec2', description: 'EC2 Name tag')
    string(name: 'INSTANCE_TYPE', defaultValue: 't3.medium',   description: 'EC2 type')
    string(name: 'KEY_NAME',      defaultValue: '',            description: 'EC2 keypair (optional)')
    string(name: 'LINUX_AMI_OWNER',  defaultValue: '137112412989', description: 'AMI owner (Amazon=137112412989, Canonical=099720109477)')
    string(name: 'LINUX_AMI_FILTER', defaultValue: 'al2023-ami-*-x86_64', description: 'AMI name filter (older distros supported)')
    string(name: 'MONGO_VERSION',    defaultValue: '7.0', description: 'MongoDB major version (e.g. 6.0, 7.0)')
    booleanParam(name: 'PUBLIC_ACCESS', defaultValue: false, description: 'Open 27017 to 0.0.0.0/0 (testing only)')

    # Storage / backups
    string(name: 'ROOT_VOLUME_GB', defaultValue: '16',  description: 'Root volume (GB)')
    string(name: 'DATA_VOLUME_GB', defaultValue: '100', description: 'Data EBS (GB)')
    string(name: 'BACKUP_BUCKET',  defaultValue: 'your-unique-mongo-backups-bucket', description: 'S3 bucket for backups (must be unique)')
    string(name: 'BACKUP_PREFIX',  defaultValue: 'mongo/stardb', description: 'S3 key prefix')
    string(name: 'BACKUP_CRON',    defaultValue: '15 2 * * *', description: 'Backup cron on instance')
    string(name: 'RETENTION_DAYS', defaultValue: '30', description: 'S3 lifecycle days')
  }

  stages {

    stage('Show tool versions') {
      steps {
        container('runner') {
          sh '''#!/usr/bin/env bash
set -euo pipefail
echo "aws: $(aws --version 2>&1 | head -n1)"
echo "tf : $(terraform -version | head -n1)"
echo "jq : $(jq --version)"
'''
        }
      }
    }

    stage('Fetch AWS creds (Conjur)') {
      steps {
        container('runner') {
          withCredentials([
            conjurSecretCredential(credentialsId: "${CONJUR_AWS_CRED_ID}", variable: 'AWS_DYNAMIC_SECRET_JSON')
          ]) {
            sh '''#!/usr/bin/env bash
set -euo pipefail

AKID=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.access_key_id // .AccessKeyId')
SKEY=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.secret_access_key // .SecretAccessKey')
STOK=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.session_token // .SessionToken')
ROLE_HINT=$(echo "$AWS_DYNAMIC_SECRET_JSON" | jq -r '.data.role_arn // .RoleArn // empty')

test -n "$AKID" && test -n "$SKEY" && test -n "$STOK" || { echo "[ERR] Missing AWS creds in dynamic secret"; exit 1; }

cat > .awscreds <<EOF
export AWS_ACCESS_KEY_ID=$AKID
export AWS_SECRET_ACCESS_KEY=$SKEY
export AWS_SESSION_TOKEN=$STOK
export AWS_DEFAULT_REGION=${AWS_REGION_PARAM}
EOF
. ./.awscreds

echo "[INFO] Caller identity (Conjur creds):"
aws sts get-caller-identity

# Optional hop: if secret includes a different role ARN, or a manual ASSUME_ROLE_ARN was provided
ROLE_TO_ASSUME="${ASSUME_ROLE_ARN:-}"
if [ -z "$ROLE_TO_ASSUME" ] && [ -n "$ROLE_HINT" ]; then
  ROLE_TO_ASSUME="$ROLE_HINT"
fi

if [ -n "$ROLE_TO_ASSUME" ]; then
  echo "[INFO] Assuming role: $ROLE_TO_ASSUME"
  CREDS=$(aws sts assume-role --role-arn "$ROLE_TO_ASSUME" --role-session-name "jenkins-mongo-tf")
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)
  cat > .awscreds <<EOF
export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN
export AWS_DEFAULT_REGION=${AWS_REGION_PARAM}
EOF
  . ./.awscreds
  echo "[INFO] Caller identity after assume-role:"
  aws sts get-caller-identity
fi
'''
          }
        }
      }
    }

    stage('Bootstrap backend (S3 + DynamoDB) if missing') {
      steps {
        container('runner') {
          sh '''#!/usr/bin/env bash
set -euo pipefail
. ./.awscreds

BUCKET="${TF_STATE_BUCKET_PARAM}"
TABLE="${TF_STATE_TABLE_PARAM}"
REGION="${AWS_REGION_PARAM}"

# S3
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "[OK] State bucket exists: $BUCKET"
else
  echo "[CREATE] S3 bucket: $BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
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

# DynamoDB
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
'''
        }
      }
    }

    stage('Terraform init') {
      steps {
        container('runner') {
          sh '''#!/usr/bin/env bash
set -euo pipefail
. ./.awscreds

cd "${INFRA_DIR}"

# backend override file (kept out of Git)
cat > backend_override.hcl <<EOF
bucket         = "${TF_STATE_BUCKET_PARAM}"
key            = "${TF_STATE_KEY_PARAM}"
region         = "${AWS_REGION_PARAM}"
dynamodb_table = "${TF_STATE_TABLE_PARAM}"
encrypt        = true
EOF

terraform init -reconfigure -backend-config=backend_override.hcl
terraform validate
'''
        }
      }
    }

    stage('Plan / Apply / Destroy') {
      steps {
        container('runner') {
          sh '''#!/usr/bin/env bash
set -euo pipefail
. ./.awscreds
cd "${INFRA_DIR}"

TFVARS=""
TFVARS="$TFVARS -var=aws_account_id=${AWS_ACCOUNT_ID}"
TFVARS="$TFVARS -var=aws_region=${AWS_REGION_PARAM}"

# Cross-account (if used): pass the same role
if [ -n "${ASSUME_ROLE_ARN}" ]; then
  TFVARS="$TFVARS -var=assume_role_arn=${ASSUME_ROLE_ARN}"
fi

# Networking
TFVARS="$TFVARS -var=vpc_id=${VPC_ID}"
TFVARS="$TFVARS -var=subnet_id=${SUBNET_ID}"
TFVARS="$TFVARS -var=ssh_ingress_cidr=${SSH_CIDR}"
if [ -n "${EKS_NODE_SG_ID}" ]; then
  TFVARS="$TFVARS -var=eks_node_sg_id=${EKS_NODE_SG_ID}"
fi
if [ -n "${ALLOWED_CIDRS}" ]; then
  CLEAN=$(echo "${ALLOWED_CIDRS}" | tr -d ' ')
  LIST=$(printf '%s' "$CLEAN" | awk -F',' '{printf("["); for(i=1;i<=NF;i++){printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")}') 
  TFVARS="$TFVARS -var=allowed_cidrs=${LIST}"
fi

# EC2 & images
TFVARS="$TFVARS -var=instance_name=${INSTANCE_NAME}"
TFVARS="$TFVARS -var=instance_type=${INSTANCE_TYPE}"
if [ -n "${KEY_NAME}" ]; then TFVARS="$TFVARS -var=key_name=${KEY_NAME}"; else TFVARS="$TFVARS -var=key_name=null"; fi
TFVARS="$TFVARS -var=linux_ami_owner=${LINUX_AMI_OWNER}"
TFVARS="$TFVARS -var=linux_ami_filter=${LINUX_AMI_FILTER}"
TFVARS="$TFVARS -var=mongo_version=${MONGO_VERSION}"
TFVARS="$TFVARS -var=public_access=${PUBLIC_ACCESS}"
TFVARS="$TFVARS -var=root_volume_gb=${ROOT_VOLUME_GB}"
TFVARS="$TFVARS -var=data_volume_gb=${DATA_VOLUME_GB}"

# Backups
TFVARS="$TFVARS -var=backup_bucket_name=${BACKUP_BUCKET}"
TFVARS="$TFVARS -var=backup_prefix=${BACKUP_PREFIX}"
TFVARS="$TFVARS -var=backup_cron='${BACKUP_CRON}'"
TFVARS="$TFVARS -var=backup_retention_days=${RETENTION_DAYS}"

terraform plan -out=tfplan $TFVARS

if [ "${ACTION}" = "apply" ]; then
  terraform apply -auto-approve tfplan
elif [ "${ACTION}" = "destroy" ]; then
  terraform destroy -auto-approve $TFVARS
fi
'''
        }
      }
    }
  }

  post {
    always {
      container('runner') {
        sh '''#!/usr/bin/env bash
set -euo pipefail
rm -f .awscreds || true
'''
      }
      archiveArtifacts artifacts: 'infra/*.tfstate.backup', allowEmptyArchive: true
      cleanWs()
    }
  }
}
