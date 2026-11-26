variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tenant_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "deployer_principal_id" { type = string }

variable "public_network_access_enabled" {
  type    = bool
  default = false
}

variable "allowed_ip_ranges" {
  type    = list(string)
  default = []
}

variable "secret_reader_principal_ids" {
  type    = map(string)
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
