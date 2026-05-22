# Month 4, Week 13 — More applications, mock interviews, system design starts

> Build phase done. Interview phase begins. 10 more applications, 3 Pramp
> mocks, system design practice every other day.

## Goal for the week

By Saturday:
- 20 total applications submitted (10 prior + 10 new)
- 3 Pramp mock interviews completed with notes
- 3 system design practice sessions done (~45 min each)
- At least 2 recruiter screens scheduled

## Time breakdown

- Applications: ~3 hours
- Mock interviews: ~3 hours
- System design practice: ~3 hours
- Coding warmup: ~3 hours
- Buffer + recruiter calls: ~3 hours

---

## Part 1 — The interview process landscape (India market)

A typical 50 LPA Kubernetes/SRE/Platform role has 4-6 rounds:

| Round | What | Pass signal |
|---|---|---|
| **1. Recruiter screen** | 20-30 min chat. Where are you, why looking, salary expectations, basic resume review | Confirm fit + comp range |
| **2. Hiring manager** | 30-45 min. Behavioral + role expectations + your portfolio | Mutual interest, technical alignment |
| **3. Coding (1-2 rounds)** | LeetCode-style problem; or systems coding (write a CLI tool, parse logs, etc.) | Solve in time, write clean code |
| **4. Kubernetes / domain depth** | 60-90 min deep dive on K8s/AWS/networking | Genuine depth, not just buzzwords |
| **5. System design** | 60 min. "Design a multi-region K8s platform that scales to 10k tenants" | Methodology + trade-offs + back-of-envelope math |
| **6. Bar raiser / leadership** | 45 min. Bigger picture: how you work, why this company | Cultural + senior signal |

Different companies emphasize different rounds. FAANG-India weights heavy
on coding + system design. Fintechs (Razorpay, Cred) weight domain depth.
Some startups skip rounds and offer fast.

## Part 2 — Compensation negotiation basics

You'll get asked salary expectations early. Don't lowball:
- Research on Levels.fyi, AmbitionBox, salary.com
- Bands for senior K8s/Platform roles in India: 40-90 LPA total
- ALWAYS say "total compensation" not just base
- Don't disclose current comp if avoidable; if forced, give range
- Anchor high but realistic: "I'm looking at 55-70 LPA total" for a Tier 1 role

If a recruiter says "what's your expected CTC":
> "I'm looking for total comp in the 55-70 LPA range, with the split between
> base, ESOPs/RSUs, and bonus depending on the role. Happy to discuss specifics
> once we've established mutual fit."

## Part 3 — Pramp / mock interview prep

[Pramp.com](https://www.pramp.com/) — free peer mock interviews. The way:
1. Schedule a slot. You get matched with another engineer.
2. You interview them for 30 min, they interview you for 30 min.
3. Mutual feedback.

Topics on Pramp:
- Data structures / algorithms
- System design
- Frontend (skip)
- Behavioral

Schedule 3 this week. Mix algos (1) + system design (2). Pick topics
you're worst at — the point is to fail in a safe place.

**After each Pramp:**
- Note what tripped you (specific concept, communication issue, time mgmt)
- Spend 30 min studying the gap before the next mock

---

## Part 4 — System design practice

This is the round that decides 50 LPA. Practice 3x this week.

### 4.1 The framework (memorize it)

When asked "design X":

1. **Clarify requirements** (5 min). Functional + non-functional. Get
   numbers: "How many users? Read/write ratio? Latency target?"
2. **Estimate** (3 min). Back of envelope. RPS, storage, bandwidth.
3. **High-level architecture** (10 min). Sketch boxes: clients, LB,
   stateless tier, stateful tier, async layer, cache.
4. **Drill into one component** (15 min). Pick the most interesting.
   Discuss data model, partitioning, consistency, replication.
5. **Trade-offs** (10 min). Walk through 2-3 design choices you made and
   why. Show you considered alternatives.
6. **Scaling / failure modes** (10 min). What breaks at 10x scale? How
   do you mitigate?

NEVER:
- Start drawing immediately without clarifying
- Use a buzzword without explaining
- Pretend to know something you don't (interviewers spot it instantly)

### 4.2 K8s / Platform-flavored problems to practice

Each is 45-60 min:

1. **Design a multi-region Kubernetes platform** that:
   - Hosts 1000s of tenants (each a K8s namespace)
   - Active-active across 2 regions
   - 99.99% SLO
   - Cost-optimized via Spot/Karpenter

2. **Design a Kubernetes-native CI/CD system** (think: ArgoCD-like) for
   500 services across 50 teams. Handle merge conflicts, RBAC, secrets,
   image scanning.

3. **Design an observability stack** (Prometheus + Loki + Mimir) for a
   100-cluster fleet. Hot-shard the data, handle cardinality, plan for
   long-term retention.

4. **Design a service mesh from first principles.** What problems does
   it solve? What's the architecture? Sidecar vs sidecar-less. Costs.

5. **Design a multi-tenant Kubernetes operator** that lets tenants
   declare their workloads via a high-level CRD. Hide the complexity of
   Deployments/Services/Ingress from them.

Do at least 2 of these this week. Self-time (45 min start). Draw on paper.
Then watch the recording (record yourself!) and grade:
- Did I clarify before drawing?
- Did I do back-of-envelope?
- Did I cover ALL the layers?
- Did I discuss trade-offs?

### 4.3 Resources

- "System Design Interview" by Alex Xu (Vol 1+2) — read 1 chapter/week
- ByteByteGo YouTube — short, dense, free
- Donne Martin's [system-design-primer](https://github.com/donnemartin/system-design-primer) — read selectively
- Practice on excalidraw.com or paper

---

## Part 5 — Coding warmup

Don't grind LeetCode. But keep the muscle alive:
- 1 medium problem per day, ~30 min, on a topic you're rusty on
- Topics most likely: arrays, strings, hashmaps, sliding window, BFS/DFS
- Use Go if you can — practice for the real interview language

If you don't have a Go-ready LeetCode habit, ramp up gently:
- Day 1: Two Sum, Valid Anagram, Reverse a Linked List
- Day 2: Group Anagrams, Container With Most Water
- Day 3: Number of Islands, Course Schedule
- Day 4-5: rotate harder

Don't burn out. The K8s/AWS rounds are where you win. Coding rounds are
where you avoid losing.

---

## Part 6 — Recruiter conversations

You'll likely have 2-3 recruiter screens this week from your Month 3
applications. Each is 20-30 min. Have a stock pitch:

> "I'm a Platform Engineer with X years of experience. Most recently I've
> been operating a 6-node Cilium-based Kubernetes cluster, including
> architecting the CNI choices, building observability, and authoring
> network policies. I open-sourced a maintenance-window operator last
> month. I'm looking at platform/SRE/infra roles where I can work on
> K8s at scale, ideally with multi-region or multi-cluster problems."

Practice this until it's 60 seconds.

Recruiter common questions:
- Why looking? → "I want larger-scale problems / better team / better comp"
  (be honest but professional)
- Current CTC? → Avoid sharing if you can; share expected if asked
- Notice period? → "I have X days notice; can buy out if needed"
- Remote vs on-site? → Match the JD; flex if needed
- When can you join? → "Could start in X weeks after offer"

---

## Saturday review checkpoint

Bring:
- Application tracker — 20 entries
- Pramp feedback (your peer's feedback + your self-grade)
- 2 system design sketches (photos)
- 1 recruiter call recap

We'll role-play:
- 5-min recruiter screen (I play recruiter)
- 15-min mini system design (I give a prompt; you sketch)

---

## What's next: Week 14 — 1st-round interviews + system design ramp

You should have 2-3 first-rounds scheduled by now. Focus shifts to
performing well in them, more system design reps, and topping up
applications to 30 total.
