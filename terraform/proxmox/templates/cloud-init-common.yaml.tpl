#cloud-config
# Rendered by Terraform — do not edit directly
users:
  - name: ${vm_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, docker]
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - vim
  - htop
  - net-tools
  - nfs-common
  - open-iscsi
  - cryptsetup
  - jq
  - unzip
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release
  - qemu-guest-agent
  - chrony

write_files:
  - path: /etc/chrony.conf
    content: |
      pool 2.ubuntu.pool.ntp.org iburst
      driftfile /var/lib/chrony/drift
      makestep 1.0 3
      rtcsync
      logdir /var/log/chrony

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now chrony
  - systemctl disable --now ufw
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  - hostnamectl set-hostname $(hostname -s).${domain_name}

manage_resolv_conf: true
resolv_conf:
  nameservers: [${dns_servers}]
  searchdomains:
    - ${domain_name}

final_message: "Cloud-init complete after $UPTIME seconds"
