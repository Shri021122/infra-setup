################################################################################
# proxmox.tfvars — VM provisioning for ONE cluster
#
# Copy this whole folder (../_template/) to clusters/<your-name>/ and edit.
# Or run: ./scripts/new-cluster.sh <name>   (interactive wizard).
#
# cluster_name MUST match the folder name (clusters/<cluster_name>/).
# Everything else is environment-specific.
################################################################################

# ─── Cluster identity ─────────────────────────────────────────────────────────
cluster_name = "CHANGE_ME"     # ← MUST match the clusters/ folder name
environment  = "production"    # production / staging / development

# ─── Proxmox Connection (API-token only — no SSH required) ────────────────────
proxmox_api_url      = "https://10.10.16.249:8006/api2/json"
proxmox_username     = "terraform@pve"
proxmox_tls_insecure = true
proxmox_node         = "pve-4"

# Shared snippet — uploaded ONCE per Proxmox host by an admin (see runbook §0.3).
shared_cloud_init_snippet_file_id = "local:snippets/k8s-common.yaml"

# ─── Network ──────────────────────────────────────────────────────────────────
network_bridge              = "vmbrk8s"
network_subnet_cidr         = "10.20.0.0/24"
network_gateway             = "10.20.0.1"
dns_servers                 = ["10.20.0.1", "8.8.8.8"]
domain_name                 = "cluster.internal"
vlan_tag                    = 0
control_plane_vip           = "10.20.0.100"
control_plane_vip_interface = "eth0"

# ─── VM Template ──────────────────────────────────────────────────────────────
vm_template_id      = 9200
vm_template_storage = "local-lvm"

# ─── Data-at-rest encryption ──────────────────────────────────────────────────
# true  → UEFI + per-VM vTPM + LUKS root/data (clevis auto-unlock). REQUIRES an
#         encrypted UEFI template (e.g. 9011/9020) in vm_template_id above.
# false → plain seabios cloud-image template (9200). Default off.
# The flag and the template must match, or nodes won't boot. See docs/disk-encryption.md.
enable_disk_encryption = false

# ─── SSH Access (public key only — paste yours; private stays on workstation) ─
vm_ssh_public_key       = "ssh-ed25519 AAAA... rke2-cluster-deploy"
vm_ssh_private_key_path = "~/.ssh/rke2_cluster_id"
vm_user                 = "ubuntu"
vm_cpu_type             = "x86-64-v2-AES"

# ─── Master Nodes ─────────────────────────────────────────────────────────────
master_count             = 3
master_vm_id_start       = 401
master_cpu_cores         = 2
master_cpu_sockets       = 1
master_memory_mb         = 8192
master_disk_size_gb      = 50
master_etcd_disk_size_gb = 20
master_disk_storage      = "pve-4-storage"
master_name_prefix       = "CHANGE_ME-m"
master_ip_addresses      = [
  "10.20.0.101",
  "10.20.0.102",
  "10.20.0.103",
]

# ─── Worker Nodes ─────────────────────────────────────────────────────────────
worker_count             = 3
worker_vm_id_start       = 410
worker_cpu_cores         = 8
worker_cpu_sockets       = 1
worker_memory_mb         = 16384
worker_disk_size_gb      = 100
worker_data_disk_size_gb = 200
worker_disk_storage      = "pve-4-storage"
worker_name_prefix       = "CHANGE_ME-w"
worker_ip_addresses      = [
  "10.20.0.111",
  "10.20.0.112",
  "10.20.0.113",
]

# ─── RKE2 ─────────────────────────────────────────────────────────────────────
rke2_version      = "v1.32.10+rke2r1"
rke2_cni          = "cilium"
rke2_cluster_cidr = "10.42.0.0/16"
rke2_service_cidr = "10.43.0.0/16"
rke2_cluster_dns  = "10.43.0.10"

# ─── Tags ─────────────────────────────────────────────────────────────────────
tags = {
  managed_by  = "terraform"
  cluster     = "CHANGE_ME"
  environment = "production"
  team        = "devops"
}
