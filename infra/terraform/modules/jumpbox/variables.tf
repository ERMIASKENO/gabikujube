variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "subnet_id" { type = string }
variable "vnet_id" { type = string }
variable "admin_ssh_public_key" { type = string }

variable "vm_size" {
  type    = string
  default = "Standard_B2s_v2" # B-series v1 sizes are announced for retirement
}

variable "admin_group_object_ids" {
  type    = list(string)
  default = []
}

variable "harden_script" {
  description = "Contents of scripts/linux/harden-server.sh"
  type        = string
}

variable "runner_script" {
  description = "Contents of scripts/linux/install-runner.sh"
  type        = string
}

variable "health_script" {
  description = "Contents of scripts/linux/health-check.sh"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
