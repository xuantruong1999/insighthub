output "endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.this.address
}

output "secret_arn" {
  description = "Secrets Manager ARN holding DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}
