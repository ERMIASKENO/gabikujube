#!/usr/bin/env bash
# Prints `items=<json>` for GITHUB_OUTPUT: [{service, tag, digest}, ...]
#
#   SOURCE=ci-artifacts : read ./digests/*.json written by _build-service.yml
#   SOURCE=git          : read the previous environment's gitops values
#                         (staging <- dev, prod <- staging)
# Env: TARGET (dev|staging|prod), SERVICES ("all" or comma list), SOURCE
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_env TARGET SOURCE
require_cmd jq yq
SERVICES="${SERVICES:-all}"

previous_env() {
  case "$1" in
    staging) echo dev ;;
    prod) echo staging ;;
    *) die "no previous environment for $1" ;;
  esac
}

wanted() {
  [[ "${SERVICES}" == "all" ]] && return 0
  [[ ",${SERVICES// /}," == *",$1,"* ]]
}

items="[]"
if [[ "${SOURCE}" == "ci-artifacts" ]]; then
  shopt -s nullglob
  files=(digests/*.json)
  (( ${#files[@]} > 0 )) && items="$(jq -cs '.' "${files[@]}")"
else
  from="$(previous_env "${TARGET}")"
  for f in "${ROOT}/gitops/envs/${from}/apps/"*.yaml; do
    svc="$(basename "${f}" .yaml)"
    wanted "${svc}" || continue
    src_digest="$(yq '.image.digest' "${f}")"
    dst_digest="$(yq '.image.digest' "${ROOT}/gitops/envs/${TARGET}/apps/${svc}.yaml")"
    if [[ "${src_digest}" == "${dst_digest}" ]]; then
      log_info "${svc}: already at ${src_digest:0:19} in ${TARGET}, skipping"
      continue
    fi
    items="$(jq -c --arg s "${svc}" --arg d "${src_digest}" --arg t "$(yq '.image.tag' "${f}")" \
      '. + [{service:$s, digest:$d, tag:$t}]' <<<"${items}")"
  done
fi

# validate before anything downstream trusts it
jq -e 'all(.[]; (.digest | test("^sha256:[a-f0-9]{64}$")) and (.service | test("^[a-z0-9-]+$")))' <<<"${items}" >/dev/null \
  || die "invalid promotion items: ${items}"

log_info "promotion plan for ${TARGET}: ${items}"
echo "items=${items}"
