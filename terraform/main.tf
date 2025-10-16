# backup 
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

# Create VNet
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# Create Subnet
resource "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Use the NSG module
module "nsg" {
  source              = "../../archive/nsg/k8s"
  nsg_name            = "kube-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# Public IP
resource "azurerm_public_ip" "kube_ip" {
  name                = "${var.vm_name}-ip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# NIC
resource "azurerm_network_interface" "kube_nic" {
  name                = "${var.vm_name}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.kube_ip.id
  }
}

# NSG Association
resource "azurerm_network_interface_security_group_association" "kube_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.kube_nic.id
  network_security_group_id = module.nsg.nsg_id
}

# Cribl VM
resource "azurerm_linux_virtual_machine" "kube_vm" {
  name                  = var.vm_name
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  zone                  = "3"
  size                  = "Standard_D8ds_v6"
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.kube_nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    name                 = "${var.vm_name}-osdisk"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(file("${path.module}/../scripts/install-kube.sh"))

}