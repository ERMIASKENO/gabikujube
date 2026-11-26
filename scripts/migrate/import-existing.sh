#!/usr/bin/env bash
# "ClickOps -> code" helper. Exports manually created Azure resources in a
# resource group into Terraform (HCL + import blocks) without touching them,
# then proves the result with a plan that must show 0 add / 0 change / 0 destroy.
# Playbook: infra/terraform/examples/import-clickops/README.md
#
# Usage: import-existing.sh --resource-group rg-legacy-shop --out ./generated [--exclude-type Microsoft.Insights/components]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd az aztfexport terraform jq

RG="" OUT="./generated" EXCLUDES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RG="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --exclude-type) EXCLUDES+=("$2"); shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ -n "${RG}" ]] || die "--resource-group is required"

log_info "inventory of ${RG}"
az resource list -g "${RG}" --query '[].{type:type, name:name}' -o table >&2

# Build an ARG-style filter so noisy / unsupported types can be skipped
query="resourceGroup =~ '${RG}'"
for t in "${EXCLUDES[@]}"; do
  query+=" and type !~ '${t}'"
done

mkdir -p "${OUT}"
log_info "exporting with aztfexport (HCL + import blocks only, no state written)"
aztfexport query --non-interactive --hcl-only --generate-import-block \
  --output-dir "${OUT}" "${query}"

log_info "verifying the generated configuration against reality"
terraform -chdir="${OUT}" init -input=false >/dev/null
set +e
terraform -chdir="${OUT}" plan -input=false -no-color -detailed-exitcode > "${OUT}/verify-plan.txt"
code=$?
set -e

summary="$(grep -E '^Plan:' "${OUT}/verify-plan.txt" || echo 'No changes.')"
log_info "plan: ${summary}"
if grep -qE '[1-9][0-9]* to (add|change|destroy)' <<<"${summary}"; then
  log_warn "generated code does not match reality yet - fix the HCL (not the resource) until only imports remain"
  exit 2
fi
(( code == 1 )) && die "terraform plan failed; see ${OUT}/verify-plan.txt"
log_info "clean import: move resources from ${OUT} into modules, use moved{} blocks when renaming"
