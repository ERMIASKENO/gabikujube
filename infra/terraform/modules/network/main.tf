# Hub-less single-VNet layout per environment (a hub/spoke with Azure Firewall
# is the next step for multi-team estates; see docs/ARCHITECTURE.md).
#
#   10.x.0.0/16
#   ├─ snet-aks-nodes   /20  nodes only (Azure CNI Overlay: pods use 192.168/16)
#   ├─ snet-pe          /24  private endpoints (ACR, KV, Redis, Service Bus)
#   ├─ snet-pls         /24  Private Link Service for Front Door -> internal LB
#   ├─ snet-postgres    /24  delegated to PostgreSQL Flexible Server
#   └─ snet-ops         /24  jumpbox / self-hosted runner VM
locals {
  subnets = {
    aks_nodes = cidrsubnet(var.address_space, 4, 0)  # x.0.0/20
    pe        = cidrsubnet(var.address_space, 8, 16) # x.16.0/24
    pls       = cidrsubnet(var.address_space, 8, 17)
    postgres  = cidrsubnet(var.address_space, 8, 18)
    ops       = cidrsubnet(var.address_space, 8, 19)
  }

  private_dns_zones = toset([
    "privatelink.azurecr.io",
    "privatelink.vaultcore.azure.net",
    "privatelink.servicebus.windows.net",
    "privatelink.redis.azure.net",
    "${var.name}.private.postgres.database.azure.com",
  ])
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.aks_nodes]
}

resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [local.subnets.pe]
  private_endpoint_network_policies = "Enabled" # NSGs/UDRs apply to private endpoints
}

resource "azurerm_subnet" "pls" {
  name                                          = "snet-pls"
  resource_group_name                           = var.resource_group_name
  virtual_network_name                          = azurerm_virtual_network.this.name
  address_prefixes                              = [local.subnets.pls]
  private_link_service_network_policies_enabled = false # required for PLS NAT IPs
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.postgres]

  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "ops" {
  name                 = "snet-ops"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.ops]
}

# ---------------------------------------------------------------------------
# Egress: NAT Gateway instead of LB outbound rules -> predictable egress IP
# (allow-listable by partners) and no SNAT port exhaustion under load.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "ng-${var.name}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks_nodes.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet_nat_gateway_association" "ops" {
  subnet_id      = azurerm_subnet.ops.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---------------------------------------------------------------------------
# NSG for the ops subnet: nothing inbound from the internet. Access is via
# Azure Bastion + Entra ID SSH login (no keys handed out, no public IP).
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "ops" {
  name                = "nsg-ops-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "ops" {
  subnet_id                 = azurerm_subnet.ops.id
  network_security_group_id = azurerm_network_security_group.ops.id
}

# ---------------------------------------------------------------------------
# Private DNS so PaaS FQDNs resolve to private endpoint IPs inside the VNet
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each              = local.private_dns_zones
  name                  = "link-${var.name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
