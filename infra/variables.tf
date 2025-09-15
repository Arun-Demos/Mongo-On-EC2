variable "aws_account_id" {
  description = "Target AWS account ID"
  type        = string
}

variable "aws_region" {
  description = "Region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "assume_role_arn" {
  description = "Optional role to assume for cross-account deployments"
  type        = string
  default     = ""
}

# Linux AMI selection
variable "linux_ami_owner" {
  description = "AMI owner ID (Amazon=137112412989, Canonical=099720109477)"
  type        = string
  default     = "137112412989"
}

variable "linux_ami_filter" {
  description = "AMI name filter (e.g., 'al2023-ami-*-x86_64', 'amzn2-ami-hvm-*-x86_64-gp2', 'ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*')"
  type        = string
  default     = "al2023-ami-*-x86_64"
}

# MongoDB version
variable "mongo_version" {
  description = "MongoDB version branch (6.0, 7.0, etc.)"
  type        = string
  default     = "7.0"
}

variable "public_access" {
  description = "Allow 27017 from 0.0.0.0/0 if true"
  type        = bool
  default     = false
}

# Networking
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "eks_node_sg_id" {
  description = "SG ID of EKS nodes that should reach MongoDB"
  type        = string
  default     = ""
}
variable "ssh_ingress_cidr" {
  description = "CIDR for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}
variable "allowed_cidrs" {
  description = "Extra CIDRs allowed to reach Mongo"
  type        = list(string)
  default     = []
}

# EC2
variable "instance_name" { type = string default = "mongodb-ec2" }
variable "instance_type" { type = string default = "t3.medium" }
variable "key_name" { type = string default = null }
variable "root_volume_gb" { type = number default = 16 }
variable "data_volume_gb" { type = number default = 100 }

# Backups
variable "backup_bucket_name" { type = string }
variable "backup_prefix" { type = string default = "mongo/stardb" }
variable "backup_cron" { type = string default = "15 2 * * *" }
variable "backup_retention_days" { type = number default = 30 }
