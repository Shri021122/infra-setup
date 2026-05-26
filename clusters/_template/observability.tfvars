################################################################################
# observability.tfvars — Prometheus (agent mode) + Alloy on each VM
#
# cluster_name MUST match the proxmox.tfvars in this same folder.
################################################################################

kubeconfig_path = "../../clusters/CHANGE_ME/kubeconfig.yaml"
cluster_name    = "CHANGE_ME"
environment     = "production"
entity          = "CHANGE_ME"   # Defaults to cluster_name if left empty

# ─── Central Mimir ────────────────────────────────────────────────────────────
# Prometheus (agent mode) remote_writes to your central Mimir.
# Password via TF_VAR_central_mimir_password.
central_mimir_url      = "http://mimir.stackflow.org/api/v1/push"
central_mimir_username = ""
mimir_tenant_id        = "CHANGE_ME"   # X-Scope-OrgID; defaults to cluster_name if empty

# ─── Central Loki (consumed by Alloy on each VM) ──────────────────────────────
central_loki_url       = "http://loki.stackflow.org"
central_loki_username  = ""
loki_tenant_id         = "CHANGE_ME"   # Defaults to cluster_name if empty

# ─── Prometheus tuning ────────────────────────────────────────────────────────
prometheus_retention_days  = 3
prometheus_scrape_interval = "30s"
