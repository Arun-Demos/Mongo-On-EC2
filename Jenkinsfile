pipeline {
  agent any

  environment {
    TF_IN_AUTOMATION   = 'true'
    TERRAFORM_VERSION  = '1.9.5'
    PATH               = "/usr/local/bin:/usr/bin:/bin:${PATH}"
  }

  parameters {
    // Action
    choice(name: 'ACTION', choices: ['plan','apply','destroy'], description: 'Terraform action')

    // Target account/region
    string(name: 'AWS_ACCOUNT_ID', defaultValue: '111122223333', description: 'Target AWS Account ID (informational)')
    string(name: 'AWS_REGION',     defaultValue: 'ap-southeast-1', description: 'Target region')

    // Cross-account (optional)
    string(name: 'ASSUME_ROLE_ARN', defaultValue: '', description: 'Optional: arn:aws:iam::<acct>:role/TerraformDeploy')

    // Backend state
    string(name: 'TF_STATE_BUCKET', defaultValue: 'tf-state-prod', description: 'S3 bucket for Terraform state')
    string(name: 'TF_STATE_KEY',    defaultValue: 'mongo-ec2/terraform.tfstate', description: 'Object key for state')
    string(name: 'TF_LOCK_TABLE',   defaultValue: 'tf-locks', description: 'DynamoDB lock table')

    // Network / compute
    string(name: 'VPC_ID',        defaultValue: '', description: 'Target VPC ID')
    string(name: 'SUBNET_ID',     defaultValue: '', description: 'Private subnet ID for EC2')
    string(name: 'EKS_NODE_SG_ID',defaultValue: '', description: 'Allow 27017 from this EKS node SG (optional)')
    string(name: 'SSH_CIDR',      defaultValue: '0.0.0.0/0', description: 'SSH ingress CIDR (tighten for prod)')
    string(name: 'ALLOWED_CIDRS', defaultValue: '', description: 'Comma-separated extra CIDRs allowed to reach 27017 (optional)')
    string(name: 'INSTANCE_NAME', defaultValue: 'mongodb-ec2', description: 'EC2 Name tag')
    string(name: 'INSTANCE_TYPE', defaultValue: 't3.medium',   description: 'EC2 instance type')
    string(name: 'KEY_NAME',      defaultValue: '',            description: 'EC2 key pair name (optional)')

    // Linux AMI & Mongo
    string(name: 'LINUX_AMI_OWNER',  defaultValue: '137112412989', description: 'AMI owner (Amazon=137112412989, Canonical=099720109477)')
    string(name: 'LINUX_AMI_FILTER', defaultValue: 'al2023-ami-*-x86_64', description: 'AMI name filter pattern (supports older distros)')
    string(name: 'MONGO_VERSION',    defaultValue: '7.0', description: 'MongoDB major version (e.g., 6.0 or 7.0)')
    booleanParam(name: 'PUBLIC_ACCESS', defaultValue: false, description: 'Allow 27017 from 0.0.0.0/0')

    // Storage / backups
    string(name: 'ROOT_VOLUME_GB', defaultValue: '16',  description: 'Root volume size (GB)')
    string(name: 'DATA_VOLUME_GB', defaultValue: '100', description: 'Data EBS volume size (GB)')
    string(name: 'BACKUP_BUCKET',  defaultValue: 'your-unique-mongo-backups-bucket', description: 'Globally-unique S3 bucket for backups')
    string(name: 'BACKUP_PREFIX',  defaultValue: 'mongo/stardb', description: 'S3 key prefix for backups')
    string(name: 'BACKUP_CRON',    defaultValue: '15 2 * * *', description: 'Backup cron on instance (server TZ)')
    string(name: 'RETENTION_DAYS', defaultValue: '30', description: 'S3 lifecycle expiration (days)')
  }

  options {
    timestamps()
    ansiColor('xterm')
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Install tooling') {
      steps {
        sh '''
          set -eux
          # Terraform
          if ! command -v terraform >/dev/null 2>&1; then
            curl -sSLo tf.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
            unzip tf.zip
            sudo mv terraform /usr/local/bin/terraform
            rm -f tf.zip
          fi
          terraform -version

          # jq
          if ! command -v jq >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
              sudo apt-get update -y && sudo apt-get install -y jq
            elif command -v yum >/dev/null 2>&1; then
              sudo yum install -y jq
            fi
          fi

          # AWS CLI
          if ! command -v aws >/dev/null 2>&1; then
            curl -sSLo awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
            unzip -q awscliv2.zip
            sudo ./aws/install
            rm -rf aws awscliv2.zip
          fi
        '''
      }
    }

    stage('Assume Role (optional)') {
      when { expression { return params.ASSUME_ROLE_ARN?.trim() } }
      steps {
        sh '''
          set -eux
          CREDS=$(aws sts assume-role --role-arn "${ASSUME_ROLE_ARN}" --role-session-name "jenkins-terraform" --query 'Credentials' --output json)
          echo "$CREDS" | jq .
          export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
          export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
          export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
          cat > $WORKSPACE/aws-env.sh <<EOF
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
EOF
        '''
      }
    }

    stage('Terraform Init') {
      steps {
        sh '''
          set -eux
          [ -f "$WORKSPACE/aws-env.sh" ] && source "$WORKSPACE/aws-env.sh" || true
          cd infra
          terraform init \
            -backend-config="bucket=${TF_STATE_BUCKET}" \
            -backend-config="key=${TF_STATE_KEY}" \
            -backend-config="region=${AWS_REGION}" \
            -backend-config="dynamodb_table=${TF_LOCK_TABLE}"
        '''
      }
    }

    stage('Validate / Plan / Apply / Destroy') {
      steps {
        sh '''
          set -eux
          [ -f "$WORKSPACE/aws-env.sh" ] && source "$WORKSPACE/aws-env.sh" || true
          cd infra

          # Build -var args
          TFVARS=""
          TFVARS="$TFVARS -var=aws_account_id=${AWS_ACCOUNT_ID}"
          TFVARS="$TFVARS -var=aws_region=${AWS_REGION}"
          if [ -n "${ASSUME_ROLE_ARN}" ]; then
            TFVARS="$TFVARS -var=assume_role_arn=${ASSUME_ROLE_ARN}"
          fi

          TFVARS="$TFVARS -var=vpc_id=${VPC_ID}"
          TFVARS="$TFVARS -var=subnet_id=${SUBNET_ID}"
          TFVARS="$TFVARS -var=instance_name=${INSTANCE_NAME}"
          TFVARS="$TFVARS -var=instance_type=${INSTANCE_TYPE}"

          if [ -n "${KEY_NAME}" ]; then
            TFVARS="$TFVARS -var=key_name=${KEY_NAME}"
          else
            TFVARS="$TFVARS -var=key_name=null"
          fi

          TFVARS="$TFVARS -var=ssh_ingress_cidr=${SSH_CIDR}"
          if [ -n "${EKS_NODE_SG_ID}" ]; then
            TFVARS="$TFVARS -var=eks_node_sg_id=${EKS_NODE_SG_ID}"
          fi

          if [ -n "${ALLOWED_CIDRS}" ]; then
            CLEAN=$(echo "${ALLOWED_CIDRS}" | tr -d ' ')
            LIST=$(printf '%s' "$CLEAN" | awk -F',' '{printf("["); for(i=1;i<=NF;i++){printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")}') 
            TFVARS="$TFVARS -var=allowed_cidrs=${LIST}"
          fi

          TFVARS="$TFVARS -var=linux_ami_owner=${LINUX_AMI_OWNER}"
          TFVARS="$TFVARS -var=linux_ami_filter=${LINUX_AMI_FILTER}"
          TFVARS="$TFVARS -var=mongo_version=${MONGO_VERSION}"
          TFVARS="$TFVARS -var=public_access=${PUBLIC_ACCESS}"

          TFVARS="$TFVARS -var=root_volume_gb=${ROOT_VOLUME_GB}"
          TFVARS="$TFVARS -var=data_volume_gb=${DATA_VOLUME_GB}"
          TFVARS="$TFVARS -var=backup_bucket_name=${BACKUP_BUCKET}"
          TFVARS="$TFVARS -var=backup_prefix=${BACKUP_PREFIX}"
          TFVARS="$TFVARS -var=backup_cron='${BACKUP_CRON}'"
          TFVARS="$TFVARS -var=backup_retention_days=${RETENTION_DAYS}"

          terraform validate
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

  post {
    always {
      archiveArtifacts artifacts: 'infra/*.tfstate.backup', allowEmptyArchive: true
    }
  }
}
