#!/usr/bin/env bash
# Logical backup of an Azure PostgreSQL Flexible Server database to Blob
# Storage, on top of the platform's automatic PITR backups. Used for
# long-term retention (compliance) and for restores into other environments.
#
#  * auth: managed identity of the ops VM -> Entra token for PostgreSQL and
#          Storage (no passwords, no storage keys)
#  * pg_dump custom format, verified with pg_restore --list before upload
#  * retention enforced by deleting blobs older than RETENTION_DAYS
#  * flock prevents overlapping runs from the systemd timer
#
# Usage: backup-postgres.sh --server psql-shopsphere-prod --db inventory \
#          --user id-ops-shopsphere-prod --account stshopspherebackups --container pg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

SERVER="" DB="" PGUSER_NAME="" ACCOUNT="" CONTAINER="pg-backups"
RETENTION_DAYS="${RETENTION_DAYS:-35}"
WORKDIR="${WORKDIR:-/var/tmp/pg-backup}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="$2"; shift ;;
    --db) DB="$2"; shift ;;
    --user) PGUSER_NAME="$2"; shift ;;
    --account) ACCOUNT="$2"; shift ;;
    --container) CONTAINER="$2"; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[[ -n "${SERVER}" && -n "${DB}" && -n "${PGUSER_NAME}" && -n "${ACCOUNT}" ]] || die "missing required arguments"
require_cmd az pg_dump pg_restore jq flock

main() {
  mkdir -p "${WORKDIR}"
  local stamp file blob
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  file="${WORKDIR}/${DB}-${stamp}.dump"
  blob="${SERVER}/${DB}/${DB}-${stamp}.dump"
  on_exit "rm -f '${file}'"

  log_info "login with managed identity"
  retry 3 5 az login --identity --allow-no-subscriptions >/dev/null

  log_info "dumping ${DB} from ${SERVER}"
  PGPASSWORD="$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)" \
  PGSSLMODE=require \
    pg_dump --host "${SERVER}.postgres.database.azure.com" --username "${PGUSER_NAME}" \
            --dbname "${DB}" --format custom --compress 6 --no-owner --file "${file}"

  pg_restore --list "${file}" >/dev/null || die "dump verification failed"
  log_info "dump verified ($(du -h "${file}" | cut -f1))"

  retry 3 5 az storage blob upload --auth-mode login --account-name "${ACCOUNT}" \
    --container-name "${CONTAINER}" --name "${blob}" --file "${file}" --tier Cool --only-show-errors >/dev/null
  log_info "uploaded ${blob}"

  local cutoff
  cutoff="$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
  az storage blob list --auth-mode login --account-name "${ACCOUNT}" --container-name "${CONTAINER}" \
      --prefix "${SERVER}/${DB}/" --query "[?properties.creationTime<'${cutoff}'].name" -o tsv |
    while read -r old; do
      [[ -z "${old}" ]] && continue
      run_cmd az storage blob delete --auth-mode login --account-name "${ACCOUNT}" \
        --container-name "${CONTAINER}" --name "${old}" --only-show-errors
      log_info "expired ${old}"
    done
}

with_lock "/run/lock/pg-backup-${DB}.lock" main
