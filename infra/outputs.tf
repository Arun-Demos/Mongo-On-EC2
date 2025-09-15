output "mongo_private_ip" { value = aws_instance.mongo.private_ip }
output "mongo_public_ip"  { value = aws_instance.mongo.public_ip }
output "admin_password_param" { value = aws_ssm_parameter.mongo_admin.name }
output "backup_bucket"    { value = aws_s3_bucket.mongo_backups.bucket }
