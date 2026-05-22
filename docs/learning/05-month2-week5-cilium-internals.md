# Month 2, Week 5 — Cilium internals (BPF, identity, ipcache, policy maps)

> Most "Cilium users" treat it as a CNI black box. This week you open the
> hood. By end of week you can debug a Cilium policy drop from BPF maps
> directly — not from logs or Hubble.

## Goal for the week

By Saturday, you can:
- Explain what eBPF is and why it underpins Cilium
- Read every BPF map that matters: ipcache, identity, policy maps, lb, ct, nat
- Trace a packet from pod → veth → BPF program → datapath decision
- Look up an endpoint's identity, find which CCNPs apply, predict policy verdict
- Use `cilium-dbg` like you've been doing it for 2 years

## Time breakdown

- Theory: ~3 hours (heavier this week — concepts are dense)
- Lab on dealing cluster: ~10 hours
- Buffer: ~2 hours

---

## Part 1 — Theory

### 1.1 What eBPF actually is

eBPF = "extended Berkeley Packet Filter." Forget the name. What it is:

> A sandboxed VM inside the Linux kernel that runs small programs, attached
> to specific kernel hooks, with safety guarantees.

The hooks Cilium uses:
- **XDP** (eXpress Data Path) — runs at NIC driver level, before sk_buff is allocated. Fastest. Used for DDoS dropping, L4 LB.
- **TC** (Traffic Control) — runs on every packet entering or leaving an interface. Cilium's main hook for pod traffic.
- **Socket hooks** — `sock_ops`, `sock_msg`. Used for socket-level redirection (bypassing TCP/IP for same-node pod-to-pod).
- **Kprobes / tracepoints** — used by Hubble for observability.

A BPF program:
- Is C compiled to BPF bytecode by clang/llvm
- Verified by the kernel verifier (no unbounded loops, no out-of-bounds reads, etc.)
- JIT-compiled to native instructions
- Cannot crash the kernel
- Cannot block (limited stack, limited instructions)

**BPF maps** are key-value stores that BPF programs use to share state
between themselves AND with userspace. Cilium has dozens of them — each
encodes a different chunk of policy/datapath state.

### 1.2 Cilium identity model

This is THE concept that breaks the iptables analogy in your head. Read
this section twice.

**The problem with iptables-based policy:** rules reference IPs. Pod IPs
change. So policies based on IPs are constantly being rewritten as pods
spin up and down. At scale this thrashes badly.

**Cilium's solution:** every pod gets a numeric **identity** derived from
its labels. Identity is hashed from the label set:
- `{app=postgres, env=prod, ns=database}` → identity 23847
- All pods with that exact label set share that identity

Policy is enforced on **identity**, not IP. So when you write a CCNP saying
"identity 23847 can talk to identity 19283," the rule is stable forever
even as the underlying pod IPs change.

**Where identity is allocated:**
- For pods in the cluster: by the local Cilium agent, stored in etcd (or
  CRD-backed if you're on KVStore-less mode)
- For pods in other clusters (ClusterMesh): pulled from remote etcd
- For external endpoints (e.g., `8.8.8.8`): "world" identity (`ReservedIdentityWorld`)
- For host: `ReservedIdentityHost`
- For "everything in CIDR X": numeric, allocated via CIDR ranges in policy

**Reserved identities** (always present):
```
1   host        — the node itself
2   world       — anything outside the cluster
3   unmanaged   — pods Cilium hasn't seen
4   health      — Cilium health endpoints
5   init        — pods still booting
6   remote-node — other nodes in the cluster
7   kube-apiserver — the K8s API server endpoint
8   ingress     — Cilium's IngressController identity (the footgun)
```

The number `8` is the one that broke your dealing cluster's argocd Ingress.
A CCNP with `endpointSelector: {}` matches `ingress` identity, which forces
Envoy into the default-deny path.

### 1.3 The 5 BPF maps you actually need to know

Cilium has ~40 BPF maps. These 5 are the ones you'll look at when debugging:

| Map | Purpose | View with |
|---|---|---|
| **ipcache** | IP → identity mapping. Tells the datapath "this packet's source IP has identity X" | `cilium-dbg map get cilium_ipcache` |
| **policy** | Per-endpoint policy. For endpoint X, what identities can talk in/out and on which L4 ports | `cilium-dbg endpoint get <id>` |
| **identity** | Identity number → label set | `cilium-dbg identity list` |
| **lb** | Service VIP → backend pod IPs (kube-proxy replacement) | `cilium-dbg service list` |
| **ct** | Conntrack table — flow state | `cilium-dbg bpf ct list global` |

Hidden but worth knowing:
- **nat** — NAT entries for masquerading
- **lxc** — endpoint metadata (per pod)
- **encrypt** — WireGuard keys per peer
- **hubble** — Hubble's event ring buffer

### 1.4 Datapath: tracing a packet

A packet from pod A to pod B on the same node:

```
1. Pod A's namespace stack → veth pair → host network namespace
                              │
                              ▼
2. TC ingress hook on host side of veth fires bpf_lxc.o
                              │
                              ▼
3. bpf_lxc.o:
   - Look up source endpoint (Pod A) from lxc map
   - Look up dest IP in ipcache → dest identity
   - Look up policy map for Pod A: is (dest identity, L4 port) allowed?
   - If allowed: rewrite, update conntrack, redirect to dest veth's host side
   - If denied: drop, emit Hubble event
                              │
                              ▼
4. Packet now on Pod B's veth host side
                              │
                              ▼
5. TC egress on Pod B's veth host side → Pod B's namespace stack
```

The whole thing happens in BPF, in the kernel, without leaving the network stack.

Cross-node: same path but with WireGuard encap between step 3 and 4 if
encryption is enabled (which it is on dealing).

### 1.5 Policy evaluation order

When a CCNP / CNP exists, here's how Cilium decides "allow or drop":

1. Look up source endpoint's identity (from `lxc` map / `ipcache`)
2. Look up dest endpoint's identity
3. Consult source endpoint's policy map (for egress) — is dest identity allowed on this L4 port?
4. Consult dest endpoint's policy map (for ingress) — is source identity allowed on this L4 port?
5. If both allow → forward. If either denies → drop, emit Hubble verdict.

**Important:** Cilium policies are additive (`enableDefaultDeny: false`)
OR default-deny (`enableDefaultDeny: true`). The mode depends on what
selectors match an endpoint.

- If NO policy selects an endpoint → policy is "no-op," all traffic allowed
  (default-allow).
- If ANY policy with `enableDefaultDeny: true` selects an endpoint → default-deny
  for that direction, only explicit allows pass.
- If only policies with `enableDefaultDeny: false` select → additive, all
  default-allow PLUS the policies grant extra explicit allows (which are
  redundant since default is allow — so additive mode is mainly a NO-OP
  unless other policies turn on default-deny).

This is exactly the `endpointSelector: {}` footgun in your dealing cluster:
- The CCNP selected every endpoint (including `ingress` identity)
- Even though `enableDefaultDeny: false`, the policy still applied
- For the `ingress` identity specifically, the default-deny was already
  triggered by SOMETHING in the Cilium internals when it saw Envoy traffic,
  and the additive policy didn't include the ingress→argocd path

The fix (matchExpressions with `pod.namespace Exists`) excluded `ingress`
identity from the selector, leaving Envoy on default-allow.

### 1.6 Cilium agent vs operator vs envoy

Three components, three jobs:

| Component | Where | Job |
|---|---|---|
| **cilium-agent** | DaemonSet, one per node | Manages BPF programs/maps on the node, talks to local kubelet, allocates pod IPs, enforces policy locally |
| **cilium-operator** | Deployment, one cluster-wide leader | Manages cluster-scoped things: identity GC, IPAM (in some modes), cluster-mesh, CRD lifecycle |
| **cilium-envoy** | DaemonSet (in 1.14+), one per node | L7 proxy used for L7 policy, Ingress, Gateway API |

A bug in agent → policies break on that node only.
A bug in operator → identity allocation freezes cluster-wide.
A bug in envoy → L7 Ingress/policy breaks.

Knowing which to look at first is debugging muscle memory.

---

## Part 2 — Lab on the dealing cluster

You're not building from scratch this week — you're exploring the cluster
you already operate. Read-only by default. Take notes for the blog post in
Week 8.

### Lab 1 — Map the cluster's identities (~2 hours)

SSH to a master node. Get into a cilium-agent pod:

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg status

# List all identities the cluster knows
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg identity list | head -50
```

Look at the output. Find:
- The reserved identities (1-8)
- Identity for argocd pods
- Identity for prometheus pods
- Identity for a workload pod you deployed

Write down in a doc:
- 5 example identities, their labels, their numeric ID
- Notice: do identical pods on different nodes share an identity? (Yes.)

### Lab 2 — Trace a real connection (~2 hours)

Pick a real connection that flows on the cluster, e.g., a prometheus scrape
to a cilium-agent metrics endpoint.

```bash
# What's the source pod
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus -o wide

# What's the dest endpoint
kubectl -n kube-system get pods -l k8s-app=cilium -o wide

# Pick one of each. Note their IPs and node.

# On the source node's cilium agent
SRC_NODE=node-where-prometheus-runs
kubectl -n kube-system exec -it $(kubectl -n kube-system get pod -l k8s-app=cilium -o name --field-selector=spec.nodeName=$SRC_NODE | head -1) -- cilium-dbg monitor --type=trace | grep <prom-pod-ip>
```

You'll see TRACE events for each packet, including:
- Source identity, dest identity
- L4 port
- Verdict (FORWARDED / DROPPED)

### Lab 3 — Read the ipcache map (~1 hour)

```bash
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg map get cilium_ipcache | head -30
```

Output is keyed by IP, values are identity + flags. Verify:
- Pick a pod IP from `kubectl get pods -A -o wide`
- Find its entry in the ipcache
- Cross-check the identity matches `kubectl exec ds/cilium -- cilium-dbg identity get <id>`

### Lab 4 — Read an endpoint's policy map (~1 hour)

```bash
# List endpoints on this node
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg endpoint list

# Pick an interesting one (e.g., argocd-server)
ENDPOINT_ID=12345
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg endpoint get $ENDPOINT_ID

# Get the full policy
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg endpoint config $ENDPOINT_ID
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg bpf policy get $ENDPOINT_ID
```

The output shows:
- Which CCNPs and CNPs select this endpoint
- For each direction (ingress, egress), which identities + L4 ports are allowed

Cross-reference with what you'd expect from your platform-baseline CCNP.

### Lab 5 — Verify the L2 announcements policy (~1 hour)

Cilium L2 announcement is how dealing exposes services without MetalLB.

```bash
# Look at the L2 announce config
kubectl get ciliuml2announcementpolicy -A

# See which IPs are being announced and from which node
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg bpf lb list
```

Pick a Service IP from your CCNP that's L2-announced. Trace:
- Which node currently owns the announcement (cilium-agent leader election)
- The MAC address used for ARP replies (matches the node's MAC)

### Lab 6 — Trigger and observe a policy drop (~1.5 hours)

Carefully (read-only goal preserved): deploy a test pod in `default` namespace
that you know your platform-baseline CCNP doesn't grant special access to:

```bash
kubectl run test-drop --image=busybox --restart=Never --rm -i -- sh
```

Inside, try to hit something you expect to be blocked, e.g., the kube-apiserver
on a port other than 6443:

```bash
nc -vz 10.10.120.138 22  # SSH port — should be blocked
```

In another terminal, watch hubble:
```bash
hubble observe --pod default/test-drop --verdict DROPPED --last 10
```

You should see a DROPPED verdict with the policy that caused it.

### Lab 7 — Inspect Hubble flows for a real bug (~1 hour)

Find a real (non-test) drop in the cluster:

```bash
hubble observe --verdict DROPPED --last 500 | head -30
```

Pick one. Write up in your notes:
- Source / dest pod
- L4 port
- Which policy caused the drop
- Is this drop expected (good — policy is doing its job) or unexpected (bug)?

### Lab 8 — Documentation pass (~1.5 hours)

Write a 1-page summary of the cluster's policy posture, drawn from what you
just observed:
- Identities in use (with examples)
- The default-allow / default-deny choices on each layer
- One example flow you traced end-to-end

This is the seed of your Month 2 Week 8 blog post.

---

## Part 3 — Saturday review checkpoint

1. **An interviewer asks: "How is Cilium policy different from iptables-based
   policy?" Answer in 60 seconds.**
2. **You see a Hubble drop verdict on pod A → pod B, port 5432. You suspect
   a misconfigured CCNP. Walk through how you'd debug from BPF maps alone
   (no logs, no Hubble UI).**
3. **Identity 8 (`ingress`). When does Cilium assign this identity? Why
   did `endpointSelector: {}` on a CCNP break ingress-to-argocd?**
4. **`cilium-dbg endpoint config <id>` shows `Conntrack: enabled` and
   `Policy: enabled (ingress + egress)`. What does that combination tell
   you about the policy verdict path for packets to this endpoint?**
5. **Your operator pod crashes. What stops working in the cluster? What
   keeps working?**

Bring: your 1-page cluster posture writeup, your trace notes from Lab 2,
your blog-post outline draft.

---

## Resources

- [Cilium docs: BPF and XDP Reference Guide](https://docs.cilium.io/en/stable/bpf/)
- [Cilium docs: Concepts](https://docs.cilium.io/en/stable/overview/component-overview/)
- [Liz Rice — "Learning eBPF" book](https://www.oreilly.com/library/view/learning-ebpf/9781098135119/) (the best single resource)
- `cilium-dbg --help` — your new best friend

---

## What's next: Week 6 — Cilium IngressController, Gateway API, L7

You've seen the L3/L4 datapath. Week 6 goes up the stack: Cilium's L7 proxy
(Envoy), Gateway API, L7 policy, HTTP routing, L7 metrics in Hubble.
