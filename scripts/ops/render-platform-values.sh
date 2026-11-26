#!/usr/bin/env bash
# Feeds Terraform outputs into the GitOps layer, replacing the manual step of
# copying client IDs / hostnames from the portal into YAML.
#   terraform output -json  ->  gitops/envs/<env>/apps/*.yaml + platform/*.yaml
# Only non-secret identifiers are written; secrets stay in Key Vault.
#
# Usage: render-platform-values.sh --env prod [--tf-dir infra/terraform/stacks/platform]
#        (or pipe JSON: terraform output -json | render-platform-values.sh --env prod --stdin)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd jq yq

ENV_NAME="" TF_DIR="${ROOT}/infra/terraform/stacks/platform" FROM_STDIN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift ;;
    --tf-dir) TF_DIR="$2"; shift ;;
    --stdin) FROM_STDIN=true ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ "${ENV_NAME}" =~ ^(dev|staging|prod)$ ]] || die "--env dev|staging|prod required"

if ${FROM_STDIN}; then
  out="$(cat)"
else
  require_cmd terraform
  out="$(terraform -chdir="${TF_DIR}" output -json)"
fi

val() { jq -er "$1" <<<"${out}"; }
envdir="${ROOT}/gitops/envs/${ENV_NAME}"

acr="$(val '.acr_login_server.value')"
sb="$(val '.servicebus_fqdn.value')"
redis="$(val '.redis_host.value')"

for f in "${envdir}"/apps/*.yaml; do
  svc="$(basename "${f}" .yaml)"
  REPO="${acr}/shopsphere/${svc}" yq -i '.image.repository = strenv(REPO)' "${f}"
done

ORDER_ID="$(val '.workload_client_ids.value.order')" SB="${sb}" \
  yq -i '.serviceAccount.workloadIdentityClientId = strenv(ORDER_ID) | .env.SERVICEBUS_FQDN = strenv(SB)' "${envdir}/apps/order.yaml"

NOTIF_ID="$(val '.workload_client_ids.value.notification')" KEDA_ID="$(val '.workload_client_ids.value.keda')" \
SB="${sb}" SBNS="${sb%%.*}" \
  yq -i '.serviceAccount.workloadIdentityClientId = strenv(NOTIF_ID)
         | .env.SERVICEBUS_FQDN = strenv(SB)
         | .autoscaling.keda.serviceBus.namespace = strenv(SBNS)
         | .autoscaling.keda.serviceBus.identityClientId = strenv(KEDA_ID)' "${envdir}/apps/notification.yaml"

URL="rediss://${redis}:10000" yq -i '.env.REDIS_URL = strenv(URL)' "${envdir}/apps/cart.yaml"

ESO_ID="$(val '.workload_client_ids.value["external-secrets"]')" \
  yq -i '.serviceAccount.annotations["azure.workload.identity/client-id"] = strenv(ESO_ID)' "${envdir}/platform/external-secrets.yaml"

if CM_ID="$(jq -er '.workload_client_ids.value["cert-manager"]' <<<"${out}")"; then
  CM_ID="${CM_ID}" yq -i '.serviceAccount.annotations["azure.workload.identity/client-id"] = strenv(CM_ID)' "${envdir}/platform/cert-manager.yaml"
fi

log_info "updated ${envdir}; review with: git diff -- gitops/envs/${ENV_NAME}"
