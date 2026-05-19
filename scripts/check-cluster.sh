#!/usr/bin/env bash
################################################################################
# check-cluster.sh — Pre-deploy / pre-redeploy sanity check for ONE cluster
#
# Runs read-only verifications:
#   1. cluster directory + tfvars exist
#   2. cluster_name consistency across the three tfvars
#   3. no IP/VM-ID collisions with OTHER clusters in clusters/
#   4. IP reachability (ping) — flags conflicts on the network
#   5. terraform validate per module
#   6. terraform plan per module — summary only
#
# Exits 0 if everything looks safe to deploy. Non-zero if something needs
# attention. NEVER applies anything.
#
# Usage:
#   ./scripts/check-cluster.sh <cluster-name>
#   ./scripts/check-cluster.sh <cluster-name> --skip-plan   # skip the slowest step
#
# Requires (for full plan check): TF_VAR_proxmox_api_token exported.
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTERS_DIR="${ROOT_DIR}/clusters"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()    { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }
pass()    { echo -e "  ${GREEN}✓${NC} $*"; }
warnmsg() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail()    { echo -e "  ${RED}✗${NC} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ─── Args ─────────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || { echo "Usage: $0 <cluster-name> [--skip-plan]"; exit 1; }
CLUSTER_NAME="$1"; shift
SKIP_PLAN=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-plan) SKIP_PLAN=true; shift ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *)           echo "Unknown arg: $1"; exit 1 ;;
  esac
done

CLUSTER_DIR="${CLUSTERS_DIR}/${CLUSTER_NAME}"
TFSTATE_DIR="${CLUSTER_DIR}/tfstate"

WARN_COUNT=0
FAIL_COUNT=0

echo -e "${BOLD}${CYAN}Pre-deploy check — cluster: ${CLUSTER_NAME}${NC}"

# ─── 1. Cluster directory + required tfvars exist ────────────────────────────
step "1. Cluster directory & required files"
if [[ ! -d "$CLUSTER_DIR" ]]; then
  fail "${CLUSTER_DIR}/ does not exist. Run: ./scripts/new-cluster.sh ${CLUSTER_NAME}"
  exit 1
fi
pass "clusters/${CLUSTER_NAME}/ exists"

for f in proxmox.tfvars observability.tfvars; do
  if [[ -f "${CLUSTER_DIR}/${f}" ]]; then
    pass "${f} present"
  else
    fail "${f} missing — run ./scripts/new-cluster.sh ${CLUSTER_NAME} to scaffold"
  fi
done
if [[ -f "${CLUSTER_DIR}/argocd.tfvars" ]]; then
  pass "argocd.tfvars present (Phase 7 will run)"
else
  warnmsg "argocd.tfvars missing — Phase 7 will be skipped (often intentional)"
fi

# ─── 2. cluster_name consistency ─────────────────────────────────────────────
step "2. cluster_name consistency across tfvars"
for f in proxmox.tfvars observability.tfvars argocd.tfvars; do
  [[ -f "${CLUSTER_DIR}/${f}" ]] || continue
  declared=$(grep -E '^cluster_name\s*=' "${CLUSTER_DIR}/${f}" 2>/dev/null \
             | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/')
  if [[ "$declared" == "$CLUSTER_NAME" ]]; then
    pass "${f}: cluster_name = \"${declared}\" ✓ matches folder"
  else
    fail "${f}: cluster_name = \"${declared}\" — should be \"${CLUSTER_NAME}\""
  fi
done

# ─── 3. Cross-cluster IP + VM ID collisions ──────────────────────────────────
step "3. Conflicts with OTHER clusters in clusters/"

# Extract only the IPs we PROVISION — masters, workers, control-plane VIP, LB
# pool IP. NOT gateway, DNS, subnet base, or service-CIDR (those are network
# plumbing that any cluster on this subnet legitimately shares).
extract_provisioned_ips() {
  local cluster_dir="$1"
  {
    # master/worker_ip_addresses may be written as:
    #   inline:   master_ip_addresses = ["10.x.y.1", "10.x.y.2"]   ← wizard's format
    #   multi:    master_ip_addresses = [
    #               "10.x.y.1",
    #               "10.x.y.2",
    #             ]                                                  ← hand-edited format
    # State machine: enter in_list on the assignment line (and print it so
    # inline IPs are captured); exit on the FIRST line containing `]`.
    awk '
      /^[[:space:]]*(master|worker)_ip_addresses[[:space:]]*=/ { in_list=1 }
      in_list {
        print
        if ($0 ~ /\]/) in_list = 0
      }
    ' "$cluster_dir"/*.tfvars 2>/dev/null \
      | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"'
    # control_plane_vip (single string)
    grep -hE '^[[:space:]]*control_plane_vip[[:space:]]*=' "$cluster_dir"/*.tfvars 2>/dev/null \
      | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"'
    # argocd LB pool CIDR — strip the /xx
    grep -hE '^[[:space:]]*argocd_lb_ip_pool_cidr' "$cluster_dir"/*.tfvars 2>/dev/null \
      | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr -d '"'
  } | sort -u
}

this_ips=$(extract_provisioned_ips "$CLUSTER_DIR")
other_clusters=$(find "$CLUSTERS_DIR" -maxdepth 1 -mindepth 1 -type d \
                   ! -name "_template" ! -name "${CLUSTER_NAME}" 2>/dev/null)

if [[ -z "$other_clusters" ]]; then
  pass "No other clusters defined — nothing to conflict with"
else
  conflict_found=false
  for other in $other_clusters; do
    other_name=$(basename "$other")
    other_ips=$(extract_provisioned_ips "$other")
    overlap=$(comm -12 <(echo "$this_ips") <(echo "$other_ips") 2>/dev/null)
    if [[ -n "$overlap" ]]; then
      conflict_found=true
      fail "IP collision with cluster '${other_name}': $(echo $overlap | tr '\n' ' ')"
    fi
  done
  $conflict_found || pass "No IP collisions across $(echo "$other_clusters" | wc -l) other clusters"
fi

# VM ID collision check
this_master=$(grep -E '^master_vm_id_start' "${CLUSTER_DIR}/proxmox.tfvars" 2>/dev/null | sed -E 's/.*=\s*([0-9]+).*/\1/')
this_worker=$(grep -E '^worker_vm_id_start' "${CLUSTER_DIR}/proxmox.tfvars" 2>/dev/null | sed -E 's/.*=\s*([0-9]+).*/\1/')
this_mc=$(grep -E '^master_count' "${CLUSTER_DIR}/proxmox.tfvars" 2>/dev/null | sed -E 's/.*=\s*([0-9]+).*/\1/')
this_wc=$(grep -E '^worker_count' "${CLUSTER_DIR}/proxmox.tfvars" 2>/dev/null | sed -E 's/.*=\s*([0-9]+).*/\1/')

if [[ -n "$this_master" && -n "$this_worker" && -n "$this_mc" && -n "$this_wc" ]]; then
  this_m_end=$((this_master + this_mc - 1))
  this_w_end=$((this_worker + this_wc - 1))
  pass "This cluster owns VM IDs ${this_master}-${this_m_end} (masters) + ${this_worker}-${this_w_end} (workers)"

  # Compare against each other cluster
  for other in $other_clusters; do
    other_name=$(basename "$other")
    [[ -f "$other/proxmox.tfvars" ]] || continue
    o_master=$(grep -E '^master_vm_id_start' "$other/proxmox.tfvars" | sed -E 's/.*=\s*([0-9]+).*/\1/')
    o_worker=$(grep -E '^worker_vm_id_start' "$other/proxmox.tfvars" | sed -E 's/.*=\s*([0-9]+).*/\1/')
    o_mc=$(grep -E '^master_count' "$other/proxmox.tfvars" | sed -E 's/.*=\s*([0-9]+).*/\1/')
    o_wc=$(grep -E '^worker_count' "$other/proxmox.tfvars" | sed -E 's/.*=\s*([0-9]+).*/\1/')
    [[ -n "$o_master" && -n "$o_worker" && -n "$o_mc" && -n "$o_wc" ]] || continue
    o_m_end=$((o_master + o_mc - 1))
    o_w_end=$((o_worker + o_wc - 1))
    # Build flat lists and intersect
    this_ids=$(seq $this_master $this_m_end; seq $this_worker $this_w_end)
    other_ids=$(seq $o_master $o_m_end; seq $o_worker $o_w_end)
    overlap=$(echo -e "$this_ids\n$other_ids" | sort | uniq -d)
    if [[ -n "$overlap" ]]; then
      fail "VM-ID collision with cluster '${other_name}': IDs $(echo $overlap | tr '\n' ' ')"
    fi
  done
fi

# ─── 4. IP reachability (ping) ───────────────────────────────────────────────
step "4. IP reachability (network sanity)"
# For a fresh deploy: every IP should be FREE.
# For a redeploy: master/worker/VIP IPs SHOULD respond (they're your VMs).
# We just report; the operator interprets based on context.
for ip in $this_ips; do
  if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    echo -e "    $ip → ${YELLOW}responds${NC}  (good for redeploy of existing cluster; bad for fresh deploy)"
  else
    echo -e "    $ip → ${GREEN}silent${NC}     (good for fresh deploy; bad for redeploy)"
  fi
done

# ─── 5. terraform validate per module ────────────────────────────────────────
step "5. terraform validate (HCL syntax + variable types)"
for mod in proxmox observability argocd; do
  [[ -f "${CLUSTER_DIR}/${mod}.tfvars" ]] || { warnmsg "skipping ${mod} (no tfvars)"; continue; }
  # validate needs providers downloaded — silently init if first time
  if [[ ! -d "${ROOT_DIR}/terraform/${mod}/.terraform" ]]; then
    ( cd "${ROOT_DIR}/terraform/${mod}" && terraform init -upgrade -no-color ) >/dev/null 2>&1 \
      || { warnmsg "terraform/${mod}: init failed — skipping validate"; continue; }
  fi
  if terraform -chdir="${ROOT_DIR}/terraform/${mod}" validate -no-color >/dev/null 2>&1; then
    pass "terraform/${mod}: valid"
  else
    fail "terraform/${mod}: validation failed — run \`terraform -chdir=terraform/${mod} validate\` for details"
  fi
done

# ─── 6. terraform plan per module ────────────────────────────────────────────
if $SKIP_PLAN; then
  step "6. terraform plan — SKIPPED (--skip-plan)"
else
  step "6. terraform plan per module (slowest step; reads state)"

  if [[ -z "${TF_VAR_proxmox_api_token:-}" && -z "${TF_VAR_proxmox_password:-}" ]]; then
    warnmsg "TF_VAR_proxmox_api_token not exported — plan for terraform/proxmox will fail"
    warnmsg "Skipping proxmox plan; continuing with observability + argocd"
  fi

  # Fresh-deploy detection: observability + argocd modules use the kubernetes
  # provider, which tries to authenticate at PLAN time. On a fresh deploy
  # there's no cluster + no kubeconfig yet — those plans will fail with
  # "connection refused" or "kubeconfig: no such file". That's expected, NOT
  # a check failure. Detect and skip cleanly.
  fresh_deploy=false
  if [[ ! -f "${CLUSTER_KUBECONFIG:-${CLUSTER_DIR}/kubeconfig.yaml}" ]]; then
    fresh_deploy=true
    echo "  (Detected fresh deploy — no kubeconfig yet at ${CLUSTER_DIR}/kubeconfig.yaml)"
    echo "  observability + argocd plans will be skipped (they need a live cluster)."
  fi

  for mod in proxmox observability argocd; do
    [[ -f "${CLUSTER_DIR}/${mod}.tfvars" ]] || continue

    # Skip k8s-provider modules on fresh deploys — no point trying.
    if $fresh_deploy && [[ "$mod" != "proxmox" ]]; then
      warnmsg "    ${mod}: skipped (fresh deploy, no cluster API to plan against yet)"
      continue
    fi

    state_file="${TFSTATE_DIR}/${mod}.tfstate"
    plan_args=(-var-file="${CLUSTER_DIR}/${mod}.tfvars")
    [[ -f "$state_file" ]] && plan_args+=(-state="$state_file")

    echo "  ── ${mod} ──"
    # init silently if needed (no providers in .terraform yet)
    if [[ ! -d "${ROOT_DIR}/terraform/${mod}/.terraform" ]]; then
      ( cd "${ROOT_DIR}/terraform/${mod}" && terraform init -upgrade -no-color ) >/dev/null 2>&1 \
        || { warnmsg "    terraform init failed for ${mod} — skipping plan"; continue; }
    fi
    plan_output=$( cd "${ROOT_DIR}/terraform/${mod}" \
                   && terraform plan -refresh=false -no-color "${plan_args[@]}" 2>&1 ) || true
    summary=$(echo "$plan_output" | grep -E "^Plan:|^No changes|forces replacement|Error:" | head -5)

    if echo "$summary" | grep -q "No changes"; then
      pass "    No changes — state matches config (safe to re-run)"
    elif echo "$summary" | grep -q "forces replacement"; then
      fail "    FORCES REPLACEMENT — read the full plan carefully before deploying!"
      echo "$plan_output" | grep -B1 "forces replacement" | head -10 | sed 's/^/      /'
    elif echo "$summary" | grep -qE "^Plan: [0-9]+ to add"; then
      adds=$(echo "$summary" | grep -oE "[0-9]+ to add" | head -1)
      changes=$(echo "$summary" | grep -oE "[0-9]+ to change" | head -1)
      destroys=$(echo "$summary" | grep -oE "[0-9]+ to destroy" | head -1)
      if [[ "$destroys" == "0 to destroy" ]]; then
        pass "    ${adds}, ${changes}, ${destroys}"
      else
        warnmsg "    ${adds}, ${changes}, ${destroys} — review the destroy list before applying"
      fi
    elif echo "$summary" | grep -q "Error:"; then
      # Connection-refused / no-kubeconfig errors during fresh deploy are
      # benign (we filtered above), but if we get here it's a real error.
      if echo "$plan_output" | grep -qE "connect: connection refused|no such file or directory.*kubeconfig|Unable to load credentials"; then
        warnmsg "    ${mod}: plan needs a live cluster — skip on fresh deploys"
      else
        fail "    plan errored — see: terraform -chdir=terraform/${mod} plan -var-file=... -state=..."
        echo "$summary" | head -3 | sed 's/^/      /'
      fi
    else
      warnmsg "    plan output unclear — run the command manually to inspect"
    fi
  done
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
if [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}  ALL GREEN — safe to deploy ${CLUSTER_NAME}${NC}"
  echo -e "  Next:  ${CYAN}./scripts/deploy.sh ${CLUSTER_NAME}${NC}"
  exit 0
elif [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "${BOLD}${YELLOW}  ${WARN_COUNT} warning(s) — review, then deploy if expected${NC}"
  echo -e "  Next:  ${CYAN}./scripts/deploy.sh ${CLUSTER_NAME}${NC}"
  exit 0
else
  echo -e "${BOLD}${RED}  ${FAIL_COUNT} fail(s), ${WARN_COUNT} warning(s) — fix before deploying${NC}"
  exit 1
fi
