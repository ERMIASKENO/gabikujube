data "azurerm_client_config" "current" {}

locals {
  name = "shopsphere-${var.env}"
  # Key Vault / ACR names are global and length-limited
  compact = replace(local.name, "-", "")
  tags = {
    app         = "shopsphere"
    env         = var.env
    owner       = "platform-team"
    managed_by  = "terraform"
    repo        = "ERMIASKENO/gabikujube"
    cost_center = var.cost_center
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.env == "prod" ? 90 : 30
  daily_quota_gb      = var.env == "prod" ? -1 : 5 # cap spend outside prod
  tags                = local.tags
}

module "network" {
  source              = "../../modules/network"
  name                = local.name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.address_space
  tags                = local.tags
}

module "aks" {
  source                     = "../../modules/aks"
  name                       = local.name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  vnet_id                    = module.network.vnet_id
  node_subnet_id             = module.network.subnet_ids.aks_nodes
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  kubernetes_version         = var.kubernetes_version
  admin_group_object_ids     = var.admin_group_object_ids
  sku_tier                   = var.aks.sku_tier
  private_cluster_enabled    = var.aks.private_cluster_enabled
  api_authorized_ip_ranges   = var.aks.api_authorized_ip_ranges
  system_vm_size             = var.aks.system_vm_size
  apps_vm_size               = var.aks.apps_vm_size
  system_min_count           = var.aks.system_min_count
  system_max_count           = var.aks.system_max_count
  apps_min_count             = var.aks.apps_min_count
  apps_max_count             = var.aks.apps_max_count
  enable_spot_pool           = var.aks.enable_spot_pool
  tags                       = local.tags
}

module "acr" {
  source                        = "../../modules/acr"
  name                          = "acr${local.compact}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  private_endpoint_subnet_id    = module.network.subnet_ids.pe
  private_dns_zone_id           = module.network.private_dns_zone_ids["privatelink.azurecr.io"]
  public_network_access_enabled = var.acr_public_access
  geo_replication_locations     = var.acr_geo_replications
  pull_principal_ids            = { aks_kubelet = module.aks.kubelet_object_id }
  push_principal_ids            = { github_ci = var.ci_principal_id }
  tags                          = local.tags
}

module "keyvault" {
  source                        = "../../modules/keyvault"
  name                          = "kv-${substr(local.compact, 0, 20)}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  private_endpoint_subnet_id    = module.network.subnet_ids.pe
  private_dns_zone_id           = module.network.private_dns_zone_ids["privatelink.vaultcore.azure.net"]
  deployer_principal_id         = data.azurerm_client_config.current.object_id
  public_network_access_enabled = var.env == "dev"
  tags                          = local.tags
}

module "data" {
  source                     = "../../modules/data"
  name                       = local.name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  resource_group_id          = azurerm_resource_group.this.id
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  key_vault_id               = module.keyvault.id
  postgres_subnet_id         = module.network.subnet_ids.postgres
  postgres_dns_zone_id       = module.network.postgres_dns_zone_id
  private_endpoint_subnet_id = module.network.subnet_ids.pe
  redis_dns_zone_id          = module.network.private_dns_zone_ids["privatelink.redis.azure.net"]
  servicebus_dns_zone_id     = module.network.private_dns_zone_ids["privatelink.servicebus.windows.net"]
  secret_version             = var.secret_version
  postgres_sku               = var.data.postgres_sku
  postgres_ha                = var.data.postgres_ha
  redis_sku                  = var.data.redis_sku
  redis_ha                   = var.data.redis_ha
  servicebus_premium         = var.data.servicebus_premium
  tags                       = local.tags

  depends_on = [module.keyvault] # deployer RBAC on KV must exist before writing secrets
}

module "workload_identity" {
  source              = "../../modules/workload-identity"
  name                = local.name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  oidc_issuer_url     = module.aks.oidc_issuer_url
  tags                = local.tags

  workloads = merge(
    {
      order = {
        namespace       = "shop"
        service_account = "order"
        roles           = [{ role = "Azure Service Bus Data Sender", scope = module.data.order_events_topic_id }]
      }
      notification = {
        namespace       = "shop"
        service_account = "notification"
        roles           = [{ role = "Azure Service Bus Data Receiver", scope = module.data.order_events_topic_id }]
      }
      external-secrets = {
        namespace       = "external-secrets"
        service_account = "external-secrets"
        roles           = [{ role = "Key Vault Secrets User", scope = module.keyvault.id }]
      }
      # KEDA add-on reads subscription backlog to scale notification 0..N
      keda = {
        namespace       = "kube-system"
        service_account = "keda-operator"
        roles           = [{ role = "Azure Service Bus Data Owner", scope = module.data.servicebus_id }]
      }
    },
    var.public_dns_zone_id == "" ? {} : {
      cert-manager = {
        namespace       = "cert-manager"
        service_account = "cert-manager"
        roles           = [{ role = "DNS Zone Contributor", scope = var.public_dns_zone_id }]
      }
    },
  )
}

module "jumpbox" {
  source                 = "../../modules/jumpbox"
  name                   = local.name
  location               = var.location
  resource_group_name    = azurerm_resource_group.this.name
  subnet_id              = module.network.subnet_ids.ops
  vnet_id                = module.network.vnet_id
  admin_ssh_public_key   = var.ops_ssh_public_key
  admin_group_object_ids = var.admin_group_object_ids
  harden_script          = file("${path.root}/../../../../scripts/linux/harden-server.sh")
  runner_script          = file("${path.root}/../../../../scripts/linux/install-runner.sh")
  health_script          = file("${path.root}/../../../../scripts/linux/health-check.sh")
  tags                   = local.tags
}

# ---------------------------------------------------------------------------
# Phase 2 (after Argo CD has deployed istio-ingressgateway and AKS created the
# Private Link Service): set frontdoor_pls_name in tfvars and re-apply.
# Then approve the private endpoint connection: scripts/ops/approve-frontdoor-pls.sh
# ---------------------------------------------------------------------------
data "azurerm_private_link_service" "ingress" {
  count               = var.frontdoor_pls_name == "" ? 0 : 1
  name                = var.frontdoor_pls_name
  resource_group_name = module.aks.node_resource_group
}

module "edge" {
  count                   = var.frontdoor_pls_name == "" ? 0 : 1
  source                  = "../../modules/edge"
  name                    = local.name
  location                = var.location
  resource_group_name     = azurerm_resource_group.this.name
  private_link_service_id = data.azurerm_private_link_service.ingress[0].id
  origin_private_ip       = var.ingress_internal_ip
  public_host_name        = var.public_host_name
  waf_mode                = var.env == "prod" ? "Prevention" : "Detection"
  tags                    = local.tags
}

# ------------------------------------------------------------------ alerting
resource "azurerm_monitor_action_group" "platform" {
  name                = "ag-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "platform"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "aks_node_cpu" {
  name                = "alert-aks-node-cpu-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [module.aks.id]
  description         = "Sustained node CPU > 85% - autoscaler may be at max_count."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# FinOps guard-rail: email at 80% / 100% of the monthly budget
resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "budget-${local.name}"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.monthly_budget
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = length(var.alert_emails) > 0
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = length(var.alert_emails) > 0
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.alert_emails
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
