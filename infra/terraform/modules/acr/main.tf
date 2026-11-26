# Premium ACR: zone redundant, private endpoint, geo-replication, retention of
# untagged manifests. Admin user disabled -> pushes use GitHub OIDC identity
# (AcrPush), pulls use the kubelet identity (AcrPull). No passwords anywhere.
resource "azurerm_container_registry" "this" {
  name                          = var.name # globally unique, alphanumeric
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  zone_redundancy_enabled       = true
  data_endpoint_enabled         = true
  public_network_access_enabled = var.public_network_access_enabled
  network_rule_bypass_option    = "AzureServices"
  retention_policy_in_days      = 14
  tags                          = var.tags

  dynamic "georeplications" {
    for_each = var.geo_replication_locations
    content {
      location                = georeplications.value
      zone_redundancy_enabled = true
    }
  }
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

resource "azurerm_role_assignment" "pull" {
  for_each             = var.pull_principal_ids # map: static keys, values may be unknown at plan
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "push" {
  for_each             = var.push_principal_ids
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = each.value
}
