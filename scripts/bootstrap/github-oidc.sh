#!/usr/bin/env bash
# Creates the Azure identities GitHub Actions uses via OIDC - no client
# secrets anywhere. One user-assigned managed identity per purpose, each
# federated ONLY to a specific GitHub environment:
#
#   id-gh-ci-publish     environment:ci-publish   AcrPush on dev ACR
#   id-gh-<env>-plan     environment:<env>-plan   Reader + tfstate blob access
#   id-gh-<env>          environment:<env>        Contributor + constrained RBAC admin
#
# The federated credential subject pins repo AND environment, so a workflow on
# a feature branch (or in a fork) can never obtain the prod identity, and the
# environment's protection rules (reviewers, branch policy) gate every token.
#
# Usage: github-oidc.sh --repo ERMIASKENO/gabikujube --env prod --subscription <id>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd az jq

REPO="" ENV_NAME="" SUBSCRIPTION="" LOCATION="westeurope"
RG="rg-shopsphere-identity"
TFSTATE_SCOPE_SA="stshopspheretfstate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --env) ENV_NAME="$2"; shift ;;
    --subscription) SUBSCRIPTION="$2"; shift ;;
    --location) LOCATION="$2"; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ -n "${REPO}" && -n "${ENV_NAME}" && -n "${SUBSCRIPTION}" ]] || die "--repo, --env and --subscription are required"

az account set --subscription "${SUBSCRIPTION}"
az group create --name "${RG}" --location "${LOCATION}" -o none

# ensure_identity <name> <github-environment> -> prints principalId
ensure_identity() {
  local name="$1" gh_env="$2" id
  az identity show -g "${RG}" -n "${name}" -o none 2>/dev/null || \
    az identity create -g "${RG}" -n "${name}" -l "${LOCATION}" -o none
  if ! az identity federated-credential show -g "${RG}" --identity-name "${name}" --name "github-${gh_env}" -o none 2>/dev/null; then
    az identity federated-credential create -g "${RG}" --identity-name "${name}" --name "github-${gh_env}" \
      --issuer https://token.actions.githubusercontent.com \
      --subject "repo:${REPO}:environment:${gh_env}" \
      --audiences api://AzureADTokenExchange -o none
    log_info "federated ${name} <- repo:${REPO}:environment:${gh_env}"
  fi
  id="$(az identity show -g "${RG}" -n "${name}" --query principalId -o tsv)"
  echo "${id}"
}

assign() { # principal role scope [condition]
  local existing
  existing="$(az role assignment list --assignee "$1" --role "$2" --scope "$3" --query 'length(@)' -o tsv)"
  [[ "${existing}" != "0" ]] && return 0
  if [[ -n "${4:-}" ]]; then
    az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
      --role "$2" --scope "$3" --condition "$4" --condition-version 2.0 -o none
  else
    az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
      --role "$2" --scope "$3" -o none
  fi
  log_info "granted $2 on ${3##*/}"
}

sub_scope="/subscriptions/${SUBSCRIPTION}"
state_scope="$(az storage account show -n "${TFSTATE_SCOPE_SA}" --query id -o tsv)/blobServices/default/containers/tfstate"

# read-only plan identity
plan_id="$(ensure_identity "id-gh-${ENV_NAME}-plan" "${ENV_NAME}-plan")"
assign "${plan_id}" "Reader" "${sub_scope}"
assign "${plan_id}" "Storage Blob Data Contributor" "${state_scope}"   # state lock (blob lease)
assign "${plan_id}" "Key Vault Secrets User" "${sub_scope}"            # refresh secret metadata

# deploy identity
deploy_id="$(ensure_identity "id-gh-${ENV_NAME}" "${ENV_NAME}")"
assign "${deploy_id}" "Contributor" "${sub_scope}"
assign "${deploy_id}" "Storage Blob Data Contributor" "${state_scope}"
assign "${deploy_id}" "Key Vault Secrets Officer" "${sub_scope}"
# Terraform creates role assignments (AcrPull, workload identities...). Instead
# of Owner, use RBAC Administrator with an ABAC condition: it may only assign
# this short list of roles, never Owner / User Access Administrator.
roles=(
  7f951dda-4ed3-4680-a7ca-43fe172d538d  # AcrPull
  8311e382-0749-4cb8-b61a-304f252e45ec  # AcrPush
  4633458b-17de-408a-b874-0445c86b69e6  # Key Vault Secrets User
  b86a8fe4-44ce-4948-aee5-eccb2c155cd7  # Key Vault Secrets Officer
  69a216fc-b8fb-44d8-bc22-1f3c2cd27a39  # Azure Service Bus Data Sender
  4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0  # Azure Service Bus Data Receiver
  090c5cfd-751d-490a-894a-3ce6f1109419  # Azure Service Bus Data Owner
  befefa01-2a29-4197-83a8-272ff33ce314  # DNS Zone Contributor
  4d97b98b-1d4f-4787-a291-c67834d212e7  # Network Contributor
  1c0163c0-47e6-4577-8991-ea5c82e286e4  # Virtual Machine Administrator Login
)
allowed_roles="$(IFS=,; echo "${roles[*]}")"
condition="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${allowed_roles}}))"
assign "${deploy_id}" "Role Based Access Control Administrator" "${sub_scope}" "${condition}"

if [[ "${ENV_NAME}" == "dev" ]]; then
  publish_id="$(ensure_identity "id-gh-ci-publish" "ci-publish")"
  log_info "grant AcrPush to id-gh-ci-publish (${publish_id}) once the dev ACR exists (terraform: ci_principal_id)"
fi

jq -n --arg env "${ENV_NAME}" \
  --arg plan "$(az identity show -g "${RG}" -n "id-gh-${ENV_NAME}-plan" --query clientId -o tsv)" \
  --arg deploy "$(az identity show -g "${RG}" -n "id-gh-${ENV_NAME}" --query clientId -o tsv)" \
  '{env:$env, plan_client_id:$plan, deploy_client_id:$deploy}'
