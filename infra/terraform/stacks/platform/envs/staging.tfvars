env                = "staging"
subscription_id    = "66666666-6666-6666-6666-666666666666" # staging subscription
location           = "westeurope"
address_space      = "10.20.0.0/16"
kubernetes_version = "1.36"

aks = {
  sku_tier                = "Standard" # financially backed API server SLA
  private_cluster_enabled = true       # API server only reachable inside the VNet
  system_vm_size          = "Standard_D4ds_v5"
  apps_vm_size            = "Standard_D8ds_v5"
  system_min_count        = 3
  system_max_count        = 5
  apps_min_count          = 2
  apps_max_count          = 8
}

data = {
  postgres_sku       = "GP_Standard_D2ds_v5"
  postgres_ha        = true # zone-redundant standby, 35d PITR, geo backups
  redis_sku          = "Balanced_B1"
  redis_ha           = true
  servicebus_premium = true # private endpoint + isolation
}

admin_group_object_ids = ["44444444-4444-4444-4444-444444444444"]
ci_principal_id        = "55555555-5555-5555-5555-555555555555"
acr_public_access      = false # pushes go through private runners
acr_geo_replications   = []
ops_ssh_public_key     = "ssh-ed25519 AAAAC3Nza...replace-me ops@shopsphere"
public_host_name       = "staging.shop.example.com"
ingress_internal_ip    = "10.20.15.250"
frontdoor_pls_name     = "pls-istio-ingress"
alert_emails           = ["platform-alerts@example.com", "oncall@example.com"]
monthly_budget         = 1500
