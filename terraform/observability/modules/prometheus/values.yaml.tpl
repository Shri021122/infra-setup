################################################################################
# kube-prometheus-stack Helm Values
# Architecture: NO local Grafana — all visualization via central Grafana.
# Prometheus remote-writes every metric to central Mimir with cluster label.
################################################################################

# ─── Global Labels ────────────────────────────────────────────────────────────
commonLabels:
  cluster: ${cluster_name}
  environment: ${environment}
  managed-by: terraform

# ─── Prometheus ───────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    replicas: ${replicas}
    retention: ${retention_days}d
    retentionSize: "45GB"

    # HA: Both replicas scrape everything (Mimir deduplicates)
    replicaExternalLabelName: "__replica__"

    externalLabels:
      cluster: ${cluster_name}
      environment: ${environment}

    # Scrape all ServiceMonitors and PodMonitors across all namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorNamespaceSelector:
      matchLabels: {}    # All namespaces
    podMonitorNamespaceSelector:
      matchLabels: {}

    # Scrape interval — 15s for production
    scrapeInterval: "15s"
    evaluationInterval: "15s"

    # Security context
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      fsGroup: 65534

    resources:
      requests:
        cpu: ${cpu_request}
        memory: ${memory_request}
      limits:
        cpu: ${cpu_limit}
        memory: ${memory_limit}

    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${storage_class}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${storage_size}

    # HA pod anti-affinity — spread replicas across nodes
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values: ["prometheus"]
            topologyKey: kubernetes.io/hostname

    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"

    # Remote write to YOUR centralized Mimir
    # Every metric gets cluster + environment labels so Grafana can filter per cluster
    remoteWrite:
      - url: "${central_mimir_url}"
        name: central-mimir
        remoteTimeout: ${remote_write_timeout}

%{ if central_mimir_username != "" ~}
        basicAuth:
          username: "${central_mimir_username}"
          password: "${central_mimir_password}"
%{ endif ~}

        # Write-ahead log — survives Prometheus restarts, no data loss
        writeRelabelConfigs:
          # Drop high-cardinality labels before sending to keep Mimir cardinality low
          - sourceLabels: [__name__]
            regex: "go_gc_.*|go_memstats_alloc_bytes_total|go_memstats_frees_total"
            action: drop

        queueConfig:
          maxSamplesPerSend: ${remote_write_queue_max}
          batchSendDeadline: 5s
          minBackoff: 30ms
          maxBackoff: 5s
          # Buffer up to 2 hours of data if central Mimir is temporarily unreachable
          capacity: 10000
          maxShards: 30

    # Extra scrape configs for non-operator targets
    additionalScrapeConfigs:
      - job_name: 'rke2-etcd'
        static_configs:
          - targets:
            # Targets populated by Terraform from master IPs
            - 'MASTER_IP_1:2381'
            - 'MASTER_IP_2:2381'
            - 'MASTER_IP_3:2381'
        tls_config:
          insecure_skip_verify: false
          ca_file: /etc/prometheus/secrets/etcd-certs/ca.crt
          cert_file: /etc/prometheus/secrets/etcd-certs/client.crt
          key_file: /etc/prometheus/secrets/etcd-certs/client.key

# ─── Alertmanager ─────────────────────────────────────────────────────────────
alertmanager:
  alertmanagerSpec:
    replicas: 2
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${storage_class}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

  config:
    global:
      resolve_timeout: 5m
%{ if smtp_host != "" ~}
      smtp_smarthost: '${smtp_host}:587'
      smtp_from: 'alerts@${cluster_name}.cluster'
      smtp_require_tls: true
%{ endif ~}

    route:
      group_by: ['alertname', 'cluster', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'default'
      routes:
        - matchers:
            - severity =~ "critical|page"
          receiver: 'pagerduty-critical'
          repeat_interval: 1h
        - matchers:
            - severity = "warning"
          receiver: 'slack-warnings'
        - matchers:
            - alertname = "Watchdog"
          receiver: 'null'

    receivers:
      - name: 'null'

%{ if slack_webhook != "" ~}
      - name: 'slack-warnings'
        slack_configs:
          - api_url: '${slack_webhook}'
            channel: '#alerts-${cluster_name}'
            send_resolved: true
            title: '[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}'
            text: >-
              {{ range .Alerts }}
                *Alert:* {{ .Annotations.summary }}
                *Description:* {{ .Annotations.description }}
                *Namespace:* {{ .Labels.namespace }}
                *Severity:* `{{ .Labels.severity }}`
              {{ end }}
%{ endif ~}

%{ if pagerduty_key != "" ~}
      - name: 'pagerduty-critical'
        pagerduty_configs:
          - routing_key: '${pagerduty_key}'
            description: '{{ .CommonAnnotations.summary }}'
            severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
%{ endif ~}

%{ if email_to != "" ~}
      - name: 'default'
        email_configs:
          - to: '${email_to}'
            send_resolved: true
%{ else ~}
      - name: 'default'
        # Configure an actual receiver — null receiver only for development
%{ endif ~}

    inhibit_rules:
      - source_matchers:
          - severity = "critical"
        target_matchers:
          - severity = "warning"
        equal: ['alertname', 'namespace']

# ─── Grafana ──────────────────────────────────────────────────────────────────
# DISABLED — visualization is handled by your centralized Grafana instance.
# All metrics flow to central Mimir; Grafana queries Mimir filtered by
# cluster="${cluster_name}" to scope dashboards to this cluster.
grafana:
  enabled: false

# ─── Node Exporter ────────────────────────────────────────────────────────────
# DISABLED — Grafana Alloy (systemd on each VM) runs prometheus.exporter.unix
# which collects the same metrics. Running both would create duplicate series.
nodeExporter:
  enabled: false

# ─── Kube State Metrics ───────────────────────────────────────────────────────
kubeStateMetrics:
  enabled: true

kube-state-metrics:
  metricLabelsAllowlist:
    - "pods=[*]"
    - "deployments=[*]"
    - "statefulsets=[*]"
    - "daemonsets=[*]"
    - "namespaces=[*]"
    - "nodes=[*]"
    - "horizontalpodautoscalers=[*]"
    - "endpoints=[*]"
    - "networkpolicies=[*]"

# ─── Default Prometheus Rules ─────────────────────────────────────────────────
defaultRules:
  create: true
  rules:
    alertmanager: true
    etcd: true
    configReloaders: true
    general: true
    k8sContainerCpuUsageSecondsTotal: true
    k8sContainerMemoryCache: true
    k8sContainerMemoryRss: true
    k8sContainerMemorySwap: true
    k8sContainerResource: true
    k8sPodOwner: true
    kubeApiserverAvailability: true
    kubeApiserverBurnrate: true
    kubeApiserverHistogram: true
    kubeApiserverSlos: true
    kubeControllerManager: true
    kubelet: true
    kubeProxy: true
    kubePrometheusGeneral: true
    kubePrometheusNodeRecording: true
    kubernetesApps: true
    kubernetesResources: true
    kubernetesStorage: true
    kubernetesSystem: true
    kubeSchedulerAlerting: true
    kubeSchedulerRecording: true
    kubeStateMetrics: true
    network: true
    node: true
    nodeExporterAlerting: true
    nodeExporterRecording: true
    prometheus: true
    prometheusOperator: true

# ─── Component Enablement ─────────────────────────────────────────────────────
kubeEtcd:
  enabled: true
  endpoints: []    # Populated dynamically

kubeControllerManager:
  enabled: true

kubeScheduler:
  enabled: true

kubeProxy:
  enabled: false    # RKE2 uses kube-proxy replacement via Cilium

# ─── Kubelet ──────────────────────────────────────────────────────────────────
# Override the chart's default cAdvisorMetricRelabelings which drops
# container_cpu_cfs_throttled_seconds_total along with a few others. We keep
# the *_throttled_seconds_total (used for CPU throttling alerts and dashboards)
# while still dropping the load_average / system / user variants which are
# high cardinality and rarely useful at scale.
kubelet:
  enabled: true
  serviceMonitor:
    cAdvisorMetricRelabelings:
      - sourceLabels: [__name__]
        regex: container_cpu_(load_average_10s|system_seconds_total|user_seconds_total)
        action: drop
      - sourceLabels: [__name__]
        regex: container_fs_(io_current|io_time_seconds_total|io_time_weighted_seconds_total|reads_merged_total|sector_reads_total|sector_writes_total|writes_merged_total)
        action: drop
      - sourceLabels: [__name__]
        regex: container_memory_(mapped_file|swap)
        action: drop
      - sourceLabels: [__name__]
        regex: container_(file_descriptors|tasks_state|threads_max)
        action: drop
      - sourceLabels: [__name__]
        regex: container_spec.*
        action: drop
