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
  validation {
    condition     = var.cluster_endpoint == "" || can(regex("^https://", var.cluster_endpoint))
    error_message = "cluster_endpoint must be empty (validate-only) or a valid https:// URL."
  }
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

# NOTE: embedding dimension (1024) is enforced in infra/db/init.sql VECTOR(1024)
# and the app's EMBEDDING_DIM env var — there is no RDS-level knob for it, so it is
# intentionally not a Terraform variable here.

variable "deletion_protection" {
  description = "RDS deletion protection (off for lab teardown)"
  type        = bool
  default     = false
}
