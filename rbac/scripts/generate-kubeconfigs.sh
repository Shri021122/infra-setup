#!/usr/bin/env bash
################################################################################
# Generate Role-Specific Kubeconfigs
# Creates a separate kubeconfig for each team persona using certificates.
#
# Each kubeconfig uses a unique client certificate with the user's group
# embedded as the Organization field — matching RBAC group bindings above.
#
# Usage: ./generate-kubeconfigs.sh
# Requires: kubectl with admin access, openssl
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Multi-cluster mode: callers (deploy.sh) pass the cluster name. Falls back to
# inventory.ini's [all:vars] cluster_name for ad-hoc invocations.
CLUSTER_NAME="${1:-${CLUSTER_NAME:-}}"
INVENTORY="${ROOT_DIR}/rke2/configs/inventory.ini"
if [[ -z "$CLUSTER_NAME" ]]; then
  CLUSTER_NAME=$(grep '^cluster_name=' "$INVENTORY" 2>/dev/null | head -1 | cut -d= -f2)
fi
[[ -n "$CLUSTER_NAME" ]] || { echo "ERROR: cluster name not provided. Usage: $0 <cluster-name>"; exit 1; }

# Per-cluster paths
CLUSTER_DIR="${ROOT_DIR}/clusters/${CLUSTER_NAME}"
ADMIN_KUBECONFIG="${CLUSTER_DIR}/kubeconfig.yaml"
KUBECONFIGS_DIR="${CLUSTER_DIR}/rbac-kubeconfigs"
SECRETS_DIR="${ROOT_DIR}/.secrets"     # certs still live here (gitignored)

[[ -f "$ADMIN_KUBECONFIG" ]] || { echo "ERROR: admin kubeconfig not found at $ADMIN_KUBECONFIG"; exit 1; }

mkdir -p "$KUBECONFIGS_DIR" "$SECRETS_DIR/certs"
chmod 700 "$KUBECONFIGS_DIR" "$SECRETS_DIR/certs"

# SSH key for reaching master — read from inventory so it matches what
# cloud-init actually injected into the VM (the tfvars vm_ssh_public_key).
SSH_KEY=$(grep 'ansible_ssh_private_key_file=' "$INVENTORY" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | sed "s|^~|$HOME|")
[[ -f "$SSH_KEY" ]] || SSH_KEY="$HOME/.ssh/rke2_cluster_id"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -i ${SSH_KEY}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Get API server URL from admin kubeconfig
API_SERVER=$(kubectl --kubeconfig "$ADMIN_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl --kubeconfig "$ADMIN_KUBECONFIG" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# ─── Function: create_user_kubeconfig ─────────────────────────────────────────
# Args: username, group, expiry_days
create_user_kubeconfig() {
  local username="$1"
  local group="$2"
  local expiry_days="${3:-365}"
  local cert_dir="${SECRETS_DIR}/certs/${username}"
  local kubeconfig_file="${KUBECONFIGS_DIR}/kubeconfig-${username}.yaml"

  log "Generating kubeconfig for: ${username} (group: ${group}, expiry: ${expiry_days}d)"
  mkdir -p "$cert_dir"

  # Generate private key
  openssl genrsa -out "${cert_dir}/key.pem" 4096 2>/dev/null

  # Generate CSR with group embedded in Organization field
  openssl req -new -key "${cert_dir}/key.pem" \
    -out "${cert_dir}/csr.pem" \
    -subj "/CN=${username}/O=${group}" 2>/dev/null

  # Sign with the cluster CA (extracted from admin kubeconfig)
  echo "$CA_DATA" | base64 -d > "${cert_dir}/ca.crt"

  # Get cluster CA key from master node (requires SSH access)
  # In production, use cert-manager or an external PKI instead
  local master_ip
  master_ip=$(kubectl --kubeconfig "$ADMIN_KUBECONFIG" get nodes \
    -l node-role.kubernetes.io/master=true -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

  log "  Signing certificate via cluster CA on ${master_ip}..."

  # Upload CSR to master and sign it
  scp ${SSH_OPTS} "${cert_dir}/csr.pem" "ubuntu@${master_ip}:/tmp/${username}-csr.pem"
  ssh ${SSH_OPTS} "ubuntu@${master_ip}" "
    sudo openssl x509 -req \
      -in /tmp/${username}-csr.pem \
      -CA /var/lib/rancher/rke2/server/tls/client-ca.crt \
      -CAkey /var/lib/rancher/rke2/server/tls/client-ca.key \
      -CAcreateserial \
      -out /tmp/${username}-cert.pem \
      -days ${expiry_days} \
      -extensions v3_req 2>/dev/null
    sudo cat /tmp/${username}-cert.pem
    sudo rm -f /tmp/${username}-csr.pem /tmp/${username}-cert.pem
  " > "${cert_dir}/cert.pem"

  # Encode credentials as base64
  local client_cert
  client_cert=$(base64 -w0 < "${cert_dir}/cert.pem")
  local client_key
  client_key=$(base64 -w0 < "${cert_dir}/key.pem")

  # Write kubeconfig
  cat > "$kubeconfig_file" << EOF
apiVersion: v1
kind: Config
preferences: {}
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ${username}
    user:
      client-certificate-data: ${client_cert}
      client-key-data: ${client_key}
contexts:
  - name: ${username}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${username}
      namespace: $(get_default_namespace "$group")
current-context: ${username}@${CLUSTER_NAME}
EOF

  chmod 600 "$kubeconfig_file"

  # Clean up CSR (keep cert and key)
  rm -f "${cert_dir}/csr.pem"

  log "  ✓ Kubeconfig: ${kubeconfig_file}"
  log "  ✓ Expires: $(date -d "+${expiry_days} days" '+%Y-%m-%d')"
}

get_default_namespace() {
  case "$1" in
    senior-devops)    echo "default" ;;
    junior-devops)    echo "default" ;;
    developers)       echo "development" ;;
    read-only-auditors) echo "default" ;;
    *)                echo "default" ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  log "=== Generating Role-Based Kubeconfigs ==="
  log "API Server: ${API_SERVER}"
  log ""

  [[ -f "$ADMIN_KUBECONFIG" ]] || { echo "ERROR: Admin kubeconfig not found at ${ADMIN_KUBECONFIG}"; exit 1; }

  # Apply RBAC manifests first
  log "Applying RBAC policies..."
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" apply -f "${SCRIPT_DIR}/../00-namespace-setup.yaml"
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" apply -f "${SCRIPT_DIR}/../01-senior-devops.yaml"
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" apply -f "${SCRIPT_DIR}/../02-junior-devops.yaml"
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" apply -f "${SCRIPT_DIR}/../03-developer.yaml"
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" apply -f "${SCRIPT_DIR}/../04-read-only-auditor.yaml"
  log "✓ RBAC policies applied"
  log ""

  # Generate kubeconfigs per persona
  # Format: username, group (matches RBAC binding), expiry_days
  create_user_kubeconfig "senior-devops-user"    "senior-devops"       365
  create_user_kubeconfig "junior-devops-user"    "junior-devops"       180
  create_user_kubeconfig "developer-user"        "developers"          180
  create_user_kubeconfig "auditor-user"          "read-only-auditors"  90

  log ""
  log "=== Kubeconfig Summary ==="
  echo ""
  printf "%-30s %-25s %-10s %s\n" "FILE" "PERSONA" "EXPIRY" "PERMISSIONS"
  printf "%-30s %-25s %-10s %s\n" "----" "-------" "------" "-----------"
  printf "%-30s %-25s %-10s %s\n" "kubeconfig-senior-devops-user.yaml" "senior-devops"  "365d" "Full cluster (no RBAC write)"
  printf "%-30s %-25s %-10s %s\n" "kubeconfig-junior-devops-user.yaml" "junior-devops"  "180d" "Read/write workloads, no secrets"
  printf "%-30s %-25s %-10s %s\n" "kubeconfig-developer-user.yaml"     "developers"     "180d" "dev namespace full, staging read"
  printf "%-30s %-25s %-10s %s\n" "kubeconfig-auditor-user.yaml"       "read-only"      "90d"  "Full cluster read, no secret data"
  echo ""
  log "Distribute kubeconfigs from: ${KUBECONFIGS_DIR}/"
  log "IMPORTANT: Never commit kubeconfigs or certs to git."
}

main "$@"
