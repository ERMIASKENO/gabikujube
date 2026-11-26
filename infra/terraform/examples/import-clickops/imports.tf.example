# Example: adopting a hand-made public DNS zone and its NSG rule.
# Run `terraform plan -generate-config-out=generated.tf`, review, then merge
# the generated resources into the real module and delete this file.
import {
  to = azurerm_dns_zone.public
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/dnsZones/example.com"
}

import {
  to = azurerm_network_security_rule.incident_hotfix
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shopsphere-prod/providers/Microsoft.Network/networkSecurityGroups/nsg-ops-shopsphere-prod/securityRules/allow-vendor-443"
}
