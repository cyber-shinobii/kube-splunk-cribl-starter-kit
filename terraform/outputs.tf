output "vm_id" {
  value = azurerm_linux_virtual_machine.kube_vm.id
}

output "public_ip" {
  value = azurerm_public_ip.kube_ip.ip_address
}

output "nic_id" {
  value = azurerm_network_interface.kube_nic.id
}

output "nsg_id" {
  value = module.nsg.nsg_id
}