#!/usr/bin/env bash
# setup-aws.sh — Provisions AWS EKS infrastructure and bootstraps the platform.
#
# Steps:
#   1. Validate prerequisites and AWS credentials
#   2. Terraform init / plan / apply  (VPC + EKS + IRSA + S3)
#   3. Update kubeconfig for the new cluster
#   4. Install Helm repos
#   5. Install ingress-nginx  (imperative — NLB prerequisite)
#   6. Install ArgoCD         (imperative — bootstraps GitOps engine)
#   7. Wait for ArgoCD
#   8. Apply app-of-apps-aws  (ArgoCD takes over from here)
#
# Usage: bash scripts/setup-aws.sh [--auto-approve]
#        (called by: task bootstrap TARGET=aws)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/dev"

AUTO_APPROVE="${1:-}"

# ── Load config ───────────────────────────────────────────────────────────────

AWS_ENV="${REPO_ROOT}/config/aws.env"
if [[ ! -f "${AWS_ENV}" ]]; then
  echo "✗ config/aws.env not found."
  echo "  Copy the example and fill in values:"
  echo "    cp config/aws.env.example config/aws.env"
  exit 1
fi

# shellcheck disable=SC1090 # aws.env path is dynamic, generated locally
set -a; source "${AWS_ENV}"; set +a

# ── Step 1: Validate prerequisites ───────────────────────────────────────────

echo ""
echo "═══ Step 1/8: Validate prerequisites ════════════════════════════════════"

for tool in terraform aws kubectl helm jq; do
  if ! command -v "${tool}" &>/dev/null; then
    echo "✗ ${tool} not found — install it and retry."
    exit 1
  fi
done

echo "→ Verifying AWS credentials (aws sts get-caller-identity)..."
if ! IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null); then
  echo "✗ AWS credentials not configured or invalid."
  echo "  Run: aws configure  OR  set AWS_PROFILE in config/aws.env"
  exit 1
fi
ACCOUNT_ID=$(echo "${IDENTITY}" | jq -r '.Account')
echo "✓ Authenticated as: $(echo "${IDENTITY}" | jq -r '.Arn')"

# ── Step 2: Terraform ─────────────────────────────────────────────────────────

echo ""
echo "═══ Step 2/8: Terraform ══════════════════════════════════════════════════"

if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
  echo "✗ TF_STATE_BUCKET not set in config/aws.env"
  echo "  Create it first: bash scripts/create-tf-state-bucket.sh"
  exit 1
fi

# Generate terraform.tfvars from aws.env values
cat > "${TF_DIR}/terraform.tfvars" <<EOF
aws_region          = "${AWS_REGION}"
aws_profile         = "${AWS_PROFILE:-default}"
cluster_name        = "${EKS_CLUSTER_NAME}"
kubernetes_version  = "1.31"
node_instance_type  = "t3.medium"
node_desired_count  = 2
node_min_count      = 1
node_max_count      = 3
loki_s3_bucket_name = "${EKS_CLUSTER_NAME}-loki-logs-${ACCOUNT_ID}"
EOF

echo "→ terraform init..."
terraform -chdir="${TF_DIR}" init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=k8s-bootstrap-lab/dev/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -reconfigure

echo "→ terraform plan..."
terraform -chdir="${TF_DIR}" plan -out="${TF_DIR}/tfplan"

if [[ "${AUTO_APPROVE}" != "--auto-approve" ]]; then
  echo ""
  read -rp "Apply the above plan? [yes/N] " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "→ terraform apply..."
terraform -chdir="${TF_DIR}" apply "${TF_DIR}/tfplan"

# Capture outputs and update aws.env
LOKI_S3_BUCKET_NAME=$(terraform -chdir="${TF_DIR}" output -raw loki_s3_bucket_name)
LOKI_IRSA_ROLE_ARN=$(terraform -chdir="${TF_DIR}" output -raw loki_irsa_role_arn)
TRIVY_IRSA_ROLE_ARN=$(terraform -chdir="${TF_DIR}" output -raw trivy_irsa_role_arn)

# Persist outputs to aws.env for idempotent re-runs
sed -i "s|^LOKI_S3_BUCKET_NAME=.*|LOKI_S3_BUCKET_NAME=${LOKI_S3_BUCKET_NAME}|" "${AWS_ENV}"
sed -i "s|^LOKI_IRSA_ROLE_ARN=.*|LOKI_IRSA_ROLE_ARN=${LOKI_IRSA_ROLE_ARN}|" "${AWS_ENV}"
sed -i "s|^TRIVY_IRSA_ROLE_ARN=.*|TRIVY_IRSA_ROLE_ARN=${TRIVY_IRSA_ROLE_ARN}|" "${AWS_ENV}"

echo "✓ Terraform apply complete."

# ── Step 3: Update kubeconfig ─────────────────────────────────────────────────

echo ""
echo "═══ Step 3/8: Update kubeconfig ══════════════════════════════════════════"

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER_NAME}" \
  --alias "${EKS_CLUSTER_NAME}"

echo -n "  Waiting for API server"
for i in $(seq 1 30); do
  if kubectl get nodes &>/dev/null; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 5
  [[ "$i" -eq 30 ]] && echo "" && echo "✗ Timed out waiting for EKS API server." && exit 1
done

echo "✓ kubectl context: ${EKS_CLUSTER_NAME}"

# ── Step 4: Helm repos ────────────────────────────────────────────────────────

echo ""
echo "═══ Step 4/8: Helm repos ═════════════════════════════════════════════════"

helm repo add argo           https://argoproj.github.io/argo-helm       2>/dev/null || true
helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
echo "✓ Helm repos ready."

# ── Step 5: ingress-nginx ─────────────────────────────────────────────────────

echo ""
echo "═══ Step 5/8: ingress-nginx ══════════════════════════════════════════════"

if helm status ingress-nginx -n "${INGRESS_NGINX_NAMESPACE}" &>/dev/null; then
  echo "  ingress-nginx already installed — skipping."
else
  echo "→ Installing ingress-nginx ${INGRESS_NGINX_CHART_VERSION} (LoadBalancer mode)..."
  kubectl create namespace "${INGRESS_NGINX_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NGINX_NAMESPACE}" \
    --version "${INGRESS_NGINX_CHART_VERSION}" \
    --values "${REPO_ROOT}/platform/ingress-nginx/values.yaml" \
    --values "${REPO_ROOT}/platform/ingress-nginx/values-aws.yaml" \
    --wait \
    --timeout 5m
  echo "✓ ingress-nginx installed."
fi

# Wait for NLB to be provisioned (external-ip populated)
echo -n "  Waiting for NLB external IP"
for i in $(seq 1 40); do
  EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NGINX_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${EXTERNAL_IP}" ]]; then
    echo " ready: ${EXTERNAL_IP}"
    break
  fi
  echo -n "."
  sleep 10
  [[ "$i" -eq 40 ]] && echo "" && echo "✗ NLB did not become ready. Check: kubectl get svc -n ${INGRESS_NGINX_NAMESPACE}" && exit 1
done

# ── Step 6: ArgoCD ────────────────────────────────────────────────────────────

echo ""
echo "═══ Step 6/8: ArgoCD ═════════════════════════════════════════════════════"

if helm status argocd -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  echo "  ArgoCD already installed — skipping."
else
  echo "→ Installing ArgoCD ${ARGOCD_CHART_VERSION}..."
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  helm install argocd argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --version "${ARGOCD_CHART_VERSION}" \
    --values "${REPO_ROOT}/platform/argocd/values.yaml" \
    --wait \
    --timeout 5m
  echo "✓ ArgoCD installed."
fi

# ── Step 7: Wait for ArgoCD ───────────────────────────────────────────────────

echo ""
echo "═══ Step 7/8: Wait for ArgoCD ════════════════════════════════════════════"

kubectl rollout status deployment/argocd-server      -n "${ARGOCD_NAMESPACE}" --timeout=120s
kubectl rollout status deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=120s
echo "✓ ArgoCD ready."

# ── Step 8: Apply app-of-apps ─────────────────────────────────────────────────

echo ""
echo "═══ Step 8/8: Apply app-of-apps ══════════════════════════════════════════"
echo "→ Applying root Application (GitHub → platform/apps-aws/)..."

export REPO_URL REPO_BRANCH AWS_REGION LOKI_S3_BUCKET_NAME LOKI_IRSA_ROLE_ARN TRIVY_IRSA_ROLE_ARN

envsubst < "${REPO_ROOT}/platform/app-of-apps-aws.yaml" | kubectl apply -f -

for app_file in "${REPO_ROOT}/platform/apps-aws/"*.yaml; do
  envsubst < "${app_file}" | kubectl apply -f -
done

echo "✓ Applications applied. ArgoCD is now syncing the platform."

# ── Done ──────────────────────────────────────────────────────────────────────

ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(secret not found)")

echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo "✓ Bootstrap complete!"
echo ""
echo "  ArgoCD is syncing the platform from: ${REPO_URL}"
echo "  Give it a few minutes, then check: task status TARGET=aws"
echo ""
echo "  ArgoCD access:"
echo "    task argocd TARGET=aws  — port-forward to localhost:8080"
echo "    user: admin  pass: ${ARGOCD_PASSWORD}"
echo ""
echo "  NLB hostname: ${EXTERNAL_IP:-run: kubectl get svc -n ${INGRESS_NGINX_NAMESPACE}}"
echo ""
echo "  Estimated cost: ~\$0.10/hr for EKS control plane + ~\$0.08/hr per t3.medium node"
echo "  Remember to tear down when done: task destroy TARGET=aws"
echo "══════════════════════════════════════════════════════════════════════════"
