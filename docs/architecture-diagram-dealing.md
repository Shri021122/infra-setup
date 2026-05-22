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
