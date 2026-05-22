# Month 3, Week 11 — Operator polish + open-source + 2nd blog post

> Take the rough operator from Week 10 to "v0.1.0 published" quality.
> Add metrics, webhook validation, leader election. Write the blog post.

## Goal for the week

By Saturday, you have:
- Operator with Prometheus metrics, leader election, validating webhook
- Helm chart for installation
- Tagged v0.1.0 release on GitHub
- 2nd blog post published on dev.to + LinkedIn

## Time breakdown

- Coding: ~9 hours
- Writing: ~5 hours
- Buffer: ~1 hour

---

## Part 1 — Production-quality additions

### 1.1 Metrics

Add Prometheus metrics for:
- `maintenance_windows_total` (gauge): how many MaintenanceWindow CRs exist
- `maintenance_window_active{name, namespace}` (gauge): 0 or 1
- `maintenance_window_reconcile_total{result}` (counter): success, error
- `maintenance_window_reconcile_duration_seconds` (histogram)

Use controller-runtime's built-in metrics registry:

```go
import "sigs.k8s.io/controller-runtime/pkg/metrics"

var (
    activeGauge = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{Name: "maintenance_window_active", Help: "1 if window is currently active"},
        []string{"name", "namespace"},
    )
)

func init() {
    metrics.Registry.MustRegister(activeGauge)
}
```

Expose `/metrics` on port 8080 — kubebuilder scaffold does this already.
Add a Prometheus `ServiceMonitor`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: maintenance-operator, namespace: maintenance-operator-system }
spec:
  selector: { matchLabels: { control-plane: controller-manager } }
  endpoints: [{ port: https, path: /metrics, scheme: https, tlsConfig: { insecureSkipVerify: true } }]
```

### 1.2 Leader election

Already on by default in Kubebuilder. Verify:
```go
mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
    LeaderElection: true,
    LeaderElectionID: "maintenance-operator-leader",
    ...
})
```

Test: run two replicas; only one becomes leader. Kill the leader; the other
takes over within ~15s.

### 1.3 Validating webhook

Validate at admission time:
- `spec.end > spec.start`
- `spec.namespaces` is non-empty
- `spec.bumpMinAvailableTo >= 1`

Scaffold:
```bash
kubebuilder create webhook --group ops --version v1 --kind MaintenanceWindow --defaulting --programmatic-validation
```

Implement in `api/v1/maintenancewindow_webhook.go`:

```go
func (r *MaintenanceWindow) ValidateCreate() (admission.Warnings, error) {
    return r.validate()
}

func (r *MaintenanceWindow) validate() (admission.Warnings, error) {
    if !r.Spec.End.After(r.Spec.Start.Time) {
        return nil, fmt.Errorf("end must be after start")
    }
    if len(r.Spec.Namespaces) == 0 {
        return nil, fmt.Errorf("at least one namespace required")
    }
    return nil, nil
}
```

Test: try to apply a bad MW. K8s rejects at admission time, not later in reconcile.

### 1.4 Helm chart

Move from kustomize to a Helm chart for distribution. The structure:
```
charts/maintenance-operator/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── crd.yaml
│   ├── deployment.yaml
│   ├── rbac.yaml
│   ├── webhook.yaml
│   └── servicemonitor.yaml
```

Hosted via `helm push` to a GitHub OCI repo or use a github-pages chart repo.

Add to README:
```
helm repo add maint https://yourname.github.io/maintenance-operator
helm install maintenance-operator maint/maintenance-operator -n maint-system --create-namespace
```

### 1.5 v0.1.0 release

```bash
git tag v0.1.0
git push origin v0.1.0
```

In GitHub: create a release with notes. Include a screenshot of `kubectl get mw`
showing it working.

---

## Part 2 — Lab schedule

### Day 1 — Mon-Tue (~3 hours)
Metrics + ServiceMonitor + manual test.

### Day 2 — Wed-Thu (~3 hours)
Webhook + leader election + integration test.

### Day 3 — Fri (~3 hours)
Helm chart + tag release.

### Day 4 — Sat morning (~2 hours)
README polish, GH Actions for CI (`make test` + `make docker-build` on every PR).

### Day 5 — Sat afternoon + Sun (~5 hours)
Blog post.

---

## Part 3 — Blog post #2

Title (pick one or your own variation):
- "Building a Kubernetes operator in Go: lessons from a first-timer"
- "What I wish I'd known before writing my first operator"

**Outline (~1800 words):**

1. **Why I built this** (200 words). The problem: maintenance windows
   were tribal knowledge in our shop. The solution: codify them.
2. **The mental model — Reconcile is everything** (300 words). What
   reconciliation actually means; idempotency; observe-vs-event-driven.
3. **Kubebuilder's structure** (300 words). What kubebuilder scaffolds for
   you; what you have to write yourself.
4. **The 3 design decisions I had to make** (400 words). Pick 3, e.g.:
   - Spec validation: webhook vs runtime?
   - Disable HPA: delete + remember, or annotate?
   - Status: report-only vs canonical source?
5. **The gotcha that took 4 hours to debug** (300 words). Pick a real
   one. Optimistic concurrency conflicts are a popular choice (every
   first-timer hits them).
6. **Testing** (200 words). envtest setup, what unit tests vs integration tests look like.
7. **What's next** (100 words). Public roadmap if you have one; or
   "ideas for v0.2.0."

**Code snippets:**
- Show the Reconcile signature
- Show a piece of the validation logic
- Show the test setup

**Diagrams:**
- A flow diagram: CRD applied → webhook validates → operator reconciles →
  status updates
- (You can hand-draw and photograph; no need for fancy tools)

**Quality bar:**
- Link to the GitHub repo
- Include 1 specific commit hash showing a bug fix you made
- Honest about what's still broken / what you'd do differently

Publish on dev.to. Cross-post on LinkedIn. Pin your GitHub repo on profile.

---

## Part 4 — Saturday review checkpoint

1. **Demo the operator end-to-end.** Apply CR → show webhook reject + accept;
   show reconcile; show metrics on `/metrics`; kill the leader and watch
   failover.
2. **Optimistic concurrency. Walk me through what happens when two clients
   PATCH the same object at the same time.**
3. **Your operator has a bug that causes infinite reconcile loops on a
   specific CR. How do you detect it from metrics alone?**
4. **What's the difference between a validating webhook and a mutating
   webhook?**
5. **The blog post. Read me the lead paragraph aloud.** Is it specific
   enough to make a hiring manager click through?

Bring: GitHub repo URL, blog post URL, screenshot of `kubectl get mw` +
Prometheus `maintenance_window_active` graph.

---

## What's next: Week 12 — LinkedIn + resume + start applying

The build phase is done. Week 12 is all about visibility: a polished
LinkedIn profile, a resume that emphasizes the right things, and your
first 10 applications.
