############################################
# Provider & Backend
############################################
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn     = var.assume_role_arn
    session_name = "terraform-mongo-ec2"
  }
}

############################################
# Data Sources
############################################
data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

############################################
# Security Group
############################################
resource "aws_security_group" "mongo" {
  name        = "${var.instance_name}-sg"
  description = "Security group for MongoDB EC2"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # MongoDB - optional EKS SG
  dynamic "ingress" {
    for_each = var.eks_node_sg_id != "" ? [1] : []
    content {
      description     = "Mongo from EKS nodes"
      from_port       = 27017
      to_port         = 27017
      protocol        = "tcp"
      security_groups = [var.eks_node_sg_id]
    }
  }

  # MongoDB - optional extra CIDRs
  dynamic "ingress" {
    for_each = var.allowed_cidrs
    content {
      description = "Mongo from CIDR"
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # MongoDB - open to world (if enabled)
  dynamic "ingress" {
    for_each = var.public_access ? [1] : []
    content {
      description = "Mongo open to world"
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

############################################
# IAM Role + Instance Profile
############################################
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mongo_role" {
  name               = "${var.instance_name}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.mongo_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.mongo_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "mongo_profile" {
  name = "${var.instance_name}-profile"
  role = aws_iam_role.mongo_role.name
}

############################################
# Storage Volumes
############################################
resource "aws_ebs_volume" "mongo_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  tags = {
    Name = "${var.instance_name}-data"
  }
}

############################################
# EC2 Instance
############################################

# Generate a strong admin password and store it in SSM (SecureString)
resource "random_password" "mongo_admin" {
  length  = 20
  special = false
}

resource "aws_ssm_parameter" "mongo_admin" {
  name  = "/mongo/admin_password"
  type  = "SecureString"
  value = random_password.mongo_admin.result
}

resource "aws_instance" "mongo" {
  ami                         = var.linux_ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.mongo.id]
  iam_instance_profile        = aws_iam_instance_profile.mongo_profile.name
  key_name                    = var.key_name != "" ? var.key_name : null
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/cloudinit/cloudinit.yaml.tmpl", {
    MONGO_MAJOR = var.mongo_version
    REGION      = var.aws_region
    BUCKET      = var.backup_bucket_name
    PREFIX      = var.backup_prefix
    CRON        = var.backup_cron
  })

  tags = {
    Name = var.instance_name
  }
}

resource "aws_volume_attachment" "mongo_data" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.mongo_data.id
  instance_id = aws_instance.mongo.id
}
