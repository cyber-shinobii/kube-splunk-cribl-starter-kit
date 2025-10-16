variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
  default     = "changeme-kube"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "changeme-eastus"
}

variable "vnet_name" {
  description = "Name of the existing virtual network"
  type        = string
  default     = "changeme-vnet"
}

variable "subnet_name" {
  description = "Name of the subnet to use"
  type        = string
  default     = "changeme-subnet"
}

variable "vm_name" {
  description = "Name of the virtual machine"
  type        = string
  default     = "changeme-kube"
}

variable "admin_username" {
  description = "Username for the VM admin account"
  type        = string
  default     = "changeme-azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/changeme.pub"
}