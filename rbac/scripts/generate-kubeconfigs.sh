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
SECRETS_DIR="${SCRIPT_DIR}/../../.secrets"
KUBECONFIGS_DIR="${SCRIPT_DIR}/../kubeconfigs"
ADMIN_KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

mkdir -p "$KUBECONFIGS_DIR" "$SECRETS_DIR/certs"
chmod 700 "$KUBECONFIGS_DIR" "$SECRETS_DIR/certs"

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
  scp -o StrictHostKeyChecking=no "${cert_dir}/csr.pem" "ubuntu@${master_ip}:/tmp/${username}-csr.pem"
  ssh -o StrictHostKeyChecking=no "ubuntu@${master_ip}" "
    sudo openssl x509 -req \
      -in /tmp/${username}-csr.pem \
      -CA /var/lib/rancher/rke2/server/tls/client-ca.crt \
      -CAkey /var/lib/rancher/rke2/server/tls/client-ca.key \
      -CAcreateserial \
      -out /tmp/${username}-cert.pem \
      -days ${expiry_days} \
      -extensions v3_req 2>/dev/null
    cat /tmp/${username}-cert.pem
    rm -f /tmp/${username}-csr.pem /tmp/${username}-cert.pem
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
  - name: rke2-prod
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ${username}
    user:
      client-certificate-data: ${client_cert}
      client-key-data: ${client_key}
contexts:
  - name: ${username}@rke2-prod
    context:
      cluster: rke2-prod
      user: ${username}
      namespace: $(get_default_namespace "$group")
current-context: ${username}@rke2-prod
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
