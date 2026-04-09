# Architecture

This document describes the platform architecture for both the local (Kind) and AWS (EKS) targets, the data flows between components, and the key design decisions.

## Bootstrap Sequence

The bootstrap script solves the GitOps chicken-and-egg problem by installing foundational components imperatively, then handing control to ArgoCD:

```mermaid
flowchart TD
    A[task bootstrap] --> B[Create cluster<br>Kind or EKS via Terraform]
    B --> C[Add Helm repos]
    C --> D[Install ingress-nginx<br>imperatively]
    D --> E[Install Gitea<br>imperatively]
    E --> F[Initialize Gitea<br>create repo, push code]
    F --> G[Install ArgoCD<br>imperatively]
    G --> H[Wait for ArgoCD readiness]
    H --> I[Apply app-of-apps]
    I --> J[ArgoCD takes over]

    J --> K[kube-prometheus-stack]
    J --> L[Loki]
    J --> M[Promtail]
    J --> N[Trivy Operator]
    J --> O[Falco + Falcosidekick]
    J --> P[Sample App]

    style A fill:#2d6a4f,color:#fff
    style I fill:#e76f51,color:#fff
    style J fill:#e76f51,color:#fff
```

After the app-of-apps is applied (step 8), all changes flow through git: push to Gitea (local) or GitHub (AWS) and ArgoCD syncs to the cluster.

## Local Architecture (Kind)

```mermaid
graph TB
    subgraph WSL2["WSL2 / Docker"]
        subgraph Kind["Kind Cluster (1 CP + 2 Workers)"]
            subgraph ingress["Ingress Layer"]
                NGINX[ingress-nginx<br>hostPort 80/443]
            end

            subgraph gitops["GitOps"]
                Gitea[Gitea<br>in-cluster git server]
                ArgoCD[ArgoCD<br>app-of-apps]
            end

            subgraph observability["Observability"]
                Prom[Prometheus]
                Grafana[Grafana]
                Loki[Loki<br>SingleBinary]
                Promtail[Promtail<br>DaemonSet]
            end

            subgraph security["Security"]
                Trivy[Trivy Operator]
                Falco[Falco<br>eBPF ⚠️ WSL2]
                Sidekick[Falcosidekick]
            end

            subgraph workload["Workload"]
                App[Sample App<br>nginx 1.21.6]
            end
        end
    end

    Developer -->|git push| Gitea
    Gitea -->|sync| ArgoCD
    NGINX -->|route| Grafana
    NGINX -->|route| Gitea
    NGINX -->|route| App

    Promtail -->|ship logs| Loki
    Loki -->|datasource| Grafana
    Prom -->|datasource| Grafana
    Sidekick -->|forward alerts| Loki
    Trivy -->|scan metrics| Prom
```

**Key local details:**
- Kind maps container ports 80/443 to the host via `hostPort` on ingress-nginx
- All services accessible via `*.localhost` hostnames (requires `/etc/hosts` entries)
- Gitea serves as the in-cluster git remote — ArgoCD pulls from `gitea-http.gitea.svc.cluster.local`
- Falco DaemonSet will not start on WSL2 (no kernel probe) — Falcosidekick is still deployed and ready

## AWS Architecture (EKS)

```mermaid
graph TB
    subgraph AWS["AWS Account"]
        subgraph VPC["VPC (2 public subnets, 2 AZs)"]
            NLB[Network Load Balancer<br>internet-facing]

            subgraph EKS["EKS 1.31 (2× t3.medium managed nodes)"]
                subgraph ingress["Ingress Layer"]
                    NGINX[ingress-nginx<br>AWS NLB mode]
                end

                subgraph gitops["GitOps"]
                    ArgoCD[ArgoCD<br>syncs from GitHub]
                end

                subgraph observability["Observability"]
                    Prom[Prometheus]
                    Grafana[Grafana]
                    Loki[Loki<br>S3 storage via IRSA]
                    Promtail[Promtail<br>DaemonSet]
                end

                subgraph security["Security"]
                    Trivy[Trivy Operator<br>ECR access via IRSA]
                    Falco[Falco<br>eBPF on AL2 kernel]
                    Sidekick[Falcosidekick]
                end

                subgraph workload["Workload"]
                    App[Sample App<br>nginx 1.21.6]
                end
            end
        end

        S3[S3 Bucket<br>Loki log storage]
        ECR[ECR<br>image registry]
    end

    Internet -->|traffic| NLB
    NLB --> NGINX
    GitHub -->|sync| ArgoCD
    NGINX -->|route| Grafana
    NGINX -->|route| App

    Promtail -->|ship logs| Loki
    Loki -->|store chunks| S3
    Loki -->|datasource| Grafana
    Prom -->|datasource| Grafana
    Sidekick -->|forward alerts| Loki
    Trivy -->|pull images| ECR
    Trivy -->|scan metrics| Prom
    Falco -->|events| Sidekick
```

**Key AWS differences from local:**
- No Gitea — ArgoCD syncs directly from GitHub
- ingress-nginx provisions an AWS Network Load Balancer
- Loki stores log chunks in S3 instead of local filesystem
- Trivy Operator accesses ECR via IRSA (no static credentials)
- Falco works fully — Amazon Linux 2 nodes have pre-built eBPF probes
- Terraform manages: VPC, subnets, EKS cluster, managed node group, OIDC provider, IRSA roles

## Observability Data Flow

```mermaid
flowchart LR
    subgraph Sources
        Pods[Application Pods]
        K8s[Kubernetes API]
        FalcoD[Falco DaemonSet]
    end

    subgraph Collection
        Promtail[Promtail<br>DaemonSet]
        Prom[Prometheus<br>scrape]
        Sidekick[Falcosidekick]
    end

    subgraph Storage
        Loki[Loki]
        TSDB[Prometheus TSDB]
    end

    subgraph Visualization
        Grafana[Grafana]
    end

    Pods -->|stdout/stderr| Promtail
    Promtail -->|push| Loki
    K8s -->|metrics endpoints| Prom
    Pods -->|/metrics| Prom
    FalcoD -->|gRPC| Sidekick
    Sidekick -->|/loki/api/v1/push| Loki
    Loki --> Grafana
    Prom --> TSDB --> Grafana
```

**Pre-deployed Grafana dashboards:**
- **Trivy — Vulnerability Reports**: CRITICAL/HIGH/MEDIUM/LOW counts by image, filterable
- **Falco — Security Events**: Event rate by priority, full event log (populated on EKS)

## Terraform Module Structure (AWS)

```mermaid
graph TD
    Root[environments/dev] --> VPC[modules/vpc]
    Root --> EKS_MOD[modules/eks]
    Root --> IRSA[modules/irsa]

    VPC -->|vpc_id, subnet_ids| EKS_MOD
    EKS_MOD -->|oidc_provider_arn, oidc_provider_url| IRSA

    VPC -.->|creates| VPC_R[VPC + IGW<br>2 public subnets<br>EKS/NLB subnet tags]
    EKS_MOD -.->|creates| EKS_R[EKS cluster<br>managed node group<br>OIDC provider]
    IRSA -.->|creates| IRSA_R[Loki → S3 role<br>Trivy → ECR role]
```

## Umbrella Chart Pattern

Each platform component uses a wrapper Helm chart that depends on the upstream chart:

```
platform/monitoring/
├── Chart.yaml        # depends on: kube-prometheus-stack
├── values.yaml       # all config nested under kube-prometheus-stack:
└── templates/        # extra resources (e.g., Grafana dashboard ConfigMaps)
```

This keeps every ArgoCD Application single-source (one git path) while allowing extra resources like custom dashboards to live alongside the values. Environment differences are handled with overlay values files (`values-aws.yaml`), not branching or duplication.

## Design Decisions

| Decision | Rationale |
|---|---|
| Gitea for local GitOps | Avoids dependency on external git hosting; ArgoCD can sync from an in-cluster URL without network access |
| Umbrella charts over multi-source | Simpler ArgoCD config; each app is one path in git with no multi-source complexity |
| IRSA over static credentials | AWS best practice — pods assume IAM roles via service account annotations, no secrets to rotate |
| Public subnets only (no NAT Gateway) | NAT Gateway costs ~$30/month — unnecessary for a demo. Document the production upgrade path |
| Falco modern_ebpf driver | Works on kernel >= 5.8 (EKS AL2); fails gracefully on WSL2 where kernel probes are unavailable |
| Deliberately vulnerable sample app | nginx 1.21.6 has known CVEs — proves the Trivy scanning pipeline works end-to-end |
| Taskfile over Makefile | Better YAML-native syntax, built-in dotenv loading, clearer task dependencies |
