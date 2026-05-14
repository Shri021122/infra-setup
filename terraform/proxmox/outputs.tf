################################################################################
# Outputs — used by downstream Terraform (observability) and scripts
################################################################################

output "master_ips" {
  description = "IP addresses of all master nodes"
  value       = [for m in module.master_nodes : m.ip_address]
}

output "master_hostnames" {
  description = "Hostnames of all master nodes"
  value       = [for m in module.master_nodes : m.hostname]
}

output "init_master_ip" {
  description = "IP of the bootstrap master node (primary etcd member)"
  value       = module.master_nodes[0].ip_address
}

output "worker_ips" {
  description = "IP addresses of all worker nodes"
  value       = [for w in module.worker_nodes : w.ip_address]
}

output "worker_hostnames" {
  description = "Hostnames of all worker nodes"
  value       = [for w in module.worker_nodes : w.hostname]
}

output "control_plane_vip" {
  description = "Virtual IP for the HA control plane"
  value       = var.control_plane_vip
}

output "cluster_name" {
  description = "Kubernetes cluster name"
  value       = var.cluster_name
}

output "ssh_private_key" {
  description = "Generated SSH private key for VM access (sensitive)"
  value       = tls_private_key.cluster_ssh.private_key_openssh
  sensitive   = true
}

output "all_node_ips" {
  description = "All node IPs (masters + workers) for firewall rules"
  value = concat(
    [for m in module.master_nodes : m.ip_address],
    [for w in module.worker_nodes : w.ip_address]
  )
}
