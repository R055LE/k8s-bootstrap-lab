variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "default"
}

variable "cluster_name" {
  description = "Name of the EKS cluster and prefix for all related resources"
  type        = string
  default     = "zero-to-cluster"
}

variable "environment" {
  description = "Environment name — used in resource names and tags"
  type        = string
  default     = "dev"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS. Check AWS docs for supported versions."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes. t3.medium gives 2 vCPU / 4GB RAM."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_count" {
  description = "Desired worker node count"
  type        = number
  default     = 2
}

variable "node_min_count" {
  description = "Minimum worker node count"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum worker node count"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "loki_s3_bucket_name" {
  description = "Name of the S3 bucket for Loki log storage. Must be globally unique."
  type        = string
}
