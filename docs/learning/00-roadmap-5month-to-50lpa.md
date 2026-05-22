# Roadmap: 5-month sprint to 50 LPA Kubernetes Expert (AWS-focused)

> The master plan. Read this once, then keep going back to it each Monday to
> remember what week you're in. Updated as we progress.

## The goal

Land a **50 LPA total comp** K8s / SRE / Platform Engineer role at an Indian
fintech / SaaS / FAANG-India company (Razorpay / Swiggy / PhonePe / Cred /
Zerodha / Atlassian-India / Browserstack / Postman / FAANG India) within
**5 months** of the start date.

## Your starting position

- **Time budget:** 15 hours/week, sustained for 5 months = 300 hours
- **Day job:** already operating Kubernetes clusters daily (huge advantage)
- **Existing assets:** the `dealing` cluster as a living lab + portfolio piece
- **Level:** intermediate — past beginner foundations, ready for depth
- **Lab environment:** own laptop + AWS account
- **Goal market:** Indian, with bias to AWS-shop employers

## The 5-month plan (revised: certs at the end)

| Month | Theme | Why this slot | Output |
|---|---|---|---|
| **1** | AWS + EKS Mastery | Pure-K8s engineers cap at ~35 LPA. EKS unlocks the 50 LPA band. Foundation everything else builds on. | Working EKS cluster via Terraform, IRSA, ALB controller, EBS CSI, Karpenter |
| **2** | Cilium/eBPF deep dive + advanced K8s | Specialization. Uses dealing as the lab — no time wasted rebuilding what exists. Cilium expertise transfers to EKS (more shops adopt it). | 1st blog post; CCNP authoring fluency; service-mesh basics |
| **3** | Go + Kubernetes operator + portfolio | The separator between "ops engineer" and "platform engineer." Writing Go is the muscle that pushes you across the 50 LPA threshold. | Open-source operator on GitHub; 2nd blog post; polished LinkedIn |
| **4** | Active interview cycle | Maximum applications + interviewing. System design practice weekly. Don't wait — start at Week 1 of Month 4. | 30-50 applications, 5-10 mock interviews, 5-10 real interview cycles in flight |
| **5** | CKA + CKS + close offer | Certs as validation while you're closing offers. Demonstrates active learning during interview process. Strong negotiation lever. | CKA pass, CKS pass (or in progress), 1-2 offers, signed |

### Why CKA/CKS are deferred to Month 5 (your choice)

You chose to defer certs to last. The honest trade-off:

**Pros of this ordering:**
- You spend Months 2-3 building real skills, not memorizing cert curricula
- You go into interviews with portfolio (operator + blog posts + dealing migration story), not just paper
- Some hiring managers prefer "shipping" candidates over "credentialed" ones
- You compress cert grinding into 4-6 weeks of focused study, when interviewing is forcing you to know the material anyway

**Cons of this ordering:**
- Recruiters who filter on "CKA required" will pre-screen you out of ~15-20% of postings
- You can't say "CKA certified" during the Month 4 interview rounds
- Some MNCs make CKA a hard requirement and won't budge

**Mitigation:**
- During Month 4 interviews: tell recruiters you're scheduled for CKA in Month 5. Many will hold the process for it.
- Lead with the operator + blog posts + dealing cluster work in your pitch. The portfolio compensates.
- For companies that hard-require CKA upfront, reapply after Month 5.

If you change your mind mid-stream, we can shuffle — taking CKA in Month 3
instead is a 2-week swap.

---

## Hours breakdown — what 15 hrs/week looks like

| Slot | Hours | Type |
|---|---|---|
| Weeknights (Mon-Fri, ~1 hr/day) | 5 | Reading the week's explainer; light lab work |
| Saturday | 5-6 | Heavy lab work, hands-on labs, exam practice |
| Sunday | 4-5 | Review session with me; portfolio work; blog drafting |
| **Total** | **15** | |

Burn-out signal: if you find yourself missing 3+ days in a row, slow the pace
(drop to 10 hrs/week, extend to 7 months). Better than crashing out at month 3.

---

## Month-by-month: detailed breakdown

### Month 1 — AWS + EKS Mastery (60 hrs)

Goal: **Operate EKS like you operate dealing today.** Everything that's
different about EKS vs RKE2 — VPC-CNI, IRSA, ALB controller, EBS CSI,
Karpenter, IAM-everywhere — fluent by end of month.

| Week | Focus | Hands-on output |
|---|---|---|
| 1 | AWS networking + IAM | K8s-ready VPC built by hand via console then Terraform |
| 2 | EC2 + ALB + Route53 + ACM | Multi-AZ web app with ALB + TLS via ACM |
| 3 | EKS cluster setup (Terraform) + IRSA | EKS cluster deployed, sample app uses IRSA to read S3 |
| 4 | EKS production patterns | Karpenter autoscaling, ALB Ingress Controller, EBS CSI for stateful workload |

**Cost:** ~$50-100 in AWS (free tier covers most of week 1; EKS itself is
$0.10/hour control plane = ~$73/month + node costs; destroy nightly).

**End-of-month checkpoint:** You can describe end-to-end how a pod in EKS
gets AWS S3 credentials, how an Ingress provisions an ALB, and how a PVC
gets an EBS volume. Without notes.

### Month 2 — Cilium/eBPF deep dive + advanced K8s (60 hrs)

Goal: **The specialization that anchors your interview pitch.** Cilium is
the differentiator. By end of month, you can talk about BPF maps, identities,
the Cilium datapath, and L7 policy as if you wrote them.

| Week | Focus | Hands-on output |
|---|---|---|
| 1 | Cilium internals (BPF, identity, ipcache, policy maps) | Read all BPF maps on dealing using `cilium-dbg`; document the cluster's identity allocation |
| 2 | Cilium IngressController + Gateway API + L7 | Add an HTTPRoute to dealing; capture L7 metrics in Hubble |
| 3 | CCNP authoring + service mesh | Write 3 production-grade CCNPs for dealing; explore Cilium Service Mesh basics |
| 4 | Multi-cluster (ClusterMesh) + WireGuard internals + 1st blog post | Local Cilium cluster pair with ClusterMesh; publish "Cilium eBPF vs iptables in production" on dev.to |

**End-of-month checkpoint:** You can debug a Cilium connectivity issue with
zero references in <15 minutes. You have a public blog post Hiring Managers
can find.

### Month 3 — Go + Operator + Portfolio + start applying (60 hrs)

Goal: **Ship code, ship visibility, start applying.** Go separates you from
generic ops; operator separates you from generic platform engineer; blog
posts make you findable.

| Week | Focus | Hands-on output |
|---|---|---|
| 1 | Go fundamentals | "Tour of Go" + "Effective Go". Write 3 small CLI tools. |
| 2 | Kubebuilder + first operator | Scaffold an operator that automates something in dealing (e.g., cert-rotation reminder, namespace template) |
| 3 | Finish operator + open-source + 2nd blog post | Publish operator to GitHub with README + examples; blog "Building a K8s operator in Go: lessons" |
| 4 | LinkedIn + resume polish + start applying | Profile updated; first 10 applications submitted |

**End-of-month checkpoint:** Public GitHub with operator, 2 blog posts,
LinkedIn says "Senior Platform Engineer | Kubernetes / EKS / Cilium," and
you've sent 10+ applications.

### Month 4 — Active interview cycle (60 hrs)

Goal: **Get interview reps.** Most candidates fail the first 5-10 interviews;
that's normal and necessary. You burn through them this month.

| Week | Focus | What you're doing |
|---|---|---|
| 1 | 10 more applications + 3 mock interviews via Pramp | Apply to Razorpay, PhonePe, Cred, Swiggy, plus 6 others |
| 2 | 1st-round interviews + system design practice | "Design a multi-region K8s platform" — practice 3 times this week |
| 3 | 2nd-round interviews + technical deep-dives | Bring dealing migration story into every round |
| 4 | More applications + final-round interviews | Aim to have 3+ companies in late-stage by month end |

**End-of-month checkpoint:** 5+ companies actively engaged, at least 1 in
final rounds, system design no longer scares you.

### Month 5 — CKA + CKS + close offer (60 hrs)

Goal: **Certify + close.** Convert the interview reps into offers; convert
offers into a signed contract; add CKA/CKS as validation.

| Week | Focus | What you're doing |
|---|---|---|
| 1 | CKA intensive prep | KodeKloud course + killer.sh practice exam |
| 2 | Take CKA exam + final-round interviews | $395, 2 hours, online proctored. Pass. |
| 3 | CKS intensive prep | Linux Foundation CKS curriculum + killer.sh |
| 4 | Take CKS exam + close offer | $395. Negotiate with 2+ offers in hand. Sign. |

**End-of-month checkpoint:** CKA badge + CKS badge + signed offer at ≥50 LPA.

---

## Lab setup (your laptop + AWS)

### Tools to install on your laptop

```bash
# Required
docker          # or colima / podman
kind            # local K8s for daily lab work
k3d             # alternative fast local K8s
kubectl
helm
terraform
aws-cli         # configured with your AWS account
jq
yq

# Strongly recommended
k9s             # terminal UI for kubectl
kubectx         # switch kubeconfigs
kubens          # switch namespaces
stern           # multi-pod log tailer
go              # for Month 3
kubebuilder     # for Month 3

# Editor
VS Code         # with K8s, Go, Terraform, YAML extensions
```

### Laptop requirements

- 16 GB RAM minimum (32 GB ideal)
- 100 GB free disk
- Docker Desktop or colima working
- Decent internet (Cilium image pulls are large)

### AWS account setup

- Personal AWS account (don't use work account for personal labs)
- Budget alarm at $50, hard cap at $200/month
- Always destroy expensive resources (EKS control plane, NAT GW, RDS) at end
  of each session
- Use AWS free tier where possible

### Cost expectations over 5 months

| Item | Cost (USD) | Cost (INR ~₹85/USD) |
|---|---|---|
| AWS labs | $150-400 | ~₹13K-34K |
| CKA exam | $395 | ~₹33K |
| CKS exam | $395 | ~₹33K |
| Books (Production Kubernetes, optional) | $50 | ~₹4K |
| KodeKloud or A Cloud Guru subscription (optional) | $40/mo × 5 = $200 | ~₹17K |
| Pramp mock interviews | Free | 0 |
| **Total** | **$1,190-1,440** | **~₹100K-122K** |

Most of the cost is the 2 cert exams. The AWS lab cost depends entirely on
your discipline around destroying resources. The discount: cert exams have
periodic Linux Foundation discount codes (often 30-40% off around CNCF events).

---

## What I provide vs what you do vs external resources

| What I provide | What you do | External resources |
|---|---|---|
| Weekly explainer doc tailored to your existing dealing knowledge | Read + work the lab | KodeKloud / Mumshad for cert content (more polished than I can do for cert-specific patterns) |
| Lab exercises with step-by-step | Execute on your laptop or AWS | killer.sh for cert practice (only place that mimics exam UI) |
| Review of your YAML, Go code, operator design | Bring me your work | Pramp for mock interviews (need humans, not me) |
| System design mock partner | Iterate with me | "Designing Data-Intensive Applications" book |
| Blog post drafts review | Polish before publishing | Medium / dev.to to publish |
| Resume + LinkedIn review | Polish before applying | LinkedIn premium (optional, for InMail) |
| Curated reading list per topic | Read | Official Cilium / Kubernetes / AWS docs |
| Synthesis across topics ("this is why X relates to Y") | Trust me on the connections | Stack Overflow + GitHub issues for specific bugs |

What I can't:
- Take the CKA/CKS exam for you ($395 each, your test)
- Pay for AWS practice (your bill)
- Replace KodeKloud / Mumshad's cert-specific content (better for that)
- Be a hiring manager (use Pramp + peer mocks)
- Get you a referral (your network, your responsibility)

---

## The non-negotiables

These are things you don't get to skip, regardless of preference:

1. **You will take CKA and CKS in Month 5.** Even with portfolio strength,
   these are the badges hiring managers expect at the senior K8s band.
2. **You will write at least 2 public blog posts.** Recruiters search.
3. **You will ship one open-source operator.** This is the muscle Go signal.
4. **You will do at least 5 Pramp mock interviews before applying.** Interview
   skill is a learnable thing; practice or get rejected.
5. **You will apply to 30+ companies.** Acceptance rate is ~5-10% at this
   band; volume matters.
6. **You will negotiate.** Always have ≥2 offers when accepting. Always ask
   for ESOPs / RSUs / bonus on top of base.

---

## Tracking progress

A separate doc `PROGRESS.md` will track week-by-week:
- What's planned this week
- What's actually been done
- What blocked or surprised you
- What's queued for next week

I'll initialize that doc + update it each week.

---

## How we work together each week

```
Sunday evening:
  I write next week's explainer + lab doc into docs/learning/MM-week-NN-topic.md.
  PROGRESS.md updated with the week's plan.
  You read the explainer over weekend.

Monday-Friday:
  You work the lab in your evenings.
  Open a Claude Code session whenever you hit a wall.
  Ask me anything. Pair-debug a tricky concept.

Saturday:
  Review session. You bring me what you built — code, configs, observations,
  questions. I critique. We agree what to revisit and what's done.
  PROGRESS.md updated with what shipped.

Sunday evening: cycle repeats.
```

This rhythm holds for Months 1-3. Months 4-5 the rhythm changes (interviews
take priority over fixed weekly topics).

---

## Risk register

Honest list of things that could derail this plan:

| Risk | Probability | Mitigation |
|---|---|---|
| Day job demands swell, can't sustain 15 hrs/week | Medium | Drop to 10 hrs/week, extend to 7 months. Don't quit. |
| AWS cost spirals (forgot to destroy a cluster) | High first month, low after | Hard budget alarm at $50; destroy ritual at end of each session |
| CKA fail on first attempt | Low if prep is solid | Linux Foundation lets you retake once for free |
| No interview offers by end of Month 4 | Medium | Apply more aggressively in Month 4 Week 4. Push for referrals on LinkedIn. |
| Offer comes in at 35-42 LPA, not 50 | Medium | Decide your floor in advance. Walk away from offers below floor IF you have alternatives in flight. |
| Burnout in Month 4 from interviewing while studying | High | Reduce study load during Month 4. Interview prep IS study. |

---

## Open the first lab

Your first week starts at `docs/learning/01-month1-week1-aws-vpc-iam.md`.

That doc contains:
- ~2 hours of theory to read
- ~10 hours of hands-on lab
- 3 hours of buffer for breakage and review
- Checkpoint questions for our Saturday review

Open it. Read the theory section first (don't start the lab until you've
read theory). The lab references concepts the theory teaches.

We start Week 1 of Month 1 now. See you Saturday for the first review.

---

*Last updated when curriculum was created. Update each Monday with status.*
