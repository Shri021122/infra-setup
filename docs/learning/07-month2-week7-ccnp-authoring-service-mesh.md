# Month 2, Week 7 — CCNP authoring + service mesh basics

> You've read CCNPs. This week you write them from scratch — three
> production-grade ones for dealing, with full justification. Then a
> shallow swim through Cilium Service Mesh: mTLS, traffic shifting, retries.

## Goal for the week

By Saturday, you can:
- Author a CCNP from a plain-English requirement, justifying every rule
- Apply the 4-layer policy model dealing uses (switch ACL → CCNP → CNP → app TLS)
- Use Cilium Service Mesh mTLS in identity mode
- Set up canary traffic shifting via HTTPRoute weighted backends
- Explain why dealing chose Cilium Service Mesh over Istio

## Time breakdown

- Theory: ~2 hours
- Lab on dealing cluster: ~10 hours
- Buffer: ~3 hours

---

## Part 1 — Theory

### 1.1 The 4-layer policy model (dealing)

```
┌───────────────────────────────────────────────────────────────────┐
│ Layer 1: Switch VLAN ACLs                                          │
│   Hard segmentation between cluster subnets and other VLANs.       │
│   Only allowed cross-VLAN flows: explicit pinholes (DNS, NTP, IPMI)│
└───────────────────────────────────────────────────────────────────┘
                              │ traffic that survived L1
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer 2: Cluster-wide CCNPs                                        │
│   Platform-level baselines:                                        │
│   - Every pod can reach DNS, kube-apiserver, host services         │
│   - IngressController can reach all pods                           │
│   - Monitoring can scrape all pods                                 │
│   Mode: enableDefaultDeny: false (additive only)                   │
│   Authored: by you (platform team)                                 │
└───────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer 3: Per-app CNPs                                              │
│   Application-specific rules. Restrict what a workload can reach.  │
│   Mode: enableDefaultDeny: true (default-deny, opt-in allows)      │
│   Authored: by app teams, reviewed by platform team                │
└───────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer 4: App-layer authn/authz (TLS, JWT, OAuth)                   │
│   Application-level identity + access control                      │
└───────────────────────────────────────────────────────────────────┘
```

Defense in depth: a flow has to pass all four. No single layer is the
"security boundary" alone.

### 1.2 CCNP vs CNP

| | CCNP (CiliumClusterwideNetworkPolicy) | CNP (CiliumNetworkPolicy) |
|---|---|---|
| Scope | Cluster-wide | Namespaced |
| Owner | Platform team | App teams |
| Use for | Baselines, infra → workload allows | App-specific rules |
| RBAC | Locked to platform admins | App teams can edit |

A common pattern (dealing uses this):
- CCNPs are additive baselines (enableDefaultDeny: false)
- Each app's CNP sets enableDefaultDeny: true for its own pods, then explicit allows

When BOTH apply to a pod, Cilium ANDs them — both must allow. Because the
baseline CCNP doesn't deny anything (additive), the app's CNP determines
the actual restrictions.

### 1.3 The `endpointSelector: {}` footgun in detail

`{}` matches every endpoint, INCLUDING reserved identities (host, ingress,
world, remote-node). If the policy has even one default-deny rule, every
endpoint's `policy enabled` flag flips on — and reserved-identity endpoints
that should be permissive suddenly need explicit allows.

**The fix patterns:**

```yaml
# Pattern A: pods only (exclude all reserved)
endpointSelector:
  matchExpressions:
  - { key: k8s:io.kubernetes.pod.namespace, operator: Exists }

# Pattern B: specific namespaces
endpointSelector:
  matchExpressions:
  - { key: k8s:io.kubernetes.pod.namespace, operator: In, values: [argocd, default] }

# Pattern C: by label
endpointSelector:
  matchLabels: { tier: app }
```

Pattern A is what dealing uses for platform baselines.

### 1.4 CIDR vs identity selectors

Two ways to allow egress to "external":

```yaml
egress:
- toCIDR: [8.8.8.8/32]                     # by IP — use for external IPs
- toEntities: [world]                       # by identity — everything external
- toFQDNs: [{ matchName: api.stripe.com }]  # by DNS — auto-resolved to IPs
```

`toCIDR` is most explicit but brittle (IPs change).
`toEntities: [world]` is broadest, useful for "any external."
`toFQDNs` requires Cilium's DNS proxy to be enabled (it intercepts pod DNS,
caches the response, allows the resolved IP).

### 1.5 Cilium Service Mesh — what it does

Cilium 1.16+ ships a "service mesh" that's NOT sidecar-based. Instead:
- mTLS is implemented in the BPF datapath using SPIFFE identities
- Traffic policies (retries, timeouts, circuit breaking) via Gateway API filters
- Tracing via Hubble L7

**Comparison with Istio:**

| | Cilium Service Mesh | Istio |
|---|---|---|
| Architecture | Sidecar-less (BPF + Envoy DaemonSet) | Sidecar Envoy per pod (~50MB RAM each) |
| mTLS | SPIFFE in BPF datapath | Envoy-to-Envoy TLS |
| Overhead per pod | ~0 | 50-150 MB RAM, 0.1-1 vCPU |
| Mature | Less | More |
| Operator complexity | Lower | High |

For dealing: Cilium Service Mesh is a good fit because you already use Cilium
and don't want the sidecar tax. For Istio shops (your target employers), know
both at a vocabulary level.

### 1.6 Why your interview pitch should mention "we chose Cilium SM over Istio"

A real engineering decision. The trade-off:
- Less mature, fewer features (no traffic mirroring yet, less rich auth policy)
- Massively lower overhead at scale (no sidecar tax)
- One vendor (Cilium covers CNI, Ingress, mesh) reduces operator surface area

That kind of justification is what 50 LPA candidates sound like in
architecture rounds.

---

## Part 2 — Lab on the dealing cluster

### Lab 1 — Audit existing CCNPs (~1 hour)

```bash
kubectl get ccnp -A
kubectl get ccnp <name> -o yaml | yq '.spec'
```

Document each policy:
- Selector (what does it match?)
- enableDefaultDeny mode
- Direction (ingress, egress, or both)
- What it allows

Cross-reference against the 4-layer model: which layer is each one?

### Lab 2 — Author CCNP #1: Allow DNS to External (~2 hours)

**Requirement**: All pods in the cluster should be able to resolve external
hostnames via the cluster's CoreDNS, which in turn forwards to upstream
DNS (1.1.1.1, 8.8.8.8).

Two flows to allow:
1. Pod → CoreDNS (UDP/TCP 53)
2. CoreDNS → upstream (UDP 53 to 1.1.1.1, 8.8.8.8)

Sketch:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata: { name: dns-egress-baseline }
spec:
  enableDefaultDeny: { ingress: false, egress: false }
  endpointSelector:
    matchExpressions:
    - { key: k8s:io.kubernetes.pod.namespace, operator: Exists }
  egress:
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - { port: "53", protocol: UDP }
      - { port: "53", protocol: TCP }
---
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata: { name: coredns-upstream }
spec:
  enableDefaultDeny: { ingress: false, egress: false }
  endpointSelector:
    matchLabels:
      k8s:io.kubernetes.pod.namespace: kube-system
      k8s-app: kube-dns
  egress:
  - toCIDR: [ "1.1.1.1/32", "8.8.8.8/32" ]
    toPorts:
    - ports:
      - { port: "53", protocol: UDP }
```

**Don't apply to dealing yet** — write it as a doc/PR first. The CCNPs you
already have probably cover this; the point is the authoring exercise.

### Lab 3 — Author CCNP #2: Restrict argocd egress (~2.5 hours)

**Requirement**: argocd-server should only be able to:
- Reach the K8s API
- Reach DNS (already covered by Lab 2)
- Reach GitHub, GitLab on 443 (for repository pulls)
- NOT reach arbitrary internet

This is a per-app CNP (since argocd lives in the `argocd` namespace), not
a CCNP. The right tool:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: argocd-server-egress, namespace: argocd }
spec:
  enableDefaultDeny: { egress: true }
  endpointSelector:
    matchLabels: { app.kubernetes.io/name: argocd-server }
  egress:
  # K8s API
  - toEntities: [kube-apiserver]
  # DNS (CoreDNS)
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts: [{ ports: [{ port: "53", protocol: UDP }] }]
  # GitHub/GitLab
  - toFQDNs:
    - { matchName: github.com }
    - { matchName: api.github.com }
    - { matchPattern: "*.gitlab.com" }
    toPorts: [{ ports: [{ port: "443", protocol: TCP }] }]
```

This requires the Cilium DNS proxy to be enabled. Check:
```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg config | grep -i dns
# Look for: EnableLocalRedirectPolicy + EnableDNSProxyResolution
```

### Lab 4 — Author CCNP #3: Allow Prometheus to scrape (~1.5 hours)

**Requirement**: Prometheus pod in monitoring namespace should be able to
scrape metrics on any pod's `/metrics` endpoint, on any port labeled with
`prometheus.io/scrape=true`.

Since "any pod" is the dest, this is a cluster-wide policy:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata: { name: prometheus-scrape-all }
spec:
  enableDefaultDeny: { ingress: false, egress: false }
  endpointSelector:
    matchExpressions:
    - { key: k8s:io.kubernetes.pod.namespace, operator: Exists }
  ingress:
  - fromEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: monitoring
        app.kubernetes.io/name: prometheus
```

Note: this allows ALL ports because we don't restrict toPorts. In production
you'd restrict to common metrics ports (9090, 8080, etc.). Trade-off:
flexibility vs precision.

### Lab 5 — Dry-run via Cilium Audit Mode (~2 hours)

Before applying any new CCNP to production-shape dealing, use **audit mode**
to see what WOULD be denied without actually denying:

```yaml
metadata:
  annotations:
    io.cilium/policy-mode: audit
```

When you enable audit on a policy, drops become "AUDIT" events instead of
actual drops. Watch:
```bash
hubble observe --verdict AUDIT --last 100
```

This is how you safely roll out a new default-deny policy in production —
deploy in audit mode, observe what would break, fix gaps, then flip to enforce.

### Lab 6 — Cilium Service Mesh mTLS (~2 hours)

Enable mTLS in your Cilium config (this is a cluster-wide setting):
```bash
kubectl -n kube-system get cm cilium-config -o yaml | grep -i mesh
```

If not already enabled (dealing might not have it on):
```yaml
# Helm values
authentication:
  enabled: true
  mTLS: { enabled: true }
```

Don't enable on dealing without a backup plan. Instead: spin up a kind cluster
with Cilium and try mTLS there.

Define an authentication requirement on a CNP:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: mtls-required }
spec:
  endpointSelector: { matchLabels: { app: secure-backend } }
  ingress:
  - fromEndpoints: [{ matchLabels: { app: trusted-frontend } }]
    authentication: { mode: required }
```

Test from an unauthenticated pod → blocked. From the authenticated frontend →
allowed. Hubble shows `auth=success` or `auth=failure`.

### Lab 7 — Traffic shifting with HTTPRoute weights (~1 hour)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: canary, namespace: default }
spec:
  parentRefs: [{ name: lab-gateway }]
  hostnames: [ canary.dealing.local ]
  rules:
  - backendRefs:
    - { name: app-v1, port: 80, weight: 90 }
    - { name: app-v2, port: 80, weight: 10 }
```

`for i in {1..100}; do curl -s http://canary.dealing.local/version; done | sort | uniq -c`

Should show ~90 v1 hits and ~10 v2 hits.

### Lab 8 — Clean up + writeup (~1 hour)

Roll back any test policies. Write a 1-page summary:
- Your 3 CCNP drafts (with rationale per rule)
- The audit-mode workflow you'd recommend for prod rollout
- One-paragraph evaluation: does dealing's CCNP set need additions/changes?

This feeds the Week 8 blog post.

---

## Part 3 — Saturday review checkpoint

1. **Audit mode — when in a policy rollout do you transition from audit to
   enforce? What signals tell you it's safe?**
2. **You write a CCNP with `toFQDNs: [matchName: stripe.com]`. The
   connection still fails. List 4 possible reasons.** (DNS proxy not enabled;
   no DNS rule allowing CoreDNS; HTTP/443 not allowed in toPorts; cert
   pinning in the app.)
3. **Cilium SM mTLS vs Istio mTLS — give 3 architectural differences.**
4. **HTTPRoute weight 90/10 splits traffic. How does Cilium implement that
   in the datapath?** (Answer: Envoy weighted clusters; each request picks
   a backend by weighted random.)
5. **A new namespace gets created in dealing. By default, what can pods
   in it reach? What's blocked?** (Tests your mental model of the layered
   policy.)

Bring: 3 CCNP drafts, hubble audit-mode screenshot, traffic-split test result.

---

## Resources

- [Cilium CCNP docs](https://docs.cilium.io/en/stable/security/policy/)
- [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/)
- [Gateway API traffic splitting](https://gateway-api.sigs.k8s.io/guides/traffic-splitting/)
- [SPIFFE identity model](https://spiffe.io/docs/)

---

## What's next: Week 8 — Multi-cluster, WireGuard internals, first blog post

Wrapping Month 2. ClusterMesh basics, WireGuard internals (what's encrypted
on dealing today), and your first public blog post: "Cilium eBPF vs iptables
in production — observations from a 6-node cluster."
