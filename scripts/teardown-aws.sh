#!/usr/bin/env bash
# teardown-aws.sh — Destroys all AWS resources created by setup-aws.sh.
#
# Order matters:
#   1. Delete ArgoCD Applications — triggers cascade deletion of managed resources
#   2. Wait for LoadBalancer Services to be deleted by the cloud controller
#      (NLBs/target groups must be gone before terraform can delete the VPC)
#   3. Uninstall Helm releases installed imperatively
#   4. Terraform destroy — safe now that k8s-owned AWS resources are gone
#
# Usage: bash scripts/teardown-aws.sh [--auto-approve]
#        (called by: task destroy TARGET=aws)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/dev"

AUTO_APPROVE="${1:-}"

# ── Load config ───────────────────────────────────────────────────────────────

AWS_ENV="${REPO_ROOT}/config/aws.env"
if [[ ! -f "${AWS_ENV}" ]]; then
  echo "✗ config/aws.env not found — cannot determine cluster name."
  exit 1
fi

# shellcheck disable=SC1090 # aws.env path is dynamic, generated locally
set -a; source "${AWS_ENV}"; set +a

# ── Confirmation ──────────────────────────────────────────────────────────────

if [[ "${AUTO_APPROVE}" != "--auto-approve" ]]; then
  echo ""
  echo "⚠ This will permanently destroy all AWS resources:"
  echo "  EKS cluster: ${EKS_CLUSTER_NAME}"
  echo "  VPC, subnets, IAM roles, S3 bucket (${LOKI_S3_BUCKET_NAME:-<not set>})"
  echo ""
  read -rp "Type 'yes' to continue: " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Ensure we're pointing at the right cluster
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER_NAME}" \
  --alias "${EKS_CLUSTER_NAME}" 2>/dev/null || true

# ── Step 1: Delete ArgoCD Applications ───────────────────────────────────────

echo ""
echo "═══ Step 1/4: Delete ArgoCD Applications ════════════════════════════════"
echo "→ Deleting platform app-of-apps (cascade prunes all managed resources)..."

export REPO_URL REPO_BRANCH AWS_REGION LOKI_S3_BUCKET_NAME LOKI_IRSA_ROLE_ARN TRIVY_IRSA_ROLE_ARN

envsubst < "${REPO_ROOT}/platform/app-of-apps-aws.yaml" | kubectl delete -f - --ignore-not-found

for app_file in "${REPO_ROOT}/platform/apps-aws/"*.yaml; do
  envsubst < "${app_file}" | kubectl delete -f - --ignore-not-found
done

echo "✓ ArgoCD Applications deleted."

# ── Step 2: Wait for LoadBalancer Services to be removed ─────────────────────

echo ""
echo "═══ Step 2/4: Wait for LoadBalancer cleanup ══════════════════════════════"
echo "→ Waiting for cloud controller to delete NLBs..."

TIMEOUT=300
ELAPSED=0
while true; do
  LB_COUNT=$(kubectl get svc -A -o json 2>/dev/null \
    | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length' || echo "0")
  if [[ "${LB_COUNT}" -eq 0 ]]; then
    echo "✓ All LoadBalancer services removed."
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    echo "✗ Timed out waiting for LoadBalancer cleanup."
    echo "  Check: kubectl get svc -A | grep LoadBalancer"
    echo "  You may need to manually delete NLBs in the AWS console before terraform destroy."
    exit 1
  fi
  echo "  ${LB_COUNT} LoadBalancer service(s) still exist — waiting..."
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

# ── Step 3: Uninstall imperative Helm releases ────────────────────────────────

echo ""
echo "═══ Step 3/4: Uninstall Helm releases ════════════════════════════════════"

for release_ns in "argocd:${ARGOCD_NAMESPACE}" "ingress-nginx:${INGRESS_NGINX_NAMESPACE}"; do
  release="${release_ns%%:*}"
  ns="${release_ns##*:}"
  if helm status "${release}" -n "${ns}" &>/dev/null; then
    echo "→ Uninstalling ${release}..."
    helm uninstall "${release}" -n "${ns}" --wait --timeout 3m
    echo "✓ ${release} uninstalled."
  fi
done

# ── Step 4: Terraform destroy ─────────────────────────────────────────────────

echo ""
echo "═══ Step 4/4: Terraform destroy ══════════════════════════════════════════"

terraform -chdir="${TF_DIR}" init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=k8s-bootstrap-lab/dev/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -reconfigure

echo "→ terraform plan -destroy..."
terraform -chdir="${TF_DIR}" plan -destroy -out="${TF_DIR}/destroy.tfplan"

if [[ "${AUTO_APPROVE}" != "--auto-approve" ]]; then
  read -rp "Apply destroy plan? [yes/N] " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted. Plan saved to ${TF_DIR}/destroy.tfplan — apply manually with:"
    echo "  terraform -chdir=${TF_DIR} apply ${TF_DIR}/destroy.tfplan"
    exit 0
  fi
fi

terraform -chdir="${TF_DIR}" apply "${TF_DIR}/destroy.tfplan"

# Clean up local kubeconfig context
kubectl config delete-context "${EKS_CLUSTER_NAME}" 2>/dev/null || true

echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo "✓ All AWS resources destroyed."
echo ""
echo "  Tip: Check the AWS console for any orphaned resources:"
echo "    - EC2 → Load Balancers (NLBs not cleaned up by Kubernetes)"
echo "    - EC2 → Security Groups"
echo "    - S3 → ${TF_STATE_BUCKET} (Terraform state bucket — delete manually if done)"
echo "══════════════════════════════════════════════════════════════════════════"
