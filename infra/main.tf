data "aws_caller_identity" "current" {}

# Shared customer-managed KMS key for at-rest encryption of secrets, RDS and Redis.
resource "aws_kms_key" "main" {
  description             = "InsightHub at-rest encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/insighthub-${var.namespace}"
  target_key_id = aws_kms_key.main.key_id
}

module "namespace" {
  source    = "./modules/namespace"
  namespace = var.namespace
}

module "rds" {
  source                   = "./modules/rds"
  vpc_id                   = var.vpc_id
  private_subnet_ids       = var.private_subnet_ids
  source_security_group_id = var.eks_node_security_group_id
  kms_key_arn              = aws_kms_key.main.arn
  instance_class           = var.db_instance_class
  deletion_protection      = var.deletion_protection
}

module "elasticache" {
  source                   = "./modules/elasticache"
  vpc_id                   = var.vpc_id
  private_subnet_ids       = var.private_subnet_ids
  source_security_group_id = var.eks_node_security_group_id
  kms_key_arn              = aws_kms_key.main.arn
  node_type                = var.redis_node_type
}

module "irsa" {
  source            = "./modules/irsa"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  namespace         = var.namespace
  secret_arns       = [module.rds.secret_arn, module.elasticache.secret_arn]
  kms_key_arn       = aws_kms_key.main.arn
}
