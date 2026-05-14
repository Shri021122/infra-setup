################################################################################
# Main — Proxmox VM Provisioning for RKE2 Cluster
# Creates: 3 master nodes + N worker nodes via reusable modules
################################################################################

# ─── SSH Key Pair (if you want Terraform to generate it) ─────────────────────

resource "tls_private_key" "cluster_ssh" {
  algorithm = "ED25519"
}

resource "local_file" "cluster_ssh_private_key" {
  content         = tls_private_key.cluster_ssh.private_key_openssh
  filename        = "${path.module}/../../.secrets/cluster_id_ed25519"
  file_permission = "0600"
}

resource "local_file" "cluster_ssh_public_key" {
  content  = tls_private_key.cluster_ssh.public_key_openssh
  filename = "${path.module}/../../.secrets/cluster_id_ed25519.pub"
}

# ─── Cloud-Init Snippet Files ─────────────────────────────────────────────────
# These are uploaded to Proxmox snippets storage and referenced by VMs.

resource "proxmox_virtual_environment_file" "cloud_init_common" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    file_name = "cloud-init-common.yaml"
    data = templatefile("${path.module}/templates/cloud-init-common.yaml.tpl", {
      ssh_public_key = var.vm_ssh_public_key != "" ? var.vm_ssh_public_key : tls_private_key.cluster_ssh.public_key_openssh
      vm_user        = var.vm_user
      dns_servers    = join(" ", var.dns_servers)
      domain_name    = var.domain_name
    })
  }
}

# ─── Master Nodes ─────────────────────────────────────────────────────────────

module "master_nodes" {
  source = "./modules/master_node"

  count = var.master_count

  # Identity
  vm_id    = var.master_vm_id_start + count.index
  hostname = "${var.master_name_prefix}-${count.index + 1}"
  index    = count.index

  # Proxmox placement
  proxmox_node    = var.proxmox_node
  template_vm_id  = var.vm_template_id
  disk_storage    = var.master_disk_storage

  # Resources
  cpu_cores        = var.master_cpu_cores
  cpu_sockets      = var.master_cpu_sockets
  memory_mb        = var.master_memory_mb
  disk_size_gb     = var.master_disk_size_gb
  etcd_disk_size_gb = var.master_etcd_disk_size_gb
  cpu_type         = var.vm_cpu_type
  os_type          = var.vm_os_type

  # Network
  network_bridge  = var.network_bridge
  ip_address      = length(var.master_ip_addresses) > count.index ? var.master_ip_addresses[count.index] : ""
  gateway         = var.network_gateway
  vlan_tag        = var.vlan_tag
  dns_servers     = var.dns_servers
  domain_name     = var.domain_name

  # Cloud-init
  cloud_init_snippet = proxmox_virtual_environment_file.cloud_init_common.id
  ssh_public_key     = var.vm_ssh_public_key != "" ? var.vm_ssh_public_key : tls_private_key.cluster_ssh.public_key_openssh
  vm_user            = var.vm_user

  # Behavior
  agent_enabled   = var.vm_agent_enabled
  protection      = var.vm_protection
  start_on_boot   = var.vm_start_on_boot

  # SSH provisioner key
  ssh_private_key_path = var.vm_ssh_private_key_path

  # RKE2
  rke2_version   = var.rke2_version
  cluster_name   = var.cluster_name
  is_init_node   = count.index == 0  # First master bootstraps the cluster

  tags = merge(var.tags, {
    role = "master"
    node = "${var.master_name_prefix}-${count.index + 1}"
  })
}

# ─── Worker Nodes ─────────────────────────────────────────────────────────────

module "worker_nodes" {
  source = "./modules/worker_node"

  # This depends on at least one master being ready
  depends_on = [module.master_nodes]

  count = var.worker_count

  # Identity
  vm_id    = var.worker_vm_id_start + count.index
  hostname = "${var.worker_name_prefix}-${count.index + 1}"
  index    = count.index

  # Proxmox placement
  proxmox_node   = var.proxmox_node
  template_vm_id = var.vm_template_id
  disk_storage   = var.worker_disk_storage

  # Resources
  cpu_cores          = var.worker_cpu_cores
  cpu_sockets        = var.worker_cpu_sockets
  memory_mb          = var.worker_memory_mb
  disk_size_gb       = var.worker_disk_size_gb
  data_disk_size_gb  = var.worker_data_disk_size_gb
  cpu_type           = var.vm_cpu_type
  os_type            = var.vm_os_type

  # Network
  network_bridge = var.network_bridge
  ip_address     = length(var.worker_ip_addresses) > count.index ? var.worker_ip_addresses[count.index] : ""
  gateway        = var.network_gateway
  vlan_tag       = var.vlan_tag
  dns_servers    = var.dns_servers
  domain_name    = var.domain_name

  # Cloud-init
  cloud_init_snippet = proxmox_virtual_environment_file.cloud_init_common.id
  ssh_public_key     = var.vm_ssh_public_key != "" ? var.vm_ssh_public_key : tls_private_key.cluster_ssh.public_key_openssh
  vm_user            = var.vm_user

  # SSH provisioner key
  ssh_private_key_path = var.vm_ssh_private_key_path

  # Behavior
  agent_enabled = var.vm_agent_enabled
  protection    = var.vm_protection
  start_on_boot = var.vm_start_on_boot

  tags = merge(var.tags, {
    role = "worker"
    node = "${var.worker_name_prefix}-${count.index + 1}"
  })
}

# ─── Inventory File for RKE2 Scripts ─────────────────────────────────────────
# Generated after VM creation so installation scripts know all IPs.

resource "local_file" "ansible_inventory" {
  depends_on = [module.master_nodes, module.worker_nodes]

  filename = "${path.module}/../../rke2/configs/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.ini.tpl", {
    masters = [
      for i, m in module.master_nodes : {
        hostname   = m.hostname
        ip         = m.ip_address
        is_primary = i == 0
      }
    ]
    workers = [
      for w in module.worker_nodes : {
        hostname = w.hostname
        ip       = w.ip_address
      }
    ]
    ssh_user            = var.vm_user
    ssh_private_key     = var.vm_ssh_private_key_path
    control_plane_vip   = var.control_plane_vip
    rke2_version        = var.rke2_version
    rke2_cni            = var.rke2_cni
    cluster_cidr        = var.rke2_cluster_cidr
    service_cidr        = var.rke2_service_cidr
    cluster_name        = var.cluster_name
  })
}

# ─── RKE2 Config Files ────────────────────────────────────────────────────────

resource "local_file" "rke2_master_config" {
  depends_on = [module.master_nodes]

  for_each = { for i, m in module.master_nodes : i => m }

  filename = "${path.module}/../../rke2/configs/master-${each.key + 1}-config.yaml"
  content = templatefile("${path.module}/templates/rke2-master-config.yaml.tpl", {
    node_ip          = each.value.ip_address
    node_name        = each.value.hostname
    is_init_node     = tonumber(each.key) == 0
    init_node_ip     = module.master_nodes[0].ip_address
    control_plane_vip = var.control_plane_vip
    vip_interface    = var.control_plane_vip_interface
    cluster_cidr     = var.rke2_cluster_cidr
    service_cidr     = var.rke2_service_cidr
    cluster_dns      = var.rke2_cluster_dns
    cni              = var.rke2_cni
    cluster_name     = var.cluster_name
    master_ips       = [for m in module.master_nodes : m.ip_address]
  })
}

resource "local_file" "rke2_worker_config" {
  depends_on = [module.master_nodes]

  for_each = { for i, w in module.worker_nodes : i => w }

  filename = "${path.module}/../../rke2/configs/worker-${each.key + 1}-config.yaml"
  content = templatefile("${path.module}/templates/rke2-worker-config.yaml.tpl", {
    node_ip           = each.value.ip_address
    node_name         = each.value.hostname
    control_plane_vip = var.control_plane_vip
    cluster_name      = var.cluster_name
  })
}
