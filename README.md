# MongoDB on EC2 with Terraform + Seed Files

This provisions:
- EC2 with **configurable Linux AMI** (even older distros) and **MongoDB version**
- MongoDB with **auth enabled** (local + remote), bind to localhost + private IP (+ optionally public)
- Security Group allowing:
  - EKS node SG to access port 27017 (pods can reach private IP),
  - Optional public access to 27017,
  - Optional extra CIDRs
- **stardb** + **services** collection (validator) and **seed data** from `seed/` files
- Nightly **S3 backups** of `stardb`

## Quick start

1. Create/choose a **remote state** bucket + DynamoDB lock table (once):
   - S3 bucket (e.g., `tf-state-prod`)
   - DynamoDB table (e.g., `tf-locks`)

2. Copy `infra/terraform.tfvars.example` → `infra/terraform.tfvars`, fill your values.

3. (Optional local run)
   ```bash
   cd infra
   terraform init \
     -backend-config="bucket=tf-state-prod" \
     -backend-config="key=mongo-ec2/terraform.tfstate" \
     -backend-config="region=ap-southeast-1" \
     -backend-config="dynamodb_table=tf-locks"
   terraform plan -out=tfplan
   terraform apply -auto-approve tfplan
