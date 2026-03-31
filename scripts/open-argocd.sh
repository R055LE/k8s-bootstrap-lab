#!/usr/bin/env bash
# open-argocd.sh — Print the ArgoCD admin password and port-forward the UI.
# If the ArgoCD ingress is available at argocd.localhost, print that URL too.
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

echo "→ ArgoCD admin password:"
kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d && echo ""

# Check if ingress is reachable
if kubectl get ingress -n "${ARGOCD_NAMESPACE}" 2>/dev/null | grep -q argocd; then
  echo "→ ArgoCD ingress is configured — try http://argocd.localhost"
  echo "  (Add '127.0.0.1 argocd.localhost' to /etc/hosts if not already there)"
fi

echo ""
echo "→ Port-forwarding ArgoCD to http://localhost:8080 (Ctrl+C to stop)"
kubectl port-forward svc/argocd-server -n "${ARGOCD_NAMESPACE}" 8080:80
