output "address" {
  description = "Host name of the database server"
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "security_group_id" {
  value = aws_security_group.db.id
}

output "master_secret_arn" {
  description = "Secrets Manager secret holding the admin username and password"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "migration_bucket" {
  value = aws_s3_bucket.migration.bucket
}

output "app_secret_arn" {
  description = "Secrets Manager secret holding the web app's restricted username and password"
  value       = aws_secretsmanager_secret.app.arn
}
