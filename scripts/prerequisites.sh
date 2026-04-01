#!/usr/bin/env bash
# prerequisites.sh — Check required tools are installed before bootstrapping.
# Fails fast with clear install hints so the user knows exactly what's missing.
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

ERRORS=()

check_tool() {
  local name="$1"
  local hint="$2"
  if ! command -v "$name" &>/dev/null; then
    ERRORS+=("  ✗ $name not found — $hint")
  else
    echo "  ✓ $name $(${name} version 2>/dev/null || ${name} --version 2>/dev/null || echo '(found)'  | head -1)"
  fi
}

# ── Checks ───────────────────────────────────────────────────────────────────

echo "→ Checking prerequisites..."

TARGET="${TARGET:-local}"

# ── Common tools (all targets) ────────────────────────────────────────────────

check_tool docker  "install Docker Desktop or Docker Engine: https://docs.docker.com/engine/install/"
check_tool kubectl "install: curl -LO https://dl.k8s.io/release/\$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl && sudo install kubectl /usr/local/bin/"
check_tool helm    "install: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
check_tool task    "install: sh -c \"\$(curl --location https://taskfile.dev/install.sh)\" -- -d -b /usr/local/bin"

# Docker daemon must be running
if command -v docker &>/dev/null; then
  if ! docker info &>/dev/null; then
    ERRORS+=("  ✗ Docker daemon is not running — start Docker and retry")
  fi
fi

# ── Local-only tools ──────────────────────────────────────────────────────────

if [[ "${TARGET}" == "local" ]]; then
  check_tool kind "install: go install sigs.k8s.io/kind@latest  OR  curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 && sudo install kind /usr/local/bin/"
fi

# ── AWS-only tools ────────────────────────────────────────────────────────────

if [[ "${TARGET}" == "aws" ]]; then
  check_tool terraform "install: https://developer.hashicorp.com/terraform/install"
  check_tool aws       "install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  check_tool jq        "install: sudo apt-get install -y jq  OR  brew install jq"
fi

# ── Result ───────────────────────────────────────────────────────────────────

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "✗ Prerequisites check failed. Install the following and retry:"
  for err in "${ERRORS[@]}"; do
    echo "$err"
  done
  exit 1
fi

echo "✓ All prerequisites satisfied."
