#!/usr/bin/env bash
# status.sh — Health check for all platform components.
# Exit 0 if everything is healthy, non-zero if any check fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/local.env"

FAILED=0

# ── Helpers ──────────────────────────────────────────────────────────────────

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILED=1; }

check_pods_ready() {
  local label="$1"
  local namespace="$2"
  local display="$3"

  local total ready
  total=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || true)

  if [[ "$total" -eq 0 ]]; then
    fail "$display — no pods found"
  elif [[ "$ready" -eq "$total" ]]; then
    ok "$display ($ready/$total pods running)"
  else
    fail "$display ($ready/$total pods running)"
  fi
}

# ── Kind cluster ─────────────────────────────────────────────────────────────

echo "→ Cluster"
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  ok "Kind cluster '${KIND_CLUSTER_NAME}' exists"
else
  fail "Kind cluster '${KIND_CLUSTER_NAME}' not found — run: task bootstrap"
  exit 1
fi

not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | wc -l || true)
if [[ "$not_ready" -eq 0 ]]; then
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  ok "All ${node_count} nodes Ready"
else
  fail "${not_ready} node(s) not Ready"
fi

# ── ArgoCD ───────────────────────────────────────────────────────────────────

echo ""
echo "→ ArgoCD"
check_pods_ready "app.kubernetes.io/name=argocd-server" "argocd" "argocd-server"
check_pods_ready "app.kubernetes.io/name=argocd-repo-server" "argocd" "argocd-repo-server"
check_pods_ready "app.kubernetes.io/name=argocd-application-controller" "argocd" "argocd-application-controller"

# App sync status
if command -v argocd &>/dev/null; then
  echo ""
  echo "→ ArgoCD Applications"
  argocd app list --server localhost:8080 --plaintext 2>/dev/null || \
    echo "  (argocd CLI not logged in — run: task argocd)"
fi

# ── ingress-nginx ─────────────────────────────────────────────────────────────

echo ""
echo "→ ingress-nginx"
check_pods_ready "app.kubernetes.io/name=ingress-nginx" "ingress-nginx" "ingress-nginx controller"

# ── Gitea ─────────────────────────────────────────────────────────────────────

echo ""
echo "→ Gitea"
check_pods_ready "app.kubernetes.io/name=gitea" "gitea" "gitea"
if kubectl get pods -n gitea -l "app.kubernetes.io/name=gitea" --no-headers 2>/dev/null | grep -q "Running"; then
  if curl -sf http://localhost:3000/api/v1/version &>/dev/null; then
    ok "Gitea API reachable (port-forward active)"
  else
    ok "Gitea running (no active port-forward — run: kubectl port-forward svc/gitea-http -n gitea 3000:3000)"
  fi
fi

# ── Monitoring ────────────────────────────────────────────────────────────────

echo ""
echo "→ Monitoring"
if kubectl get namespace monitoring &>/dev/null; then
  check_pods_ready "app.kubernetes.io/name=prometheus" "monitoring" "prometheus"
  check_pods_ready "app.kubernetes.io/name=grafana" "monitoring" "grafana"
  check_pods_ready "app.kubernetes.io/name=alertmanager" "monitoring" "alertmanager"
else
  echo "  (monitoring namespace not found — Phase 2 not yet deployed)"
fi

# ── Logging ───────────────────────────────────────────────────────────────────

echo ""
echo "→ Logging"
if kubectl get namespace logging &>/dev/null; then
  check_pods_ready "app.kubernetes.io/name=loki" "logging" "loki"
  check_pods_ready "app.kubernetes.io/name=promtail" "logging" "promtail"
else
  echo "  (logging namespace not found — Phase 2 not yet deployed)"
fi

# ── Security ──────────────────────────────────────────────────────────────────

echo ""
echo "→ Security"
if kubectl get namespace trivy-system &>/dev/null; then
  check_pods_ready "app.kubernetes.io/name=trivy-operator" "trivy-system" "trivy-operator"
else
  echo "  (trivy-system namespace not found — Phase 3 not yet deployed)"
fi

if kubectl get namespace falco &>/dev/null; then
  check_pods_ready "app.kubernetes.io/name=falco" "falco" "falco"
  check_pods_ready "app.kubernetes.io/name=falcosidekick" "falco" "falcosidekick"
else
  echo "  (falco namespace not found — Phase 3 not yet deployed)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "✓ Platform healthy."
else
  echo "✗ One or more checks failed."
  exit 1
fi
