# One user-assigned managed identity per workload, federated to exactly one
# Kubernetes ServiceAccount. Least privilege: each identity only gets the
# data-plane roles it needs, scoped to the narrowest resource.
#
#   pod (SA shop/order) --projected SA token--> Entra ID (trusts AKS OIDC issuer)
#                       <--access token-------- for Service Bus / Key Vault ...
locals {
  # flatten { workload => [roles] } into { "workload/role/n" => {...} }
  role_assignments = merge([
    for wname, w in var.workloads : {
      for idx, r in w.roles : "${wname}/${idx}" => {
        workload = wname
        role     = r.role
        scope    = r.scope
      }
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "this" {
  for_each            = var.workloads
  name                = "id-${each.key}-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  for_each            = var.workloads
  name                = "aks-${each.value.namespace}-${each.value.service_account}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

resource "azurerm_role_assignment" "this" {
  for_each             = local.role_assignments
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.this[each.value.workload].principal_id
}
