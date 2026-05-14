# Backup Strategy & Upgrade Procedures

## Backup Strategy

### etcd Snapshots

RKE2 automatically snapshots etcd every 6 hours (configured in master config).
Snapshots are stored at `/var/lib/rancher/rke2/server/db/snapshots/` on each master.

**Manual snapshot:**
```bash
# SSH to any master
ssh ubuntu@192.168.10.101

# Create snapshot
sudo /var/lib/rancher/rke2/bin/rke2 etcd-snapshot save \
  --name manual-$(date +%Y%m%d-%H%M%S)

# List snapshots
sudo /var/lib/rancher/rke2/bin/rke2 etcd-snapshot list
```

**Offsite backup (configure in cron):**
```bash
# Copy snapshots to S3 — run on each master
#!/bin/bash
SNAPSHOT_DIR="/var/lib/rancher/rke2/server/db/snapshots"
S3_BUCKET="s3://your-backup-bucket/rke2-etcd/$(hostname)"
aws s3 sync "$SNAPSHOT_DIR" "$S3_BUCKET" --delete
```

**etcd Restore procedure:**
```bash
# ONLY run on a STOPPED cluster. Stop rke2 on ALL nodes first.

# On init master:
sudo systemctl stop rke2-server

# Restore from snapshot
sudo /var/lib/rancher/rke2/bin/rke2 etcd-snapshot restore \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<snapshot-name>

sudo systemctl start rke2-server

# Start other masters after init master is healthy
# Then start all workers
```

### Persistent Volume Backups

Use **Velero** for application-level backups including PVCs:

```bash
# Install Velero with S3 backend
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set configuration.backupStorageLocation[0].name=default \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].bucket=your-velero-bucket \
  --set configuration.backupStorageLocation[0].config.region=us-east-1 \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins

# Create daily backup schedule
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --ttl 720h \
  --include-namespaces production,staging \
  --snapshot-volumes

# Manual backup
velero backup create pre-upgrade-backup --include-namespaces production
```

### Proxmox VM Snapshots

```bash
# Create VM snapshot before upgrades (Proxmox API)
# Run from Proxmox host:
qm snapshot 300 pre-upgrade --description "Before RKE2 upgrade $(date)"
qm snapshot 301 pre-upgrade --description "Before RKE2 upgrade $(date)"
qm snapshot 302 pre-upgrade --description "Before RKE2 upgrade $(date)"

# List snapshots
qm listsnapshot 300
```

---

## RKE2 Upgrade Procedure

**Strategy: Rolling upgrade — one node at a time. Zero-downtime.**

### Pre-upgrade checklist
- [ ] Take etcd snapshot
- [ ] Take Velero backup of production namespace
- [ ] Take Proxmox VM snapshots of all masters
- [ ] Verify cluster health: `kubectl get nodes && kubectl get pods -A | grep -v Running`
- [ ] Read RKE2 release notes for breaking changes
- [ ] Test upgrade in staging first

### Step 1: Upgrade first master (init master)

```bash
TARGET_VERSION="v1.30.1+rke2r1"

# SSH to init master
ssh ubuntu@192.168.10.101

# Download and install new version
curl -sfL https://get.rke2.io | \
  INSTALL_RKE2_VERSION="${TARGET_VERSION}" \
  INSTALL_RKE2_TYPE="server" \
  sh -

# Restart RKE2 (brief API server interruption — kube-vip keeps VIP alive)
sudo systemctl restart rke2-server

# Wait for node to become Ready (2-3 minutes)
watch kubectl get nodes
```

### Step 2: Upgrade remaining masters (one at a time)

```bash
# For each additional master (101, 102)
for MASTER_IP in 192.168.10.102 192.168.10.103; do
  echo "Upgrading master ${MASTER_IP}..."
  ssh ubuntu@${MASTER_IP} "
    curl -sfL https://get.rke2.io | \
      INSTALL_RKE2_VERSION='${TARGET_VERSION}' \
      INSTALL_RKE2_TYPE='server' \
      sh -
    sudo systemctl restart rke2-server
  "
  echo "Waiting for node to be Ready..."
  sleep 60
  kubectl get nodes
done
```

### Step 3: Upgrade workers (drain → upgrade → uncordon)

```bash
for WORKER in rke2-worker-1 rke2-worker-2; do
  WORKER_IP=$(kubectl get node "$WORKER" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

  echo "Draining ${WORKER}..."
  kubectl drain "$WORKER" --ignore-daemonsets --delete-emptydir-data --timeout=5m

  echo "Upgrading ${WORKER} (${WORKER_IP})..."
  ssh ubuntu@${WORKER_IP} "
    curl -sfL https://get.rke2.io | \
      INSTALL_RKE2_VERSION='${TARGET_VERSION}' \
      INSTALL_RKE2_TYPE='agent' \
      sh -
    sudo systemctl restart rke2-agent
  "

  echo "Waiting 60s for ${WORKER} to rejoin..."
  sleep 60
  kubectl uncordon "$WORKER"

  echo "Verifying ${WORKER} is Ready..."
  kubectl wait --for=condition=Ready node/"$WORKER" --timeout=5m
done
```

### Step 4: Verify upgrade

```bash
# All nodes should show new version
kubectl get nodes -o wide

# Verify no pods are stuck
kubectl get pods -A | grep -v "Running\|Completed"

# Verify etcd health
kubectl -n kube-system exec -it \
  $(kubectl -n kube-system get pod -l component=etcd -o name | head -1) -- \
  etcdctl endpoint health --cluster
```

---

## Rollback Procedure

```bash
# If upgrade fails on a master: restore from Proxmox snapshot
# On Proxmox host:
sudo qm stop 300
sudo qm rollback 300 pre-upgrade
sudo qm start 300

# If entire cluster needs rollback: restore from etcd snapshot (see above)
```

---

## Observability Stack Upgrades

```bash
# Upgrade kube-prometheus-stack (update version in modules/prometheus/main.tf)
cd terraform/observability
# Update: version = "59.0.0"  (from 58.2.2)
terraform apply -target='module.prometheus_stack'

# Upgrade Loki
terraform apply -target='module.loki'

# Upgrade Mimir
terraform apply -target='module.mimir'
```

**Always upgrade one component at a time and verify metrics/logs are flowing.**
