#!/usr/bin/env bash
# create-tf-state-bucket.sh — Creates the S3 bucket used for Terraform state.
# Run this once before running: task bootstrap TARGET=aws
#
# The bucket must exist before terraform init can run, which is why Terraform
# cannot manage it. Once created, the bucket is durable — do not delete it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AWS_ENV="${REPO_ROOT}/config/aws.env"
if [[ ! -f "${AWS_ENV}" ]]; then
  echo "✗ config/aws.env not found."
  echo "  Copy the example and fill in values:"
  echo "    cp config/aws.env.example config/aws.env"
  exit 1
fi

# shellcheck disable=SC1090 # aws.env path is dynamic, generated locally
set -a; source "${AWS_ENV}"; set +a

if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
  echo "✗ TF_STATE_BUCKET is not set in config/aws.env"
  exit 1
fi

echo "→ Creating Terraform state bucket: ${TF_STATE_BUCKET}"

if aws s3api head-bucket --bucket "${TF_STATE_BUCKET}" --region "${AWS_REGION}" &>/dev/null; then
  echo "  Bucket already exists — skipping."
  exit 0
fi

aws s3api create-bucket \
  --bucket "${TF_STATE_BUCKET}" \
  --region "${AWS_REGION}" \
  $([ "${AWS_REGION}" != "us-east-1" ] && echo "--create-bucket-configuration" "LocationConstraint=${AWS_REGION}")

aws s3api put-bucket-versioning \
  --bucket "${TF_STATE_BUCKET}" \
  --versioning-configuration Status=Enabled \
  --region "${AWS_REGION}"

aws s3api put-public-access-block \
  --bucket "${TF_STATE_BUCKET}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region "${AWS_REGION}"

echo "✓ Terraform state bucket created: s3://${TF_STATE_BUCKET}"
echo "  Versioning enabled. Do not delete this bucket."
