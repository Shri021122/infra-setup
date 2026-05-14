apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rke2-infrastructure-rules
  namespace: ${namespace}
  labels:
    app: kube-prometheus-stack
    release: kube-prometheus-stack
spec:
  groups:
    # ─── RKE2 Control Plane ─────────────────────────────────────────────────
    - name: rke2.control-plane
      interval: 30s
      rules:
        - alert: RKE2ApiServerDown
          expr: up{job="apiserver"} == 0
          for: 1m
          labels:
            severity: critical
            cluster: ${cluster_name}
          annotations:
            summary: "API server is down on {{ $labels.instance }}"
            description: "The Kubernetes API server has been unreachable for 1 minute."

        - alert: EtcdMemberDown
          expr: up{job="etcd"} == 0
          for: 1m
          labels:
            severity: critical
            cluster: ${cluster_name}
          annotations:
            summary: "etcd member down on {{ $labels.instance }}"
            description: "An etcd cluster member has been unreachable for 1 minute. Quorum may be at risk."

        - alert: EtcdHighFsyncDuration
          expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
          for: 10m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "High etcd fsync latency (p99 > 500ms) on {{ $labels.instance }}"
            description: "etcd WAL fsync p99 latency is {{ $value | humanizeDuration }}. This may indicate slow storage."

        - alert: EtcdDatabaseSizeHigh
          expr: etcd_mvcc_db_total_size_in_bytes > 7516192768
          for: 5m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "etcd database approaching quota limit on {{ $labels.instance }}"
            description: "etcd DB size is {{ $value | humanize1024 }}. Quota is 8GB."

    # ─── Node Health ──────────────────────────────────────────────────────────
    - name: rke2.nodes
      interval: 30s
      rules:
        - alert: NodeNotReady
          expr: kube_node_status_condition{condition="Ready",status="true"} == 0
          for: 5m
          labels:
            severity: critical
            cluster: ${cluster_name}
          annotations:
            summary: "Node {{ $labels.node }} is not Ready"
            description: "Node {{ $labels.node }} has been in a non-Ready state for 5 minutes."

        - alert: NodeHighCPU
          expr: (1 - avg by(node)(rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.9
          for: 15m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "High CPU usage on node {{ $labels.node }}"
            description: "Node {{ $labels.node }} CPU usage is {{ $value | humanizePercentage }} for 15 minutes."

        - alert: NodeHighMemory
          expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.1
          for: 10m
          labels:
            severity: critical
            cluster: ${cluster_name}
          annotations:
            summary: "Low memory on node {{ $labels.node }}"
            description: "Node {{ $labels.node }} has less than 10% memory available."

        - alert: NodeDiskPressure
          expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.15
          for: 5m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "Low disk space on node {{ $labels.node }}"
            description: "Root filesystem on {{ $labels.node }} has less than 15% free."

        - alert: NodeDiskCritical
          expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.05
          for: 2m
          labels:
            severity: critical
            cluster: ${cluster_name}
          annotations:
            summary: "Critical disk space on {{ $labels.node }}"
            description: "Root filesystem has less than 5% free — IMMEDIATE ACTION REQUIRED."

    # ─── Workload Health ──────────────────────────────────────────────────────
    - name: rke2.workloads
      interval: 30s
      rules:
        - alert: DeploymentReplicasMismatch
          expr: |
            kube_deployment_spec_replicas
              != kube_deployment_status_available_replicas
          for: 10m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has replica mismatch"
            description: "Expected {{ $value }} available replicas but have fewer."

        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 5 > 5
          for: 5m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping"
            description: "Container {{ $labels.container }} restarted more than 5 times in 15 minutes."

        - alert: PVCCapacityHigh
          expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) > 0.85
          for: 5m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is 85% full"
            description: "PVC capacity usage is at {{ $value | humanizePercentage }}."

    # ─── Observability Stack Self-Monitoring ──────────────────────────────────
    - name: observability.self
      interval: 60s
      rules:
        - alert: PrometheusTargetScrapeFailure
          expr: up == 0
          for: 5m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "Prometheus cannot scrape {{ $labels.job }} on {{ $labels.instance }}"

        - alert: LokiRequestErrors
          expr: sum(rate(loki_request_duration_seconds_count{status_code=~"5.."}[5m])) by (route) > 0.1
          for: 5m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "Loki is returning errors on route {{ $labels.route }}"

        - alert: MimirIngestionRateHigh
          expr: sum(rate(cortex_ingester_ingested_samples_total[5m])) > 1000000
          for: 10m
          labels:
            severity: warning
            cluster: ${cluster_name}
          annotations:
            summary: "Mimir ingestion rate is very high (>1M samples/s)"
