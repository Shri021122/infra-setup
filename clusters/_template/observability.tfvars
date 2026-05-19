################################################################################
# observability.tfvars — Prometheus + Alertmanager (Helm via Terraform)
#
# cluster_name MUST match the proxmox.tfvars in this same folder.
################################################################################

kubeconfig_path = "../../clusters/CHANGE_ME/kubeconfig.yaml"
cluster_name    = "CHANGE_ME"
environment     = "production"

# ─── Central observability endpoints ──────────────────────────────────────────
# Prometheus remote_writes to your central Mimir; Alloy on each VM ships logs
# to central Loki. Passwords come from env vars (TF_VAR_central_*_password).
central_mimir_url      = "http://mimir.stackflow.org/api/v1/push"
central_mimir_username = ""

central_loki_url       = "http://loki.stackflow.org"
central_loki_username  = ""
loki_tenant_id         = "CHANGE_ME"   # Defaults to cluster_name if empty

# ─── Prometheus sizing ────────────────────────────────────────────────────────
prometheus_replicas       = 2
prometheus_storage_size   = "20Gi"
prometheus_retention_days = 3

# ─── Alertmanager ─────────────────────────────────────────────────────────────
alertmanager_replicas  = 2
alertmanager_email_to  = "devops@example.com"
alertmanager_smtp_host = ""
