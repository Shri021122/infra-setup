# Cluster Handbook — `dealing`

> Plain-English guide to every component on this cluster. For each one:
> **Who** uses or maintains it, **What** it does, **How** it works in 30 seconds,
> and **Why** we chose it over alternatives.
>
> Audience: DevOps team. Assumes you know Kubernetes basics (Pod, Service,
> Deployment, NetworkPolicy) but not necessarily the specific tools we run.

## Table of contents

1. [The shape of the cluster](#1-the-shape-of-the-cluster)
2. [Proxmox — the virtualization layer](#2-proxmox)
3. [RKE2 — the Kubernetes distribution](#3-rke2)
4. [etcd — the cluster's brain](#4-etcd)
5. [kube-vip — control-plane high availability](#5-kube-vip)
6. [Cilium — networking, security, and ingress](#6-cilium)
7. [Hubble — flow observability](#7-hubble)
8. [CoreDNS — service-name DNS](#8-coredns)
9. [cert-manager — TLS certificates](#9-cert-manager)
10. [external-secrets — secret synchronization](#10-external-secrets)
11. [ArgoCD — GitOps](#11-argocd)
12. [kube-prometheus-stack — in-cluster metrics scraping](#12-kube-prometheus-stack)
13. [Grafana Alloy — node-level scraping & log shipping](#13-grafana-alloy)
14. [Mimir — long-term metrics store (off-cluster)](#14-mimir)
15. [Loki — log store (off-cluster)](#15-loki)
16. [Grafana — visualization & alerts](#16-grafana)
17. [Microsoft Teams — alert sink](#17-microsoft-teams)
18. [Kubernetes NetworkPolicy & Cilium NetworkPolicy](#18-network-policy)
19. [PodSecurityStandards (PSS)](#19-pss)
20. [Kyverno — policy enforcement](#20-kyverno)
21. [RKE2 bundled add-ons](#21-rke2-add-ons)
22. [Terraform & the IaC layout](#22-terraform-and-iac)
23. [Pritunl jump server (the access path)](#23-pritunl)

---

## 1. The shape of the cluster

Before any of the named components, here's the physical picture.

- The cluster runs on **6 virtual machines** in your Proxmox cluster. All on the same VLAN (`10.10.120.0/24`).
- **3 are control-plane ("master") nodes**: `dealing-m-1/2/3` at `10.10.120.131-133`.
- **3 are worker nodes**: `dealing-w-1/2/3` at `10.10.120.134-136`.
- The control plane is reached through a single floating IP — `10.10.120.138` — that automatically moves to whichever master is currently the leader.
- External users reach apps via another floating IP — `10.10.120.140` — that the ingress controller owns.
- Each VM has two disks: a 50 GB OS disk and a smaller dedicated etcd disk (20 GB on masters, or a 20 GB data disk on workers).
- All VM-to-VM pod traffic across hosts is encrypted with WireGuard. App-to-app traffic on the same host is not (no need; it never leaves the host).
- Three off-cluster services are central, shared by every cluster your org runs: **Mimir** (metrics), **Loki** (logs), **Grafana** (dashboards + alerts). All at `*.stackflow.org`.

When you hear "the cluster," that's the 6 VMs. When you hear "the observability stack," some of it runs on-cluster (Prometheus, Alloy) and the storage/UI sits off-cluster.

---

## 2. Proxmox

- **Who:** The infrastructure team that owns the physical hardware.
- **What:** Open-source virtualization platform. Runs the 6 VMs that make up the dealing cluster.
- **How:** Proxmox combines KVM (the Linux kernel hypervisor) with a web UI and a CLI for managing VMs, storage, and networking. We tell Terraform what VMs to create; Terraform calls Proxmox's API; Proxmox spawns the VMs on top of the underlying hardware.
- **Why:** Open-source, no per-CPU license cost, mature, runs anywhere you can install Linux. Strong enough for production. Alternatives (vSphere, Hyper-V, OpenStack) would either cost real money or be much heavier to operate.

---

## 3. RKE2

- **Who:** Anyone running `kubectl` is using it indirectly. The DevOps team owns the upgrades.
- **What:** A Kubernetes distribution from Rancher/SUSE. Specifically, **RKE2 = "Rancher Kubernetes Engine 2"**.
- **How:** RKE2 is shipped as a single binary that, when started as a systemd unit, downloads and runs the Kubernetes core components (apiserver, controller-manager, scheduler, etcd) as **static pods** managed by kubelet. It also auto-deploys some bundled add-ons (Cilium-as-CNI, CoreDNS, metrics-server, snapshot-controller) using a built-in Helm controller that watches files in `/var/lib/rancher/rke2/server/manifests/`.
- **Why:** Faster setup than vanilla kubeadm, secure defaults (CIS-benchmark compliant, FIPS-friendly), runs on bare metal or VMs equally well, free, and from the same vendor as Rancher (so the upgrade path stays predictable). The alternative — kubeadm — works but you'd have to wire up everything RKE2 does for free yourself.

---

## 4. etcd

- **Who:** The Kubernetes control plane uses it. As a human, you should rarely touch it — but when it gets slow, the whole cluster gets slow, so you should know it's there.
- **What:** A small, strongly-consistent database that stores every single Kubernetes object (every Pod definition, every Service, every Secret, every NetworkPolicy). It runs as a 3-node cluster (one on each master) using the Raft consensus algorithm.
- **How:** Every write to the Kubernetes API ultimately ends up as a write to etcd. The apiserver is just an HTTPS wrapper with auth and validation; the data lives in etcd. The 3 etcd instances elect a leader; the leader accepts writes and replicates them to the others. As long as 2 of the 3 are alive, the cluster is fine.
- **Why:** Required by Kubernetes — apiserver only knows how to talk to etcd (in standard upstream; some distros like k3s have alternatives). The interesting choices we made:
  - **Dedicated disk per master** (the 20 GB `scsi1` we discussed) so etcd's fsync I/O doesn't fight with anything else for disk time.
  - **8 GB quota** (`quota-backend-bytes`) — once etcd's on-disk size hits this, the cluster goes read-only. We size for headroom.
  - **6h snapshots, 10 retained** — local snapshots automatically taken; restore from one if the cluster catches fire.
  - **Performance-tuned heartbeat/election timeouts** — slightly more aggressive than defaults, suitable for our local network.

---

## 5. kube-vip

- **Who:** Mostly invisible. It just makes the cluster API reachable at one IP no matter which master you actually connect to.
- **What:** A small daemon that runs on every master node. The three instances elect a leader; whoever wins claims the floating IP `10.10.120.138` and answers traffic for it. If the leader dies or loses a network heartbeat, another instance takes the IP within seconds.
- **How:** Two parts:
  1. **ARP-based VIP** (control plane): the three kube-vip instances talk among themselves via the kube-apiserver. The leader sends ARP packets advertising `10.10.120.138 → leader's MAC address` on the local L2. Other hosts on the VLAN update their ARP tables and route traffic to whoever is the current leader.
  2. **Service load-balancer** mode (optional, not in use here — Cilium provides this instead).
- **Why:** We need a single, stable IP for the kubeconfig and worker `--server=…` URLs. The alternatives:
  - **External load-balancer** (F5, HAProxy box) — needs hardware and ops, and is itself a SPOF or yet another HA system.
  - **MetalLB** — works but doesn't do control-plane VIPs.
  - **DNS round-robin** to all 3 masters — slow failover (DNS TTL) and many clients don't honor it.

  kube-vip is just three small pods, zero external dependencies, and the failover is fast (~3 seconds).

---

## 6. Cilium

This is the biggest single piece. Read this section if you read no other.

- **Who:** Every pod's network traffic passes through Cilium. The DevOps team writes NetworkPolicies and CCNPs that Cilium enforces.
- **What:** Cilium replaces the Kubernetes CNI plugin **and** kube-proxy **and** the Ingress controller, all with one set of BPF programs that run inside the Linux kernel.

What does it actually do for the cluster?

### 6.1 Pod networking (the CNI part)

Every pod gets an IP from a `/24` block carved out for its node (e.g. `10.42.4.0/24` on `dealing-w-1`). When a pod sends a packet, the BPF program on its node decides where the packet goes:
- If the destination IP is on the same node → BPF redirects it directly to the destination pod (no network hop).
- If the destination IP is on another node → BPF wraps it in a **vxlan** tunnel and ships it to the other node, where another BPF program unwraps it and delivers to the destination pod.
- Pod-to-pod traffic between nodes is also encrypted with WireGuard (so the vxlan packet rides inside a WG tunnel on the wire).

The **kube-proxy replacement** part means there's no iptables-based DNAT for Service IPs. Cilium's BPF maintains a small in-kernel map of Service IP → backend pod IP and rewrites destination addresses there. Much faster than iptables (which scales linearly with rule count).

### 6.2 L2 announcements

Cilium watches Kubernetes Services of type LoadBalancer that have a designated VIP. For each, **one Cilium agent (the leader for that VIP) sends ARP packets on the LAN saying "I'm the answer for this IP."** That's how `10.10.120.140` (the IngressController) becomes reachable from anywhere on `10.10.120.0/24`. Failover works the same way as kube-vip — if the leader Cilium agent fails, another takes over.

This replaces MetalLB. Same idea, but built into Cilium and uses the same identity/policy machinery for security.

### 6.3 IngressController + Gateway API

Standard Kubernetes Ingress resources (and the newer Gateway API resources) get picked up by Cilium and turned into Envoy configuration. **Envoy runs embedded inside each cilium-agent pod** — it's the L7 proxy that terminates TLS and routes incoming HTTPS by hostname (e.g. `argocd.dealing.internal`) to the right backend Service.

This is the path: browser → `10.10.120.140:443` → Cilium L2 LB → Envoy in cilium-agent → backend Service → backend pod.

### 6.4 WireGuard node-to-node encryption

`encryption.enabled: true, type: wireguard`. Every Cilium agent sets up a WireGuard interface (`cilium_wg0`) and establishes peers with every other agent. Pod-to-pod traffic across nodes goes through this WG mesh, encrypted with modern Noise-protocol cryptography.

What we explicitly do NOT do: **`nodeEncryption: false`** — encrypting pod-to-node-host-IP traffic with WG. We tried, it broke metrics scraping for reasons buried in the Cilium 1.18 datapath. Pod-to-pod (the security-meaningful traffic) is still encrypted; pod-to-host-IP traffic rides the vxlan tunnel un-WG'd (still on the private VLAN).

### 6.5 NetworkPolicy enforcement

Both vanilla Kubernetes `NetworkPolicy` and Cilium's richer `CiliumNetworkPolicy` / `CiliumClusterwideNetworkPolicy` get compiled into BPF programs. When a packet hits the BPF, it's checked against the policy in O(1) time per rule.

- **Who:** Application/security teams write policies. Cilium enforces.
- **Why Cilium policies over plain K8s:** Cilium can match by labels, identities, FQDNs, L7 (HTTP methods, paths, DNS queries), and reserved identities. Plain K8s NetworkPolicy is L3/L4-only and only IP-based.

### Cilium summary

**Why we chose Cilium over alternatives (Calico, Flannel, Weave, …):**
- Replaces THREE other components (CNI + kube-proxy + Ingress controller), so we run fewer moving parts.
- BPF datapath is faster than iptables-based ones for non-trivial cluster sizes.
- Hubble (next section) gives flow-level observability nothing else matches.
- One vendor's docs and support, not three.

---

## 7. Hubble

- **Who:** SRE/DevOps debugging "why can't X talk to Y." Also feeds Grafana dashboards for network visibility.
- **What:** A network flow logger and metrics exporter built into Cilium. Every packet decision Cilium makes (forward / drop / encrypt) generates a flow event.
- **How:** Three pieces:
  - **`hubble-agent`** — runs inside every cilium-agent pod (DaemonSet). Reads BPF events from the kernel ring buffer in real time.
  - **`hubble-relay`** — one deployment that fans out queries to every hubble-agent and aggregates results. The single endpoint your Hubble UI or CLI talks to.
  - **`hubble-ui`** — web UI that visualizes flows in real time. Reachable at `hubble.cluster.internal`.
- **Why:** When something networking-related breaks (a NetworkPolicy denies, a Service IP doesn't resolve, an Envoy 403s), `hubble observe --verdict DROPPED` tells you exactly which packet was dropped and why. It's the single highest-leverage debugging tool for this cluster. We've already used it three times this week.

Note: Hubble doesn't capture L7 (HTTP/DNS) content unless a CiliumNetworkPolicy with `http: []` or `dns: []` rules is in effect on the relevant pods. Cilium's IngressController traffic IS L7-parsed by Envoy and produces `hubble_http_*` metrics, but pod-to-pod HTTP between workloads is L4-only until we opt in.

---

## 8. CoreDNS

- **Who:** Every pod resolves DNS through CoreDNS. Almost always invisible.
- **What:** A Go-based DNS server. Runs as 2 replicas (Deployment) and is the default cluster DNS server (`10.43.0.10`).
- **How:** It has plugins for different DNS functions chained in a "Corefile." Ours:
  - `hosts` block adds custom static entries (we add `mimir.stackflow.org → 10.10.103.203` here because external secrets weren't an option).
  - `kubernetes` plugin: resolves `*.svc.cluster.local` names by querying the Kubernetes apiserver for matching Services.
  - `forward . /etc/resolv.conf` plugin: anything else, forward to the node's upstream DNS.
- **Why:** Standard Kubernetes DNS implementation. Ships with RKE2 by default. Alternative would be `kube-dns` (older, slower).

---

## 9. cert-manager

- **Who:** Anyone declaring a `Certificate` or annotating an `Ingress` with `cert-manager.io/cluster-issuer: ...`. Largely automatic.
- **What:** The cert-issuance robot. You declare a `Certificate` resource (or rely on automatic issuance via Ingress annotations); cert-manager generates a CSR, talks to a CA (Let's Encrypt, an internal CA, etc.), gets a signed cert back, and stores it in a Kubernetes Secret.
- **How:** Three pods:
  - **`cert-manager`** controller — does the work (talk to CA, store secret).
  - **`cert-manager-cainjector`** — auto-injects CA bundles into webhooks/APIService objects that need them.
  - **`cert-manager-webhook`** — validates Certificate/Issuer YAML at API admission time.

  Issuers in this cluster:
  - `cluster-ca-issuer` (Ready) — internal CA, used for `*.dealing.internal` and `*.cluster.internal`.
  - `selfsigned-issuer` (Ready) — bootstrap CA.
  - `letsencrypt-prod` / `letsencrypt-staging` (Not Ready) — configured but ACME solver isn't fully wired up. Out of scope today.
- **Why:** Renewal is automated, expiry monitoring is built in, and the same code works against private CAs and public Let's Encrypt. Doing this by hand for every Ingress would be a half-time job.

---

## 10. external-secrets

- **Who:** The team's plan was for apps to declare an `ExternalSecret` and have it auto-sync from a central secret backend (HashiCorp Vault, Azure Key Vault, AWS Secrets Manager, etc.).
- **What:** A controller that watches `ExternalSecret` resources, fetches the actual secret from a backend, and writes it as a Kubernetes `Secret`.
- **How:** You configure a `ClusterSecretStore` once (telling it where the backend lives and how to authenticate). Then every `ExternalSecret` references the store and names which secret to fetch.
- **Why:** Avoids committing secrets to Git. Lets the security team rotate secrets centrally without needing to redeploy every app.

**Status on this cluster:** Deployed, but **not configured**. There's no `ClusterSecretStore` defined, and no `ExternalSecret` resources exist. Currently three pods doing nothing. Either pick a backend or remove the install.

---

## 11. ArgoCD

- **Who:** Anyone deploying applications to the cluster. The team's deploy pattern.
- **What:** GitOps controller. You commit a Helm/Kustomize/plain-YAML app to a Git repo; you write an `Application` resource pointing at that repo path; ArgoCD pulls the manifests and `kubectl apply`s them to the cluster. It continuously checks Git and reconciles drift.
- **How:** Several pods working together:
  - **`argocd-application-controller`** (StatefulSet) — the reconcile loop.
  - **`argocd-repo-server`** — clones git repos and renders manifests.
  - **`argocd-server`** — the web UI and API.
  - **`argocd-applicationset-controller`** — generates multiple Applications from one template (good for multi-cluster).
  - **`argocd-notifications-controller`** — sends events to Slack/Teams/webhook.
  - **`argocd-redis`** — caches manifest renders.
- **Why:** GitOps means "the cluster state is whatever the Git repo says." Audit trail, rollback by `git revert`, no one ever `kubectl apply`-s by hand again. Argo specifically (vs. Flux) has a much better web UI for inspecting application state and diffing live vs. Git.

**Status on this cluster:** Argo is running and reachable at `argocd.dealing.internal`, but **no Applications are defined yet** — Argo is idle. Once you start deploying workloads, you'll register Applications.

Admin password (initial): in Secret `argocd/argocd-initial-admin-secret`. Currently `JVIA0NfztsCBPvGs`. Change it.

---

## 12. kube-prometheus-stack

The metrics-scraping side of observability lives inside the cluster.

- **Who:** SRE/DevOps. Your dashboards and alerts ultimately read from data scraped here.
- **What:** A Helm chart that bundles Prometheus, the Prometheus Operator, kube-state-metrics, and (optionally) Alertmanager + Grafana. We use the first three; we send alerts via Grafana instead of the bundled Alertmanager.
- **How:**

  - **Prometheus Operator** is a controller that creates Prometheus pods based on a `Prometheus` CR you define. It watches `ServiceMonitor` and `PodMonitor` resources and tells Prometheus to scrape those endpoints. Effectively a templating system on top of the raw Prometheus config.

  - **Prometheus** (one StatefulSet pod, `prometheus-kube-prometheus-stack-prometheus-0`) pulls metrics every 30 seconds from every endpoint covered by a `ServiceMonitor`. It stores them locally for ~2 hours (for fast queries during incidents) and `remote-writes` them to **Mimir** for long-term storage. Mimir is the single source of truth; the local Prometheus is just a buffer.

  - **kube-state-metrics (KSM)** is a separate process that talks to the Kubernetes API and emits one Prometheus metric per K8s object property. `kube_node_status_condition`, `kube_pod_container_status_restarts_total`, etc. — these all come from KSM, not from the kubelet.

- **Why:**
  - Prometheus is the de-facto standard. Everything that emits metrics speaks the Prometheus exposition format.
  - The Operator removes the need to hand-edit Prometheus configs; the `ServiceMonitor` model is much more Kubernetes-native.
  - KSM is the only good way to get object-state metrics into Prometheus (the apiserver itself doesn't expose them as metrics).

---

## 13. Grafana Alloy

- **Who:** Runs as a systemd unit on every cluster node. You don't interact with it day-to-day; it just runs.
- **What:** A combined metrics exporter + log forwarder. Replaces what would otherwise be **two separate processes**: node_exporter (for host metrics) and Promtail (for log shipping).
- **How:** Alloy uses a config language (called Alloy syntax — it's River/HCL-ish). Our config does three things on each node:
  1. **`prometheus.exporter.unix`** — exposes node-level metrics (CPU, RAM, disk, network, processes) on a local port.
  2. **`prometheus.scrape "node_metrics"`** — scrapes that local port every 15s and `remote-writes` the results to Mimir.
  3. **`loki.source.file`** — tails `/var/log/pods/**/*.log`, parses CRI log format, and ships each log line to Loki.

  Both writes go to `mimir.stackflow.org` / `loki.stackflow.org` and carry the label `cluster_name=dealing` so we can filter to this cluster in Grafana.

- **Why:**
  - Running as systemd (not as a Pod) means it can read `/sys/`, `/proc/`, and `/var/log/pods/` natively without privileged container shenanigans.
  - Single binary = one less DaemonSet to manage. The chart's `nodeExporter` and Promtail are both disabled because Alloy covers both.
  - Alloy is from the same vendor (Grafana Labs) as the rest of our observability stack — Mimir, Loki, Grafana — so the integration is well-supported.

---

## 14. Mimir

- **Who:** Where every metric ultimately lives. Queried by Grafana.
- **What:** A horizontally scalable Prometheus-compatible long-term metrics store. Off-cluster — runs at `mimir.stackflow.org` and is shared across all your org's clusters (10 of them today).
- **How:** Mimir accepts Prometheus's `remote-write` protocol over HTTP. Each cluster's Prometheus + Alloy push metrics in; Mimir spreads them across object storage (S3/GCS/disk) with millisecond-level query response thanks to a tiered query engine. Multi-tenancy is per-cluster via the `X-Scope-OrgID` HTTP header (we send `dealing`).
- **Why:**
  - Single-replica Prometheus can't store more than a few weeks of data; Mimir keeps months/years.
  - Sharing one Mimir across clusters means one Grafana, one set of dashboards.
  - Open-source (AGPL'd), no vendor lock-in.

  Alternatives — Thanos (similar architecture, slightly older), Cortex (predecessor), VictoriaMetrics (different ecosystem). Mimir's the most actively developed of the bunch.

---

## 15. Loki

- **Who:** Same role as Mimir, but for logs.
- **What:** A horizontally scalable, Prometheus-style log store. Off-cluster at `loki.stackflow.org`.
- **How:** Logs come in tagged with labels (just like Prometheus metrics). The labels are indexed; the log bodies are stored in object storage. You query with **LogQL** which looks like PromQL but operates on log lines. Alloy on each node ships logs there.
- **Why:** Cheap log storage (you only pay for object storage), tag-based not full-text-index-based (so it scales without breaking the bank like ELK does), and same labels/auth model as Mimir so one mental model.

---

## 16. Grafana

- **Who:** Where humans look at dashboards and where alerts fire from. Off-cluster.
- **What:** The visualization layer over Mimir, Loki, and other data sources. Also the alerting engine you've chosen.
- **How:** Grafana has data-source connections to Mimir (metrics) and Loki (logs). Dashboards (we have 5 in the `new-kube-cluster` folder) render queries against those sources. **Grafana managed alerts** evaluate PromQL queries on a schedule and fire alerts to **contact points** — for you, a Microsoft Teams webhook.
- **Why:** Universal interface to multiple backends; team can switch the storage layer underneath without changing dashboards. Alerting in Grafana (rather than Prometheus's Alertmanager) means one place to define + route alerts.

---

## 17. Microsoft Teams

- **Who:** Your on-call destination.
- **What:** Where alerts arrive.
- **How:** Grafana posts JSON to a Teams webhook URL. Teams renders it as a card in the configured channel.
- **Why:** Your org uses Teams. The integration is straightforward (caveat: Microsoft is deprecating the legacy "Incoming Webhook" connector in 2025; the replacement is "Workflows" — same general idea, different URL format).

---

## 18. Network policy (K8s + Cilium)

- **Who:** Security/platform team writes them. Cilium enforces them.
- **What:** Rules about which pods/identities can talk to which other pods/identities/CIDRs. Three resource types in play:

  | Resource | Scope | Capability |
  |---|---|---|
  | `networking.k8s.io/v1 NetworkPolicy` | Namespace | L3/L4 only (IP, port). Doesn't match Cilium reserved identities. |
  | `cilium.io/v2 CiliumNetworkPolicy` (CNP) | Namespace | L3/L4/L7 (HTTP method/path, DNS query patterns). Matches identities. |
  | `cilium.io/v2 CiliumClusterwideNetworkPolicy` (CCNP) | Cluster | Same as CNP but global. |

- **How:** Whichever resources select a pod, that pod enters default-deny for the directions declared (ingress or egress). Each rule's `to`/`from` clause adds an allowance. The CNI's BPF programs evaluate matches in O(1).

- **Why:** Defense in depth. Even if a pod is compromised, it can only talk where policy allows. Critical when running multi-tenant or production workloads.

**The big footgun:** an empty selector (`{}`) matches every endpoint including reserved identities (`ingress`, `host`, `world`, `kube-apiserver`). Use `matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]` to match all real pods but skip reserved identities. See [`policy-reviewer.md`](./policy-reviewer.md).

---

## 19. PodSecurityStandards (PSS)

- **Who:** Kubernetes admission controller. Activated by labels on namespaces.
- **What:** Three pre-defined security profiles for what a Pod is allowed to declare in its `spec`. Replaces the deprecated PodSecurityPolicy (PSP).
- **How:** You label a namespace with `pod-security.kubernetes.io/enforce: <profile>` (or `audit` / `warn`). Profiles:

  | Profile | Permits |
  |---|---|
  | `privileged` | Everything. No restrictions. Use for system namespaces only. |
  | `baseline` | Disallows obvious privilege escalation: hostPID, hostNetwork, hostPath (most uses), privileged containers, dangerous capabilities. |
  | `restricted` | Hardened: only runs as non-root, must drop all caps, seccomp required, no host-* anything. |

  Current state on dealing:
  - `production` → `restricted`
  - `staging`, `development`, `argocd` → `baseline`
  - `cert-manager` → `restricted`
  - `monitoring` → `privileged` (Prometheus needs hostPath)
  - `external-secrets`, `kube-system`, `default` → no label

- **Why:** Cheap, builtin, no extra controller. Apply once, get hard guarantees forever.

---

## 20. Kyverno

- **Who:** All admission requests pass through Kyverno's webhook. As a human, you write ClusterPolicies.
- **What:** Policy-as-code engine for Kubernetes. Validates, mutates, or generates resources at admission time based on rules you write in YAML.
- **How:** Same admission-webhook pattern as cert-manager and the Prometheus operator. The apiserver POSTs every incoming resource to Kyverno's webhook; Kyverno evaluates each `ClusterPolicy` whose `match` block applies; if any policy says reject, the request fails.

  Our current single policy (`ccnp-no-empty-endpoint-selector`) blocks CCNPs with `endpointSelector: {}` — the specific bug that broke Ingress on 2026-05-20.

- **Why:**
  - Rules become code that runs every time. Humans forget; webhooks don't.
  - YAML syntax, no Rego (unlike OPA/Gatekeeper, the main alternative). Lower learning curve.
  - Can also do mutating (inject default labels, set default resources) and generating (auto-create NetworkPolicies for new namespaces). We start narrow but the surface is broad.

**Cost trade-off to be aware of:** Kyverno is in the write path for every API call. If it's down with `failurePolicy: Fail` (default), no one can apply YAML. With `Ignore`, policies stop being enforced silently. We run 2 admission-controller replicas and check it's alive via Kyverno's own metrics.

---

## 21. RKE2 bundled add-ons

Smaller pieces RKE2 ships and we leave at defaults.

| Add-on | What it does | Why |
|---|---|---|
| **CoreDNS** | Cluster DNS (covered in §8) | Standard. |
| **rke2-metrics-server** | Powers `kubectl top` and HPA resource scaling | Required by HPA. Cheap. |
| **rke2-snapshot-controller** | Watches `VolumeSnapshot` CRs and triggers CSI snapshot calls | Future-proofing for stateful workloads. Currently no PVCs exist, so it sits idle. |
| **rke2-runtimeclasses** | Pre-defines `RuntimeClass` resources for non-default runtimes (gVisor, etc.) | Unused today. |
| **rke2-ingress-nginx** | (Disabled — Cilium IngressController replaces it) | We picked Cilium's instead. |

---

## 22. Terraform & the IaC layout

The whole cluster is defined as code under `terraform/` and `clusters/`. High level:

```
terraform/
  proxmox/                    # 6 VMs definition (modules: master_node, worker_node)
    modules/master_node/      # one VM definition per master, with 2 disks
    modules/worker_node/      # one VM definition per worker, with 2 disks
    templates/                # cloud-init template files
  observability/              # kube-prometheus-stack + alerts deployment
    modules/prometheus/       # the Helm release wrapped in TF
  argocd/                     # ArgoCD install (Helm)
  (per cluster: additional terraform code for cert-manager, external-secrets, etc.)

clusters/
  dealing/                    # per-cluster vars + state
    proxmox.tfvars            # disk sizes, VM counts, network ranges
    observability.tfvars      # cluster-name, Mimir creds, alert webhooks
    argocd.tfvars             # ArgoCD bootstrap config
    kubeconfig.yaml           # admin kubeconfig (writeable only by ops)
    tfstate/                  # terraform state

rke2/
  configs/                    # rendered per-master/worker RKE2 configs (gitignored)
  scripts/                    # install scripts (install-master.sh, install-worker.sh, install-alloy.sh)
  configs/audit-policy.yaml   # apiserver audit log policy

security/
  network-policies/           # K8s NetworkPolicy + Cilium CCNP YAMLs
  kyverno-policies/           # ClusterPolicy YAMLs

docs/
  cluster-handbook-dealing.md   # this doc
  workload-catalog-dealing.md   # what's deployed
  runbook-dealing.md            # incident response
  policy-reviewer.md            # policy checklist
  multi-cluster-operations-runbook.md  # fleet-level ops
```

**Why this layout:**
- Separates cluster-shape (`terraform/proxmox/`) from cluster-content (`terraform/observability/`, `terraform/argocd/`).
- Per-cluster variables in `clusters/<name>/` so adding a new cluster is a copy of `_template/` plus filling in IPs.
- Static security policies in `security/` so they can be diffed across clusters.

---

## 23. Pritunl

- **Who:** The team's VPN entry point. You connect through it to reach internal hostnames like `argocd.dealing.internal`.
- **What:** OpenVPN-compatible VPN server. Provides per-user authenticated access into the internal network.
- **How:** Out of scope of the cluster itself — runs on an external host (`10.10.16.82`). Issuing routes that include `10.10.120.0/24` so VPN clients can reach the cluster.
- **Why:** Standard self-hosted VPN. Audit log of who connected when. See [`pritunl-jumpserver-audit-10.10.16.82.md`](./pritunl-jumpserver-audit-10.10.16.82.md) for the access path notes.

---

## Glossary (one-liners)

| Term | Meaning |
|---|---|
| **CNI** | Container Network Interface. The plugin model Kubernetes uses for pod networking. Cilium is our CNI. |
| **CRD** | Custom Resource Definition. Lets you define your own resource kinds (`Certificate`, `ArgoApplication`, …) that behave like first-class Kubernetes objects. |
| **CCNP** | CiliumClusterwideNetworkPolicy. Cilium-specific NetworkPolicy that works globally. |
| **PSS** | PodSecurityStandards. The successor to PSP (PodSecurityPolicy, deprecated). |
| **Reserved identity** | In Cilium, a fixed identity assigned to special endpoints: `host`, `world`, `remote-node`, `kube-apiserver`, `ingress`, `unmanaged`, `init`, `health`. |
| **GitOps** | Pattern where Git commits → cluster state. The cluster is reconciled to whatever Git says. |
| **L7** | Application layer. HTTP, DNS, gRPC — anything where the meaning is in the bytes, not just IP/port. |
| **Remote-write** | Prometheus protocol for pushing metrics to a long-term store like Mimir. |
| **External labels** | Labels that Prometheus/Alloy add to every metric on the way out — used to tag which cluster the metric came from. |

---

*This handbook is alive — when you onboard a new component or change how something works, update the corresponding section. The companion docs (catalog, runbook, policy-reviewer) cross-link back to here.*
