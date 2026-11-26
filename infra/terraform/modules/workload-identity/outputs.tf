output "client_ids" {
  description = "workload => client id; goes into the ServiceAccount annotation azure.workload.identity/client-id."
  value       = { for k, id in azurerm_user_assigned_identity.this : k => id.client_id }
}

output "principal_ids" {
  value = { for k, id in azurerm_user_assigned_identity.this : k => id.principal_id }
}
