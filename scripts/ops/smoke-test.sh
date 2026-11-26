#!/usr/bin/env bash
# End-to-end smoke test through the real edge (Front Door -> Istio -> services).
# Used by post-deploy.yml and by humans after an incident.
#
# Usage: smoke-test.sh --base-url https://shop.example.com [--timeout 10]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd curl jq

BASE="" TIMEOUT=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE="${2%/}"; shift ;;
    --timeout) TIMEOUT="$2"; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ -n "${BASE}" ]] || die "--base-url is required"

failures=0
user="smoke-$(date +%s)-$RANDOM"

http() { # method path [json-body]
  curl -fsS --max-time "${TIMEOUT}" -X "$1" -H 'content-type: application/json' \
       ${3:+--data "$3"} "${BASE}$2"
}

check() { # name command...
  local name="$1"; shift
  if retry 3 2 "$@" >/dev/null; then
    log_info "PASS ${name}"
  else
    log_error "FAIL ${name}"
    failures=$((failures + 1))
  fi
}

products_not_empty() { http GET /api/products | jq -e 'length > 0'; }
cart_round_trip() {
  http POST "/api/cart/${user}/items" '{"productId":"sku-1001","quantity":1}' >/dev/null
  http GET "/api/cart/${user}" | jq -e '.items[0].productId == "sku-1001"'
}
recommendations() { http GET "/api/recommendations?productId=sku-1001" | jq -e '.recommendations | length > 0'; }
orders_require_auth() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" -X POST "${BASE}/api/orders")"
  [[ "${code}" == "403" || "${code}" == "401" ]]
}

check "frontend /healthz"            http GET /healthz
check "catalog returns products"     products_not_empty
check "cart add + read"              cart_round_trip
check "recommendations"              recommendations
check "jwks published"               http GET /.well-known/jwks.json
check "orders rejected without JWT"  orders_require_auth

http DELETE "/api/cart/${user}" >/dev/null 2>&1 || true

if (( failures > 0 )); then
  die "${failures} smoke check(s) failed against ${BASE}"
fi
log_info "all smoke checks passed against ${BASE}"
