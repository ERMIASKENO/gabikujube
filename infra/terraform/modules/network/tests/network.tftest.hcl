# `terraform test` with a mocked provider: runs in CI in seconds, no Azure
# credentials, and catches CIDR-math / validation regressions in the module.
mock_provider "azurerm" {}

variables {
  name                = "shopsphere-test"
  location            = "westeurope"
  resource_group_name = "rg-test"
  address_space       = "10.99.0.0/16"
}

run "subnet_layout" {
  command = plan

  assert {
    condition     = azurerm_subnet.aks_nodes.address_prefixes[0] == "10.99.0.0/20"
    error_message = "AKS node subnet must be the first /20."
  }
  assert {
    condition     = azurerm_subnet.pls.private_link_service_network_policies_enabled == false
    error_message = "PLS subnet must disable private link service network policies."
  }
  assert {
    condition     = length(azurerm_private_dns_zone.this) == 5
    error_message = "Expected 5 private DNS zones."
  }
}

run "rejects_non_slash16" {
  command = plan
  variables {
    address_space = "10.99.0.0/24"
  }
  expect_failures = [var.address_space]
}
