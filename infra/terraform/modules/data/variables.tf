variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "resource_group_id" { type = string }
variable "tenant_id" { type = string }
variable "key_vault_id" { type = string }
variable "postgres_subnet_id" { type = string }
variable "postgres_dns_zone_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "redis_dns_zone_id" { type = string }
variable "servicebus_dns_zone_id" { type = string }

variable "secret_version" {
  description = "Bump to rotate generated credentials (write-only attributes)."
  type        = number
  default     = 1
}

variable "postgres_sku" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  type    = number
  default = 32768
}

variable "postgres_ha" {
  type    = bool
  default = false
}

variable "redis_sku" {
  description = "Azure Managed Redis SKU, e.g. Balanced_B0 (dev) / Balanced_B5 (prod)."
  type        = string
  default     = "Balanced_B0"
}

variable "redis_ha" {
  type    = bool
  default = false
}

variable "servicebus_premium" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
