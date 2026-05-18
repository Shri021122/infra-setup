# ArgoCD Helm values
# Rendered by Terraform — do not hand-edit (changes will be overwritten).
# See terraform/argocd/modules/argocd/main.tf for the templatefile() inputs.

global:
  # Pod-level defaults that apply to every ArgoCD component
  podLabels:
    app.kubernetes.io/part-of: argocd

configs:
  params:
    # When server_insecure=true, argocd-server serves plain HTTP and expects
    # a fronting Ingress/Gateway to terminate TLS. When false (default),
    # argocd-server serves its own self-signed TLS.
    server.insecure: ${server_insecure}

  cm:
    # Tighter session timeouts than the default 24h
    timeout.reconciliation: "180s"
    timeout.hard.reconciliation: "0s"
    # exec.enabled: "false"  # uncomment to block `argocd app exec` for tighter security

  # Default RBAC: cluster admins get admin in ArgoCD; everyone else is read-only.
  # Adjust once you wire SSO; for now this matches the bootstrap admin user.
  rbac:
    policy.default: role:readonly

# ─── server (UI + API) ────────────────────────────────────────────────────────
server:
  replicas: ${ha_enabled ? 2 : 1}

  service:
    type: ${server_service_type}

  # No Ingress here — add separately once domain + cert-manager Issuer are decided
  ingress:
    enabled: false

  resources:
    requests:
      cpu: ${server_cpu_request}
      memory: ${server_memory_request}
    limits:
      cpu: ${server_cpu_limit}
      memory: ${server_memory_limit}

  metrics:
    enabled: true
    serviceMonitor:
      # ServiceMonitor CRD lands in the cluster as part of kube-prometheus-stack
      # (Phase 5). Safe to enable here — if Prometheus isn't installed yet the
      # CR is just ignored.
      enabled: true

# ─── application controller (reconciles git → cluster) ───────────────────────
controller:
  replicas: ${ha_enabled ? 2 : 1}
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

# ─── repo server (clones + renders sources) ──────────────────────────────────
repoServer:
  replicas: ${ha_enabled ? 2 : 1}
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

# ─── applicationset controller ───────────────────────────────────────────────
applicationSet:
  replicas: ${ha_enabled ? 2 : 1}
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

# ─── notifications ───────────────────────────────────────────────────────────
notifications:
  enabled: true
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

# ─── redis ───────────────────────────────────────────────────────────────────
# Single-replica redis for non-HA; redis-ha (3 replicas + sentinel) when HA.
redis:
  enabled: ${!ha_enabled}

redis-ha:
  enabled: ${ha_enabled}

# ─── Dex (SSO) — disabled by default; wire OIDC later ────────────────────────
dex:
  enabled: false
