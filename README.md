# K8s Bootstrap Lab

A production-grade Kubernetes platform bootstrap for local development (Kind/WSL2) and AWS (EKS). Demonstrates end-to-end platform engineering: GitOps, observability, and runtime security — all managed declaratively.

```
┌─────────────────────────────────────────────────────────┐
│                  K8s Bootstrap Lab                      │
│                                                         │
│  Bootstrap ──► Gitea ──► ArgoCD ──► Platform Apps       │
│                                                         │
│  Phase 1: Kind + ingress-nginx + Gitea + ArgoCD         │
│  Phase 2: Prometheus + Grafana + Loki + Promtail        │
│  Phase 3: Trivy Operator + Falco + Falcosidekick        │
│  Phase 4: Terraform + AWS EKS                           │
└─────────────────────────────────────────────────────────┘
```

## Platform Components

| Component | Purpose | Version |
|---|---|---|
| [Kind](https://kind.sigs.k8s.io) | Local Kubernetes cluster (1 control-plane + 2 workers) | v1.35 |
| [ingress-nginx](https://kubernetes.github.io/ingress-nginx) | Ingress controller with hostPort | 4.11.3 |
| [Gitea](https://gitea.com) | In-cluster git server (GitOps source of truth) | 10.6.0 |
| [ArgoCD](https://argoproj.github.io/cd) | GitOps engine, app-of-apps pattern | 7.7.5 |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | Prometheus + Grafana + Alertmanager | 65.3.1 |
| [Loki](https://grafana.com/oss/loki) | Log aggregation (SingleBinary mode) | 6.16.0 |
| [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail) | Log shipping DaemonSet | 6.16.6 |
| [Trivy Operator](https://aquasecurity.github.io/trivy-operator) | Vulnerability scanning, CRD-based reports | 0.32.1 |
| [Falco](https://falco.org) + Falcosidekick | Runtime threat detection → Loki forwarding | 4.8.0 |

## Prerequisites

```bash
task prerequisites   # checks all tools and prints install hints
```

Required tools (all targets):

| Tool | Install |
|---|---|
| Docker Engine / Docker Desktop | [docs.docker.com/engine/install](https://docs.docker.com/engine/install/) |
| kubectl | `curl -LO https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl` |
| Helm | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| Task | `sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin` |

Additional tools for `TARGET=local`:

| Tool | Install |
|---|---|
| Kind | `curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 && sudo install kind /usr/local/bin/` |

Additional tools for `TARGET=aws`:

| Tool | Install |
|---|---|
| Terraform ≥ 1.6 | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| AWS CLI v2 | [docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| jq | `sudo apt-get install -y jq` |

**WSL2 users:** Apply the inotify limits before bootstrapping or Promtail will crash:

```bash
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=1048576
```

To make persistent, add to `/etc/sysctl.d/99-kind.conf` (requires WSL2 restart).

## Quick Start — Local (Kind)

```bash
# 1. Clone and bootstrap
git clone <this-repo> && cd k8s-bootstrap-lab
task bootstrap              # provisions Kind, Gitea, ArgoCD, and all platform apps

# 2. Add hosts entries for ingress
echo "127.0.0.1  argocd.localhost  gitea.localhost  grafana.localhost" | sudo tee -a /etc/hosts

# 3. Watch ArgoCD sync everything (takes ~3-5 minutes)
task status

# 4. Access services
task argocd      # port-forward + print credentials → http://localhost:8080
task dashboard   # port-forward + print credentials → http://localhost:3000
```

Credentials:
- **ArgoCD**: `admin` / printed by `task argocd` (from the `argocd-initial-admin-secret`)
- **Grafana**: `admin` / `zero-to-cluster-local`
- **Gitea**: `gitea-admin` / see `config/local.secrets.env`

Ingress (requires `/etc/hosts` entry above):
- ArgoCD → `http://argocd.localhost`
- Gitea → `http://gitea.localhost`
- Grafana → `http://grafana.localhost`

## Project Structure

```
.
├── Taskfile.yml              # All automation entry points
├── bootstrap/
│   ├── bootstrap.sh          # 8-step local bootstrap orchestrator
│   └── kind-config.yaml      # Kind cluster (1 control-plane + 2 workers)
├── config/
│   ├── local.env             # Non-secret config (chart versions, namespaces)
│   ├── local.secrets.env     # Generated on first run — gitignored
│   ├── aws.env.example       # AWS config template (copy to aws.env and fill in)
│   └── aws.env               # AWS config — gitignored
├── platform/
│   ├── app-of-apps.yaml      # Root ArgoCD Application (local)
│   ├── app-of-apps-aws.yaml  # Root ArgoCD Application (AWS, envsubst)
│   ├── apps/                 # ArgoCD Application manifests (local)
│   ├── apps-aws/             # ArgoCD Application manifests (AWS, envsubst)
│   ├── argocd/               # Umbrella Helm chart — wraps argo/argo-cd
│   ├── gitea/                # Umbrella Helm chart — wraps gitea-charts/gitea
│   ├── ingress-nginx/        # Umbrella chart — values-aws.yaml for NLB mode
│   ├── monitoring/           # Umbrella chart — kube-prometheus-stack + dashboards
│   ├── loki/                 # Umbrella chart — values-aws.yaml for S3 storage
│   ├── promtail/             # Umbrella chart — grafana/promtail
│   ├── trivy-operator/       # Umbrella chart — values-aws.yaml for IRSA
│   └── falco/                # Umbrella chart — values-aws.yaml for AL2 eBPF
├── terraform/
│   ├── modules/
│   │   ├── vpc/              # VPC, IGW, public subnets, EKS/NLB tags
│   │   ├── eks/              # IAM, EKS cluster, node group, OIDC provider
│   │   └── irsa/             # IRSA roles for Loki (S3) and Trivy (ECR)
│   └── environments/dev/     # Wires modules together, S3 bucket, outputs
├── scripts/
│   ├── prerequisites.sh      # Tool checks (kind for local, terraform/aws/jq for AWS)
│   ├── status.sh             # Platform health check
│   ├── open-argocd.sh        # Port-forward ArgoCD
│   ├── open-dashboard.sh     # Port-forward Grafana
│   ├── teardown-local.sh     # Delete Kind cluster
│   ├── create-tf-state-bucket.sh  # Create S3 backend bucket (once)
│   ├── setup-aws.sh          # 8-step EKS bootstrap
│   └── teardown-aws.sh       # Ordered EKS teardown
└── docs/
    └── troubleshooting.md    # Known issues and fixes
```

## Bootstrap Architecture

The bootstrap sequence handles the GitOps chicken-and-egg problem explicitly:

```
1. Kind cluster created
2. Helm repos added
3. ingress-nginx installed imperatively  ← must exist before Gitea ingress
4. Gitea installed imperatively          ← git server required by ArgoCD
5. Gitea initialised: repo created, code pushed
6. ArgoCD installed imperatively         ← needs Gitea to be reachable first
7. ArgoCD readiness wait
8. app-of-apps applied                   ← ArgoCD takes over from here
   └── syncs platform/apps/*.yaml
       └── each app syncs its platform/<component>/ chart
```

After step 8, all changes go through git: push to Gitea → ArgoCD detects → syncs to cluster.

## Umbrella Chart Pattern

Each platform component uses an umbrella (wrapper) chart:

```
platform/monitoring/
├── Chart.yaml        # depends on: kube-prometheus-stack
├── values.yaml       # nested under kube-prometheus-stack:
└── templates/        # extra resources (e.g. Grafana dashboard ConfigMaps)
```

This keeps all ArgoCD Applications as single-source (one git path, no multi-source complexity) while allowing extra resources (dashboards, extra secrets) to live alongside the values.

## Grafana Dashboards

Pre-deployed dashboards (auto-loaded via sidecar):

| Dashboard | Data Source | What it shows |
|---|---|---|
| Trivy — Vulnerability Reports | Prometheus | CRITICAL/HIGH/MEDIUM/LOW counts by image, filterable table |
| Falco — Security Events | Loki | Event rate by priority, full event log |

The Grafana sidecar detects ConfigMaps with `grafana_dashboard: "1"` label and loads them automatically.

## Observability Setup

```
Pods → Promtail (DaemonSet) → Loki → Grafana (Loki datasource pre-wired)
                                          ↑
Kubernetes → Prometheus (scrapes pods) → Grafana (Prometheus datasource)
                                          ↑
Falco → Falcosidekick → Loki ────────────┘
```

## Security Scanning

Trivy Operator runs as a controller, watching all workloads and scheduling scan jobs:

```bash
# Check scan results
kubectl get vulnerabilityreports -A
kubectl get configauditreports -A

# Quick summary (Prometheus metrics — also visible in Grafana)
kubectl get --raw /api/v1/namespaces/trivy-system/services/trivy-operator:80/proxy/metrics \
  | grep trivy_image_vulnerabilities | grep severity
```

## Known Limitations (WSL2 / Kind)

**Falco DaemonSet will not start on WSL2.** The `microsoft-standard-WSL2` kernel has no pre-built Falco eBPF probe, and compilation requires kernel headers and debugfs that are unavailable inside Kind containers.

What works locally:
- Falcosidekick (2 pods running) — Loki destination is wired and ready
- The Falco Grafana dashboard — deployed and will populate on EKS

This is expected. Falco works correctly on AWS EKS (Amazon Linux 2 nodes, Phase 4).

See [docs/troubleshooting.md](docs/troubleshooting.md) for a full list of issues encountered and their fixes.

## Quick Start — AWS (EKS)

**Estimated cost:** ~$0.10/hr (EKS control plane) + ~$0.08/hr per `t3.medium` node. Always destroy when done. See [docs/aws-testing.md](docs/aws-testing.md) for cost guardrails and a pre-flight checklist.

```bash
# 1. Copy and fill in config
cp config/aws.env.example config/aws.env
# Edit: AWS_REGION, EKS_CLUSTER_NAME, TF_STATE_BUCKET, REPO_URL, REPO_BRANCH

# 2. Create Terraform state bucket (once per AWS account/region)
task tf-state-bucket

# 3. Bootstrap — provisions VPC + EKS via Terraform, then bootstraps the platform
task bootstrap TARGET=aws

# 4. Watch platform sync
task status TARGET=aws

# 5. Access ArgoCD
task argocd TARGET=aws   # → http://localhost:8080
```

### AWS Architecture

```
VPC (2 public subnets, 2 AZs)
└── EKS 1.31 (managed node group, 2× t3.medium)
    ├── ingress-nginx       — AWS NLB (internet-facing)
    ├── ArgoCD              — GitOps from GitHub
    ├── kube-prometheus-stack
    ├── Loki                — logs to S3 (IRSA)
    ├── Promtail
    ├── Falco               — eBPF runtime detection (AL2 kernel)
    └── Trivy Operator      — pulls images via ECR (IRSA)
```

IRSA (IAM Roles for Service Accounts) is provisioned by Terraform — no static credentials in-cluster.

### Teardown

```bash
task destroy TARGET=aws  # deletes ArgoCD apps → waits for NLB cleanup → terraform destroy
```

**Important:** The Terraform state bucket (`TF_STATE_BUCKET`) is not deleted by teardown — delete it manually from the AWS console when you're fully done.

## Teardown — Local

```bash
task destroy             # deletes the Kind cluster (all data lost)
```

## Roadmap

- [x] Phase 1 — Local foundation (Kind, ingress-nginx, Gitea, ArgoCD)
- [x] Phase 2 — Observability (Prometheus, Grafana, Loki, Promtail)
- [x] Phase 3 — Security (Trivy Operator, Falco + Falcosidekick)
- [x] Phase 4 — AWS EKS (Terraform: VPC, EKS, IAM/IRSA, EKS-specific overlays)
- [ ] Phase 5 — Sample app, architecture diagrams, portfolio polish
  - Deploy a real workload that exercises the full stack (Trivy reports, Falco events, logs)
  - Architecture diagrams for local and AWS topologies
  - General cleanup and portfolio presentation
