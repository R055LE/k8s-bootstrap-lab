data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  environment        = var.environment
}

# ── EKS ───────────────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.public_subnet_ids
  node_instance_type = var.node_instance_type
  node_desired_count = var.node_desired_count
  node_min_count     = var.node_min_count
  node_max_count     = var.node_max_count
  environment        = var.environment
}

# ── IRSA ──────────────────────────────────────────────────────────────────────

module "irsa" {
  source = "../../modules/irsa"

  cluster_name       = var.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_issuer_url    = module.eks.cluster_oidc_issuer_url
  loki_s3_bucket_arn = aws_s3_bucket.loki.arn
  environment        = var.environment
}

# ── S3 Bucket for Loki ────────────────────────────────────────────────────────

resource "aws_s3_bucket" "loki" {
  bucket        = var.loki_s3_bucket_name
  force_destroy = true # allows terraform destroy even if bucket has objects

  tags = {
    Name        = var.loki_s3_bucket_name
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-old-chunks"
    status = "Enabled"

    filter {}

    expiration {
      days = 30 # adjust retention as needed
    }
  }
}
