output "vm_id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "private_ip" {
  value = azurerm_network_interface.this.private_ip_address
}

output "principal_id" {
  description = "System-assigned identity used by the infra runner (az login --identity)."
  value       = azurerm_linux_virtual_machine.this.identity[0].principal_id
}
