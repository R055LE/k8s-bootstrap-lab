# AWS Testing Guide

This document covers how to safely run and validate the Phase 4 EKS bootstrap
against a real AWS account without incurring runaway costs.

## Cost Expectations

| Resource | Rate |
|---|---|
| EKS control plane | ~$0.10/hr |
| t3.medium node (×2 default) | ~$0.08/hr each |
| NLB | ~$0.008/hr + data processing |
| S3 (Loki logs) | negligible for a short test run |
| **Total (default config)** | **~$0.27/hr** |

A full bootstrap → validate → destroy session typically takes under an hour.
A forgotten cluster left running overnight costs ~$6.

## Pre-Flight Checklist

Before running `task bootstrap TARGET=aws`, complete the following:

- [ ] **AWS Budget alert configured** — go to AWS Billing → Budgets → Create Budget.
  Set a monthly threshold (e.g. $20–50) with an email/SNS alert at 80% and 100%.
  This is a hard requirement, not optional.
- [ ] `config/aws.env` filled in from `config/aws.env.example`
- [ ] AWS credentials active (`aws sts get-caller-identity` returns your account)
- [ ] Terraform state bucket created (`task tf-state-bucket`)
- [ ] You have time to run the full session — bootstrap and destroy in one sitting

## Smoke-Test Config (Recommended for First Run)

Edit `config/aws.env` to reduce node count for the initial validation:

```bash
# Use 1 node for smoke testing — saves ~$0.08/hr
NODE_DESIRED_COUNT=1
NODE_MIN_COUNT=1
NODE_MAX_COUNT=1
```

The full platform still bootstraps correctly with a single node.
Restore to 2 nodes for any performance or DaemonSet testing.

> Note: `NODE_DESIRED_COUNT` and friends are not yet wired from `aws.env` into
> `setup-aws.sh` — the defaults in `setup-aws.sh` (2 nodes) apply unless you
> edit `terraform/environments/dev/terraform.tfvars` directly before applying.

## Running a Test Session

```bash
# 1. Bootstrap
task bootstrap TARGET=aws

# 2. Validate
task status TARGET=aws
kubectl get vulnerabilityreports -A   # Trivy scans
kubectl get pods -n falco             # Falco eBPF (should run on AL2 nodes)
kubectl get svc -n ingress-nginx      # NLB hostname

# 3. Destroy — do not skip this step
task destroy TARGET=aws
```

## Post-Destroy Verification

`task destroy` handles the ordered teardown, but always verify in the AWS console:

- **EC2 → Load Balancers** — no NLBs remaining (Kubernetes-managed NLBs are the most
  common orphan if the LB cleanup step times out)
- **EC2 → Security Groups** — no `eks-cluster-*` or `k8s-elb-*` groups remaining
- **EC2 → Instances** — no running nodes
- **S3** — the Loki log bucket is deleted by Terraform; the Terraform state bucket
  (`TF_STATE_BUCKET`) is intentionally preserved — delete it manually when fully done

If any resources remain after `task destroy`, delete them manually before they
accumulate charges.

## Terraform State Bucket

The S3 state bucket is created once and never destroyed by the teardown script.
It stores the Terraform state so future runs are idempotent.

Delete it manually from the S3 console only when you are completely done with
the project and have confirmed all other AWS resources are gone.
