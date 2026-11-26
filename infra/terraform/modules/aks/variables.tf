variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tenant_id" { type = string }
variable "vnet_id" { type = string }
variable "node_subnet_id" { type = string }
variable "log_analytics_workspace_id" { type = string }

variable "kubernetes_version" {
  description = "Minor version only (e.g. 1.35). Patch upgrades are automatic."
  type        = string
  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "Use a minor version like 1.35 so patch auto-upgrades don't cause drift."
  }
}

variable "sku_tier" {
  description = "Free (dev), Standard (SLA) or Premium (LTS)."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "private_cluster_enabled" {
  type    = bool
  default = true
}

variable "api_authorized_ip_ranges" {
  description = "Only used for public API servers (dev)."
  type        = list(string)
  default     = []
}

variable "admin_group_object_ids" {
  description = "Entra groups that get cluster-admin via Azure RBAC."
  type        = list(string)
}

variable "zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "system_vm_size" {
  type    = string
  default = "Standard_D4ds_v5"
}

variable "system_min_count" {
  type    = number
  default = 2
}

variable "system_max_count" {
  type    = number
  default = 4
}

variable "apps_vm_size" {
  type    = string
  default = "Standard_D4ds_v5"
}

variable "apps_min_count" {
  type    = number
  default = 3
}

variable "apps_max_count" {
  type    = number
  default = 12
}

variable "enable_spot_pool" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
