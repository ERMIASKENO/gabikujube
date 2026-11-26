env                = "dev"
subscription_id    = "00000000-0000-0000-0000-000000000000" # dev subscription
location           = "westeurope"
address_space      = "10.10.0.0/16"
kubernetes_version = "1.36"

aks = {
  sku_tier                 = "Free"
  private_cluster_enabled  = false # public API + authorized IPs keeps dev cheap and simple
  api_authorized_ip_ranges = ["203.0.113.0/24"]
  system_vm_size           = "Standard_D2ds_v5"
  apps_vm_size             = "Standard_D4ds_v5"
  system_min_count         = 1
  system_max_count         = 2
  apps_min_count           = 1
  apps_max_count           = 4
  enable_spot_pool         = true
}

data = {
  postgres_sku       = "B_Standard_B1ms"
  postgres_ha        = false
  redis_sku          = "Balanced_B0"
  redis_ha           = false
  servicebus_premium = false
}

admin_group_object_ids = ["11111111-1111-1111-1111-111111111111"]
ci_principal_id        = "22222222-2222-2222-2222-222222222222"
acr_public_access      = true # GitHub-hosted runners push to dev ACR
ops_ssh_public_key     = "ssh-ed25519 AAAAC3Nza...replace-me ops@shopsphere"
public_host_name       = "dev.shop.example.com"
ingress_internal_ip    = "10.10.15.250"
frontdoor_pls_name     = "" # phase 2: "pls-istio-ingress"
alert_emails           = ["platform-alerts@example.com"]
monthly_budget         = 400
