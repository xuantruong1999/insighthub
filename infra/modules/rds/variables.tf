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
