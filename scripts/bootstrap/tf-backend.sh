#!/usr/bin/env bash
# One-time (idempotent) bootstrap of the Terraform remote state backend.
# Terraform can't create the storage it keeps its own state in, so this is
# the only infrastructure created by script - and it is safe to re-run.
#
#  * Storage account: TLS 1.2, no shared keys (Entra auth only), no public blob
#  * blob versioning + soft delete => recover a corrupted/deleted state file
#  * resource lock (CanNotDelete) on the resource group
#
# Usage: tf-backend.sh --subscription <id> [--location westeurope]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd az

SUBSCRIPTION="" LOCATION="westeurope"
RG="rg-shopsphere-tfstate"
SA="stshopspheretfstate"
CONTAINER="tfstate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift ;;
    --location) LOCATION="$2"; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ -n "${SUBSCRIPTION}" ]] || die "--subscription is required"

run_cmd az account set --subscription "${SUBSCRIPTION}"

if [[ "$(az group exists --name "${RG}")" != "true" ]]; then
  run_cmd az group create --name "${RG}" --location "${LOCATION}" --tags managed_by=bootstrap app=shopsphere -o none
  log_info "created ${RG}"
fi

if ! az storage account show --name "${SA}" --resource-group "${RG}" -o none 2>/dev/null; then
  run_cmd az storage account create --name "${SA}" --resource-group "${RG}" --location "${LOCATION}" \
    --sku Standard_ZRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false \
    --https-only true -o none
  log_info "created storage account ${SA}"
fi

run_cmd az storage account blob-service-properties update --account-name "${SA}" --resource-group "${RG}" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 -o none

if ! az storage container show --name "${CONTAINER}" --account-name "${SA}" --auth-mode login -o none 2>/dev/null; then
  run_cmd az storage container create --name "${CONTAINER}" --account-name "${SA}" --auth-mode login -o none
  log_info "created container ${CONTAINER}"
fi

if ! az lock show --name tfstate-no-delete --resource-group "${RG}" -o none 2>/dev/null; then
  run_cmd az lock create --name tfstate-no-delete --resource-group "${RG}" --lock-type CanNotDelete \
    --notes "Terraform state - deleting this loses track of all infrastructure" -o none
fi

log_info "backend ready: storage_account_name=${SA} container_name=${CONTAINER}"
