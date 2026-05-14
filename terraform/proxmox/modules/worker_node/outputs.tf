output "vm_id"      { value = proxmox_virtual_environment_vm.worker.vm_id }
output "hostname"   { value = proxmox_virtual_environment_vm.worker.name }
output "ip_address" { value = var.ip_address }
