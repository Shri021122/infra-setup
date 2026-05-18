#!/usr/bin/env bash
################################################################################
# new-cluster.sh — Scaffold a new cluster directory under clusters/<name>/
#
# Interactive wizard that fills in proxmox.tfvars / observability.tfvars /
# argocd.tfvars based on prompts. Does NOT deploy — that's deploy.sh's job.
#
# Usage:
#   ./scripts/new-cluster.sh <cluster-name>
#   ./scripts/new-cluster.sh acme-prod --non-interactive   # use only defaults
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTERS_DIR="${ROOT_DIR}/clusters"
TEMPLATE_DIR="${CLUSTERS_DIR}/_template"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
log()  { echo -e "${GREEN}[wizard]${NC} $*"; }
hdr()  { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }

# ─── Args ─────────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || { echo "Usage: $0 <cluster-name>"; exit 1; }
CLUSTER_NAME="$1"; shift
NON_INTERACTIVE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    *) err "Unknown arg: $1" ;;
  esac
done

# Validate cluster name (DNS-safe)
[[ "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
  err "Cluster name must be lowercase letters/digits/hyphens, start+end alnum: '${CLUSTER_NAME}'"

CLUSTER_DIR="${CLUSTERS_DIR}/${CLUSTER_NAME}"
if [[ -e "$CLUSTER_DIR" ]]; then
  err "${CLUSTER_DIR} already exists. Delete it first or pick a different name."
fi
[[ -d "$TEMPLATE_DIR" ]] || err "Template not found: ${TEMPLATE_DIR}"

# ─── Prompt helper ────────────────────────────────────────────────────────────
# ask <prompt> <default> -> echoes the answer. With --non-interactive, returns default.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    echo "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "  ${prompt} [${default}]: " reply
    echo "${reply:-$default}"
  else
    while true; do
      read -r -p "  ${prompt}: " reply
      [[ -n "$reply" ]] && { echo "$reply"; return; }
      echo "  (required — please enter a value)"
    done
  fi
}

# Derive default IP list from a /24 subnet base.
# Args: subnet_cidr (e.g. 10.20.0.0/24), start_octet, count
# Prints: comma-separated IPs.
derive_ips() {
  local cidr="$1" start="$2" count="$3"
  local base="${cidr%.*}"   # 10.20.0
  local ips=""
  for ((i=0; i<count; i++)); do
    ips+="${base}.$((start+i))"
    [[ $i -lt $((count-1)) ]] && ips+=","
  done
  echo "$ips"
}

cat <<EOF

${BOLD}${CYAN}╔══════════════════════════════════════════════════╗
║   New Cluster Wizard — ${CLUSTER_NAME}
╚══════════════════════════════════════════════════╝${NC}

This wizard writes config to ${CYAN}${CLUSTER_DIR}/${NC} (does NOT deploy).
Hit ${BOLD}Enter${NC} on any prompt to accept the [default].

EOF

# ─── Identity ─────────────────────────────────────────────────────────────────
hdr "Identity"
ENVIRONMENT=$(ask "Environment" "production")

# ─── Network ──────────────────────────────────────────────────────────────────
hdr "Network"
SUBNET_CIDR=$(ask "Subnet CIDR (e.g. 10.20.0.0/24)" "10.20.0.0/24")
BASE="${SUBNET_CIDR%.*}"           # e.g. 10.20.0
NETWORK_BRIDGE=$(ask "Proxmox network bridge" "vmbrk8s")
NETWORK_GATEWAY=$(ask "Network gateway" "${BASE}.1")
DNS_SERVERS=$(ask "DNS servers (comma)" "${BASE}.1, 8.8.8.8")
DOMAIN_NAME=$(ask "Internal domain" "cluster.internal")
CONTROL_PLANE_VIP=$(ask "Control-plane VIP (free IP)" "${BASE}.100")
LB_POOL_CIDR=$(ask "Ingress LB pool CIDR (/32 = one IP)" "${BASE}.200/32")

# ─── Proxmox ──────────────────────────────────────────────────────────────────
hdr "Proxmox connection"
PROXMOX_API_URL=$(ask "Proxmox API URL" "https://10.10.16.249:8006/api2/json")
PROXMOX_NODE=$(ask "Proxmox node name" "pve-4")
TEMPLATE_VM_ID=$(ask "Cloud-init template VM ID" "9200")
DISK_STORAGE=$(ask "Disk storage pool" "pve-4-storage")
SNIPPET_FILE_ID=$(ask "Shared cloud-init snippet (leave empty to skip)" "local:snippets/k8s-common.yaml")

# ─── Masters ──────────────────────────────────────────────────────────────────
hdr "Masters"
MASTER_COUNT=$(ask "Number of masters (odd: 1, 3, 5)" "3")
[[ $((MASTER_COUNT % 2)) -eq 1 ]] || err "Master count must be ODD (etcd quorum)."
MASTER_IPS=$(ask "Master IPs (comma)" "$(derive_ips "$SUBNET_CIDR" 101 "$MASTER_COUNT")")
MASTER_VM_ID_START=$(ask "Proxmox VM ID for first master (must not clash with other clusters)" "401")
MASTER_CPU=$(ask "Master CPU cores" "2")
MASTER_RAM=$(ask "Master RAM (MB)" "8192")
MASTER_DISK=$(ask "Master OS disk (GB)" "50")
MASTER_ETCD_DISK=$(ask "Master etcd disk (GB)" "20")

# ─── Workers ──────────────────────────────────────────────────────────────────
hdr "Workers"
WORKER_COUNT=$(ask "Number of workers" "3")
WORKER_IPS=$(ask "Worker IPs (comma)" "$(derive_ips "$SUBNET_CIDR" 111 "$WORKER_COUNT")")
# Default = first ID *after* the master block, leaving a gap (master_start + 9).
# E.g. masters 421..423 → workers default to 430+.
WORKER_VM_ID_DEFAULT=$((MASTER_VM_ID_START + 9))
WORKER_VM_ID_START=$(ask "Proxmox VM ID for first worker (must not clash with other clusters)" "$WORKER_VM_ID_DEFAULT")
WORKER_CPU=$(ask "Worker CPU cores" "8")
WORKER_RAM=$(ask "Worker RAM (MB)" "16384")
WORKER_DISK=$(ask "Worker OS disk (GB)" "100")
WORKER_DATA_DISK=$(ask "Worker data disk (GB)" "200")

# Validate VM ID ranges don't overlap each other on this same cluster
MASTER_VM_ID_END=$((MASTER_VM_ID_START + MASTER_COUNT - 1))
WORKER_VM_ID_END=$((WORKER_VM_ID_START + WORKER_COUNT - 1))
if [[ "$WORKER_VM_ID_START" -le "$MASTER_VM_ID_END" && "$WORKER_VM_ID_END" -ge "$MASTER_VM_ID_START" ]]; then
  err "Master VM IDs (${MASTER_VM_ID_START}-${MASTER_VM_ID_END}) overlap worker VM IDs (${WORKER_VM_ID_START}-${WORKER_VM_ID_END}). Pick non-overlapping ranges."
fi

# ─── SSH ──────────────────────────────────────────────────────────────────────
hdr "SSH key (for VM access)"
SSH_KEY_PATH=$(ask "SSH private key path" "~/.ssh/rke2_cluster_id")
SSH_KEY_FILE="${SSH_KEY_PATH/#\~/$HOME}"
if [[ ! -f "$SSH_KEY_FILE" ]]; then
  log "${YELLOW}WARNING: ${SSH_KEY_FILE} not found.${NC} Generate it with:"
  log "  ssh-keygen -t ed25519 -f ${SSH_KEY_FILE} -C 'rke2-cluster-deploy' -N ''"
fi
SSH_PUBKEY_FILE="${SSH_KEY_FILE}.pub"
if [[ -f "$SSH_PUBKEY_FILE" ]]; then
  SSH_PUBKEY=$(<"$SSH_PUBKEY_FILE")
  log "Using public key from ${SSH_PUBKEY_FILE}"
else
  SSH_PUBKEY=$(ask "Paste your VM SSH PUBLIC key" "")
fi
VM_USER=$(ask "Linux user inside VMs" "ubuntu")

# ─── Observability ────────────────────────────────────────────────────────────
hdr "Central observability"
MIMIR_URL=$(ask "Mimir push URL" "http://mimir.stackflow.org/api/v1/push")
LOKI_URL=$(ask "Loki push URL" "http://loki.stackflow.org")

# ─── ArgoCD ───────────────────────────────────────────────────────────────────
hdr "ArgoCD (optional — Phase 7 skipped if you choose 'no')"
WANT_ARGOCD=$(ask "Deploy ArgoCD for this cluster? (y/n)" "y")
ARGOCD_HOSTNAME="argocd.${CLUSTER_NAME}.internal"
if [[ "$WANT_ARGOCD" =~ ^[Yy] ]]; then
  ARGOCD_HOSTNAME=$(ask "ArgoCD hostname (internal DNS)" "$ARGOCD_HOSTNAME")
fi

# ─── Write files ──────────────────────────────────────────────────────────────
mkdir -p "${CLUSTER_DIR}/tfstate"

# Helper: convert "1.2.3.4, 5.6.7.8" -> hcl list  ["1.2.3.4", "5.6.7.8"]
hcl_list() {
  echo -n '['
  local first=true
  IFS=',' read -ra parts <<<"$1"
  for p in "${parts[@]}"; do
    p="$(echo "$p" | xargs)"   # trim
    $first || echo -n ', '
    echo -n "\"$p\""
    first=false
  done
  echo ']'
}

MASTER_IPS_HCL=$(hcl_list "$MASTER_IPS")
WORKER_IPS_HCL=$(hcl_list "$WORKER_IPS")
DNS_HCL=$(hcl_list "$DNS_SERVERS")

cat > "${CLUSTER_DIR}/proxmox.tfvars" <<EOF
################################################################################
# proxmox.tfvars — VM provisioning for cluster: ${CLUSTER_NAME}
# Generated by new-cluster.sh on $(date -Iseconds).
################################################################################

cluster_name = "${CLUSTER_NAME}"
environment  = "${ENVIRONMENT}"

proxmox_api_url      = "${PROXMOX_API_URL}"
proxmox_username     = "terraform@pve"
proxmox_tls_insecure = true
proxmox_node         = "${PROXMOX_NODE}"

shared_cloud_init_snippet_file_id = "${SNIPPET_FILE_ID}"

network_bridge              = "${NETWORK_BRIDGE}"
network_subnet_cidr         = "${SUBNET_CIDR}"
network_gateway             = "${NETWORK_GATEWAY}"
dns_servers                 = ${DNS_HCL}
domain_name                 = "${DOMAIN_NAME}"
vlan_tag                    = 0
control_plane_vip           = "${CONTROL_PLANE_VIP}"
control_plane_vip_interface = "eth0"

vm_template_id      = ${TEMPLATE_VM_ID}
vm_template_storage = "local-lvm"

vm_ssh_public_key       = "${SSH_PUBKEY}"
vm_ssh_private_key_path = "${SSH_KEY_PATH}"
vm_user                 = "${VM_USER}"
vm_cpu_type             = "x86-64-v2-AES"

master_count             = ${MASTER_COUNT}
master_vm_id_start       = ${MASTER_VM_ID_START}
master_cpu_cores         = ${MASTER_CPU}
master_cpu_sockets       = 1
master_memory_mb         = ${MASTER_RAM}
master_disk_size_gb      = ${MASTER_DISK}
master_etcd_disk_size_gb = ${MASTER_ETCD_DISK}
master_disk_storage      = "${DISK_STORAGE}"
master_name_prefix       = "${CLUSTER_NAME}-m"
master_ip_addresses      = ${MASTER_IPS_HCL}

worker_count             = ${WORKER_COUNT}
worker_vm_id_start       = ${WORKER_VM_ID_START}
worker_cpu_cores         = ${WORKER_CPU}
worker_cpu_sockets       = 1
worker_memory_mb         = ${WORKER_RAM}
worker_disk_size_gb      = ${WORKER_DISK}
worker_data_disk_size_gb = ${WORKER_DATA_DISK}
worker_disk_storage      = "${DISK_STORAGE}"
worker_name_prefix       = "${CLUSTER_NAME}-w"
worker_ip_addresses      = ${WORKER_IPS_HCL}

rke2_version      = "v1.32.10+rke2r1"
rke2_cni          = "cilium"
rke2_cluster_cidr = "10.42.0.0/16"
rke2_service_cidr = "10.43.0.0/16"
rke2_cluster_dns  = "10.43.0.10"

tags = {
  managed_by  = "terraform"
  cluster     = "${CLUSTER_NAME}"
  environment = "${ENVIRONMENT}"
  team        = "devops"
}
EOF

cat > "${CLUSTER_DIR}/observability.tfvars" <<EOF
################################################################################
# observability.tfvars — cluster: ${CLUSTER_NAME}
# Generated by new-cluster.sh on $(date -Iseconds).
################################################################################

kubeconfig_path = "../../clusters/${CLUSTER_NAME}/kubeconfig.yaml"
cluster_name    = "${CLUSTER_NAME}"
environment     = "${ENVIRONMENT}"

central_mimir_url      = "${MIMIR_URL}"
central_mimir_username = ""

central_loki_url       = "${LOKI_URL}"
central_loki_username  = ""
loki_tenant_id         = "${CLUSTER_NAME}"

prometheus_replicas       = 2
prometheus_storage_size   = "20Gi"
prometheus_retention_days = 3

alertmanager_replicas  = 2
alertmanager_email_to  = "devops@example.com"
alertmanager_smtp_host = ""
EOF

if [[ "$WANT_ARGOCD" =~ ^[Yy] ]]; then
  cat > "${CLUSTER_DIR}/argocd.tfvars" <<EOF
################################################################################
# argocd.tfvars — cluster: ${CLUSTER_NAME}
# Generated by new-cluster.sh on $(date -Iseconds).
################################################################################

kubeconfig_path  = "../../clusters/${CLUSTER_NAME}/kubeconfig.yaml"
cluster_name     = "${CLUSTER_NAME}"
environment      = "${ENVIRONMENT}"

argocd_namespace     = "argocd"
argocd_chart_version = "7.7.0"

argocd_ha_enabled          = false
argocd_server_service_type = "ClusterIP"
argocd_server_insecure     = true

argocd_server_cpu_request    = "100m"
argocd_server_memory_request = "256Mi"
argocd_server_cpu_limit      = "500m"
argocd_server_memory_limit   = "512Mi"

argocd_ingress_enabled       = true
argocd_hostname              = "${ARGOCD_HOSTNAME}"
argocd_cluster_issuer        = "cluster-ca-issuer"
argocd_lb_ip_pool_cidr       = "${LB_POOL_CIDR}"
argocd_lb_l2_interface_regex = "^(eth|ens|enp).*"
EOF
  log "✓ Wrote ${CLUSTER_DIR}/argocd.tfvars"
fi

log "✓ Wrote ${CLUSTER_DIR}/proxmox.tfvars"
log "✓ Wrote ${CLUSTER_DIR}/observability.tfvars"
log ""
log "${BOLD}Next steps:${NC}"
log "  1. Review the generated files:  ${CYAN}$EDITOR ${CLUSTER_DIR}/*.tfvars${NC}"
log "  2. Commit through your GitLab MR:"
log "       ${CYAN}git add ${CLUSTER_DIR} && git commit -m 'feat: add ${CLUSTER_NAME}'${NC}"
log "  3. After merge, deploy:"
log "       ${CYAN}./scripts/deploy.sh ${CLUSTER_NAME}${NC}"
