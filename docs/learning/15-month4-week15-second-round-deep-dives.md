# Month 4, Week 15 — 2nd round interviews + technical deep-dives

> Round 2 is where most candidates wash out. Deep technical interrogation
> on K8s/AWS/Cilium. This week we drill the topics interviewers love.

## Goal for the week

By Saturday:
- 2-3 second-round interviews completed
- Deep review of: K8s networking, scheduler, etcd, Cilium internals, EKS-isms
- 2 more system design reps
- Status: at least 1 candidate moving toward final rounds

## Time breakdown

- Interviews: ~5 hours live
- Deep-dive study: ~5 hours
- System design: ~2 hours
- Buffer / debrief / portfolio updates: ~3 hours

---

## Part 1 — The technical deep-dive structure

Second/third round usually goes:
- 5 min warmup
- 25-35 min: "Walk me through your project / cluster" then drilling down
  with "Why X?" "How did you decide?" "What if Y instead?"
- 15-20 min: rapid-fire on K8s/AWS knowledge
- 5-10 min: your questions

The interviewers WANT to find the edge of your knowledge. They'll keep
asking deeper until you say "I don't know." Get comfortable saying that
honestly — pretending kills you faster.

---

## Part 2 — Topics to drill this week

### 2.1 K8s scheduler internals (~1.5 hours)

Read [the scheduling framework docs](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/).
Know:
- The scheduling cycle: filter → score → bind
- Pre-filter plugins: NodeAffinity, PodTopologySpread, InterPodAffinity
- Score plugins: NodeResourcesFit, ImageLocality, NodeAffinity
- Bind plugin: writes the binding to apiserver

**Likely questions:**
- "How does the scheduler pick a node?"
- "A pod is Pending. How do you debug?"
- "I want to spread pods across AZs. How?" (topologySpreadConstraints)
- "I want to co-locate two pods. How?" (podAffinity)
- "I want to AVOID co-locating two pods. How?" (podAntiAffinity)

### 2.2 etcd (~1 hour)

The K8s state store. Know:
- Raft consensus — leader/followers, quorum needed for writes
- Watch streams — how informers get notified
- Compaction — why etcd needs it, what happens if it stops
- Backup/restore — etcdctl snapshot save/restore

**Likely questions:**
- "What if etcd is slow?"  (Latency on apiserver, slow apply across cluster)
- "How big can etcd get?" (~8GB practical; quota)
- "How do you back up etcd?" (snapshot + offsite copy)
- "Leader election in K8s controllers — how does it work?" (Lease objects in
  coordination.k8s.io, with TTL renewals)

### 2.3 K8s networking — the full path (~1.5 hours)

A request from `kubectl exec -it pod-a -- curl http://service-b/`:
1. DNS lookup for `service-b` — pod's `/etc/resolv.conf` points to CoreDNS ClusterIP
2. CoreDNS returns the Service ClusterIP
3. Pod sends packet to ClusterIP
4. kube-proxy (or Cilium kpr) rewrites dest IP to a backend pod IP (DNAT)
5. Routing — same-node bridges/veth, or cross-node tunnels (VXLAN, WireGuard, native)
6. Receiving pod's veth → namespace → process

Each step is interview-able. Know:
- kube-proxy iptables vs IPVS vs Cilium's BPF replacement (you've done the deep dive)
- ClusterIP vs NodePort vs LoadBalancer vs ExternalName vs headless
- DNS hostsAliases, ndots, search paths

### 2.4 Cilium-specific (you did this in Month 2, refresh) (~1 hour)

Speed-review:
- Identity allocation (hash of labels, reserved identities)
- Policy maps (per-endpoint, BPF)
- IPCache (IP → identity)
- Datapath modes: kpr, direct routing vs encap, encryption (WireGuard)
- Hubble for observability

Have one specific incident story queued up. "Once we had …" — the
endpointSelector:{} story works perfectly.

### 2.5 EKS-isms (~1 hour)

Know cold:
- IRSA — full flow (you did this Week 3)
- VPC-CNI — pod IPs are VPC IPs, ENI limits, prefix delegation
- Why EKS is more expensive ($0.10/hr) than self-managed
- Karpenter vs Cluster Autoscaler vs Fargate
- AWS LB Controller — Ingress → ALB, Service → NLB
- EKS upgrade — control plane vs node group, blue/green strategy

**Likely questions:**
- "How do you upgrade an EKS cluster?"
- "Pods are crashing with no IP. What's wrong?" (VPC-CNI out of ENIs; need prefix delegation or smaller pod density)
- "How do you authenticate kubectl to EKS?" (aws-iam-authenticator OR aws eks update-kubeconfig + IAM identity → K8s identity via aws-auth ConfigMap, or AccessEntries in newer EKS)

### 2.6 The Linux foundation (~1 hour)

Don't forget the substrate. Know:
- cgroups v1 vs v2 (K8s 1.25+ defaults to v2)
- namespaces: pid, net, mnt, ipc, uts, user, cgroup
- How a container is "just" a process with namespaces + cgroups + (sometimes) seccomp
- OOM killer — what does the K8s "OOMKilled" state really mean?
- Disk pressure → kubelet evicts pods (which ones first?)

---

## Part 3 — Two more system design reps

Pick the prompts that scared you most last week. Redo them. Aim for
improvement on:
- Faster clarification phase
- Specific numbers (not just "lots of users")
- Layered architecture (always cover: client → CDN → LB → app → cache → DB → async → obs)
- Naming trade-offs you considered

---

## Part 4 — Don't get stuck on one company

Some candidates fixate on a top choice and let other processes drag.
Don't. Keep 5+ companies active:
- Push slow processes (politely): "Wanted to check in — any update on
  scheduling round 2?"
- If a company goes silent for >5 days, assume dead, move on
- If you get an offer, use it as leverage with others ("I have an offer
  deadline of X; can we accelerate?")

## Part 5 — Negotiation prep

If a final round is close, prepare:
- Your floor (walk-away number) — keep this private
- Your target — what you'd accept comfortably
- Your stretch — what you'd push for
- Non-cash levers: joining bonus, ESOP refresher, faster vesting, WFH,
  start date, role title (Senior vs Staff)

Practice saying "That's lower than I was expecting. I was looking at X
range, given the role and my experience" — without filler words. The
silence after is where the company moves up.

---

## Saturday review checkpoint

Bring:
- Interview tracker — what stage each company is at
- 1 hardest technical question this week and how you answered
- 2 system design improvements vs last week
- 1 thing that's not working (process, technical, mental)

We'll work the stuck thing.

---

## What's next: Week 16 — Final rounds + more apps

By Week 16 you should have 1-2 companies in final round. Time to convert
to offers and keep options open.
