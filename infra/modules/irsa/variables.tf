variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's IAM OIDC provider"
  type        = string
}
variable "oidc_provider_url" {
  description = "OIDC provider URL without https://"
  type        = string
}
variable "namespace" {
  description = "Kubernetes namespace where the service account lives"
  type        = string
}
variable "service_account" {
  description = "Kubernetes service account name to bind the IAM role to"
  type        = string
  default     = "insighthub-api"
}
variable "secret_arns" {
  description = "Secrets Manager ARNs the pod may read"
  type        = list(string)
}
variable "kms_key_arn" {
  description = "ARN of the KMS key the pod needs decrypt access to"
  type        = string
}
