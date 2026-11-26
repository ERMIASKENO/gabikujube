output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "redis_host" {
  value = azapi_resource.redis.output.properties.hostName
}

output "servicebus_id" {
  value = azurerm_servicebus_namespace.this.id
}

output "servicebus_fqdn" {
  value = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
}

output "order_events_topic_id" {
  value = azurerm_servicebus_topic.order_events.id
}
