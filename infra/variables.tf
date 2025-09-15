variable "aws_account_id" {
  description = "Target AWS account ID (informational; not used by provider directly)"
  type        = string
}

variable "aws_region" {
  description = "Region to deploy to"
  type        = string
  default     = "ap-southeast-1"
}

variable "assume_role_arn" {
  description = "Optional: IAM role ARN to assume (use for cross-account deploys)"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID where EC2 will run"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID (prefer a private subnet)"
  type        = string
}

variable "instance_name" {
  description = "Name tag for the MongoDB instance"
  type        = string
  default     = "mongodb-ec2"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Optional EC2 KeyPair for break-glass SSH"
  type        = string
  default     = null
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed for SSH (tighten or disable if using SSM only)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "eks_node_sg_id" {
  description = "Optional: allow Mongo 27017 from this SG (e.g., EKS nodes)"
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "Optional: extra CIDRs allowed to access 27017"
  type        = list(string)
  default     = []
}

variable "mongo_version" {
  description = "MongoDB major version branch"
  type        = string
  default     = "7.0"
}

variable "root_volume_gb" { type = number default = 16 }
variable "data_volume_gb" { type = number default = 100 }

# Backups
variable "backup_bucket_name" {
  description = "Globally unique S3 bucket for backups"
  type        = string
}

variable "backup_prefix" {
  description = "S3 key prefix for backups"
  type        = string
  default     = "mongo/stardb"
}

variable "backup_cron" {
  description = "Cron schedule (server timezone); e.g., daily at 02:15"
  type        = string
  default     = "15 2 * * *"
}

variable "backup_retention_days" {
  description = "S3 lifecycle expiration for backups"
  type        = number
  default     = 30
}
