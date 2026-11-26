# Continuous validation: evaluated on every plan/apply (and the nightly drift
# job). A failed check is a warning, not an error - it tells you the
# infrastructure applied fine but the system it supports is unhealthy.
check "public_endpoint_healthy" {
  data "http" "healthz" {
    url = "https://${var.public_host_name}/healthz"
    retry {
      attempts = 3
    }
  }

  assert {
    condition     = data.http.healthz.status_code == 200
    error_message = "https://${var.public_host_name}/healthz returned ${data.http.healthz.status_code}."
  }
}

check "aks_has_workload_identity" {
  assert {
    condition     = startswith(module.aks.oidc_issuer_url, "https://")
    error_message = "AKS OIDC issuer missing: workload identity federation will fail."
  }
}
