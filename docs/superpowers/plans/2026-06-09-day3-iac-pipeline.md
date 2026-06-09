# Day 3 — IaC Module + Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a checkov-clean Terraform module (`infra/`) for InsightHub (namespace + RDS pgvector + ElastiCache + IRSA) and a green GitHub Actions IaC pipeline, artifact-only (no AWS apply).

**Architecture:** Root module wires four sub-modules (`namespace`, `rds`, `elasticache`, `irsa`). A shared KMS key encrypts secrets and storage. Secrets are generated via `random_password` and stored in Secrets Manager — never hardcoded. Outputs feed Helm (`api.irsa.roleArn`). CI runs fmt/lint/scan/validate always; real `terraform plan` is OIDC-gated and skipped without creds.

**Tech Stack:** Terraform ≥1.9, AWS provider ~>5.x, Kubernetes provider ~>2.x, random provider; checkov (`python -m checkov.main`); GitHub Actions.

**Verify loop (every task):** `terraform fmt -recursive infra` → `terraform -chdir=infra init -backend=false` (once) + `terraform -chdir=infra validate` → `python -m checkov.main -d infra --compact` → commit. Run from repo root `c:/Users/Truong/source/projects/insighthub`.

---

### Task 1: Root scaffolding (versions, providers, variables, KMS)

**Files:**
- Create: `infra/versions.tf`
- Create: `infra/providers.tf`
- Create: `infra/variables.tf`
- Create: `infra/main.tf` (KMS only for now)

- [ ] **Step 1: Write `infra/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

- [ ] **Step 2: Write `infra/providers.tf`**

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "insighthub"
      ManagedBy = "terraform"
      Day       = "3"
    }
  }
}

# Cluster already exists (lab: do NOT create EKS). Configure the k8s provider
# against it via standard kubeconfig/exec; left to the environment for apply.
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = var.cluster_ca_certificate != "" ? base64decode(var.cluster_ca_certificate) : null
}
```

- [ ] **Step 3: Write `infra/variables.tf`**

```hcl
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "namespace" {
  description = "Kubernetes namespace for InsightHub"
  type        = string
  default     = "insighthub-dev"
}

# --- Existing cluster / network inputs (no cluster is created here) ---
variable "cluster_endpoint" {
  description = "Existing EKS cluster API endpoint"
  type        = string
  default     = ""
}

variable "cluster_ca_certificate" {
  description = "Base64 CA cert of the existing EKS cluster"
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider (for IRSA)"
  type        = string
  default     = ""
}

variable "oidc_provider_url" {
  description = "URL of the cluster's IAM OIDC provider, without https://"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC the cluster runs in"
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS/ElastiCache"
  type        = list(string)
  default     = []
}

variable "eks_node_security_group_id" {
  description = "Security group of EKS nodes (source for DB/Redis ingress)"
  type        = string
  default     = ""
}

# --- Sizing (cost-aware, lab) ---
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "embedding_dim" {
  description = "Embedding vector dimension (must match infra/db/init.sql VECTOR(n))"
  type        = number
  default     = 1024
}

variable "deletion_protection" {
  description = "RDS deletion protection (off for lab teardown)"
  type        = bool
  default     = false
}
```

- [ ] **Step 4: Write `infra/main.tf` (KMS key only)**

```hcl
# Shared customer-managed KMS key for at-rest encryption of secrets, RDS and Redis.
resource "aws_kms_key" "main" {
  description             = "InsightHub at-rest encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "main" {
  name          = "alias/insighthub"
  target_key_id = aws_kms_key.main.key_id
}
```

- [ ] **Step 5: Verify fmt + validate**

Run:
```bash
terraform fmt -recursive infra
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Verify checkov on KMS**

Run: `python -m checkov.main -d infra --compact`
Expected: KMS checks pass (rotation enabled). No HIGH/CRITICAL.

- [ ] **Step 7: Commit**

```bash
git add infra/versions.tf infra/providers.tf infra/variables.tf infra/main.tf
git commit -m "feat(day-3): scaffold terraform root + shared KMS key"
```

---

### Task 2: Namespace sub-module

**Files:**
- Create: `infra/modules/namespace/main.tf`
- Create: `infra/modules/namespace/variables.tf`
- Create: `infra/modules/namespace/outputs.tf`
- Modify: `infra/main.tf` (add module block)

- [ ] **Step 1: Write `infra/modules/namespace/variables.tf`**

```hcl
variable "namespace" {
  description = "Namespace name"
  type        = string
}
```

- [ ] **Step 2: Write `infra/modules/namespace/main.tf`**

```hcl
resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "insighthub"
    }
  }
}
```

- [ ] **Step 3: Write `infra/modules/namespace/outputs.tf`**

```hcl
output "name" {
  description = "Created namespace name"
  value       = kubernetes_namespace.this.metadata[0].name
}
```

- [ ] **Step 4: Add module block to `infra/main.tf`**

```hcl
module "namespace" {
  source    = "./modules/namespace"
  namespace = var.namespace
}
```

- [ ] **Step 5: Verify fmt + validate**

Run:
```bash
terraform fmt -recursive infra
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add infra/modules/namespace infra/main.tf
git commit -m "feat(day-3): namespace sub-module"
```

---

### Task 3: RDS PostgreSQL + pgvector sub-module

**Files:**
- Create: `infra/modules/rds/variables.tf`
- Create: `infra/modules/rds/main.tf`
- Create: `infra/modules/rds/outputs.tf`
- Modify: `infra/main.tf` (add module block)

- [ ] **Step 1: Write `infra/modules/rds/variables.tf`**

```hcl
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "source_security_group_id" {
  description = "SG allowed to reach Postgres (EKS nodes)"
  type        = string
}
variable "kms_key_arn" {
  type = string
}
variable "instance_class" {
  type = string
}
variable "deletion_protection" {
  type = bool
}
```

- [ ] **Step 2: Write `infra/modules/rds/main.tf`**

```hcl
resource "random_password" "db" {
  length  = 32
  special = false # avoid RDS-invalid chars (/, @, ", space)
}

resource "aws_secretsmanager_secret" "db" {
  name       = "insighthub/rds"
  kms_key_id = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "insighthub"
    password = random_password.db.result
    dbname   = "insighthub"
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

  db_name  = "insighthub"
  username = "insighthub"
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

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Lab teardown convenience; would be false + final snapshot in prod.
  skip_final_snapshot = true #checkov:skip=CKV_AWS_293:"lab teardown; final snapshot in prod"
}
```

- [ ] **Step 3: Write `infra/modules/rds/outputs.tf`**

```hcl
output "endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.this.address
}

output "secret_arn" {
  description = "Secrets Manager ARN holding DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}
```

- [ ] **Step 4: Add module block to `infra/main.tf`**

```hcl
module "rds" {
  source                   = "./modules/rds"
  vpc_id                   = var.vpc_id
  private_subnet_ids       = var.private_subnet_ids
  source_security_group_id = var.eks_node_security_group_id
  kms_key_arn              = aws_kms_key.main.arn
  instance_class           = var.db_instance_class
  deletion_protection      = var.deletion_protection
}
```

- [ ] **Step 5: Verify fmt + validate**

Run:
```bash
terraform fmt -recursive infra
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Verify checkov on RDS**

Run: `python -m checkov.main -d infra --compact`
Expected: 0 HIGH/CRITICAL. If a HIGH appears, paste the check ID + resource and either add the missing argument or a justified `#checkov:skip=<ID>:"<reason>"`. Re-run until clean.

- [ ] **Step 7: Commit**

```bash
git add infra/modules/rds infra/main.tf
git commit -m "feat(day-3): RDS pgvector sub-module (encrypted, private, secrets-managed)"
```

---

### Task 4: ElastiCache Redis sub-module

**Files:**
- Create: `infra/modules/elasticache/variables.tf`
- Create: `infra/modules/elasticache/main.tf`
- Create: `infra/modules/elasticache/outputs.tf`
- Modify: `infra/main.tf` (add module block)

- [ ] **Step 1: Write `infra/modules/elasticache/variables.tf`**

```hcl
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "source_security_group_id" {
  type = string
}
variable "kms_key_arn" {
  type = string
}
variable "node_type" {
  type = string
}
```

- [ ] **Step 2: Write `infra/modules/elasticache/main.tf`**

```hcl
resource "random_password" "auth" {
  length  = 32
  special = false # ElastiCache auth token: alphanumeric only
}

resource "aws_secretsmanager_secret" "redis" {
  name       = "insighthub/redis"
  kms_key_id = var.kms_key_arn
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

  automatic_failover_enabled = false #checkov:skip=CKV_AWS_31:"single-node for lab cost; failover in prod"
  multi_az_enabled           = false

  snapshot_retention_limit = 1
}
```

- [ ] **Step 3: Write `infra/modules/elasticache/outputs.tf`**

```hcl
output "endpoint" {
  description = "Redis primary endpoint"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "secret_arn" {
  description = "Secrets Manager ARN holding Redis auth token"
  value       = aws_secretsmanager_secret.redis.arn
}
```

- [ ] **Step 4: Add module block to `infra/main.tf`**

```hcl
module "elasticache" {
  source                   = "./modules/elasticache"
  vpc_id                   = var.vpc_id
  private_subnet_ids       = var.private_subnet_ids
  source_security_group_id = var.eks_node_security_group_id
  kms_key_arn              = aws_kms_key.main.arn
  node_type                = var.redis_node_type
}
```

- [ ] **Step 5: Verify fmt + validate + checkov**

Run:
```bash
terraform fmt -recursive infra
terraform -chdir=infra validate
python -m checkov.main -d infra --compact
```
Expected: valid; 0 HIGH/CRITICAL (iterate with justified skips as in Task 3 Step 6).

- [ ] **Step 6: Commit**

```bash
git add infra/modules/elasticache infra/main.tf
git commit -m "feat(day-3): ElastiCache Redis sub-module (encrypted at-rest + transit, auth)"
```

---

### Task 5: IRSA sub-module

**Files:**
- Create: `infra/modules/irsa/variables.tf`
- Create: `infra/modules/irsa/main.tf`
- Create: `infra/modules/irsa/outputs.tf`
- Modify: `infra/main.tf` (add module block)

- [ ] **Step 1: Write `infra/modules/irsa/variables.tf`**

```hcl
variable "oidc_provider_arn" {
  type = string
}
variable "oidc_provider_url" {
  description = "OIDC provider URL without https://"
  type        = string
}
variable "namespace" {
  type = string
}
variable "service_account" {
  type    = string
  default = "insighthub-api"
}
variable "secret_arns" {
  description = "Secrets Manager ARNs the pod may read"
  type        = list(string)
}
variable "kms_key_arn" {
  type = string
}
```

- [ ] **Step 2: Write `infra/modules/irsa/main.tf`**

```hcl
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "insighthub-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "insighthub-secrets-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.secrets.json
}
```

- [ ] **Step 3: Write `infra/modules/irsa/outputs.tf`**

```hcl
output "role_arn" {
  description = "IRSA role ARN to annotate the InsightHub service account"
  value       = aws_iam_role.this.arn
}
```

- [ ] **Step 4: Add module block to `infra/main.tf`**

```hcl
module "irsa" {
  source            = "./modules/irsa"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  namespace         = var.namespace
  secret_arns       = [module.rds.secret_arn, module.elasticache.secret_arn]
  kms_key_arn       = aws_kms_key.main.arn
}
```

- [ ] **Step 5: Verify fmt + validate + checkov**

Run:
```bash
terraform fmt -recursive infra
terraform -chdir=infra validate
python -m checkov.main -d infra --compact
```
Expected: valid; 0 HIGH/CRITICAL.

- [ ] **Step 6: Commit**

```bash
git add infra/modules/irsa infra/main.tf
git commit -m "feat(day-3): IRSA role with least-priv Secrets Manager access"
```

---

### Task 6: Root outputs + Helm wiring doc

**Files:**
- Create: `infra/outputs.tf`
- Modify: `infra/helm/insighthub/values.yaml:34-35` (comment documenting the wire-up)

- [ ] **Step 1: Write `infra/outputs.tf`**

```hcl
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
```

- [ ] **Step 2: Document the Helm wire-up in `infra/helm/insighthub/values.yaml`**

Change lines 34-35 from:
```yaml
  irsa:
    roleArn: ""
```
to:
```yaml
  irsa:
    # Populate from Terraform: helm upgrade --set api.irsa.roleArn=$(terraform -chdir=infra output -raw irsa_role_arn)
    roleArn: ""
```

- [ ] **Step 3: Verify fmt + validate**

Run:
```bash
terraform fmt -recursive infra
terraform -chdir=infra validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add infra/outputs.tf infra/helm/insighthub/values.yaml
git commit -m "feat(day-3): root outputs + document IRSA->Helm wire-up"
```

---

### Task 7: README + AI prompt log

**Files:**
- Modify: `infra/README.md` (append Terraform module section)

- [ ] **Step 1: Append to `infra/README.md`**

````markdown

## Terraform module (Day 3)

InsightHub managed infra: K8s namespace, RDS PostgreSQL 16 (pgvector), ElastiCache
Redis, and an IRSA role — all encrypted at rest with a shared KMS key, secrets in
Secrets Manager. **No EKS cluster is created** (lab runs on an existing cluster).

### Inputs

| Variable | Default | Purpose |
|---|---|---|
| `region` | `ap-southeast-1` | AWS region |
| `namespace` | `insighthub-dev` | K8s namespace |
| `cluster_endpoint` / `cluster_ca_certificate` | `""` | Existing EKS API access |
| `oidc_provider_arn` / `oidc_provider_url` | `""` | Cluster OIDC provider for IRSA |
| `vpc_id` / `private_subnet_ids` / `eks_node_security_group_id` | `""` / `[]` / `""` | Network placement + DB/Redis ingress source |
| `db_instance_class` | `db.t3.micro` | RDS size (cost-aware) |
| `redis_node_type` | `cache.t3.micro` | Redis size (cost-aware) |
| `embedding_dim` | `1024` | Must match `infra/db/init.sql` VECTOR(n) |
| `deletion_protection` | `false` | RDS deletion protection (lab: off) |

### Outputs

`irsa_role_arn`, `rds_endpoint`, `redis_endpoint`, `db_secret_arn`, `redis_secret_arn`.

### Usage

```bash
terraform -chdir=infra init
terraform -chdir=infra fmt -check -recursive
python -m checkov.main -d infra          # gate: 0 HIGH/CRITICAL
terraform -chdir=infra plan -var-file=lab.tfvars
# apply only after human review:
terraform -chdir=infra apply
# wire IRSA into the app:
helm upgrade insighthub infra/helm/insighthub \
  --set api.irsa.roleArn=$(terraform -chdir=infra output -raw irsa_role_arn)
```

### AI prompt log

- "Tạo Terraform module trong infra/ cho InsightHub trên AWS. Ràng buộc: EKS namespace
  trên cluster có sẵn, RDS pgvector không public + encryption at rest + single-AZ,
  ElastiCache Redis không public, IRSA không IAM user, instance nhỏ nhất, secrets qua
  Secrets Manager."
- "checkov báo HIGH [...]. Sửa Terraform để pass, giải thích từng thay đổi."
- "Giải thích terraform plan này bằng tiếng Việt: mỗi resource tạo gì, rủi ro, cost."
````

- [ ] **Step 2: Commit**

```bash
git add infra/README.md
git commit -m "docs(day-3): terraform module README + AI prompt log"
```

---

### Task 8: GitHub Actions IaC pipeline

**Files:**
- Create: `.github/workflows/iac.yml`

- [ ] **Step 1: Write `.github/workflows/iac.yml`**

```yaml
name: iac

on:
  push:
    branches: [main, "feature/**"]
    paths: ["infra/**", ".github/workflows/iac.yml"]
  pull_request:
    paths: ["infra/**", ".github/workflows/iac.yml"]

permissions:
  contents: read

jobs:
  fmt:
    name: fmt
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"
      - name: terraform fmt
        run: terraform fmt -check -recursive infra

  lint:
    name: lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: latest
      - name: tflint
        run: |
          cd infra
          tflint --init
          tflint --recursive

  scan:
    name: scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: infra
          soft_fail_on: LOW,MEDIUM
          output_format: cli
          quiet: true

  validate:
    name: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"
      - name: terraform validate
        run: |
          terraform -chdir=infra init -backend=false
          terraform -chdir=infra validate

  plan:
    name: plan
    runs-on: ubuntu-latest
    needs: [fmt, lint, scan, validate]
    # OIDC, no long-lived keys. Skipped (not failed) when no AWS role is configured.
    if: ${{ github.ref == 'refs/heads/main' && vars.AWS_ROLE_ARN != '' }}
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"
      - name: terraform plan
        run: |
          terraform -chdir=infra init
          terraform -chdir=infra plan -input=false
```

- [ ] **Step 2: Validate YAML locally**

Run: `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/iac.yml')); print('yaml ok')"`
Expected: `yaml ok`

- [ ] **Step 3: Confirm verify-day-3 stage greps will match**

Run: `grep -iE "(name: fmt|name: lint|name: scan|name: plan|terraform plan|tflint|checkov)" .github/workflows/iac.yml`
Expected: matches for fmt, lint, scan, plan stages.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/iac.yml
git commit -m "ci(day-3): IaC pipeline (fmt/lint/scan/validate + OIDC-gated plan)"
```

---

### Task 9: Final gate — whole-module checkov + fmt, fix HIGH

**Files:** (fixes as needed across `infra/`)

- [ ] **Step 1: Full fmt check**

Run: `terraform fmt -check -recursive infra`
Expected: no output (all formatted). If files listed, run `terraform fmt -recursive infra`.

- [ ] **Step 2: Full validate**

Run: `terraform -chdir=infra init -backend=false && terraform -chdir=infra validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Full checkov, count HIGH/CRITICAL**

Run: `python -m checkov.main -d infra --compact`
Then: `python -m checkov.main -d infra -o json > /tmp/ck.json; python -c "import json;d=json.load(open('/tmp/ck.json'));f=[c for c in d['results']['failed_checks'] if c.get('severity') in ('HIGH','CRITICAL')];print('HIGH/CRITICAL:',len(f));[print(c['check_id'],c['resource']) for c in f]"`
Expected: `HIGH/CRITICAL: 0`. For each remaining HIGH: add the missing secure argument, or — only when it conflicts with a documented lab constraint (cost/single-AZ/teardown) — a justified `#checkov:skip=<ID>:"<reason>"`. Re-run until 0.

- [ ] **Step 4: Run the day verifier**

Run: `bash scripts/verify-day-3.sh`
Expected: Terraform + pipeline checks PASS. (kubectl/gh/tflint checks skip locally — they are `command -v`-gated.)

- [ ] **Step 5: Commit any fixes**

```bash
git add infra
git commit -m "fix(day-3): resolve checkov HIGH findings; module is checkov-clean"
```

---

## Self-Review

**Spec coverage:**
- Terraform module (namespace/RDS/ElastiCache/IRSA) → Tasks 2–5. ✓
- checkov no-HIGH → Tasks 3,4,5 per-module + Task 9 final gate. ✓
- CI fmt/lint/scan/plan + OIDC gating → Task 8. ✓
- Secrets via Secrets Manager + KMS, no hardcoded → Tasks 1,3,4. ✓
- IRSA no IAM user → Task 5. ✓
- Terraform→Helm integration (irsa_role_arn) → Task 6. ✓
- README + AI prompt log → Task 7. ✓
- Namespace-not-cluster constraint → Task 2 (no aws_eks_cluster anywhere). ✓
- EMBEDDING_DIM 1024 constraint → variable carried in Task 1; schema unchanged. ✓
- Out-of-scope (Part B app pipeline, real apply) → not included. ✓

**Placeholder scan:** No TBD/TODO; all code blocks complete; checkov skip reasons are concrete.

**Type/name consistency:** module output names (`role_arn`, `endpoint`, `secret_arn`) referenced consistently in root `main.tf`/`outputs.tf`; var names (`source_security_group_id`, `kms_key_arn`, `oidc_provider_url`) match across module and caller.

**Note on checkov severity:** OSS checkov may report `severity: null` (no Prisma connection); the verify script's HIGH count can read 0 trivially. Task 9 therefore also inspects the `--compact` failed-check list directly, not just the severity count — we fix real misconfigurations, not just the grep.
