output "loki_role_arn" {
  description = "IAM role ARN for Loki's S3 access (inject into Loki ServiceAccount annotation)"
  value       = aws_iam_role.loki.arn
}

output "trivy_role_arn" {
  description = "IAM role ARN for Trivy's ECR access (inject into trivy-operator ServiceAccount annotation)"
  value       = aws_iam_role.trivy.arn
}
