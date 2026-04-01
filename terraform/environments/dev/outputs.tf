output "cluster_name" {
  description = "EKS cluster name — use with: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "aws_region" {
  description = "AWS region the cluster was deployed into"
  value       = var.aws_region
}

output "loki_s3_bucket_name" {
  description = "S3 bucket name for Loki storage — injected into Loki values-aws.yaml"
  value       = aws_s3_bucket.loki.id
}

output "loki_irsa_role_arn" {
  description = "IAM role ARN for Loki's S3 access — inject as ServiceAccount annotation"
  value       = module.irsa.loki_role_arn
}

output "trivy_irsa_role_arn" {
  description = "IAM role ARN for Trivy's ECR access — inject as ServiceAccount annotation"
  value       = module.irsa.trivy_role_arn
}
