# Implementation Guide — RKE2 on Proxmox

## Prerequisites

Install on your workstation:
- Terraform >= 1.6.0
- kubectl
- helm >= 3.14
- openssl
- ssh-keygen
- AWS CLI (if using S3 for Loki/Mimir)

## Phase 1 — Proxmox Preparation

### 1.1 Create Proxmox API Token

```bash
# On Proxmox host (as root):
pveum user add terraform@pve
pveum role add TerraformRole -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit SDN.Use Sys.Audit"
pveum aclmod / -user terraform@pve -role TerraformRole
pveum user token add terraform@pve terraform --expire 0 --privsep=0
# Save the full token string: terraform@pve!terraform=<UUID> — export as TF_VAR_proxmox_api_token
```

### 1.2 Create Ubuntu 22.04 Cloud-Init Template

```bash
# On Proxmox host:
TEMPLATE_ID=9000
wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
qm create $TEMPLATE_ID --memory 2048 --cores 2 --name ubuntu-2204-template --net0 virtio,bridge=vmbr0
qm importdisk $TEMPLATE_ID jammy-server-cloudimg-amd64.img local-lvm
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-${TEMPLATE_ID}-disk-0
qm set $TEMPLATE_ID --ide2 local-lvm:cloudinit
qm set $TEMPLATE_ID --boot c --bootdisk scsi0
qm set $TEMPLATE_ID --serial0 socket --vga serial0
qm set $TEMPLATE_ID --agent enabled=1
qm template $TEMPLATE_ID
```

## Phase 2 — Terraform Infrastructure

### 2.1 Configure Variables

```bash
cd terraform/proxmox
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Proxmox details
vim terraform.tfvars

# Set sensitive values as environment variables
# Preferred: API token (no SSH to Proxmox needed)
export TF_VAR_proxmox_api_token='terraform@pve!terraform=<UUID>'
# Fallback: username + password
# export TF_VAR_proxmox_password="your-proxmox-password"
```

### 2.2 Initialize and Apply

```bash
terraform init
terraform validate
terraform plan -out=cluster.tfplan
# Review the plan — verify VM count, IPs, resources
terraform apply cluster.tfplan
```

Terraform will:
- Create 3 master VMs and 2 worker VMs
- Configure cloud-init for each
- Format etcd and data disks
- Apply kernel tuning
- Generate `rke2/configs/inventory.ini` and config files

## Phase 3 — RKE2 Installation

### 3.1 Make scripts executable

```bash
chmod +x rke2/scripts/*.sh rbac/scripts/*.sh
```

### 3.2 Install masters

```bash
./rke2/scripts/install-master.sh
```

This will:
- Install RKE2 on init master first (bootstraps etcd)
- Save cluster token to `.secrets/rke2-cluster-token`
- Deploy kube-vip for HA VIP
- Join remaining masters to the cluster
- Save admin kubeconfig to `.secrets/kubeconfig-admin.yaml`

### 3.3 Install workers

```bash
./rke2/scripts/install-worker.sh
```

### 3.4 Verify cluster

```bash
export KUBECONFIG=.secrets/kubeconfig-admin.yaml
kubectl get nodes -o wide
# All nodes should show Ready
```

## Phase 4 — Security Hardening

### 4.1 Apply namespaces and RBAC

```bash
kubectl apply -f rbac/00-namespace-setup.yaml
kubectl apply -f rbac/01-senior-devops.yaml
kubectl apply -f rbac/02-junior-devops.yaml
kubectl apply -f rbac/03-developer.yaml
kubectl apply -f rbac/04-read-only-auditor.yaml
```

### 4.2 Apply network policies

```bash
kubectl apply -f security/network-policies/
```

### 4.3 Install cert-manager (TLS)

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --version v1.14.5

# Create ClusterIssuer (edit with your email/ACME settings)
kubectl apply -f security/tls/cluster-issuer.yaml
```

### 4.4 Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace

# Configure your secret store (edit with Vault/AWS/Azure details)
kubectl apply -f security/secrets/external-secrets-operator.yaml
```

### 4.5 Generate role-specific kubeconfigs

```bash
./rbac/scripts/generate-kubeconfigs.sh
# Kubeconfigs land in rbac/kubeconfigs/
# Distribute to team members via secure channel (NOT email)
```

## Phase 5 — Observability Stack

### 5.1 Configure variables

```bash
cd terraform/observability
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

export TF_VAR_alertmanager_slack_webhook="https://hooks.slack.com/..."
# Mimir/Loki auth (leave empty if your central stack has no auth)
export TF_VAR_central_mimir_password="your-mimir-password"
export TF_VAR_central_loki_password="your-loki-password"
```

### 5.2 Add Helm repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 5.3 Deploy observability stack

```bash
terraform init
terraform plan -out=obs.tfplan
terraform apply obs.tfplan
```

Deploys in-cluster:
1. kube-prometheus-stack (Prometheus HA + Alertmanager + kube-state-metrics)
   - Grafana DISABLED (centralized)
   - node-exporter DISABLED (Alloy on each VM replaces it)
   - Remote-writes all metrics to your central Mimir

Alloy was already deployed as systemd on each VM during Phase 3 (install-master/worker.sh).
It collects: pod logs → central Loki, node metrics → central Mimir, journald → central Loki.

### 5.4 Verify observability

```bash
# Verify Prometheus is running and remote-writing
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open http://localhost:9090/targets — all targets should be green
# Check http://localhost:9090/config — remoteWrite section should show your Mimir URL

# Verify Alloy on a node (Alloy is systemd, not in Kubernetes)
ssh <vm-user>@<node-ip> "systemctl status alloy && journalctl -u alloy -n 20 --no-pager"

# Verify in central Grafana (Explore):
# Metrics: datasource=Mimir, filter cluster="rke2-prod"
# Logs:    datasource=Loki,  {cluster="rke2-prod"}
```

## Phase 6 — Cilium IngressController (automatic — no manual steps)

Cilium IngressController is deployed automatically by RKE2 via the
`rke2-cilium-config.yaml` HelmChartConfig that `install-master.sh` uploads
before starting the RKE2 server.

After the cluster is up, verify with:

```bash
# IngressClass should be registered
kubectl get ingressclass cilium

# Cilium IngressController LB service (kube-vip assigns the IP)
kubectl get svc -n kube-system -l app.kubernetes.io/name=cilium-ingress

# Hubble UI (network observability)
kubectl get ingress -n kube-system hubble-ui
```

### Using Cilium Ingress in your apps

```yaml
# Standard Kubernetes Ingress — use ingressClassName: cilium
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: production
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: cilium        # ← Cilium IngressController
  rules:
    - host: my-app.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app-svc
                port:
                  number: 80
  tls:
    - secretName: my-app-tls
      hosts:
        - my-app.yourdomain.com
```

### Gateway API (more powerful — recommended for new apps)

```yaml
# HTTPRoute — requires GatewayClass 'cilium'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: production
spec:
  parentRefs:
    - name: cilium-gateway
      namespace: kube-system
  hostnames:
    - my-app.yourdomain.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-svc
          port: 80
```

**The ingress LoadBalancer IP** is allocated dynamically by Cilium from a
`CiliumLoadBalancerIPPool` (created in Phase 7 from
`terraform/argocd/terraform.tfvars` → `argocd_lb_ip_pool_cidr`, default
`192.168.10.200/32`). Don't hardcode `loadBalancerIP` in
`rke2/configs/rke2-cilium-config.yaml` — the cilium-ingress Service will pick
up the IP automatically once Phase 7 creates the pool.

## Implementation Order Summary

```
Phase 1: Proxmox Setup (MANUAL — one time only)
  └── Create API token
  └── Create Ubuntu 22.04 cloud-init template

Phases 2–7: FULLY AUTOMATED
  └── Single command: ./scripts/deploy.sh

  Phase 2: Terraform → Proxmox VMs
  Phase 3: RKE2 install (masters → workers) + Cilium (L2 announce + LB IPAM)
  Phase 4: RBAC + NetworkPolicies + cert-manager + ESO + kubeconfigs
  Phase 5: Prometheus + Alertmanager (→ your central Mimir); Alloy already on VMs
  Phase 6: Cilium IngressController verification (already deployed by RKE2)
  Phase 7: ArgoCD + (optional) Ingress, LB IP pool, certificate
           — self-skips if terraform/argocd/terraform.tfvars is absent
```

### Resume from a specific phase

```bash
./scripts/deploy.sh --from phase4   # Re-run from Phase 4 onward
./scripts/deploy.sh --only phase5   # Run only Phase 5
./scripts/deploy.sh --dry-run       # Validate without applying anything
```

Total time: approximately 25–35 minutes unattended after Phase 1.
