################################################################################
# Module: master_node
# Creates a single RKE2 control-plane node on Proxmox
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

resource "proxmox_virtual_environment_vm" "master" {
  vm_id       = var.vm_id
  name        = var.hostname
  description = "RKE2 Control Plane Node ${var.index + 1} — managed by Terraform"
  # Proxmox tags allow only [a-z0-9_-]; collapse k/v with hyphen, lowercase
  tags = [for k, v in var.tags : lower(replace("${k}-${v}", "/[^a-z0-9_-]/", "-"))]

  node_name = var.proxmox_node

  # Clone from template
  clone {
    vm_id   = var.template_vm_id
    full    = true  # Full clone avoids snapshot dependency
    retries = 3
  }

  # CPU
  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    type    = var.cpu_type
    # Enable NUMA for multi-socket configs
    numa    = var.cpu_sockets > 1
  }

  # Memory — no ballooning on masters for predictable etcd performance
  memory {
    dedicated = var.memory_mb
    floating  = 0
  }

  # OS disk (cloned from template)
  # Root disk — RESIZES the cloned template disk (must match template interface: scsi0)
  disk {
    interface    = "scsi0"
    size         = var.disk_size_gb
    datastore_id = var.disk_storage
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Dedicated etcd disk — NEW disk added on top of the clone
  disk {
    interface    = "scsi1"
    size         = var.etcd_disk_size_gb
    datastore_id = var.disk_storage
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Network interface
  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    vlan_id  = var.vlan_tag > 0 ? var.vlan_tag : null
    firewall = false
  }

  # QEMU guest agent for better Proxmox integration
  agent {
    enabled = var.agent_enabled
    timeout = "15m"
    trim    = true
    type    = "virtio"
  }

  # Cloud-init drive
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

  # Performance settings
  machine = "q35"          # Modern machine type with PCIe support
  bios    = "seabios"      # Use ovmf for UEFI if your template supports it

  operating_system {
    type = var.os_type
  }

  # Boot order: disk first, network second
  boot_order = ["scsi0", "net0"]

  # VM lifecycle
  protection    = var.protection
  started       = true
  on_boot       = var.start_on_boot

  # Wait for cloud-init to complete before Terraform considers VM ready
  lifecycle {
    ignore_changes = [
      # Prevent recreation when template is updated
      clone,
      # Tags managed outside Terraform are preserved
      tags,
    ]
  }

  # Allow time for cloud-init to finish (bpg/proxmox uses top-level timeout_* args)
  timeout_clone  = 1200
  timeout_create = 1200
  timeout_stop_vm = 300
}

# Format etcd disk after VM creation
resource "null_resource" "format_etcd_disk" {
  depends_on = [proxmox_virtual_environment_vm.master]

  triggers = {
    vm_id = proxmox_virtual_environment_vm.master.vm_id
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
      # Wait for cloud-init
      "cloud-init status --wait",
      # Format and mount etcd disk
      "sudo mkfs.ext4 -F -L etcd /dev/sdb",
      "sudo mkdir -p /var/lib/rancher/rke2/server/db",
      "echo 'LABEL=etcd /var/lib/rancher/rke2/server/db ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab",
      "sudo mount -a",
      # Kernel tuning for etcd
      "echo 'vm.swappiness=0' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'vm.overcommit_memory=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.core.somaxconn=32768' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.bridge.bridge-nf-call-iptables=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
      "sudo modprobe br_netfilter",
      "sudo modprobe overlay",
      "echo 'br_netfilter' | sudo tee -a /etc/modules-load.d/rke2.conf",
      "echo 'overlay' | sudo tee -a /etc/modules-load.d/rke2.conf",
      "sudo sysctl --system",
    ]
  }
}
