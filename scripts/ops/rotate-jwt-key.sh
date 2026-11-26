#!/usr/bin/env bash
# Rotates the RS256 signing key used by the user service.
#   new JWK -> Key Vault secret "user-jwt-signing-key"
#   External Secrets syncs it (refreshInterval) -> Reloader restarts user pods
#   gateway picks up the new public key from /.well-known/jwks.json
# Tokens are short-lived (15 min), so the old key needs no grace period
# beyond one token lifetime.
#
# Usage: rotate-jwt-key.sh --vault kv-shopsphereprod
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
require_cmd az node

VAULT=""
[[ "${1:-}" == "--vault" ]] && VAULT="${2:-}"
[[ -n "${VAULT}" ]] || die "--vault is required"

kid="$(date -u +%Y%m%d%H%M%S)"
# generate in memory, never written to disk
jwk="$(KID="${kid}" node -e '
  const { generateKeyPairSync } = require("node:crypto");
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = privateKey.export({ format: "jwk" });
  process.stdout.write(JSON.stringify({ ...jwk, kid: process.env.KID, alg: "RS256", use: "sig" }));
')"

if is_dry_run; then
  log_info "[dry-run] would store new key kid=${kid} in ${VAULT}"
  exit 0
fi

az keyvault secret set --vault-name "${VAULT}" --name user-jwt-signing-key \
  --value "${jwk}" --content-type application/jwk+json --tags "kid=${kid}" -o none
log_info "stored new signing key kid=${kid}; ESO + Reloader will roll the user service"
