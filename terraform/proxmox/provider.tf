################################################################################
# Proxmox Provider Configuration
# Supports Proxmox VE 7.x and 8.x
# Provider: bpg/proxmox (recommended over telmate for production)
################################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.46"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state backend — configure to match your environment
  # Uncomment and fill in when using shared state
  # backend "s3" {
  #   bucket         = var.tf_state_bucket
  #   key            = "proxmox/rke2-cluster/terraform.tfstate"
  #   region         = var.tf_state_region
  #   dynamodb_table = var.tf_state_lock_table
  #   encrypt        = true
  # }
}

provider "proxmox" {
  endpoint = var.proxmox_api_url
  username = var.proxmox_username
  password = var.proxmox_password

  # Set to true only in lab/dev environments
  insecure = var.proxmox_tls_insecure

  # SSH configuration for file uploads and provisioning
  ssh {
    agent       = false
    username    = var.proxmox_ssh_user
    private_key = file(var.proxmox_ssh_private_key_path)
  }
}
