provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn     = var.assume_role_arn != "" ? var.assume_role_arn : null
    session_name = "terraform-mongo-ec2"
  }
}
