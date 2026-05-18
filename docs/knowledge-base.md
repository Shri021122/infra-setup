---
title: "RKE2 on Proxmox — Infrastructure Knowledge Base"
subtitle: "Production Kubernetes Cluster: Architecture, Deployment, Operations"
author: "DevOps Team"
date: "2026-05-15"
---

# Table of Contents

1. [What This Deploys](#1-what-this-deploys)
2. [Network Topology](#2-network-topology)
3. [Services & Their Purposes](#3-services--their-purposes)
4. [Deployment — Phase by Phase](#4-deployment--phase-by-phase)
5. [Bootstrap Dependency Chain (read this before debugging)](#5-bootstrap-dependency-chain)
6. [RBAC — Roles, Groups, Kubeconfigs](#6-rbac--roles-groups-kubeconfigs)
7. [Security Hardening](#7-security-hardening)
8. [Observability](#8-observability)
9. [Day-2: Scaling, Backup, Upgrade](#9-day-2-scaling-backup-upgrade)
10. [Uninstall — Destroy the Cluster](#10-uninstall--destroy-the-cluster)
11. [Troubleshooting Cheatsheet](#11-troubleshooting-cheatsheet)
12. [Variable Reference](#12-variable-reference)

---

# 1. What This Deploys

A self-hosted, HA Kubernetes cluster on Proxmox VE, designed for a stack that already has centralized Grafana + Mimir + Loki — the cluster *ships telemetry out*, it does not host its own Grafana.

| Layer | Component | Why |
|---|---|---|
| Hypervisor | Proxmox VE 7/8 | VM host |
| IaC | Terraform (`bpg/proxmox`) | VM provisioning, lifecycle |
| OS | Ubuntu 22.04 cloud-init | Predictable, modern kernel |
| K8s distro | **RKE2 v1.32.10+rke2r1** | CIS-hardened, single-binary, easy upgrades |
| HA control plane | **kube-vip** (DaemonSet) | Floats one VIP across 3 masters, ARP-based |
| CNI / kube-proxy replacement | **Cilium v1.18** with WireGuard | eBPF data plane, IngressController, Hubble, transparent encryption |
| TLS | **cert-manager** | Let's Encrypt + internal CA ClusterIssuers |
| Secrets | **External Secrets Operator** | Pulls from Vault, no secrets in git |
| Metrics (cluster) | **Prometheus** (HA, 2 replicas) | Remote-writes to your central Mimir |
| Alerting | **Alertmanager** (2 replicas) | Slack / PagerDuty / email routing |
| Metrics (nodes) | **Grafana Alloy** (systemd, every VM) | Replaces node-exporter; ships node metrics to central Mimir |
| Logs | **Grafana Alloy** (systemd, every VM) | Pod logs + journald → central Loki |
| Network observability | **Hubble** (Cilium component) | Per-flow visibility, DNS, HTTP |

**Three masters + N workers (3 recommended), one Proxmox host** is the default. Workers scale horizontally — two will boot fine but three leaves headroom for cordon-drain during rolling upgrades. Masters must stay odd (1/3/5) for etcd quorum.

---

# 2. Network Topology

## VMs

```
                         ┌────────────────────────────────────────────────┐
                         │   Proxmox VE Host (e.g. pve-4)                  │
                         │                                                  │
                         │   ╭───────────────╮ ╭───────────────╮ ╭───────────────╮
                         │   │  master-1     │ │  master-2     │ │  master-3     │
                         │   │  VM 401       │ │  VM 402       │ │  VM 403       │
                         │   │  10.10.18.101 │ │  10.10.18.102 │ │  10.10.18.103 │
                         │   │  4 vCPU 8 GB  │ │  4 vCPU 8 GB  │ │  4 vCPU 8 GB  │
                         │   │  50 GB OS     │ │  50 GB OS     │ │  50 GB OS     │
                         │   │  20 GB etcd*  │ │  20 GB etcd*  │ │  20 GB etcd*  │
                         │   ╰───────────────╯ ╰───────────────╯ ╰───────────────╯
                         │                          │
                         │            kube-vip floats 10.10.18.100 across masters
                         │              (ARP, ~2s failover, one node holds it)
                         │                          │
                         │   ╭───────────────╮ ╭───────────────╮
                         │   │  worker-1     │ │  worker-2     │
                         │   │  VM 410       │ │  VM 411       │
                         │   │  10.10.18.111 │ │  10.10.18.112 │
                         │   │  8 vCPU 16 GB │ │  8 vCPU 16 GB │
                         │   │  100 GB OS    │ │  100 GB OS    │
                         │   │  200 GB data† │ │  200 GB data† │
                         │   ╰───────────────╯ ╰───────────────╯
                         │   * /var/lib/rancher/rke2/server/db   (dedicated disk to keep etcd fsync off OS disk)
                         │   † /var/lib/rancher                  (container images + PVCs)
                         │                                                  │
                         │   bridge: vmbrk8s   subnet: 10.10.18.0/24       │
                         └────────────────────────────────────────────────┘
```

**The IPs above are this cluster's actual values.** Change them in `terraform/proxmox/terraform.tfvars` for your own environment.

## Address Plan

| What | Address | Notes |
|---|---|---|
| Node subnet | `10.10.18.0/24` | Set on Proxmox bridge `vmbrk8s` |
| master-1 / 2 / 3 | `.101 / .102 / .103` | Static, set via cloud-init |
| worker-1 / 2 | `.111 / .112` | Static, set via cloud-init |
| Control-plane VIP | `.100` | kube-vip holds this; floats across masters |
| Ingress VIP | `.200` (recommended) | For Cilium IngressController LB; set in `rke2-cilium-config.yaml` `loadBalancerIP` |
| Pod CIDR | `10.42.0.0/16` | Allocated by Cilium per-node |
| Service CIDR | `10.43.0.0/16` | kubernetes service is `10.43.0.1` |
| Cluster DNS | `10.43.0.10` | CoreDNS service IP |

## Traffic Flow

**Inbound (from outside the cluster):**

```
client → LB IP (10.10.18.200, kube-vip) → Cilium IngressController → Service → Pod
                                              (eBPF, hostNetwork)              (overlay if cross-node)
```

**API access (kubectl, kubelet→apiserver):**

```
kubectl → 10.10.18.100:6443 (VIP, kube-vip) → apiserver pod on whichever master holds VIP
                                              (apiserver is hostNetwork, listens on each master's :6443)
```

**Node-to-node pod traffic:** Encrypted by Cilium's WireGuard transparently. No application changes.

**Outbound telemetry:**

```
Pod logs (/var/log/pods/*) ──┐
journald                     ├──→ Alloy (systemd, host net) ──→ http://loki.stackflow.org
Node CPU/mem/disk metrics    ──→ Alloy ──→ http://mimir.stackflow.org/api/v1/push

In-cluster Prometheus ──→ kube-state-metrics + Cilium + etcd + apiserver
                       ──→ remote_write ──→ http://mimir.stackflow.org/api/v1/push
```

Central Grafana queries with `cluster="rke2-prod"` to filter just this cluster's data.

---

# 3. Services & Their Purposes

## In `kube-system`

| Component | Form | What it does | Why |
|---|---|---|---|
| `kube-apiserver` (per master) | Static pod | k8s API endpoint | Standard |
| `etcd` (per master) | Static pod | Cluster state store | HA via 3-node quorum |
| `kube-controller-manager`, `kube-scheduler` | Static pod | Standard k8s controllers | Standard |
| `kube-vip-ds` | DaemonSet | Advertises control-plane VIP `10.10.18.100` via ARP. Elects one master as leader; only that master binds the VIP. | HA: API stays up if a master dies, VIP migrates in ~2s |
| `cilium` | DaemonSet | eBPF data plane: pod networking, **kube-proxy replacement**, NetworkPolicy enforcement, WireGuard encryption | Replaces both kube-proxy and a separate ingress controller |
| `cilium-operator` | Deployment (2 replicas) | IPAM allocation, CRD management, Gateway API watchers | Required for Cilium |
| `cilium-ingress` | Service + envoy | Implements `IngressClass: cilium` | Replaces NGINX ingress |
| `hubble-relay`, `hubble-ui` | Deployment | Per-flow network observability — see drops, HTTP, DNS | Network debugging without app changes |
| `rke2-coredns` | Deployment | Cluster DNS (`kubernetes.default.svc...`) **plus** custom `hosts` block mapping bare `kubernetes` → master IPs so kube-vip can reach the apiserver (see §5) | Required by every pod + the kube-vip workaround |

**Note: there is no `kube-proxy` running.** RKE2 has `disable-kube-proxy: true` set and Cilium provides the service-routing data plane via eBPF. If you see `kube-proxy-*` pods after an upgrade, something regressed.

## In `cert-manager`

| Component | What |
|---|---|
| `cert-manager` Deployment | Watches Certificate / Ingress annotations, talks to ACME (Let's Encrypt) or internal CA, writes TLS secrets |
| `ClusterIssuer/letsencrypt-prod` | Public domains via HTTP-01 |
| `ClusterIssuer/letsencrypt-staging` | Same, against ACME staging (rate-limit-free, untrusted cert — for testing) |
| `ClusterIssuer/cluster-ca-issuer` | Internal CA, for cluster-internal mTLS — auto-bootstrapped from `selfsigned-issuer` |

Ingress consumes via `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation.

## In `external-secrets`

| Component | What |
|---|---|
| `external-secrets` Deployment | The ESO controller — reconciles `ExternalSecret` CRDs into native k8s `Secret` resources |
| `ClusterSecretStore` (configured post-deploy) | Points at your Vault — every namespace can reference it |

## In `monitoring`

| Component | What |
|---|---|
| `prometheus` (StatefulSet, 2 replicas) | Scrapes kube-state-metrics + Cilium + etcd + apiserver. **Local retention 3 days only** (just a buffer if Mimir is unreachable). Remote-writes everything to central Mimir. |
| `alertmanager` (StatefulSet, 2 replicas) | Routes alerts: `critical/page` → PagerDuty, `warning` → Slack, default → email |
| `kube-state-metrics` | Exposes Deployment/Pod/Node etc. as Prometheus metrics |
| `prometheus-operator` | CRD-driven Prometheus management |
| **NOT deployed**: Grafana, node-exporter | Grafana is your central stack; node-exporter's job is done by Alloy on each VM |

## On every VM (systemd, not Kubernetes)

`alloy.service` runs Grafana Alloy directly on the OS. It has access to `/var/log/pods/*` and `/var/log/journal/` without container boundaries, so it can ship:

| Source | Where to | Why |
|---|---|---|
| `loki.source.file` from `/var/log/pods/*/*/*.log` | central Loki | All pod logs, labeled `cluster`, `namespace`, `pod`, `container`, `node`, `level`, `trace_id` |
| `loki.source.journal` (systemd journal) | central Loki | RKE2 server/agent logs, kubelet logs, kernel messages |
| `prometheus.exporter.unix` | central Mimir | CPU/mem/disk/net per node (same metrics node-exporter produces) |
| `prometheus.scrape` of etcd port 2381 (masters only) | central Mimir | etcd fsync latency, peer health, leader changes |

Config template: `rke2/configs/alloy-config.alloy.tpl`. Rendered + installed by `install-alloy.sh` (called from `install-master.sh` and `install-worker.sh`).

## On every master (RKE2 internals worth knowing)

- `rke2-server` systemd unit owns kube-apiserver + etcd + scheduler + controller-manager static pods.
- Auto etcd snapshots: every 6h, 10 retained, stored at `/var/lib/rancher/rke2/server/db/snapshots/`.
- API server audit log: `/var/lib/rancher/rke2/server/logs/audit.log`. Policy in `rke2/configs/audit-policy.yaml` captures RBAC changes, exec/attach, secret access. Alloy ships this via journald.

---

# 4. Deployment — Phase by Phase

## Phase 1 — Proxmox prep (one-time, manual)

Once per Proxmox host, before any clone of this repo will work:

```bash
# On Proxmox host as root
pveum user add terraform@pve
pveum role add TerraformRole -privs "VM.Allocate VM.Clone VM.Config.CDROM \
  VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType \
  VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor VM.Audit \
  VM.PowerMgmt Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate \
  Datastore.Audit SDN.Use Sys.Audit"
pveum aclmod / -user terraform@pve -role TerraformRole
pveum user token add terraform@pve terraform --expire 0 --privsep=0
# → save the token UUID; you'll export it as TF_VAR_proxmox_api_token
# (--privsep=0 makes the token inherit the user's privileges; without it,
#  also run: pveum aclmod / -token 'terraform@pve!terraform' -role TerraformRole -propagate 1)

# Ubuntu 22.04 cloud-init template (this repo's defaults expect VM ID 9200)
wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
qm create 9200 --memory 2048 --cores 2 --name ubuntu-2204-template --net0 virtio,bridge=vmbrk8s
qm importdisk 9200 jammy-server-cloudimg-amd64.img local-lvm
qm set 9200 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9200-disk-0
qm set 9200 --ide2 local-lvm:cloudinit --boot c --bootdisk scsi0
qm set 9200 --serial0 socket --vga serial0 --agent enabled=1
qm template 9200
```

## Phase 1.5 — Workstation prep (one-time)

```bash
# Tools (versions are minimums)
terraform --version   # ≥ 1.6.0
kubectl version --client   # ≥ 1.29
helm version --short  # ≥ 3.14
jq --version
openssl version

# Just one SSH key — for the cluster VMs. Terraform reaches Proxmox via API
# token only; no Proxmox-root SSH key is needed (see "Cloud-init snippet"
# below).
ssh-keygen -t ed25519 -f ~/.ssh/rke2_cluster_id -N "" -C "rke2-cluster-deploy"
```

> **One-time per Proxmox host** (admin task, not per cluster): upload
> `terraform/proxmox/snippets/k8s-common.yaml` to `local:snippets/` via the
> Proxmox web UI (Datacenter → Storage → local → Snippets → Upload) or via
> a single `scp`. Then set
> `shared_cloud_init_snippet_file_id = "local:snippets/k8s-common.yaml"`
> in `terraform/proxmox/terraform.tfvars`. After this one-time step, every
> cluster deploy talks to Proxmox exclusively over the REST API.

## Phase 1.6 — Fill in tfvars + placeholders (per cluster)

```bash
git clone https://github.com/<you>/infra-setup.git && cd infra-setup

cp terraform/proxmox/terraform.tfvars.example terraform/proxmox/terraform.tfvars
cp terraform/observability/terraform.tfvars.example terraform/observability/terraform.tfvars
```

Edit `terraform/proxmox/terraform.tfvars` — minimum changes from the example:

- `proxmox_api_url`, `proxmox_node`
- `network_bridge`, `network_subnet_cidr`, `network_gateway`, `control_plane_vip`
- `vm_template_id` (`9200`)
- `master_disk_storage`, `worker_disk_storage` (your Proxmox storage pool name)
- `master_ip_addresses`, `worker_ip_addresses`
- `vm_ssh_public_key` ← paste contents of `~/.ssh/rke2_cluster_id.pub`
- `master_vm_id_start` (default 300; we use 401)
- `worker_vm_id_start` (default 310; we use 410)

Edit `terraform/observability/terraform.tfvars`:

- `central_mimir_url`
- `central_loki_url`
- `loki_tenant_id` (defaults to cluster name)

Two YAMLs still have placeholders **in the repo** that you should fill (or leave; deploy.sh handles missing values for ESO):

- `security/tls/cluster-issuer.yaml` → `YOUR_EMAIL@yourdomain.com` (used by Let's Encrypt)
- `security/secrets/external-secrets-operator.yaml` → `YOUR_DOMAIN` Vault URL (deploy.sh skips applying the `ClusterSecretStore` if the placeholder is still there)

## Phase 2–6 — Single command

```bash
# Required
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'   # preferred
# OR
export TF_VAR_proxmox_password='...'

# Optional (deploy.sh warns if unset, doesn't fail)
export TF_VAR_central_mimir_password=''
export TF_VAR_central_loki_password=''
export TF_VAR_alertmanager_slack_webhook=''
export TF_VAR_alertmanager_pagerduty_key=''

./scripts/deploy.sh
```

What runs:

| Phase | Step | Time |
|---|---|---|
| 2 | `terraform apply` on `terraform/proxmox/` — creates VMs, formats etcd/data disks via remote-exec, generates `rke2/configs/inventory.ini` + per-node configs | ~8–12 min |
| 3 | `install-master.sh` (init master + 2 joiners) → `install-worker.sh` → `install-alloy.sh` on each VM | ~12–18 min |
| 4 | Apply namespaces (with PSS labels), RBAC ClusterRoles + Bindings, NetworkPolicies, install cert-manager via Helm, apply ClusterIssuers, install ESO via Helm, generate 4 role-specific kubeconfigs signed by the cluster CA | ~4–6 min |
| 5 | `terraform apply` on `terraform/observability/` — kube-prometheus-stack via Helm, Prometheus configured to remote_write to central Mimir | ~5–8 min |
| 6 | Verify Cilium IngressController + Hubble + smoke-test Ingress | ~1 min |

Resume from a specific phase: `./scripts/deploy.sh --from phase4`.

Run only one phase: `./scripts/deploy.sh --only phase5`.

Dry-run (validate without applying): `./scripts/deploy.sh --dry-run`.

## Generated artifacts (gitignored)

| File | What |
|---|---|
| `.secrets/cluster_id_ed25519`, `.pub` | Terraform-generated keypair (unused if you provided `vm_ssh_public_key` in tfvars) |
| `.secrets/rke2-cluster-token` | The RKE2 join token, 64 hex chars. Reused across re-runs of `install-master.sh`. |
| `.secrets/kubeconfig-admin.yaml` | Admin kubeconfig retrieved from init master. Server URL is the **VIP** (`https://10.10.18.100:6443`) once kube-vip is up. |
| `rbac/kubeconfigs/kubeconfig-<role>-user.yaml` | 4 role-specific kubeconfigs, each with a unique cert signed by the cluster CA |
| `rke2/configs/inventory.ini` | Generated by terraform with master/worker IPs, used by install scripts |
| `rke2/configs/master-N-config.yaml`, `worker-N-config.yaml` | RKE2 server/agent config files |

---

# 5. Bootstrap Dependency Chain

This is the hard-won part. The first deploy of this stack hits a circular dependency that took 5+ rounds of debugging to map out. Understanding it explains every "weird" thing in the install scripts and config files.

## The cycle

```
        kube-vip needs apiserver  ←──┐
              ↓                       │ (to elect leader and bind VIP)
        apiserver lives at VIP        │
              ↓                       │
        VIP needs kube-vip ───────────┘  ← chicken-and-egg #1

        Cilium needs apiserver  ←─────┐
              ↓                       │ (k8sServiceHost setting)
        apiserver reachable           │
        via 'kubernetes' service      │
              ↓                       │
        'kubernetes' service          │
        needs kube-proxy or Cilium ───┘  ← chicken-and-egg #2
```

## How the scripts break the cycle

**Cilium k8sServiceHost = init master's direct IP, not the VIP.**
`install-master.sh` rewrites `CONTROL_PLANE_VIP_PLACEHOLDER` in `rke2-cilium-config.yaml` with the init master's address (e.g. `10.10.18.101`) before the manifest hits etcd. Cilium pods (hostNetwork) can reach that address before any service routing exists. Once Cilium is up, the VIP works too — but Cilium is configured to keep using the direct IP because it always works.

**kube-vip uses cluster DNS + hosts plugin to resolve `kubernetes`.**
kube-vip v0.7.2 hardcodes `https://kubernetes:6443` as the apiserver URL. Two fixes:
1. `dnsPolicy: ClusterFirstWithHostNet` on the kube-vip DaemonSet → DNS goes through CoreDNS instead of host `/etc/resolv.conf`.
2. A CoreDNS `HelmChartConfig` (`rke2/configs/rke2-coredns-config.yaml`) injects a `hosts` plugin: `<each master IP> kubernetes`. The apiserver listens on `:6443` on each master and its TLS cert SAN includes `DNS:kubernetes`, so `https://kubernetes:6443` connects and validates.

**kube-vip's IPVS LB is disabled** (`svc_enable: false`, `lb_enable: false`). It needs IPVS kernel modules to start the LB, and Cilium already does service LB via eBPF. We only use kube-vip for the control-plane VIP.

**Joiner masters and workers connect via init master's direct IP, not the VIP.**
Same reason — the VIP may not be up when a new node tries to join. `master-N-config.yaml` for non-init masters uses `server: https://<init-master-ip>:9345`. `install-worker.sh` rewrites the worker config the same way before upload.

**Local kubeconfig points at init master's IP, not the VIP** (after first deploy run).
`install-master.sh::retrieve_kubeconfig` does the rewrite. Once you've manually verified the VIP works, you can flip the kubeconfig to the VIP for fault-tolerance (`sed -i 's|10.10.18.101:6443|10.10.18.100:6443|' .secrets/kubeconfig-admin.yaml`).

## Why disable-kube-proxy needs both RKE2 and Cilium flags

`kubeProxyReplacement: true` in Cilium tells **Cilium** to take over service LB via eBPF. It does **not** stop RKE2 from deploying its built-in kube-proxy static pod. Both layers need to agree:

```yaml
# rke2-master-config.yaml + rke2-worker-config.yaml
disable-kube-proxy: true
```

Without this, both run in parallel — Cilium wins service traffic, but kube-proxy still wastes CPU programming iptables rules nothing reads.

---

# 6. RBAC — Roles, Groups, Kubeconfigs

Each role is a `ClusterRole` + `ClusterRoleBinding` to a Kubernetes Group. The kubeconfig generator embeds the group name in the client cert's `O=` field, which is how the API server identifies the user's groups.

| Group (cert `O=`) | Cluster scope | Namespaces | Exec/Attach/PF | Secrets | RBAC write |
|---|---|---|---|---|---|
| `senior-devops` | Full read+write on workloads/networking/storage | All | All namespaces | Yes | **No** (read-only) |
| `junior-devops` | Workloads only | All | Non-prod only (implicit — no grant in prod) | **No** | No |
| `developers` | Namespace list + cluster reads | `development` (full), `staging` (read) | `development` only | **No** | No |
| `read-only-auditors` | Full read | All | **No** | Metadata only (no `.data`) | No |

`rbac/scripts/generate-kubeconfigs.sh` creates 4 kubeconfigs in `rbac/kubeconfigs/`:

| File | Group | Cert validity |
|---|---|---|
| `kubeconfig-senior-devops-user.yaml` | `senior-devops` | 365 days |
| `kubeconfig-junior-devops-user.yaml` | `junior-devops` | 180 days |
| `kubeconfig-developer-user.yaml` | `developers` | 180 days |
| `kubeconfig-auditor-user.yaml` | `read-only-auditors` | 90 days |

Re-run the generator before expiry. Distribute over a secure channel (1Password / encrypted email — not Slack, not git).

**Pod Security Standards by namespace** (set on namespace labels, enforced at admission):

| Namespace | Enforcement |
|---|---|
| `production` | `restricted` (no privilege escalation, read-only root FS, drops capabilities) |
| `staging` | `baseline` (no host network, no privileged containers) |
| `development` | `baseline` (warn on `restricted` violations) |
| `monitoring` | `privileged` (Prometheus needs host metrics access) |
| `cert-manager` | `restricted` |

---

# 7. Security Hardening

## API server (per `rke2-master-config.yaml`)

- `anonymous-auth=false`, `authorization-mode=Node,RBAC`
- TLS 1.2 minimum, restricted cipher list
- `enable-admission-plugins=NodeRestriction,PodSecurity`
- Audit log: 30-day retention, 10 backups × 100 MB, captures RBAC changes, exec, secret access
- Audit log shipped by Alloy from `/var/log/rancher/rke2/server/logs/audit.log` via journald

## Worker kubelet

- `protect-kernel-defaults=true` — requires `vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1` (install-worker.sh sets these in `/etc/sysctl.d/99-rke2.conf`)
- `read-only-port=0` (kubelet's :10255 metric port disabled)
- `streaming-connection-idle-timeout=4h`
- Eviction: hard at memory < 500Mi, soft at < 1Gi (1m30s grace)

## etcd

- Heartbeat 250ms, election timeout 5000ms
- Quota 8 GB, auto-compaction every 8h
- Dedicated disk at `/var/lib/rancher/rke2/server/db` (separate `/dev/sdb`, formatted ext4 by Terraform's `null_resource.format_etcd_disk` provisioner)
- Auto-snapshot every 6h, 10 retained

## Network Policies (`security/network-policies/`)

Zero-trust default-deny on `production` and `staging`. Allow rules:
- DNS egress (UDP/TCP 53) to anywhere — required for everything
- Ingress from `kube-system` namespace (Cilium IngressController lives there)
- Ingress from `monitoring` namespace on ports 9090/9091/8080/8443 (Prometheus scrape)

`development` namespace: default-deny ingress only, all egress allowed (devs need to install packages, hit APIs).

## Inter-node encryption

Cilium's WireGuard: every packet between nodes is encrypted with a per-node keypair, transparent to pods. No application changes. `cilium status` shows the keys.

---

# 8. Observability

## What's in-cluster vs. centralized

**In this cluster (`monitoring` namespace):**
- Prometheus × 2 (HA, scrapes + remote-writes; 3-day local retention only)
- Alertmanager × 2 (HA, alert routing)
- kube-state-metrics (k8s object → metrics adapter)
- Prometheus Operator (CRDs)

**On each VM (systemd, not k8s):**
- Grafana Alloy

**Not deployed (centralized in your existing stack):**
- Grafana — you query from yours
- Mimir — receives remote-write
- Loki — receives push
- node-exporter — Alloy's `prometheus.exporter.unix` replaces it
- Promtail — Alloy replaces it

## Labels on every metric / log line

```
cluster      = "rke2-prod"
environment  = "production"
node         = "<hostname>"
role         = "master|worker"
namespace    = "<ns>"        # for pod logs
pod, container, level, trace_id   # auto-extracted for JSON logs
```

In central Grafana, filter every dashboard variable by `cluster="rke2-prod"`.

## Alertmanager routing

```
severity=critical|page  →  PagerDuty
severity=warning        →  Slack (#alerts-rke2-prod)
alertname=Watchdog      →  /dev/null (silenced, used by Mimir to confirm pipeline)
default                 →  Email
```

Inhibition: `critical` for `<alertname,namespace>` suppresses matching `warning` for 5 min.

## Useful Grafana dashboards to import (filter by `cluster`)

| ID | What |
|---|---|
| 7249 | Kubernetes Cluster Overview |
| 1860 | Node Exporter Full (works against Alloy) |
| 3070 | etcd |
| 13639 | Loki / pod logs |
| 16611 | Cilium + Hubble |
| 16450 | RKE2 Cluster |

---

# 9. Day-2: Scaling, Backup, Upgrade

## Add a worker (zero downtime)

```bash
# 1. terraform.tfvars
worker_count = 3
worker_ip_addresses = [
  "10.10.18.111",
  "10.10.18.112",
  "10.10.18.113",   # new
]

# 2. Apply — only the new VM is created
cd terraform/proxmox && terraform apply

# 3. Join — install-worker.sh skips workers already in the cluster
cd ../.. && ./rke2/scripts/install-worker.sh

# 4. Verify
kubectl get nodes -o wide
```

## Add masters (3 → 5, never 3 → 4)

etcd needs an odd count to keep quorum. Going 3→4 means a 2-vs-2 partition has no winner.

```bash
master_count = 5
master_ip_addresses = [...the three you have..., "10.10.18.104", "10.10.18.105"]

terraform apply -target='module.master_nodes[3]' -target='module.master_nodes[4]'
./rke2/scripts/install-master.sh   # joins via init master direct IP, idempotent
```

## etcd snapshots

Automatic every 6h. Manual on-demand:

```bash
ssh ubuntu@10.10.18.101
sudo /var/lib/rancher/rke2/bin/rke2 etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)
sudo /var/lib/rancher/rke2/bin/rke2 etcd-snapshot list
```

Stored at `/var/lib/rancher/rke2/server/db/snapshots/`. Copy to S3 / NFS daily via a cron — they're not exported automatically.

## RKE2 version upgrade (rolling, zero downtime)

```bash
TARGET="v1.33.x+rke2r1"

# 0. Snapshot first
ssh ubuntu@10.10.18.101 "sudo /var/lib/rancher/rke2/bin/rke2 etcd-snapshot save --name pre-${TARGET}"

# 1. Update tfvars rke2_version, run terraform apply (only regenerates inventory.ini + configs, no VM changes)

# 2. Init master first
ssh ubuntu@10.10.18.101 "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$TARGET INSTALL_RKE2_TYPE=server sh - && sudo systemctl restart rke2-server"
# wait until kubectl get nodes shows it Ready and the new version

# 3. Other masters, one at a time (same command on each)
# 4. Workers, drain → upgrade → uncordon
```

## Velero (apps + PVCs) — not deployed; suggested setup

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero -n velero --create-namespace ...
velero schedule create daily --schedule="0 2 * * *" --ttl 720h \
  --include-namespaces production,staging --snapshot-volumes
```

---

# 10. Uninstall — Destroy the Cluster

Clean teardown is **two terraform destroys, in this order**, plus a local-files mop-up. Order matters: the observability stack (Prometheus, Alertmanager, monitoring namespace) lives **inside** the cluster — if you kill the VMs first, terraform can't reach the API to delete the Helm release and `terraform destroy` will hang.

## 10.1 Set credentials

```bash
cd /path/to/infra-setup
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'    # same one used to deploy
```

## 10.2 Destroy in order

### (a) Observability — while the cluster is still up

```bash
cd terraform/observability
terraform destroy -auto-approve
cd ../..
```

Removes: `helm_release.kube_prometheus_stack`, the `kubectl_manifest` for infra alert rules, the `monitoring` namespace.

### (b) VMs + everything Terraform created on Proxmox

```bash
cd terraform/proxmox
terraform destroy -auto-approve
cd ../..
```

Removes:

- 5 VMs (`401/402/403/410/411`)
- Their etcd-disk and worker-data-disk format `null_resource`s
- The cloud-init common snippet on Proxmox `local` storage
- The Terraform-generated SSH keypair in `.secrets/`
- `rke2/configs/inventory.ini` and every `master-N-config.yaml` / `worker-N-config.yaml`

## 10.3 Files Terraform doesn't manage

The install scripts and kubectl applies created several artifacts outside Terraform's view. Remove them:

```bash
rm -rf .secrets/                # kubeconfig-admin.yaml, rke2-cluster-token (script-generated)
rm -rf .logs/                   # deploy run logs
rm -rf rbac/kubeconfigs/        # 4 role-specific kubeconfigs
rm -rf rbac/certs/              # per-role private keys (if present)
rm -f  terraform/proxmox/cluster.tfplan terraform/observability/obs.tfplan

# Stale SSH host keys (the dead VMs' fingerprints in known_hosts)
for ip in 10.10.18.101 10.10.18.102 10.10.18.103 10.10.18.111 10.10.18.112; do
  ssh-keygen -R "$ip" -f ~/.ssh/known_hosts 2>/dev/null
done
```

## 10.4 (Optional) Wipe terraform state + provider downloads

Only do this if you're sure you won't redeploy soon. State files remain on disk after a `destroy`, just empty.

```bash
rm -f  terraform/proxmox/terraform.tfstate*
rm -f  terraform/observability/terraform.tfstate*
rm -rf terraform/proxmox/.terraform terraform/observability/.terraform
```

## 10.5 Verify

```bash
# On Proxmox host — should print nothing
ssh root@<proxmox-ip> "qm list | awk '\$1 ~ /^(40[1-3]|41[01])$/'"

# Locally
git status   # only gitignored leftovers should appear; no surprises
```

## 10.6 Gotchas

- **If the cluster is already dead** when you reach step (a), `terraform destroy` will hang trying to reach the apiserver. Recover by removing the orphaned resources from state first:

  ```bash
  cd terraform/observability
  terraform state list | xargs -n1 terraform state rm
  terraform destroy -auto-approve   # now a no-op
  ```

- **Proxmox API token** keeps working after destroy. Revoke if you're not redeploying:

  ```bash
  ssh root@<proxmox-ip> "pveum user token remove terraform@pve terraform"
  ```

- **What Terraform does NOT touch** (persists for future deploys):
  - The Ubuntu 22.04 cloud-init template VM (e.g. ID `9200`) — that was Phase-1 manual setup
  - The Proxmox storage pool, network bridge (`vmbrk8s`), the `terraform@pve` user/role
  - Your `~/.ssh/rke2_cluster_id` keypair (it's your key, not Terraform's)
  - Your central Mimir/Loki/Grafana stack (it was never inside the cluster)

- **In-cluster Kubernetes resources** (RBAC, NetworkPolicies, cert-manager Helm release, ESO Helm release, the ClusterIssuers) were created via `kubectl`/`helm`, not Terraform. They disappear with the cluster — no separate teardown needed.

---

# 11. Troubleshooting Cheatsheet

| Symptom | First check | Likely cause |
|---|---|---|
| `kubectl: connection refused` to VIP | `for ip in masters; do ssh $ip 'ip addr | grep 10.10.18.100'; done` — is the VIP bound anywhere? | kube-vip not advertising. Check `kubectl logs -n kube-system -l app=kube-vip-ds` for DNS errors → CoreDNS hosts plugin missing |
| Node `NotReady` (fresh deploy) | `kubectl describe pod -n kube-system cilium-XXX` — `Insufficient memory`? | Master RAM < 8 GB. Bump tfvars `master_memory_mb=8192` |
| Worker rke2-agent in restart loop | `journalctl -u rke2-agent` → "Kubelet exited" | Check `tail /var/lib/rancher/rke2/agent/logs/kubelet.log`. Common: `invalid kernel flag: vm/overcommit_memory` (missing sysctl) or `unknown 'kubernetes.io' label` (self-applied role label) |
| `helm install` fails: `namespace already exists` | `kubectl get ns monitoring -o yaml` | Phase 4 created it. `terraform import module.prometheus_stack.kubernetes_namespace.monitoring monitoring` |
| Cilium DaemonSet `Pending` | `kubectl describe pod -n kube-system cilium-XXX` | Usually node taints (NotReady) or insufficient memory |
| `kubectl exec` returns Forbidden | `kubectl auth can-i create pods/exec --as-group=<group>` | RBAC: junior-devops can't exec in production (intentional) |
| Cert-manager certs not issuing | `kubectl describe certificate <name>` | Usually wrong email in ClusterIssuer, or HTTP-01 challenge can't reach the domain |
| Loki has no logs | `ssh <node> 'systemctl status alloy; journalctl -u alloy -n 20'` | Alloy systemd unit failing — check `/etc/alloy/config.alloy` |
| Mimir has no metrics | Prometheus UI → Status → Targets | ServiceMonitor label mismatch most common |

## Health-check one-liners

```bash
# Cluster
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl top nodes; kubectl top pods -A --sort-by=memory | head -20

# etcd
ETCD_POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -1)
kubectl -n kube-system exec "$ETCD_POD" -- etcdctl endpoint health --cluster \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server.key

# Cilium
kubectl exec -n kube-system ds/cilium -- cilium-dbg status
kubectl exec -n kube-system ds/cilium -- cilium connectivity test  # full ping/HTTP test

# kube-vip leader election state
kubectl get lease -n kube-system plndr-cp-lock -o yaml
```

---

# 12. Variable Reference

## Required environment variables before `deploy.sh`

```bash
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'   # preferred
# OR
export TF_VAR_proxmox_password='...'

# Optional — warn-only if unset
export TF_VAR_central_mimir_password=''
export TF_VAR_central_loki_password=''
export TF_VAR_alertmanager_slack_webhook=''
export TF_VAR_alertmanager_pagerduty_key=''
```

## Key Proxmox tfvars

| Variable | Default | Notes |
|---|---|---|
| `proxmox_api_url` | — | `https://<proxmox-host>:8006/api2/json` |
| `proxmox_node` | — | e.g. `pve-4` |
| `network_bridge` | `vmbr0` | This cluster uses `vmbrk8s` |
| `network_subnet_cidr` | — | `10.10.18.0/24` for this cluster |
| `network_gateway` | — | `10.10.18.1` |
| `master_count` | 3 | Must be odd (validated) |
| `master_memory_mb` | 8192 | **Less than 8 GB will fail** — Cilium + Hubble + control plane all in 4 GB hits eviction |
| `master_cpu_cores` | 4 | |
| `master_etcd_disk_size_gb` | 20 | Separate disk — keep etcd fsync off the OS disk |
| `worker_memory_mb` | 16384 | |
| `worker_data_disk_size_gb` | 200 | `/var/lib/rancher` — container images + PVCs |
| `control_plane_vip` | — | Free IP in subnet; kube-vip will hold it |
| `control_plane_vip_interface` | `eth0` | The actual NIC inside the VM (Ubuntu cloud-init renames may apply) |
| `rke2_version` | `v1.32.10+rke2r1` | |
| `vm_ssh_public_key` | — | Paste `~/.ssh/rke2_cluster_id.pub` contents here |

## Port reference

| Port | Component | Notes |
|---|---|---|
| 6443/TCP | kube-apiserver | Behind the VIP for HA |
| 9345/TCP | RKE2 server | Node join — joiners hit init master direct IP |
| 2379-2380/TCP | etcd | client + peer |
| 10250/TCP | kubelet | metrics + API |
| 9962/TCP | Cilium | Prometheus metrics |
| 4244/TCP | Hubble | relay |
| 9090/TCP | Prometheus | local UI; not exposed externally |
| 12345/TCP | Alloy | health endpoint, localhost-only |

---

*Last updated: 2026-05-18 | Cluster: `rke2-prod` | RKE2 v1.32.10+rke2r1, Cilium v1.18 (kube-proxy replacement + L2 announcements + LB IPAM), kube-vip control-plane VIP, ArgoCD for GitOps*
