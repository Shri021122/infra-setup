#!/usr/bin/env bash
################################################################################
# RKE2 Worker Node Installation Script
# Run AFTER install-master.sh has completed successfully.
# Idempotent: safe to re-run or use to add new workers.
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/../configs"
SECRETS_DIR="${SCRIPT_DIR}/../../.secrets"

INVENTORY="${CONFIGS_DIR}/inventory.ini"
[[ -f "$INVENTORY" ]] || { echo "ERROR: inventory.ini not found."; exit 1; }
[[ -f "${SECRETS_DIR}/rke2-cluster-token" ]] || { echo "ERROR: Cluster token not found. Run install-master.sh first."; exit 1; }

SSH_USER=$(grep 'ansible_user=' "$INVENTORY" | head -1 | cut -d= -f2)
SSH_KEY=$(grep 'ansible_ssh_private_key_file=' "$INVENTORY" | head -1 | cut -d= -f2 | tr -d '"')
CONTROL_PLANE_VIP=$(grep 'control_plane_vip=' "$INVENTORY" | head -1 | cut -d= -f2)
RKE2_VERSION=$(grep 'rke2_version=' "$INVENTORY" | head -1 | cut -d= -f2)
CLUSTER_TOKEN=$(cat "${SECRETS_DIR}/rke2-cluster-token")

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ${SSH_KEY}"

ssh_exec() { ssh ${SSH_OPTS} "${SSH_USER}@$1" "${@:2}"; }
scp_file() { scp ${SSH_OPTS} "$1" "${SSH_USER}@$2:$3"; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

install_worker() {
  local node_ip="$1"
  local node_index="$2"
  local config_file="${CONFIGS_DIR}/worker-$((node_index + 1))-config.yaml"

  [[ -f "$config_file" ]] || err "Config not found: ${config_file}"

  log "Installing RKE2 agent on worker ${node_ip}..."

  # Upload config
  ssh_exec "$node_ip" "sudo mkdir -p /etc/rancher/rke2"
  scp_file "$config_file" "$node_ip" "/tmp/rke2-config.yaml"
  ssh_exec "$node_ip" "sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml && sudo chmod 600 /etc/rancher/rke2/config.yaml"

  # Set cluster token
  ssh_exec "$node_ip" "echo '${CLUSTER_TOKEN}' | sudo tee /etc/rancher/rke2/token > /dev/null && sudo chmod 600 /etc/rancher/rke2/token"

  # Install RKE2 agent
  ssh_exec "$node_ip" "
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION='${RKE2_VERSION}' INSTALL_RKE2_TYPE='agent' sh -
  "

  # Apply kernel settings required by kubelet protect-kernel-defaults
  ssh_exec "$node_ip" "
    sudo sysctl -w kernel.panic=10
    sudo sysctl -w kernel.panic_on_oops=1
    echo 'kernel.panic=10' | sudo tee -a /etc/sysctl.d/99-rke2.conf
    echo 'kernel.panic_on_oops=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf
    sudo sysctl --system
  "

  # Enable and start
  ssh_exec "$node_ip" "
    sudo systemctl daemon-reload
    sudo systemctl enable rke2-agent
    sudo systemctl start rke2-agent
  "

  # Wait for node to appear in cluster
  log "Waiting for worker ${node_ip} to join the cluster..."
  local kubeconfig="${SECRETS_DIR}/kubeconfig-admin.yaml"
  local node_name
  node_name=$(grep -A5 "ansible_host=${node_ip}" "$INVENTORY" | head -1 | awk '{print $1}')

  local max_wait=300
  local waited=0
  while ! kubectl --kubeconfig "$kubeconfig" get node "$node_name" 2>/dev/null | grep -q Ready; do
    sleep 10
    waited=$((waited + 10))
    [[ $waited -lt $max_wait ]] || { log "WARNING: Timeout waiting for ${node_name}; check manually"; return; }
    log "  Still waiting for ${node_name}... (${waited}/${max_wait}s)"
  done

  log "✓ Worker ${node_name} (${node_ip}) is Ready"
}

main() {
  log "=== RKE2 Worker Installation ==="

  # Parse worker IPs from inventory
  local in_workers=false
  local idx=0
  while IFS= read -r line; do
    [[ "$line" =~ ^\[workers\] ]] && { in_workers=true; continue; }
    [[ "$line" =~ ^\[ ]] && { in_workers=false; continue; }
    [[ "$in_workers" == false || -z "$line" ]] && continue

    local node_ip
    node_ip=$(echo "$line" | grep -oP 'ansible_host=\K[^ ]+')
    install_worker "$node_ip" "$idx"
    idx=$((idx + 1))
  done < "$INVENTORY"

  log ""
  log "=== All worker nodes installed successfully ==="
  log ""

  # Display cluster status
  if command -v kubectl &>/dev/null && [[ -f "${SECRETS_DIR}/kubeconfig-admin.yaml" ]]; then
    kubectl --kubeconfig "${SECRETS_DIR}/kubeconfig-admin.yaml" get nodes -o wide
  fi

  # Install Grafana Alloy on all worker nodes (OS-level, systemd service)
  # Alloy collects: pod logs, journald, node metrics for each worker
  log ""
  log "=== Installing Grafana Alloy on worker nodes ==="
  # shellcheck source=install-alloy.sh
  source "${SCRIPT_DIR}/install-alloy.sh"

  local in_workers=false
  while IFS= read -r line; do
    [[ "$line" =~ ^\[workers\] ]] && { in_workers=true; continue; }
    [[ "$line" =~ ^\[ ]]         && { in_workers=false; continue; }
    [[ "$in_workers" == false || -z "$line" ]] && continue
    local node_ip; node_ip=$(echo "$line" | grep -oP 'ansible_host=\K[^ ]+')
    install_alloy "$node_ip" "worker" "$SSH_USER" "$SSH_KEY"
  done < "$INVENTORY"
}

main "$@"
