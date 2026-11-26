#!/usr/bin/env bats
# Unit tests for shell scripts (run in CI by the lint job: `bats scripts/tests`)

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../lib/common.sh
  source "${ROOT}/scripts/lib/common.sh"
}

@test "retry succeeds once the command starts passing" {
  counter_file="$(mktemp)"
  echo 0 >"${counter_file}"
  flaky() { local n; n=$(( $(cat "${counter_file}") + 1 )); echo "${n}" >"${counter_file}"; (( n >= 3 )); }
  run retry 5 0 flaky
  [ "${status}" -eq 0 ]
  [ "$(cat "${counter_file}")" -eq 3 ]
}

@test "retry gives up after N attempts" {
  run retry 2 0 false
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"failed after 2 attempts"* ]]
}

@test "require_env fails with a clear message" {
  unset SOME_MISSING_VAR
  run require_env SOME_MISSING_VAR
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"SOME_MISSING_VAR"* ]]
}

@test "run_cmd only echoes in dry-run mode" {
  DRY_RUN=true run run_cmd touch "${BATS_TEST_TMPDIR}/should-not-exist"
  [ "${status}" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/should-not-exist" ]
}

@test "json logging escapes quotes" {
  LOG_FORMAT=json run log_info 'say "hi"'
  [[ "${output}" == *'"msg":"say \"hi\""'* ]]
}
