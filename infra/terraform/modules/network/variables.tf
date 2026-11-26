variable "name" {
  description = "Name suffix, e.g. shopsphere-prod."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "address_space" {
  description = "VNet CIDR. Must be a /16 so the cidrsubnet() layout fits."
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && endswith(var.address_space, "/16")
    error_message = "address_space must be a valid /16 CIDR, e.g. 10.20.0.0/16."
  }
}

variable "zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
