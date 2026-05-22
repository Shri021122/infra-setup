# Month 2, Week 6 — Cilium IngressController + Gateway API + L7

> Up the stack from L3/L4 into L7. Cilium's Envoy-based L7 proxy, the
> Gateway API model, HTTP-aware policy, and the L7 metrics that show up
> in Hubble.

## Goal for the week

By Saturday, you can:
- Explain the difference between Cilium IngressController and Gateway API
- Write a Gateway + HTTPRoute that splits traffic by path and host
- Author an L7 CCNP that restricts HTTP methods/paths between services
- Read Hubble L7 metrics (HTTP status, latency by route)
- Decide when to use Cilium Ingress vs a separate Ingress controller

## Time breakdown

- Theory: ~2.5 hours
- Lab on dealing cluster: ~10 hours
- Buffer: ~2.5 hours

---

## Part 1 — Theory

### 1.1 Three ways to expose services in Cilium

| Mechanism | Where it lives | Best for |
|---|---|---|
| **Service type=LoadBalancer + L2 announce** | Inside Cilium, L4 only | Internal services, simple TCP exposure |
| **Cilium IngressController** | Envoy DaemonSet, L7 | Standard Ingress objects (legacy K8s API) |
| **Cilium Gateway API** | Envoy DaemonSet, L7 | Newer K8s Gateway API CRDs |

The dealing cluster uses all three. The argocd UI is exposed via
IngressController. New apps prefer Gateway API.

### 1.2 Gateway API vs Ingress — why the migration

The K8s Ingress API has hard limitations:
- Annotations are vendor-specific (`nginx.ingress.kubernetes.io/...`,
  `alb.ingress.kubernetes.io/...`) — non-portable
- Single Ingress per service awkward when multi-tenant
- TLS config limited
- No support for non-HTTP protocols (gRPC, TCP, UDP)

Gateway API:
- **Gateway** (cluster admin owns) — the listener: which port, protocol, TLS
- **HTTPRoute** (app team owns) — routing rules attached to a Gateway
- **GatewayClass** (cluster admin) — the implementation (e.g., Cilium)
- Supports HTTP, gRPC, TCP, TLS termination, etc.
- Role-based: separate ownership of infrastructure vs routing

```
   GatewayClass: cilium
        │
        │ implements
        ▼
     Gateway (admin)              ──── listener :443 on cilium-gateway VIP
        │
        │ attached to
        ▼
   ┌─────────────────┐
   │  HTTPRoute (app1)│ → host: app1.example.com, path /api → svc app1-api
   │  HTTPRoute (app2)│ → host: app2.example.com → svc app2
   │  HTTPRoute (mon) │ → host: grafana.example.com → svc grafana
   └─────────────────┘
```

### 1.3 Cilium L7 policy

L7 policy lets you say things like:
- "Service A can GET /api/* on Service B, but not POST"
- "Service C can only call gRPC method UserService.GetUser on Service D"
- "Service E can only set the Host header to allowed-host.com"

Mechanism: when an L7 policy applies, Cilium redirects traffic through Envoy.
Envoy parses HTTP and applies the rule. Cilium becomes a transparent L7 proxy
for that specific (src, dest) identity pair.

**Cost of L7 policy:**
- Extra latency (~0.1-1ms typical) from going through Envoy
- Envoy CPU/memory
- Don't enable L7 on every flow — only where you genuinely need HTTP-aware rules

### 1.4 L7 metrics in Hubble

When traffic goes through Envoy, Hubble gets L7 metrics:
- HTTP method, path, status code
- Latency p50/p95/p99 per route
- Request rate per (src, dest, route)

These show up in Hubble UI and as Prometheus metrics. The dealing cluster's
"Hubble L7 metrics" Grafana panel (in the connectivity dashboard) consumes
these.

### 1.5 TLS termination — three options

When a request hits your Gateway/Ingress on :443:

| Mode | Where TLS terminates | Use case |
|---|---|---|
| **Terminate at Gateway** | Envoy decrypts, then re-encrypts (or plaintext) to backend | Most common; cert managed by cert-manager / external-secrets |
| **TLS Passthrough** | Bytes forwarded encrypted; backend handles TLS | When backend has its own cert (mTLS, etc.) |
| **TLS Pass + SNI routing** | Envoy peeks SNI, routes by hostname, doesn't decrypt | Multi-tenant TLS termination |

Dealing's argocd Ingress uses "terminate" with a cert-manager-issued cert.

### 1.6 Why dealing has BOTH Ingress and Gateway

When dealing was first built, only Ingress was stable. Newer routes (planned)
will use Gateway API. The migration is gradual — both controllers coexist
in Cilium, and HTTPRoutes/Gateways don't conflict with Ingress objects.

For your interview pitch: "We're mid-migration from Ingress to Gateway API on
the cluster; the Gateway API model is cleaner for our multi-tenant routing."

---

## Part 2 — Lab on the dealing cluster

### Lab 1 — Audit existing Ingress + Gateway resources (~1 hour)

```bash
# Ingress controllers configured
kubectl get ingressclass
# Look for: cilium

# All Ingress objects
kubectl get ingress -A

# Gateway API config
kubectl get gatewayclass
kubectl get gateway -A
kubectl get httproute -A
```

Document in a doc:
- How many Ingress objects exist
- Which use the cilium class
- Is there a Gateway resource? Which GatewayClass?
- Any HTTPRoutes already?

### Lab 2 — Examine the Envoy DaemonSet (~1 hour)

```bash
kubectl -n kube-system get ds cilium-envoy -o yaml | head -100
kubectl -n kube-system describe pod -l app.kubernetes.io/name=cilium-envoy
```

Look at:
- Which ports it listens on (typically 7443 for the IngressController VIP-facing side)
- Its resource limits
- ServiceMonitor for metrics scraping (port 9964 — you fixed this last week of Month 1!)

### Lab 3 — Create a Gateway + HTTPRoute (~3 hours)

Deploy a sample app:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: default }
spec:
  replicas: 2
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
      - name: echo
        image: ealen/echo-server:latest
        ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: default }
spec:
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 80 }]
```

Now a Gateway + HTTPRoute (use a real TLS cert from cert-manager or self-signed):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces: { from: Same }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-route
  namespace: default
spec:
  parentRefs: [{ name: lab-gateway }]
  hostnames: [ echo-lab.dealing.local ]
  rules:
  - matches: [{ path: { type: PathPrefix, value: / } }]
    backendRefs:
    - name: echo
      port: 80
```

Apply. Wait for the Gateway to get an external IP:
```bash
kubectl get gateway lab-gateway -w
```

Add a `/etc/hosts` entry: `<gateway-ip> echo-lab.dealing.local`

`curl http://echo-lab.dealing.local/` → echo server JSON response.

### Lab 4 — Path-based + host-based routing (~2 hours)

Add a second app + route both via different paths:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: whoami, namespace: default }
spec:
  replicas: 2
  selector: { matchLabels: { app: whoami } }
  template:
    metadata: { labels: { app: whoami } }
    spec:
      containers:
      - name: whoami
        image: containous/whoami:latest
        ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: whoami, namespace: default }
spec:
  selector: { app: whoami }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: multi-route
  namespace: default
spec:
  parentRefs: [{ name: lab-gateway }]
  hostnames: [ multi-lab.dealing.local ]
  rules:
  - matches: [{ path: { type: PathPrefix, value: /echo } }]
    filters:
    - type: URLRewrite
      urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: / } }
    backendRefs: [{ name: echo, port: 80 }]
  - matches: [{ path: { type: PathPrefix, value: /whoami } }]
    filters:
    - type: URLRewrite
      urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: / } }
    backendRefs: [{ name: whoami, port: 80 }]
```

Test:
```bash
curl http://multi-lab.dealing.local/echo
curl http://multi-lab.dealing.local/whoami
```

Both work, routed to different backends.

### Lab 5 — L7 CCNP with method restriction (~2 hours)

Write a CCNP that says: pods in `default` namespace with label `client=allowed`
can GET on the echo service, but not POST.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: echo-l7
  namespace: default
spec:
  endpointSelector:
    matchLabels: { app: echo }
  ingress:
  - fromEndpoints:
    - matchLabels: { client: allowed }
    toPorts:
    - ports: [{ port: "80", protocol: TCP }]
      rules:
        http:
        - method: GET
          path: "/.*"
```

Test:
```bash
kubectl run probe --image=curlimages/curl --labels=client=allowed --rm -it --restart=Never -- curl -X GET http://echo/
# Should succeed
kubectl run probe2 --image=curlimages/curl --labels=client=allowed --rm -it --restart=Never -- curl -X POST http://echo/
# Should get HTTP 403 (L7 policy violation, NOT a network drop)
```

Note: the POST gets a 403 RESPONSE, not a connection reset. Envoy is
serving the response. Watch Hubble:
```bash
hubble observe --pod default/probe2 --type=l7
```

You'll see L7 events: HTTP method=POST, verdict=FORBIDDEN.

### Lab 6 — Read L7 metrics in Grafana (~1 hour)

Open the Connectivity dashboard. Find the L7 panels (HTTP request rate,
latency by route).

Look for:
- Methods being used (GET dominates for argocd UI; mix for prometheus federation)
- Top hosts
- 4xx / 5xx rates
- p99 latency per route

Document the top 5 routes by volume — useful for capacity discussions in interview.

### Lab 7 — Clean up (~30 min)

```bash
kubectl delete httproute echo-route multi-route -n default
kubectl delete gateway lab-gateway -n default
kubectl delete cnp echo-l7 -n default
kubectl delete deploy,svc echo whoami -n default
```

Confirm Envoy and Cilium return to clean state:
```bash
kubectl -n kube-system logs ds/cilium-envoy --tail=20
hubble observe --type=l7 --last=20
```

---

## Part 3 — Saturday review checkpoint

1. **Gateway API has 3 main resource types. What are they, and who owns
   each in a multi-team org?**
2. **L7 policy adds latency. When is it worth it? When is L4 sufficient?**
3. **Your Gateway's IP is allocated but `curl` times out. List 5 debug
   steps in order.** (DNS, Gateway status, HTTPRoute status, Cilium agent
   logs, Envoy logs.)
4. **The L7 policy allows GET. A client sends POST. What HTTP status does
   it get? Why 403 not RST?** (Answer: Envoy serves a 403; the TCP
   connection succeeds because the L4 rule allowed it, but L7 enforced a
   method restriction in the application layer.)
5. **You want to enforce mTLS between two services. Can Cilium do it without
   a service mesh? What are the options?** (Answer: Cilium Service Mesh adds
   mTLS support, or use app-layer TLS, or sidecar Envoys. Cilium's WireGuard
   encrypts node-to-node but not pod-to-pod identity.)

Bring: your Gateway + HTTPRoute YAMLs, screenshots of Hubble L7 events,
your L7 dashboard observation notes.

---

## Resources

- [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [Cilium L7 policy](https://docs.cilium.io/en/stable/security/policy/language/#http)
- [Gateway API official site](https://gateway-api.sigs.k8s.io/)

---

## What's next: Week 7 — CCNP authoring + service mesh

You've used CCNPs from the outside. Week 7: author 3 production-grade CCNPs
for dealing from scratch. Then dip into Cilium Service Mesh fundamentals
(mTLS, traffic shifting, retries).
