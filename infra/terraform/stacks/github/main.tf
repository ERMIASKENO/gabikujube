# GitHub Enterprise configuration as code.
# Before: branch protection, environments, reviewers and Actions policies were
# clicked together per repo and drifted. Now every setting is reviewed in a PR
# and applied by the same pipeline as the cloud infrastructure.
#
# NOTE: teams, team permissions and Integration bypass actors require a GitHub
# ORGANIZATION. On a personal account, apply only the repository, ruleset and
# environment resources (or create a free org and transfer the repo).
#
# Auth: a GitHub App installation (GITHUB_APP_ID / GITHUB_APP_INSTALLATION_ID /
# GITHUB_APP_PEM_FILE) with org admin + repo admin permissions.
terraform {
  required_version = ">= 1.11"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
  backend "azurerm" {}
}

provider "github" {
  owner = var.org
  app_auth {} # reads GITHUB_APP_* env vars
}

variable "org" {
  type    = string
  default = "ERMIASKENO"
}

variable "environments" {
  description = "env => Azure identity for GitHub OIDC (client ids are not secrets)."
  type = map(object({
    azure_client_id       = string
    azure_subscription_id = string
    reviewers_team        = optional(string)
    wait_minutes          = optional(number, 0)
    # *-plan environments must run on PR branches; deploy envs only from main
    protected_branches_only = optional(bool, true)
  }))
}

variable "gitops_app_id" {
  description = "GitHub App used by CI to commit/PR desired-state changes."
  type        = number
}

variable "azure_tenant_id" {
  type = string
}

# ----------------------------------------------------------------- teams
resource "github_team" "platform" {
  name        = "platform"
  description = "Platform engineering - owns infra, pipelines, clusters"
  privacy     = "closed"
}

resource "github_team" "release_managers" {
  name        = "release-managers"
  description = "Approve production deployments"
  privacy     = "closed"
}

# ----------------------------------------------------------------- repo
resource "github_repository" "shopsphere" {
  name                        = "gabikujube"
  description                 = "ShopSphere e-commerce platform"
  visibility                  = "public" # "internal" in a GHEC enterprise
  has_issues                  = true
  allow_merge_commit          = false
  allow_rebase_merge          = false
  allow_squash_merge          = true
  squash_merge_commit_title   = "PR_TITLE"
  delete_branch_on_merge      = true
  allow_auto_merge            = true
  vulnerability_alerts        = true
  web_commit_signoff_required = true

  security_and_analysis {
    advanced_security {
      status = "enabled"
    }
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

resource "github_team_repository" "platform" {
  team_id    = github_team.platform.id
  repository = github_repository.shopsphere.name
  permission = "maintain"
}

# Only allow GitHub-owned, verified-creator and explicitly listed actions.
# (Org policy additionally enforces SHA pinning for third-party actions.)
resource "github_actions_repository_permissions" "this" {
  repository      = github_repository.shopsphere.name
  allowed_actions = "selected"
  enabled         = true

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = true
    patterns_allowed = [
      "azure/*",
      "docker/*",
      "aquasecurity/*",
      "anchore/*",
      "sigstore/*",
      "hashicorp/*",
      "dorny/paths-filter@*",
      "actions/*",
    ]
  }
}

# ----------------------------------------------------------------- rulesets
resource "github_repository_ruleset" "main" {
  name        = "main-protection"
  repository  = github_repository.shopsphere.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # The GitOps App may push dev promotions straight to main (audited bot
  # commits); staging/prod promotions still go through PR + release managers.
  bypass_actors {
    actor_id    = var.gitops_app_id
    actor_type  = "Integration"
    bypass_mode = "always"
  }

  # Platform team can bypass only through a PR (audited), never by direct push
  bypass_actors {
    actor_id    = github_team.platform.id
    actor_type  = "Team"
    bypass_mode = "pull_request"
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true
    required_signatures     = true

    pull_request {
      required_approving_review_count   = 1
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      # single aggregate check => path-filtered/matrix jobs never block merges
      required_check {
        context = "ci-gate"
      }
      required_check {
        context = "CodeQL"
      }
    }

    merge_queue {
      merge_method                      = "SQUASH"
      grouping_strategy                 = "ALLGREEN"
      max_entries_to_build              = 5
      min_entries_to_merge              = 1
      min_entries_to_merge_wait_minutes = 5
      check_response_timeout_minutes    = 60
    }
  }
}

resource "github_repository_ruleset" "release_tags" {
  name        = "release-tags"
  repository  = github_repository.shopsphere.name
  target      = "tag"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/tags/v*"]
      exclude = []
    }
  }

  rules {
    deletion = true
    update   = true # release tags are immutable
  }
}

# ----------------------------------------------------------------- environments
resource "github_repository_environment" "this" {
  for_each            = var.environments
  repository          = github_repository.shopsphere.name
  environment         = each.key
  wait_timer          = each.value.wait_minutes
  prevent_self_review = true

  dynamic "reviewers" {
    for_each = each.value.reviewers_team == null ? [] : [1]
    content {
      teams = [each.value.reviewers_team == "release-managers" ? github_team.release_managers.id : github_team.platform.id]
    }
  }

  dynamic "deployment_branch_policy" {
    for_each = each.value.protected_branches_only ? [1] : []
    content {
      protected_branches     = true # only main can deploy
      custom_branch_policies = false
    }
  }
}

# OIDC identifiers are configuration, not secrets -> Actions *variables*
resource "github_actions_environment_variable" "client_id" {
  for_each      = var.environments
  repository    = github_repository.shopsphere.name
  environment   = github_repository_environment.this[each.key].environment
  variable_name = "AZURE_CLIENT_ID"
  value         = each.value.azure_client_id
}

resource "github_actions_environment_variable" "subscription_id" {
  for_each      = var.environments
  repository    = github_repository.shopsphere.name
  environment   = github_repository_environment.this[each.key].environment
  variable_name = "AZURE_SUBSCRIPTION_ID"
  value         = each.value.azure_subscription_id
}

resource "github_actions_variable" "tenant_id" {
  repository    = github_repository.shopsphere.name
  variable_name = "AZURE_TENANT_ID"
  value         = var.azure_tenant_id
}
