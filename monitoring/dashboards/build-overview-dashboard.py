#!/usr/bin/env python3
"""Build the 'Overview — dealing cluster' dashboard.

Design: one screen the monitoring person opens every morning. If
all green, the cluster is fine; if anything is amber/red, drill into
the linked detail dashboard.

Layout (24-column Grafana grid):

Row 1 — status stats (4w each, 6 panels)
  Nodes | EtcdLeader | RunningPods | API p99 | CPU% | Mem%

Row 2 — control-plane trends (12w each, 2 panels)
  Etcd WAL fsync p99 + DB size                      | Apiserver req rate by code

Row 3 — workload signals (8w each, 3 panels)
  OOM events by ns | Restarts by ns | CPU throttling by ns

Row 4 — network (12w each, 2 panels)
  Cilium drops by reason | HTTP responses by status
"""
import json, os, urllib.request, urllib.error

GRAFANA_URL = open(os.path.expanduser("~/.grafana-url")).read().strip()
TOKEN = open(os.path.expanduser("~/.grafana-token")).read().strip()
MIMIR_DS = {"type": "prometheus", "uid": "ff37820pkxr7kf"}
FOLDER_UID = "efmm2ry0na8e8a"  # new-kube-cluster

panel_id = 0
def next_id():
    global panel_id
    panel_id += 1
    return panel_id

def stat(title, gp, expr, unit, thresholds, decimals=0, description=""):
    return {
        "id": next_id(), "type": "stat", "title": title, "gridPos": gp,
        "datasource": MIMIR_DS, "description": description,
        "targets": [{"datasource": MIMIR_DS, "expr": expr, "instant": True, "refId": "A"}],
        "fieldConfig": {
            "defaults": {"unit": unit, "decimals": decimals,
                "thresholds": {"mode": "absolute", "steps": thresholds},
                "color": {"mode": "thresholds"}},
            "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "textMode": "auto", "colorMode": "background", "graphMode": "area",
                    "justifyMode": "center", "orientation": "auto"},
    }

def ts(title, gp, targets, unit="short", legend_calcs=("mean","lastNotNull","max"),
       thresholds=None, description=""):
    fc = {"defaults": {"unit": unit, "custom": {"drawStyle": "line", "lineWidth": 2,
            "fillOpacity": 8, "spanNulls": True, "showPoints": "never"}}}
    if thresholds:
        fc["defaults"]["thresholds"] = {"mode": "absolute", "steps": thresholds}
        fc["defaults"]["custom"]["thresholdsStyle"] = {"mode": "line"}
        fc["defaults"]["color"] = {"mode": "thresholds"}
    return {
        "id": next_id(), "type": "timeseries", "title": title, "gridPos": gp,
        "datasource": MIMIR_DS, "description": description,
        "targets": [{"datasource": MIMIR_DS, "expr": e, "legendFormat": l, "refId": chr(65+i)}
                    for i, (e, l) in enumerate(targets)],
        "fieldConfig": fc,
        "options": {
            "legend": {"showLegend": True, "displayMode": "table",
                       "placement": "bottom", "calcs": list(legend_calcs)},
            "tooltip": {"mode": "multi", "sort": "desc"}},
    }

green = {"color": "green", "value": None}
yellow = lambda v: {"color": "yellow", "value": v}
red = lambda v: {"color": "red", "value": v}
green_v = lambda v: {"color": "green", "value": v}
# Note: thresholds are in ASCENDING order, value < step uses the previous color

CLUSTER = '"$cluster"'

# ======================================================================
# Row 1 — status gauges (y=0, h=4)
# ======================================================================
row1 = [
    stat("Nodes",
        {"x": 0, "y": 0, "w": 4, "h": 4},
        f'count(kube_node_info{{cluster_name={CLUSTER}}})',
        unit="short",
        thresholds=[red(None), yellow(5), {"color":"green","value":6}],
        description="Number of nodes the cluster sees. Anything <6 = a node fell out. Drill: K8s Views Global → CPU/Memory by instance."),
    stat("Etcd Leader",
        {"x": 4, "y": 0, "w": 4, "h": 4},
        f'max(etcd_server_has_leader{{cluster_name={CLUSTER}}})',
        unit="short",
        thresholds=[red(None), green_v(1)],
        description="1 = healthy. 0 = no leader = cluster API is read-only. Page immediately. Drill: Etcd by Prometheus."),
    stat("Running Pods",
        {"x": 8, "y": 0, "w": 4, "h": 4},
        f'sum(kube_pod_status_phase{{phase="Running", cluster_name={CLUSTER}}})',
        unit="short",
        thresholds=[green],
        description="Total Running pods. Sudden drops indicate eviction or mass restart."),
    stat("API avg latency",
        {"x": 12, "y": 0, "w": 4, "h": 4},
        f'sum(rate(apiserver_request_duration_seconds_sum{{cluster_name={CLUSTER},verb!~"WATCH|CONNECT"}}[5m])) / sum(rate(apiserver_request_duration_seconds_count{{cluster_name={CLUSTER},verb!~"WATCH|CONNECT"}}[5m]))',
        unit="s", decimals=3,
        thresholds=[green, yellow(0.1), red(0.5)],
        description="Average apiserver request latency (excludes WATCH/CONNECT). Avg, not p99, because *_bucket series are dropped at remote-write. >500ms sustained = control plane stress. Drill: Etcd by Prometheus."),
    stat("Cluster CPU %",
        {"x": 16, "y": 0, "w": 4, "h": 4},
        f'100 * (1 - avg(rate(node_cpu_seconds_total{{cluster_name={CLUSTER}, mode="idle"}}[5m])))',
        unit="percent", decimals=1,
        thresholds=[green, yellow(60), red(85)],
        description="Cluster-wide CPU utilization. Above 85% sustained = no headroom for spikes."),
    stat("Cluster Memory %",
        {"x": 20, "y": 0, "w": 4, "h": 4},
        f'100 * (1 - sum(node_memory_MemAvailable_bytes{{cluster_name={CLUSTER}}}) / sum(node_memory_MemTotal_bytes{{cluster_name={CLUSTER}}}))',
        unit="percent", decimals=1,
        thresholds=[green, yellow(75), red(90)],
        description="Memory used as % of cluster total. Above 90% = eviction imminent."),
]

# ======================================================================
# Row 2 — control plane (y=4, h=8)
# ======================================================================
row2 = [
    ts("Etcd Disk Latency (WAL fsync p99) + DB size",
        {"x": 0, "y": 4, "w": 12, "h": 8},
        [
            ('histogram_quantile(0.99, sum by (le, instance) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{cluster="dealing"}[5m])))',
             "fsync p99 — {{instance}}"),
            ('etcd_mvcc_db_total_size_in_bytes{cluster="dealing"} / 1024 / 1024 / 1024',
             "db size GiB — {{instance}}"),
        ],
        unit="s",
        thresholds=[green, yellow(0.05), red(0.1)],
        description="WAL fsync p99 should be <30 ms; >100 ms = disk degrading. DB size grows toward the 8 GiB quota — alert at ~6.5 GiB. Note: etcd metrics carry 'cluster' (not cluster_name)."),
    ts("API Request Rate by code",
        {"x": 12, "y": 4, "w": 12, "h": 8},
        [
            (f'sum by (code) (rate(apiserver_request_total{{cluster_name={CLUSTER}}}[5m]))',
             "{{code}}"),
        ],
        unit="reqps",
        description="API server request rate, broken down by HTTP status code. Sustained 5xx rate = control plane in trouble. 4xx may be legitimate (RBAC denials)."),
]

# ======================================================================
# Row 3 — workload signals (y=12, h=8)
# ======================================================================
row3 = [
    ts("OOM events by namespace (last 1h)",
        {"x": 0, "y": 12, "w": 8, "h": 8},
        [
            (f'sum by (namespace) (increase(container_oom_events_total{{cluster_name={CLUSTER}}}[1h]))',
             "{{namespace}}"),
        ],
        unit="short",
        thresholds=[green, red(1)],
        description="Any non-zero = at least one container was killed for memory in the last hour. Find the pod with `kubectl get events -A | grep OOM`."),
    ts("Container Restarts by namespace (last 1h)",
        {"x": 8, "y": 12, "w": 8, "h": 8},
        [
            (f'sum by (namespace) (increase(kube_pod_container_status_restarts_total{{cluster_name={CLUSTER}}}[1h]))',
             "{{namespace}}"),
        ],
        unit="short",
        thresholds=[green, yellow(1), red(5)],
        description="Restart counter increase over 1h. Sustained restarts = CrashLoopBackOff. Drill: kubectl logs --previous."),
    ts("CPU throttling by namespace",
        {"x": 16, "y": 12, "w": 8, "h": 8},
        [
            (f'sum by (namespace) (rate(container_cpu_cfs_throttled_seconds_total{{cluster_name={CLUSTER}}}[5m]))',
             "{{namespace}}"),
        ],
        unit="s",
        thresholds=[green, yellow(0.1)],
        description="Per-namespace CPU throttling rate. Sustained >0 = the namespace's containers are hitting their CPU limits. Raise the limit or fix the app."),
]

# ======================================================================
# Row 4 — networking (y=20, h=8)
# ======================================================================
row4 = [
    ts("Cilium Packet Drops by reason",
        {"x": 0, "y": 20, "w": 12, "h": 8},
        [
            (f'sum by (reason) (rate(cilium_drop_count_total{{cluster_name={CLUSTER}}}[5m]))',
             "{{reason}}"),
        ],
        unit="pps",
        thresholds=[green, yellow(10), red(100)],
        description="Packets dropped per second, by reason. Any sustained 'policy-deny' is suspicious. Drill: Hubble Metrics dashboard or `hubble observe --verdict DROPPED`."),
    ts("HTTP Responses by status (Ingress)",
        {"x": 12, "y": 20, "w": 12, "h": 8},
        [
            (f'sum by (status) (rate(hubble_http_responses_total{{cluster_name={CLUSTER}}}[5m]))',
             "{{status}}"),
        ],
        unit="reqps",
        thresholds=[green, yellow(1), red(10)],
        description="Responses served by Cilium IngressController Envoy. 2xx = healthy, 4xx may be normal (401 auth, 404 misroute), sustained 5xx = backend in trouble."),
]

# ======================================================================
# Templating
# ======================================================================
cluster_var = {
    "name": "cluster", "label": "Cluster", "type": "query",
    "datasource": MIMIR_DS,
    "query": {"qryType": 1, "query": "label_values(kube_node_info, cluster_name)",
              "refId": "PrometheusVariableQueryEditor-VariableQuery"},
    "definition": "label_values(kube_node_info, cluster_name)",
    "includeAll": False, "multi": False, "refresh": 1, "regex": "", "sort": 1,
    "current": {"text": "dealing", "value": "dealing", "selected": True},
    "options": [], "hide": 0,
}

dashboard = {
    "uid": "overview-dealing",
    "title": "Overview — dealing cluster",
    "tags": ["overview", "dealing", "single-pane"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 0,
    "refresh": "30s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": [cluster_var]},
    "panels": row1 + row2 + row3 + row4,
    "links": [
        {"title": "K8s Views Global", "type": "dashboards", "tags": [], "icon": "external link",
         "asDropdown": False, "url": "/d/k8s_views_global1"},
        {"title": "Etcd by Prometheus", "type": "link",
         "url": "/d/e3541fb8-ca34-46cf-af8f-cb716e0a91f8"},
        {"title": "Cilium Metrics", "type": "link", "url": "/d/vtuWtdumz"},
        {"title": "Hubble Metrics", "type": "link", "url": "/d/5HftnJAWz"},
    ],
    "description": (
        "Single-pane-of-glass overview for the `dealing` cluster.\n\n"
        "Open this every morning. If everything's green, the cluster is healthy. "
        "If anything is amber/red, click the corresponding detail dashboard at the top "
        "(K8s Views Global / Etcd / Cilium Metrics / Hubble Metrics) and follow "
        "monitoring-playbook-dealing.md §4 (incident workflow).\n\n"
        "Thresholds tuned to cluster size: 30 vCPU, ~70 GiB RAM, 6 nodes."),
}

payload = {"dashboard": dashboard, "folderUid": FOLDER_UID, "overwrite": True,
           "message": "Initial Overview dashboard — single pane of glass for daily monitoring"}
req = urllib.request.Request(
    f"{GRAFANA_URL}/api/dashboards/db",
    data=json.dumps(payload).encode(),
    headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    method="POST")
try:
    with urllib.request.urlopen(req) as r:
        result = json.loads(r.read())
        print(f"saved: uid={result.get('uid')} url={GRAFANA_URL}{result.get('url')} version={result.get('version')}")
except urllib.error.HTTPError as e:
    raise RuntimeError(f"HTTP {e.code}: {e.read().decode()}")
