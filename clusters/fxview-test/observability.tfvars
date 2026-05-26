################################################################################
# observability.tfvars — cluster: fxview-test
################################################################################

kubeconfig_path = "../../clusters/fxview-test/kubeconfig.yaml"
cluster_name    = "fxview-test"
environment     = "development"
entity          = "fxview-test"

# ─── Central Mimir ────────────────────────────────────────────────────────────
central_mimir_url      = "http://10.10.10.203:9009/api/v1/push"
central_mimir_username = ""
mimir_tenant_id        = "fxview-test"

# ─── Central Loki (consumed by Alloy on each VM) ──────────────────────────────
central_loki_url       = "http://loki.stackflow.org"
central_loki_username  = ""
loki_tenant_id         = "fxview-test"

# ─── Prometheus (agent mode) ──────────────────────────────────────────────────
prometheus_retention_days  = 3
prometheus_scrape_interval = "30s"
