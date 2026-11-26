# Ops VM inside the VNet. Two jobs:
#  1. break-glass admin box for the private AKS API / private endpoints
#  2. self-hosted GitHub Actions runner for the *infra* pipeline (Terraform
#     must reach private endpoints; it can't run on ARC inside the cluster it
#     is creating - chicken and egg).
# No public IP. Login with Entra ID through Azure Bastion (Developer SKU).
resource "azurerm_network_interface" "this" {
  name                = "nic-ops-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "vm-ops-${var.name}"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  network_interface_ids           = [azurerm_network_interface.this.id]
  admin_username                  = "azureops"
  disable_password_authentication = true
  patch_mode                      = "AutomaticByPlatform"
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    harden_script = var.harden_script
    runner_script = var.runner_script
    health_script = var.health_script
  }))
  tags = var.tags

  admin_ssh_key {
    username   = "azureops"
    public_key = var.admin_ssh_public_key # break-glass only; daily use = Entra SSH
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [custom_data] # cloud-init runs once; changes go through config mgmt
  }
}

# Entra ID login: `az ssh vm` with RBAC roles instead of shared SSH keys
resource "azurerm_virtual_machine_extension" "aad_ssh" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.this.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_role_assignment" "vm_admin_login" {
  for_each             = toset(var.admin_group_object_ids)
  scope                = azurerm_linux_virtual_machine.this.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}

resource "azurerm_bastion_host" "this" {
  name                = "bas-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Developer"
  virtual_network_id  = var.vnet_id
  tags                = var.tags
}
