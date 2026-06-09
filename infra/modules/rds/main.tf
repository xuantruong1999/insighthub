terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  db_username = "insighthub"
  db_name     = "insighthub"
}

resource "random_password" "db" {
  length  = 32
  special = false # avoid RDS-invalid chars (/, @, ", space)
}

resource "aws_secretsmanager_secret" "db" {
  name       = "insighthub/rds"
  kms_key_id = var.kms_key_arn
  #checkov:skip=CKV2_AWS_57:"rotation requires a Lambda rotator; out of scope for lab module"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = local.db_username
    password = random_password.db.result
    dbname   = local.db_name
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "insighthub-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "insighthub-rds"
  description = "InsightHub RDS access from EKS nodes"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "db_ingress" {
  type                     = "ingress"
  description              = "Postgres from EKS nodes"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = var.source_security_group_id
}

# pgvector lives in the default postgres params; ensure shared_preload is open
# for the extension and require TLS in transit.
resource "aws_db_parameter_group" "this" {
  name   = "insighthub-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "insighthub"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name  = local.db_name
  username = local.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  publicly_accessible                 = false
  multi_az                            = false #checkov:skip=CKV_AWS_157:"single-AZ intentional for lab cost; Multi-AZ in prod"
  iam_database_authentication_enabled = true
  backup_retention_period             = 7
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true
  deletion_protection                 = var.deletion_protection

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn

  monitoring_interval = 0 #checkov:skip=CKV_AWS_118:"enhanced monitoring requires a dedicated IAM role + CloudWatch cost; enable in prod"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Lab teardown convenience; would be false + final snapshot in prod.
  skip_final_snapshot = true #checkov:skip=CKV_AWS_293:"lab teardown; final snapshot in prod"
}
