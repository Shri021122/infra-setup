# Month 4, Week 14 — 1st-round interviews + system design ramp

> Real interviews now. You'll likely have 3-5 first-rounds this week.
> Focus shifts to performing under fire + sharpening system design.

## Goal for the week

By Saturday:
- 30 total applications (10 more added)
- 3-5 first-round interviews completed
- 4 system design reps (45 min each)
- Application tracker updated with stage data
- 1 callback for 2nd round

## Time breakdown

- Interviews: ~5 hours (live)
- Post-interview debrief + study: ~3 hours
- System design: ~3 hours
- Apps + recruiter follow-up: ~2 hours
- Coding warmup: ~2 hours

---

## Part 1 — Preparing for first rounds

A first round (hiring manager or tech lead) usually goes:
- 5 min intro from both sides
- 20-25 min Q&A about your background + projects
- 10-15 min technical exploration
- 5-10 min questions from you to them

### Your 2-minute self-pitch (refined)

> "I'm <name>, currently a <role> at <company>. The work I'm proudest of
> recently is <one specific thing — make it the operator OR the cluster
> migration>. Before that I was doing <prior role>. I'm exploring this
> role because <specific reason — match the JD>."

Practice this 5 times this week. Crisp. Specific.

### Questions you'll get repeatedly

| Question | Strong answer pattern |
|---|---|
| Walk me through your cluster | Architecture diagram in your head; 60-second tour |
| Why are you leaving? | Pull (forward-looking), not push ("I want X" not "I hate Y") |
| What's a hard problem you solved? | The endpointSelector incident OR the operator decision |
| What's your weakness? | Real, specific, with mitigation (not "I work too hard") |
| Why us specifically? | Show research — read their blog, mention specifics |
| Salary expectations? | "55-70 LPA total" + flexibility on the split |

### Questions to ask THEM

End every interview with thoughtful questions. Bad: "What's the culture?"
Good (specific, gives signal):

- "What's the team's biggest technical challenge this quarter?"
- "What does production look like — what kind of K8s setup, what scale?"
- "If I joined, what would the first 90 days look like?"
- "How do you handle on-call?" (real signal of team maturity)
- "What's a recent decision the team made that you wish you'd made differently?"

The last one is gold — it tests honesty and shows you think about real
engineering culture.

---

## Part 2 — System design — 4 reps this week

Hit these prompts. Self-time 45-60 min. Record (audio at minimum).

### Prompt 1 — Multi-region K8s platform (Razorpay/PhonePe-style)

**Requirements:**
- 1000s of internal tenants, each gets a namespace
- Active-active across 2 AWS regions
- 99.99% SLO on tenant API availability
- ~10k req/sec total, peaks 50k

**Sketch outline:**
- Edge: Route53 + CloudFront → ALB per region
- Region: EKS cluster, Karpenter, AWS LB Controller
- Cross-region: ClusterMesh OR Aurora Global / Cassandra for state
- Tenant isolation: namespace + CCNP + ResourceQuota + LimitRange
- Observability: per-region Prometheus → central Mimir
- Failover: Route53 health checks; primary/secondary; failback playbook

### Prompt 2 — Kubernetes-native CI/CD for 500 services

**Requirements:**
- 50 teams, 500 services, 20 deploys/day each
- Image scanning, secrets, multi-env (dev/staging/prod) per service
- Rollback in <5 min

**Sketch outline:**
- GitOps: ArgoCD with ApplicationSets per team
- Image registry: ECR; scanning via Trivy or AWS Inspector
- Secrets: external-secrets pulling from AWS Secrets Manager
- Multi-env: Kustomize overlays per env; ArgoCD ApplicationSet generators
- Rollback: ArgoCD revision history + auto-rollback hook
- Audit: GitHub PR + ArgoCD audit log

### Prompt 3 — Observability for 100 clusters

**Requirements:**
- 100 K8s clusters (regional)
- 100k pods total, ~1M time series per cluster = 100M total
- 30-day raw + 1-year downsampled retention
- Single Grafana for SREs

**Sketch outline:**
- Local Prometheus per cluster (kube-prometheus-stack) → remote_write to central Mimir
- Mimir: sharded by tenant_id (cluster_id); ingester replicas; long-term store on S3
- Logs: Loki, similar tiering
- Single Grafana with data source = Mimir + Loki
- Cardinality control: relabel_configs drop high-cardinality labels at scrape time
- Cost: ~$50k/month at this scale, mostly S3 + compute

### Prompt 4 — Pick your stretch goal

Choose: design a service mesh from scratch, or a multi-tenant K8s
operator, or whatever feels weakest from prior reps.

After each session:
- Did you clarify before drawing? (yes/no)
- Did you do back-of-envelope math? (yes/no)
- Did you cover edge / data / async / observability / failure? (which did you miss?)
- Did you stop and explain trade-offs at decision points?

Grade yourself 1-10. Note 3 specific gaps to study.

---

## Part 3 — Debrief discipline

After every real interview, within 24h:
- Write down 5 questions they asked + how well you answered each (1-5)
- Note the technical topics that came up; rank by your confidence
- Capture any topics you fumbled — study them THIS WEEK
- Did the interviewer signal interest? (Specific follow-ups? Engaged body
  language? "Looking forward to next round"?)

This isn't masochism — it's data. Patterns emerge after 5+ interviews:
"Every interviewer asks about Cilium identity model and I always do well
there" vs "Every interviewer asks about HPA tuning and I always fumble."
Tune your study time accordingly.

---

## Part 4 — Topping up applications

Apply to 10 more, focused on:
- Companies that responded fast to round 1 (signal of healthy hiring funnel)
- Tier 1-2 (don't dilute time on lower tiers unless you have 0 traction)
- Roles where the JD matches your story well (don't apply to "DevOps Engineer
  with 8 years TerraFOrm experience" if you've got 3)

Update LinkedIn weekly with small things:
- Engagement on others' posts (comment thoughtfully, weekly)
- 1 short post: "Just shipped X on my operator" or "Spent the weekend
  exploring Y" — signals activity to recruiters

---

## Saturday review checkpoint

Bring:
- Interview debrief notes for each round you did
- 4 system design sketches + self-grades
- Updated application tracker (~30 entries, with stages)
- 1 thing you're stuck on (technical OR mental)

We'll work the stuck thing together.

---

## What's next: Week 15 — 2nd-round interviews + technical deep-dives

By now you should have 2-3 candidates moving to round 2 (deeper technical
or coding rounds). Week 15 is preparing for and executing those.
