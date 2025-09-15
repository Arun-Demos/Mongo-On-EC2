# MongoDB on EC2 (Terraform)

Provision a hardened MongoDB EC2 instance with:
- Separate EBS data volume
- Auth enabled (admin pwd in SSM SecureString)
- `stardb` + `services` collection (validator)
- Seed data
- Nightly S3 backups with lifecycle

## Define your target account & region

Set these in `infra/terraform.tfvars` (copy from `terraform.tfvars.example`):
- `aws_account_id = "111122223333"`
- `aws_region = "ap-southeast-1"`

For cross-account:
- Create a role in the **target** account (e.g., `TerraformDeploy`) and put its ARN in `assume_role_arn`.
- The Jenkins runner must be allowed to assume that role (see Jenkinsfile notes).

## Backend (remote state)

We configure backend at runtime from Jenkins. You need an S3 bucket + DynamoDB table in the target account (or a shared tools account):

- S3: e.g., `tf-state-prod`
- DynamoDB (for state lock): e.g., `tf-locks`

## Local test (optional)

```bash
cd infra
terraform init \
  -backend-config="bucket=tf-state-prod" \
  -backend-config="key=mongo-ec2/terraform.tfstate" \
  -backend-config="region=ap-southeast-1" \
  -backend-config="dynamodb_table=tf-locks"

terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply -auto-approve tfplan

