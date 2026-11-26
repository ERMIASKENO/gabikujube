#!/usr/bin/env bash
# Shared helpers for every script in this repo. Source it, don't execute it.
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Conventions: set -euo pipefail in callers, logs go to stderr (stdout stays
# clean for data), JSON log lines when LOG_FORMAT=json (CI, journald, Loki).

[[ -n "${_SHOPSPHERE_COMMON:-}" ]] && return 0
_SHOPSPHERE_COMMON=1

LOG_FORMAT="${LOG_FORMAT:-text}"

_log() {
  local level="$1"; shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "${LOG_FORMAT}" == "json" ]]; then
    printf '{"ts":"%s","level":"%s","script":"%s","msg":"%s"}\n' \
      "${ts}" "${level}" "$(basename "$0")" "${*//\"/\\\"}" >&2
  else
    printf '%s [%-5s] %s\n' "${ts}" "${level}" "$*" >&2
  fi
}

log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

die() {
  log_error "$@"
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "required command not found: ${c}"
  done
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "required environment variable not set: ${v}"
  done
}

# retry <attempts> <delay-seconds> <command...>   (exponential backoff)
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then
      log_error "command failed after ${n} attempts: $*"
      return 1
    fi
    log_warn "attempt ${n}/${attempts} failed, retrying in ${delay}s: $*"
    sleep "${delay}"
    n=$(( n + 1 ))
    delay=$(( delay * 2 ))
  done
}

# Run a cleanup function on exit, even on error/CTRL-C
on_exit() {
  # shellcheck disable=SC2064  # expand now: the caller passes the final command
  trap "$1" EXIT INT TERM
}

# Simple exclusive lock so cron/systemd runs never overlap
with_lock() {
  local lockfile="$1"; shift
  exec 9>"${lockfile}"
  flock -n 9 || die "another instance holds ${lockfile}"
  "$@"
}

is_dry_run() { [[ "${DRY_RUN:-false}" == "true" ]]; }

# run_cmd <cmd...> - echo instead of executing when DRY_RUN=true
run_cmd() {
  if is_dry_run; then
    log_info "[dry-run] $*"
  else
    "$@"
  fi
}
