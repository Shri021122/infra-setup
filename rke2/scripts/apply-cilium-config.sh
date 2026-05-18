#!/usr/bin/env bash
################################################################################
# apply-cilium-config.sh — Push rke2-cilium-config.yaml to the init master
# and wait for RKE2's helm-controller to reconcile.
#
# Use this after editing rke2/configs/rke2-cilium-config.yaml on a live cluster
# (e.g. flipping a feature flag like l2announcements). For a fresh deploy this
# is unnecessary — install-master.sh does the same work during Phase 3.
#
# Idempotent. Safe to re-run.
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIGS_DIR="${ROOT_DIR}/rke2/configs"
INVENTORY="${CONFIGS_DIR}/inventory.ini"
CILIUM_CONFIG_SRC="${CONFIGS_DIR}/rke2-cilium-config.yaml"

[[ -f "$INVENTORY" ]] || { echo "ERROR: $INVENTORY not found"; exit 1; }
[[ -f "$CILIUM_CONFIG_SRC" ]] || { echo "ERROR: $CILIUM_CONFIG_SRC not found"; exit 1; }

# Same source-of-truth deploy.sh uses
SSH_KEY=$(grep 'ansible_ssh_private_key_file=' "$INVENTORY" | head -1 | cut -d= -f2 | tr -d '"' | sed "s|^~|$HOME|")
SSH_USER=$(grep 'ansible_user=' "$INVENTORY" | head -1 | cut -d= -f2)
: "${SSH_KEY:=$HOME/.ssh/rke2_cluster_id}"
: "${SSH_USER:=ubuntu}"

# Init master is whichever entry has is_init_node=true in [masters]
INIT_MASTER_IP=$(awk '/^\[masters\]/{f=1; next} /^\[/{f=0} f && /is_init_node=true/' "$INVENTORY" \
                  | grep -oP 'ansible_host=\K[^ ]+' | head -1)
[[ -n "$INIT_MASTER_IP" ]] || { echo "ERROR: could not find init master in $INVENTORY"; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Init master: ${INIT_MASTER_IP}"
log "SSH user: ${SSH_USER}, key: ${SSH_KEY}"

# Match install-master.sh's substitution: each cilium pod targets the local
# apiserver, so the placeholder becomes the node's own IP, not the VIP.
TMP_PATCHED=$(mktemp /tmp/cilium-patched.XXXXXX.yaml)
trap "rm -f $TMP_PATCHED" EXIT
sed "s/CONTROL_PLANE_VIP_PLACEHOLDER/${INIT_MASTER_IP}/g" "$CILIUM_CONFIG_SRC" > "$TMP_PATCHED"

log "Copying patched cilium config to init master..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "$TMP_PATCHED" \
    "${SSH_USER}@${INIT_MASTER_IP}:/tmp/rke2-cilium-config.yaml" >/dev/null

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${SSH_USER}@${INIT_MASTER_IP}" \
    "sudo mv /tmp/rke2-cilium-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml \
     && sudo chmod 600 /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml"

log "Config in place. Waiting for RKE2 helm-controller to apply the new values..."

KCFG="${ROOT_DIR}/.secrets/kubeconfig-admin.yaml"
if [[ ! -f "$KCFG" ]]; then
  log "No local kubeconfig at ${KCFG} — verify manually:"
  log "  kubectl -n kube-system get helmchartconfig rke2-cilium -o yaml"
  log "  kubectl -n kube-system rollout restart daemonset/cilium deployment/cilium-operator"
  exit 0
fi
export KUBECONFIG="$KCFG"

# Wait for the helm-install Job created by helm-controller to complete.
# That's what actually re-renders the chart with our new values.
for _ in $(seq 1 30); do
  if kubectl -n kube-system get job helm-install-rke2-cilium \
       -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q '^1$'; then
    log "helm-install-rke2-cilium Job succeeded."
    break
  fi
  sleep 2
done

# helm-controller does NOT reliably restart cilium pods on a values change
# (the rendered daemonset spec often hashes identically). Force a rollout
# so the new feature flags actually land in the running cilium-agent + operator.
log "Restarting cilium daemonset + operator to pick up new flags..."
kubectl -n kube-system rollout restart daemonset/cilium deployment/cilium-operator

log "Waiting for cilium daemonset rollout..."
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s

log "Waiting for cilium-operator rollout..."
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=180s

# Verify the flag actually landed in the live ConfigMap
l2=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-l2-announcements}' 2>/dev/null)
if [[ "$l2" == "true" ]]; then
  log "✓ enable-l2-announcements=true in cilium-config"
else
  log "WARN: enable-l2-announcements=${l2:-<unset>} — expected 'true'. Check the HelmChartConfig values."
fi

log "Done."
