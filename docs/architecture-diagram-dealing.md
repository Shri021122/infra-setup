# Architecture Diagrams — `dealing` cluster

> ASCII diagrams of the cluster at different zoom levels. Pair with the verbal
> walkthrough in [`cluster-handbook-dealing.md`](./cluster-handbook-dealing.md) §1, §6,
> §25 (end-to-end flows).
>
> If you want a visual rendering, drop these into <https://asciiflow.com> or copy them
> into draw.io as "Insert ASCII Art".

---

## 1. Top-level topology — what touches what

```
                            ╔══════════════════════════════════════════════════╗
                            ║              CORPORATE NETWORK                    ║
                            ║              (multiple VLANs)                     ║
                            ╚══════════════════╤═══════════════════════════════╝
                                               │
                            ┌──────────────────┴──────────────────┐
                            │    L3 SWITCH — enforces VLAN ACLs   │
                            │  Each cross-VLAN port allow-listed  │
                            └──┬───────────┬───────────────┬──────┘
                               │           │               │
        ┌──────────────────────┘           │               └─────────────────────┐
        │                                  │                                     │
        ▼                                  ▼                                     ▼
 ┌────────────────┐               ┌─────────────────────┐                ┌────────────────┐
 │ JUMPBOX VLAN   │               │ OBSERVABILITY VLAN  │                │ DEALING CLUSTER │
 │ 10.10.16.0/24  │               │ 10.10.103.0/24       │                │ VLAN            │
 │                │               │                     │                │ 10.10.120.0/24  │
 │  Pritunl VPN   │               │  Mimir              │                │                │
 │  (admin only)  │               │  Loki               │                │  6 RKE2 nodes  │
 └────────────────┘               │  Grafana :3000      │                │  see §2        │
                                  │  + alerts → MS Teams│                │                │
                                  └─────────────────────┘                └────────────────┘
                                  Receives metrics & logs                Receives admin
                                  remote-written from cluster            traffic over VPN
                                                                         + external user
                                                                         traffic to Ingress
                                                                         LB on .140
```

Key idea: switch ACLs are the network-layer security boundary. The cluster talks to
observability via cross-VLAN ports the switch explicitly permits (HTTP/80 to .103.x).
Admins reach the cluster via VPN → switch → cluster VLAN.

---

## 2. Cluster topology — nodes, VIPs, LB IP

```
                              ╔══════════════════════════════╗
                              ║   CONTROL PLANE VIP          ║
                              ║   10.10.120.138 : 6443       ║
                              ║   (kube-vip leader election) ║
                              ╚════╤════════════╤════════════╤═╝
                                   │            │            │
                ┌──────────────────┴┐  ┌────────┴───────┐  ┌─┴────────────────┐
                │   dealing-m-1     │  │  dealing-m-2   │  │   dealing-m-3    │
                │   10.10.120.131   │  │  10.10.120.132 │  │   10.10.120.133  │
                │   ──────────────  │  │  ───────────── │  │   ──────────────  │
                │   STATIC PODS:    │  │   STATIC PODS: │  │   STATIC PODS:    │
                │     kube-apiserver│  │     kube-apisvr│  │     kube-apiserver│
                │     kube-cont-mgr │  │     kube-cont- │  │     kube-cont-mgr │
                │     kube-scheduler│  │       mgr      │  │     kube-scheduler│
                │     etcd          │  │     kube-sched │  │     etcd          │
                │     cloud-cont-mgr│  │     etcd       │  │     cloud-cont-mgr│
                │   kube-vip-ds     │  │   kube-vip-ds  │  │   kube-vip-ds     │
                │                   │  │                │  │                   │
                │   DAEMONSETS:     │  │   DAEMONSETS:  │  │   DAEMONSETS:     │
                │     cilium-agent  │  │     cilium-ag  │  │     cilium-agent  │
                │                   │  │                │  │                   │
                │   SYSTEMD:        │  │   SYSTEMD:     │  │   SYSTEMD:        │
                │     rke2-server   │  │     rke2-server│  │     rke2-server   │
                │     containerd    │  │     containerd │  │     containerd    │
                │     alloy         │  │     alloy      │  │     alloy         │
                │                   │  │                │  │                   │
                │   DISKS:          │  │   DISKS:       │  │   DISKS:          │
                │     50 GiB OS     │  │     50 GiB OS  │  │     50 GiB OS     │
                │     20 GiB etcd   │  │     20 GiB etcd│  │     20 GiB etcd   │
                │       (scsi1 SSD) │  │      (scsi1)   │  │       (scsi1 SSD) │
                └───────────────────┘  └────────────────┘  └───────────────────┘
                          ▲                    ▲                    ▲
                          │                    │                    │
                          └────── etcd raft (port 2380) ─────────────┘

                ┌───────────────────┐  ┌────────────────┐  ┌───────────────────┐
                │   dealing-w-1     │  │  dealing-w-2   │  │   dealing-w-3     │
                │   10.10.120.134   │  │  10.10.120.135 │  │   10.10.120.136   │
                │   ──────────────  │  │  ───────────── │  │   ──────────────  │
                │   DAEMONSETS:     │  │   DAEMONSETS:  │  │   DAEMONSETS:     │
                │     cilium-agent  │  │     cilium-ag  │  │     cilium-agent  │
                │                   │  │                │  │                   │
                │   APP WORKLOADS:  │  │ APP WORKLOADS: │  │  APP WORKLOADS:   │
                │     (DevOps fills │  │   (TBD)        │  │    (TBD)          │
                │      this in via  │  │                │  │                   │
                │      ArgoCD)      │  │                │  │                   │
                │                   │  │                │  │                   │
                │   SYSTEMD:        │  │   SYSTEMD:     │  │   SYSTEMD:        │
                │     rke2-agent    │  │     rke2-agent │  │     rke2-agent    │
                │     containerd    │  │     containerd │  │     containerd    │
                │     alloy         │  │     alloy      │  │     alloy         │
                │                   │  │                │  │                   │
                │   DISKS:          │  │   DISKS:       │  │   DISKS:          │
                │     100 GiB OS    │  │     100 GiB OS │  │     100 GiB OS    │
                │     20 GiB data   │  │     20 GiB data│  │     20 GiB data   │
                │       (PVCs)      │  │      (PVCs)    │  │       (PVCs)      │
                └───────────────────┘  └────────────────┘  └───────────────────┘

                              ╔══════════════════════════════╗
                              ║   INGRESS LB IP              ║
                              ║   10.10.120.140 : 80/443     ║
                              ║   (Cilium L2 Announcements)  ║
                              ╚══════════════════════════════╝
```

VIP `.138` lives on whichever master kube-vip elected as leader. LB IP `.140` lives on
whichever cilium-agent the L2-announce leader is. Both fail over within seconds.

---

## 3. The Cilium data plane on one node (worker)

Showing what's inside one cilium-agent and how a pod's packet traverses the stack.

```
                                    ┌─────────────────────────────────────┐
                                    │   APP POD                            │
                                    │   IP: 10.42.4.42 (pod CIDR)         │
                                    │   ┌───────────┐                      │
                                    │   │ container │                      │
                                    │   └─────┬─────┘                      │
                                    └─────────┼────────────────────────────┘
                                              │ veth
                                              ▼
        ╔════════════════════════════════════════════════════════════════════╗
        ║                  cilium-agent POD (host network)                    ║
        ║                                                                     ║
        ║   ┌────────────────────────────────────────────────────────────┐    ║
        ║   │  BPF programs in the kernel                                │    ║
        ║   │  • Policy enforcement (CCNP/CNP/NetworkPolicy)             │    ║
        ║   │  • Service load balancing (replaces kube-proxy)            │    ║
        ║   │  • Conntrack + NAT in BPF maps                             │    ║
        ║   │  • Identity lookup (ipcache → identity)                    │    ║
        ║   └────────────────────────┬───────────────────────────────────┘    ║
        ║                            │                                        ║
        ║   ┌────────────────────────▼───────────────────────────────────┐    ║
        ║   │  Decision:                                                  │    ║
        ║   │   • same-node pod → veth                                    │    ║
        ║   │   • other-node pod → cilium_wg0 (WireGuard, encrypted)      │    ║
        ║   │   • cluster Service IP → BPF translates → pod IP            │    ║
        ║   │   • external IP → host eth0 (with SNAT)                     │    ║
        ║   └─────────────────────────────────────────────────────────────┘    ║
        ║                                                                     ║
        ║   ┌─────────────────────────────────────────────────────────────┐    ║
        ║   │  Embedded Envoy                                              │    ║
        ║   │  • Handles Cilium IngressController traffic                  │    ║
        ║   │    (10.10.120.140 → external HTTPS → app)                   │    ║
        ║   │  • Admin metrics on :9964 (scraped by Prometheus)            │    ║
        ║   │  • Hubble L7 metrics fed from here                           │    ║
        ║   └─────────────────────────────────────────────────────────────┘    ║
        ║                                                                     ║
        ║   ┌─────────────────────────────────────────────────────────────┐    ║
        ║   │  Hubble — observes every flow decision                       │    ║
        ║   │  • Exposes metrics on :9965 (verdict / drop reason / L7)    │    ║
        ║   │  • Relay aggregates across nodes; UI at hubble.cluster.int  │    ║
        ║   └─────────────────────────────────────────────────────────────┘    ║
        ║                                                                     ║
        ║   ┌─────────────────────────────────────────────────────────────┐    ║
        ║   │  Agent metrics on :9962                                      │    ║
        ║   └─────────────────────────────────────────────────────────────┘    ║
        ╚════════════════════════════════════════════════════════════════════╝
                                              │
                                              ▼
                              ┌───────────────────────────────┐
                              │      Host network stack       │
                              │      (eth0, cilium_wg0)       │
                              └───────────────────────────────┘
```

Key ports exposed per cilium-agent:
- `9962` — agent's own Prometheus metrics
- `9964` — embedded Envoy admin metrics
- `9965` — Hubble metrics
- `4244` — Hubble peer (relay aggregates from here)
- `51871/UDP` — WireGuard tunnel

---

## 4. End-to-end: an external user opens `https://argocd.dealing.internal`

```
       ┌────────────┐
       │   Browser  │
       └─────┬──────┘
             │ 1. DNS query for argocd.dealing.internal
             ▼
       ┌──────────────────────────────────────────────────┐
       │  Internal DNS / /etc/hosts                       │
       │  → 10.10.120.140                                  │
       └─────────────────────────┬────────────────────────┘
                                 │
             ┌───────────────────┴─────────────────┐
             │ 2. TCP/443 to 10.10.120.140         │
             ▼                                     │
       ┌──────────────────────────────────────────────────┐
       │  L3 SWITCH → forwards into dealing VLAN          │
       └─────────────────────────┬────────────────────────┘
                                 │
                                 ▼
       ┌─────────────────────────────────────────────────────────┐
       │  Cilium L2-announce LEADER cilium-agent (e.g. on w-1)   │
       │  10.10.120.134 holds the LB IP via ARP                   │
       │                                                          │
       │   ┌─────────────────────────────────────────────────┐   │
       │   │  Embedded Envoy IngressController                │   │
       │   │   • Accepts TLS handshake with argocd-server-tls │   │
       │   │   • Reads HTTP Host header = argocd.dealing.int  │   │
       │   │   • Routes → Service argocd-server.argocd.svc    │   │
       │   └────────────────────────┬─────────────────────────┘   │
       └────────────────────────────┼─────────────────────────────┘
                                    │
                                    │  3. Service ClusterIP lookup
                                    ▼
                  ┌─────────────────────────────────────────┐
                  │  Cilium BPF (kube-proxy replacement)    │
                  │  Service 10.43.x.x → pod 10.42.4.X      │
                  └────────────────────┬────────────────────┘
                                       │
                                       │  4. WireGuard if cross-node
                                       ▼
                  ┌─────────────────────────────────────────┐
                  │  argocd-server pod  (on dealing-w-X)    │
                  │  container :8080                         │
                  │  serves HTML / API                       │
                  └─────────────────────────────────────────┘

       Response retraces steps 4 → 3 → Envoy → 2 → 1.
```

---

## 5. Observability data flow

Two distinct paths into Mimir/Loki — one from in-cluster Prometheus, one from on-host
Alloy.

```
   ╔══════════════════════════ DEALING CLUSTER ══════════════════════════╗
   ║                                                                       ║
   ║   ┌──────────────────┐         ┌───────────────────────────────┐    ║
   ║   │ App pod          │         │ kubelet/cadvisor on each node │    ║
   ║   │   /metrics       │         │   :10250 /metrics(+ cadvisor) │    ║
   ║   └─────────┬────────┘         └──────────────┬────────────────┘    ║
   ║             │                                  │                     ║
   ║             │                                  │                     ║
   ║             ▼                                  ▼                     ║
   ║   ┌────────────────────────────────────────────────────────────┐    ║
   ║   │  Prometheus (in-cluster)                                   │    ║
   ║   │  • Discovers ServiceMonitors                                │    ║
   ║   │  • Scrapes ~40 targets every 30s                            │    ║
   ║   │  • External labels: cluster_name=dealing                    │    ║
   ║   │  • writeRelabelConfigs drops *_bucket                       │    ║
   ║   └────────────────────────┬───────────────────────────────────┘    ║
   ║                            │ remote_write                            ║
   ║                            ▼                                         ║
   ║   ═══════════════════════════════════════════════════════════════    ║
   ║                                                                       ║
   ║   ┌────────────────────────┐         ┌─────────────────────────┐    ║
   ║   │  node /proc, /sys      │         │  /var/log/pods/*.log    │    ║
   ║   └───────────┬────────────┘         └───────────┬─────────────┘    ║
   ║               │                                  │                   ║
   ║               ▼                                  ▼                   ║
   ║   ┌────────────────────────────────────────────────────────────┐    ║
   ║   │  Alloy (systemd on each host, NOT a pod)                   │    ║
   ║   │  • prometheus.exporter.unix → loopback                      │    ║
   ║   │  • prometheus.scrape → forward                              │    ║
   ║   │  • loki.source.file → tail pod logs                         │    ║
   ║   │  • External labels: cluster_name=dealing, node=…            │    ║
   ║   └─────────────┬──────────────────────────────┬────────────────┘    ║
   ║                 │                              │                     ║
   ╚═════════════════╪══════════════════════════════╪═════════════════════╝
                     │                              │
                     │ HTTP POST to                 │ HTTP POST to
                     │ mimir.stackflow.org          │ loki.stackflow.org
                     ▼                              ▼
        ┌──────────────────────────────┐  ┌──────────────────────────────┐
        │  MIMIR @ 10.10.103.203       │  │  LOKI @ 10.10.103.x          │
        │   (off-cluster, tenant=dealing)│  │  (off-cluster)               │
        └────────────┬─────────────────┘  └───────────┬──────────────────┘
                     │                                 │
                     └──────────────┬──────────────────┘
                                    ▼
                        ┌────────────────────────────────┐
                        │  GRAFANA @ 10.10.103.203:3000  │
                        │   • Dashboards (incl. Overview) │
                        │   • Alert rules → MS Teams      │
                        └─────────────┬──────────────────┘
                                      │
                                      │ webhook (HTTPS)
                                      ▼
                              ┌──────────────────┐
                              │ Microsoft Teams  │
                              │ (Workflows / WH) │
                              └──────────────────┘
```

---

## 6. Security boundaries (four layers)

```
        ┌──────────────────────────────────────────────────────────────────┐
        │  LAYER 1 — Switch VLAN ACLs (network team)                       │
        │  • Pod traffic to cross-VLAN destinations blocked unless an      │
        │    explicit cross-VLAN port allowance exists.                    │
        │  • This is the network-layer security boundary.                  │
        ├──────────────────────────────────────────────────────────────────┤
        │  LAYER 2 — Cluster-wide CCNPs (platform team)                    │
        │  • platform-baseline-egress    (every pod → in-cluster + DNS +   │
        │                                  kube-apiserver)                  │
        │  • platform-baseline-ingress   (IngressController + Prometheus + │
        │                                  kube-system → every pod)         │
        │  Both ADDITIVE (enableDefaultDeny: false). Cluster trusts the    │
        │  switch; doesn't try to enforce CIDR boundaries.                 │
        ├──────────────────────────────────────────────────────────────────┤
        │  LAYER 3 — Per-app CNPs (app team, optional)                     │
        │  • CiliumNetworkPolicy in app's own namespace                    │
        │  • enableDefaultDeny.egress: true for tighter-than-baseline      │
        │  • Example: payments → toFQDNs *.stripe.com only                 │
        ├──────────────────────────────────────────────────────────────────┤
        │  LAYER 4 — Application TLS + authn (developers)                  │
        │  • mTLS, JWT, OAuth                                              │
        │  • Defense-in-depth on top of network policy                     │
        └──────────────────────────────────────────────────────────────────┘

         Additional cross-cutting guards:
         • WireGuard pod-to-pod encryption (cilium_wg0)
         • PodSecurityStandards labels (baseline / restricted) per namespace
         • Kyverno admission policies (blocks empty-selector CCNPs etc.)
         • cert-manager (auto-rotates TLS, prevents expiry incidents)
         • Kubernetes RBAC (token / cert based)
         • 30-day kube-apiserver audit log
```

---

## 7. Static-pod layout per master

```
                    dealing-m-N (10.10.120.13N)
        ╔════════════════════════════════════════════════════╗
        ║  Host kernel (Ubuntu 22.04, kernel 5.15)            ║
        ║                                                     ║
        ║   ┌─────────────────────────────────────────────┐  ║
        ║   │  systemd                                     │  ║
        ║   │   • rke2-server.service                      │  ║
        ║   │   • containerd (managed by rke2-server)      │  ║
        ║   │   • alloy.service (host-level metrics+logs)  │  ║
        ║   └─────────────────────────┬───────────────────┘  ║
        ║                             │                       ║
        ║                             ▼                       ║
        ║   ┌─────────────────────────────────────────────┐  ║
        ║   │  kubelet                                     │  ║
        ║   │   • reads /var/lib/rancher/rke2/agent/       │  ║
        ║   │     pod-manifests/*.yaml                     │  ║
        ║   │   • starts STATIC pods (no apiserver needed) │  ║
        ║   └─────────────────────────┬───────────────────┘  ║
        ║                             │                       ║
        ║         ┌───────────────────┼───────────────────┐  ║
        ║         ▼                   ▼                   ▼  ║
        ║   ┌─────────┐    ┌──────────────────┐    ┌──────────┐
        ║   │  etcd   │    │  kube-apiserver  │    │ scheduler│
        ║   │ :2379   │◀───│  :6443           │    │ :10259   │
        ║   │ :2380   │    │   • audit log    │    └──────────┘
        ║   │ :2381   │    │   • PSS plugin   │    ┌──────────┐
        ║   │ on scsi1 │    │   • TLS hardened │    │ kube-cont│
        ║   │ SSD     │    └──────┬───────────┘    │ -manager │
        ║   └─────────┘           │                │ :10257   │
        ║                         │                └──────────┘
        ║                         ▼                ┌──────────┐
        ║                ┌──────────────────┐      │ kube-vip │
        ║                │ cloud-controller-│      │ -ds      │
        ║                │ manager          │      │ holds VIP│
        ║                └──────────────────┘      │  .138    │
        ║                                          └──────────┘
        ║                                                     ║
        ║   DAEMONSET PODS (managed via apiserver):            ║
        ║     cilium-agent (with embedded Envoy + Hubble)     ║
        ║                                                     ║
        ║   ─── Disks ───                                     ║
        ║   /            → 50 GiB OS disk (scsi0)            ║
        ║   /var/lib/rancher/rke2/server/db                   ║
        ║              → 20 GiB SSD etcd disk (scsi1)         ║
        ╚════════════════════════════════════════════════════╝
```

---

## 8. Worker node layout

```
                    dealing-w-N (10.10.120.134-136)
        ╔════════════════════════════════════════════════════╗
        ║  Host kernel (Ubuntu 22.04, kernel 5.15)            ║
        ║                                                     ║
        ║   ┌─────────────────────────────────────────────┐  ║
        ║   │  systemd                                     │  ║
        ║   │   • rke2-agent.service                       │  ║
        ║   │   • containerd                               │  ║
        ║   │   • alloy.service                            │  ║
        ║   └─────────────────────────┬───────────────────┘  ║
        ║                             │                       ║
        ║                             ▼                       ║
        ║   ┌─────────────────────────────────────────────┐  ║
        ║   │  kubelet → kube-apiserver (via VIP .138)    │  ║
        ║   │  :10250                                       │  ║
        ║   └─────────────────────────┬───────────────────┘  ║
        ║                             │                       ║
        ║   DAEMONSET PODS:                                   ║
        ║     cilium-agent                                    ║
        ║                                                     ║
        ║   WORKLOAD PODS (where the apps actually run):     ║
        ║     ┌──────────────────────────────────────────┐   ║
        ║     │  webtrader pod                            │   ║
        ║     │  crm pod                                  │   ║
        ║     │  affiliate pod                            │   ║
        ║     │  ... (defined by ArgoCD Apps)             │   ║
        ║     └──────────────────────────────────────────┘   ║
        ║                                                     ║
        ║   PLATFORM POD (depending on placement):            ║
        ║     monitoring/prometheus (statefulset, 1 of 3 ws)  ║
        ║     monitoring/kube-state-metrics                   ║
        ║     monitoring/kps-operator                         ║
        ║                                                     ║
        ║   ─── Disks ───                                     ║
        ║   /            → 100 GiB OS disk (scsi0)           ║
        ║   /var/lib/data → 20 GiB data disk (scsi1,         ║
        ║                    for local-path PVs)              ║
        ╚════════════════════════════════════════════════════╝
```

---

## 9. Pod-to-pod encryption mesh

Showing how WireGuard wraps pod traffic between nodes.

```
                            ┌─────────────────────────────┐
                            │  POD A on dealing-w-1       │
                            │  10.42.4.11 → ... :443      │
                            └─────────────┬───────────────┘
                                          │ plain TCP
                                          ▼
                            ┌─────────────────────────────┐
                            │  cilium-agent on w-1        │
                            │  BPF: "destination is        │
                            │   another node — encrypt"   │
                            └─────────────┬───────────────┘
                                          │ encapsulate in WG
                                          ▼
                            ┌─────────────────────────────┐
                            │  cilium_wg0 (UDP :51871)    │
                            │  Curve25519 + ChaCha20Poly  │
                            └─────────────┬───────────────┘
                                          │ encrypted UDP on eth0
                                          ▼
                            ╔═════════════════════════════╗
                            ║   underlay network          ║
                            ║   (10.10.120.x VLAN)         ║
                            ║   anyone watching the wire   ║
                            ║   sees only encrypted bytes  ║
                            ╚═════════════╤═══════════════╝
                                          │
                                          ▼
                            ┌─────────────────────────────┐
                            │  cilium_wg0 on w-3          │
                            │  Decrypts to inner packet   │
                            └─────────────┬───────────────┘
                                          │ plain TCP
                                          ▼
                            ┌─────────────────────────────┐
                            │  POD B on dealing-w-3       │
                            │  Receives TCP on :443       │
                            └─────────────────────────────┘
```

5 WG peers per node (full mesh among 6 nodes).

---

## 10. The "everything" picture

A single overview that brings it all together.

```
   ┌────────────────────────────────────────────────────────────────────────────┐
   │                                                                            │
   │  EXTERNAL                                                                  │
   │                                                                            │
   │   ┌──────────┐    ┌─────────────────┐    ┌────────────────────────────┐   │
   │   │ Browser  │    │ DevOps laptop   │    │ MS Teams channel           │   │
   │   │  user    │    │ (via VPN)       │    │ (receives alerts)          │   │
   │   └────┬─────┘    └────────┬────────┘    └────────────▲───────────────┘   │
   │        │                    │                          │                   │
   └────────┼────────────────────┼──────────────────────────┼───────────────────┘
            │                    │                          │
            │ HTTPS              │ HTTPS                    │ webhook
            │ → .140 LB IP       │ → .138 VIP : 6443        │
            │                    │                          │
   ┌────────┼────────────────────┼──────────────────────────┼───────────────────┐
   │        ▼                    ▼                          │                   │
   │  ┌─────────────────────────────────────────────────────┴────────────┐     │
   │  │                  L3 SWITCH (VLAN ACLs)                            │     │
   │  └────┬──────────────────┬──────────────────────────────────┬──────┘     │
   │       │                  │                                  │             │
   │       ▼                  ▼                                  ▼             │
   │ ┌─────────────┐  ┌───────────────────────┐  ┌──────────────────────────┐ │
   │ │ OBS VLAN    │  │ DEALING CLUSTER VLAN  │  │ JUMPBOX VLAN              │ │
   │ │ 10.10.103/24│  │ 10.10.120/24          │  │ 10.10.16/24               │ │
   │ │             │  │                       │  │                          │ │
   │ │ • Mimir     │  │ ┌─── MASTERS ───┐    │  │ • Pritunl VPN endpoint   │ │
   │ │ • Loki      │  │ │ m-1 .131       │    │  │                          │ │
   │ │ • Grafana   │  │ │ m-2 .132       │    │  └──────────────────────────┘ │
   │ │ • Alerts    │  │ │ m-3 .133       │    │                               │
   │ │             │  │ │ + VIP .138     │    │                               │
   │ └──▲───▲──────┘  │ └─────────────────┘    │                               │
   │    │   │         │                       │                               │
   │    │   │         │ ┌─── WORKERS ───┐    │                               │
   │    │   │         │ │ w-1 .134       │    │                               │
   │    │   │         │ │ w-2 .135       │    │                               │
   │    │   │         │ │ w-3 .136       │    │                               │
   │    │   │         │ │ + LB IP .140   │    │                               │
   │    │   │         │ └─────────────────┘    │                               │
   │    │   │         │                       │                               │
   │    │   │         │ Components in-cluster:│                               │
   │    │   │         │  • Cilium (CNI + WG + │                               │
   │    │   │         │     IngressCtrl +     │                               │
   │    │   │         │     Hubble)           │                               │
   │    │   │         │  • cert-manager       │                               │
   │    │   │         │  • external-secrets   │                               │
   │    │   │         │  • ArgoCD             │                               │
   │    │   │         │  • Kyverno            │                               │
   │    │   │         │  • kube-prometheus    │                               │
   │    │   │         │     stack             │                               │
   │    │   │         │                       │                               │
   │    │   │         │ Components on hosts:  │                               │
   │    │   │         │  • Alloy (systemd)    │                               │
   │    │   │         │     scrape + log ship │                               │
   │    │   │         └──────────┬────────────┘                               │
   │    │   │                    │                                            │
   │    │   └────────────────────┘ Prometheus remote_write                    │
   │    │                          (cluster_name=dealing)                     │
   │    │                                                                     │
   │    └─────────────────────────┐                                           │
   │                              │ Alloy → Mimir / Loki                       │
   │                              │ (cluster_name=dealing, node=…)             │
   │                                                                          │
   └──────────────────────────────────────────────────────────────────────────┘
```

---

## 11. End-to-end: public user → deployed app `xyz`

This shows the full path a packet takes from a user's browser on the public internet,
all the way to your `xyz` pod deployed on dealing. Every defense layer is annotated
with what it does, what protocol/port, and where TLS gets terminated and re-encrypted.

### 11.1 The chain — every hop

```
                       ┌───────────────────────────────┐
                       │   END USER                    │
                       │   public internet anywhere    │
                       │   browser → https://xyz.<...> │
                       └──────────────┬────────────────┘
                                      │
                                      │  1. DNS:  user's resolver → 1.1.1.1
                                      │     → Cloudflare authoritative DNS
                                      │     → returns Cloudflare anycast IP
                                      ▼
   ╔══════════════════════════════════════════════════════════════════════════╗
   ║                          PUBLIC EDGE                                      ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 2. CLOUDFLARE  (the global anycast edge)                            │  ║
   ║  │    • TLS termination #1   ← user cert (Cloudflare-managed)          │  ║
   ║  │    • DDoS scrub (L3/L4 + L7)                                        │  ║
   ║  │    • Bot management / rate limit / firewall rules                   │  ║
   ║  │    • CDN cache hit? → respond directly, never bothers origin        │  ║
   ║  │    • CDN miss → forward to next hop (TLS re-encrypts to origin)     │  ║
   ║  │    Listening on: 443/TCP HTTPS                                       │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │  HTTPS                                  ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 3. AWS CLOUDFRONT  (origin shield CDN tier in AWS)                  │  ║
   ║  │    • TLS termination #2 ← Cloudflare↔CloudFront cert                │  ║
   ║  │    • Second-tier cache (longer TTL than Cloudflare edge)            │  ║
   ║  │    • Lambda@Edge / CloudFront Functions for request rewriting       │  ║
   ║  │    Listening on: 443/TCP                                             │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │  HTTPS                                  ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 4. AWS WAF  (Web Application Firewall, attached to CloudFront)      │  ║
   ║  │    • L7 inspection — method, URL, headers, body                      │  ║
   ║  │    • Managed rule sets (OWASP Top 10, Anonymous-IP, KnownBadInputs) │  ║
   ║  │    • Custom rules (IP allowlist, geo block, rate limit per token)   │  ║
   ║  │    • Drops → 403; allows → forward                                  │  ║
   ║  │    (Stateless inspection — no TLS termination here, sees decrypted  │  ║
   ║  │     stream from CloudFront)                                          │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │  HTTPS                                  ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 5. AWS ALB / NLB  (load balancer fronting on-prem origin)           │  ║
   ║  │    • L4 (NLB) or L7 (ALB) load balancing                            │  ║
   ║  │    • Health checks against on-prem origin                            │  ║
   ║  │    • Routes to on-prem via: Direct Connect / Site-to-Site VPN /     │  ║
   ║  │      Transit Gateway                                                 │  ║
   ║  │    • TLS termination #3 (optional, depends on ALB cert config)       │  ║
   ║  │    Listening on: 443/TCP                                             │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ╚═════════════════════════════════╪═════════════════════════════════════════╝
                                     │
                                     │  HTTPS over Direct Connect / VPN tunnel
                                     │  (private IP space at this point)
                                     ▼
   ╔══════════════════════════════════════════════════════════════════════════╗
   ║                       ON-PREM PERIMETER                                   ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 6. PHYSICAL FIREWALL  (e.g. Palo Alto / FortiGate / Cisco ASA)      │  ║
   ║  │    • Stateful packet inspection                                      │  ║
   ║  │    • Application-layer policy (App-ID / AppCtrl)                    │  ║
   ║  │    • Threat prevention (IPS signatures, anti-malware)               │  ║
   ║  │    • Inbound NAT: public LB origin IP → internal corporate IP       │  ║
   ║  │    • Logs every connection (SIEM-fed)                               │  ║
   ║  │    Listening on: per ACL rules                                       │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │  HTTPS — corporate L3                  ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 7. L3 SWITCH  (your switch fabric)                                  │  ║
   ║  │    • VLAN routing                                                    │  ║
   ║  │    • Cross-VLAN ACLs — only permitted ports between VLANs            │  ║
   ║  │    • Forwards to dealing cluster VLAN 10.10.120.0/24                 │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ╚═════════════════════════════════╪═════════════════════════════════════════╝
                                     │  HTTPS to 10.10.120.140 : 443
                                     ▼
   ╔══════════════════════════════════════════════════════════════════════════╗
   ║                          DEALING CLUSTER                                  ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 8. CILIUM INGRESS LB IP  10.10.120.140                              │  ║
   ║  │    • Cilium L2 Announcements — current leader cilium-agent answers  │  ║
   ║  │      ARP for this IP                                                 │  ║
   ║  │    • Packet hits one of the 6 nodes (whichever holds it now)         │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │                                         ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 9. CILIUM-AGENT → embedded ENVOY (IngressController)                │  ║
   ║  │    • TLS termination #4 (final, with app's cert from cert-manager)  │  ║
   ║  │    • Reads HTTP Host header = xyz.<your-internal-domain>            │  ║
   ║  │    • Looks up Ingress resource → backend Service xyz.<ns>.svc:80    │  ║
   ║  │    • Hubble L7 metrics emitted for this request                     │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │  plain HTTP (in-cluster)                ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 10. CILIUM BPF (kube-proxy replacement)                             │  ║
   ║  │     • Service ClusterIP 10.43.x.x → backend pod IP 10.42.y.z         │  ║
   ║  │     • O(1) BPF map lookup                                            │  ║
   ║  │     • If destination pod is on a different node → WireGuard         │  ║
   ║  │       encrypts and ships via cilium_wg0 (UDP :51871)                │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ║                                 │                                         ║
   ║                                 ▼                                         ║
   ║  ┌────────────────────────────────────────────────────────────────────┐  ║
   ║  │ 11. XYZ POD  (running on some dealing-w-N)                           │  ║
   ║  │     • CCNPs (platform-baseline-ingress) allow ingress from           │  ║
   ║  │       IngressController identity                                      │  ║
   ║  │     • Per-app CNP (if any) further restricts                          │  ║
   ║  │     • Application container receives request on its container port    │  ║
   ║  │     • Processes, generates response                                   │  ║
   ║  └──────────────────────────────┬─────────────────────────────────────┘  ║
   ╚═════════════════════════════════╪═════════════════════════════════════════╝
                                     │
                                     │  RESPONSE PATH retraces every hop in reverse.
                                     │  Each hop re-encrypts with its own cert.
                                     │  Each cache layer (Cloudflare, CloudFront) may
                                     │  cache the response for next time.
                                     ▼
                       ┌───────────────────────────────┐
                       │   END USER                    │
                       │   browser renders the page    │
                       └───────────────────────────────┘
```

### 11.2 Per-layer summary — what each layer does for you

| # | Layer | Primary job | Defends against | TLS terminates here? |
|---|---|---|---|---|
| 1 | DNS resolver | Resolves the hostname | (none directly; DNSSEC if used) | n/a |
| 2 | **Cloudflare** | CDN cache, DDoS scrub, global edge | Volumetric DDoS, bots, basic L7 attacks | **Yes** — first TLS endpoint |
| 3 | **AWS CloudFront** | Origin-shield CDN closer to AWS | Origin fetch reduction, longer TTL caching | Yes (Cloudflare ↔ CloudFront cert) |
| 4 | **AWS WAF** | L7 packet inspection rules | OWASP Top 10, SQL injection, XSS, abuse | (inspects decrypted stream — no separate TLS) |
| 5 | **AWS ALB / NLB** | Routes to on-prem origin | Backend unhealthy targets, simple L4 floods | Optional re-encryption |
| 6 | **Physical firewall** | Stateful inspection on-prem | Lateral movement, exfiltration, exploits | (sees encrypted stream; can do SSL decrypt if configured) |
| 7 | **L3 switch** | VLAN routing + cross-VLAN ACLs | Lateral movement between VLANs | (no — L4 only) |
| 8 | **Cilium L2 announce** | Picks a cluster node to receive | n/a — just MAC announcement | (no) |
| 9 | **Cilium IngressController (Envoy)** | Routes by Host/path to Service | Bad Host headers, missing TLS | **Yes** — final TLS endpoint, app's cert |
| 10 | **Cilium BPF** | Service IP → pod IP, encrypts if cross-node | Service-level pod-IP churn, MITM (via WG) | (no) |
| 11 | **Pod (xyz)** | Runs the application | (app's own TLS/authn for any internal call) | (no — receives plain HTTP from Envoy) |

### 11.3 Where TLS terminates (the certs at each layer)

This is worth highlighting because **TLS doesn't go end-to-end from browser to pod by
default** — it terminates and re-encrypts at multiple hops.

```
   Browser  ─────TLS (Cloudflare cert)────▶ Cloudflare edge
                                            │
                                            ▼
                                            (decrypted, inspected,
                                             cached as needed)
                                            │
   Cloudflare ──TLS (origin cert)──────────▶ AWS CloudFront → WAF → ALB
                                                                   │
                                                                   ▼
                                                            (decrypted again)
                                                                   │
   ALB     ─────TLS (corp cert) over Direct Connect─────▶ Phys firewall → L3 sw
                                                                   │
                                                                   ▼
                                                            (decrypted at Envoy)
                                                                   │
   Envoy   ────plain HTTP in-cluster────────────────────▶ xyz pod
```

If your security policy mandates end-to-end TLS to the pod, you can keep the in-cluster
hop encrypted too by:
- Terminating TLS at the pod (the app does TLS, not Envoy)
- OR using mTLS via a service mesh (Linkerd / Istio / Cilium Service Mesh)
- OR using Envoy's upstream TLS to a self-signed cert in the pod

Most setups accept the plain in-cluster hop because pod-to-pod traffic is already
WireGuard-encrypted between nodes.

### 11.4 What gets logged where (forensics chain)

| Hop | Logs that exist | Retention | Use when |
|---|---|---|---|
| Cloudflare | All requests (free + paid tiers) | hours-days (free) / years (paid) | DDoS / bot analysis |
| CloudFront | Access logs to S3 | configurable | CDN miss debugging |
| WAF | Sample of blocks + allows | configurable in CloudWatch | "Was X request blocked?" |
| ALB | Access logs to S3 | configurable | "Did the request reach the origin?" |
| Physical firewall | Connection logs to SIEM | per-corp policy | Cross-network forensics |
| L3 switch | Flow logs (if enabled) | per-corp policy | VLAN-level traffic |
| Cilium / Hubble | Flow events | in-memory + scrape to Mimir | "Was packet dropped by NetworkPolicy?" |
| Envoy (IngressController) | hubble_http_* metrics in Mimir | retention per Mimir config | Per-route latency / status |
| Pod / app | App logs → stdout → Alloy → Loki | per Loki retention | Application-level issues |

You can build a forensic timeline of one request by querying these in order. The
Hubble flow + Envoy access events + app log line all carry timestamps you can correlate.

### 11.5 Quick mental shortcut

**Three "trust zones" the request crosses:**

```
   PUBLIC INTERNET (untrusted)
        │
        │   Cloudflare + CloudFront + WAF + ALB  ─── defenses owned by your security team
        │
        ▼
   CORPORATE NETWORK (semi-trusted)
        │
        │   Phys firewall + L3 switch ─── defenses owned by your network team
        │
        ▼
   CLUSTER (trusted)
        │
        │   Cilium Ingress + Envoy + BPF + CCNPs + WireGuard ─── you (platform team)
        │
        ▼
   POD (the app)
```

Each zone has its own security layer. A request that reaches your pod has been
inspected and either explicitly permitted or implicitly trusted by every layer above.

---

## How to render these for slides / reviews

ASCII works in any terminal and any markdown viewer. If you want richer renderings:

| Tool | How |
|---|---|
| **asciiflow.com** | Copy a diagram block in, edit visually, export back as text or PNG |
| **draw.io / diagrams.net** | "Insert ASCII Art" / Lucid chart "From ASCII" |
| **Mermaid** | Reshape any of these into Mermaid syntax (`graph LR/TD`) for nice diagrams in GitHub markdown |
| **PlantUML** | Same idea, more node-shape control |

These ASCII versions are the source of truth; a rendered PNG is a derived artifact.

---

## See also

- [`cluster-handbook-dealing.md`](./cluster-handbook-dealing.md) §1 (shape of the cluster), §6 (Cilium), §25 (end-to-end flows)
- [`workload-catalog-dealing.md`](./workload-catalog-dealing.md) — what's actually deployed where
- [`runbook-dealing.md`](./runbook-dealing.md) — what to do when something on this diagram breaks
- [`cluster-architecture-comparison-dealing-vs-fxview.md`](./cluster-architecture-comparison-dealing-vs-fxview.md) — why this architecture vs the older one

---

*Diagrams generated 2026-05-22. Update whenever the topology changes (new nodes, new components, new flows).*
