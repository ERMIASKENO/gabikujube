variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be dev, staging or prod."
  }
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "address_space" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "aks" {
  description = "AKS sizing per environment."
  type = object({
    sku_tier                 = string
    private_cluster_enabled  = bool
    api_authorized_ip_ranges = optional(list(string), [])
    system_vm_size           = string
    apps_vm_size             = string
    system_min_count         = number
    system_max_count         = number
    apps_min_count           = number
    apps_max_count           = number
    enable_spot_pool         = optional(bool, false)
  })
}

variable "data" {
  type = object({
    postgres_sku       = string
    postgres_ha        = bool
    redis_sku          = string
    redis_ha           = bool
    servicebus_premium = bool
  })
}

variable "admin_group_object_ids" {
  description = "Entra groups with cluster/VM admin (break-glass)."
  type        = list(string)
}

variable "ci_principal_id" {
  description = "Object id of the GitHub Actions OIDC identity for this env (created by scripts/bootstrap)."
  type        = string
}

variable "acr_public_access" {
  description = "Allow pushes from GitHub-hosted runners. false => private runners / Azure private networking."
  type        = bool
  default     = false
}

variable "acr_geo_replications" {
  type    = list(string)
  default = []
}

variable "ops_ssh_public_key" {
  type = string
}

variable "public_host_name" {
  description = "Public host served by Front Door, e.g. shop.example.com."
  type        = string
}

variable "ingress_internal_ip" {
  description = "Static IP pinned on the istio ingress internal LB (inside the AKS node subnet)."
  type        = string
}

variable "frontdoor_pls_name" {
  description = "Name of the PLS AKS creates for istio ingress. Empty until the platform layer is deployed (phase 2)."
  type        = string
  default     = ""
}

variable "public_dns_zone_id" {
  description = "Optional Azure DNS zone for cert-manager DNS-01."
  type        = string
  default     = ""
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "monthly_budget" {
  type = number
}

variable "budget_start_date" {
  description = "First day of a month, RFC3339."
  type        = string
  default     = "2026-12-01T00:00:00Z"
}

variable "secret_version" {
  description = "Bump to rotate generated DB credentials."
  type        = number
  default     = 1
}

variable "cost_center" {
  type    = string
  default = "ecommerce"
}
