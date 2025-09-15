output "aws_account_id" { value = var.aws_account_id }
output "aws_region"     { value = var.aws_region }

output "mongo_private_ip" { value = aws_instance.mongo.private_ip }
output "security_group_id" { value = aws_security_group.mongo.id }

output "backup_bucket" { value = aws_s3_bucket.mongo_backups.bucket }
output "backup_prefix" { value = var.backup_prefix }

output "admin_password_parameter" { value = aws_ssm_parameter.mongo_admin.name }
output "connection_string_note" {
  value = "Fetch admin password from SSM ${aws_ssm_parameter.mongo_admin.name}; connect to mongodb://admin:<PASS>@${aws_instance.mongo.private_ip}:27017/admin?authSource=admin"
}
