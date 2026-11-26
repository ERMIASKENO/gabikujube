#!/usr/bin/env bash
# Maintains exactly one open "drift" issue per environment.
#   CODE=0 -> no drift: close any open issue
#   CODE=2 -> drift: open or update the issue with the plan
#   other  -> plan failed: fail the job (that's an outage of the pipeline itself)
# Usage: CODE=<plan exit code> ENV=<env> drift-issue.sh <plan-output-file>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_env CODE ENV GH_TOKEN
require_cmd gh

plan_file="${1:?plan output file required}"
title="Terraform drift detected: ${ENV}"
existing="$(gh issue list --state open --label drift --search "in:title \"${title}\"" --json number --jq '.[0].number // empty')"

case "${CODE}" in
  0)
    if [[ -n "${existing}" ]]; then
      gh issue close "${existing}" --comment "No drift on $(date -u +%F). Closing."
    fi
    log_info "${ENV}: no drift"
    ;;
  2)
    # shellcheck disable=SC2016  # backticks are literal markdown
    body="$(printf 'Nightly plan found differences between code and Azure.\n\n```\n%s\n```\n\nEither codify the change (import / update HCL) or re-apply to revert it.' \
      "$(grep -E '^\s*[#~+-]|Plan:' "${plan_file}" | head -c 60000)")"
    if [[ -n "${existing}" ]]; then
      gh issue comment "${existing}" --body "${body}"
    else
      gh issue create --title "${title}" --label drift --label "env:${ENV}" --body "${body}"
    fi
    log_warn "${ENV}: drift detected"
    ;;
  *)
    tail -n 50 "${plan_file}" >&2
    die "terraform plan failed for ${ENV}"
    ;;
esac
