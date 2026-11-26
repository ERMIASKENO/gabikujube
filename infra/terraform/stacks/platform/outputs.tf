# These outputs are the contract between the infra layer and the GitOps layer.
# scripts/ops/render-platform-values.sh turns them into
# gitops/envs/<env>/platform-outputs.yaml (non-secret IDs only).
output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_name" {
  value = module.aks.name
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "key_vault_name" {
  value = module.keyvault.name
}

output "key_vault_uri" {
  value = module.keyvault.vault_uri
}

output "workload_client_ids" {
  value = module.workload_identity.client_ids
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "servicebus_fqdn" {
  value = module.data.servicebus_fqdn
}

output "redis_host" {
  value = module.data.redis_host
}

output "postgres_fqdn" {
  value = module.data.postgres_fqdn
}

output "egress_ip" {
  value = module.network.nat_public_ip
}

output "frontdoor_endpoint" {
  value = try(module.edge[0].endpoint_host_name, null)
}
