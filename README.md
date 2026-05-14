<div align="center">

# RKE2 on Proxmox — Production Kubernetes, One Command

**Self-hosted Kubernetes that doesn't cut corners.** Terraform-provisioned VMs, Cilium eBPF networking, HA control plane, zero-trust RBAC, and centralized observability — all from a single `deploy.sh`.

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.29+-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![RKE2](https://img.shields.io/badge/RKE2-v1.29.4-0075A8?logo=rancher&logoColor=white)](https://docs.rke2.io)
[![Terraform](https://img.shields.io/badge/Terraform-≥1.6-7B42BC?logo=terraform&logoColor=white)](https://terraform.io)
[![Cilium](https://img.shields.io/badge/Cilium-eBPF-F8C517?logo=cilium&logoColor=black)](https://cilium.io)
[![Proxmox](https://img.shields.io/badge/Proxmox-VE_8-E57000?logo=proxmox&logoColor=white)](https://proxmox.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

[**Quickstart**](#-quickstart) · [**Architecture**](#-architecture) · [**Features**](#-what-you-get) · [**Docs**](docs/) · [**Star this repo ⭐**](#)

</div>

---

## ⚡ Quickstart

From bare VMs to a running, observable, secure Kubernetes cluster in **~30 minutes**.

```bash
# 1. Clone
git clone https://github.com/<you>/infra-setup.git && cd infra-setup

# 2. Configure (fill in your Proxmox + network details)
cp terraform/proxmox/terraform.tfvars.example terraform/proxmox/terraform.tfvars
cp terraform/observability/terraform.tfvars.example terraform/observability/terraform.tfvars
$EDITOR terraform/proxmox/terraform.tfvars

# 3. Set secrets and deploy
export TF_VAR_proxmox_password="..."
export TF_VAR_central_mimir_password="..."   # leave empty if your stack has no auth
export TF_VAR_central_loki_password="..."
export TF_VAR_alertmanager_slack_webhook="..."

./scripts/deploy.sh
```

That's it. Watch Terraform provision VMs, RKE2 install masters then workers, RBAC + NetworkPolicies + cert-manager + ESO apply, Prometheus deploy, and Grafana Alloy ship logs and metrics to your central stack.

---

## 🏗 Architecture

```
                            ┌───────────────────────────────┐
                            │   Proxmox VE Hypervisor        │
                            │                                │
       kube-vip VIP ───────►│  ┌──────┐ ┌──────┐ ┌──────┐    │
       (HA API server)      │  │ M-1  │ │ M-2  │ │ M-3  │    │  3 × Masters
                            │  │ etcd │ │ etcd │ │ etcd │    │  (dedicated etcd disk)
                            │  └──────┘ └──────┘ └──────┘    │
                            │                                │
                            │  ┌──────┐ ┌──────┐             │
                            │  │ W-1  │ │ W-2  │  ◄── scale  │  2 × Workers
                            │  └──────┘ └──────┘    horizontally
                            │                                │
                            │  Cilium eBPF · WireGuard · Hubble
                            │  Grafana Alloy (systemd, every VM)
                            └────────────────┬───────────────┘
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
- **kube-proxy replacement** via eBPF — faster, fewer hops
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

### 🎯 Reliability — HA from day one
- **3-master etcd quorum** with dedicated etcd disks
- **kube-vip** virtual IP — API stays up through master failure
- **Anti-affinity** for Prometheus, Alertmanager
- **Kernel tuning** for inotify, etcd I/O, conntrack

### 📊 Observability — centralized, not bolted on
- **Prometheus HA** scrapes everything, remote-writes to **your Mimir**
- **Grafana Alloy** on each VM (systemd, not in-cluster) collects:
  - Pod logs → central Loki
  - systemd / RKE2 journal → central Loki
  - Node metrics (replaces node-exporter) → central Mimir
  - etcd metrics (masters) → central Mimir
- **Alertmanager** routes to Slack / PagerDuty / email

### 🤖 Automation — one command, six phases
| Phase | Step | Manual? |
|------|------|:---:|
| 1 | Proxmox API token + cloud-init template | ✅ |
| 2 | Terraform → 3 masters + 2 workers | 🤖 |
| 3 | RKE2 install + kube-vip + Alloy on each VM | 🤖 |
| 4 | RBAC, NetworkPolicies, cert-manager, ESO, kubeconfigs | 🤖 |
| 5 | Prometheus + Alertmanager (Helm) | 🤖 |
| 6 | Cilium IngressController verification | 🤖 |

---

## 🚀 Why This Stack?

| | This repo | Hand-rolled | Managed (EKS/GKE) |
|---|:---:|:---:|:---:|
| Runs on your hardware | ✅ | ✅ | ❌ |
| HA control plane | ✅ | 🧑‍🔧 weeks of work | ✅ |
| eBPF networking | ✅ | 🧑‍🔧 | ➕ extra cost |
| Audit logging + PSS hardened | ✅ | 🧑‍🔧 | ✅ |
| Cost | 💰 hardware only | 💰 + your time | 💰💰💰 monthly |
| Lock-in | None | None | High |
| Time to first cluster | **30 min** | weeks | hours |

---

## 📁 Project Structure

```
infra-setup/
├── scripts/deploy.sh            ← single-command deployment (Phases 2–6)
├── terraform/
│   ├── proxmox/                 ← VM provisioning
│   └── observability/           ← Prometheus + Alertmanager (Helm via TF)
├── rke2/
│   ├── scripts/                 ← install-master.sh, install-worker.sh, install-alloy.sh
│   └── configs/                 ← audit-policy, Cilium HelmChartConfig, Alloy template
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
| [Knowledge Base](docs/knowledge-base.md) | Full architecture reference (also as [PDF](docs/RKE2-Infrastructure-Knowledge-Base.pdf)) |
| [Implementation Guide](docs/implementation-guide.md) | Phase-by-phase walkthrough |
| [Scaling Procedures](docs/scaling-procedures.md) | Add masters, workers, storage |
| [Backup & Upgrade](docs/backup-and-upgrade.md) | etcd snapshots, Velero, version upgrades |
| [Troubleshooting](docs/troubleshooting.md) | Symptoms → root cause → fix |

---

## 🛠 Requirements

**On Proxmox host:**
- Proxmox VE 7 or 8
- API token with VM management permissions
- Ubuntu 22.04 cloud-init template

**On your workstation:**
- Terraform ≥ 1.6
- kubectl ≥ 1.29
- Helm ≥ 3.14
- `openssl`, `jq`, `ssh`

**Cluster defaults (all configurable):**
- 3 master VMs: 4 vCPU / 8 GB RAM / 50 GB OS + 20 GB etcd
- 2 worker VMs: 8 vCPU / 16 GB RAM / 100 GB OS + 200 GB data
- Network: any /24 you specify

---

## 🤝 Contributing

PRs welcome — especially for:
- Cloud-init templates for other distros (Debian, Rocky)
- Additional CNI examples
- Velero / backup recipes
- Grafana dashboards JSON

Open an issue first for anything bigger than a fix.

---

## ⭐ Like this project?

If this saved you a weekend, **drop a star** — it helps others find it.

---

## 📄 License

[MIT](LICENSE) — do what you want, no warranty.

## 🙏 Acknowledgements

Built on the shoulders of giants: [RKE2](https://docs.rke2.io), [Cilium](https://cilium.io), [Proxmox](https://proxmox.com), [Terraform](https://terraform.io), [kube-vip](https://kube-vip.io), [cert-manager](https://cert-manager.io), [External Secrets](https://external-secrets.io), [Prometheus](https://prometheus.io), [Grafana Alloy](https://grafana.com/oss/alloy/).
