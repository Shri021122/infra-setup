#!/usr/bin/env bash
################################################################################
# deploy.sh — Full Automated Deployment: Phases 2–7 (multi-cluster aware)
#
# Usage:
#   ./scripts/deploy.sh <cluster-name>                # Full deployment
#   ./scripts/deploy.sh <cluster-name> --from phase3  # Resume from a phase
#   ./scripts/deploy.sh <cluster-name> --only phase4  # Run a single phase
#   ./scripts/deploy.sh <cluster-name> --dry-run      # Validate without applying
#
# <cluster-name> must match a directory under clusters/. Each cluster has its
# own tfvars (clusters/<name>/*.tfvars), tfstate (clusters/<name>/tfstate/),
# and kubeconfig (clusters/<name>/kubeconfig.yaml). Terraform CODE under
# terraform/ is shared — no per-cluster copies.
#
# Prerequisites (Phase 1 — manual, once per Proxmox host):
#   - Proxmox API token created
#   - Ubuntu cloud-init template created
#   - snippets/k8s-common.yaml uploaded to local:snippets/ on Proxmox
#
# Prerequisites (once per cluster, before this script):
#   - clusters/<cluster-name>/proxmox.tfvars filled in (or use new-cluster.sh)
#   - clusters/<cluster-name>/observability.tfvars filled in
#   - clusters/<cluster-name>/argocd.tfvars filled in (optional — Phase 7 skips
#     cleanly if absent)
#   - Env: TF_VAR_proxmox_api_token, TF_VAR_central_mimir_password (optional),
#          TF_VAR_central_loki_password (optional)
#
# Phase 2: Terraform → Proxmox VMs
# Phase 3: RKE2 cluster installation (masters → workers) + Alloy on every node
# Phase 4: Security (namespaces, RBAC, NetworkPolicies, cert-manager, ESO, kubeconfigs)
# Phase 5: Observability (Prometheus + Alertmanager via Terraform)
# Phase 6: Verify Cilium IngressController (deployed by RKE2 automatically)
# Phase 7: ArgoCD via Terraform + optional Ingress (LB IP pool + L2 policy + cert)
################################################################################

set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_DIR="${ROOT_DIR}/.secrets"
TERRAFORM_PROXMOX="${ROOT_DIR}/terraform/proxmox"
TERRAFORM_OBS="${ROOT_DIR}/terraform/observability"
TERRAFORM_ARGOCD="${ROOT_DIR}/terraform/argocd"
RKE2_SCRIPTS="${ROOT_DIR}/rke2/scripts"
RBAC_DIR="${ROOT_DIR}/rbac"
SECURITY_DIR="${ROOT_DIR}/security"
CLUSTERS_DIR="${ROOT_DIR}/clusters"
LOG_DIR="${ROOT_DIR}/.logs"

mkdir -p "$SECRETS_DIR" "$LOG_DIR"
chmod 700 "$SECRETS_DIR"

# Per-cluster paths (populated after argument parsing once we know the name).
CLUSTER_NAME=""
CLUSTER_DIR=""
CLUSTER_TFSTATE_DIR=""
CLUSTER_KUBECONFIG=""
LOG_FILE=""

# ─── Colors & logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; exit 1; }
phase()   { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}${BOLD}✓ $*${NC}" | tee -a "$LOG_FILE"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
START_PHASE=2
END_PHASE=7
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") <cluster-name> [options]

Arguments:
  <cluster-name>    Must match a directory under clusters/

Options:
  --from phaseN     Resume from this phase (2-7)
  --only phaseN     Run only this phase
  --dry-run         Validate inputs; don't apply anything
  -h, --help        Show this help

Examples:
  $(basename "$0") test-prod
  $(basename "$0") acme-prod --from phase4
  $(basename "$0") widgets-prod --only phase7
EOF
  exit "${1:-0}"
}

# --help / -h works without a cluster name.
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0

# First positional arg = cluster name. Anything starting with -- is a flag.
if [[ $# -eq 0 ]] || [[ "$1" =~ ^- ]]; then
  echo "ERROR: cluster name is required (positional, first arg)." >&2
  usage 1
fi
CLUSTER_NAME="$1"; shift

while [[ $# -gt 0 ]]; do
  case $1 in
    --from)     START_PHASE="${2//phase/}"; shift 2 ;;
    --only)     p="${2//phase/}"; START_PHASE="$p"; END_PHASE="$p"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unknown argument: $1"; usage 1 ;;
  esac
done

# Resolve per-cluster paths.
CLUSTER_DIR="${CLUSTERS_DIR}/${CLUSTER_NAME}"
CLUSTER_TFSTATE_DIR="${CLUSTER_DIR}/tfstate"
CLUSTER_KUBECONFIG="${CLUSTER_DIR}/kubeconfig.yaml"
LOG_FILE="${LOG_DIR}/deploy-${CLUSTER_NAME}-$(date +%Y%m%d-%H%M%S).log"

# Validate cluster directory exists with required tfvars files.
# If it doesn't, offer to run the wizard right now (interactive only).
if [[ ! -d "$CLUSTER_DIR" ]]; then
  echo ""
  echo "clusters/${CLUSTER_NAME}/ does not exist yet."
  if [[ -t 0 ]]; then
    read -r -p "Run the new-cluster wizard now? [Y/n]: " reply
    if [[ -z "$reply" || "$reply" =~ ^[Yy] ]]; then
      "${SCRIPT_DIR}/new-cluster.sh" "$CLUSTER_NAME"
    else
      echo "Aborting. Run when you're ready: ./scripts/new-cluster.sh ${CLUSTER_NAME}"
      exit 1
    fi
  else
    echo "ERROR: not running interactively. Create the cluster first:" >&2
    echo "  ./scripts/new-cluster.sh ${CLUSTER_NAME}" >&2
    exit 1
  fi
fi
for f in proxmox.tfvars observability.tfvars; do
  [[ -f "${CLUSTER_DIR}/${f}" ]] || {
    echo "ERROR: ${CLUSTER_DIR}/${f} not found." >&2
    exit 1
  }
done

mkdir -p "$CLUSTER_TFSTATE_DIR"

should_run() {
  local phase_num="$1"
  [[ $phase_num -ge $START_PHASE && $phase_num -le $END_PHASE ]]
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
    return
  fi
  "$@" >> "$LOG_FILE" 2>&1 || { err "Command failed: $*\nCheck log: $LOG_FILE"; }
}

run_visible() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
    return
  fi
  "$@" 2>&1 | tee -a "$LOG_FILE" || { err "Command failed: $*\nCheck log: $LOG_FILE"; }
}

# tf — wrapper around `terraform` that injects -var-file + -state for the
# current cluster automatically. Pass the module short-name as $1 (proxmox /
# observability / argocd), the action as $2 (init / validate / plan / apply /
# output / destroy / ...) and the rest as terraform args.
#
# Plan/apply/destroy/output/state commands get the per-cluster state path.
# init/validate don't take a state arg.
tf() {
  local module="$1"; shift
  local action="$1"; shift
  local module_dir="${ROOT_DIR}/terraform/${module}"
  local var_file="${CLUSTER_DIR}/${module}.tfvars"
  local state_file="${CLUSTER_TFSTATE_DIR}/${module}.tfstate"

  cd "$module_dir"

  case "$action" in
    init|validate|fmt|providers|version)
      terraform "$action" "$@" ;;
    plan|apply|destroy|refresh|import|taint|untaint)
      terraform "$action" -var-file="$var_file" -state="$state_file" "$@" ;;
    output|state|show)
      terraform "$action" -state="$state_file" "$@" ;;
    *)
      terraform "$action" "$@" ;;
  esac
}

# ─── Prerequisite checks ──────────────────────────────────────────────────────
check_prerequisites() {
  phase "Checking Prerequisites"

  local missing=()
  for tool in terraform kubectl helm openssl ssh jq curl; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
      continue
    fi
    # Different tools use different version flags; ssh's `ssh version` would
    # try to connect to a host literally named "version" and prompt for a
    # password. Use `-V` (which writes to stderr) for ssh, and a per-tool
    # invocation everywhere else.
    # `|| true` because some tools exit non-zero on the version query
    # (e.g. `kubectl version` without --client tries to reach the apiserver,
    # which hasn't been built yet on a fresh deploy). With `set -euo pipefail`
    # any non-zero would otherwise kill the whole script here.
    local ver
    case "$tool" in
      ssh)        ver=$(ssh -V 2>&1 | head -1 || true) ;;
      curl)       ver=$(curl --version 2>/dev/null | head -1 || true) ;;
      jq)         ver=$(jq --version 2>/dev/null | head -1 || true) ;;
      openssl)    ver=$(openssl version 2>/dev/null | head -1 || true) ;;
      kubectl)    ver=$(kubectl version --client 2>/dev/null | head -1 || true) ;;
      *)          ver=$(${tool} version 2>/dev/null | head -1 || true) ;;
    esac
    log "  ✓ $tool ${ver}"
  done

  [[ ${#missing[@]} -eq 0 ]] || err "Missing tools: ${missing[*]}\nInstall them then re-run."

  # Terraform version check
  TF_VERSION=$(terraform version -json | jq -r '.terraform_version')
  log "  Terraform version: $TF_VERSION"

  # Per-cluster tfvars live under clusters/<name>/ — already validated at
  # script-start (cluster directory + proxmox.tfvars + observability.tfvars
  # checked there). No need to re-check legacy terraform/<module>/terraform.tfvars.
  log "  Cluster:               ${CLUSTER_NAME}"
  log "  Cluster directory:     ${CLUSTER_DIR}"
  log "  Terraform state dir:   ${CLUSTER_TFSTATE_DIR}"

  # ArgoCD tfvars is optional — if absent we skip Phase 7 cleanly later.
  if [[ ! -f "${CLUSTER_DIR}/argocd.tfvars" ]]; then
    warn "No ${CLUSTER_DIR}/argocd.tfvars — Phase 7 (ArgoCD) will be skipped."
    warn "  To enable: copy from clusters/_template/argocd.tfvars and edit."
  fi

  # Proxmox auth: accept either the api_token (preferred) or the password.
  if [[ -z "${TF_VAR_proxmox_api_token:-}" && -z "${TF_VAR_proxmox_password:-}" ]]; then
    err "Missing Proxmox credentials. Export one of:\n  export TF_VAR_proxmox_api_token='user@realm!tokenid=UUID'   # preferred\n  export TF_VAR_proxmox_password='...'"
  fi

  [[ -n "${TF_VAR_central_mimir_password:-}" ]] || warn "TF_VAR_central_mimir_password not set (Mimir auth will be empty)"
  [[ -n "${TF_VAR_central_loki_password:-}" ]]  || warn "TF_VAR_central_loki_password not set (Loki auth will be empty)"

  success "All prerequisites satisfied"
}

# ─── Phase 2: Terraform Proxmox ───────────────────────────────────────────────
phase2_terraform_proxmox() {
  phase "Phase 2: Terraform — Proxmox VM Provisioning"

  local tfplan="${CLUSTER_TFSTATE_DIR}/proxmox.tfplan"
  local var_file="${CLUSTER_DIR}/proxmox.tfvars"
  local state_file="${CLUSTER_TFSTATE_DIR}/proxmox.tfstate"

  log "Initializing Terraform..."
  ( cd "$TERRAFORM_PROXMOX" && run terraform init -upgrade )

  log "Validating configuration..."
  ( cd "$TERRAFORM_PROXMOX" && run terraform validate )

  log "Planning infrastructure..."
  ( cd "$TERRAFORM_PROXMOX" && run_visible terraform plan \
      -var-file="$var_file" -state="$state_file" -out="$tfplan" )

  log "Applying infrastructure (this creates VMs — may take 10–15 minutes)..."
  ( cd "$TERRAFORM_PROXMOX" && run_visible terraform apply \
      -state="$state_file" -auto-approve "$tfplan" )

  # Extract outputs for use in later phases
  log "Extracting Terraform outputs..."
  ( cd "$TERRAFORM_PROXMOX" && terraform output -state="$state_file" -json > "${CLUSTER_DIR}/tf-outputs.json" )
  INIT_MASTER_IP=$(  cd "$TERRAFORM_PROXMOX" && terraform output -state="$state_file" -raw init_master_ip )
  CONTROL_PLANE_VIP=$(cd "$TERRAFORM_PROXMOX" && terraform output -state="$state_file" -raw control_plane_vip )
  log "  Init master IP:     ${INIT_MASTER_IP}"
  log "  Control plane VIP:  ${CONTROL_PLANE_VIP}"

  # Wait for VMs to be reachable via SSH
  log "Waiting for VMs to boot and cloud-init to complete..."
  VM_IPS=$(cd "$TERRAFORM_PROXMOX" && terraform output -state="$state_file" -json all_node_ips | jq -r '.[]')

  # SSH user + key path come from inventory.ini (already generated by the
  # local_file resource above). Same source of truth the install-*.sh
  # scripts use, so all phases share one key path.
  local inventory="${ROOT_DIR}/rke2/configs/inventory.ini"
  SSH_KEY=$(grep 'ansible_ssh_private_key_file=' "$inventory" 2>/dev/null \
              | head -1 | cut -d= -f2 | tr -d '"' | sed "s|^~|$HOME|")
  SSH_USER=$(grep 'ansible_user=' "$inventory" 2>/dev/null | head -1 | cut -d= -f2)
  : "${SSH_KEY:=$HOME/.ssh/rke2_cluster_id}"
  : "${SSH_USER:=ubuntu}"
  log "  SSH key:  ${SSH_KEY}"
  log "  SSH user: ${SSH_USER}"
  [[ -f "$SSH_KEY" ]] || err "SSH key not found: ${SSH_KEY}"

  for ip in $VM_IPS; do
    log "  Waiting for SSH on ${ip}..."
    local waited=0
    # cloud-init may exit non-zero for non-fatal reasons (e.g. snapd-not-installed
    # on a virt-customize-stripped template), even when user creation / SSH /
    # package install succeeded. We only care that we can SSH in and that
    # cloud-init has finished running — exit code is not load-bearing.
    until ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 -o BatchMode=yes -i "${SSH_KEY}" "${SSH_USER}@${ip}" \
              "cloud-init status --wait >/dev/null 2>&1; echo ready" 2>/dev/null | grep -q ready; do
      sleep 10; waited=$((waited+10))
      [[ $waited -lt 300 ]] || err "Timeout waiting for SSH on ${ip}"
    done
    success "  ${ip} is ready"
  done

  cd "$ROOT_DIR"
  success "Phase 2 complete — all VMs provisioned and ready"
}

# ─── Phase 3: RKE2 Installation ───────────────────────────────────────────────
phase3_rke2_install() {
  phase "Phase 3: RKE2 Cluster Installation"

  chmod +x "${RKE2_SCRIPTS}"/*.sh

  log "Installing RKE2 on master nodes (init → join → join)..."
  log "  This may take 10–15 minutes per master..."
  run_visible "${RKE2_SCRIPTS}/install-master.sh"

  [[ -f "${SECRETS_DIR}/kubeconfig-admin.yaml" ]] || \
    err "Admin kubeconfig not found after master install. Check logs."

  # Copy admin kubeconfig to the per-cluster location used by all later phases.
  cp "${SECRETS_DIR}/kubeconfig-admin.yaml" "${CLUSTER_KUBECONFIG}"
  chmod 600 "${CLUSTER_KUBECONFIG}"
  log "Admin kubeconfig saved at: ${CLUSTER_KUBECONFIG}"

  log "Installing RKE2 agents on worker nodes..."
  run_visible "${RKE2_SCRIPTS}/install-worker.sh"

  # Set KUBECONFIG for subsequent phases
  export KUBECONFIG="${CLUSTER_KUBECONFIG}"

  log "Verifying cluster health..."
  local retries=0
  until kubectl get nodes --no-headers 2>/dev/null | grep -v NotReady | grep -q Ready; do
    sleep 15; retries=$((retries+1))
    [[ $retries -lt 20 ]] || err "Cluster nodes did not become Ready in time"
    log "  Waiting for nodes to be Ready... ($((retries * 15))s)"
  done

  echo ""
  kubectl get nodes -o wide
  echo ""

  # Verify Cilium is running (deployed automatically by RKE2)
  log "Verifying Cilium CNI is healthy..."
  kubectl wait --for=condition=Ready pod -l k8s-app=cilium \
    -n kube-system --timeout=5m || warn "Cilium pods not yet Ready — may still be starting"

  # ─── Pin the admin kubeconfig to the control-plane VIP ─────────────────────
  # install-master.sh writes the init-master's direct IP into the kubeconfig
  # (bootstrap-safe before kube-vip is ARPing). Now that the cluster is up and
  # we've verified the VIP is reachable, swap the kubeconfig over so admin
  # kubectl survives any single master failure.
  local inventory="${ROOT_DIR}/rke2/configs/inventory.ini"
  local vip
  vip=$(grep '^control_plane_vip=' "$inventory" 2>/dev/null | head -1 | cut -d= -f2)
  if [[ -n "$vip" ]] && ping -c1 -W2 "$vip" >/dev/null 2>&1; then
    log "Pinning admin kubeconfig to control-plane VIP (${vip})..."
    # Replace whatever :6443 server is currently in the kubeconfig with the VIP.
    sed -i "s|server: https://[^:]*:6443|server: https://${vip}:6443|" "${CLUSTER_KUBECONFIG}"
    sed -i "s|server: https://[^:]*:6443|server: https://${vip}:6443|" "${SECRETS_DIR}/kubeconfig-admin.yaml"
    # Sanity-check: the new server URL works
    kubectl --kubeconfig "${CLUSTER_KUBECONFIG}" get --raw=/version >/dev/null 2>&1 \
      && success "  Admin kubeconfig now uses VIP ${vip} (HA admin access)" \
      || warn "  VIP-pinned kubeconfig failed a smoke test — keep an eye on this"
  else
    warn "Control-plane VIP not reachable; leaving kubeconfig pointed at init master."
    warn "  Admin kubectl will fail if the init master goes down."
  fi

  success "Phase 3 complete — RKE2 cluster is up with Cilium CNI"
}

# ─── Phase 4: Security ────────────────────────────────────────────────────────
phase4_security() {
  phase "Phase 4: Security — RBAC, Network Policies, Cert-Manager, ESO"

  export KUBECONFIG="${CLUSTER_KUBECONFIG}"

  # 4a — Namespaces with Pod Security Standards
  log "4a. Creating namespaces with Pod Security Standards..."
  run kubectl apply -f "${RBAC_DIR}/00-namespace-setup.yaml"
  success "  Namespaces created"

  # 4b — RBAC policies for all team personas
  log "4b. Applying RBAC policies..."
  run kubectl apply -f "${RBAC_DIR}/01-senior-devops.yaml"
  run kubectl apply -f "${RBAC_DIR}/02-junior-devops.yaml"
  run kubectl apply -f "${RBAC_DIR}/03-developer.yaml"
  run kubectl apply -f "${RBAC_DIR}/04-read-only-auditor.yaml"
  success "  RBAC policies applied (senior-devops, junior-devops, developer, auditor)"

  # 4c — Network policies
  log "4c. Applying network policies (default-deny + monitoring allow rules)..."
  run kubectl apply -f "${SECURITY_DIR}/network-policies/"
  success "  Network policies applied"

  # 4d — cert-manager
  log "4d. Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io --force-update >> "$LOG_FILE" 2>&1 \
    || warn "  jetstack repo cache skipped (slow network — helm install below may still succeed)"
  helm repo update >> "$LOG_FILE" 2>&1 \
    || warn "  helm repo update skipped (slow network — continuing)"

  if helm status cert-manager -n cert-manager &>/dev/null; then
    log "  cert-manager already installed — upgrading..."
    run helm upgrade cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --version v1.14.5 \
      --set installCRDs=true \
      --wait --timeout 5m
  else
    run helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --version v1.14.5 \
      --set installCRDs=true \
      --wait --timeout 5m
  fi
  success "  cert-manager installed"

  # Apply ClusterIssuers (user must have filled in their email)
  log "  Applying ClusterIssuers..."
  run kubectl apply -f "${SECURITY_DIR}/tls/cluster-issuer.yaml"
  success "  ClusterIssuers created"

  # 4e — External Secrets Operator
  log "4e. Installing External Secrets Operator..."
  helm repo add external-secrets https://charts.external-secrets.io --force-update >> "$LOG_FILE" 2>&1 \
    || warn "  external-secrets repo cache skipped (slow network — helm install below may still succeed)"
  helm repo update >> "$LOG_FILE" 2>&1 \
    || warn "  helm repo update skipped (slow network — continuing)"

  if helm status external-secrets -n external-secrets &>/dev/null; then
    run helm upgrade external-secrets external-secrets/external-secrets \
      --namespace external-secrets \
      --wait --timeout 5m
  else
    run helm install external-secrets external-secrets/external-secrets \
      --namespace external-secrets \
      --create-namespace \
      --wait --timeout 5m
  fi
  success "  External Secrets Operator installed"

  # Apply ESO store config if user has configured it
  if grep -q 'YOUR_DOMAIN' "${SECURITY_DIR}/secrets/external-secrets-operator.yaml" 2>/dev/null; then
    warn "  Skipping ESO ClusterSecretStore — fill in Vault URL in security/secrets/external-secrets-operator.yaml first"
  else
    run kubectl apply -f "${SECURITY_DIR}/secrets/external-secrets-operator.yaml"
    success "  ESO ClusterSecretStore configured"
  fi

  # 4f — Generate role-specific kubeconfigs
  log "4f. Generating role-specific kubeconfigs..."
  chmod +x "${RBAC_DIR}/scripts/generate-kubeconfigs.sh"
  run_visible "${RBAC_DIR}/scripts/generate-kubeconfigs.sh" "${CLUSTER_NAME}"
  success "  Kubeconfigs generated in ${CLUSTER_DIR}/rbac-kubeconfigs/"

  success "Phase 4 complete — cluster is secured"
}

# ─── Phase 5: Observability ───────────────────────────────────────────────────
phase5_observability() {
  phase "Phase 5: Observability Stack (Prometheus + Alertmanager → central Mimir)"

  export KUBECONFIG="${CLUSTER_KUBECONFIG}"

  local tfplan="${CLUSTER_TFSTATE_DIR}/observability.tfplan"
  local var_file="${CLUSTER_DIR}/observability.tfvars"
  local state_file="${CLUSTER_TFSTATE_DIR}/observability.tfstate"

  # Add Helm repos. These are CLI-side cache only — Terraform's helm provider
  # fetches charts directly via repository URL inside helm_release. So if these
  # time out (slow github.io fetch — index.yaml can be 6+ MB), continue. The
  # terraform apply below will still work.
  log "Pre-caching Helm repos (non-fatal — TF helm provider fetches directly)..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >> "$LOG_FILE" 2>&1 \
    || warn "  prometheus-community repo cache skipped (slow network — continuing)"
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >> "$LOG_FILE" 2>&1 \
    || warn "  grafana repo cache skipped (slow network — continuing)"
  helm repo update >> "$LOG_FILE" 2>&1 \
    || warn "  helm repo update skipped (slow network — continuing)"

  cd "$TERRAFORM_OBS"

  log "Initializing observability Terraform..."
  run terraform init -upgrade

  log "Validating observability configuration..."
  run terraform validate

  log "Planning observability stack..."
  run_visible terraform plan -var-file="$var_file" -state="$state_file" -out="$tfplan"

  log "Deploying observability stack (Prometheus + Alertmanager)..."
  log "  This may take 5–10 minutes..."
  run_visible terraform apply -state="$state_file" -auto-approve "$tfplan"

  cd "$ROOT_DIR"

  # Wait for Prometheus to be ready
  log "Waiting for Prometheus to be ready..."
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=prometheus \
    -n monitoring --timeout=5m || warn "Prometheus pods still starting"

  # Display central Grafana instructions
  echo ""
  terraform -chdir="$TERRAFORM_OBS" output -state="$state_file" central_grafana_datasource_instructions 2>/dev/null || true
  echo ""

  success "Phase 5 complete — metrics flowing to central Mimir, logs to central Loki"
}

# ─── Phase 6: Cilium Ingress Verification ─────────────────────────────────────
phase6_cilium_ingress() {
  phase "Phase 6: Cilium IngressController Verification"

  export KUBECONFIG="${CLUSTER_KUBECONFIG}"

  log "Verifying Cilium IngressController is deployed..."

  # Check if CiliumIngressController is running
  if ! kubectl get deployment cilium-ingress -n kube-system &>/dev/null 2>&1; then
    warn "Cilium IngressController not found via deployment — checking via IngressClass..."
  fi

  # Check IngressClass is registered
  if kubectl get ingressclass cilium &>/dev/null 2>/dev/null; then
    success "  IngressClass 'cilium' is registered"
  else
    warn "  IngressClass 'cilium' not yet registered — may still be starting"
    log "  Cilium IngressController is enabled via rke2-cilium-config.yaml"
    log "  It will be available after Cilium reconciles (~2 minutes)"
  fi

  # Check Hubble is running
  if kubectl get pods -n kube-system -l k8s-app=hubble-relay --no-headers 2>/dev/null | grep -q Running; then
    success "  Hubble relay is running (network observability enabled)"
  else
    log "  Hubble relay starting..."
  fi

  # Test ingress with a dummy resource
  log "Testing Cilium IngressController with a smoke-test ingress..."
  kubectl apply -f - <<'EOF' >> "$LOG_FILE" 2>&1
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cilium-ingress-smoke-test
  namespace: default
  annotations:
    test: "smoke-test"
spec:
  ingressClassName: cilium
  rules:
    - host: smoke-test.cluster.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kubernetes
                port:
                  number: 443
EOF

  sleep 5
  if kubectl get ingress cilium-ingress-smoke-test -n default &>/dev/null 2>&1; then
    success "  Cilium Ingress resource accepted successfully"
    kubectl delete ingress cilium-ingress-smoke-test -n default >> "$LOG_FILE" 2>&1 || true
  else
    warn "  Smoke test ingress not accepted yet — Cilium may still be reconciling"
  fi

  echo ""
  log "Cilium Ingress usage:"
  log "  ingressClassName: cilium    (in any Ingress resource)"
  log "  Gateway API:       use GatewayClass 'cilium' for HTTPRoute/GRPCRoute"
  echo ""

  success "Phase 6 complete — Cilium IngressController active"
}

# ─── Phase 7: ArgoCD ──────────────────────────────────────────────────────────
phase7_argocd() {
  phase "Phase 7: ArgoCD — GitOps Control Plane"

  export KUBECONFIG="${CLUSTER_KUBECONFIG}"

  local tfplan="${CLUSTER_TFSTATE_DIR}/argocd.tfplan"
  local var_file="${CLUSTER_DIR}/argocd.tfvars"
  local state_file="${CLUSTER_TFSTATE_DIR}/argocd.tfstate"

  # Optional phase: skip cleanly if the user hasn't filled in tfvars.
  if [[ ! -f "$var_file" ]]; then
    warn "No ${var_file} — skipping Phase 7."
    warn "  To enable later: copy clusters/_template/argocd.tfvars there, edit,"
    warn "  then run: ./scripts/deploy.sh ${CLUSTER_NAME} --only phase7"
    return 0
  fi

  cd "$TERRAFORM_ARGOCD"

  log "Initializing ArgoCD Terraform..."
  run terraform init -upgrade

  log "Validating ArgoCD configuration..."
  run terraform validate

  log "Planning ArgoCD stack..."
  run_visible terraform plan -var-file="$var_file" -state="$state_file" -out="$tfplan"

  log "Applying ArgoCD stack (creates argocd namespace + Helm release;"
  log "  optionally LB IP pool + L2 policy + Ingress if argocd_ingress_enabled=true)..."
  log "  This may take 3–5 minutes..."
  run_visible terraform apply -state="$state_file" -auto-approve "$tfplan"

  cd "$ROOT_DIR"

  log "Waiting for argocd-server to be ready..."
  kubectl wait --for=condition=Available deployment/argocd-server \
    -n argocd --timeout=5m || warn "argocd-server not yet Available"

  # If the Ingress path was enabled, the pool/policy/cert should exist now.
  if kubectl get ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 \
     && [[ $(kubectl get ciliumloadbalancerippools.cilium.io -o name 2>/dev/null | wc -l) -gt 0 ]]; then
    log "Verifying LB IP pool + L2 announcement policy..."
    kubectl get ciliumloadbalancerippools.cilium.io
    kubectl get ciliuml2announcementpolicies.cilium.io
    kubectl -n kube-system get svc cilium-ingress \
      -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip
  fi

  # Print day-1 access instructions from the module's output
  echo ""
  terraform -chdir="$TERRAFORM_ARGOCD" output -state="$state_file" -raw argocd_access_instructions 2>/dev/null || true
  echo ""
  terraform -chdir="$TERRAFORM_ARGOCD" output -state="$state_file" -raw argocd_ingress 2>/dev/null || true
  echo ""

  success "Phase 7 complete — ArgoCD is up. Rotate the admin password and delete"
  success "  argocd-initial-admin-secret as soon as you've logged in."
}

# ─── Final Summary ─────────────────────────────────────────────────────────────
print_summary() {
  phase "Deployment Complete — ${CLUSTER_NAME}"

  export KUBECONFIG="${CLUSTER_KUBECONFIG}"

  echo -e "${BOLD}Cluster:${NC} ${CLUSTER_NAME}"
  echo ""

  echo -e "${BOLD}Cluster Status:${NC}"
  kubectl get nodes -o wide 2>/dev/null || true
  echo ""

  echo -e "${BOLD}Pod Health:${NC}"
  kubectl get pods -A --no-headers 2>/dev/null | \
    awk '{print $4}' | sort | uniq -c | sort -rn | \
    while read count status; do
      [[ "$status" == "Running" || "$status" == "Completed" ]] && \
        echo -e "  ${GREEN}${count} ${status}${NC}" || \
        echo -e "  ${YELLOW}${count} ${status}${NC}"
    done
  echo ""

  echo -e "${BOLD}Access:${NC}"
  echo -e "  Admin kubeconfig:  ${CYAN}${CLUSTER_KUBECONFIG}${NC}"
  echo -e "  Role kubeconfigs:  ${CYAN}${CLUSTER_DIR}/rbac-kubeconfigs/${NC}"
  echo -e "  Deploy logs:       ${CYAN}${LOG_FILE}${NC}"
  echo ""

  CONTROL_PLANE_VIP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||;s|:.*||')
  echo -e "${BOLD}Endpoints:${NC}"
  echo -e "  API server (VIP):  ${CYAN}https://${CONTROL_PLANE_VIP}:6443${NC}"
  echo ""

  echo -e "${BOLD}Next steps:${NC}"
  echo -e "  1. Add cluster label filter in your central Grafana: ${CYAN}cluster=\"${CLUSTER_NAME}\"${NC}"
  echo -e "  2. Import dashboards: 7249 (cluster), 1860 (nodes), 3070 (etcd)"
  echo -e "  3. Distribute role kubeconfigs to your team (secure channel)"
  echo -e "  4. Configure ESO ClusterSecretStore with your Vault URL"
  echo ""
  success "Deployment finished. Full log at: ${LOG_FILE}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  cat << 'BANNER'
  ╦═╗╦╔═╔═╗  ╔═╗╦  ╦ ╦╔═╗╔╦╗╔═╗╦═╗
  ╠╦╝╠╩╗║╣   ║  ║  ║ ║╚═╗ ║ ║╣ ╠╦╝
  ╩╚═╩ ╩╚═╝  ╚═╝╩═╝╚═╝╚═╝ ╩ ╚═╝╩╚═
BANNER
  echo -e "  ${BOLD}Cluster:${NC} ${CLUSTER_NAME}    ${BOLD}Phases:${NC} ${START_PHASE}–${END_PHASE}"
  echo -e "${NC}"

  log "Log file: ${LOG_FILE}"
  log "Starting from phase ${START_PHASE}, ending at phase ${END_PHASE}"
  [[ "$DRY_RUN" == "true" ]] && warn "DRY-RUN MODE — no changes will be made"
  echo ""

  check_prerequisites

  should_run 2 && phase2_terraform_proxmox
  should_run 3 && phase3_rke2_install
  should_run 4 && phase4_security
  should_run 5 && phase5_observability
  should_run 6 && phase6_cilium_ingress
  should_run 7 && phase7_argocd

  print_summary
}

main "$@"
