output "vm_id" { value = proxmox_virtual_environment_vm.master.vm_id }
output "hostname" { value = proxmox_virtual_environment_vm.master.name }
output "ip_address" { value = var.ip_address }
output "is_init" { value = var.is_init_node }
