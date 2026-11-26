# Production AKS baseline:
#  * Entra ID auth + Azure RBAC, local accounts disabled (no static kubeconfig)
#  * OIDC issuer + Workload Identity (pods get Entra tokens, no secrets)
#  * Azure CNI Overlay + Cilium dataplane/network policy
#  * NAT Gateway egress, optional private API server
#  * system pool tainted for critical add-ons; separate autoscaled app pool
#    across 3 zones; optional spot pool for batch/preview workloads
#  * managed KEDA + VPA add-ons, Azure Policy, image cleaner
#  * patch auto-upgrade + node OS image auto-upgrade in maintenance windows
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "id-aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Cluster identity must manage LBs / PLS in our custom VNet
resource "azurerm_role_assignment" "cluster_network" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  node_resource_group = "rg-${var.name}-nodes"
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version # minor only (e.g. "1.35"); patches via auto-upgrade
  sku_tier            = var.sku_tier
  support_plan        = "KubernetesOfficial"

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  private_cluster_enabled      = var.private_cluster_enabled
  local_account_disabled       = true
  oidc_issuer_enabled          = true
  workload_identity_enabled    = true
  azure_policy_enabled         = true
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier != "Free"

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = var.node_subnet_id
    auto_scaling_enabled         = true
    min_count                    = var.system_min_count
    max_count                    = var.system_max_count
    zones                        = var.zones
    os_sku                       = "AzureLinux"
    only_critical_addons_enabled = true # taints CriticalAddonsOnly=true:NoSchedule
    temporary_name_for_rotation  = "systemtmp"

    upgrade_settings {
      max_surge                = "33%"
      drain_timeout_in_minutes = 30
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "userAssignedNATGateway"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.240.0.0/16"
    dns_service_ip      = "10.240.0.10"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
  }

  dynamic "api_server_access_profile" {
    for_each = var.private_cluster_enabled ? [] : [1]
    content {
      authorized_ip_ranges = var.api_authorized_ip_ranges
    }
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = true
    snapshot_controller_enabled = true
    blob_driver_enabled         = false
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Saturday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # owned by cluster autoscaler
    ]
  }

  depends_on = [azurerm_role_assignment.cluster_network]
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.apps_vm_size
  vnet_subnet_id        = var.node_subnet_id
  mode                  = "User"
  os_sku                = "AzureLinux"
  zones                 = var.zones
  auto_scaling_enabled  = true
  min_count             = var.apps_min_count
  max_count             = var.apps_max_count
  node_labels           = { "shopsphere.io/pool" = "apps" }

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Spot pool: up to 90% cheaper; only for interruptible work (preview stacks,
# batch CronJobs). Workloads must tolerate the AKS-added spot taint.
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count                 = var.enable_spot_pool ? 1 : 0
  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.apps_vm_size
  vnet_subnet_id        = var.node_subnet_id
  mode                  = "User"
  os_sku                = "AzureLinux"
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1
  auto_scaling_enabled  = true
  min_count             = 0
  max_count             = 5
  node_labels           = { "kubernetes.azure.com/scalesetpriority" = "spot" }
  node_taints           = ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]
  tags                  = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Control-plane logs -> Log Analytics (audit trail for "who changed what")
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-aks"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }
  enabled_log {
    category = "guard"
  }
}
