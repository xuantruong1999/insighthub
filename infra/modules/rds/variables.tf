variable "vpc_id" {
  description = "VPC ID where the RDS instance will be deployed"
  type        = string
}
variable "private_subnet_ids" {
  description = "Private subnet IDs for the RDS subnet group"
  type        = list(string)
}
variable "source_security_group_id" {
  description = "SG allowed to reach Postgres (EKS nodes)"
  type        = string
}
variable "kms_key_arn" {
  description = "ARN of the KMS key used for RDS and Secrets Manager at-rest encryption"
  type        = string
}
variable "instance_class" {
  description = "RDS instance class (e.g. db.t3.micro)"
  type        = string
}
variable "deletion_protection" {
  description = "Enable RDS deletion protection (set false for lab teardown)"
  type        = bool
}
