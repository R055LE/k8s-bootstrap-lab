locals {
  # Strip the https:// prefix — the trust policy uses the bare URL
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")

  tags = merge(
    {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

# ── Loki IRSA ─────────────────────────────────────────────────────────────────
# Grants the loki ServiceAccount read/write access to the Loki S3 bucket.

data "aws_iam_policy_document" "loki_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.loki_namespace}:loki"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "loki_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${var.loki_s3_bucket_arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.loki_s3_bucket_arn]
  }
}

resource "aws_iam_role" "loki" {
  name               = "${var.cluster_name}-loki-irsa"
  assume_role_policy = data.aws_iam_policy_document.loki_trust.json

  tags = local.tags
}

resource "aws_iam_role_policy" "loki_s3" {
  name   = "loki-s3-access"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki_s3.json
}

# ── Trivy IRSA ────────────────────────────────────────────────────────────────
# Grants the trivy-operator ServiceAccount read access to ECR for private
# image scanning. Uses AWS managed policy — attach only if scanning private ECR.

data "aws_iam_policy_document" "trivy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.trivy_namespace}:trivy-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trivy" {
  name               = "${var.cluster_name}-trivy-irsa"
  assume_role_policy = data.aws_iam_policy_document.trivy_trust.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "trivy_ecr" {
  role       = aws_iam_role.trivy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
