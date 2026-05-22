# Month 3, Week 10 — Kubebuilder + first operator scaffold

> The week you write a real Kubernetes operator. By Saturday it builds,
> deploys, and watches a CRD. Functional but minimal.

## Goal for the week

By Saturday, you can:
- Scaffold an operator with `kubebuilder`
- Define a CRD with OpenAPI schema validation
- Implement a Reconcile loop that converges to desired state
- Run the operator locally against a kind cluster + deploy it as a manifest
- Explain to an interviewer why operators exist and what they replace

## What the operator does

**`MaintenanceWindow` controller.**

Use case: lets cluster admins declare a time window during which certain
namespaces have:
- HPA disabled (no autoscaling during the window)
- PDB minAvailable bumped (more replicas required, blocks drains)
- A label `maintenance.active=true` applied to all pods

After the window ends, the operator restores normal state.

Why this operator: it's small, deals with real K8s objects, and has both
a "begin" and "end" reconciliation — good for learning the pattern.

```yaml
apiVersion: ops.example.com/v1
kind: MaintenanceWindow
metadata:
  name: friday-night
  namespace: default
spec:
  start: "2026-06-20T22:00:00Z"
  end:   "2026-06-21T02:00:00Z"
  namespaces: [app1, app2]
  bumpMinAvailableTo: 3
```

## Time breakdown

- Reading: ~2 hours
- Coding: ~11 hours
- Buffer: ~2 hours

---

## Part 1 — Theory

### 1.1 What an operator is

A Kubernetes operator = controller + CRD. It extends K8s with custom
behavior.

The "operator pattern" (from CoreOS, 2016):
- You define a new resource type (CRD)
- You write a controller that watches that resource
- The controller "reconciles" — observes desired state, observes current
  state, makes them match

Operators replace ad-hoc bash scripts, runbooks, and chronic toil.
Examples in the wild:
- `cert-manager` — declares "give me a cert for X domain"; operator handles ACME
- `prometheus-operator` — declares "scrape these targets"; operator manages
  Prometheus CRDs
- `argocd` — declares "deploy from this Git repo"; operator handles sync
- `kyverno` — declares policies; operator enforces

### 1.2 The Reconcile pattern

```go
// In every reconcile invocation:
func (r *MaintenanceWindowReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // 1. Fetch the resource
    var mw opsv1.MaintenanceWindow
    if err := r.Get(ctx, req.NamespacedName, &mw); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. Determine desired state
    now := time.Now()
    inWindow := !now.Before(mw.Spec.Start.Time) && now.Before(mw.Spec.End.Time)

    // 3. Reconcile each managed object to desired state
    for _, ns := range mw.Spec.Namespaces {
        if inWindow {
            // disable HPAs in ns, bump PDBs, label pods
        } else {
            // restore normal state
        }
    }

    // 4. Update status
    mw.Status.Active = inWindow
    r.Status().Update(ctx, &mw)

    // 5. Requeue at a useful time
    return ctrl.Result{RequeueAfter: nextEdge(now, mw)}, nil
}
```

Key principles:
- **Idempotent**: calling Reconcile 100 times in a row should produce the
  same result as calling it once.
- **No assumption about state**: don't assume the previous Reconcile ran
  or succeeded. Always observe current state from the API.
- **Requeue for time-based events**: if you need to act at T+5min, return
  `RequeueAfter: 5*time.Minute`.

### 1.3 Owner references

If your operator creates a sub-resource (e.g., a ConfigMap), set OwnerRef
on it pointing to the parent CRD. Then when the parent is deleted, K8s
garbage-collects the children.

```go
ctrl.SetControllerReference(&mw, &configMap, r.Scheme)
```

### 1.4 RBAC

Your operator runs as a ServiceAccount. It needs permission to GET/LIST/
UPDATE/PATCH whatever it touches. Kubebuilder generates RBAC from `//+kubebuilder:rbac:...`
markers in your Go code. Read your generated `config/rbac/role.yaml` and
verify it's minimal (no `*` if avoidable).

### 1.5 Status subresource

A CRD's status block is updated independently of the spec. K8s clients
(kubectl, your controller) write to status via `.Status().Update()`, which
hits a different sub-endpoint (`/status`). This prevents conflicts between
"user edits spec" and "operator updates status."

---

## Part 2 — Lab

### Lab 1 — Scaffold the project (~1 hour)

```bash
mkdir maintenance-operator && cd maintenance-operator
go mod init github.com/<you>/maintenance-operator

# install kubebuilder
curl -L -o kubebuilder https://go.kubebuilder.io/dl/latest/$(go env GOOS)/$(go env GOARCH)
chmod +x kubebuilder && sudo mv kubebuilder /usr/local/bin/

# scaffold
kubebuilder init --domain example.com --repo github.com/<you>/maintenance-operator

# add an API
kubebuilder create api --group ops --version v1 --kind MaintenanceWindow

# answer yes to "Create Resource" and "Create Controller"
```

Look at the generated `api/v1/maintenancewindow_types.go`. This is where
you define the CRD schema. And `internal/controller/maintenancewindow_controller.go` —
where you implement Reconcile.

### Lab 2 — Define the CRD schema (~2 hours)

Edit `api/v1/maintenancewindow_types.go`:

```go
type MaintenanceWindowSpec struct {
    Start              metav1.Time `json:"start"`
    End                metav1.Time `json:"end"`
    Namespaces         []string    `json:"namespaces"`
    BumpMinAvailableTo *int32      `json:"bumpMinAvailableTo,omitempty"`
}

type MaintenanceWindowStatus struct {
    Active              bool        `json:"active,omitempty"`
    LastReconciled      metav1.Time `json:"lastReconciled,omitempty"`
    AffectedNamespaces  []string    `json:"affectedNamespaces,omitempty"`
}
```

Run `make manifests` to regenerate the CRD YAML. Look at `config/crd/bases/`.

Add OpenAPI validation via markers:

```go
// +kubebuilder:validation:Required
Namespaces []string `json:"namespaces"`

// +kubebuilder:validation:Minimum=1
BumpMinAvailableTo *int32 `json:"bumpMinAvailableTo,omitempty"`
```

Re-run `make manifests`.

### Lab 3 — Implement Reconcile (~4 hours)

Edit `internal/controller/maintenancewindow_controller.go`. Implement
the logic outlined above:

1. Fetch the MaintenanceWindow
2. Determine if we're in-window
3. For each target namespace:
   - In-window: label pods `maintenance.active=true`; scale HPAs to disabled
   - Out-of-window: remove label; restore HPAs
4. Update status
5. Requeue at next edge

For HPA disable/restore, there's no "disable" field; the trick is to
annotate the HPA `autoscaling.alpha.kubernetes.io/conditions=disabled` or
just delete it and let your operator track its previous state in a sub-
ConfigMap. Pick one approach and stick with it.

Add RBAC markers above the Reconcile method:
```go
// +kubebuilder:rbac:groups=ops.example.com,resources=maintenancewindows,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ops.example.com,resources=maintenancewindows/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;patch
// +kubebuilder:rbac:groups=autoscaling,resources=horizontalpodautoscalers,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=policy,resources=poddisruptionbudgets,verbs=get;list;watch;update;patch
```

Run `make` to build.

### Lab 4 — Test locally against kind (~2 hours)

```bash
# Create a kind cluster
kind create cluster --name=op-lab

# Install your CRD
make install

# Run the operator locally (NOT inside the cluster — just compile + run)
make run
```

In another terminal, create a sample MaintenanceWindow:

```yaml
apiVersion: ops.example.com/v1
kind: MaintenanceWindow
metadata: { name: now, namespace: default }
spec:
  start: "2026-06-20T12:00:00Z"  # set to 1 min in the past
  end:   "2026-06-20T13:00:00Z"  # 1 hour from now
  namespaces: [default]
  bumpMinAvailableTo: 3
```

`kubectl apply -f`. Watch your operator's stdout — it should reconcile.

Verify:
```bash
kubectl get mw -o wide
kubectl get mw now -o jsonpath='{.status.active}'  # true
```

Edit `end` to be in the past. Re-apply. Verify operator restores state.

### Lab 5 — Build + deploy as manifest (~2 hours)

```bash
# Build the controller image
IMG=ttl.sh/maint-operator:24h
make docker-build IMG=$IMG
docker push $IMG    # ttl.sh is a free public scratch registry

# Deploy to cluster
make deploy IMG=$IMG

# Check it's running
kubectl -n maintenance-operator-system get pods
kubectl -n maintenance-operator-system logs deploy/maintenance-operator-controller-manager
```

Now your CRD instance is reconciled by the in-cluster controller, not your
laptop. This is the production deployment shape.

### Lab 6 — Tests (~1 hour)

Kubebuilder gives you `controllers/maintenancewindow_controller_test.go`.
Write at least 2 test cases:
- A MaintenanceWindow with start in the past, end in the future → status.Active=true
- A MaintenanceWindow with end in the past → status.Active=false

Use the envtest infrastructure (Kubebuilder ships with it; runs a real
apiserver+etcd in-process for tests).

```bash
make test
```

### Lab 7 — Polish + README (~1 hour)

Write a real README:
- What the operator does (1 paragraph)
- Sample MaintenanceWindow YAML
- How to install (`kubectl apply -f config/...`)
- Architecture diagram (ASCII or PNG)
- Known limitations

This README is what hiring managers will read. Polish it.

---

## Part 3 — Saturday review checkpoint

1. **What's the difference between a CustomResourceDefinition and a CR (instance)?**
2. **The Reconcile loop should be idempotent. What goes wrong if it isn't?**
3. **You set an OwnerReference on a ConfigMap pointing at the MaintenanceWindow.
   What happens when the MW is deleted?**
4. **Your operator calls `r.Update(ctx, &pod)` to add a label. It returns
   "object has been modified, retry." What's happening, and what's the
   right way to handle it?** (Optimistic concurrency; use Patch instead
   or re-fetch + retry.)
5. **Walk me through your operator's lifecycle from `kubectl apply -f mw.yaml`
   to status.Active=true.** Should take 60 seconds.

Bring: a working GitHub repo with the operator code, a 1-minute demo
(`kubectl apply` + show status flip).

---

## Resources

- [Kubebuilder book](https://book.kubebuilder.io/) — read chapters 1-5
- [Programming Kubernetes (book)](https://www.oreilly.com/library/view/programming-kubernetes/9781492047094/) — the canonical operator reference
- [sample-controller (official K8s)](https://github.com/kubernetes/sample-controller)
- [`controller-runtime` godoc](https://pkg.go.dev/sigs.k8s.io/controller-runtime)

---

## What's next: Week 11 — Finish operator, open-source it, 2nd blog post

Polish the operator. Add real validation. Add metrics (Prometheus). Tag
v0.1.0. Open-source on GitHub. Write blog post #2: "Building a Kubernetes
operator in Go — lessons from a first-timer."
