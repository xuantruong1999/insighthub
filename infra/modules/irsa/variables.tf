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
