provider "aws" {
  region = var.aws_region

  # If ASSUME ROLE ARN is provided, use it (cross-account).
  assume_role {
    role_arn     = var.assume_role_arn != "" ? var.assume_role_arn : null
    session_name = "terraform-mongo-ec2"
  }
}
