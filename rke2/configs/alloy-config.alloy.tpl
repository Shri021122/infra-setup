// ============================================================================
// Grafana Alloy Configuration — Per-Node (systemd service on each VM)
// Templated by install-alloy.sh — do not edit on nodes directly.
//
// One Alloy instance per machine collects:
//   1. Pod logs    — reads /var/log/pods/* from this node
//   2. Journald    — rke2-server/agent, containerd, kubelet, kernel
//   3. Node metrics — CPU, RAM, disk, network (replaces node-exporter)
//
// Sends:
//   - Logs    → Central Loki  (tenant: ${CLUSTER_NAME})
//   - Metrics → Central Mimir (labels: cluster, node, environment)
// ============================================================================

// ── Pod Log Discovery ────────────────────────────────────────────────────────
// Discover all container log files on this node without needing K8s API access.
// Path format: /var/log/pods/<namespace>_<pod>_<uid>/<container>/<n>.log

local.file_match "pod_logs" {
  path_targets = [{
    __path__  = "/var/log/pods/*/*/*.log",
    cluster   = "${CLUSTER_NAME}",
    node      = constants.hostname,
  }]
  sync_period = "5s"
}

loki.source.file "pod_logs" {
  targets               = local.file_match.pod_logs.targets
  forward_to            = [loki.process.enrich_pod_logs.receiver]
  legacy_positions_file = "/var/lib/alloy/positions.yaml"
}

// ── Pod Log Enrichment Pipeline ──────────────────────────────────────────────
loki.process "enrich_pod_logs" {

  // Step 1: parse CRI (containerd) log format — adds stream, flags, log fields
  stage.cri {}

  // Step 2: extract namespace / pod / container from the file path
  stage.regex {
    expression = "/var/log/pods/(?P<namespace>[^_/]+)_(?P<pod>[^_/]+)_[^/]+/(?P<container>[^/]+)/[0-9]+\\.log"
    source     = "__path__"
  }
  stage.labels {
    values = {
      namespace = "namespace",
      pod       = "pod",
      container = "container",
    }
  }

  // Step 3: try to parse structured JSON logs — extract level, trace_id
  stage.match {
    selector = `{container!=""}`
    stage.json {
      expressions = {
        level    = "level",
        trace_id = "trace_id",
        msg      = "msg",
      }
    }
    stage.labels {
      values = {
        level    = "level",
        trace_id = "trace_id",
      }
    }
    // Replace log line with the msg field when present (cleaner in Grafana)
    stage.template {
      source   = "msg"
      template = "{{ if .msg }}{{ .msg }}{{ else }}{{ .Value }}{{ end }}"
    }
  }

  // Step 4: drop health-check noise before it reaches central Loki
  stage.drop {
    expression           = `(GET|HEAD) (/healthz|/readyz|/livez|/metrics)`
    drop_counter_reason  = "health_check_noise"
  }

  // Step 5: per-stream rate limit — prevent one noisy pod overwhelming Loki
  stage.limit {
    rate  = 10000   // lines/sec per stream
    burst = 20000
  }

  forward_to = [loki.write.central_loki.receiver]
}

// ── Journald — System & Kubernetes Component Logs ────────────────────────────
// Captures rke2-server, rke2-agent, containerd, kubelet from systemd journal.

loki.source.journal "systemd_logs" {
  max_age    = "12h"
  path       = "/var/log/journal"
  forward_to = [loki.process.enrich_journal_logs.receiver]

  labels = {
    job         = "systemd-journal",
    cluster     = "${CLUSTER_NAME}",
    node        = constants.hostname,
    environment = "${ENVIRONMENT}",
  }
}

loki.process "enrich_journal_logs" {

  // Extract unit name and hostname from journal fields
  stage.json {
    expressions = {
      unit     = "_SYSTEMD_UNIT",
      hostname = "_HOSTNAME",
      priority = "PRIORITY",
    }
  }
  stage.labels {
    values = {
      unit     = "unit",
      node     = "hostname",
    }
  }

  // Map systemd priority number to level name
  stage.template {
    source   = "level"
    template = `{{ if eq .priority "0" }}emergency{{ else if eq .priority "1" }}alert{{ else if eq .priority "2" }}critical{{ else if eq .priority "3" }}error{{ else if eq .priority "4" }}warning{{ else if eq .priority "5" }}notice{{ else if eq .priority "6" }}info{{ else }}debug{{ end }}`
  }
  stage.labels {
    values = { level = "level" }
  }

  // Keep only RKE2-relevant systemd units — drop everything else
  stage.match {
    selector = `{unit!~"(rke2-server|rke2-agent|containerd|kubelet|kube-proxy|docker|crio).service"}`
    action   = "drop"
    drop_counter_reason = "non_k8s_unit"
  }

  forward_to = [loki.write.central_loki.receiver]
}

// ── Node Metrics (replaces node-exporter DaemonSet) ─────────────────────────
// prometheus.exporter.unix exposes the same metrics as node_exporter.
// Running on the host OS gives more accurate disk/network/filesystem metrics
// than a containerized exporter.

prometheus.exporter.unix "this_node" {
  // Exclude virtual/container filesystems from disk metrics
  filesystem {
    fs_types_exclude     = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
    mount_points_exclude = "^/(dev|proc|run/credentials/.+|sys|var/lib/docker/.+|var/lib/containers/.+|run/containerd/.+)($|/)"
  }
  // Filter out virtual/container network interfaces
  netclass {
    ignored_devices = "^(veth|cni|flannel|cilium|lxc|dummy|br-|docker|lo).*"
  }
  netdev {
    device_exclude = "^(veth|cni|flannel|cilium|lxc|dummy|br-|docker|lo).*"
  }
  // Collectors to disable (noisy/unused on VMs)
  disable_collectors = ["wifi", "thermal_zone", "hwmon", "powersupplyclass"]
}

prometheus.scrape "node_metrics" {
  targets         = prometheus.exporter.unix.this_node.targets
  forward_to      = [prometheus.relabel.add_instance.receiver]
  scrape_interval = "15s"
  scrape_timeout  = "10s"
}

// Add instance label = node hostname (for Grafana node-exporter dashboards).
// Chained between the scrape and remote_write because Alloy ≥1.0 dropped the
// inline `extra_metrics_relabel_rules` attribute on prometheus.scrape — you
// pipe through a prometheus.relabel component now.
prometheus.relabel "add_instance" {
  forward_to = [prometheus.remote_write.central_mimir.receiver]

  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
}

// ── Kubernetes Component Metrics (masters only) ───────────────────────────────
// Scrape etcd, API server, controller-manager, scheduler metrics on masters.
// On workers this section has no targets and is a no-op.

prometheus.scrape "etcd_metrics" {
  targets = [
    {"__address__" = "localhost:2381"},   // etcd metrics port
  ]
  forward_to      = [prometheus.remote_write.central_mimir.receiver]
  scrape_interval = "30s"

  tls_config {
    ca_file   = "/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt"
    cert_file = "/var/lib/rancher/rke2/server/tls/etcd/client.crt"
    key_file  = "/var/lib/rancher/rke2/server/tls/etcd/client.key"
  }
}

// ── Central Mimir Remote Write ───────────────────────────────────────────────

prometheus.remote_write "central_mimir" {
  endpoint {
    url = "${CENTRAL_MIMIR_URL}"

    // Basic auth — leave username empty if your Mimir has no auth
    basic_auth {
      username = "${CENTRAL_MIMIR_USERNAME}"
      password = "${CENTRAL_MIMIR_PASSWORD}"
    }

    queue_config {
      max_samples_per_send = 10000
      batch_send_deadline  = "5s"
      min_backoff          = "30ms"
      max_backoff          = "5s"
      capacity             = 10000
    }

    write_relabel_config {
      // Drop high-cardinality go runtime metrics to save Mimir cardinality
      source_labels = ["__name__"]
      regex         = "go_gc_.*|go_memstats_(alloc|frees|lookups)_total"
      action        = "drop"
    }
  }

  // Labels attached to every metric from this node.
  // Use `cluster_name` (NOT `cluster`) so node metrics align with the
  // in-cluster Prometheus's external_labels (kube_prometheus_stack values
  // set externalLabels.cluster_name=<cluster>). Single label across all
  // metric sources lets dashboards filter consistently.
  external_labels = {
    cluster_name = "${CLUSTER_NAME}",
    node         = constants.hostname,
    environment  = "${ENVIRONMENT}",
    role         = "${NODE_ROLE}",   // "master" or "worker"
  }
}

// ── Central Loki Write ────────────────────────────────────────────────────────

loki.write "central_loki" {
  endpoint {
    url = "${CENTRAL_LOKI_URL}/loki/api/v1/push"

    basic_auth {
      username = "${CENTRAL_LOKI_USERNAME}"
      password = "${CENTRAL_LOKI_PASSWORD}"
    }

    tenant_id = "${LOKI_TENANT_ID}"

    // Batch settings — tune based on network latency to central Loki.
    // batch_size moved from raw int to units-typed string in Alloy ≥1.0.
    batch_wait = "1s"
    batch_size = "1MiB"
  }

  // Labels on every log line from this node
  external_labels = {
    cluster     = "${CLUSTER_NAME}",
    node        = constants.hostname,
    environment = "${ENVIRONMENT}",
  }
}
