# Grafana dashboards built from code

Each script here builds (or rebuilds) a Grafana dashboard via the HTTP API,
using `~/.grafana-url` and `~/.grafana-token` for credentials.

| Script | Builds |
|---|---|
| `build-overview-dashboard.py` | "Overview — dealing cluster" (uid `overview-dealing`) — single-pane-of-glass for daily monitoring. See `docs/monitoring-playbook-dealing.md` for what each panel means. |

To rebuild the dashboard after editing the script:

```bash
python3 monitoring/dashboards/build-overview-dashboard.py
```

The script uses `overwrite: true` so it's safe to re-run — it'll update the
existing dashboard in place. Bump `schemaVersion` if you change major panel
features.
