output "role_arn" {
  description = "IRSA role ARN to annotate the InsightHub service account"
  value       = aws_iam_role.this.arn
}
