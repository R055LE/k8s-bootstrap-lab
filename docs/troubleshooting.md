# Troubleshooting Guide

Issues encountered during development of this platform, with root causes and fixes documented for reference.

---

## Table of Contents

1. [WSL2: Promtail CrashLoopBackOff — inotify limits](#1-wsl2-promtail-crashloopbackoff--inotify-limits)
2. [Falco fails to start on WSL2/Kind](#2-falco-fails-to-start-on-wsl2kind)
3. [ArgoCD repo-server OOMKilled](#3-argocd-repo-server-oomkilled)
4. [Trivy scan jobs OOMKilled](#4-trivy-scan-jobs-oomkilled)
5. [Trivy chart 0.22.0: Rego parse error on k8s 1.31+](#5-trivy-chart-0220-rego-parse-error-on-k8s-131)
6. [Trivy: SuccessCriteriaMet unrecognised (k8s 1.31+ job condition)](#6-trivy-successcriteriamet-unrecognised-k8s-131-job-condition)
7. [Trivy 0.32.1: mirror.gcr.io registry pull failures](#7-trivy-0321-mirrorgcrio-registry-pull-failures)
8. [Trivy 0.69: cache lock contention in scan pods](#8-trivy-069-cache-lock-contention-in-scan-pods)
9. [ArgoCD ComparisonError: terminatingReplicas field not in schema](#9-argocd-comparisonerrror-terminatingreplicas-field-not-in-schema)
10. [ArgoCD: application manifests with unsubstituted variables](#10-argocd-application-manifests-with-unsubstituted-variables)

---

## 1. WSL2: Promtail CrashLoopBackOff — inotify limits

**Symptom**

```
kubectl logs -n logging promtail-<pod> -c promtail
too many open files
```

Pod enters `CrashLoopBackOff` on one or more Kind nodes. Usually one worker is affected first.

**Root cause**

Kind runs each node as a Docker container. On WSL2, the default inotify limits (`fs.inotify.max_user_instances=128`) are shared across all containers on the host. Three Kind nodes each running Promtail exhaust the limit.

**Fix**

```bash
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=1048576
```

For persistence across WSL2 restarts, add to `/etc/sysctl.d/99-kind.conf`:

```
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 1048576
```

Then reload: `sudo sysctl --system`

> **Note:** The `/etc/sysctl.d/` approach requires a WSL2 restart to take effect. The `sysctl -w` command applies immediately without restart.

**Prevention**

Apply these limits before running `task bootstrap`. The `scripts/prerequisites.sh` check could be extended to verify inotify limits.

---

## 2. Falco fails to start on WSL2/Kind

**Symptom**

```
kubectl get pods -n falco
NAME          READY   STATUS                  RESTARTS
falco-xxxxx   0/2     Init:CrashLoopBackOff   5
```

Falco init container exits immediately. Logs show:
```
modern_ebpf: scap_init failed
```
or (legacy ebpf):
```
Unable to load the driver: scap_proc_scan_file
Error: 404 — https://download.falco.org/... (no pre-built probe)
```

**Root cause**

Falco attaches to the kernel via eBPF probes. On WSL2:
- `modern_ebpf` requires BTF (BPF Type Format) in a form compatible with Falco's CO-RE approach — the `microsoft-standard-WSL2` kernel doesn't satisfy this
- `ebpf` (legacy) requires a pre-built probe for the exact kernel version, or on-node compilation. Neither is available: `download.falco.org` has no probe for `6.6.87.2-microsoft-standard-WSL2`, and Kind containers can't mount `debugfs` or access `/lib/modules/.../build`

**This is a known, documented limitation — not a configuration error.**

**What works locally**

- Falcosidekick (2 pods) — fully running, Loki destination wired
- Falco Grafana dashboard — deployed and will populate when connected to real Falco

**Fix for local testing (not Kind)**

- Use a Linux VM with a standard kernel (Ubuntu 22.04+)
- Docker Desktop on Linux (not WSL2)

**On EKS (Phase 4)**

Falco works correctly on Amazon Linux 2 EKS nodes, which have pre-built probes and full kernel access.

---

## 3. ArgoCD repo-server OOMKilled

**Symptom**

```
kubectl get pods -n argocd
argocd-repo-server-xxx   0/1  OOMKilled   9
```

ArgoCD Applications show as `Unknown` or fail to sync. Repo-server restarts repeatedly.

**Root cause**

The default repo-server memory limit was 256Mi. Two factors combined to exhaust it:
1. `kube-prometheus-stack` generates ~500 Kubernetes resources when rendered — the repo-server holds all of these in memory during diff calculations
2. The initial multi-source Application pattern required the repo-server to fetch two sources simultaneously per app

**Fix**

Patch the running deployment to break the OOMKill loop immediately:

```bash
kubectl set resources deployment argocd-repo-server -n argocd \
  --limits=memory=512Mi --requests=memory=256Mi
```

Then update `platform/argocd/values.yaml` permanently:

```yaml
argo-cd:
  repoServer:
    resources:
      limits:
        memory: 512Mi
      requests:
        memory: 256Mi
```

Also, switch to the umbrella chart pattern (single-source Applications) to reduce per-app memory pressure. See the [Bootstrap Architecture](../README.md#bootstrap-architecture) section.

---

## 4. Trivy scan jobs OOMKilled

**Symptom**

```
kubectl get pods -n trivy-system
scan-vulnerabilityreport-xxxxx   0/1   OOMKilled
```

No `VulnerabilityReport` CRs are created. Scan jobs complete with exit code 137.

**Root cause**

The default scan job memory limit (128Mi) is insufficient for scanning large container images. Images like `kube-prometheus-stack` or `argocd` can be 200-500MB compressed, and Trivy loads the full vulnerability DB into memory during the scan.

**Fix**

In `platform/trivy-operator/values.yaml`:

```yaml
trivy-operator:
  trivy:
    resources:
      requests:
        memory: 128Mi
      limits:
        memory: 512Mi   # was 128Mi
```

> **Note:** For very large images (e.g., full JDK base images), even 512Mi may not be enough. Increase to 1Gi if OOMKills continue.

---

## 5. Trivy chart 0.22.0: Rego parse error on k8s 1.31+

**Symptom**

```
kubectl logs -n trivy-system deployment/trivy-operator | grep "rego_parse_error"
externalPolicies/file_0.rego:1: rego_parse_error: unexpected minus token: expected number
```

The operator floods logs with this error for every resource in every namespace, blocking all reconciliation. No `VulnerabilityReport` or `ConfigAuditReport` CRs are created.

**Root cause**

Trivy Operator 0.22.0 (chart 0.22.0) bundles Rego policies for config audit scanning. The policy format is incompatible with the OPA/Rego engine version used on Kubernetes 1.31+. Every resource watch triggers a policy evaluation that immediately fails.

**Fix (short-term)**

Disable the config audit scanner to unblock the operator:

```bash
kubectl patch configmap -n trivy-system trivy-operator-config --type merge \
  -p '{"data":{"OPERATOR_CONFIG_AUDIT_SCANNER_ENABLED":"false"}}'
kubectl rollout restart deployment -n trivy-system trivy-operator
```

**Fix (permanent)**

Upgrade to chart 0.32.1+ which ships Trivy Operator 0.30.1 with updated Rego policies:

```yaml
# platform/trivy-operator/Chart.yaml
dependencies:
  - name: trivy-operator
    version: "0.32.1"   # was 0.22.0
```

---

## 6. Trivy: SuccessCriteriaMet unrecognised (k8s 1.31+ job condition)

**Symptom**

Scan jobs show `Status: Complete` but no `VulnerabilityReport` CRs are created. Operator logs show:

```
unrecognized scan job condition: SuccessCriteriaMet
unrecognized scan job condition: FailureTarget
```

**Root cause**

Kubernetes 1.31 added new Job completion conditions (`SuccessCriteriaMet`, `FailureTarget`) as part of the Job success/failure policy feature. Trivy Operator 0.22.0 uses `controller-runtime@v0.17.3`, which was built for Kubernetes ~1.29/1.30 and returns an error when it encounters these unknown condition types. The operator correctly runs the scan jobs but then fails to process their completion, so no reports are written.

**Fix**

Upgrade Trivy Operator to 0.32.1+ (uses `controller-runtime@v0.22.1`, supports k8s 1.31+). See issue [#5](#5-trivy-chart-0220-rego-parse-error-on-k8s-131) above — both problems are fixed by the same version upgrade.

After upgrading, delete stale completed/failed jobs to force fresh scans:

```bash
kubectl delete jobs -n trivy-system --all
```

---

## 7. Trivy 0.32.1: mirror.gcr.io registry pull failures

**Symptom**

Scan job init containers fail with:

```
FATAL Failed to download vulnerability DB
OCI repository error: GET https://mirror.gcr.io/v2/ghcr.io/aquasecurity/trivy-db/manifests/2:
MANIFEST_UNKNOWN: Failed to fetch "2"
```

**Root cause**

Trivy Operator 0.32.1 changed the default image and DB registries to use `mirror.gcr.io` as a GCR mirror for all pulls (`dbRegistry: mirror.gcr.io`, `image.registry: mirror.gcr.io`). The mirror uses a different URL format that doesn't support the trivy-db OCI artifact path properly.

Additionally, the `dbRepository` field semantics changed between 0.22.0 and 0.32.1:
- 0.22.0: `dbRepository: ghcr.io/aquasecurity/trivy-db` (full URL)
- 0.32.1: `dbRegistry: mirror.gcr.io` + `dbRepository: aquasec/trivy-db` (split)

**Fix**

Override all mirror.gcr.io references in `platform/trivy-operator/values.yaml`:

```yaml
trivy-operator:
  trivy:
    image:
      registry: docker.io        # was mirror.gcr.io
    dbRegistry: ghcr.io          # was mirror.gcr.io
    dbRepository: aquasecurity/trivy-db
    javaDbRegistry: ghcr.io
    javaDbRepository: aquasecurity/trivy-java-db

  policiesBundle:
    registry: ghcr.io            # was mirror.gcr.io
    repository: aquasecurity/trivy-checks
```

---

## 8. Trivy 0.69: cache lock contention in scan pods

**Symptom**

Scan job containers exit with:

```
ERROR Failed to acquire cache or database lock
FATAL cache may be in use by another process: timeout
```

Multiple containers in the same scan pod fail. No `VulnerabilityReport` CRs are created.

**Root cause**

Trivy 0.69 (shipped in trivy-operator 0.32.1) introduced an explicit file-based lock on the vulnerability DB cache. Scan pods for workloads with multiple containers (e.g., Gitea with `init-directories`, `init-app-ini`, `configure-gitea`) get one trivy init container per target container, all sharing a single `emptyDir` cache volume. All init containers attempt to acquire the same lock file simultaneously, causing timeout failures.

**Fix**

Enable the built-in Trivy server mode. One trivy server process runs in the pod as a StatefulSet, downloads the DB once, and all scan containers act as clients (no local cache needed):

```yaml
trivy-operator:
  operator:
    builtInTrivyServer: true
```

This creates a `trivy-server` StatefulSet in the `trivy-system` namespace with a PVC for the DB cache. Scan containers connect to it via `http://trivy-service.trivy-system:4975` instead of downloading the DB themselves.

> Alternatively, limit `scanJobsConcurrentLimit: 1` to avoid contention across pods (slower but avoids the server requirement). This does not fix the within-pod contention.

---

## 9. ArgoCD ComparisonError: terminatingReplicas field not in schema

**Symptom**

Applications show `Unknown` sync status (not `Synced`). The ArgoCD UI shows:

```
ComparisonError: failed to calculate diff: error calculating structured merge diff:
error building typed value from live resource:
.status.terminatingReplicas: field not declared in schema
```

Auto-sync still works for most changes, but the app permanently shows `Unknown`.

**Root cause**

Kubernetes 1.31+ added `.status.terminatingReplicas` to ReplicaSet, Deployment, and StatefulSet status. ArgoCD's bundled Kubernetes schema (from the version it was built against) doesn't know about this field, causing the structured merge diff to fail during comparison. The sync itself succeeds (ArgoCD applies resources correctly) but the comparison step cannot determine sync status.

**Fix**

Add `ignoreDifferences` to affected Applications in `platform/apps/`:

```yaml
# platform/apps/trivy-operator.yaml (or any affected app)
spec:
  ignoreDifferences:
    - group: apps
      kind: ReplicaSet
      jsonPointers:
        - /status/terminatingReplicas
    - group: apps
      kind: Deployment
      jsonPointers:
        - /status/terminatingReplicas
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /status/terminatingReplicas
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

> This is a cosmetic fix. Resources still sync and deploy correctly without it.

**Upstream fix**

This will be resolved when ArgoCD upgrades its bundled Kubernetes schema. Track: [argoproj/argo-cd#20884](https://github.com/argoproj/argo-cd/issues/20884) or equivalent.

---

## 10. ArgoCD: application manifests with unsubstituted variables

**Symptom**

ArgoCD Applications fail to connect to the git repository. ArgoCD UI shows:

```
repo 'http://gitea-http.gitea.svc.cluster.local:3000/...' not found
```

Or the Application points to an empty/wrong URL.

**Root cause**

ArgoCD Application manifests (in `platform/apps/*.yaml` and `platform/app-of-apps.yaml`) reference the in-cluster Gitea URL. If these were committed with shell variable placeholders (`${REPO_URL}`) instead of the actual URL, ArgoCD reads them as-is from git — it does not perform variable substitution at runtime.

This happens when:
1. `envsubst` is run without exporting variables first (`source` without `set -a`)
2. Variables are sourced in one shell and envsubst runs in a subshell without inheritance
3. The substituted files are not committed — only the originals are pushed

**Fix**

The correct approach is to commit the literal URL directly in Application manifests. There is no benefit to using placeholders since the in-cluster Gitea URL is deterministic and environment-specific:

```yaml
# platform/app-of-apps.yaml — commit the real URL, not a variable
spec:
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/gitea-admin/zero-to-cluster.git
```

If you accidentally push manifests with empty or wrong `repoURL`:

```bash
# Restore the files from a known-good git state
git checkout HEAD -- platform/apps/ platform/app-of-apps.yaml

# Or fix the URL and recommit
git add platform/apps/ platform/app-of-apps.yaml
git commit -m "fix: restore correct Gitea repoURL in Application manifests"
git push origin main
```

---

## General Tips

**Checking ArgoCD sync errors without the UI**

```bash
kubectl get application -n argocd -o wide
kubectl get application -n argocd <app-name> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

**Forcing an immediate ArgoCD sync**

```bash
kubectl -n argocd annotate application <app-name> argocd.argoproj.io/refresh=hard
```

**Clearing stuck scan jobs after Trivy fixes**

```bash
kubectl delete jobs -n trivy-system --all
# Operator reschedules fresh scan jobs within ~30 seconds
```

**Checking if Prometheus is scraping Trivy metrics**

```bash
kubectl get --raw /api/v1/namespaces/trivy-system/services/trivy-operator:80/proxy/metrics \
  | grep trivy_image_vulnerabilities | head -5
```

**Verifying inotify limits (WSL2)**

```bash
cat /proc/sys/fs/inotify/max_user_instances
cat /proc/sys/fs/inotify/max_user_watches
# Should be >= 512 and >= 524288 respectively for a 3-node Kind cluster
```
