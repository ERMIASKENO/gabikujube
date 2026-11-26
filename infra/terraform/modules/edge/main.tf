# Global edge: Azure Front Door Premium + WAF -> Private Link -> internal
# Azure Standard Load Balancer (created by AKS for the Istio ingress gateway
# Service) -> Istio Gateway -> HTTPRoutes -> services.
#
# The cluster has NO public ingress IP. The only way in is through Front Door,
# which gives us global anycast, TLS at the edge, OWASP managed rules, bot
# protection and rate limiting before traffic touches the VNet.
resource "azurerm_cdn_frontdoor_profile" "this" {
  name                     = "afd-${var.name}"
  resource_group_name      = var.resource_group_name
  sku_name                 = "Premium_AzureFrontDoor" # Private Link origins need Premium
  response_timeout_seconds = 60
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = "ep-${var.name}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "aks" {
  name                     = "og-aks"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  session_affinity_enabled = false

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    path                = "/healthz"
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "GET"
  }
}

resource "azurerm_cdn_frontdoor_origin" "aks" {
  name                           = "origin-aks-${var.location}"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.aks.id
  enabled                        = true
  host_name                      = var.origin_private_ip # internal LB frontend IP
  origin_host_header             = var.public_host_name  # Istio Gateway serves this cert
  certificate_name_check_enabled = true
  http_port                      = 80
  https_port                     = 443
  priority                       = 1
  weight                         = 1000

  private_link {
    request_message        = "Front Door -> ${var.name} Istio ingress"
    location               = var.location
    private_link_target_id = var.private_link_service_id
  }
}

resource "azurerm_cdn_frontdoor_route" "default" {
  name                          = "route-all"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.aks.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.aks.id]
  supported_protocols           = ["Http", "Https"]
  patterns_to_match             = ["/*"]
  forwarding_protocol           = "HttpsOnly"
  https_redirect_enabled        = true
  link_to_default_domain        = true
}

resource "azurerm_cdn_frontdoor_firewall_policy" "waf" {
  name                = replace("waf${var.name}", "-", "")
  resource_group_name = var.resource_group_name
  sku_name            = azurerm_cdn_frontdoor_profile.this.sku_name
  enabled             = true
  mode                = var.waf_mode # start in Detection, flip to Prevention after tuning
  tags                = var.tags

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.1"
    action  = "Block"
  }

  custom_rule {
    name                           = "RateLimitApi"
    enabled                        = true
    priority                       = 100
    type                           = "RateLimitRule"
    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = var.api_rate_limit_per_minute
    action                         = "Block"

    match_condition {
      match_variable = "RequestUri"
      operator       = "Contains"
      match_values   = ["/api/"]
    }
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "waf" {
  name                     = "secpol-${var.name}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.waf.id
      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}
