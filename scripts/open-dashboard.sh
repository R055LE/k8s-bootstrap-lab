#!/usr/bin/env bash
# open-dashboard.sh — Print Grafana credentials and port-forward the UI.
set -euo pipefail

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

echo "→ Grafana credentials:"
echo "  user:     admin"
echo "  password: zero-to-cluster-local"
echo ""

if kubectl get ingress -n "${MONITORING_NAMESPACE}" 2>/dev/null | grep -q grafana; then
  echo "→ Grafana ingress is configured — try http://grafana.localhost"
  echo "  (Add '127.0.0.1 grafana.localhost' to /etc/hosts if not already there)"
  echo ""
fi

echo "→ Port-forwarding Grafana to http://localhost:3000 (Ctrl+C to stop)"
kubectl port-forward svc/kube-prometheus-stack-grafana -n "${MONITORING_NAMESPACE}" 3000:80
