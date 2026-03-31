# K8s Bootstrap Platform — zero-to-cluster

## Project Overview

A hybrid Kubernetes platform bootstrap tool. One command creates a fully configured cluster with GitOps (ArgoCD), observability (Prometheus/Grafana/Loki), and security scanning (Trivy/Falco). Runs locally on Kind or deploys to AWS EKS via Terraform.

Full design doc: @k8s-bootstrap-design-doc.md

## Environment

- Development: WSL2 (Ubuntu 24.04) on Windows
- Local cluster: Kind (Kubernetes in Docker)
- Cloud target: AWS EKS
- All scripts assume bash

## Code Style

### Terraform
- snake_case for all resource names, variables, outputs
- One resource per logical concern — don't cram unrelated resources into one file
- Always use variables for anything environment-specific, never hardcode
- Include descriptions on all variables
- Tag all AWS resources with `Project = "zero-to-cluster"` and `ManagedBy = "terraform"`
- Use `terraform fmt` before committing

### Bash Scripts
- Set `set -euo pipefail` at the top of every script
- Use functions for logical grouping
- Print clear status messages: `echo "→ Creating Kind cluster..."`
- Check prerequisites before doing anything — fail fast with helpful errors
- Scripts must be idempotent — running twice shouldn't break anything

### Helm Values
- Use YAML comments to explain non-obvious config choices
- Pin chart versions in Chart.yaml, never use floating tags
- Separate values files per environment where needed, prefer overlays over duplication

### Makefile
- Targets should be self-documenting with comments
- Include a `help` target that lists available commands
- All targets should work with `TARGET=local` (default) or `TARGET=aws`

## Architecture Rules

- ArgoCD app-of-apps pattern — one root Application, everything else is managed
- Platform components go in `platform/` as individual Helm chart wrappers
- Scripts go in `scripts/` — one script per logical operation
- Terraform goes in `terraform/` — modularized by resource group
- The `platform/` directory must be target-agnostic. Environment differences handled by value overrides only.
- No manual kubectl apply in the steady state — everything through ArgoCD after bootstrap

## Implementation Phases

Build in order. Do not skip ahead.

### Phase 1 — Local Foundation
Makefile, prerequisites check, Kind cluster, ArgoCD install, app-of-apps pattern.
Verify: `make bootstrap` creates a cluster with ArgoCD running and syncing.

### Phase 2 — Observability
kube-prometheus-stack, Grafana dashboards, Loki + Promtail, `make dashboard`.
Verify: metrics in Grafana, logs queryable in Loki.

### Phase 3 — Security
Trivy Operator, Falco, scan results in Grafana, alerts in Loki.
Verify: vulnerable image gets flagged, Falco detects suspicious activity.

### Phase 4 — AWS Target
Terraform modules (VPC, EKS, IAM/IRSA), EKS value overlays, `make bootstrap TARGET=aws`.
Verify: identical platform on real AWS infrastructure.

### Phase 5 — Documentation
Architecture diagrams, README, component docs, sample app.

## Testing

- `make status` should report health of every component
- After any change to platform/, verify ArgoCD syncs cleanly
- Test teardown after every bootstrap — `make destroy` should leave nothing behind
- For Terraform: `terraform plan` before `terraform apply`, always

## Common Mistakes to Avoid

- Do NOT hardcode namespace names in manifests — use Helm chart values
- Do NOT use `latest` tags for any image or chart version
- Do NOT put secrets in git — use placeholder values with clear documentation
- Do NOT create AWS resources without corresponding teardown logic
- Do NOT assume tools are installed — always check in prerequisites.sh
- Do NOT use NodePort for production-facing services on AWS — use LoadBalancer or Ingress

## Git Workflow

- Commit after each working milestone
- Commit messages: imperative mood, under 72 chars
- Never commit .terraform/ directories or tfstate files
- Add terraform.tfstate* and .terraform/ to .gitignore immediately

## Tone

This is a portfolio project that should look like it could be used in production. Clean structure, documented decisions, professional Terraform style. But don't over-engineer — this is a one-person project proving capability, not an enterprise platform team deliverable.
