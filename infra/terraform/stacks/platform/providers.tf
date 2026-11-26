# Auth comes from the environment in CI:
#   ARM_USE_OIDC=true ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID
# i.e. GitHub's OIDC token is exchanged for an Entra token. No client secret.
provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  # Only register the resource providers we use (least privilege for the CI identity)
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.ContainerService",
    "Microsoft.ContainerRegistry",
    "Microsoft.KeyVault",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.Cache",
    "Microsoft.ServiceBus",
    "Microsoft.Cdn",
    "Microsoft.Network",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights",
    "Microsoft.ManagedIdentity",
    "Microsoft.Compute",
    "Microsoft.Consumption",
  ]

  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}
