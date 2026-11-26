output "id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  description = "Used as the issuer for every workload federated credential."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_object_id" {
  description = "Kubelet identity; gets AcrPull on the registry."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}
