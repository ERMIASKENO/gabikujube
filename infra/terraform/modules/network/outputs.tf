output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "subnet_ids" {
  value = {
    aks_nodes = azurerm_subnet.aks_nodes.id
    pe        = azurerm_subnet.pe.id
    pls       = azurerm_subnet.pls.id
    postgres  = azurerm_subnet.postgres.id
    ops       = azurerm_subnet.ops.id
  }
}

output "private_dns_zone_ids" {
  description = "Map of private DNS zone name => id."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "postgres_dns_zone_id" {
  value = azurerm_private_dns_zone.this["${var.name}.private.postgres.database.azure.com"].id
}

output "nat_public_ip" {
  description = "Stable egress IP for partner allow-lists."
  value       = azurerm_public_ip.nat.ip_address
}
