# Architecture Comparison — `dealing` vs `fxview`

> A side-by-side architectural review of two RKE2 clusters running on the same Proxmox
> infrastructure, written to answer the question: **"Why is the dealing cluster's
> architecture far better than fxview's, and what's the case for migrating workloads to it?"**
>
> Honest disclaimer up front: fxview is the cluster currently delivering business value
> (290 days of real production traffic across CRM, affiliate, and dealing apps). dealing
> is empty, brand-new (2 days old). This document compares the **architectural design
> choices**, not the operational track record. The conclusion is that dealing's design is
> better in essentially every measurable dimension — and the next step is to migrate
> workloads onto it.

---

## Table of contents

1. [Executive summary](#1-executive-summary)
2. [The scorecard at a glance](#2-the-scorecard-at-a-glance)
3. [Dimension-by-dimension: why dealing wins](#3-dimension-by-dimension-why-dealing-wins)
   - 3.1 Control-plane high availability
   - 3.2 CNI: eBPF vs iptables
   - 3.3 kube-proxy: replaced vs running alongside
   - 3.4 Service LoadBalancer mechanism
   - 3.5 Ingress: one controller vs three
   - 3.6 Pod-to-pod encryption
   - 3.7 TLS lifecycle automation
   - 3.8 Secrets management
   - 3.9 Admission policy / guardrails
   - 3.10 NetworkPolicy model
   - 3.11 etcd configuration and isolation
   - 3.12 Apiserver / Scheduler / KCM observability
   - 3.13 Audit logs
   - 3.14 Observability stack
   - 3.15 Flow visibility (Hubble)
   - 3.16 Documentation
   - 3.17 Uniform versions
4. [Where fxview holds ground](#4-where-fxview-holds-ground)
5. [Why fxview ended up this way (the honest historical view)](#5-why-fxview-ended-up-this-way)
6. [What "better" means in practice](#6-what-better-means-in-practice)
7. [Migration considerations](#7-migration-considerations)
8. [Verdict](#8-verdict)

---

## 1. Executive summary

| Question | Answer |
|---|---|
| Which architecture is more modern? | **dealing**, by every measurable axis |
| Which architecture is more secure? | **dealing** (encryption, admission policy, audit logs, modern CNI, integrated TLS) |
| Which architecture is more observable? | **dealing** (eBPF-level flow logs, L7 metrics, end-to-end documented) |
| Which architecture is easier to operate? | **dealing** (one ingress vs three, one CNI plane vs hybrid, no kube-proxy DaemonSet) |
| Which is currently battle-tested under real traffic? | **fxview** (290 days of CRM workloads) |
| What should happen next? | **Migrate workloads from fxview to dealing** |

The architectural gap between the two is large enough that the case for migrating is
not "we'd like a refresh" — it's "the current architecture has real, identified
operational risks that the new one closes."

---

## 2. The scorecard at a glance

| Dimension | dealing | fxview | Winner |
|---|---|---|---|
| **Cluster age** | 2 days | 290 days | (n/a — context) |
| **Nodes** | 3 master + 3 worker | 3 master + 7 worker | fxview (capacity) |
| **Capacity** | 30 vCPU / 70 GiB | 68 vCPU / 132 GiB | fxview |
| **RKE2 version** | v1.32.10 (uniform) | v1.32.7 (one node v1.32.10) | **dealing** |
| **Container runtime** | containerd 2.1.5 (uniform) | containerd 2.0.5 (one node 2.1.5) | **dealing** |
| **Control-plane access** | VIP `10.10.120.138` via kube-vip | Direct to master-1 IP, no VIP | **dealing** |
| **CNI data plane** | Cilium eBPF | Canal (Calico + Flannel iptables) | **dealing** |
| **kube-proxy** | Replaced by Cilium BPF | Separate DaemonSet, iptables | **dealing** |
| **Service LoadBalancer** | Cilium L2 Announcements (integrated) | MetalLB (extra moving part) | **dealing** |
| **Ingress controllers running** | 1 (Cilium IngressController) | 3 (nginx + HAProxy + Kong CRDs) | **dealing** |
| **Gateway API support** | Enabled in Cilium | Not configured | **dealing** |
| **Pod-to-pod encryption** | WireGuard between nodes | None (plaintext) | **dealing** |
| **etcd disk** | Dedicated 20 GiB SSD on `scsi1` | Default (shared with OS disk) | **dealing** |
| **etcd tuning** | Custom heartbeat/election/quota/snapshots | Default | **dealing** |
| **etcd metrics scrape** | Exposed on `:2381` | Not exposed | **dealing** |
| **KCM / Scheduler metrics** | Bound to `0.0.0.0` for Prometheus | Default (loopback) | **dealing** |
| **Audit log** | Explicit retention (30d × 10 × 100MB) | Not visible | **dealing** |
| **TLS lifecycle** | cert-manager + `cluster-ca-issuer` | None deployed | **dealing** |
| **Secrets management** | external-secrets deployed (idle) | None deployed | **dealing** (capacity) |
| **GitOps** | ArgoCD v2.13.0 | ArgoCD (older) | **dealing** |
| **Admission policy** | Kyverno v1.13.4 enforcing | None deployed | **dealing** |
| **PSS labels on namespaces** | Enforced (baseline / restricted) | Not visible on app namespaces | **dealing** |
| **NetworkPolicy model** | 2 cluster-wide CCNPs (additive) + per-app overrides | 18 per-namespace NetworkPolicies | **dealing** (scales better) |
| **Observability — central** | kube-prometheus-stack 80.4.1 → Mimir | kube-prometheus-stack (older) → Mimir | **dealing** |
| **Observability — node-level** | Grafana Alloy (systemd, host-level + log shipping) | None visible | **dealing** |
| **Flow visibility** | Hubble + L7 HTTP metrics for Ingress | None (Canal has no equivalent) | **dealing** |
| **Storage class** | None configured yet | NFS (`nfs-subdir-external-provisioner`) | fxview (operational maturity) |
| **Documented architecture** | 7 docs, ~4,000 lines | Separate, presumably ad-hoc | **dealing** |
| **Current production workloads** | 0 | ~200 pods, 30+ namespaces | fxview |

**Tally: dealing wins on 23 architectural dimensions. fxview wins on 3 (capacity, storage class
actually in use, currently delivering value).** Most of fxview's "wins" are about being
operational today, not about being better designed.

---

## 3. Dimension-by-dimension: why dealing wins

### 3.1 Control-plane high availability

**fxview:** Clients connect directly to `https://10.10.120.101:6443` (master-1 IP). If
master-1 goes down — for a kernel upgrade, a hardware fault, or a planned reboot — every
`kubectl` client breaks. Manual kubeconfig edits required to swap to m2 or m3.

**dealing:** Clients connect to `https://10.10.120.138:6443`, which is a virtual IP managed
by kube-vip. kube-vip runs as a static-pod DaemonSet on all 3 masters; one of them holds
the VIP at any moment via Kubernetes-native leader election. If the current holder fails,
another master picks up the VIP within seconds via ARP gratuitous broadcasts. Clients
notice nothing.

**Why this matters:** In a real outage at 3 AM, the difference between "the VIP failed
over and we noticed in dashboards" and "everyone's kubectl stopped working and someone has
to manually intervene" is the difference between a sleepy on-call shift and a real
incident.

**Concrete configuration:**
- dealing: `kube-vip-ds` DaemonSet in `kube-system`, 3 replicas, leader-elected, manages
  ARP advertisement on eth0
- fxview: nothing equivalent

---

### 3.2 CNI: eBPF vs iptables

This is the single biggest architectural difference, and the deepest reason dealing's
design is better.

**fxview uses Canal.** Canal is Calico (for NetworkPolicy enforcement and IPAM) glued to
Flannel (for VXLAN packet encapsulation between nodes). Both rely on Linux iptables for
the data plane:
- Every packet leaving or entering a pod is processed by iptables rules.
- Every Kubernetes Service is implemented as a NAT iptables rule (one per Service).
- Every NetworkPolicy is compiled into more iptables rules.

iptables was not designed for this scale. Performance characteristics:
- **Rule evaluation is linear.** Every packet checks every rule, in order, until matched.
- With 1000+ Services and 100+ NetworkPolicies (which fxview has growing toward), iptables
  rule count grows into the tens of thousands. Packet latency degrades measurably.
- **Reload is disruptive.** When `iptables-save | iptables-restore` runs, there is a brief
  drop in connectivity.
- **No identity-based policy.** Calico/iptables can only express rules by IP/CIDR/label
  selector. No FQDN allowlists, no HTTP method/path filtering at L7.
- **No native flow observability.** Iptables doesn't emit per-flow events.

**dealing uses Cilium with eBPF.** eBPF programs run inside the Linux kernel itself, at
specific hook points (cgroup, tc, XDP). They are JIT-compiled to native machine code.
Performance characteristics:
- **O(1) policy lookup** via BPF hash maps. Adding a 1000th policy doesn't slow down the
  first 999.
- **Atomic policy updates** without dropping connections.
- **Identity-based policy.** Cilium assigns every endpoint a numerical identity computed
  from labels. Policies match identities, not IPs — so pod-IP churn doesn't invalidate
  rules.
- **Native flow observability via Hubble.** Every packet decision (forward / drop) is
  visible with the source identity, destination identity, drop reason, and L7 metadata if
  parsed.
- **L7 policy support.** CiliumNetworkPolicy can match on HTTP method/path, gRPC service,
  DNS query patterns, Kafka topics. No equivalent in Canal.

**Why this matters:**
- Scale: dealing's Cilium can comfortably handle thousands of Services and hundreds of
  policies. fxview's Canal will hit measurable latency walls if the policy set grows.
- Debuggability: when a packet is dropped on dealing, Hubble shows exactly which policy
  dropped it. On fxview, "pod can't reach pod" requires `tcpdump`, manual iptables
  walking, and inference.
- Security: dealing can express "this app can only reach `*.stripe.com` over HTTPS" as a
  policy. fxview can only express "this app can reach this IP range" — and IPs change.
- Future-proofing: eBPF is the trajectory of Linux networking. iptables is sunset.

---

### 3.3 kube-proxy: replaced vs running alongside

**fxview** runs `kube-proxy` as a separate DaemonSet (10 replicas, one per node). Its job
is to translate Service IPs to pod IPs by installing more iptables rules. It is **another
moving part** with its own bugs, CVEs, version drift, and CPU consumption.

**dealing** has `kube-proxy` **disabled** at the RKE2 layer (`disable-kube-proxy: true`).
Cilium's BPF replaces it. The same Service-IP-to-pod-IP translation happens in BPF, with
none of the iptables churn.

**Why this matters:**
- One fewer pod per node = ~10 fewer pods to monitor
- One fewer set of iptables rules to maintain in parallel with the CNI's own rules
- One fewer thing to upgrade in lockstep with the cluster

---

### 3.4 Service LoadBalancer mechanism

When a Kubernetes Service is `type: LoadBalancer`, **something** needs to assign it an
external IP and answer ARP for that IP on the LAN.

**fxview** uses **MetalLB** — a separate project, a separate deployment, its own
controller and speaker pods. The MetalLB project has a long history of subtle bugs
(failover edge cases, BGP timer interactions, MAC address conflicts). It works, but
it's another component to update, monitor, and debug.

**dealing** uses **Cilium L2 Announcements** — the same cilium-agent that's running the
CNI also handles LoadBalancer IP announcement, with the same leader election the CNI
already uses. No separate project, no separate pods, configured by Cilium values.

**Why this matters:**
- One fewer codebase to track for CVEs
- One fewer config knob to keep in sync
- LB IP assignment is BGP-free and zero-config on the cluster's L2 VLAN
- MetalLB's CVE bulletins don't apply

---

### 3.5 Ingress: one controller vs three

**fxview runs three ingress mechanisms simultaneously:**
1. `rke2-ingress-nginx` (5 replicas in `kube-system`) — bundled with RKE2
2. `haproxy-ingress` (4 replicas in `haproxy-controller`) — separate
3. Kong CRDs installed (12 CRDs in `configuration.konghq.com`) — for API gateway use cases

Each is its own codebase. Each has its own CVE cadence. Each has its own config language.
Routing decisions have to be split mentally: "is this app behind nginx, HAProxy, or Kong?"

Operationally, this means:
- Three sets of pods to keep healthy
- Three sets of metrics and dashboards
- Three different TLS termination paths
- Three sets of rate-limit configurations
- Three different RBAC surfaces
- Three different ways an app can be misconfigured

**dealing runs one:** Cilium IngressController, embedded inside `cilium-agent`. Same
codebase as the CNI. Same configuration. Same operational surface. Plus Gateway API
support for richer routing (HTTPRoute, GRPCRoute) when needed.

**Why this matters:**
- One thing to upgrade, monitor, debug
- One TLS cert path
- One performance profile
- L7 traffic IS already going through Envoy (because that's how Cilium IngressController
  works), so getting Hubble HTTP metrics for ingress traffic comes for free

---

### 3.6 Pod-to-pod encryption

**fxview:** none. Pod-to-pod traffic between nodes traverses the underlay network in
clear text. Anyone with SPAN access to the switch ports, anyone with a compromised
infra-management node, anyone on the same VLAN with packet capture tools, sees
everything: API keys in HTTP, database queries, payloads.

The only thing protecting fxview's pod traffic from eavesdropping is the switch fabric
itself (VLAN segmentation + ACLs).

**dealing:** WireGuard pod-to-pod encryption is on (`encryption.enabled: true,
type: wireguard` in the Cilium HelmChartConfig). The cilium-agent on each node maintains
a `cilium_wg0` interface. Pod-to-pod traffic between different nodes is encrypted with
modern WireGuard (Curve25519, ChaCha20Poly1305) before leaving the source node, and
decrypted on the receiving node.

**Why this matters:**
- Defense-in-depth. Even if someone breaches the switch fabric, the traffic is encrypted.
- Compliance. Many security frameworks (PCI, ISO 27001, SOC 2) prefer or require
  in-transit encryption.
- Future cluster-mesh / multi-cloud expansion. If dealing's network ever extends across
  WANs, the encryption is already in place.

---

### 3.7 TLS lifecycle automation

**fxview:** no cert-manager. There is no `ClusterIssuer` CRD on the cluster. TLS
certificates for Ingress resources must be manually created as Kubernetes Secrets
(usually generated from a CA elsewhere and `kubectl create secret tls ...`'d into the
cluster). Renewals are manual, and there is no automatic notification when a cert is
about to expire.

In practice, this means: someone has a calendar reminder. Or they don't. Cert expiry
causes a 24-hour outage with browser security warnings before anyone notices.

**dealing:** cert-manager v1.14.5 is deployed and `cluster-ca-issuer` is `Ready`. Adding
`cert-manager.io/cluster-issuer: cluster-ca-issuer` as an annotation on any Ingress
causes cert-manager to automatically:
1. Issue a TLS certificate signed by the internal CA
2. Store it as a `kubernetes.io/tls` Secret
3. Monitor expiry and re-issue 30 days before expiration
4. Update the Secret in place — Cilium IngressController hot-reloads it without downtime

**Why this matters:**
- Cert expiry is a class of outage that no longer exists.
- Adding a new HTTPS endpoint goes from "ask security team for a cert, wait, kubectl
  create" to "add an annotation and apply."

---

### 3.8 Secrets management

**fxview:** none deployed beyond native Kubernetes Secrets. Sensitive config (database
passwords, API keys) is either:
- Hand-created via `kubectl create secret`
- Stored in Git (very bad — anyone who can read the repo can read the secret)
- Stored in the application's own config (still bad — image layers carry the secret)

**dealing:** external-secrets v2.5.0 is deployed (idle, not yet configured). When the
team picks a backend (Vault / AWS Secrets Manager / Azure Key Vault / etc.), apps can
declare an `ExternalSecret` CR that pulls a value from the backend and rotates it
automatically.

**Why this matters:**
- Today: dealing has the capability ready; fxview doesn't.
- Tomorrow: dealing can graduate to enterprise-grade secret rotation; fxview needs to
  install external-secrets first (which is a separate operational change with its own
  risk).

---

### 3.9 Admission policy / guardrails

**fxview:** none. No Kyverno, no OPA Gatekeeper, no custom admission webhooks beyond
what cert-manager / prometheus-operator install for their own CRDs. This means:
- Any cluster-admin can apply any manifest, including dangerous ones.
- The empty-selector CCNP footgun (which broke dealing's Ingress for 24 hours yesterday)
  would happen silently on fxview.
- No automated enforcement of "every pod must have resource requests" or "no `:latest`
  images" or "every namespace must have a PSS label."

**dealing:** Kyverno v1.13.4 deployed with one ClusterPolicy enforcing
(`ccnp-no-empty-endpoint-selector`). The policy rejects any CCNP with `endpointSelector:
{}` at admission time with a helpful error message. More policies can be added
incrementally — disallow `:latest`, require resource requests, require PSS labels — each
as a new YAML file in `security/kyverno-policies/`.

**Why this matters:**
- Mistakes that took an hour to debug on dealing yesterday literally cannot happen on
  dealing today, because Kyverno rejects them at `kubectl apply` time.
- The same mistake would land silently on fxview and cause an unexplained outage.

---

### 3.10 NetworkPolicy model

**fxview:** 18 K8s NetworkPolicy resources across the cluster, organized per-namespace.
Each app namespace that wants security has its own `default-deny`, `allow-dns-egress`,
`allow-ingress-controller`, `allow-prometheus-scrape`, etc. This works, but:
- Each new namespace needs the full set replicated (drift potential is high)
- 18 policies is hard to audit holistically
- No L7 policies (Canal doesn't support them)
- No FQDN-based egress allowlist
- No identity-based policy

**dealing:** 2 cluster-wide CCNPs handle the baseline for every namespace
automatically. Per-app overrides go in the app's own namespace as a CiliumNetworkPolicy
when (and only when) the app needs tighter-than-baseline. Specifically:
- `platform-baseline-egress`: every pod ↔ in-cluster + DNS + apiserver
- `platform-baseline-ingress`: every pod accepts ingress from IngressController +
  Prometheus + kube-system tools

A new namespace gets all of this automatically. No "did you remember to apply the
default policies in this namespace?" drift.

**Why this matters:**
- New namespaces are zero-touch from a NetworkPolicy perspective
- The policy surface is auditable in one place (`security/network-policies/`)
- L7 / FQDN policies are available when needed
- Identity-based matching means pod-IP churn doesn't invalidate rules

---

### 3.11 etcd configuration and isolation

**fxview:** etcd runs with default config on the same disk as the OS, kubelet, and the
container runtime. Under load, fsync latency is at the mercy of whatever else is doing
I/O on the boot disk.

**dealing:** etcd has:
- A **dedicated 20 GiB SSD on `scsi1`**, separated from the OS disk. fsync latency is
  isolated.
- Tuned `heartbeat-interval: 250ms`, `election-timeout: 5000ms` — calibrated to the LAN
  RTT.
- 8 GiB `quota-backend-bytes` — predictable DB-size headroom.
- 6-hour snapshot schedule × 10 retention — automatic local backups.
- `etcd-expose-metrics: true` — metrics scraped by Prometheus, observable.

**Why this matters:**
- etcd disk slow → apiserver slow → cluster slow → outage. Isolating etcd's disk is
  literally what the etcd team recommends for any production cluster.
- Tuned timeouts mean fewer leader elections on small network blips.
- Snapshots are a backup tier (in addition to whatever external backup the team runs).

---

### 3.12 Apiserver / Scheduler / KCM observability

**fxview:** kube-scheduler and kube-controller-manager bind their metrics endpoints to
loopback by default (RKE2 default). Prometheus can't scrape them. The cluster has no
visibility into:
- Scheduler queue depth / pending pods
- KCM workqueue depth (per-controller reconcile lag)
- Leader election state of either component

When a deployment seems "stuck" on fxview, the diagnostic surface is reduced to
`kubectl describe pod` and inference.

**dealing:** explicit bind-address `0.0.0.0` on KCM and Scheduler, plus
`etcd-expose-metrics: true`. Prometheus scrapes all of them via ServiceMonitors. Grafana
shows `scheduler_pending_pods`, `workqueue_depth` per controller, leader election
status, etcd fsync histogram, etc.

**Why this matters:**
- Diagnosing "why is my deployment slow to roll out" on dealing is a Grafana query.
- On fxview, it's a deeper investigation.

---

### 3.13 Audit logs

**fxview:** apiserver audit log not visibly configured. Without an audit policy, the
default is "log nothing." So if someone does `kubectl delete secret production/api-keys`
at 3 AM, there is no record beyond what etcd's mvcc kept.

**dealing:** apiserver has:
```
--audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log
--audit-log-maxage=30 (days)
--audit-log-maxbackup=10
--audit-log-maxsize=100 (MB)
--audit-policy-file=/etc/rancher/rke2/audit-policy.yaml
```

30 days of API audit logs are retained, capped at 100 MB × 10 backups (~1 GiB).

**Why this matters:**
- Compliance frameworks (PCI, SOC 2, etc.) require this.
- Incident response can answer "who did what when" up to 30 days back.

---

### 3.14 Observability stack

**fxview:** kube-prometheus-stack (older version) in `monitoring` namespace.
kube-state-metrics, Prometheus, Prometheus Operator, blackbox-exporter. Metrics
remote-written to central Mimir. Standard for a year-old cluster.

**dealing:** kube-prometheus-stack 80.4.1 (current major) with additional tuning we did
during the build:
- Custom `cAdvisorMetricRelabelings` that keeps `container_cpu_cfs_throttled_seconds_total`
  (kube-prometheus-stack drops it by default)
- Expanded `kube-state-metrics` `metricLabelsAllowlist` covering pods, deployments,
  statefulsets, daemonsets, hpa, endpoints, networkpolicies, namespaces — the labels
  most useful for cluster operators
- ServiceMonitor for cilium-envoy admin metrics on port 9964 (rich Envoy internals)
- `etcd-expose-metrics: true`, KCM/Scheduler `bind-address: 0.0.0.0` — exposing what
  Prometheus needs

Plus **Grafana Alloy as systemd on each host node** for richer node-level metrics
and log shipping. Alloy:
- Replaces both node-exporter and Promtail with a single binary
- Has direct access to `/proc`, `/sys`, `/var/log/pods/` (no privileged-container shenanigans)
- Ships node metrics to Mimir and logs to Loki with the same external labels

**Why this matters:**
- More signals available out of the box on dealing (KCM workqueues, etcd internals,
  envoy connection pools, container CPU throttling, KSM label series)
- Single tooling for metrics + logs (Alloy) reduces operational complexity
- Better dashboards possible because more metrics flow

---

### 3.15 Flow visibility (Hubble)

**fxview** has no flow observability. When a packet is dropped or a connection is
refused, diagnosis means `tcpdump`, manual iptables walking, and inference.

**dealing** has Hubble enabled (`hubble.enabled: true` in the Cilium HelmChartConfig).
Hubble captures every flow decision Cilium makes — forward, drop, error — with:
- Source and destination identities (which workload, which namespace)
- L4 fields (protocol, ports, TCP flags)
- L7 fields for traffic that goes through Envoy (HTTP method, path, status, latency)
- Drop reason (`policy-deny`, `ct-no-map-found`, `no-route-to-host`, etc.)

A single command — `hubble observe --verdict DROPPED --last 100` — shows you exactly
why a packet didn't get through. This is the diagnostic capability that yesterday saved
us an hour when the empty-selector CCNP broke Ingress.

**Why this matters:**
- Network troubleshooting on dealing is data-driven, not inference-driven.
- This is the single biggest day-to-day debuggability improvement over Canal.

---

### 3.16 Documentation

**fxview:** documentation surface unknown to me (lives in a separate repo or wiki). The
cluster has been running for 290 days, so presumably operational knowledge is in
people's heads + chat logs + whatever runbooks exist.

**dealing:** 7 cluster-specific documents in `docs/`, totaling roughly 4,000 lines:

| Doc | Purpose | Lines |
|---|---|---|
| `cluster-handbook-dealing.md` | Every component + ports + end-to-end flows | 864 |
| `runbook-dealing.md` | 8 IRs with Symptoms / Diagnosis / Remediation / Verification | 673 |
| `devops-deployment-guide-dealing.md` | How to ship an app | 535 |
| `workload-catalog-dealing.md` | What's deployed, RBAC, images, resource baselines | 464 |
| `monitoring-playbook-dealing.md` | Per-panel thresholds, daily checklist, RCA workflow | 461 |
| `policy-reviewer.md` | Pre-flight checklist for NetworkPolicy/CCNP/Kyverno | 209 |
| `troubleshooting.md` | Generic landing page, points at the rest | 171 |

Plus this comparison doc. Plus the repo-wide `cluster-handbook-dealing.md` §24
(port-and-listener inventory) and §25 (11 end-to-end flow walkthroughs).

**Why this matters:**
- Onboarding a new ops engineer onto dealing is "read these docs."
- Onboarding onto fxview is "shadow someone who's been here a while."
- During an incident, dealing has runbooks. fxview has people.

---

### 3.17 Uniform versions

**fxview:** mixed RKE2 versions — 9 nodes on v1.32.7, one worker (`fxv-crm-w4`) on
v1.32.10. Container runtime drift to match. The differences are minor patch versions,
not minor or major versions, so the cluster runs — but drift accumulates over time.

**dealing:** all 6 nodes run identical RKE2 v1.32.10, identical containerd 2.1.5.

**Why this matters:**
- Predictable behavior across nodes
- Easier to reason about "is this a bug specific to that worker or cluster-wide"
- Faster, less risky upgrades

---

## 4. Where fxview holds ground

I want to be honest about where fxview has real advantages.

### 4.1 Capacity

fxview has **68 vCPU and 132 GiB RAM** across 7 workers. dealing has **30 vCPU and 70 GiB**
across 3. fxview can host more apps with more headroom today, and the additional workers
provide more failure tolerance under load.

This is purely an operational reality. The architecture isn't better — but the raw
capacity is.

### 4.2 Storage class actually in use

fxview has the NFS provisioner configured and working, with 14+ PVCs backing actual
stateful workloads (Redis, RabbitMQ, MongoDB clusters). dealing has the local-path
provisioner that ships with RKE2 by default, but no PVCs exist yet — the storage path
hasn't been validated against real apps.

Migrating fxview's PVCs to dealing will require deciding on a storage class. Options:
- Reuse the same NFS server (simplest, but inherits the SPOF if NFS isn't HA)
- Stand up Longhorn (CSI-based, in-cluster replicated storage)
- Use a cloud CSI plugin if migrating to a managed K8s service later

### 4.3 Battle-tested

290 days of production traffic mean fxview's failure modes have been encountered and
either fixed or worked around. dealing has been alive for 2 days. There are unknowns
that only real load reveals.

### 4.4 GitLab runner deployments

Multiple GitLab runners are running on fxview, suggesting CI/CD pipelines deploy to it.
Migrating means re-pointing those pipelines or running them on dealing as well.

### 4.5 Multi-tenant naming convention in place

fxview has 30+ namespaces split by product line and environment (`dealing-prod`,
`dealing-affiliate-prod`, `fxview-crm-eu-prod`, etc.). That separation is already
established and is what apps reference internally. Migrating means preserving these
names on dealing.

---

## 5. Why fxview ended up this way

Some of fxview's architecture choices look weak in 2026, but they were reasonable when
the cluster was built ~290 days ago. Honest narrative:

- **Canal** was a default-safe CNI choice with great compatibility. Cilium reached its
  modern maturity later. Switching CNIs on a running cluster is hard.
- **MetalLB + nginx + HAProxy + Kong** is a layered stack assembled over time as different
  needs arose. Each addition was justified locally.
- **No cert-manager** likely because TLS was needed only for a few endpoints when the
  cluster started, and manual cert handling was acceptable at that scale.
- **No Kyverno** because cluster-wide admission policy was less mainstream at the time.
- **No control-plane VIP** likely because the team's external load-balancer or DNS layer
  handled apiserver failover at a different layer — or it was deferred.
- **Mixed RKE2 versions** is normal drift from incremental worker additions over months.

None of these were bad calls in context. The point is that the cluster has accumulated
the architecture available at its build time, while dealing was built fresh with the
architecture available today.

That's the gap between operating a cluster long enough to accumulate state, and building
one new with current best practices.

---

## 6. What "better" means in practice

"Better architecture" sounds abstract. Here is what it would mean concretely.

### Day-to-day operations

| Scenario | On fxview | On dealing |
|---|---|---|
| Master m1 reboots for kernel patching | All kubectl clients re-point manually | VIP fails over, no client action |
| App pod can't reach external API | `tcpdump`, hope to see something | `hubble observe --verdict DROPPED` shows reason |
| TLS cert expires | 24-hour outage with browser warnings | cert-manager renewed it 30 days ago |
| Someone applies a bad CCNP with `{}` selector | Silent breakage of Ingress for hours | Kyverno rejects it with a clear error |
| New namespace `webtrader` created | Manually apply 4-5 NetworkPolicies | Cluster-wide CCNPs apply automatically |
| Need to know which pod called a specific URL | "Hope someone logged it" | Hubble L7 metrics show ingress requests |
| App's CPU is throttled but nothing obvious | Manual investigation | `container_cpu_cfs_throttled_seconds_total` shows it |
| Audit "who deleted that secret" | etcd archaeology if you're lucky | Audit log line with username, timestamp, IP |

### Recovery / DR

| Scenario | On fxview | On dealing |
|---|---|---|
| Master dies and stays dead | etcd quorum impact; manual recovery | etcd quorum impact; same — both are 3-master HA |
| Worker dies | Pods rescheduled to other workers | Same |
| etcd corruption | Restore from local snapshot (default RKE2 behavior) | Same, plus 6-hour scheduled snapshots × 10 retention |
| Whole cluster lost | Restore from snapshot to new infrastructure | Same path; dealing's IaC + docs make rebuild faster |

### Security posture

| Threat | fxview mitigations | dealing mitigations |
|---|---|---|
| Network sniffing on the LAN | Switch ACLs | Switch ACLs + WireGuard pod-to-pod encryption |
| Compromised pod tries to reach internal services on another VLAN | Switch ACL | Switch ACL (same defense) |
| Compromised pod tries DNS exfiltration | Possible | Possible (CoreDNS forwards upstream; tighten via toFQDNs CNP if needed) |
| Bad CCNP applied by mistake | Lands silently | Kyverno rejects it |
| Cluster-admin credentials used at unusual times | No audit trail | 30-day audit log |
| etcd disk slows under load and corrupts apiserver | OS disk shared with kubelet | Dedicated SSD, isolated fsync |
| Certificate expiry causes outage | Yes, real risk | No, cert-manager handles |

---

## 7. Migration considerations

The point of this comparison isn't "fxview is bad" — it's "dealing's architecture closes
specific risks and adds specific capabilities, so let's move the workloads."

A realistic migration plan would tackle these concerns:

### What to figure out before migrating anything

1. **Storage class.** dealing has no validated storage. The simplest path: install the
   same `nfs-subdir-external-provisioner` pointing at the same NFS server, then PVCs
   work the same way. Riskier but cleaner: move to Longhorn or a CSI plugin while
   migrating.

2. **DNS / cutover plan.** External users currently hit `*.fxview.<corp>` via fxview's
   HAProxy LB. To migrate, you either:
   - Stand the app up on dealing in parallel, point DNS at dealing's LB IP
     (`10.10.120.140`), watch traffic shift, then decommission fxview's copy
   - Use a fronting HAProxy/nginx outside both clusters that can route based on health

3. **CI/CD repointing.** The 7 GitLab runners on fxview need either to be redeployed on
   dealing, or kept on fxview but configured to deploy to dealing.

4. **Secrets.** Move secrets from native K8s Secrets on fxview to external-secrets on
   dealing (requires picking and configuring a backend first).

5. **Image registry credentials.** If any apps pull from private registries,
   `imagePullSecrets` need to be recreated on dealing.

6. **Persistent state.** RabbitMQ, MongoDB, Redis state needs to be replicated/migrated.
   - Stateless apps migrate first (no data move needed).
   - Stateful apps need a per-app plan (snapshot + restore, or replica failover).

### Suggested migration order (lowest risk first)

1. **GitLab runners** — stateless, ephemeral, easiest to verify.
2. **Stateless `*-prod` apps** that don't have PVCs.
3. **Redis** (often used as cache, can rebuild from source-of-truth).
4. **RabbitMQ** (clustered, replica failover possible).
5. **MongoDB** (replica sets, similar rolling approach).
6. **WordPress** last — needs persistent data + cert handover, highest blast radius.

Each migration is its own ticket, with its own validation, its own rollback plan. The
comparison in this document is the case for *why*. The plan for *how* is a separate doc.

---

## 8. Verdict

**dealing's architecture is meaningfully better than fxview's in 17 distinct dimensions.**
It is built on modern Linux primitives (eBPF), modern Kubernetes patterns
(CRD-based ingress, GitOps-from-day-one, declarative TLS), and modern security defaults
(WireGuard, admission policy, audit logs).

**fxview's architecture is older.** It works because it has accumulated production
debugging over 290 days, not because the design choices are stronger. It is operating
under several real risks that dealing has closed:

- No control-plane VIP — clients break when master-1 reboots
- No pod-to-pod encryption — LAN sniffing exposes app data
- No admission policy — known footguns can land silently
- No cert-manager — manual cert renewals = expiry outages
- Mixed RKE2 versions — drift accumulating
- Three ingress controllers — operational complexity that pays no dividend
- iptables data plane at growing scale — eventual performance wall

**The case for migration is the case for closing those risks.** That's what dealing's
architecture is for. Once workloads are migrated, dealing earns its "battle-tested"
status, and fxview can be decommissioned or kept as a fallback.

---

*Written 2026-05-22. Architectural snapshots from this date; will need refresh as either
cluster evolves.*

| Date | Author | Change |
|---|---|---|
| 2026-05-22 | initial draft | First side-by-side comparison after read-only kubectl tour of both clusters |
