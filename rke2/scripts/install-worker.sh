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
INIT_MASTER_IP=$(awk '/^\[masters\]/{f=1; next} /^\[/{f=0} f && /is_init_node=true/' "$INVENTORY" | grep -oP 'ansible_host=\K[^ ]+' | head -1)
RKE2_VERSION=$(grep 'rke2_version=' "$INVENTORY" | head -1 | cut -d= -f2)
CLUSTER_TOKEN=$(cat "${SECRETS_DIR}/rke2-cluster-token")

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ${SSH_KEY}"

ssh_exec() { ssh -n ${SSH_OPTS} "${SSH_USER}@$1" "${@:2}"; }
scp_file() { scp ${SSH_OPTS} "$1" "${SSH_USER}@$2:$3"; }

worker_is_ready() {
  local node_ip="$1"
  ssh -n ${SSH_OPTS} "${SSH_USER}@${node_ip}" "
    sudo systemctl is-active rke2-agent 2>/dev/null | grep -qw active
  " 2>/dev/null
}
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

install_worker() {
  local node_ip="$1"
  local node_index="$2"
  local config_file="${CONFIGS_DIR}/worker-$((node_index + 1))-config.yaml"

  [[ -f "$config_file" ]] || err "Config not found: ${config_file}"

  if worker_is_ready "$node_ip"; then
    log "✓ Worker ${node_ip} already has active rke2-agent — skipping install"
    return 0
  fi

  log "Installing RKE2 agent on worker ${node_ip}..."

  # Upload config (patched: join via init master direct IP, not VIP;
  # strip kubernetes.io/* self-labels which kubelet's NodeRestriction blocks)
  local patched_config="/tmp/rke2-worker-patched-$$.yaml"
  sed -e "s|https://${CONTROL_PLANE_VIP}:9345|https://${INIT_MASTER_IP}:9345|" \
      -e '/node-role\.kubernetes\.io\/worker/d' \
      "$config_file" > "$patched_config"
  ssh_exec "$node_ip" "sudo mkdir -p /etc/rancher/rke2"
  scp_file "$patched_config" "$node_ip" "/tmp/rke2-config.yaml"
  rm -f "$patched_config"
  ssh_exec "$node_ip" "sudo mv /tmp/rke2-config.yaml /etc/rancher/rke2/config.yaml && sudo chmod 600 /etc/rancher/rke2/config.yaml"

  # Stop any running rke2-agent so we don't fight an existing failed start
  ssh_exec "$node_ip" "sudo systemctl stop rke2-agent 2>/dev/null || true"

  # Inject token into config.yaml (RKE2 requires it there, not in a separate file)
  ssh_exec "$node_ip" "
    sudo sed -i '/^token:/d' /etc/rancher/rke2/config.yaml
    echo 'token: ${CLUSTER_TOKEN}' | sudo tee -a /etc/rancher/rke2/config.yaml > /dev/null
  "

  # Install RKE2 agent
  ssh_exec "$node_ip" "
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION='${RKE2_VERSION}' INSTALL_RKE2_TYPE='agent' sh -
  "

  # Apply kernel settings required by kubelet protect-kernel-defaults.
  # kubelet refuses to start unless these match its expected defaults.
  ssh_exec "$node_ip" "
    sudo sysctl -w kernel.panic=10 vm.overcommit_memory=1 vm.panic_on_oom=0 kernel.panic_on_oops=1
    for kv in 'kernel.panic=10' 'kernel.panic_on_oops=1' 'vm.overcommit_memory=1' 'vm.panic_on_oom=0'; do
      grep -qxF \"\$kv\" /etc/sysctl.d/99-rke2.conf 2>/dev/null || echo \"\$kv\" | sudo tee -a /etc/sysctl.d/99-rke2.conf >/dev/null
    done
    sudo sysctl --system >/dev/null
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

  # Apply worker role label via kubectl (kubelet can't self-apply kubernetes.io/* labels)
  kubectl --kubeconfig "$kubeconfig" label node "$node_name" \
    node-role.kubernetes.io/worker=true --overwrite >/dev/null 2>&1 || true
  log "  Labeled ${node_name} with node-role.kubernetes.io/worker=true"
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

  # Install Grafana Alloy on every node — masters AND workers (OS-level, systemd).
  # Alloy collects pod logs + journald + node metrics on every VM; on masters
  # it also scrapes etcd. install-master.sh has no alloy step, so we cover the
  # whole cluster here at the end of Phase 3.
  log ""
  log "=== Installing Grafana Alloy on every node (masters + workers) ==="
  # shellcheck source=install-alloy.sh
  source "${SCRIPT_DIR}/install-alloy.sh"
  install_alloy_all_nodes
}

main "$@"
