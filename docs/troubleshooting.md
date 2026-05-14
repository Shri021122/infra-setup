# Troubleshooting Guide

## Cluster Health Quick Checks

```bash
# Full cluster status
kubectl get nodes -o wide
kubectl get pods -A | grep -v "Running\|Completed"
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20

# etcd health
ETCD_POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -1)
kubectl -n kube-system exec -it "$ETCD_POD" -- \
  etcdctl endpoint health --cluster \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server.key

# API server logs
sudo journalctl -u rke2-server -f --since "10m ago" | grep -i error

# kubelet logs on worker
sudo journalctl -u rke2-agent -f --since "10m ago"
```

---

## Issue: Node Not Ready

```bash
# 1. Check node conditions
kubectl describe node <node-name> | grep -A 20 "Conditions:"

# 2. Check kubelet
ssh ubuntu@<node-ip> "sudo journalctl -u rke2-server -n 100 | tail -30"

# 3. Check disk pressure
ssh ubuntu@<node-ip> "df -h && free -h"

# 4. Restart kubelet (last resort)
ssh ubuntu@<node-ip> "sudo systemctl restart rke2-server"
# or for workers:
ssh ubuntu@<node-ip> "sudo systemctl restart rke2-agent"
```

## Issue: etcd Leader Election Failing

```bash
# Symptoms: API server returns 503, etcd logs show "lost leader"
# Cause: Usually network partition or disk I/O starvation

# Check etcd disk latency
ETCD_POD=$(kubectl -n kube-system get pod -l component=etcd -o name | head -1)
kubectl -n kube-system exec "$ETCD_POD" -- \
  etcdctl check perf \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/client.key

# If disk is too slow, the etcd disk (virtio1) may need to be moved to faster storage
# Check in Prometheus: etcd_disk_wal_fsync_duration_seconds (should be <10ms p99)
```

## Issue: Pod Stuck in Pending

```bash
# Check why pod isn't scheduled
kubectl describe pod <pod-name> -n <namespace>
# Look for: "Insufficient cpu", "Insufficient memory", "node(s) didn't match..."

# Check resource usage
kubectl describe nodes | grep -A 5 "Allocated resources"

# If PVC not binding:
kubectl describe pvc <pvc-name> -n <namespace>
kubectl get storageclass
kubectl get pv
```

## Issue: Prometheus Not Scraping Targets

```bash
# Port-forward to Prometheus UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open: http://localhost:9090/targets

# Check ServiceMonitor
kubectl get servicemonitor -A
kubectl describe servicemonitor <name> -n monitoring

# Common fix: label mismatch — ServiceMonitor selector must match Service labels
kubectl get svc -n <namespace> --show-labels
```

## Issue: Alloy Not Sending Logs to Central Loki

```bash
# Check Alloy service on a specific VM (Alloy runs as systemd, not in Kubernetes)
ssh <vm-user>@<node-ip> "systemctl status alloy"
ssh <vm-user>@<node-ip> "journalctl -u alloy -n 100 --no-pager"

# Check Alloy config
ssh <vm-user>@<node-ip> "cat /etc/alloy/config.alloy"

# Restart Alloy if needed
ssh <vm-user>@<node-ip> "sudo systemctl restart alloy"

# Verify logs reaching central Loki (query from central Grafana)
# Explore → Loki → {cluster="rke2-prod", job="kubernetes-pods"}
```

## Issue: Grafana Dashboards Showing No Data

```bash
# 1. Verify data source connectivity in Grafana UI
# Admin → Data Sources → Test

# 2. Check if Prometheus has data
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# Query: up{cluster="rke2-prod"}

# 3. Check time range — Grafana defaults to "last 6 hours"
# 4. Verify dashboard variable filters match actual label values
```

## Issue: Terraform Apply Fails on Proxmox Provider

```bash
# Error: "400 Bad Request" on VM creation
# Fix: Check vm_id is not already in use
qm list  # Run on Proxmox host

# Error: "connection refused" on SSH provisioner
# Fix: VM hasn't finished cloud-init yet — increase timeout
# In main.tf: timeouts { create = "30m" }

# Error: "template not found"
# Fix: Verify vm_template_id in tfvars matches your Proxmox template
qm list | grep 9000
```

## Issue: kube-vip VIP Not Responding

```bash
# Check kube-vip DaemonSet
kubectl get pods -n kube-system -l app=kube-vip-ds
kubectl logs -n kube-system -l app=kube-vip-ds

# Verify VIP is assigned to an interface
ssh ubuntu@192.168.10.101 "ip addr show eth0 | grep 192.168.10.100"

# kube-vip requires ARP to be working — check:
arping -I eth0 192.168.10.100  # From another host on the same subnet

# If VIP is missing: restart kube-vip on all masters
kubectl rollout restart daemonset/kube-vip-ds -n kube-system
```

## Issue: Certificate Expired

```bash
# Check certificate expiry
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get csr

# RKE2 auto-rotates certs before expiry (kubelet-arg: rotate-certificates=true)
# Manual rotation if needed:
sudo rke2 certificate rotate

# For kubeconfig certs (generated by generate-kubeconfigs.sh):
# Re-run the script — it generates new certs
./rbac/scripts/generate-kubeconfigs.sh
```

## Useful Diagnostic Commands

```bash
# Resource usage per namespace
kubectl resource-capacity --namespace --pods

# Events sorted by time
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Check API server request latency
kubectl get --raw /metrics | grep apiserver_request_duration_seconds

# Network connectivity test between pods
kubectl run nettest --image=nicolaka/netshoot --rm -it -- /bin/bash
# Inside: curl <service-name>.<namespace>.svc.cluster.local

# Capture pod network traffic (requires privilege)
kubectl debug node/<node-name> -it --image=nicolaka/netshoot

# etcd compaction (free space if quota is hit)
ETCDCTL_API=3 etcdctl compact $(etcdctl endpoint status --write-out="json" | jq '.[0].Status.header.revision')
ETCDCTL_API=3 etcdctl defrag
```
