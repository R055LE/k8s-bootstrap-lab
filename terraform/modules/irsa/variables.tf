variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (without https://)"
  type        = string
}

variable "loki_s3_bucket_arn" {
  description = "ARN of the S3 bucket Loki uses for log storage"
  type        = string
}

variable "loki_namespace" {
  description = "Kubernetes namespace where Loki runs"
  type        = string
  default     = "logging"
}

variable "trivy_namespace" {
  description = "Kubernetes namespace where Trivy Operator runs"
  type        = string
  default     = "trivy-system"
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "tags" {
  description = "Additional tags to merge onto all resources"
  type        = map(string)
  default     = {}
}
