variable "vm_id" {
  type = number
}
variable "hostname" {
  type = string
}
variable "index" {
  type = number
}
variable "proxmox_node" {
  type = string
}
variable "template_vm_id" {
  type = number
}
variable "disk_storage" {
  type = string
}
variable "cpu_cores" {
  type = number
}
variable "cpu_sockets" {
  type = number
}
variable "memory_mb" {
  type = number
}
variable "disk_size_gb" {
  type = number
}
variable "data_disk_size_gb" {
  type = number
}
variable "cpu_type" {
  type = string
}
variable "os_type" {
  type = string
}
variable "network_bridge" {
  type = string
}
variable "ip_address" {
  type = string
}
variable "gateway" {
  type = string
}
variable "vlan_tag" {
  type = number
}
variable "dns_servers" {
  type = list(string)
}
variable "domain_name" {
  type = string
}
variable "cloud_init_user_data_file_id" {
  description = "Proxmox file ID of a pre-uploaded cloud-init snippet (e.g. 'local:snippets/k8s-common.yaml'). Empty = no user_data reference."
  type        = string
  default     = ""
}
variable "ssh_public_key" {
  type = string
}
variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/id_rsa"
}
variable "vm_user" {
  type = string
}
variable "agent_enabled" {
  type = bool
}
variable "protection" {
  type = bool
}
variable "start_on_boot" {
  type = bool
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "enable_disk_encryption" {
  description = "UEFI + per-VM vTPM + LUKS data disk + auto-grow encrypted root. Default off (seabios, plain mkfs)."
  type        = bool
  default     = false
}
variable "luks_passphrase" {
  description = "LUKS recovery passphrase (the template's build key). Supply ONLY via TF_VAR_luks_passphrase at deploy time to grow the encrypted root; used only in the provisioner, never persisted to state/tfvars. Empty = skip the root resize."
  type        = string
  sensitive   = true
  default     = ""
}
