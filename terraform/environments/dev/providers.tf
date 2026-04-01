terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # S3 backend — bucket must exist before running terraform init.
  # Create it once with: bash scripts/create-tf-state-bucket.sh
  # Pass backend config at init time:
  #   terraform init \
  #     -backend-config="bucket=<your-tfstate-bucket>" \
  #     -backend-config="key=k8s-bootstrap-lab/dev/terraform.tfstate" \
  #     -backend-config="region=<your-region>"
  backend "s3" {}
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "k8s-bootstrap-lab"
    }
  }
}
