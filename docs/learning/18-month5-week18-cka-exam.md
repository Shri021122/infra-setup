# Month 5, Week 18 — Take CKA + ongoing interviews

> Exam week. The single highest-leverage hour this whole month is the
> 2-hour CKA exam. Don't sabotage it with poor sleep, bad timing, or
> last-minute cramming.

## Goal for the week

By Saturday:
- CKA exam taken and passed (or scheduled retake if narrowly failed)
- 1-2 active offer conversations
- Started loose CKS prep (reading the curriculum)

## Time breakdown

- Final CKA polish: ~3 hours
- Exam day buffer: ~4 hours
- Interview activity: ~3 hours
- CKS curriculum read: ~2 hours
- Recovery: ~3 hours

---

## Part 1 — Exam day routine

Schedule the exam for a quiet morning. NOT Friday (you're tired). NOT Monday
(too much pressure to clean inbox).

### T-24 hours

- Re-read the killer.sh #2 solutions one final time
- Sleep ≥8 hours
- Don't drink alcohol
- Set out water, clear desk

### T-1 hour

- Light meal (NOT heavy — coffee + toast or rice + dal)
- Bathroom break
- Quick laptop check: external mouse if you use one
- Disable EVERY notification (Slack, email, phone)

### T-30 min

- PSI check-in starts ~30 min early. They scan your room with webcam.
- Have your ID ready (passport preferred — driver's license has worked too)
- Audit your desk one more time — NO papers, books, devices

### Exam

- Read all 17 questions in the first 5 minutes; flag the ones that look
  easy (do those first)
- Stick to your aliases. `alias k=kubectl` at the start.
- For every YAML question: `k <verb> ... --dry-run=client -o yaml >file.yaml`
  then edit then apply
- Verify after every task: `k get -n <ns> <resource>`
- If stuck on a task >10 min: skip, mark, return at end
- Don't get tunnel vision — the easy tasks are worth as much as hard ones
- Last 10 min: revisit anything you skipped

### Immediately after

- Walk away from laptop for 30 min before checking anything
- Score arrives in 24 hours
- If you pass (≥66%): celebrate, post on LinkedIn ("Just passed CKA…")
- If you fail: schedule retake (free), but take 1 week recovery before
  studying again

---

## Part 2 — Continue interview activity

Don't pause your active processes for the exam. Schedule any pending
interviews for the back half of the week. If you're in final-round + late-
stage talks, this is when you might convert.

If you have an offer in hand:
- Use it to push other companies: "I have an offer with deadline X — can
  we expedite?"
- Be polite, never combative

---

## Part 3 — Start loose CKS prep

CKS curriculum overview:
- Cluster Setup: 10%
- Cluster Hardening: 15%
- System Hardening: 15%
- Minimize Microservice Vulnerabilities: 20%
- Supply Chain Security: 20%
- Monitoring, Logging, Runtime Security: 20%

CKS is harder than CKA. It assumes CKA-level competence and adds:
- Pod Security Standards (baseline, restricted)
- ImagePolicyWebhook
- AdmissionControllers (you've used Kyverno on dealing)
- Runtime security (Falco)
- Open source tools: Trivy (scanning), kube-bench (CIS audit)
- Network policies (advanced)

You've done a lot of this on dealing. Spend ~2 hours this week reading the
curriculum, listing what's familiar vs new. Don't drill yet — wait for
Week 19.

---

## Saturday review checkpoint

Bring:
- CKA result (pass/fail/pending)
- Interview tracker — companies, stages, offers (if any)
- Brief CKS familiarity audit: 1-line per curriculum item ("done it on
  dealing" / "read but never applied" / "totally new")

If CKA failed narrowly (60-65%): we plan a 2-week retake. If failed badly
(<55%), we plan more carefully.

---

## What's next: Week 19 — CKS intensive prep

The harder cert. Pod Security Standards, AdmissionControllers, Falco,
Trivy, kube-bench. Most of these you've touched on dealing.
