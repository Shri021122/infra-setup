# Month 3, Week 12 — LinkedIn + resume + first 10 applications

> The week marketing replaces engineering. Your portfolio is built; now you
> package it. LinkedIn, resume, application list, first round of submissions.

## Goal for the week

By Saturday:
- LinkedIn profile that converts a recruiter scroll into a click within 5 sec
- Resume that's specific, quantified, and 1 page (max 2)
- A target list of 30 companies with rationale
- 10 applications submitted
- 3 LinkedIn DMs to people at target companies (referrals)

## Time breakdown

- Profile polish: ~4 hours
- Resume: ~4 hours
- Target list research: ~3 hours
- Application submissions: ~3 hours
- Buffer: ~1 hour

---

## Part 1 — LinkedIn

### 1.1 Profile audit, top to bottom

| Section | What it should say |
|---|---|
| **Photo** | Clear face, professional, neutral background |
| **Banner** | Custom: K8s/AWS-themed, NOT generic LinkedIn template |
| **Headline** | "Senior Platform Engineer \| Kubernetes • EKS • Cilium • Go" (or your variation) |
| **About** | 200 words: what you do + what you've shipped + what you're looking for. NOT a wall of buzzwords. |
| **Featured** | Pin: blog post #1, blog post #2, GitHub operator |
| **Experience** | Current role: 4-6 bullet points, each starting with a verb, ending with a result. Past role: 2-4 bullets. |
| **Education** | College + relevant certs (none yet — Month 5) |
| **Skills** | Top 5 only: Kubernetes, AWS, Go, Cilium, Terraform. Endorsements come later. |
| **Projects** | Add the operator |

### 1.2 The headline formula

`<Role> | <3-4 specialty keywords>`

Examples:
- "Senior Platform Engineer | Kubernetes • EKS • Cilium • Go"
- "DevOps Engineer | Building scalable K8s infra @ <Company>"
- "Infrastructure Engineer | Multi-cluster Kubernetes • Observability"

DON'T:
- "Aspiring DevOps Engineer" (anti-pattern, signals junior)
- "Open to opportunities | Kubernetes | DevOps | SRE | Platform | Cloud" (laundry list)
- "Passionate about technology" (zero signal)

### 1.3 The About section template

```
I'm a Platform Engineer with X years' experience operating Kubernetes
clusters in production. I'm currently building <briefly: what at your job>.

Specialties:
• Cilium / eBPF networking — including authoring CCNPs, debugging from BPF
  maps, multi-cluster ClusterMesh
• AWS EKS — Terraform-managed clusters with IRSA, Karpenter, AWS LB
  Controller, EBS CSI
• Kubernetes operators — I've built and open-sourced a maintenance-window
  operator in Go (link below)

Recent writing:
• <Blog 1 title> [link]
• <Blog 2 title> [link]

I'm currently exploring roles in platform / SRE / infrastructure engineering
at companies operating Kubernetes at scale. Open to remote or Bengaluru/
Hyderabad/Pune.

DM me if you're hiring, or just want to chat about CNI design.
```

### 1.4 Experience bullets

Bad (vague):
> Worked on Kubernetes cluster

Bad (laundry list):
> Used Kubernetes, Helm, Terraform, Docker, Prometheus, Grafana

Good (specific + result):
> Designed and operated a 6-node on-prem RKE2 cluster with Cilium CNI;
> reduced node-to-node latency by ~40% vs prior iptables-based setup by
> migrating to eBPF datapath.

Better (specific + result + scale):
> Reduced cluster-wide policy thrash from >2000 NetworkPolicies to <20
> CCNPs by refactoring to a 4-layer model (switch ACL / cluster CCNP /
> per-app CNP / app-layer TLS), cutting policy-recompute CPU by ~60%.

Each bullet: **action verb + thing + measurable result.** Numbers beat
adjectives. If you can't quantify a bullet, you might not need that bullet.

---

## Part 2 — Resume

### 2.1 Format rules

- Max 2 pages. 1 page if you have <5 years experience.
- PDF only. Never .docx.
- Single font, sans-serif. Calibri / Inter / Open Sans.
- No photo, no chart, no fancy design. Hiring managers spend 6-8 seconds.
- ATS-friendly: avoid tables, multi-column, header/footer.

### 2.2 Section order

1. **Name + contact** — email, phone, LinkedIn, GitHub. NO physical address.
2. **Summary (3-4 lines)** — distilled version of LinkedIn About.
3. **Skills** — short list, max 10 items, organized: Languages | Tools | Platforms
4. **Experience** — reverse chronological, 3-5 bullets per role
5. **Projects** — operator + dealing cluster + blog series (link each)
6. **Education** — degree + year
7. **Certifications** — empty for now; will populate in Month 5

### 2.3 The Skills block

```
Languages         Go, Bash, Python (intermediate)
Cloud             AWS (EKS, VPC, IAM, IRSA, ALB, Route53, ACM)
Kubernetes        RKE2, EKS, Cilium, ArgoCD, Helm, Kustomize, Kubebuilder
Observability     Prometheus, Grafana, Loki, Mimir, Alloy, Hubble
IaC               Terraform, Ansible
Networking        eBPF, VLANs, BGP, WireGuard, L7 routing
```

### 2.4 Anti-pattern: skills laundry list

DON'T write:
> Kubernetes, Docker, Linux, Bash, Git, GitHub Actions, CI/CD, Helm, Kustomize,
> Terraform, Ansible, Prometheus, Grafana, Loki, ArgoCD, Flux, Cilium, Calico,
> Flannel, Calico, MetalLB, Nginx, Traefik, HAProxy, Envoy, Istio, Linkerd,
> AWS, GCP, Azure, ...

Hiring managers see this and think "knows about all of these, mastered none."
Pick 5-10 things you can confidently defend in an interview.

---

## Part 3 — Target list

### 3.1 Tier the companies

| Tier | Pay band | Examples (India) |
|---|---|---|
| **Tier 1 (50+ LPA likely)** | 50-90 LPA total | Atlassian-India, Browserstack, Postman, Razorpay (Sr.), PhonePe (SDE-3), Stripe-India, Confluent-India, Databricks-India, FAANG (Amazon SDE-2/3, Google L4/L5, Meta E4/E5) |
| **Tier 2 (40-50 LPA)** | 40-50 LPA total | Cred, Swiggy, Zerodha, Dream11, Flipkart (SDE-2/3), MakeMyTrip, Paytm-platform, Tata 1mg |
| **Tier 3 (30-40 LPA)** | 30-40 LPA | Many SaaS startups; gives breadth, can pivot up |
| **Stretch (60+ LPA)** | 60-100+ LPA | FAANG senior tracks; pre-IPO US-funded companies' India offices |

### 3.2 How to research a company

Before applying, spend 15 min:
- Read their engineering blog. Do they write about K8s?
- Search "<Company> Kubernetes" on LinkedIn — who works there in your role?
- Check Glassdoor / AmbitionBox for compensation data
- Look at their open positions on Levels.fyi if listed

Filter out companies that:
- Don't actually use K8s at scale (a sign: their job postings emphasize
  "passionate, fast-paced" over "complex distributed systems")
- Pay below your floor (research first)
- Are pre-Series B startups (variance is too high)

### 3.3 Build the target list spreadsheet

Columns:
| Company | Role | Posted | Source | Status | Pay band | Referral | Notes |
|---|---|---|---|---|---|---|---|

Aim for 30 companies. You'll apply to ~50 over 4 months as openings rotate.

### 3.4 Where to find jobs

- LinkedIn Jobs (set filters: K8s, India, 5+ yrs)
- AngelList / Wellfound (startups)
- HackerNews "Who is Hiring" (monthly thread)
- Direct company careers pages (best signal-to-noise)
- Recruiter DMs (respond to every one that looks credible)
- The Lever / Greenhouse aggregators

---

## Part 4 — Applications

### 4.1 Apply to 10 this week

Pick 10 from your list. Apply via:
1. Company careers page (best — no recruiter middleman)
2. LinkedIn Easy Apply (lazier; lower quality signal)
3. Referral (highest conversion if you have one)

### 4.2 The cover letter / message

If a cover letter / "Why this company" field exists:

```
Hi <Company> team,

I'm applying for the <role>. Three reasons I think there's a fit:

1. <Specific thing about the company you actually care about>. I read
   your engineering blog post on <X> and it lines up with how I've been
   thinking about <Y>.

2. <Specific match between your skills and the JD>. <Concrete example from
   your portfolio: "I built a maintenance-window operator in Go (link), the
   same kind of tooling pattern you describe in your platform doc">.

3. <Something honest about what you're looking for>. <"I want to work on
   K8s networking problems at scale, and your multi-region active-active
   setup is the kind of problem I'd happily spend 5 years on">.

Resume attached. Happy to talk anytime.

— <Your name>
LinkedIn: ...
GitHub: ...
```

100-150 words. Specific. NEVER use a template that says "I'm a passionate
engineer who loves to learn."

### 4.3 Track everything

Keep a sheet:
| Date | Company | Role | Channel | Cover letter? | Recruiter response | Stage |
|---|---|---|---|---|---|---|

This becomes your data for "which channels actually convert" in Month 4.

### 4.4 LinkedIn referrals

Find 3 people at your target companies in roles similar to what you want.
Send a friendly DM:

> Hi <Name>, I saw your work at <Company> — particularly <specific thing
> from their profile or blog>. I'm exploring <role> positions in K8s/SRE
> space and <Company> is on my shortlist. Would you be open to a 15-min
> chat about your team and what you look for in hires? If a referral makes
> sense after, I'd appreciate it; if not, no pressure.
>
> A bit about me: I currently operate a 6-node K8s cluster, recently
> open-sourced a maintenance-window operator (link), and blog about Cilium
> (link).

Don't open with "Can you refer me?" Open with curiosity + your work.

---

## Part 5 — Saturday review checkpoint

I'll review:
- Your LinkedIn profile (URL)
- Your resume PDF
- Your target list spreadsheet (top 10 with rationale)
- 1 cover letter you've sent (with company name)
- Your tracking sheet of 10 submitted applications

Feedback areas:
- Headline conversion potential
- Resume's first-15-seconds impression
- Bullet specificity (are numbers there?)
- Cover letter authenticity (does it sound like a person?)
- Target list realism (right tier, right roles?)

We'll iterate. Some bullets get rewritten. Maybe 1-2 target companies get
swapped out.

---

## What's next: Month 4 — Active interview cycle

Build phase = done. Application phase begins. Week 13: 10 more applications,
3 Pramp mocks, start system design practice.
