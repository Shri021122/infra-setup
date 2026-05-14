#!/usr/bin/env bash
################################################################################
# install-alloy.sh — Install Grafana Alloy as a systemd service on a single node
#
# Called by install-master.sh and install-worker.sh after RKE2 is running.
# Alloy runs on the OS (not inside Kubernetes) so one instance per machine
# covers: pod logs, journald, node metrics, etcd metrics (masters only).
#
# Usage (internal — called by install-*.sh scripts):
#   install_alloy <node_ip> <node_role> <ssh_user> <ssh_key>
#   node_role: "master" or "worker"
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/../configs"
SECRETS_DIR="${SCRIPT_DIR}/../../.secrets"

# ─── Load centralized endpoints from observability tfvars ────────────────────
# We read directly from terraform.tfvars so there's one source of truth.
OBS_TFVARS="${SCRIPT_DIR}/../../terraform/observability/terraform.tfvars"

read_tfvar() {
  local key="$1"
  grep "^${key}" "$OBS_TFVARS" 2>/dev/null | \
    sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' '
}

ALLOY_VERSION="v1.2.1"
CLUSTER_NAME=$(read_tfvar "cluster_name")
ENVIRONMENT=$(read_tfvar "environment")
CENTRAL_MIMIR_URL=$(read_tfvar "central_mimir_url")
CENTRAL_MIMIR_USERNAME=$(read_tfvar "central_mimir_username")
CENTRAL_LOKI_URL=$(read_tfvar "central_loki_url")
CENTRAL_LOKI_USERNAME=$(read_tfvar "central_loki_username")
LOKI_TENANT_ID=$(read_tfvar "loki_tenant_id")
[[ -z "$LOKI_TENANT_ID" ]] && LOKI_TENANT_ID="$CLUSTER_NAME"

# Sensitive values from environment variables (same as Terraform)
CENTRAL_MIMIR_PASSWORD="${TF_VAR_central_mimir_password:-}"
CENTRAL_LOKI_PASSWORD="${TF_VAR_central_loki_password:-}"

log() { echo "[$(date '+%H:%M:%S')] [alloy] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# ─── Main install function ────────────────────────────────────────────────────
install_alloy() {
  local node_ip="$1"
  local node_role="$2"      # "master" or "worker"
  local ssh_user="$3"
  local ssh_key="$4"

  local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ${ssh_key}"

  ssh_exec()  { ssh  ${ssh_opts} "${ssh_user}@${node_ip}" "$@"; }
  scp_file()  { scp  ${ssh_opts} "$1" "${ssh_user}@${node_ip}:$2"; }

  log "Installing Grafana Alloy ${ALLOY_VERSION} on ${node_ip} (role: ${node_role})"

  # 1. Add Grafana APT repo and install Alloy
  ssh_exec "
    # Add Grafana apt repo
    mkdir -p /etc/apt/keyrings
    wget -q -O /etc/apt/keyrings/grafana.gpg https://apt.grafana.com/gpg.key
    echo 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' \
      | sudo tee /etc/apt/sources.list.d/grafana.list

    sudo apt-get update -qq
    sudo apt-get install -y alloy
  "

  # 2. Render Alloy config from template — substitute all placeholders
  local rendered_config
  rendered_config=$(sed \
    -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
    -e "s|\${ENVIRONMENT}|${ENVIRONMENT}|g" \
    -e "s|\${NODE_ROLE}|${node_role}|g" \
    -e "s|\${CENTRAL_MIMIR_URL}|${CENTRAL_MIMIR_URL}|g" \
    -e "s|\${CENTRAL_MIMIR_USERNAME}|${CENTRAL_MIMIR_USERNAME}|g" \
    -e "s|\${CENTRAL_MIMIR_PASSWORD}|${CENTRAL_MIMIR_PASSWORD}|g" \
    -e "s|\${CENTRAL_LOKI_URL}|${CENTRAL_LOKI_URL}|g" \
    -e "s|\${CENTRAL_LOKI_USERNAME}|${CENTRAL_LOKI_USERNAME}|g" \
    -e "s|\${CENTRAL_LOKI_PASSWORD}|${CENTRAL_LOKI_PASSWORD}|g" \
    -e "s|\${LOKI_TENANT_ID}|${LOKI_TENANT_ID}|g" \
    "${CONFIGS_DIR}/alloy-config.alloy.tpl"
  )

  # Workers don't have etcd certs — remove the etcd scrape block for workers
  if [[ "$node_role" == "worker" ]]; then
    rendered_config=$(echo "$rendered_config" | \
      awk '/\/\/ ── Kubernetes Component Metrics \(masters only\)/{skip=1} skip && /^}$/{skip=0; next} !skip')
  fi

  # 3. Upload rendered config to node
  echo "$rendered_config" | ssh ${ssh_opts} "${ssh_user}@${node_ip}" \
    "sudo tee /etc/alloy/config.alloy > /dev/null && sudo chmod 640 /etc/alloy/config.alloy"

  # 4. Create Alloy data directory for positions file
  ssh_exec "sudo mkdir -p /var/lib/alloy && sudo chown alloy:alloy /var/lib/alloy 2>/dev/null || true"

  # 5. Override systemd unit to run Alloy with config file and proper user
  ssh_exec "
    sudo mkdir -p /etc/systemd/system/alloy.service.d
    sudo tee /etc/systemd/system/alloy.service.d/override.conf > /dev/null << 'SYSTEMD_EOF'
[Service]
# Run as root so Alloy can read /var/log/pods and /var/log/journal
User=root
Group=root
ExecStart=
ExecStart=/usr/bin/alloy run /etc/alloy/config.alloy \
  --storage.path=/var/lib/alloy \
  --server.http.listen-addr=127.0.0.1:12345 \
  --stability.level=generally-available
SYSTEMD_EOF
  "

  # 6. Enable and start Alloy
  ssh_exec "
    sudo systemctl daemon-reload
    sudo systemctl enable alloy
    sudo systemctl restart alloy
  "

  # 7. Verify Alloy is running
  local retries=0
  until ssh_exec "sudo systemctl is-active alloy 2>/dev/null | grep -q '^active$'"; do
    sleep 5; retries=$((retries+1))
    [[ $retries -lt 12 ]] || { log "WARNING: Alloy not active on ${node_ip} — check: journalctl -u alloy -n 20"; return; }
  done

  log "✓ Alloy running on ${node_ip}"
  log "  Collecting: pod logs + journald → ${CENTRAL_LOKI_URL}"
  log "  Collecting: node metrics       → ${CENTRAL_MIMIR_URL}"
  log "  Query in Grafana: {cluster=\"${CLUSTER_NAME}\", node=\"<hostname>\"}"
}

# ─── Bulk install across all nodes in inventory ───────────────────────────────
install_alloy_all_nodes() {
  local inventory="${CONFIGS_DIR}/inventory.ini"
  [[ -f "$inventory" ]] || err "inventory.ini not found. Run terraform apply first."

  local ssh_user; ssh_user=$(grep 'ansible_user=' "$inventory" | head -1 | cut -d= -f2)
  local ssh_key;  ssh_key=$(grep  'ansible_ssh_private_key_file=' "$inventory" | head -1 | cut -d= -f2 | tr -d '"')

  log "=== Installing Alloy on all cluster nodes ==="

  # Masters
  local in_section=false
  while IFS= read -r line; do
    [[ "$line" =~ ^\[masters\] ]] && { in_section=true; continue; }
    [[ "$line" =~ ^\[ ]] && { in_section=false; continue; }
    [[ "$in_section" == false || -z "$line" ]] && continue
    local node_ip; node_ip=$(echo "$line" | grep -oP 'ansible_host=\K[^ ]+')
    install_alloy "$node_ip" "master" "$ssh_user" "$ssh_key"
  done < "$inventory"

  # Workers
  in_section=false
  while IFS= read -r line; do
    [[ "$line" =~ ^\[workers\] ]] && { in_section=true; continue; }
    [[ "$line" =~ ^\[ ]] && { in_section=false; continue; }
    [[ "$in_section" == false || -z "$line" ]] && continue
    local node_ip; node_ip=$(echo "$line" | grep -oP 'ansible_host=\K[^ ]+')
    install_alloy "$node_ip" "worker" "$ssh_user" "$ssh_key"
  done < "$inventory"

  log ""
  log "=== Alloy installation complete on all nodes ==="
  log ""
  log "Verify in central Loki (Grafana Explore):"
  log "  {cluster=\"${CLUSTER_NAME}\"}"
  log ""
  log "Verify in central Mimir (Grafana Explore):"
  log "  node_cpu_seconds_total{cluster=\"${CLUSTER_NAME}\"}"
}

# Run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_alloy_all_nodes
fi
