#!/usr/bin/env bash
# Host health check. Two output modes:
#   default            human-readable report, exit 0 OK / 1 WARN / 2 CRIT
#   --textfile <path>  Prometheus textfile-collector format for node_exporter
#                      (written atomically), so Grafana alerts on hosts the
#                      same way it alerts on pods
#
# Thresholds via env: DISK_WARN=80 DISK_CRIT=90 MEM_WARN=85 LOAD_PER_CPU_WARN=2
set -euo pipefail

DISK_WARN="${DISK_WARN:-80}"
DISK_CRIT="${DISK_CRIT:-90}"
MEM_WARN="${MEM_WARN:-85}"
LOAD_PER_CPU_WARN="${LOAD_PER_CPU_WARN:-2}"
TEXTFILE=""
[[ "${1:-}" == "--textfile" ]] && TEXTFILE="${2:?path required}"

status=0       # 0 ok, 1 warn, 2 crit
metrics=()
report=()

raise() { (( $1 > status )) && status=$1; return 0; }

# --- disk usage per real filesystem
while read -r mount pct; do
  pct="${pct%\%}"
  metrics+=("shopsphere_host_disk_used_percent{mount=\"${mount}\"} ${pct}")
  if (( pct >= DISK_CRIT )); then report+=("CRIT disk ${mount} ${pct}%"); raise 2
  elif (( pct >= DISK_WARN )); then report+=("WARN disk ${mount} ${pct}%"); raise 1
  fi
done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs | awk 'NR>1 {print $6, $5}')

# --- memory (MemAvailable accounts for reclaimable cache)
read -r mem_total mem_avail < <(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {print t, a}' /proc/meminfo)
mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
metrics+=("shopsphere_host_memory_used_percent ${mem_used_pct}")
(( mem_used_pct >= MEM_WARN )) && { report+=("WARN memory ${mem_used_pct}%"); raise 1; }

# --- load relative to CPU count
cpus="$(nproc)"
load1="$(cut -d' ' -f1 /proc/loadavg)"
metrics+=("shopsphere_host_load1_per_cpu $(awk -v l="${load1}" -v c="${cpus}" 'BEGIN {printf "%.2f", l/c}')")
if awk -v l="${load1}" -v c="${cpus}" -v w="${LOAD_PER_CPU_WARN}" 'BEGIN {exit !(l/c > w)}'; then
  report+=("WARN load ${load1} on ${cpus} cpus"); raise 1
fi

# --- failed systemd units
failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' || true)"
failed_count="$(grep -c . <<<"${failed}" || true)"
metrics+=("shopsphere_host_failed_units ${failed_count}")
(( failed_count > 0 )) && { report+=("CRIT failed units: ${failed//$'\n'/ }"); raise 2; }

# --- clock sync (TLS, tokens and logs all depend on it)
synced=0
timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes && synced=1
metrics+=("shopsphere_host_time_synced ${synced}")
(( synced == 0 )) && { report+=("WARN clock not NTP-synchronized"); raise 1; }

# --- pending reboot after kernel/security updates
reboot_required=0
[[ -f /var/run/reboot-required ]] && reboot_required=1
metrics+=("shopsphere_host_reboot_required ${reboot_required}")

metrics+=("shopsphere_host_health_status ${status}")

if [[ -n "${TEXTFILE}" ]]; then
  mkdir -p "$(dirname "${TEXTFILE}")"
  tmp="$(mktemp "${TEXTFILE}.XXXX")"
  {
    echo "# HELP shopsphere_host_health_status 0=ok 1=warn 2=crit"
    echo "# TYPE shopsphere_host_health_status gauge"
    printf '%s\n' "${metrics[@]}"
  } >"${tmp}"
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${TEXTFILE}"     # atomic: node_exporter never reads a half-written file
else
  if (( ${#report[@]} == 0 )); then echo "OK"; else printf '%s\n' "${report[@]}"; fi
fi
exit "${status}"
