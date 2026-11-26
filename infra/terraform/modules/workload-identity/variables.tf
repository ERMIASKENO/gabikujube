variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "oidc_issuer_url" { type = string }

variable "workloads" {
  description = "Workload => namespace, service account and data-plane roles."
  type = map(object({
    namespace       = string
    service_account = string
    roles = list(object({
      role  = string
      scope = string
    }))
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
