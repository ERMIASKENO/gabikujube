# terraform init -backend-config=envs/prod.backend.hcl
resource_group_name  = "rg-shopsphere-tfstate"
storage_account_name = "stshopspheretfstate"
container_name       = "tfstate"
key                  = "platform/prod.tfstate"
use_azuread_auth     = true # Entra RBAC on blob, no storage keys
use_oidc             = true
