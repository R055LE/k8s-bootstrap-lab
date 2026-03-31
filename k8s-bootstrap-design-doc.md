# K8s Bootstrap Platform — Design Document

**Working title:** `zero-to-cluster` (or whatever lands)
**Purpose:** Portfolio project demonstrating end-to-end Kubernetes platform engineering
**Scope:** Hybrid — develops locally on Kind, deploys to AWS EKS with Terraform
**Approach:** Claude Code handles the majority of implementation

---

## What This Is

A single repository that bootstraps a production-ready Kubernetes platform from nothing. Run one command locally to get a fully configured cluster with GitOps, observability, and security scanning. Swap a config flag and the same tooling targets a real AWS EKS cluster.

This is the repo version of "I walk into environments with no documentation, no CI/CD, and no observability, and I leave behind infrastructure that actually works."

---

## Core Stack

| Layer | Tool | Why |
|-------|------|-----|
| Local cluster | Kind (Kubernetes in Docker) | Free, fast, runs in WSL |
| Cloud cluster | AWS EKS via Terraform | Real-world target |
| GitOps | ArgoCD | Declarative deploys, self-healing |
| Monitoring | Prometheus + Grafana | Metrics collection + dashboards |
| Logging | Loki + Promtail | Log aggregation without Elasticsearch overhead |
| Vulnerability scanning | Trivy | Image and config scanning |
| Runtime security | Falco | Threat detection at runtime |
| IaC | Terraform | AWS infrastructure provisioning |
| Configuration | Helm charts + Kustomize overlays | Per-environment config |
| Automation | Makefile + bash scripts | Single-command operations |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Developer Machine                       │
│                                                              │
│  make bootstrap TARGET=local     make bootstrap TARGET=aws   │
│         │                                │                   │
│         ▼                                ▼                   │
│  ┌─────────────┐                 ┌──────────────┐            │
│  │ Kind Cluster │                 │ Terraform    │            │
│  │ (WSL/Docker) │                 │ → EKS Cluster│            │
│  └──────┬──────┘                 └──────┬───────┘            │
│         │                                │                   │
│         └──────────┬─────────────────────┘                   │
│                    ▼                                         │
│           ┌────────────────┐                                 │
│           │    ArgoCD      │                                 │
│           │  (bootstraps   │                                 │
│           │   itself +     │                                 │
│           │   all apps)    │                                 │
│           └───────┬────────┘                                 │
│                   │                                          │
│                   ▼                                          │
│    ┌──────────────────────────────────┐                      │
│    │        Platform Apps             │                      │
│    │                                  │                      │
│    │  ┌────────────┐ ┌─────────────┐  │                      │
│    │  │ Prometheus  │ │    Loki     │  │                      │
│    │  │ + Grafana   │ │ + Promtail  │  │                      │
│    │  └────────────┘ └─────────────┘  │                      │
│    │                                  │                      │
│    │  ┌────────────┐ ┌─────────────┐  │                      │
│    │  │   Trivy    │ │   Falco     │  │                      │
│    │  │  Operator  │ │             │  │                      │
│    │  └────────────┘ └─────────────┘  │                      │
│    │                                  │                      │
│    │  ┌────────────────────────────┐  │                      │
│    │  │   Sample App (optional)    │  │                      │
│    │  │   proves the stack works   │  │                      │
│    │  └────────────────────────────┘  │                      │
│    └──────────────────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
zero-to-cluster/
├── Makefile                    # Entry point — make bootstrap, make destroy, make status
├── README.md
├── CLAUDE.md                   # Claude Code project context
├── config/
│   ├── local.env               # Kind-specific overrides
│   └── aws.env                 # AWS-specific overrides (region, cluster name, etc.)
├── terraform/
│   ├── main.tf                 # EKS cluster, VPC, IAM
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── modules/
│       ├── vpc/
│       ├── eks/
│       └── iam/
├── bootstrap/
│   ├── kind-config.yaml        # Kind cluster definition
│   ├── argocd-install.yaml     # ArgoCD bootstrap manifest
│   └── bootstrap.sh            # Orchestrates the full setup
├── platform/                   # ArgoCD Application manifests (app of apps)
│   ├── app-of-apps.yaml        # Root ArgoCD Application
│   ├── argocd/
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── monitoring/
│   │   ├── Chart.yaml          # kube-prometheus-stack umbrella
│   │   ├── values.yaml         # Grafana dashboards, retention, scrape configs
│   │   └── dashboards/         # Custom Grafana dashboard JSON
│   ├── logging/
│   │   ├── Chart.yaml          # Loki + Promtail
│   │   └── values.yaml
│   ├── security/
│   │   ├── trivy/
│   │   │   ├── Chart.yaml
│   │   │   └── values.yaml
│   │   └── falco/
│   │       ├── Chart.yaml
│   │       └── values.yaml
│   └── sample-app/             # Optional: simple app to prove the stack works
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
├── scripts/
│   ├── prerequisites.sh        # Check for required tools (docker, kubectl, helm, terraform)
│   ├── setup-local.sh          # Kind cluster creation + kubeconfig
│   ├── setup-aws.sh            # Terraform apply + kubeconfig
│   ├── teardown-local.sh
│   ├── teardown-aws.sh
│   └── status.sh               # Health check across all components
└── docs/
    ├── architecture.md         # Detailed architecture decisions
    ├── local-quickstart.md
    ├── aws-deployment.md
    └── adding-apps.md          # How to add your own apps to the platform
```

---

## Core Workflow

### Local Bootstrap

```bash
# One command — creates Kind cluster, installs ArgoCD, syncs all platform apps
make bootstrap TARGET=local

# Check everything is healthy
make status

# Access dashboards
make dashboard          # Opens Grafana in browser
make argocd             # Opens ArgoCD UI in browser

# Tear it all down
make destroy TARGET=local
```

### AWS Bootstrap

```bash
# Requires AWS credentials configured
export AWS_PROFILE=your-profile

# Provisions EKS + bootstraps the full platform
make bootstrap TARGET=aws

# Same commands work regardless of target
make status
make dashboard
make argocd

# Tear down (destroys all AWS resources)
make destroy TARGET=aws
```

---

## Implementation Phases

### Phase 1 — Local Foundation
1. Makefile skeleton with TARGET switching
2. prerequisites.sh — verify docker, kubectl, helm, kind are installed
3. Kind cluster creation with config (multi-node: 1 control plane, 2 workers)
4. ArgoCD installation via manifest + CLI bootstrap
5. App-of-apps pattern — root Application that manages all platform apps
6. Verify: `make bootstrap TARGET=local` creates cluster with ArgoCD running

### Phase 2 — Observability Stack
7. kube-prometheus-stack Helm chart (Prometheus + Grafana)
8. Custom Grafana dashboards — cluster overview, pod resources, node health
9. Loki + Promtail for log aggregation
10. Grafana datasource for Loki (logs queryable alongside metrics)
11. `make dashboard` opens Grafana with port-forward
12. Verify: metrics flowing, logs queryable, dashboards populated

### Phase 3 — Security Layer
13. Trivy Operator — automatic vulnerability scanning of all images in cluster
14. Trivy CRDs visible in Grafana (scan results dashboard)
15. Falco — runtime threat detection with default ruleset
16. Falco alerts forwarded to Loki (security events in same logging pipeline)
17. Verify: deploy a known-vulnerable image, see Trivy flag it, see Falco detect suspicious activity

### Phase 4 — AWS Target
18. Terraform modules — VPC, EKS, IAM roles for service accounts (IRSA)
19. EKS-specific values overlays for all Helm charts
20. setup-aws.sh — terraform apply + kubeconfig merge + ArgoCD bootstrap
21. teardown-aws.sh — ArgoCD cleanup + terraform destroy
22. Verify: `make bootstrap TARGET=aws` produces identical platform on real infrastructure

### Phase 5 — Documentation and Polish
23. Architecture diagram (Mermaid or SVG in docs/)
24. README with quickstart, screenshots of dashboards
25. docs/ for each component explaining decisions
26. Sample app deployment to prove the stack works end-to-end
27. `make status` with colored output showing health of each component

---

## ArgoCD App-of-Apps Pattern

ArgoCD manages itself and all platform components. The bootstrap script installs ArgoCD minimally, then applies a single root Application that points to the `platform/` directory. ArgoCD then syncs everything else automatically.

```yaml
# platform/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/R055LE/zero-to-cluster.git
    path: platform
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

This means:
- Adding a new platform component = adding a directory under `platform/` and pushing to main
- ArgoCD detects the change and syncs it automatically
- Self-healing: if someone manually deletes something, ArgoCD restores it

---

## Helm Chart Versions (Pin These)

| Chart | Version | Notes |
|-------|---------|-------|
| argo-cd | latest stable | ArgoCD Helm chart from argoproj |
| kube-prometheus-stack | latest stable | Includes Prometheus, Grafana, Alertmanager |
| loki | latest stable | Grafana Loki (simple scalable mode for local) |
| promtail | latest stable | Log shipper to Loki |
| trivy-operator | latest stable | Aqua Security |
| falco | latest stable | Falcosecurity |

Pin exact versions in Chart.yaml once initial setup is working. Don't use `latest` in production configs.

---

## Grafana Dashboards

Include at minimum:
- **Cluster Overview** — node count, pod count, resource utilization
- **Pod Resources** — CPU/memory requests vs limits vs actual usage
- **ArgoCD Sync Status** — application health at a glance
- **Trivy Scan Results** — vulnerability counts by severity
- **Falco Alerts** — runtime security events timeline
- **Loki Logs Explorer** — pre-configured for namespace/pod filtering

---

## Terraform (AWS)

### Resources Created
- VPC with public/private subnets across 2 AZs
- EKS cluster (1.29+) with managed node group (2x t3.medium)
- IAM roles for service accounts (IRSA) for ArgoCD, Prometheus, Loki
- Security groups — minimal, locked down
- No NAT Gateway in default config (costs $30+/month) — use public subnets for the demo, document the production upgrade path

### Cost Estimate
- EKS control plane: ~$0.10/hr ($72/month)
- 2x t3.medium nodes: ~$0.08/hr ($60/month)
- Total running: ~$130/month
- With teardown after testing: < $5 per session

---

## What This Demonstrates to a Hiring Manager

- **IaC fluency** — Terraform modules with proper variable/output structure
- **Kubernetes orchestration** — multi-component platform, not just a deployment
- **GitOps** — ArgoCD app-of-apps, self-healing, declarative everything
- **Observability** — full metrics + logging stack, custom dashboards
- **Security posture** — vulnerability scanning + runtime detection, not just "we'll add security later"
- **Operational maturity** — Makefile-driven workflow, prerequisite checks, health status, clean teardown
- **Documentation** — architecture decisions explained, not just "here's the code"

---

## Notes for Claude Code

- Start with Phase 1. Get the local Kind bootstrap working before touching AWS.
- Use well-known Helm charts — don't reinvent anything. The value is in the integration, not the individual components.
- Makefile targets should be idempotent — running `make bootstrap` twice shouldn't break anything.
- All scripts should check prerequisites before running and fail with clear error messages.
- Keep Terraform modules small and focused. One module per logical resource group.
- Test the local path thoroughly before writing any Terraform. The platform/ directory should be identical between local and AWS — only the cluster creation differs.
- Use kustomize overlays or Helm value overrides for environment-specific differences, never if/else in manifests.
- Pin Helm chart versions after initial setup. Search for current stable versions before pinning.

---

## Stretch Goals (If the Core is Solid)

- **Vault integration** — secrets management with CSI driver
- **Kyverno** — policy enforcement (pod security, image registry restrictions)
- **External DNS + cert-manager** — automatic DNS and TLS (requires a domain)
- **Backstage** — developer portal / service catalog
- **Multi-cluster** — bootstrap a second cluster and federate monitoring
- **CI pipeline** — GitHub Actions that runs `make bootstrap TARGET=local` as integration test
