variable "vpc_id" {
  description = "VPC ID where the ElastiCache cluster will be deployed"
  type        = string
}
variable "private_subnet_ids" {
  description = "Private subnet IDs for the ElastiCache subnet group"
  type        = list(string)
}
variable "source_security_group_id" {
  description = "SG allowed to reach Redis (EKS nodes)"
  type        = string
}
variable "kms_key_arn" {
  description = "ARN of the KMS key used for ElastiCache and Secrets Manager at-rest encryption"
  type        = string
}
variable "node_type" {
  description = "ElastiCache node type (e.g. cache.t3.micro)"
  type        = string
}
