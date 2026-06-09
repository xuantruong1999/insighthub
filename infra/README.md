# Day 3: Terraform IaC sẽ được học viên tạo ở đây (EKS namespace, RDS, ElastiCache).

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
