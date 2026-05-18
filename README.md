<div align="center">

# RKE2 on Proxmox — Production Kubernetes, One Command

**Self-hosted Kubernetes that doesn't cut corners.** Terraform-provisioned VMs, Cilium eBPF networking (kube-proxy replacement), HA control plane via kube-vip, zero-trust RBAC, and centralized observability — all from a single `deploy.sh`.

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.32+-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![RKE2](https://img.shields.io/badge/RKE2-v1.32.10-0075A8?logo=rancher&logoColor=white)](https://docs.rke2.io)
[![Terraform](https://img.shields.io/badge/Terraform-≥1.6-7B42BC?logo=terraform&logoColor=white)](https://terraform.io)
[![Cilium](https://img.shields.io/badge/Cilium-v1.18_eBPF-F8C517?logo=cilium&logoColor=black)](https://cilium.io)
[![Proxmox](https://img.shields.io/badge/Proxmox-VE_8-E57000?logo=proxmox&logoColor=white)](https://proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

[**Quickstart**](#-quickstart) · [**Architecture**](#-architecture) · [**Features**](#-what-you-get) · [**Docs**](docs/knowledge-base.md) · [**Star this repo ⭐**](#)

</div>

---

## ⚡ Quickstart

From bare VMs to a running, observable, secure Kubernetes cluster in **~30 minutes**.
This repo is **multi-cluster aware** — one directory per cluster under `clusters/`.

```bash
# 1. Clone
git clone https://github.com/<you>/infra-setup.git && cd infra-setup

# 2. Set secrets in your shell (no SSH-to-Proxmox required — API token only)
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'
export TF_VAR_central_mimir_password=''     # empty if your central stack has no auth
export TF_VAR_central_loki_password=''
export TF_VAR_alertmanager_slack_webhook=''

# 3. Scaffold a new cluster (interactive wizard)
./scripts/new-cluster.sh acme-prod

# 4. Review + commit the cluster definition through GitLab
git add clusters/acme-prod
git commit -m "feat(clusters): bootstrap acme-prod"
git push

# 5. Deploy
./scripts/deploy.sh acme-prod
```

To deploy another cluster: `./scripts/new-cluster.sh widgets-prod` → commit → `./scripts/deploy.sh widgets-prod`. Each cluster's tfvars + tfstate + kubeconfig stays in its own `clusters/<name>/` folder; the Terraform code under `terraform/` is shared.

Terraform provisions the VMs, RKE2 installs masters then workers, kube-vip floats the control-plane VIP, Cilium comes up as kube-proxy replacement + IngressController + Hubble, RBAC + NetworkPolicies + cert-manager + ESO apply, Prometheus deploys, and Grafana Alloy ships logs and metrics to your central stack.

> Phase 1 (Proxmox API token + Ubuntu 22.04 cloud-init template) is one-time manual setup — see [Deployment](docs/knowledge-base.md#4-deployment--phase-by-phase) for the exact commands.

---

## 🏗 Architecture

```
                            ┌──────────────────────────────────────┐
                            │   Proxmox VE Host                     │
                            │                                        │
       kube-vip VIP ───────►│  ┌──────┐ ┌──────┐ ┌──────┐           │
       (HA API server)      │  │ M-1  │ │ M-2  │ │ M-3  │           │  3 × Masters
                            │  │ etcd │ │ etcd │ │ etcd │           │  (dedicated etcd disk)
                            │  └──────┘ └──────┘ └──────┘           │
                            │                                        │
                            │  ┌──────┐ ┌──────┐ ┌──────┐           │
                            │  │ W-1  │ │ W-2  │ │ W-3  │  ◄── scale│  N × Workers
                            │  └──────┘ └──────┘ └──────┘  horiz.   │  (3 recommended)
                            │                                        │
                            │  Cilium eBPF · WireGuard · Hubble
                            │  (replaces kube-proxy, ingress-nginx)
                            │  Grafana Alloy (systemd, every VM)
                            └────────────────┬───────────────────────┘
                                             │ remote_write / push
                                             ▼
                          ┌─────────────────────────────────┐
                          │   Your Central Stack            │
                          │   Grafana · Mimir · Loki        │
                          │   (queries: cluster="rke2-prod")│
                          └─────────────────────────────────┘
```

---

## ✨ What You Get

### 🚦 Networking — Cilium eBPF, no kube-proxy
- **`kubeProxyReplacement: true` + `disable-kube-proxy: true`** — single eBPF data plane, no iptables NAT churn
- **Cilium IngressController** + **Gateway API** — no separate NGINX
- **WireGuard node-to-node encryption** — transparent, zero-config
- **Hubble** for flow visibility — see every connection in real time
- **NetworkPolicies** — zero-trust default-deny on production namespaces

### 🔐 Security — production-hardened by default
- **Pod Security Standards** — `restricted` on production, `baseline` on dev/staging
- **API server audit logging** — RBAC changes, exec, secret reads
- **Cluster-CA-signed client certs** — 4 role-based kubeconfigs (senior-devops, junior-devops, developer, auditor)
- **cert-manager** with Let's Encrypt + internal CA ClusterIssuers
- **External Secrets Operator** — Vault-backed, never in git
- **Kubelet `protect-kernel-defaults`** with the required sysctls auto-applied

### 🎯 Reliability — HA from day one
- **3-master etcd quorum** with dedicated etcd disks (ext4, separate `/dev/sdb`)
- **kube-vip** virtual IP — API stays up through master failure, ARP-based, ~2s failover
- **CoreDNS hosts plugin** so kube-vip's hardcoded `kubernetes:6443` URL resolves at bootstrap (no chicken-and-egg)
- **Anti-affinity** for Prometheus, Alertmanager
- **Kernel tuning** for inotify, etcd I/O, conntrack

### 📊 Observability — centralized, not bolted on
- **Prometheus HA** scrapes everything, remote-writes to **your Mimir** (3-day local retention as a buffer)
- **Grafana Alloy** on each VM (systemd, not in-cluster) collects:
  - Pod logs → central Loki
  - systemd / RKE2 journal → central Loki
  - Node metrics (replaces node-exporter) → central Mimir
  - etcd metrics (masters only) → central Mimir
- **Alertmanager** routes to Slack / PagerDuty / email
- All telemetry carries `cluster`, `environment`, `node`, `role` labels — filter `cluster="rke2-prod"` in Grafana

### 🤖 Automation — one command, seven phases
| Phase | Step | Manual? |
|------|------|:---:|
| 1 | Proxmox API token + cloud-init template | ✅ |
| 2 | Terraform → 3 masters + N workers (3 recommended) | 🤖 |
| 3 | RKE2 install + kube-vip + Cilium (L2 announce + LB IPAM) + Alloy on each VM | 🤖 |
| 4 | RBAC, NetworkPolicies, cert-manager, ESO, kubeconfigs | 🤖 |
| 5 | Prometheus + Alertmanager (Helm via Terraform) | 🤖 |
| 6 | Cilium IngressController + Hubble verification | 🤖 |
| 7 | ArgoCD + (optional) Ingress, LB IP pool, cert | 🤖 |

`./scripts/deploy.sh --from phaseN` resumes from a specific phase; `--only phaseN` runs one; `--dry-run` validates without applying.

Phase 7 is optional — it self-skips if `terraform/argocd/terraform.tfvars` isn't present. Add ArgoCD later with `./scripts/deploy.sh --only phase7`.

Reverse it all with `./scripts/uninstall.sh` (interactive, symmetric to deploy).

---

## 🚀 Why This Stack?

| | This repo | Hand-rolled | Managed (EKS/GKE) |
|---|:---:|:---:|:---:|
| Runs on your hardware | ✅ | ✅ | ❌ |
| HA control plane | ✅ | 🧑‍🔧 weeks of work | ✅ |
| eBPF networking | ✅ | 🧑‍🔧 | ➕ extra cost |
| kube-proxy fully gone (one data plane) | ✅ | 🧑‍🔧 | ❌ |
| Audit logging + PSS hardened | ✅ | 🧑‍🔧 | ✅ |
| Cost | 💰 hardware only | 💰 + your time | 💰💰💰 monthly |
| Lock-in | None | None | High |
| Time to first cluster | **30 min** | weeks | hours |

---

## 📁 Project Structure

```
infra-setup/
├── clusters/                    ← ONE folder per cluster, tfvars tracked in Git
│   ├── _template/               ← copy this when adding a cluster
│   ├── test-prod/               ← example cluster (tfvars in Git, tfstate gitignored)
│   └── <your-cluster>/          ← created by ./scripts/new-cluster.sh
├── scripts/
│   ├── deploy.sh    <cluster>   ← single-command deployment (Phases 2–7)
│   ├── uninstall.sh <cluster>   ← reverse of deploy.sh (interactive, per-cluster)
│   └── new-cluster.sh <cluster> ← interactive wizard, writes clusters/<name>/*.tfvars
├── terraform/                   ← SHARED module code (no per-cluster copies)
│   ├── proxmox/                 ← VM provisioning (API-token-only)
│   │   └── snippets/k8s-common.yaml  ← admin uploads once per Proxmox host
│   ├── observability/           ← Prometheus + Alertmanager (Helm via TF)
│   └── argocd/                  ← ArgoCD + Ingress, LB IP pool, cert (Phase 7)
├── rke2/
│   ├── scripts/                 ← install-master.sh, install-worker.sh, install-alloy.sh,
│   │                              apply-cilium-config.sh (push Cilium changes to live cluster)
│   └── configs/                 ← audit-policy, Cilium HelmChartConfig (L2 announce + LB IPAM),
│                                  CoreDNS hosts-plugin HelmChartConfig, Alloy template
├── rbac/                        ← 4 role-based ClusterRoles + kubeconfig generator
├── security/
│   ├── network-policies/        ← zero-trust default-deny + monitoring policies
│   ├── secrets/                 ← External Secrets Operator + Vault config
│   └── tls/                     ← cert-manager ClusterIssuers
└── docs/                        ← knowledge base, implementation, troubleshooting
```

---

## 📚 Documentation

| Doc | What's inside |
|-----|---------------|
| [Knowledge Base](docs/knowledge-base.md) | **Read this first.** Full architecture, deployment, troubleshooting, with the actual gotchas (kube-vip bootstrap, Cilium k8sServiceHost, disable-kube-proxy). Also as [PDF](docs/RKE2-Infrastructure-Knowledge-Base.pdf). |
| [Implementation Guide](docs/implementation-guide.md) | Phase-by-phase walkthrough |
| [Fresh-Cluster Runbook](docs/fresh-cluster-deployment.md) | Go/no-go checklist style, [PDF](docs/Fresh-Cluster-Deployment-Runbook.pdf) |
| [Scaling Procedures](docs/scaling-procedures.md) | Add masters, workers, storage |
| [Backup & Upgrade](docs/backup-and-upgrade.md) | etcd snapshots, Velero, version upgrades |
| [Troubleshooting](docs/troubleshooting.md) | Symptoms → root cause → fix |

---

## 🛠 Requirements

**On Proxmox host:**
- Proxmox VE 7 or 8
- API token with VM management permissions (`terraform@pve!terraform`)
- Ubuntu 22.04 cloud-init template
- **One-time:** admin uploads `terraform/proxmox/snippets/k8s-common.yaml` to `local:snippets/` (web UI or scp). After that, Terraform never SSHs to Proxmox.

**On your workstation:**
- Terraform ≥ 1.6
- kubectl ≥ 1.29
- Helm ≥ 3.14
- `openssl`, `jq`, `ssh`
- One SSH keypair for the VMs (`~/.ssh/rke2_cluster_id`). No SSH key to Proxmox is required — Terraform uses only the API token.

**Cluster defaults (all configurable):**
- 3 master VMs: 4 vCPU / **8 GB RAM** / 50 GB OS + 20 GB etcd
  - *Note: 4 GB will deploy but Cilium + Hubble + control plane won't fit — see [`master_memory_mb`](docs/knowledge-base.md#key-proxmox-tfvars).*
- N worker VMs (3 recommended): 8 vCPU / 16 GB RAM / 100 GB OS + 200 GB data
- Network: any /24 you specify
- Pod CIDR: `10.42.0.0/16`, Service CIDR: `10.43.0.0/16`

---

## 🤝 Contributing

PRs welcome — especially for:
- Cloud-init templates for other distros (Debian, Rocky)
- Velero / backup recipes
- Grafana dashboards JSON
- Additional CNI examples

Open an issue first for anything bigger than a fix.

---

## ⭐ Like this project?

If this saved you a weekend, **drop a star** — it helps others find it.

---

## 📄 License

[MIT](LICENSE) — do what you want, no warranty.

## 🙏 Acknowledgements

Built on the shoulders of giants: [RKE2](https://docs.rke2.io), [Cilium](https://cilium.io), [Proxmox](https://proxmox.com), [Terraform](https://terraform.io), [kube-vip](https://kube-vip.io), [cert-manager](https://cert-manager.io), [External Secrets](https://external-secrets.io), [Prometheus](https://prometheus.io), [Grafana Alloy](https://grafana.com/oss/alloy/).
