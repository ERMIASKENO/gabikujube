#!/usr/bin/env bash
# Hands a freshly created AKS cluster over to GitOps. After this script the
# cluster is managed exclusively from Git:
#   1. Entra ID kubeconfig (no local admin account exists)
#   2. install Argo CD with our values (the only Helm install done by hand)
#   3. apply the root app-of-apps for this environment
#   4. wait until every Application is Synced + Healthy
#
# Usage: bootstrap-cluster.sh --env dev --resource-group rg-shopsphere-dev --cluster aks-shopsphere-dev
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd az kubectl kubelogin helm jq

ENV_NAME="" RG="" CLUSTER=""
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.20.0}"
TIMEOUT_MIN="${TIMEOUT_MIN:-30}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift ;;
    --resource-group) RG="$2"; shift ;;
    --cluster) CLUSTER="$2"; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ "${ENV_NAME}" =~ ^(dev|staging|prod)$ && -n "${RG}" && -n "${CLUSTER}" ]] || die "usage: --env dev|staging|prod --resource-group RG --cluster NAME"

log_info "fetching Entra ID kubeconfig for ${CLUSTER}"
az aks get-credentials --resource-group "${RG}" --name "${CLUSTER}" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli        # non-interactive: reuse the az login session

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

log_info "installing Argo CD chart ${ARGOCD_CHART_VERSION}"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${ROOT}/gitops/bootstrap/argocd-values.yaml" \
  --wait --timeout 10m

log_info "applying root app-of-apps for ${ENV_NAME}"
kubectl apply -f "${ROOT}/gitops/bootstrap/root-${ENV_NAME}.yaml"

deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while true; do
  apps="$(kubectl get applications.argoproj.io -n argocd -o json)"
  total="$(jq '.items | length' <<<"${apps}")"
  ready="$(jq '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length' <<<"${apps}")"
  log_info "applications healthy: ${ready}/${total}"
  if (( total > 1 && ready == total )); then
    break
  fi
  if (( $(date +%s) > deadline )); then
    jq -r '.items[] | select(.status.health.status!="Healthy") | "\(.metadata.name): \(.status.sync.status)/\(.status.health.status) \(.status.health.message // "")"' <<<"${apps}" >&2
    die "timed out waiting for applications"
  fi
  sleep 20
done
log_info "cluster ${CLUSTER} is fully reconciled from Git"
