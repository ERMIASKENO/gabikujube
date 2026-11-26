azure_tenant_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
gitops_app_id   = 123456

environments = {
  # registry push identity (AcrPush on dev ACR only) used by _build-service.yml
  ci-publish = {
    azure_client_id       = "ci-publish-client-id-from-bootstrap"
    azure_subscription_id = "00000000-0000-0000-0000-000000000000"
  }
  # read-only plan identities (Reader + tfstate blob access), usable from PRs
  dev-plan = {
    azure_client_id         = "dev-plan-client-id"
    azure_subscription_id   = "00000000-0000-0000-0000-000000000000"
    protected_branches_only = false
  }
  staging-plan = {
    azure_client_id         = "staging-plan-client-id"
    azure_subscription_id   = "66666666-6666-6666-6666-666666666666"
    protected_branches_only = false
  }
  prod-plan = {
    azure_client_id         = "prod-plan-client-id"
    azure_subscription_id   = "33333333-3333-3333-3333-333333333333"
    protected_branches_only = false
  }
  dev = {
    azure_client_id       = "dev-client-id-from-bootstrap"
    azure_subscription_id = "00000000-0000-0000-0000-000000000000"
  }
  staging = {
    azure_client_id       = "staging-client-id-from-bootstrap"
    azure_subscription_id = "66666666-6666-6666-6666-666666666666"
    reviewers_team        = "platform"
  }
  prod = {
    azure_client_id       = "prod-client-id-from-bootstrap"
    azure_subscription_id = "33333333-3333-3333-3333-333333333333"
    reviewers_team        = "release-managers"
    wait_minutes          = 10 # bake time: staging soak before prod can start
  }
}
