
---

# Jenkinsfile (works from EKS runner; same-acct or cross-acct)

This pipeline:
- Runs on any Jenkins agent (your EKS runner is perfect).
- Uses **IRSA** if the runner is in the **same account** as target.
- If you pass `ASSUME_ROLE_ARN`, it will **assume role** into the target account before running Terraform.

```groovy
pipeline {
  agent any

  environment {
    TF_IN_AUTOMATION = 'true'
    TERRAFORM_VERSION = '1.9.5'
  }

  parameters {
    choice(name: 'ACTION', choices: ['plan','apply','destroy'], description: 'Terraform action')
    string(name: 'AWS_ACCOUNT_ID', defaultValue: '111122223333', description: 'Target AWS Account ID')
    string(name: 'AWS_REGION', defaultValue: 'ap-southeast-1', description: 'Target Region')

    // Optional cross-account
    string(name: 'ASSUME_ROLE_ARN', defaultValue: '', description: 'Optional: arn:aws:iam::<acct>:role/TerraformDeploy')

    // Networking/compute
    string(name: 'VPC_ID', defaultValue: '', description: 'VPC ID')
    string(name: 'SUBNET_ID', defaultValue: '', description: 'Subnet ID (private preferred)')
    string(name: 'EKS_NODE_SG_ID', defaultValue: '', description: 'Optional: allow 27017 from this SG')
    string(name: 'SSH_CIDR', defaultValue: '0.0.0.0/0', description: 'SSH ingress CIDR (tighten!)')
    string(name: 'INSTANCE_NAME', defaultValue: 'mongodb-ec2', description: 'EC2 Name tag')
    string(name: 'INSTANCE_TYPE', defaultValue: 't3.medium', description: 'EC2 type')
    string(name: 'KEY_NAME', defaultValue: '', description: 'Optional EC2 keypair')

    // Backups
    string(name: 'BACKUP_BUCKET', defaultValue: 'your-unique-mongo-backups-bucket', description: 'S3 bucket for backups')
    string(name: 'BACKUP_PREFIX', defaultValue: 'mongo/stardb', description: 'S3 key prefix')
    string(name: 'BACKUP_CRON',   defaultValue: '15 2 * * *', description: 'Cron schedule')
    string(name: 'RETENTION_DAYS',defaultValue: '30', description: 'S3 lifecycle retention days')

    // Remote state backend
    string(name: 'TF_STATE_BUCKET', defaultValue: 'tf-state-prod', description: 'S3 bucket for tfstate')
    string(name: 'TF_STATE_KEY',    defaultValue: 'mongo-ec2/terraform.tfstate', description: 'Object key for tfstate')
    string(name: 'TF_LOCK_TABLE',   defaultValue: 'tf-locks', description: 'DynamoDB table for state lock')
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Install Terraform') {
      steps {
        sh '''
          set -eux
          if ! command -v terraform >/dev/null 2>&1; then
            curl -sSLo tf.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
            unzip tf.zip
            sudo mv terraform /usr/local/bin/terraform
            rm -f tf.zip
          fi
          terraform -version
        '''
      }
    }

    stage('Assume Role (optional)') {
      when { expression { return params.ASSUME_ROLE_ARN?.trim() } }
      steps {
        sh '''
          set -eux
          CREDS=$(aws sts assume-role --role-arn "${ASSUME_ROLE_ARN}" --role-session-name "jenkins-terraform" --query 'Credentials' --output json)
          export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
          export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
          export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
          # Persist for later stages
          echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"   >> $WORKSPACE/aws-env.sh
          echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> $WORKSPACE/aws-env.sh
          echo "export AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN"   >> $WORKSPACE/aws-env.sh
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

    stage('Validate & Plan/Apply/Destroy') {
      steps {
        sh '''
          set -eux
          [ -f "$WORKSPACE/aws-env.sh" ] && source "$WORKSPACE/aws-env.sh" || true
          cd infra

          # Build var args
          TFVARS="-var=aws_account_id=${AWS_ACCOUNT_ID} -var=aws_region=${AWS_REGION}"
          if [ -n "${ASSUME_ROLE_ARN}" ]; then
            TFVARS="${TFVARS} -var=assume_role_arn=${ASSUME_ROLE_ARN}"
          fi

          TFVARS="${TFVARS} -var=vpc_id=${VPC_ID} -var=subnet_id=${SUBNET_ID}"
          TFVARS="${TFVARS} -var=instance_name=${INSTANCE_NAME} -var=instance_type=${INSTANCE_TYPE}"
          if [ -n "${KEY_NAME}" ]; then TFVARS="${TFVARS} -var=key_name=${KEY_NAME}"; fi
          TFVARS="${TFVARS} -var=ssh_ingress_cidr=${SSH_CIDR}"
          if [ -n "${EKS_NODE_SG_ID}" ]; then TFVARS="${TFVARS} -var=eks_node_sg_id=${EKS_NODE_SG_ID}"; fi

          TFVARS="${TFVARS} -var=backup_bucket_name=${BACKUP_BUCKET} -var=backup_prefix=${BACKUP_PREFIX} -var=backup_cron='${BACKUP_CRON}' -var=backup_retention_days=${RETENTION_DAYS}"

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
