# Month 2, Week 8 — ClusterMesh + WireGuard + first blog post

> Month 2's finale. ClusterMesh (multi-cluster Cilium), WireGuard
> internals (the encryption already on dealing), and your first public
> piece of writing.

## Goal for the week

By Saturday, you have:
- A local pair of Cilium kind clusters joined by ClusterMesh
- A deep understanding of how dealing's WireGuard encryption works
  (keys, rotation, what's covered)
- Published a blog post on dev.to or your own site

## Time breakdown

- Theory: ~2 hours
- Lab: ~5 hours (mesh)
- Blog: ~6 hours (writing + revision)
- Buffer: ~2 hours

---

## Part 1 — Theory

### 1.1 ClusterMesh: what it is

Two Cilium clusters joined together so that:
- Pods in cluster A can call Services in cluster B by name
- Identities are shared (cluster B's `app=frontend` identity is visible to A)
- Policies can reference cross-cluster identities
- DNS resolution works across clusters

**Mechanism:**
- Each cluster runs an `etcd` (clustermesh-apiserver) that exposes identities + services
- Other clusters connect to it as read-only clients
- The local cilium-agent enriches its ipcache with remote-cluster identities

```
   ┌─────── Cluster A ─────────┐         ┌─────── Cluster B ─────────┐
   │  cilium-agent              │ ◄─────► │  cilium-agent              │
   │  ├ identities (local)      │  mesh   │  ├ identities (local)      │
   │  └ identities (B, remote)  │  etcd   │  └ identities (A, remote)  │
   │                            │         │                            │
   │  Service frontend-a        │         │  Service backend-b         │
   │  pods…                     │         │  pods…                     │
   └────────────────────────────┘         └────────────────────────────┘
```

A pod in cluster A can `curl backend-b.default.svc.clusterset.local` and
Cilium routes it to a backend pod in cluster B.

### 1.2 When you'd use ClusterMesh

- Multi-region active-active
- HA: failover from primary to secondary cluster
- Region-specific tenants but shared back-end services
- Migration from one cluster to another with zero downtime

Why this matters for 50 LPA: every fintech/SaaS has a multi-region story.
Showing you understand multi-cluster networking distinguishes you from
"single cluster" candidates.

### 1.3 WireGuard internals — what dealing uses

WireGuard is a fast, modern VPN protocol. Cilium uses it to encrypt
pod-to-pod traffic between nodes.

**The model:**
- Each node has a WireGuard private key, stored at `/var/lib/cilium/wireguard/`
- Each node's public key is published via the WireGuard interface (`cilium_wg0`)
- Cilium agent puts public keys into the cilium identity store, distributed
  to all peers
- When pod-A on node-1 sends to pod-B on node-2, BPF redirects the packet
  into the WireGuard interface, which encrypts and sends as UDP to node-2's
  WireGuard endpoint
- Node-2's WireGuard decrypts, BPF routes to pod-B's veth

**What's encrypted:**
- All cross-node pod-to-pod traffic
- All cross-node pod-to-service traffic

**What's NOT encrypted:**
- Same-node pod-to-pod (stays on host, no need)
- Host-to-host non-pod traffic (kubelet ↔ apiserver) — that's TLS, not WG
- Traffic to external endpoints (world) — leaves WireGuard interface

**Key rotation:**
- WireGuard doesn't auto-rotate keys; Cilium does on pod restart
- For prod, rotate by rolling cilium-agent DaemonSet quarterly

**Performance:**
- WireGuard adds ~5-10 μs per packet on modern CPUs
- Throughput: ~1-3 Gbps single-stream, line-rate (10 Gbps+) multi-stream

### 1.4 IPSec vs WireGuard for Cilium

Cilium supports both. Comparison:

| | WireGuard | IPSec |
|---|---|---|
| Setup complexity | Low | High (IKE, certs, SAs) |
| Performance | Higher | Lower |
| Maturity | New (2020) | Decades |
| FIPS compliance | Limited | Yes |
| Use when | Most cases | Compliance demand |

Dealing uses WireGuard — modern, fast, simpler. Most non-government shops do.

---

## Part 2 — Lab

### Lab 1 — Two kind clusters with Cilium ClusterMesh (~4 hours)

Use kind because it's free and ClusterMesh on dealing would be production-risky.

```bash
# Create two kind clusters
cat <<EOF > kind-1.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.11.0.0/16"
nodes:
- role: control-plane
- role: worker
EOF
kind create cluster --name=mesh-1 --config=kind-1.yaml

# Cluster 2 with different CIDRs (required for mesh)
sed 's/10.10/10.20/g; s/10.11/10.21/g' kind-1.yaml > kind-2.yaml
kind create cluster --name=mesh-2 --config=kind-2.yaml

# Install Cilium on each
cilium install --set cluster.name=mesh-1 --set cluster.id=1 --context kind-mesh-1
cilium install --set cluster.name=mesh-2 --set cluster.id=2 --context kind-mesh-2

# Enable mesh
cilium clustermesh enable --context kind-mesh-1
cilium clustermesh enable --context kind-mesh-2

# Connect them
cilium clustermesh connect --context kind-mesh-1 --destination-context kind-mesh-2

# Wait + verify
cilium clustermesh status --context kind-mesh-1 --wait
```

Test a cross-cluster service:

```bash
# Deploy a service in cluster 2
kubectl --context kind-mesh-2 apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: rebel-base }
spec:
  replicas: 2
  selector: { matchLabels: { app: rebel-base } }
  template:
    metadata: { labels: { app: rebel-base } }
    spec:
      containers:
      - name: rebel
        image: docker.io/cilium/json-mock:1.3.5
---
apiVersion: v1
kind: Service
metadata:
  name: rebel-base
  annotations: { service.cilium.io/global: "true" }   # exposed across mesh
spec:
  selector: { app: rebel-base }
  ports: [{ port: 80 }]
EOF

# Call from cluster 1
kubectl --context kind-mesh-1 run -i --tty client --image=curlimages/curl --rm \
  -- curl http://rebel-base.default.svc.cluster.local/
# Returns JSON — proves cross-cluster routing works
```

### Lab 2 — Inspect WireGuard on dealing (~1 hour)

SSH to a dealing master:

```bash
# WireGuard interface
ip link show cilium_wg0

# Public keys of peers
wg show cilium_wg0

# Verify encryption is enabled
kubectl -n kube-system exec ds/cilium -- cilium-dbg config | grep -i encrypt
# Should show: EncryptInterface, EnableWireguard, etc.

# Look at the keys directory
sudo ls /var/lib/cilium/wireguard/
```

You'll see one private key per node. The public keys are advertised via
Cilium's BPF maps.

### Lab 3 — Blog post writing (~6 hours)

Topic: "Cilium eBPF vs iptables in production — observations from a
6-node cluster"

**Outline (write to this, ~1500 words):**

1. **Intro** (200 words): why I write this. What dealing is. The Cilium
   choice.
2. **What changes in production** (300 words): VLAN-segmented network, real
   workloads, real latency requirements. Why this isn't a demo.
3. **The iptables baseline (mental model)** (300 words): how kube-proxy
   does it, scaling pain points (rule explosion, conntrack pressure),
   debugging horror stories.
4. **The Cilium model in practice** (400 words): BPF maps, identity-based
   policy, latency improvement (real numbers from your dashboards), what
   we observed migrating off iptables.
5. **What broke** (300 words): the endpointSelector:{} incident. How we
   detected it (argocd UI down), how we fixed it (matchExpressions),
   what we learned.
6. **What we'd do differently** (200 words): audit mode for new policies,
   stricter CCNP review process.
7. **Conclusion + reading list** (100 words).

**Drafting plan:**
- Day 1: write 800-word rough draft in one sitting. Don't edit.
- Day 2: revise. Tighten language. Add 1-2 diagrams (ASCII or PNG).
- Day 3: publish on dev.to. Cross-post to your LinkedIn.

**Quality bar:**
- ≥1 real diagram (you have plenty in your dealing docs already)
- ≥1 specific number (latency, scrape count, policy count) — generic claims
  are weak
- ≥1 personal story (the endpointSelector incident is gold)
- Link to authoritative sources (Cilium docs, eBPF papers)

Tag with: `kubernetes`, `cilium`, `ebpf`, `networking`, `devops`

**Why this matters more than you think:**
Hiring managers search blog posts. A specific, well-written post is worth
~10 LinkedIn endorsements. It also gives interviewers a question hook:
"Tell me more about that endpointSelector incident."

### Lab 4 — LinkedIn + GitHub sweep (~1 hour)

- Update LinkedIn headline to mention "Cilium / eBPF / Kubernetes Platform"
- Add the blog post as a "Featured" item
- Push your dealing-architecture diagrams (suitably anonymized — remove
  IPs, customer names) to a public GitHub repo as "Reference architecture
  diagrams for an on-prem Kubernetes cluster"
- Pin that repo on your profile

### Lab 5 — Tear down kind clusters (~15 min)

```bash
kind delete cluster --name=mesh-1
kind delete cluster --name=mesh-2
```

---

## Part 3 — Saturday review checkpoint

Bring me your published blog post + LinkedIn profile screenshot.

Quick verbal questions:

1. **Why must the two ClusterMesh clusters have different pod and service CIDRs?**
2. **When a pod in cluster A calls `backend.default.svc.cluster.local`,
   how does Cilium decide which cluster's backend to route to?** (Answer:
   service is annotated `global: true`; both clusters' backends register;
   Cilium L4 LB picks via affinity policy.)
3. **Cilium's WireGuard implementation encrypts X but not Y. Be specific
   about both X and Y.**
4. **The blog post. What's the single most important thing you took away
   from writing it?** (Answer this honestly, no canned answer.)

---

## Resources

- [Cilium ClusterMesh docs](https://docs.cilium.io/en/stable/network/clustermesh/)
- [Cilium WireGuard docs](https://docs.cilium.io/en/stable/security/network-encryption/)
- [WireGuard whitepaper](https://www.wireguard.com/papers/wireguard.pdf)
- [dev.to writing guide](https://dev.to/help/writing) (technical post formatting)

---

## What's next: Month 3 — Go + Kubernetes operator + portfolio

End of Month 2. You can:
- Architect EKS clusters
- Debug Cilium from BPF maps
- Author CCNPs
- Reason about multi-cluster mesh
- Published 1 blog post (one milestone done!)

Month 3 shifts to code: Go fundamentals (Week 9), kubebuilder + first
operator (Week 10), polish + 2nd blog (Week 11), LinkedIn + start
applying (Week 12).

This is the month that moves you from "ops engineer who knows networking"
to "platform engineer who can ship Go."
