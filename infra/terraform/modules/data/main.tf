# Stateful PaaS: PostgreSQL Flexible Server, Azure Managed Redis, Service Bus.
#
# Secrets never touch Terraform state:
#   ephemeral random_password -> administrator_password_wo (write-only)
#                              -> azurerm_key_vault_secret.value_wo (write-only)
# Rotate by bumping var.secret_version (Terraform >= 1.11).

# ----------------------------------------------------------------- PostgreSQL
ephemeral "random_password" "pg_admin" {
  length  = 40
  special = false # avoids URL-encoding issues in the DSN
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                              = "psql-${var.name}"
  location                          = var.location
  resource_group_name               = var.resource_group_name
  version                           = "16"
  sku_name                          = var.postgres_sku
  storage_mb                        = var.postgres_storage_mb
  auto_grow_enabled                 = true
  backup_retention_days             = var.postgres_ha ? 35 : 7
  geo_redundant_backup_enabled      = var.postgres_ha
  delegated_subnet_id               = var.postgres_subnet_id
  private_dns_zone_id               = var.postgres_dns_zone_id
  public_network_access_enabled     = false
  zone                              = "1"
  administrator_login               = "shopadmin"
  administrator_password_wo         = ephemeral.random_password.pg_admin.result
  administrator_password_wo_version = var.secret_version
  tags                              = var.tags

  authentication {
    active_directory_auth_enabled = true # next step: apps use Entra tokens, drop passwords
    password_auth_enabled         = true
    tenant_id                     = var.tenant_id
  }

  dynamic "high_availability" {
    for_each = var.postgres_ha ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }

  lifecycle {
    prevent_destroy = true # holds customer data
    # Azure may swap primary/standby zones after a failover; don't fight it.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "inventory" {
  name      = "inventory"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true # dropping a prod database should never be a plan side-effect
  }
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # derived value, regenerated on rotation
resource "azurerm_key_vault_secret" "inventory_dsn" {
  name             = "inventory-database-url"
  key_vault_id     = var.key_vault_id
  content_type     = "postgresql-dsn"
  value_wo_version = var.secret_version
  value_wo = format(
    "postgresql://shopadmin:%s@%s:5432/inventory?sslmode=require",
    ephemeral.random_password.pg_admin.result,
    azurerm_postgresql_flexible_server.this.fqdn,
  )
}

# ----------------------------------------------------------- Azure Managed Redis
# Azure Cache for Redis is retiring; Azure Managed Redis is the replacement.
# Deployed through AzAPI so we are not blocked on azurerm resource coverage.
resource "azapi_resource" "redis" {
  type      = "Microsoft.Cache/redisEnterprise@2025-07-01"
  name      = "amr-${var.name}"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    sku = { name = var.redis_sku }
    properties = {
      minimumTlsVersion   = "1.2"
      highAvailability    = var.redis_ha ? "Enabled" : "Disabled"
      publicNetworkAccess = "Disabled" # reachable only via the private endpoint
    }
  }
  response_export_values = ["properties.hostName"]
}

resource "azapi_resource" "redis_db" {
  type      = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  name      = "default"
  parent_id = azapi_resource.redis.id

  body = {
    properties = {
      clientProtocol           = "Encrypted"
      port                     = 10000
      clusteringPolicy         = "OSSCluster"
      evictionPolicy           = "VolatileLRU"
      accessKeysAuthentication = "Enabled" # TODO: switch cart to Entra auth and disable keys
    }
  }
}

resource "azapi_resource_action" "redis_keys" {
  type                             = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  resource_id                      = azapi_resource.redis_db.id
  action                           = "listKeys"
  sensitive_response_export_values = ["primaryKey"]
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # derived value, regenerated on rotation
resource "azurerm_key_vault_secret" "redis_password" {
  name         = "cart-redis-password"
  key_vault_id = var.key_vault_id
  value        = azapi_resource_action.redis_keys.sensitive_output.primaryKey
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-amr-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "redis"
    private_connection_resource_id = azapi_resource.redis.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [var.redis_dns_zone_id]
  }
}

# ----------------------------------------------------------------- Service Bus
resource "azurerm_servicebus_namespace" "this" {
  name                          = "sb-${var.name}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = var.servicebus_premium ? "Premium" : "Standard"
  capacity                      = var.servicebus_premium ? 1 : 0
  premium_messaging_partitions  = var.servicebus_premium ? 1 : 0
  local_auth_enabled            = false                   # Entra ID only: no SAS keys to leak
  public_network_access_enabled = !var.servicebus_premium # private endpoints need Premium
  minimum_tls_version           = "1.2"
  tags                          = var.tags

  lifecycle {
    prevent_destroy = true # in-flight messages would be lost
  }
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # namespace is protected; topic config is fully in code
resource "azurerm_servicebus_topic" "order_events" {
  name                                    = "order-events"
  namespace_id                            = azurerm_servicebus_namespace.this.id
  requires_duplicate_detection            = true # dedupe on MessageId = orderId
  duplicate_detection_history_time_window = "PT10M"
  default_message_ttl                     = "P7D"
}

resource "azurerm_servicebus_subscription" "notification" {
  name                                 = "notification"
  topic_id                             = azurerm_servicebus_topic.order_events.id
  max_delivery_count                   = 5
  lock_duration                        = "PT1M"
  dead_lettering_on_message_expiration = true
}

resource "azurerm_private_endpoint" "servicebus" {
  count               = var.servicebus_premium ? 1 : 0
  name                = "pe-sb-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "servicebus"
    private_connection_resource_id = azurerm_servicebus_namespace.this.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "servicebus"
    private_dns_zone_ids = [var.servicebus_dns_zone_id]
  }
}
