#!/usr/bin/env bash
# bootstrap.sh — Orchestrates the full local platform bootstrap.
#
# Steps:
#   1. Kind cluster
#   2. Helm repos
#   3. ingress-nginx  (imperative — prerequisite for all ingress)
#   4. Gitea          (imperative — git server, prerequisite for ArgoCD)
#   5. Gitea init     (create repo, push code)
#   6. ArgoCD         (imperative — bootstraps the GitOps engine)
#   7. Wait for ArgoCD
#   8. Apply app-of-apps (ArgoCD takes over from here)
#
# After step 8, ArgoCD syncs platform/apps/ from Gitea and manages everything.
#
# Usage: bash bootstrap/bootstrap.sh
#        (called by: task bootstrap)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/config/local.env"

# Load secrets if they exist (generated on first run)
SECRETS_FILE="${REPO_ROOT}/config/local.secrets.env"
if [[ -f "${SECRETS_FILE}" ]]; then
  source "${SECRETS_FILE}"
fi

# ── Step 1: Kind cluster ──────────────────────────────────────────────────────

echo ""
echo "═══ Step 1/8: Kind cluster ═══════════════════════════════════════════════"

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  echo "  Cluster '${KIND_CLUSTER_NAME}' already exists — skipping."
else
  echo "→ Creating Kind cluster '${KIND_CLUSTER_NAME}'..."
  kind create cluster \
    --name "${KIND_CLUSTER_NAME}" \
    --config "${SCRIPT_DIR}/kind-config.yaml" \
    --wait 120s
  echo "✓ Kind cluster created."
fi

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}" >/dev/null
echo "✓ kubectl context: kind-${KIND_CLUSTER_NAME}"

# ── Step 2: Helm repos ────────────────────────────────────────────────────────

echo ""
echo "═══ Step 2/8: Helm repos ═════════════════════════════════════════════════"

helm repo add argo           https://argoproj.github.io/argo-helm       2>/dev/null || true
helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add gitea-charts   https://dl.gitea.com/charts/               2>/dev/null || true
helm repo update
echo "✓ Helm repos ready."

# ── Step 3: ingress-nginx ─────────────────────────────────────────────────────

echo ""
echo "═══ Step 3/8: ingress-nginx ══════════════════════════════════════════════"

if helm status ingress-nginx -n "${INGRESS_NGINX_NAMESPACE}" &>/dev/null; then
  echo "  ingress-nginx already installed — skipping."
else
  echo "→ Installing ingress-nginx ${INGRESS_NGINX_CHART_VERSION}..."
  kubectl create namespace "${INGRESS_NGINX_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NGINX_NAMESPACE}" \
    --version "${INGRESS_NGINX_CHART_VERSION}" \
    --values "${REPO_ROOT}/platform/ingress-nginx/values.yaml" \
    --wait \
    --timeout 5m
  echo "✓ ingress-nginx installed."
fi

# ── Step 4: Gitea ─────────────────────────────────────────────────────────────

echo ""
echo "═══ Step 4/8: Gitea ══════════════════════════════════════════════════════"

# Generate admin password on first run, save to secrets file
if [[ -z "${GITEA_ADMIN_PASSWORD:-}" ]]; then
  GITEA_ADMIN_PASSWORD=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 24)
  echo "GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD}" >> "${SECRETS_FILE}"
  echo "  Generated Gitea admin password → config/local.secrets.env"
fi

if helm status gitea -n "${GITEA_NAMESPACE}" &>/dev/null; then
  echo "  Gitea already installed — skipping."
else
  echo "→ Installing Gitea ${GITEA_CHART_VERSION}..."
  kubectl create namespace "${GITEA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  # Store admin credentials in a k8s secret (avoids password appearing in helm history)
  kubectl create secret generic gitea-admin-secret \
    --namespace "${GITEA_NAMESPACE}" \
    --from-literal=username="${GITEA_ADMIN_USER}" \
    --from-literal=password="${GITEA_ADMIN_PASSWORD}" \
    --from-literal=email="admin@gitea.localhost" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm install gitea gitea-charts/gitea \
    --namespace "${GITEA_NAMESPACE}" \
    --version "${GITEA_CHART_VERSION}" \
    --values "${REPO_ROOT}/platform/gitea/values.yaml" \
    --wait \
    --timeout 5m
  echo "✓ Gitea installed."
fi

# ── Step 5: Gitea init ────────────────────────────────────────────────────────

echo ""
echo "═══ Step 5/8: Gitea init ═════════════════════════════════════════════════"

# Port-forward Gitea for local API access during bootstrap
echo "→ Port-forwarding Gitea to localhost:3000..."
kubectl port-forward svc/gitea-http -n "${GITEA_NAMESPACE}" 3000:3000 &>/dev/null &
GITEA_PF_PID=$!
cleanup() { kill "${GITEA_PF_PID}" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for Gitea HTTP to respond
GITEA_LOCAL_URL="http://localhost:3000"
echo -n "  Waiting for Gitea API"
for i in $(seq 1 30); do
  if curl -sf "${GITEA_LOCAL_URL}/api/v1/version" &>/dev/null; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 3
  if [[ "$i" -eq 30 ]]; then
    echo ""
    echo "✗ Gitea did not become ready in time. Check: kubectl logs -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea"
    exit 1
  fi
done

# Create the repo (idempotent — 409 Conflict means it already exists)
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${GITEA_LOCAL_URL}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${GITEA_REPO_NAME}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}")

if [[ "${HTTP_STATUS}" == "201" ]]; then
  echo "✓ Repository '${GITEA_REPO_NAME}' created."
elif [[ "${HTTP_STATUS}" == "409" ]]; then
  echo "  Repository '${GITEA_REPO_NAME}' already exists — skipping."
else
  echo "✗ Failed to create repository (HTTP ${HTTP_STATUS})."
  exit 1
fi

# Push the repo
GITEA_REMOTE="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}@localhost:3000/${GITEA_ADMIN_USER}/${GITEA_REPO_NAME}.git"

cd "${REPO_ROOT}"

if [[ ! -d ".git" ]]; then
  echo "→ Initialising git repository..."
  git init
  git config user.email "bootstrap@zero-to-cluster.local"
  git config user.name "zero-to-cluster bootstrap"
  git checkout -b main
fi

# Stage everything (excluding gitignored files)
git add .
if git diff --cached --quiet; then
  echo "  Nothing new to commit — skipping."
else
  git commit -m "bootstrap: Phase 1 platform foundation"
  echo "✓ Committed."
fi

# Add/update remote and push
if git remote get-url origin &>/dev/null; then
  git remote set-url origin "${GITEA_REMOTE}"
else
  git remote add origin "${GITEA_REMOTE}"
fi

git push -u origin main --force-with-lease 2>/dev/null || git push -u origin main --force
echo "✓ Code pushed to Gitea."

# Stop port-forward — no longer needed
kill "${GITEA_PF_PID}" 2>/dev/null || true
trap - EXIT

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
echo "→ Applying Applications (repo: ${REPO_URL}, branch: ${REPO_BRANCH})..."

export REPO_URL REPO_BRANCH

# Root app-of-apps
envsubst '${REPO_URL} ${REPO_BRANCH}' \
  < "${REPO_ROOT}/platform/app-of-apps.yaml" \
  | kubectl apply -f -

# Child Application manifests (multi-source $values refs need REPO_URL injected)
for app_file in "${REPO_ROOT}/platform/apps/"*.yaml; do
  envsubst '${REPO_URL} ${REPO_BRANCH}' < "${app_file}" | kubectl apply -f -
done

echo "✓ Applications applied. ArgoCD is now syncing the platform."

# ── Done ─────────────────────────────────────────────────────────────────────

ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(secret not found)")

echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo "✓ Bootstrap complete!"
echo ""
echo "  ArgoCD is syncing the platform. Give it a few minutes."
echo ""
echo "  Add to /etc/hosts for ingress access:"
echo "    127.0.0.1  argocd.localhost  gitea.localhost"
echo ""
echo "  ArgoCD  → http://argocd.localhost  (user: admin  pass: ${ARGOCD_PASSWORD})"
echo "  Gitea   → http://gitea.localhost   (user: ${GITEA_ADMIN_USER}  pass: in config/local.secrets.env)"
echo ""
echo "  Commands:"
echo "    task status   — check component health"
echo "    task argocd   — port-forward ArgoCD UI"
echo "══════════════════════════════════════════════════════════════════════════"
