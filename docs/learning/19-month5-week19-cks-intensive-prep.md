# Month 5, Week 19 — CKS intensive prep

> CKS is harder than CKA. More tools, more depth, more obscure recipes.
> But you've done a lot of this on dealing — Kyverno, PSS, NetworkPolicies.
> Lean on muscle memory.

## Goal for the week

By Saturday:
- CKS curriculum drilled, all 6 sections
- 2 killer.sh CKS practice exams
- CKS scheduled for early next week

## Time breakdown

- KodeKloud CKS speed-run: ~5 hours
- Hands-on with new-to-you tools (Falco, Trivy, kube-bench): ~5 hours
- killer.sh practice exams: ~4 hours
- Buffer: ~1 hour

---

## Part 1 — The exam

- 2 hours, ~16 tasks
- 67% to pass
- Online, proctored
- $395, one free retake
- Identical UX to CKA but tasks are security-focused

You can use `kubernetes.io/docs`, `falco.org`, `trivy.dev`, `kube-bench`
docs during the exam. Bookmark them in your exam browser.

---

## Part 2 — Topics that always appear

### 2.1 Pod Security Standards (you've used on dealing)

3 levels: privileged, baseline, restricted. Enforced via PodSecurity admission
plugin at the namespace level:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: restricted-ns
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

Drill: given a Pod YAML that's failing PSS, identify which violations and
fix them (drop capabilities, set seccompProfile, runAsNonRoot, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true).

### 2.2 AdmissionControllers (Kyverno / OPA)

Write a Kyverno ClusterPolicy that:
- Denies privileged pods
- Forces image registry to a specific allowlist
- Requires labels on namespaces

Drill: ImagePolicyWebhook setup (less common, but appears).

### 2.3 RBAC + ServiceAccounts

Same as CKA but more nuance:
- automountServiceAccountToken: false (default-deny for tokens)
- Audit logs — which fields catch privilege escalation attempts
- Aggregated ClusterRoles

### 2.4 Network Policies

You've authored these. Drill:
- Default-deny per namespace
- Allow from specific pod labels
- Allow egress to specific CIDR
- DNS allow rule (UDP 53 to kube-dns)

### 2.5 etcd encryption at rest

```yaml
# EncryptionConfiguration on kube-apiserver
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-key>
  - identity: {}
```

Drill: rotate the key (add new key as first, re-encrypt secrets, remove old key).

### 2.6 Runtime — Falco

Falco watches kernel events for anomalies (suspicious shell in container,
file modification, network connection). Install on a node, write a rule
that catches `cat /etc/shadow`, observe the alert.

```yaml
- rule: Read sensitive file
  desc: Detect read of /etc/shadow
  condition: open_read and fd.name = /etc/shadow
  output: "Sensitive file read (user=%user.name file=%fd.name)"
  priority: WARNING
```

### 2.7 Trivy — scan images

```bash
# Scan an image
trivy image nginx:1.27

# Scan a K8s deployment
trivy k8s --report summary deployment/myapp

# Scan a Helm chart
trivy config helm-chart/
```

Drill: given an image with known CVEs, identify them and recommend fixes.

### 2.8 kube-bench — CIS audit

```bash
kube-bench --check 1.2.1   # specific check
kube-bench --benchmark cis-1.8
```

Drill: given a failing check, fix it (edit kube-apiserver, scheduler, etc. flags).

### 2.9 Container image hardening

- Use distroless or minimal base
- Multi-stage Dockerfile, copy only the binary
- Pin image digests (not tags)
- Sign with cosign (Supply Chain Security)

Drill: rewrite a bloated Dockerfile to a distroless multi-stage build.

### 2.10 Supply Chain — image signing

cosign sign + verify:
```bash
cosign sign --key cosign.key ghcr.io/me/myapp:v1
cosign verify --key cosign.pub ghcr.io/me/myapp:v1
```

ImagePolicyWebhook can enforce "only signed images allowed."

---

## Part 3 — Schedule

### Mon-Tue (~4 hours)

KodeKloud CKS speed-run. Skim chapters you already know (PSS, NetworkPolicy,
RBAC). Slow down on Falco, Trivy, kube-bench, cosign.

### Wed (~3 hours)

Install Falco on a kind cluster. Write 2 custom rules. Trigger them. See
the alerts.

Install Trivy. Scan 3 images. Fix one image (rebuild distroless).

### Thu (~3 hours)

killer.sh CKS practice #1. Time honest.

### Fri (~2 hours)

Review gaps from killer.sh #1.

### Sat (~2 hours)

killer.sh CKS practice #2.

### Sun (~1 hour)

Review #2 gaps. Schedule real exam for early next week.

---

## Saturday review checkpoint

I'll quiz:
1. **Default-deny NetworkPolicy that allows DNS only.**
2. **PodSecurity Standards: 3 levels. What's the difference between
   baseline and restricted?** (key gaps: hostNetwork, capabilities,
   seccomp, runAsNonRoot)
3. **Falco rule for detecting a shell in a container.**
4. **etcd encryption at rest: walk through the config + rotation.**
5. **You scan an image with Trivy and find a CRITICAL CVE. What's your
   playbook?**

---

## What's next: Week 20 — Take CKS, close offer, ship

The end. Take CKS, push toward signing whichever offer is best, and wrap.
