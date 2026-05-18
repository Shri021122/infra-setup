#!/usr/bin/env bash
################################################################################
# uninstall.sh — Tear down everything deploy.sh created
#
# Phases run in REVERSE of deploy.sh:
#   Phase 7: terraform destroy → ArgoCD (Helm release, Ingress, LB pool, cert)
#   Phase 5: terraform destroy → observability (Prometheus, Alertmanager, KSM)
#   Phase 4: helm uninstall → cert-manager, External Secrets Operator
#            kubectl delete → RBAC, NetworkPolicies, namespaces
#   Phase 3: rke2-uninstall.sh + Alloy removal on every node
#   Phase 2: terraform destroy → Proxmox VMs
#   Cleanup: remove .secrets, rbac/kubeconfigs, tfstate, *.tfplan, .logs
#            (tfvars files are KEPT so the repo stays redeployable)
#
# Usage:
#   ./scripts/uninstall.sh                # Interactive, prompts before each phase
#   ./scripts/uninstall.sh --only phase3  # Just uninstall RKE2 (keep VMs + tfstate)
#   ./scripts/uninstall.sh --dry-run      # Show what would happen
#   ./scripts/uninstall.sh --yes          # Skip all prompts (CI / scripted use)
#   ./scripts/uninstall.sh --keep-local   # Skip the final local-artifact cleanup
################################################################################

set -euo pipefail

# ─── Paths (same source-of-truth as deploy.sh) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_DIR="${ROOT_DIR}/.secrets"
TERRAFORM_PROXMOX="${ROOT_DIR}/terraform/proxmox"
TERRAFORM_OBS="${ROOT_DIR}/terraform/observability"
TERRAFORM_ARGOCD="${ROOT_DIR}/terraform/argocd"
RBAC_DIR="${ROOT_DIR}/rbac"
SECURITY_DIR="${ROOT_DIR}/security"
INVENTORY="${ROOT_DIR}/rke2/configs/inventory.ini"
LOG_DIR="${ROOT_DIR}/.logs"
LOG_FILE="${LOG_DIR}/uninstall-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

# ─── Colors & logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; exit 1; }
phase()   { echo -e "\n${BOLD}${RED}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${RED}══════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}${BOLD}✓ $*${NC}" | tee -a "$LOG_FILE"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
ONLY_PHASE=""
DRY_RUN=false
ASSUME_YES=false
KEEP_LOCAL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --only)        ONLY_PHASE="${2//phase/}"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --yes|-y)      ASSUME_YES=true; shift ;;
    --keep-local)  KEEP_LOCAL=true; shift ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    *)             echo "Unknown argument: $1"; exit 1 ;;
  esac
done

should_run() {
  local phase_num="$1"
  [[ -z "$ONLY_PHASE" || "$ONLY_PHASE" == "$phase_num" ]]
}

confirm() {
  # Returns 0 if user confirms (or --yes is set), 1 otherwise.
  local prompt="$1"
  if [[ "$ASSUME_YES" == "true" ]]; then
    log "  --yes set, proceeding: $prompt"
    return 0
  fi
  echo -en "${YELLOW}${BOLD}${prompt} [y/N]: ${NC}"
  read -r reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
    return 0
  fi
  "$@" >> "$LOG_FILE" 2>&1
}

run_visible() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
    return 0
  fi
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

# Run a command but don't fail the script if it errors (uninstall must be
# idempotent — many sub-steps may already be undone).
run_soft() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
    return 0
  fi
  if "$@" >> "$LOG_FILE" 2>&1; then
    return 0
  else
    local rc=$?
    warn "Command returned $rc (continuing): $*"
    return 0
  fi
}

# ─── SSH config (read same way deploy.sh / install-*.sh do) ───────────────────
load_ssh_config() {
  [[ -f "$INVENTORY" ]] || return 1
  SSH_KEY=$(grep 'ansible_ssh_private_key_file=' "$INVENTORY" 2>/dev/null \
              | head -1 | cut -d= -f2 | tr -d '"' | sed "s|^~|$HOME|")
  SSH_USER=$(grep 'ansible_user=' "$INVENTORY" 2>/dev/null | head -1 | cut -d= -f2)
  : "${SSH_KEY:=$HOME/.ssh/rke2_cluster_id}"
  : "${SSH_USER:=ubuntu}"
  [[ -f "$SSH_KEY" ]]
}

ssh_exec() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "${SSH_USER}@${ip}" "$@"
}

# ─── Phase 7: ArgoCD ──────────────────────────────────────────────────────────
phase7_destroy_argocd() {
  phase "Phase 7: Destroy ArgoCD Stack (terraform)"

  if [[ ! -f "${TERRAFORM_ARGOCD}/terraform.tfstate" ]]; then
    log "No ArgoCD tfstate found — nothing to destroy."
    return 0
  fi

  echo -e "${BOLD}This will:${NC}"
  echo -e "  - terraform destroy in ${CYAN}${TERRAFORM_ARGOCD}${NC}"
  echo -e "  - removes: argocd Helm release, Ingress, Certificate,"
  echo -e "    CiliumLoadBalancerIPPool, CiliumL2AnnouncementPolicy, argocd namespace"
  echo ""

  if ! confirm "Proceed with ArgoCD teardown?"; then
    warn "Skipped Phase 7"
    return 0
  fi

  cd "$TERRAFORM_ARGOCD"
  log "terraform destroy (argocd)..."
  if [[ -f "${SECRETS_DIR}/kubeconfig-admin.yaml" ]] \
     && KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml" kubectl get ns &>/dev/null; then
    run_visible terraform destroy -auto-approve
  else
    warn "API server unreachable — clearing tfstate without destroy"
    run_soft rm -f terraform.tfstate terraform.tfstate.backup argocd.tfplan
  fi

  cd "$ROOT_DIR"
  success "Phase 7 complete"
}

# ─── Phase 5: Observability stack ─────────────────────────────────────────────
phase5_destroy_observability() {
  phase "Phase 5: Destroy Observability Stack (terraform)"

  if [[ ! -f "${TERRAFORM_OBS}/terraform.tfstate" ]]; then
    log "No observability tfstate found — nothing to destroy."
    return 0
  fi

  echo -e "${BOLD}This will:${NC}"
  echo -e "  - helm uninstall kube-prometheus-stack (Prometheus, Alertmanager, KSM)"
  echo -e "  - delete monitoring namespace + all PVCs"
  echo -e "  - tfstate: ${CYAN}${TERRAFORM_OBS}/terraform.tfstate${NC}"
  echo ""

  if ! confirm "Proceed with observability teardown?"; then
    warn "Skipped Phase 5"
    return 0
  fi

  cd "$TERRAFORM_OBS"
  log "terraform destroy (observability)..."
  # The provider talks to the cluster — if RKE2 is already gone the destroy
  # will fail to reach the API. That's OK; run_soft tolerates it and Phase 2
  # will wipe the cluster anyway.
  if [[ -f "${SECRETS_DIR}/kubeconfig-admin.yaml" ]] \
     && KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml" kubectl get ns &>/dev/null; then
    run_visible terraform destroy -auto-approve
  else
    warn "API server unreachable — clearing tfstate without destroy"
    run_soft terraform state list
    # If the cluster is already gone, Helm releases are gone too. Just drop
    # tfstate so a future apply starts clean.
    run_soft rm -f terraform.tfstate terraform.tfstate.backup obs.tfplan
  fi

  cd "$ROOT_DIR"
  success "Phase 5 complete"
}

# ─── Phase 4: Security / addons / RBAC ────────────────────────────────────────
phase4_uninstall_security() {
  phase "Phase 4: Uninstall Security Addons (cert-manager, ESO, RBAC, NetPols)"

  if [[ ! -f "${SECRETS_DIR}/kubeconfig-admin.yaml" ]]; then
    log "No admin kubeconfig — cluster probably already gone. Skipping."
    return 0
  fi

  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

  if ! kubectl get nodes &>/dev/null; then
    warn "API server unreachable — skipping (Phase 3 will wipe everything)"
    return 0
  fi

  echo -e "${BOLD}This will:${NC}"
  echo -e "  - helm uninstall cert-manager + external-secrets"
  echo -e "  - kubectl delete: RBAC, NetworkPolicies, ClusterIssuers, namespaces"
  echo ""

  if ! confirm "Proceed with addon teardown?"; then
    warn "Skipped Phase 4"
    return 0
  fi

  log "Removing ClusterIssuers..."
  run_soft kubectl delete -f "${SECURITY_DIR}/tls/cluster-issuer.yaml" --ignore-not-found

  log "Uninstalling External Secrets Operator..."
  run_soft helm uninstall external-secrets -n external-secrets

  log "Uninstalling cert-manager..."
  run_soft helm uninstall cert-manager -n cert-manager

  log "Removing network policies..."
  run_soft kubectl delete -f "${SECURITY_DIR}/network-policies/" --ignore-not-found

  log "Removing RBAC..."
  for f in 04-read-only-auditor.yaml 03-developer.yaml \
           02-junior-devops.yaml 01-senior-devops.yaml; do
    run_soft kubectl delete -f "${RBAC_DIR}/${f}" --ignore-not-found
  done

  log "Removing user namespaces..."
  run_soft kubectl delete -f "${RBAC_DIR}/00-namespace-setup.yaml" --ignore-not-found

  # Belt-and-suspenders: namespaces explicitly
  for ns in cert-manager external-secrets monitoring; do
    run_soft kubectl delete namespace "$ns" --ignore-not-found --timeout=60s
  done

  success "Phase 4 complete"
}

# ─── Phase 3: RKE2 + Alloy uninstall on every node ────────────────────────────
phase3_uninstall_rke2() {
  phase "Phase 3: Uninstall RKE2 + Alloy on All Nodes"

  if ! load_ssh_config; then
    warn "Could not read inventory ($INVENTORY) or SSH key missing — skipping"
    return 0
  fi

  local masters workers
  masters=$(awk '/^\[masters\]/{flag=1;next} /^\[/{flag=0} flag && /ansible_host=/{
    for(i=1;i<=NF;i++) if($i ~ /^ansible_host=/){split($i,a,"="); print a[2]}}' "$INVENTORY")
  workers=$(awk '/^\[workers\]/{flag=1;next} /^\[/{flag=0} flag && /ansible_host=/{
    for(i=1;i<=NF;i++) if($i ~ /^ansible_host=/){split($i,a,"="); print a[2]}}' "$INVENTORY")

  echo -e "${BOLD}This will SSH to and run rke2-uninstall.sh + alloy purge on:${NC}"
  echo -e "  ${BOLD}Workers${NC} (uninstalled first to drain gracefully):"
  for ip in $workers; do echo -e "    ${CYAN}${ip}${NC}"; done
  echo -e "  ${BOLD}Masters${NC} (uninstalled last):"
  for ip in $masters; do echo -e "    ${CYAN}${ip}${NC}"; done
  echo ""
  echo -e "  SSH key: ${CYAN}${SSH_KEY}${NC}   user: ${CYAN}${SSH_USER}${NC}"
  echo ""

  if ! confirm "Proceed with RKE2 uninstall? (irreversible on each node)"; then
    warn "Skipped Phase 3"
    return 0
  fi

  uninstall_node() {
    local ip="$1" role="$2"
    log "  → ${role} ${ip}: stopping services + running rke2-uninstall.sh..."

    if [[ "$DRY_RUN" == "true" ]]; then
      echo -e "${YELLOW}[DRY-RUN]${NC} Would uninstall RKE2 + Alloy on ${ip}"
      return 0
    fi

    # If the node is unreachable, log and move on — don't block the whole
    # teardown on one dead VM (it'll be terraform-destroyed in Phase 2 anyway).
    if ! ssh_exec "$ip" "true" 2>/dev/null; then
      warn "    ${ip} unreachable over SSH — skipping (will be destroyed in Phase 2)"
      return 0
    fi

    ssh_exec "$ip" "bash -s" <<'REMOTE' >> "$LOG_FILE" 2>&1 || \
      warn "    ${ip}: uninstall returned non-zero (continuing)"
set +e
# RKE2 — the installer drops both scripts. Prefer the full uninstall;
# fall back to killall + manual rm if uninstall is missing.
if [ -x /usr/local/bin/rke2-uninstall.sh ]; then
  sudo /usr/local/bin/rke2-uninstall.sh
elif [ -x /usr/local/bin/rke2-killall.sh ]; then
  sudo /usr/local/bin/rke2-killall.sh
  sudo rm -rf /etc/rancher/rke2 /var/lib/rancher/rke2 /var/lib/kubelet \
              /usr/local/bin/rke2 /usr/local/lib/systemd/system/rke2-* \
              /etc/systemd/system/rke2-*.service
  sudo systemctl daemon-reload
fi

# Alloy (systemd service installed by install-alloy.sh)
if systemctl list-unit-files 2>/dev/null | grep -q '^alloy\.service'; then
  sudo systemctl stop alloy 2>/dev/null
  sudo systemctl disable alloy 2>/dev/null
fi
sudo apt-get remove --purge -y alloy 2>/dev/null
sudo rm -rf /etc/alloy /var/lib/alloy /etc/systemd/system/alloy.service.d
sudo rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg

# sysctl tweaks deploy.sh adds
sudo rm -f /etc/sysctl.d/99-rke2.conf

# CNI / kube state that survives rke2-uninstall on some versions
sudo rm -rf /var/lib/cni /etc/cni/net.d /run/flannel /run/k3s /run/calico
true
REMOTE
    success "    ${ip} uninstalled"
  }

  for ip in $workers; do uninstall_node "$ip" "worker"; done
  for ip in $masters; do uninstall_node "$ip" "master"; done

  success "Phase 3 complete — all nodes wiped"
}

# ─── Phase 2: Destroy Proxmox VMs ─────────────────────────────────────────────
phase2_destroy_proxmox() {
  phase "Phase 2: Destroy Proxmox VMs (terraform)"

  if [[ ! -f "${TERRAFORM_PROXMOX}/terraform.tfstate" ]]; then
    log "No Proxmox tfstate found — nothing to destroy."
    return 0
  fi

  # Require Proxmox creds the same way deploy.sh does
  if [[ -z "${TF_VAR_proxmox_api_token:-}" && -z "${TF_VAR_proxmox_password:-}" ]]; then
    err "Missing Proxmox credentials. Export one of:
    export TF_VAR_proxmox_api_token='user@realm!tokenid=UUID'   # preferred
    export TF_VAR_proxmox_password='...'"
  fi

  echo -e "${BOLD}${RED}This will PERMANENTLY DESTROY:${NC}"
  cd "$TERRAFORM_PROXMOX"
  terraform state list 2>/dev/null | sed 's/^/  - /' || true
  echo ""

  if ! confirm "Proceed with VM destruction? (Cannot be undone)"; then
    warn "Skipped Phase 2"
    cd "$ROOT_DIR"
    return 0
  fi

  log "terraform destroy (Proxmox)..."
  run_visible terraform destroy -auto-approve

  cd "$ROOT_DIR"
  success "Phase 2 complete — all VMs destroyed"
}

# ─── Local artifact cleanup ───────────────────────────────────────────────────
cleanup_local() {
  phase "Local Cleanup"

  if [[ "$KEEP_LOCAL" == "true" ]]; then
    log "--keep-local set — leaving local artifacts in place."
    return 0
  fi

  echo -e "${BOLD}This will delete:${NC}"
  echo -e "  - ${CYAN}${SECRETS_DIR}/${NC}                   (kubeconfig, cluster token, tf-outputs)"
  echo -e "  - ${CYAN}${RBAC_DIR}/kubeconfigs/${NC}         (role-specific kubeconfigs)"
  echo -e "  - ${CYAN}${TERRAFORM_PROXMOX}/terraform.tfstate*${NC}"
  echo -e "  - ${CYAN}${TERRAFORM_PROXMOX}/*.tfplan${NC}"
  echo -e "  - ${CYAN}${TERRAFORM_OBS}/terraform.tfstate*${NC}"
  echo -e "  - ${CYAN}${TERRAFORM_OBS}/*.tfplan${NC}"
  echo -e "  - ${CYAN}${LOG_DIR}/${NC} (after this run completes)"
  echo ""
  echo -e "  ${BOLD}KEEPING:${NC} terraform.tfvars files (so deploy.sh works again)"
  echo ""

  if ! confirm "Proceed with local cleanup?"; then
    warn "Skipped local cleanup"
    return 0
  fi

  run_soft rm -rf "$SECRETS_DIR"
  run_soft rm -rf "${RBAC_DIR}/kubeconfigs"
  run_soft rm -f "${TERRAFORM_PROXMOX}/terraform.tfstate" \
                 "${TERRAFORM_PROXMOX}/terraform.tfstate.backup" \
                 "${TERRAFORM_PROXMOX}/cluster.tfplan" \
                 "${TERRAFORM_PROXMOX}/.terraform.lock.hcl"
  run_soft rm -rf "${TERRAFORM_PROXMOX}/.terraform"
  run_soft rm -f "${TERRAFORM_OBS}/terraform.tfstate" \
                 "${TERRAFORM_OBS}/terraform.tfstate.backup" \
                 "${TERRAFORM_OBS}/obs.tfplan" \
                 "${TERRAFORM_OBS}/.terraform.lock.hcl"
  run_soft rm -rf "${TERRAFORM_OBS}/.terraform"

  # Generated configs that come from terraform apply, not the user
  run_soft rm -f "${ROOT_DIR}/rke2/configs/inventory.ini" \
                 "${ROOT_DIR}/rke2/configs/master-1-config.yaml" \
                 "${ROOT_DIR}/rke2/configs/master-2-config.yaml" \
                 "${ROOT_DIR}/rke2/configs/master-3-config.yaml" \
                 "${ROOT_DIR}/rke2/configs/worker-1-config.yaml" \
                 "${ROOT_DIR}/rke2/configs/worker-2-config.yaml" \
                 "${ROOT_DIR}/rke2/configs/alloy-config.alloy.tpl"

  success "Local cleanup complete"
  # Note: $LOG_DIR is removed below in main() AFTER all logging is done.
}

# ─── Final Summary ─────────────────────────────────────────────────────────────
print_summary() {
  phase "Uninstall Complete"
  echo -e "${BOLD}What's gone:${NC}"
  echo -e "  ✓ Observability stack (Prometheus + Alertmanager)"
  echo -e "  ✓ Cluster addons (cert-manager, ESO, RBAC, NetworkPolicies)"
  echo -e "  ✓ RKE2 + Alloy on all 5 nodes"
  echo -e "  ✓ Proxmox VMs (terraform destroyed)"
  [[ "$KEEP_LOCAL" == "false" ]] && echo -e "  ✓ Local kubeconfigs, tfstate, secrets"
  echo ""
  echo -e "${BOLD}What's kept (so you can redeploy):${NC}"
  echo -e "  - terraform/proxmox/terraform.tfvars"
  echo -e "  - terraform/observability/terraform.tfvars"
  echo -e "  - All source code under git"
  echo ""
  echo -e "${BOLD}To redeploy:${NC}  ${CYAN}./scripts/deploy.sh${NC}"
  echo ""
  success "Done. Log: ${LOG_FILE}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${RED}"
  cat << 'BANNER'
  ╦ ╦╔╗╔╦╔╗╔╔═╗╔╦╗╔═╗╦  ╦
  ║ ║║║║║║║║╚═╗ ║ ╠═╣║  ║
  ╚═╝╝╚╝╩╝╚╝╚═╝ ╩ ╩ ╩╩═╝╩═╝
  Tear down everything deploy.sh created
BANNER
  echo -e "${NC}"

  log "Log file: ${LOG_FILE}"
  [[ -n "$ONLY_PHASE" ]] && log "Running ONLY phase ${ONLY_PHASE}"
  [[ "$DRY_RUN" == "true" ]] && warn "DRY-RUN MODE — nothing will actually be destroyed"
  [[ "$ASSUME_YES" == "true" ]] && warn "--yes: skipping per-phase prompts"
  echo ""

  # Big upfront banner if running the full uninstall (no --only)
  if [[ -z "$ONLY_PHASE" && "$DRY_RUN" == "false" && "$ASSUME_YES" == "false" ]]; then
    echo -e "${BOLD}${RED}You are about to destroy the entire infra-setup deployment.${NC}"
    echo -e "Each phase will prompt before acting. ${BOLD}Ctrl-C anytime to abort.${NC}"
    echo ""
    confirm "Continue?" || { log "Aborted by user."; exit 0; }
  fi

  should_run 7 && phase7_destroy_argocd
  should_run 5 && phase5_destroy_observability
  should_run 4 && phase4_uninstall_security
  should_run 3 && phase3_uninstall_rke2
  should_run 2 && phase2_destroy_proxmox

  # Local cleanup only runs on a full uninstall (no --only)
  [[ -z "$ONLY_PHASE" ]] && cleanup_local

  print_summary

  # Finally, drop the log dir if asked. Copy this run's log out first so the
  # user can still read it if something went sideways.
  if [[ -z "$ONLY_PHASE" && "$KEEP_LOCAL" == "false" && "$DRY_RUN" == "false" ]]; then
    cp "$LOG_FILE" "/tmp/$(basename "$LOG_FILE")" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
    echo -e "${YELLOW}Log moved to /tmp/$(basename "$LOG_FILE")${NC}"
  fi
}

main "$@"
