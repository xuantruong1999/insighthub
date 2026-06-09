output "endpoint" {
  description = "Redis primary endpoint"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "secret_arn" {
  description = "Secrets Manager ARN holding Redis auth token"
  value       = aws_secretsmanager_secret.redis.arn
}
