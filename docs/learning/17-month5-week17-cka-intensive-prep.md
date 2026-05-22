# Month 5, Week 17 — CKA intensive prep

> The cert sprint begins. CKA is hands-on (no MCQs) — you're given a real
> cluster and ~17 problems to solve in 2 hours. This week: drill the
> curriculum + 2 practice exams.

## Goal for the week

By Saturday:
- Whole CKA curriculum reviewed
- 2 killer.sh practice exams completed
- kubectl cheat sheet memorized
- Scheduled CKA exam for next week

## Time breakdown

- KodeKloud course speed-run: ~5 hours
- Hands-on lab practice: ~6 hours
- killer.sh practice exams: ~4 hours

---

## Part 1 — The exam

- 2 hours
- ~17 hands-on tasks
- 66% to pass
- Online, proctored (PSI)
- Score released within 24 hours
- $395 USD, one free retake within 12 months if you fail
- You get a real cluster + an exam terminal in a browser

**Allowed:**
- `kubectl` (the only tool you need)
- Linux man pages, K8s docs (`kubernetes.io/docs/*`)
- 1 paper for notes (auditor must see; usually no)

**NOT allowed:**
- Outside browser tabs
- Cheatsheet sites
- Anything beyond docs.kubernetes.io subdomain

## Part 2 — Curriculum (CKA 2024+)

Weights:
- Storage: 10%
- Troubleshooting: 30%
- Workloads & Scheduling: 15%
- Cluster Architecture, Installation & Configuration: 25%
- Services & Networking: 20%

The 25% on Cluster Architecture is where most candidates lose points —
RBAC, kubeadm install, etcd backup. Drill these hardest.

### 2.1 Topics that ALWAYS show up

1. **etcd backup & restore** (`etcdctl snapshot save / restore`)
2. **Upgrade control plane** (kubeadm upgrade)
3. **Drain a node, perform maintenance, uncordon**
4. **Create a ServiceAccount + Role + RoleBinding for specific permissions**
5. **Debug a broken kubectl**, a broken pod, broken DNS
6. **Create a PV + PVC + use in pod**
7. **NetworkPolicy** to restrict traffic
8. **Multi-container pod** with volume sharing
9. **Static pod** in /etc/kubernetes/manifests
10. **Modify kubelet config** to fix something

Each of these has a recipe. Memorize the recipes.

### 2.2 The kubectl moves (memorize cold)

```bash
# Pod creation
kubectl run nginx --image=nginx --dry-run=client -o yaml > pod.yaml

# Deployment
kubectl create deployment x --image=nginx --replicas=3 --dry-run=client -o yaml

# Service
kubectl expose deploy x --port=80 --target-port=80 --type=ClusterIP

# Set image (rolling update)
kubectl set image deploy/x nginx=nginx:1.27

# Rollout
kubectl rollout history deploy/x
kubectl rollout undo deploy/x

# Auto-scale
kubectl autoscale deploy/x --min=2 --max=5 --cpu-percent=70

# Edit live
kubectl edit deploy/x

# Patch (faster than edit for small changes)
kubectl patch deploy/x -p '{"spec":{"replicas":5}}'

# Drain
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data

# Cordon / uncordon
kubectl cordon node-1
kubectl uncordon node-1

# Top pods / nodes
kubectl top pods
kubectl top nodes

# Debug a pod
kubectl describe pod x
kubectl logs x -c container-name --previous
kubectl exec -it x -- /bin/sh
kubectl debug -it x --image=busybox --target=app-container
```

### 2.3 The exam terminal tricks

```bash
# Set namespace default
kubectl config set-context --current --namespace=mynamespace

# Aliases (set at start of exam)
alias k=kubectl
alias kn='kubectl -n'
alias kgp='kubectl get pods'

# Always use --dry-run=client -o yaml for scaffolding
k run busybox --image=busybox --restart=Never --dry-run=client -o yaml > pod.yaml

# Edit then apply
vim pod.yaml
k apply -f pod.yaml
```

---

## Part 3 — Schedule for the week

### Mon-Tue (2 hours each)

KodeKloud CKA course speed-run. You don't need every chapter — focus on:
- RBAC
- ServiceAccounts
- Network Policies
- etcd backup/restore
- kubeadm upgrade
- Troubleshooting (worker node failing, control plane failing, app failing)

Skip topics you know cold (Deployments, Services).

### Wed (3 hours)

killer.sh practice exam #1. This is the only sim that mimics the real
exam UI. Note your time per question. Note questions you couldn't solve.

After the sim, the killer.sh review shows solutions. Walk every one.

### Thu (2 hours)

Study the gaps from killer.sh #1. Memorize the recipes for any tasks you
fumbled.

### Fri (3 hours)

killer.sh practice exam #2. Time it. Score honestly. If you scored >75%,
you're ready for the real exam. If <60%, slow down — push exam by a week.

### Sat (2 hours)

Review #2 gaps. Update your personal cheatsheet (mental).

### Sun (1 hour)

Schedule the real exam for Tuesday or Wednesday of Week 18. Quiet morning,
no other commitments that day.

---

## Part 4 — Exam-day setup

24 hours before:
- Test your webcam + mic with PSI's check-in process
- Clean your desk — exam needs a fully clear workspace
- Phone in another room
- Test your network speed (need 1+ Mbps stable)

Day of:
- Eat ~1 hour before
- Bathroom right before check-in
- Have water nearby
- Disable system notifications

Question strategy:
- ~7 min per task on average (17 tasks, 120 min)
- Skip and revisit hard tasks
- Each task has a weight (shown at top) — prioritize high-weight tasks
- For YAML: always start from `--dry-run=client -o yaml`; never type from scratch
- Always verify with `kubectl get <resource>` after applying

---

## Saturday review checkpoint

I'll quiz you:
1. **Backup etcd. Walk me through the command.**
2. **Upgrade kubeadm cluster from 1.32 to 1.33. Steps.**
3. **A pod is Pending. Walk me through every check.**
4. **Create a ServiceAccount that can only list pods in `team-a` namespace.**
5. **NetworkPolicy: allow ingress from `frontend` namespace only.**

If you can't answer 4/5 in 60 seconds each, postpone the exam by a week.

---

## What's next: Week 18 — Take CKA + final-round interviews

You sit the real exam. Pass it. Continue any negotiation / final round
processes in parallel.
