#!/usr/bin/env bash
################################################################################
# deploy.sh — Full Automated Deployment: Phases 2–7
#
# Usage:
#   ./scripts/deploy.sh                   # Full deployment
#   ./scripts/deploy.sh --from phase3     # Resume from a specific phase
#   ./scripts/deploy.sh --only phase4     # Run a single phase
#   ./scripts/deploy.sh --dry-run         # Validate without applying
#
# Prerequisites (Phase 1 — manual):
#   - Proxmox API token created
#   - Ubuntu 22.04 cloud-init template created
#   - terraform.tfvars files filled in (see *.tfvars.example files)
#     (terraform/argocd/terraform.tfvars is optional — see Phase 7 below)
#   - SSH key for VM access available
#
# Phase 2: Terraform → Proxmox VMs
# Phase 3: RKE2 cluster installation (masters → workers)
#          Cilium config includes L2 announcements + LB IPAM (flags enabled,
#          pool itself is created in Phase 7).
# Phase 4: Security (namespaces, RBAC, NetworkPolicies, cert-manager, ESO, kubeconfigs)
# Phase 5: Observability (Prometheus + Alertmanager via Terraform; Alloy already on VMs)
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
LOG_DIR="${ROOT_DIR}/.logs"
LOG_FILE="${LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$SECRETS_DIR" "$LOG_DIR"
chmod 700 "$SECRETS_DIR"

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

while [[ $# -gt 0 ]]; do
  case $1 in
    --from)
      START_PHASE="${2//phase/}"; shift 2 ;;
    --only)
      p="${2//phase/}"; START_PHASE="$p"; END_PHASE="$p"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    *)
      echo "Unknown argument: $1"; exit 1 ;;
  esac
done

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

  # Check tfvars files exist (not just examples)
  [[ -f "${TERRAFORM_PROXMOX}/terraform.tfvars" ]] || \
    err "Missing terraform.tfvars\n  cp ${TERRAFORM_PROXMOX}/terraform.tfvars.example ${TERRAFORM_PROXMOX}/terraform.tfvars\n  Then fill in your values."

  [[ -f "${TERRAFORM_OBS}/terraform.tfvars" ]] || \
    err "Missing observability terraform.tfvars\n  cp ${TERRAFORM_OBS}/terraform.tfvars.example ${TERRAFORM_OBS}/terraform.tfvars\n  Then fill in your Mimir and Loki URLs."

  # ArgoCD tfvars is optional — if absent we skip Phase 7 cleanly later.
  if [[ ! -f "${TERRAFORM_ARGOCD}/terraform.tfvars" ]]; then
    warn "No ${TERRAFORM_ARGOCD}/terraform.tfvars — Phase 7 (ArgoCD) will be skipped."
    warn "  To enable: cp terraform.tfvars.example terraform.tfvars and edit."
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

  cd "$TERRAFORM_PROXMOX"

  log "Initializing Terraform..."
  run terraform init -upgrade

  log "Validating configuration..."
  run terraform validate

  log "Planning infrastructure..."
  run_visible terraform plan -out=cluster.tfplan

  log "Applying infrastructure (this creates VMs — may take 10–15 minutes)..."
  run_visible terraform apply -auto-approve cluster.tfplan

  # Extract outputs for use in later phases
  log "Extracting Terraform outputs..."
  terraform output -json > "${SECRETS_DIR}/tf-outputs.json"
  INIT_MASTER_IP=$(terraform output -raw init_master_ip)
  CONTROL_PLANE_VIP=$(terraform output -raw control_plane_vip)
  log "  Init master IP:     ${INIT_MASTER_IP}"
  log "  Control plane VIP:  ${CONTROL_PLANE_VIP}"

  # Wait for VMs to be reachable via SSH
  log "Waiting for VMs to boot and cloud-init to complete..."
  VM_IPS=$(terraform output -json all_node_ips | jq -r '.[]')

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

  log "Installing RKE2 agents on worker nodes..."
  run_visible "${RKE2_SCRIPTS}/install-worker.sh"

  # Set KUBECONFIG for subsequent phases
  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

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

  success "Phase 3 complete — RKE2 cluster is up with Cilium CNI"
}

# ─── Phase 4: Security ────────────────────────────────────────────────────────
phase4_security() {
  phase "Phase 4: Security — RBAC, Network Policies, Cert-Manager, ESO"

  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

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
  helm repo add jetstack https://charts.jetstack.io --force-update >> "$LOG_FILE" 2>&1
  helm repo update >> "$LOG_FILE" 2>&1

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
  helm repo add external-secrets https://charts.external-secrets.io --force-update >> "$LOG_FILE" 2>&1
  helm repo update >> "$LOG_FILE" 2>&1

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
  run_visible "${RBAC_DIR}/scripts/generate-kubeconfigs.sh"
  success "  Kubeconfigs generated in rbac/kubeconfigs/"

  success "Phase 4 complete — cluster is secured"
}

# ─── Phase 5: Observability ───────────────────────────────────────────────────
phase5_observability() {
  phase "Phase 5: Observability Stack (Prometheus + Alertmanager → central Mimir)"

  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

  # Add Helm repos
  log "Adding Helm repositories..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >> "$LOG_FILE" 2>&1
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >> "$LOG_FILE" 2>&1
  helm repo update >> "$LOG_FILE" 2>&1
  success "  Helm repos ready"

  cd "$TERRAFORM_OBS"

  log "Initializing observability Terraform..."
  run terraform init -upgrade

  log "Validating observability configuration..."
  run terraform validate

  log "Planning observability stack..."
  run_visible terraform plan -out=obs.tfplan

  log "Deploying observability stack (Prometheus + Alertmanager)..."
  log "  This may take 5–10 minutes..."
  run_visible terraform apply -auto-approve obs.tfplan

  cd "$ROOT_DIR"

  # Wait for Prometheus to be ready
  log "Waiting for Prometheus to be ready..."
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=prometheus \
    -n monitoring --timeout=5m || warn "Prometheus pods still starting"

  # Display central Grafana instructions
  echo ""
  terraform -chdir="$TERRAFORM_OBS" output central_grafana_datasource_instructions 2>/dev/null || true
  echo ""

  success "Phase 5 complete — metrics flowing to central Mimir, logs to central Loki"
}

# ─── Phase 6: Cilium Ingress Verification ─────────────────────────────────────
phase6_cilium_ingress() {
  phase "Phase 6: Cilium IngressController Verification"

  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

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

  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

  # Optional phase: skip cleanly if the user hasn't filled in tfvars.
  if [[ ! -f "${TERRAFORM_ARGOCD}/terraform.tfvars" ]]; then
    warn "No ${TERRAFORM_ARGOCD}/terraform.tfvars — skipping Phase 7."
    warn "  To enable later: cp terraform.tfvars.example terraform.tfvars, edit,"
    warn "  then run: ./scripts/deploy.sh --only phase7"
    return 0
  fi

  cd "$TERRAFORM_ARGOCD"

  log "Initializing ArgoCD Terraform..."
  run terraform init -upgrade

  log "Validating ArgoCD configuration..."
  run terraform validate

  log "Planning ArgoCD stack..."
  run_visible terraform plan -out=argocd.tfplan

  log "Applying ArgoCD stack (creates argocd namespace + Helm release;"
  log "  optionally LB IP pool + L2 policy + Ingress if argocd_ingress_enabled=true)..."
  log "  This may take 3–5 minutes..."
  run_visible terraform apply -auto-approve argocd.tfplan

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
  terraform -chdir="$TERRAFORM_ARGOCD" output -raw argocd_access_instructions 2>/dev/null || true
  echo ""
  terraform -chdir="$TERRAFORM_ARGOCD" output -raw argocd_ingress 2>/dev/null || true
  echo ""

  success "Phase 7 complete — ArgoCD is up. Rotate the admin password and delete"
  success "  argocd-initial-admin-secret as soon as you've logged in."
}

# ─── Final Summary ─────────────────────────────────────────────────────────────
print_summary() {
  phase "Deployment Complete"

  export KUBECONFIG="${SECRETS_DIR}/kubeconfig-admin.yaml"

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
  echo -e "  Admin kubeconfig:  ${CYAN}${SECRETS_DIR}/kubeconfig-admin.yaml${NC}"
  echo -e "  Role kubeconfigs:  ${CYAN}${ROOT_DIR}/rbac/kubeconfigs/${NC}"
  echo -e "  Deploy logs:       ${CYAN}${LOG_FILE}${NC}"
  echo ""

  CONTROL_PLANE_VIP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||;s|:.*||')
  echo -e "${BOLD}Endpoints:${NC}"
  echo -e "  API server (VIP):  ${CYAN}https://${CONTROL_PLANE_VIP}:6443${NC}"
  echo ""

  echo -e "${BOLD}Next steps:${NC}"
  echo -e "  1. Add cluster label filter in your central Grafana: ${CYAN}cluster=\"rke2-prod\"${NC}"
  echo -e "  2. Import dashboards: 7249 (cluster), 1860 (nodes), 3070 (etcd)"
  echo -e "  3. Distribute role kubeconfigs to your team"
  echo -e "  5. Configure ESO ClusterSecretStore with your Vault URL"
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
  Automated Deploy: Phases 2–7
BANNER
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
