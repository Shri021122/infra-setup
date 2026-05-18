################################################################################
# Global Variables — Proxmox Cluster Provisioning
# All sensitive values should come from environment variables or a vault.
# Pattern: TF_VAR_<variable_name>=value
################################################################################

# ─── Proxmox Connection ───────────────────────────────────────────────────────

variable "proxmox_api_url" {
  description = "Proxmox API endpoint. Example: https://192.168.1.10:8006/api2/json"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API username with realm. Example: terraform@pve"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox API password. Use TF_VAR_proxmox_password env var. Leave empty if using api_token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token, format: user@realm!tokenid=UUID. Use TF_VAR_proxmox_api_token env var."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification (set false in production)"
  type        = bool
  default     = false
}

variable "shared_cloud_init_snippet_file_id" {
  description = <<-EOT
    Proxmox file ID of a cloud-init snippet that an admin pre-uploaded to the
    Proxmox host (e.g. "local:snippets/k8s-common.yaml"). When non-empty, the
    file is set as user_data_file_id on every VM's initialization{} block.
    Leave empty to skip referencing a snippet — Proxmox API user_account /
    ip_config / dns blocks still wire up SSH user, IP, and DNS per VM.

    Upload the snippet once per Proxmox host via: Datacenter → Storage → local
    → Snippets → Upload (or scp to /var/lib/vz/snippets/ during initial setup).
    The provided file lives at terraform/proxmox/snippets/k8s-common.yaml.
  EOT
  type        = string
  default     = ""
}

variable "proxmox_node" {
  description = "Proxmox node name where VMs will be created"
  type        = string
}

# ─── Network Configuration ────────────────────────────────────────────────────

variable "network_bridge" {
  description = "Proxmox network bridge for VM NICs (e.g. vmbr0)"
  type        = string
  default     = "vmbr0"
}

variable "network_subnet_cidr" {
  description = "Subnet CIDR for cluster nodes (e.g. 192.168.10.0/24)"
  type        = string
}

variable "network_gateway" {
  description = "Default gateway for cluster nodes"
  type        = string
}

variable "dns_servers" {
  description = "List of DNS servers for VM configuration"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

variable "domain_name" {
  description = "Domain name for cluster nodes (e.g. cluster.internal)"
  type        = string
  default     = "cluster.internal"
}

variable "vlan_tag" {
  description = "VLAN tag for cluster network (0 = untagged)"
  type        = number
  default     = 0
}

# ─── VM Template ──────────────────────────────────────────────────────────────

variable "vm_template_id" {
  description = "Proxmox template VM ID to clone (Ubuntu 22.04 cloud-init recommended)"
  type        = number
}

variable "vm_template_storage" {
  description = "Storage pool where the template lives"
  type        = string
  default     = "local-lvm"
}

# ─── Master Node Resources ────────────────────────────────────────────────────

variable "master_count" {
  description = "Number of master (control-plane) nodes. Must be odd (1, 3, 5)."
  type        = number
  default     = 3

  validation {
    condition     = var.master_count % 2 == 1
    error_message = "Master count must be an odd number for etcd quorum (1, 3, or 5)."
  }
}

variable "master_vm_id_start" {
  description = "Starting VM ID for master nodes (e.g. 300 → 300, 301, 302)"
  type        = number
  default     = 300
}

variable "master_cpu_cores" {
  description = "CPU cores per master node"
  type        = number
  default     = 4
}

variable "master_cpu_sockets" {
  description = "CPU sockets per master node"
  type        = number
  default     = 1
}

variable "master_memory_mb" {
  description = "RAM in MB per master node (minimum 4096 for RKE2)"
  type        = number
  default     = 8192
}

variable "master_disk_size_gb" {
  description = "OS disk size in GB for master nodes"
  type        = number
  default     = 50
}

variable "master_etcd_disk_size_gb" {
  description = "Dedicated etcd data disk size in GB (separate disk for etcd performance)"
  type        = number
  default     = 20
}

variable "master_disk_storage" {
  description = "Proxmox storage pool for master node disks"
  type        = string
  default     = "local-lvm"
}

variable "master_ip_addresses" {
  description = "Static IP addresses for master nodes (must match master_count)"
  type        = list(string)
  default     = []
}

variable "master_name_prefix" {
  description = "Hostname prefix for master nodes"
  type        = string
  default     = "rke2-master"
}

# ─── Worker Node Resources ────────────────────────────────────────────────────

variable "worker_count" {
  description = "Number of worker nodes. Can be scaled without cluster disruption."
  type        = number
  default     = 2
}

variable "worker_vm_id_start" {
  description = "Starting VM ID for worker nodes (e.g. 310 → 310, 311, ...)"
  type        = number
  default     = 310
}

variable "worker_cpu_cores" {
  description = "CPU cores per worker node"
  type        = number
  default     = 8
}

variable "worker_cpu_sockets" {
  description = "CPU sockets per worker node"
  type        = number
  default     = 1
}

variable "worker_memory_mb" {
  description = "RAM in MB per worker node"
  type        = number
  default     = 16384
}

variable "worker_disk_size_gb" {
  description = "OS disk size in GB for worker nodes"
  type        = number
  default     = 100
}

variable "worker_data_disk_size_gb" {
  description = "Additional data disk for container storage (local-path provisioner)"
  type        = number
  default     = 200
}

variable "worker_disk_storage" {
  description = "Proxmox storage pool for worker node disks"
  type        = string
  default     = "local-lvm"
}

variable "worker_ip_addresses" {
  description = "Static IP addresses for worker nodes (must match worker_count)"
  type        = list(string)
  default     = []
}

variable "worker_name_prefix" {
  description = "Hostname prefix for worker nodes"
  type        = string
  default     = "rke2-worker"
}

# ─── VM Common Settings ───────────────────────────────────────────────────────

variable "vm_ssh_public_key" {
  description = "SSH public key content to inject into VMs via cloud-init"
  type        = string
}

variable "vm_ssh_private_key_path" {
  description = "Path to SSH private key for VM provisioning (matches vm_ssh_public_key)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "vm_user" {
  description = "Default user created by cloud-init on VMs"
  type        = string
  default     = "ubuntu"
}

variable "vm_cpu_type" {
  description = "CPU type for VMs. Use 'host' for best performance (single Proxmox node)"
  type        = string
  default     = "x86-64-v2-AES"
}

variable "vm_os_type" {
  description = "OS type hint for Proxmox (l26 = Linux 2.6+)"
  type        = string
  default     = "l26"
}

variable "vm_agent_enabled" {
  description = "Enable QEMU guest agent (requires qemu-guest-agent in template)"
  type        = bool
  default     = true
}

variable "vm_protection" {
  description = "Enable Proxmox VM protection (prevents accidental deletion)"
  type        = bool
  default     = false
}

variable "vm_start_on_boot" {
  description = "Automatically start VMs when Proxmox host boots"
  type        = bool
  default     = true
}

variable "vm_startup_order" {
  description = "Startup order hint for Proxmox (masters boot before workers)"
  type        = string
  default     = "1"
}

# ─── RKE2 Configuration ───────────────────────────────────────────────────────

variable "rke2_version" {
  description = "RKE2 version to install (e.g. v1.29.4+rke2r1)"
  type        = string
  default     = "v1.29.4+rke2r1"
}

variable "rke2_cni" {
  description = "CNI plugin for RKE2 (canal, calico, cilium)"
  type        = string
  default     = "cilium"
}

variable "rke2_cluster_cidr" {
  description = "CIDR for Kubernetes pod network"
  type        = string
  default     = "10.42.0.0/16"
}

variable "rke2_service_cidr" {
  description = "CIDR for Kubernetes service network"
  type        = string
  default     = "10.43.0.0/16"
}

variable "rke2_cluster_dns" {
  description = "Cluster DNS service IP (must be within service_cidr)"
  type        = string
  default     = "10.43.0.10"
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "rke2-prod"
}

# ─── Load Balancer / VIP ──────────────────────────────────────────────────────

variable "control_plane_vip" {
  description = "Virtual IP for HA control plane (used by kube-vip or external LB)"
  type        = string
}

variable "control_plane_vip_interface" {
  description = "Network interface for kube-vip VIP advertisement"
  type        = string
  default     = "eth0"
}

# ─── Tags & Metadata ──────────────────────────────────────────────────────────

variable "environment" {
  description = "Deployment environment (production, staging, development)"
  type        = string
  default     = "production"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    managed_by  = "terraform"
    cluster     = "rke2-prod"
    environment = "production"
  }
}
