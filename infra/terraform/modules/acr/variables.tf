variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }

variable "public_network_access_enabled" {
  description = "true only while CI pushes from GitHub-hosted runners without private networking."
  type        = bool
  default     = false
}

variable "geo_replication_locations" {
  type    = list(string)
  default = []
}

variable "pull_principal_ids" {
  description = "Map of stable name => principal id (map, not list, so for_each keys are known at plan time)."
  type        = map(string)
  default     = {}
}

variable "push_principal_ids" {
  type    = map(string)
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
