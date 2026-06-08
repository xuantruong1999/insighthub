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
