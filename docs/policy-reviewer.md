# Policy Reviewer Checklist

> A short checklist for anyone adding or changing a NetworkPolicy, CiliumNetworkPolicy (CNP),
> CiliumClusterwideNetworkPolicy (CCNP), or Kyverno ClusterPolicy on the `dealing` cluster.
>
> Origin: an in-place CCNP with `endpointSelector: {}` silently broke the Cilium IngressController
> and several UIs. We added a Kyverno rule to block that one specific footgun. This checklist exists
> to catch the other 80% that no automation will catch for us.

## Before you `kubectl apply`

Run through these questions. If any answer is unclear, write the answer into the policy YAML as a
comment before applying — that's the documentation the next person needs.

### 1. Does the policy live in the repo?

If you're applying live via `kubectl` and the manifest isn't in `security/network-policies/`,
`security/kyverno-policies/`, or under `terraform/`, **stop and commit it first**. Cluster state
must match IaC. The CCNP that broke us was kubectl-applied directly.

### 2. What does this selector actually match?

For NetworkPolicy / CNP / CCNP, the most common mistake is over-broad selection:

| Selector | What it actually matches |
|---|---|
| `endpointSelector: {}` | **EVERY endpoint identity, including reserved (`ingress`, `host`, `world`, `kube-apiserver`, `remote-node`).** Almost always wrong. Kyverno now blocks this for CCNPs. |
| `podSelector: {}` (K8s NetworkPolicy) | Every pod in the namespace. Sometimes correct (e.g. a namespace-wide deny). |
| `endpointSelector: matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]` | Every real pod cluster-wide, but **not** reserved identities. Use this when you want "every workload". |
| `endpointSelector: matchLabels: {<specific label>: <value>}` | Only pods with that label. Most policies should be this narrow. |

For Kyverno ClusterPolicies, check `match` and `exclude`:

- `match: any: - resources: kinds: [Pod]` matches every pod. Almost always you want `match` plus
  an `exclude` block for `kube-system`, `kyverno`, `cilium-secrets`, and any other system namespace.
- A policy without `exclude` is at risk of breaking platform components.

### 3. Once this policy is applied, what *new* pods/identities become "default-deny"?

Every NetworkPolicy / CNP / CCNP with an **egress** block puts every endpoint it selects into
default-deny egress. Same for ingress. If your policy selects more endpoints than you intend,
you can break things you didn't even consider.

**Mental test:** "What's the smallest selector that captures only what I need? Why isn't *that* the
selector?"

### 4. What identities/CIDRs does it allow?

For each rule in `egress`/`ingress`:

| Allow shape | Catches |
|---|---|
| `toEntities: [kube-apiserver]` | Just the apiserver (CIDRs tagged with the `kube-apiserver` reserved identity) |
| `toEntities: [host, remote-node]` | **Node IPs only** — does not match pod-CIDR traffic |
| `toEntities: [cluster]` | All in-cluster pod and reserved identities (broad) |
| `toEntities: [world]` | External (non-cluster) destinations only |
| `toCIDR: ["10.10.103.0/24"]` | A specific external CIDR |
| `toServices: [...]` | A specific Kubernetes Service (Cilium L4) |
| K8s `ipBlock: {cidr: ...}` | **Only the `cidr` reserved identity** — does NOT match host/remote-node/world identities. Frequent footgun. |

K8s NetworkPolicy `ipBlock` does NOT match Cilium's reserved identities. If you need to allow
egress to a *node IP*, use a CiliumNetworkPolicy with `toEntities`, not a K8s NetworkPolicy with
`ipBlock`.

### 5. Is there a default-deny baseline already in the namespace?

```bash
kubectl get networkpolicy,cnp -n <namespace>
```

If there's a `default-deny-all` already, any new policy you add is purely additive (allows extra
egress/ingress on top of deny). If not, the namespace is default-allow except where you restrict.

### 6. Did you test in a non-prod namespace first?

For anything cluster-wide (CCNP, CiliumClusterwideNetworkPolicy, Kyverno ClusterPolicy):

1. Apply with `validationFailureAction: Audit` (Kyverno) or scoped to one test namespace (Cilium).
2. Watch for 24h with `hubble observe --verdict DROPPED` and Kyverno PolicyReport.
3. Promote to Enforce / cluster-wide only after the audit window is clean.

### 7. Have you noted the runbook impact?

If the policy could trigger a 4xx response or a connection drop in normal operation, **document
the error message** in [`runbook-dealing.md`](./runbook-dealing.md) under IR-6. Future on-call
should be able to grep the message and find the policy.

### 8. (Kyverno specifically) Audit vs Enforce vs Mutate?

| Mode | When |
|---|---|
| `Audit` | Always start here. Kyverno logs violations in `PolicyReport` / `ClusterPolicyReport`. No request is blocked. Watch reports for at least a few days. |
| `Enforce` | Flip once you've confirmed audit-mode reports are clean. Now violations get rejected at admission time. |
| `Mutate` | Different rule type — Kyverno modifies the resource (adds labels, sets defaults). Use sparingly; mutations are surprising. |

Switching directly from "doesn't exist" to `Enforce` is how you accidentally block legit traffic.

## After you `kubectl apply`

```bash
# 1. NetworkPolicy / CNP / CCNP — confirm it's accepted
kubectl get cnp,ccnp,netpol -A | grep <name>
kubectl describe <kind> <name> | sed -n '/Status:/,$p'    # look for "Valid"

# 2. Watch drops for 5-10 min
W1_AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=dealing-w-1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $W1_AGENT -c cilium-agent -- hubble observe --verdict DROPPED --last 50

# 3. Kyverno-side: check PolicyReports for new violations
kubectl get clusterpolicyreport -o json | python3 -c "
import sys, json
for r in json.load(sys.stdin)['items']:
    for res in r.get('results',[]):
        if res.get('result') != 'pass':
            print(res.get('policy'), '→', res.get('result'), ':', res.get('message',''))"
```

## When to escalate

If a NetworkPolicy or CCNP you applied causes any of these — revert immediately and discuss:

- Ingress UIs return 403 / 404 (you probably caught the `ingress` reserved identity)
- Pods can no longer reach DNS (`coredns` returns nothing → blocked egress on port 53)
- Pods can no longer reach kube-apiserver (kubectl from pods fails)
- Argo Application sync starts failing across the board
- Prometheus targets all go `up=0` at once

Revert: `kubectl delete -f <file>` (and remove the live resource if not in IaC).

## Links

- [Cilium NetworkPolicy concepts](https://docs.cilium.io/en/stable/security/policy/)
- [Kyverno docs](https://kyverno.io/docs/)
- [`runbook-dealing.md`](./runbook-dealing.md) — what to do when policy issues hit production
- [`workload-catalog-dealing.md`](./workload-catalog-dealing.md) — what's running where
- Existing policies: `security/network-policies/`, `security/kyverno-policies/`
