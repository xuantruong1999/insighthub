# Day 3 — AI-Powered IaC & Pipeline (Design)

**Date:** 2026-06-09 · **Branch:** `feature/day-three` · **Scope:** artifact-only (no AWS apply)

## Goal

Produce the three Day 3 artifacts that `scripts/verify-day-3.sh` and the lab guide
(`docs/lab-guides/Day3-AI-IaC-Pipeline.md`) require, **without provisioning real AWS**:

1. A production-grade Terraform module in `infra/` that passes `terraform fmt`,
   `tflint`, and **`checkov` with no HIGH/CRITICAL findings**.
2. A GitHub Actions IaC pipeline (`.github/workflows/iac.yml`) with `fmt` / `lint` /
   `scan` / `plan` stages that runs **green**.
3. InsightHub live on the cluster (currently minikube) — namespace `insighthub-dev`,
   ≥4 pods Running. (Bring-up is a separate, already-built Helm step; this spec covers
   only the IaC + pipeline artifacts and the Terraform→Helm integration.)

The real bar is a genuinely checkov-clean module + a pipeline that is actually green —
not merely satisfying the (trivially-greppable) verify script.

## Constraints (from lab + CLAUDE.md)

- **Namespace on an existing cluster — do NOT create an EKS cluster** (lab line 95).
  Out of scope and a checkov minefield.
- RDS PostgreSQL 16 with pgvector: **not publicly accessible**, encryption at rest,
  single-AZ (lab cost).
- ElastiCache Redis: not public, in-VPC, encryption at rest + in transit.
- **IRSA** for pod IAM — no IAM user, no long-lived keys.
- All secrets via AWS Secrets Manager (`random_password`), never hardcoded.
- Cost-aware: smallest viable instance classes.
- `EMBEDDING_DIM` stays 1024 (matches `infra/db/init.sql` `VECTOR(1024)`).
- pgvector ≥ 0.8.2 (CVE-2026-3172).

## Architecture / File layout

```
infra/
  versions.tf       # terraform >=1.9; aws ~>5.x, kubernetes ~>2.x, random pinned
  providers.tf      # aws + kubernetes providers (region/cluster vars)
  variables.tf      # region, cluster_name, vpc_id, subnet_ids, *_instance_class, embedding_dim, namespace
  main.tf           # wires the four sub-modules
  outputs.tf        # irsa_role_arn, rds_endpoint, redis_endpoint, secrets_arn
  README.md         # input variables, usage, AI prompt log
  modules/
    namespace/      # kubernetes_namespace "insighthub-dev"
    rds/            # aws_db_instance (encrypted, private, pgvector parameter group),
                    #   random_password + aws_secretsmanager_secret, SG (EKS->5432)
    elasticache/    # aws_elasticache_replication_group (at-rest + transit encryption,
                    #   auth_token from secret, private subnet group, SG)
    irsa/           # aws_iam_role with OIDC assume-role policy, least-priv to Secrets Manager
```

Sub-modules keep each concern independently reviewable and testable. Root module only
wires inputs/outputs.

## Checkov strategy

Satisfy every HIGH/CRITICAL by construction:

| Resource | Checks addressed |
|---|---|
| RDS | `storage_encrypted=true`, `publicly_accessible=false`, no hardcoded password (`random_password`→Secrets Manager), `backup_retention_period>0`, `iam_database_authentication_enabled=true`, `deletion_protection` (var-gated for lab teardown) |
| ElastiCache | `at_rest_encryption_enabled=true`, `transit_encryption_enabled=true`, `auth_token` from secret |
| IRSA/IAM | scoped policy (no `*` admin), OIDC trust, no IAM user |
| Secrets | KMS-encrypted secret, no plaintext in state outputs |

**Justified conflict:** lab wants single-AZ (cost) but checkov wants Multi-AZ. Resolve with
a documented inline skip — the teachable pattern, not silent omission:

```hcl
#checkov:skip=CKV_AWS_157:"single-AZ intentional for lab cost; would be Multi-AZ in prod"
```

(Exact check IDs confirmed at implementation time by running `python -m checkov.main -d infra`.)

## CI pipeline — `.github/workflows/iac.yml`

Jobs that need **no AWS creds** run always; the real `plan` is gated so a credential-less
repo skips it (skipped ≠ failed → run stays green):

- `fmt` — `terraform fmt -check -recursive`
- `lint` — `tflint --recursive` (setup-tflint action)
- `scan` — `bridgecrewio/checkov-action` (the real gate; a non-clean module turns this red)
- `validate` — `terraform init -backend=false && terraform validate`
- `plan` — `if: ${{ secrets.AWS_ROLE_ARN != '' }}`; uses OIDC:
  `permissions: id-token: write` + `aws-actions/configure-aws-credentials@v4` with
  `role-to-assume`. Makes "no long-lived keys" visible even though unexercised here.

## Integration with running system

Terraform `outputs.tf` emits `irsa_role_arn` → wired into Helm `values.yaml`
`api.irsa.roleArn` (currently `""`). Also outputs RDS + Redis endpoints and the Secrets
Manager ARN, so the module is visibly part of the deployed system rather than dead code.

## Out of scope

- App-build pipeline (lab Part B: 3 images + trivy + deploy-on-main). Optional; verify
  only needs the IaC pipeline. Not built unless requested.
- Actual `terraform apply` / AWS provisioning.
- EKS cluster creation.

## Verification

- `terraform fmt -check -recursive` → clean (self-run).
- `terraform init -backend=false && terraform validate` → success (self-run).
- `python -m checkov.main -d infra` → 0 HIGH/CRITICAL (self-run; this is the gate).
- `tflint` / `gh run` checks are skipped locally (tools absent); the workflow's checkov
  action enforces the real bar on push.
