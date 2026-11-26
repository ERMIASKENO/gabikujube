#!/usr/bin/env bash
# Front Door Premium connects to the AKS internal LB through a Private Link
# Service. Each new Front Door origin creates a *pending* private endpoint
# connection that must be approved on the PLS side. This automates the
# approval (previously a portal click after every Front Door change).
#
# Usage: approve-frontdoor-pls.sh --node-resource-group rg-shopsphere-prod-nodes [--pls pls-istio-ingress]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd az jq

NODE_RG="" PLS="pls-istio-ingress"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-resource-group) NODE_RG="$2"; shift ;;
    --pls) PLS="$2"; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ -n "${NODE_RG}" ]] || die "--node-resource-group is required"

pls_id="$(retry 10 15 az network private-link-service show -g "${NODE_RG}" -n "${PLS}" --query id -o tsv)"
pending="$(az network private-endpoint-connection list --id "${pls_id}" -o json |
  jq -r '.[] | select(.properties.privateLinkServiceConnectionState.status=="Pending")
              | select(.properties.privateLinkServiceConnectionState.description | test("Front Door"; "i"))
              | .id')"

if [[ -z "${pending}" ]]; then
  log_info "no pending Front Door connections on ${PLS}"
  exit 0
fi

while read -r conn; do
  run_cmd az network private-endpoint-connection approve --id "${conn}" \
    --description "Approved by approve-frontdoor-pls.sh" -o none
  log_info "approved ${conn##*/}"
done <<<"${pending}"
