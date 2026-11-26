#!/usr/bin/env bats

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${BATS_TEST_TMPDIR}"
}

@test "promotion-plan reads CI digest artifacts" {
  mkdir -p digests
  echo '{"service":"cart","digest":"sha256:'"$(printf 'a%.0s' {1..64})"'","tag":"abc1234"}' > digests/cart.json
  TARGET=dev SOURCE=ci-artifacts run "${ROOT}/scripts/ci/promotion-plan.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'items=[{"service":"cart"'* ]]
}

@test "promotion-plan rejects malformed digests" {
  mkdir -p digests
  echo '{"service":"cart","digest":"latest","tag":"x"}' > digests/cart.json
  TARGET=dev SOURCE=ci-artifacts run "${ROOT}/scripts/ci/promotion-plan.sh"
  [ "${status}" -ne 0 ]
}

@test "promotion-plan from git skips services already at the same digest" {
  # dev and staging values ship with identical placeholder digests
  TARGET=staging SOURCE=git SERVICES=cart run "${ROOT}/scripts/ci/promotion-plan.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"items=[]"* ]]
}

@test "health-check writes valid prometheus textfile atomically" {
  run "${ROOT}/scripts/linux/health-check.sh" --textfile "${BATS_TEST_TMPDIR}/out/health.prom"
  [ -f "${BATS_TEST_TMPDIR}/out/health.prom" ]
  grep -qE '^shopsphere_host_health_status [012]$' "${BATS_TEST_TMPDIR}/out/health.prom"
  grep -qE '^shopsphere_host_memory_used_percent [0-9]+$' "${BATS_TEST_TMPDIR}/out/health.prom"
  # no temp files left behind
  [ "$(find "${BATS_TEST_TMPDIR}/out" -name 'health.prom.*' | wc -l)" -eq 0 ]
}
