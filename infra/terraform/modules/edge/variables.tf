variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }

variable "private_link_service_id" {
  description = "PLS created by AKS from the istio-ingressgateway Service annotations."
  type        = string
}

variable "origin_private_ip" {
  description = "Frontend IP of the internal load balancer behind the PLS."
  type        = string
}

variable "public_host_name" {
  type = string
}

variable "waf_mode" {
  type    = string
  default = "Prevention"
  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be Detection or Prevention."
  }
}

variable "api_rate_limit_per_minute" {
  type    = number
  default = 600
}

variable "tags" {
  type    = map(string)
  default = {}
}
