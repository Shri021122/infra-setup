################################################################################
# kube-prometheus-stack — Agent-mode values
#
# Prometheus runs in AGENT mode (no local TSDB) and remote_writes every
# scraped sample to the central Mimir at ${central_mimir_url}. All
# visualization is via the central Grafana — nothing in-cluster.
#
# Disabled here (handled elsewhere):
#   - alertmanager   alerting routed centrally (or off)
#   - grafana        central Grafana
#   - nodeExporter   Grafana Alloy on each VM (systemd) collects node metrics
#   - kubeProxy      Cilium replaces kube-proxy, no targets to scrape
################################################################################

global:
  rbac:
    create: true

alertmanager:
  enabled: false

grafana:
  enabled: false

nodeExporter:
  enabled: false

kubeProxy:
  enabled: false

kubeStateMetrics:
  enabled: true

kubelet:
  enabled: true

kubernetesServiceMonitors:
  enabled: true

prometheus:
  enabled: true
  prometheusSpec:
    # Agent mode — scrape and forward only, no local TSDB. emptyDir is fine.
    enableFeatures:
      - agent
    storageSpec: {}
    replicas: 1
    retention: ${retention_days}d
    scrapeInterval: ${scrape_interval}
    walCompression: true

    # Pick up every ServiceMonitor/PodMonitor/Rule on the cluster, not just
    # the ones labelled with this helm release. Without these, app metrics
    # (Cilium, Hubble, ArgoCD, etc.) are silently dropped.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues:     false
    ruleSelectorNilUsesHelmValues:           false

    externalLabels:
      cluster_name: ${cluster_name}
      entity:       ${entity}

    remoteWrite:
      - url: "${central_mimir_url}"
        headers:
          X-Scope-OrgID: "${mimir_tenant_id}"
%{ if central_mimir_username != "" ~}
        basicAuth:
          username: "${central_mimir_username}"
          password: "${central_mimir_password}"
%{ endif ~}
        writeRelabelConfigs:
          # Histograms expand to _bucket series with huge cardinality. Drop
          # them at remote_write to keep central Mimir cost in check; keep
          # _sum/_count which are enough for most dashboards.
          - sourceLabels: [__name__]
            regex: ".*_bucket"
            action: drop

    remoteWriteDashboards: true
