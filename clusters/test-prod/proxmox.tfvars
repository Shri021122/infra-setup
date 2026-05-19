################################################################################
# terraform.tfvars.example
# Copy to terraform.tfvars and fill in your values.
# NEVER commit terraform.tfvars to git — it contains secrets.
################################################################################

# ─── Proxmox Connection ───────────────────────────────────────────────────────
proxmox_api_url              = "https://10.10.16.249:8006/api2/json"
proxmox_username             = "terraform@pve"
# proxmox_password is set via: export TF_VAR_proxmox_password="your-password"
proxmox_tls_insecure = true
proxmox_node         = "pve-4"   # Your Proxmox node name

# Enabled for the fresh test-prod deploy on 2026-05-18. Snippet
# k8s-common.yaml is already on pve-4:/var/lib/vz/snippets/.
shared_cloud_init_snippet_file_id = "local:snippets/k8s-common.yaml"

# ─── Network ──────────────────────────────────────────────────────────────────
network_bridge      = "vmbrk8s"
network_subnet_cidr = "10.10.18.0/24"
network_gateway     = "10.10.18.1"
dns_servers         = ["10.10.18.1", "8.8.8.8"]
domain_name         = "cluster.internal"
vlan_tag            = 0   # 0 = untagged; set to your VLAN ID if needed
control_plane_vip   = "10.10.18.100"   # Free IP in your subnet (not assigned to any node)
control_plane_vip_interface = "eth0"

# ─── VM Template ──────────────────────────────────────────────────────────────
vm_template_id = 9200   # Your Ubuntu 22.04 cloud-init template VM ID
vm_template_storage = "local-lvm"

# ─── SSH Access ───────────────────────────────────────────────────────────────
# Paste your SSH public key here (or leave blank to auto-generate)
vm_ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINWEtprN82zfB18A3+Bg5fgvSpw0jUNsNpktYb1yAUq7 rke2-cluster-deploy"
vm_ssh_private_key_path = "~/.ssh/rke2_cluster_id"
vm_user                 = "ubuntu"
vm_cpu_type             = "x86-64-v2-AES"  # Or "host" for single-node Proxmox

# ─── Master Nodes ─────────────────────────────────────────────────────────────
master_count            = 3
master_vm_id_start      = 401
master_cpu_cores        = 2
master_cpu_sockets      = 1
master_memory_mb        = 8192    # 8 GB
master_disk_size_gb     = 50
master_etcd_disk_size_gb = 20
master_disk_storage     = "pve-4-storage"
master_name_prefix      = "test-m"
master_ip_addresses     = [
  "10.10.18.101",
  "10.10.18.102",
  "10.10.18.103",
]

# ─── Worker Nodes ─────────────────────────────────────────────────────────────
# To add workers: increment worker_count and add IPs — run terraform apply
worker_count            = 3
worker_vm_id_start      = 410
worker_cpu_cores        = 8
worker_cpu_sockets      = 1
worker_memory_mb        = 16384   # 16 GB
worker_disk_size_gb     = 100
worker_data_disk_size_gb = 200
worker_disk_storage     = "pve-4-storage"
worker_name_prefix      = "test-w"
worker_ip_addresses     = [
  "10.10.18.111",
  "10.10.18.112",
  "10.10.18.113",
]

# ─── RKE2 ─────────────────────────────────────────────────────────────────────
rke2_version     = "v1.32.10+rke2r1"
rke2_cni         = "cilium"
rke2_cluster_cidr = "10.42.0.0/16"
rke2_service_cidr = "10.43.0.0/16"
rke2_cluster_dns  = "10.43.0.10"
cluster_name     = "test-prod"

# ─── Metadata ─────────────────────────────────────────────────────────────────
environment = "production"
tags = {
  managed_by  = "terraform"
  cluster     = "test-prod"
  environment = "production"
  team        = "devops"
}
