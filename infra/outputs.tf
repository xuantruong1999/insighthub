output "irsa_role_arn" {
  description = "Annotate the InsightHub SA: helm --set api.irsa.roleArn=<this>"
  value       = module.irsa.role_arn
}

output "rds_endpoint" {
  description = "RDS Postgres endpoint"
  value       = module.rds.endpoint
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = module.elasticache.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN for DB credentials"
  value       = module.rds.secret_arn
}

output "redis_secret_arn" {
  description = "Secrets Manager ARN for Redis auth token"
  value       = module.elasticache.secret_arn
}
