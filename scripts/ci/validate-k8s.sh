#!/usr/bin/env bash
# Validates everything Argo CD would apply, without a cluster:
#   1. helm lint the golden-path chart
#   2. helm template every service x environment (exact Argo CD value layering)
#   3. kustomize build every cluster-config overlay and Argo CD cluster dir
#   4. kubeconform all of it against K8s + CRD schemas (Rollouts, Istio, ...)
#   5. fail if generated Argo CD files are stale vs components.yaml
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd helm kustomize kubeconform yq

CHART="${ROOT}/deploy/charts/microservice"
OUT="$(mktemp -d)"
on_exit "rm -rf '${OUT}'"
K8S_VERSION="${K8S_VERSION:-1.36.0}"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

log_info "helm lint"
helm lint "${CHART}" --strict -f "${ROOT}/gitops/apps/cart/values.yaml" -f "${ROOT}/gitops/envs/dev/apps/cart.yaml"

for env in dev staging prod; do
  for dir in "${ROOT}"/gitops/apps/*/; do
    svc="$(basename "${dir}")"
    helm template "${svc}" "${CHART}" --namespace shop \
      -f "${dir}/values.yaml" \
      -f "${ROOT}/gitops/envs/${env}/values.yaml" \
      -f "${ROOT}/gitops/envs/${env}/apps/${svc}.yaml" \
      >"${OUT}/app-${env}-${svc}.yaml"
  done
  kustomize build "${ROOT}/gitops/cluster-config/overlays/${env}" >"${OUT}/cluster-config-${env}.yaml"
  kustomize build "${ROOT}/gitops/clusters/${env}" >"${OUT}/argocd-${env}.yaml"
done
log_info "rendered $(find "${OUT}" -name '*.yaml' | wc -l) files"

kubeconform -strict -summary -output pretty \
  -kubernetes-version "${K8S_VERSION}" \
  -schema-location default -schema-location "${CRD_SCHEMAS}" \
  "${OUT}"/*.yaml

log_info "checking generated Argo CD manifests are up to date"
"${ROOT}/scripts/ops/render-cluster-apps.sh" >/dev/null 2>&1
if ! git -C "${ROOT}" diff --quiet -- gitops/clusters gitops/bootstrap; then
  git -C "${ROOT}" --no-pager diff --stat -- gitops/clusters gitops/bootstrap
  die "gitops/clusters is stale: run scripts/ops/render-cluster-apps.sh and commit"
fi
log_info "all manifests valid"
