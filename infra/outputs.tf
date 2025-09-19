output "instance_id"        { value = aws_instance.mongo.id }
output "public_ip"          { value = aws_instance.mongo.public_ip }
output "private_ip"         { value = aws_instance.mongo.private_ip }
output "security_group_id"  { value = aws_security_group.mongo.id }
output "admin_password_param" { value = aws_ssm_parameter.mongo_admin.name }
output "backup_bucket"      { value = var.backup_bucket_name }
