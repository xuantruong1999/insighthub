resource "random_password" "auth" {
  length  = 32
  special = false # ElastiCache auth token: alphanumeric only
}

resource "aws_secretsmanager_secret" "redis" {
  name       = "insighthub/redis"
  kms_key_id = var.kms_key_arn
  #checkov:skip=CKV2_AWS_57:"rotation requires a Lambda rotator; out of scope for lab module"
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id     = aws_secretsmanager_secret.redis.id
  secret_string = jsonencode({ auth_token = random_password.auth.result })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "insighthub-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name        = "insighthub-redis"
  description = "InsightHub Redis access from EKS nodes"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "redis_ingress" {
  type                     = "ingress"
  description              = "Redis from EKS nodes"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = var.source_security_group_id
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "insighthub"
  description          = "InsightHub ARQ queue + cache"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.node_type
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  auth_token                 = random_password.auth.result

  automatic_failover_enabled = false #checkov:skip=CKV_AWS_31,CKV2_AWS_50:"single-node for lab cost; failover/Multi-AZ in prod"
  multi_az_enabled           = false

  snapshot_retention_limit = 1
}
