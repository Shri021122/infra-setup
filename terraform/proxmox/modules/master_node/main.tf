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

locals {
  etcd_mount = "/var/lib/rancher/rke2/server/db"

  # Expand the LUKS+LVM encrypted root to fill scsi0 (whatever disk_size_gb is set
  # to). Plain growpart can't do this — LUKS+LVM needs the whole chain. Names match
  # the subiquity guided-LVM template (sda3 = LUKS, dm_crypt-0, ubuntu-vg/ubuntu-lv).
  # Grow the encrypted root to fill scsi0. cryptsetup resize needs the LUKS volume
  # key, so the real resize runs ONLY when var.luks_passphrase is supplied (pass it
  # at deploy via TF_VAR_luks_passphrase — used only here, never persisted). Without
  # it we grow just the partition and skip the LUKS resize (no hang; root stays at
  # the template size — fine, data lives on scsi1).
  grow_root_steps = !var.enable_disk_encryption ? [] : (
    var.luks_passphrase != "" ? [
      "echo '== growing encrypted root to fill scsi0 =='",
      "sudo growpart /dev/sda 3 || true",
      "printf '%s' '${var.luks_passphrase}' | sudo cryptsetup resize dm_crypt-0 || echo 'WARN: cryptsetup resize failed — check TF_VAR_luks_passphrase; root stays at template size'",
      "sudo pvresize /dev/mapper/dm_crypt-0 || true",
      "sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv || true",
      "sudo resize2fs /dev/ubuntu-vg/ubuntu-lv || true",
      ] : [
      "echo '== root grow: partition only (no luks_passphrase given); root stays at template size =='",
      "sudo growpart /dev/sda 3 || true",
    ]
  )

  # scsi1 = /dev/sdb = the dedicated etcd disk.
  etcd_disk_steps = var.enable_disk_encryption ? [
    # LUKS2-encrypt it; key lives on the (already-encrypted) root and is referenced
    # from crypttab, so it auto-unlocks at boot AFTER the TPM-unlocked root is up.
    "sudo mkdir -p /etc/luks-keys && sudo chmod 700 /etc/luks-keys",
    "test -f /etc/luks-keys/etcd.key || (sudo dd if=/dev/urandom of=/etc/luks-keys/etcd.key bs=512 count=1 status=none && sudo chmod 400 /etc/luks-keys/etcd.key)",
    "sudo cryptsetup luksFormat --type luks2 --batch-mode /dev/sdb /etc/luks-keys/etcd.key",
    "sudo cryptsetup open --key-file /etc/luks-keys/etcd.key /dev/sdb cryptetcd",
    "echo \"cryptetcd UUID=$(sudo blkid -s UUID -o value /dev/sdb) /etc/luks-keys/etcd.key luks,discard\" | sudo tee -a /etc/crypttab",
    "sudo mkfs.ext4 -F -L etcd /dev/mapper/cryptetcd",
    "sudo mkdir -p ${local.etcd_mount}",
    "echo '/dev/mapper/cryptetcd ${local.etcd_mount} ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab",
    "sudo mount ${local.etcd_mount}",
    ] : [
    # Plain, unencrypted (original behavior).
    "sudo mkfs.ext4 -F -L etcd /dev/sdb",
    "sudo mkdir -p ${local.etcd_mount}",
    "echo 'LABEL=etcd ${local.etcd_mount} ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab",
    "sudo mount -a",
  ]
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
    full    = true # Full clone avoids snapshot dependency
    retries = 3
  }

  # CPU
  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    type    = var.cpu_type
    # Enable NUMA for multi-socket configs
    numa = var.cpu_sockets > 1
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

    # Don't make Proxmox's auto-generated user-data inject `package_upgrade: true`.
    # That triggers `apt upgrade && snap refresh` during cloud-init, and snapd is
    # stripped from the template (virt-customize), so snap refresh fails and
    # cloud-init exits non-zero — even though every other step succeeded.
    upgrade = false

    # Generic host-prep snippet uploaded once by a Proxmox admin (packages,
    # chrony, swap-off, growpart, qemu-guest-agent). Use vendor_data_file_id
    # (NOT user_data_file_id) — vendor-data is cloud-init's "platform extras"
    # slot that *complements* the user-data Proxmox auto-generates from the
    # user_account/ip_config/dns blocks below. user_data_file_id would override
    # them and leave authorized_keys empty.
    vendor_data_file_id = var.cloud_init_user_data_file_id != "" ? var.cloud_init_user_data_file_id : null

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
  machine = "q35" # Modern machine type with PCIe support
  # Encrypted-root template (9011) is UEFI; cloud-image template (9200) is BIOS.
  bios = var.enable_disk_encryption ? "ovmf" : "seabios"

  # UEFI vars disk + per-VM virtual TPM — only when cloning the encrypted template.
  # The vTPM is what clevis uses to auto-unlock the LUKS root at boot; without it
  # an encrypted node would block on a passphrase prompt.
  dynamic "efi_disk" {
    for_each = var.enable_disk_encryption ? [1] : []
    content {
      datastore_id      = var.disk_storage
      type              = "4m"
      pre_enrolled_keys = false
    }
  }
  dynamic "tpm_state" {
    for_each = var.enable_disk_encryption ? [1] : []
    content {
      datastore_id = var.disk_storage
      version      = "v2.0"
    }
  }

  operating_system {
    type = var.os_type
  }

  # Boot order: disk first, network second
  boot_order = ["scsi0", "net0"]

  # VM lifecycle
  protection = var.protection
  started    = true
  on_boot    = var.start_on_boot

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
  timeout_clone   = 1200
  timeout_create  = 1200
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
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    # Wait for cloud-init, (encryption only) grow the encrypted root, set up the
    # etcd disk (LUKS or plain per local.etcd_disk_steps), then kernel tuning.
    inline = concat(
      ["cloud-init status --wait"],
      local.grow_root_steps,
      local.etcd_disk_steps,
      [
        "echo 'vm.swappiness=0' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'vm.overcommit_memory=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'net.core.somaxconn=32768' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'net.bridge.bridge-nf-call-iptables=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'net.bridge.bridge-nf-call-ip6tables=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'kernel.panic=10' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "echo 'kernel.panic_on_oops=1' | sudo tee -a /etc/sysctl.d/99-rke2.conf",
        "sudo modprobe br_netfilter",
        "sudo modprobe overlay",
        "echo 'br_netfilter' | sudo tee -a /etc/modules-load.d/rke2.conf",
        "echo 'overlay' | sudo tee -a /etc/modules-load.d/rke2.conf",
        "sudo sysctl --system",
      ],
    )
  }
}
