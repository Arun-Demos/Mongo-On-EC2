# MongoDB on EC2 (Terraform)

This module provisions:
- EC2 with configurable Linux AMI and MongoDB version
- Local + remote auth
- Optional public access
- SG rule to allow EKS pods via node SG
- stardb + services collection + seed data
- Automated S3 backups

## Steps
1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in values.
2. Run:
   ```bash
   cd infra
   terraform init -backend-config="bucket=..." -backend-config="key=..." -backend-config="region=..." -backend-config="dynamodb_table=..."
   terraform plan -out=tfplan
   terraform apply tfplan
