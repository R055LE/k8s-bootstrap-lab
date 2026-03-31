#!/usr/bin/env bash
# teardown-local.sh — Delete the local Kind cluster.
# Idempotent: safe to run even if the cluster doesn't exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/local.env"

echo "→ Deleting Kind cluster '${KIND_CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
  echo "✓ Cluster '${KIND_CLUSTER_NAME}' deleted."
else
  echo "  Cluster '${KIND_CLUSTER_NAME}' does not exist — nothing to do."
fi
