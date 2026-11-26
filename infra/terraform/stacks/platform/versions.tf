terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0" # 5.0 upgrade tracked separately; .terraform.lock.hcl pins exact builds
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # Partial backend config: values come from envs/<env>.backend.hcl so the
  # same root module serves dev/staging/prod with isolated state files.
  #   terraform init -backend-config=envs/prod.backend.hcl
  backend "azurerm" {}
}
