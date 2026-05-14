################################################################################
# Module: worker_node
# Creates a single RKE2 worker node on Proxmox.
# Scaling: increment worker_count in tfvars — no master-side changes needed.
################################################################################

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.46"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  vm_id       = var.vm_id
  name        = var.hostname
  description = "RKE2 Worker Node ${var.index + 1} — managed by Terraform"
  # Proxmox tags allow only [a-z0-9_-]; collapse k/v with hyphen, lowercase
  tags = [for k, v in var.tags : lower(replace("${k}-${v}", "/[^a-z0-9_-]/", "-"))]

  node_name = var.proxmox_node

  clone {
    vm_id   = var.template_vm_id
    full    = true
    retries = 3
  }

  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    type    = var.cpu_type
    numa    = var.cpu_sockets > 1
  }

  # Enable memory ballooning on workers — workload-dependent usage
  memory {
    dedicated = var.memory_mb
    floating  = var.memory_mb / 2  # Min guaranteed = 50% of dedicated
  }

  # Root disk — RESIZES the cloned template disk (must match template interface: scsi0)
  disk {
    interface    = "scsi0"
    size         = var.disk_size_gb
    datastore_id = var.disk_storage
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Data disk for container images and volumes (NEW disk on top of clone)
  disk {
    interface    = "scsi1"
    size         = var.data_disk_size_gb
    datastore_id = var.disk_storage
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    vlan_id  = var.vlan_tag > 0 ? var.vlan_tag : null
    firewall = false
  }

  agent {
    enabled = var.agent_enabled
    timeout = "15m"
    trim    = true
    type    = "virtio"
  }

  initialization {
    datastore_id = var.disk_storage

    ip_config {
      ipv4 {
        address = var.ip_address != "" ? "${var.ip_address}/24" : "dhcp"
        gateway = var.ip_address != "" ? var.gateway : null
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.domain_name
    }

    user_account {
      username = var.vm_user
      keys     = [var.ssh_public_key]
    }
  }

  machine = "q35"
  bios    = "seabios"

  operating_system {
    type = var.os_type
  }

  boot_order = ["scsi0", "net0"]

  protection = var.protection
  started    = true
  on_boot    = var.start_on_boot

  lifecycle {
    ignore_changes = [clone, tags]
  }

  # bpg/proxmox uses top-level timeout_* args (seconds), not a timeouts block
  timeout_clone  = 1200
  timeout_create = 1200
  timeout_stop_vm = 300
}

# Format and mount the data disk for container workloads
resource "null_resource" "setup_worker_data_disk" {
  depends_on = [proxmox_virtual_environment_vm.worker]

  triggers = {
    vm_id = proxmox_virtual_environment_vm.worker.vm_id
  }

  connection {
    type        = "ssh"
    host        = var.ip_address
    user        = var.vm_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      # Format data disk with XFS (preferred for container workloads)
      "sudo mkfs.xfs -f -L containerd /dev/sdb",
      "sudo mkdir -p /var/lib/rancher",
      "echo 'LABEL=containerd /var/lib/rancher xfs defaults,noatime,nodiratime 0 2' | sudo tee -a /etc/fstab",
      "sudo mount -a",
      # Kernel tuning for worker nodes
      "echo 'vm.swappiness=0' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'fs.inotify.max_user_instances=512' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.bridge.bridge-nf-call-iptables=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.core.somaxconn=32768' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "sudo modprobe br_netfilter",
      "sudo modprobe overlay",
      "echo 'br_netfilter' | sudo tee -a /etc/modules-load.d/rke2.conf",
      "echo 'overlay' | sudo tee -a /etc/modules-load.d/rke2.conf",
      "sudo sysctl --system",
    ]
  }
}
