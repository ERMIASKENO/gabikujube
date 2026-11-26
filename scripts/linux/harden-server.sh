#!/usr/bin/env bash
# Idempotent baseline hardening for Ubuntu 22.04/24.04 servers (ops VM,
# self-hosted runners, any legacy VM we still own).
#
# Replaces the old wiki page "how to set up a new VM" (45 manual steps,
# never done the same way twice). Runs from cloud-init on first boot and can
# be re-run any time; every step checks state before changing it.
#
# Usage: sudo ./harden-server.sh [--check] [--ssh-allow-cidr 10.0.0.0/8]
#   --check   report what would change, change nothing (exit 1 if non-compliant)
set -euo pipefail

SSH_ALLOW_CIDR="10.0.0.0/8"
CHECK_ONLY=false
CHANGES=0

usage() { sed -n '2,13p' "$0"; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true ;;
    --ssh-allow-cidr) SSH_ALLOW_CIDR="${2:?}"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done

log() { printf '%s [harden] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

[[ ${EUID} -eq 0 ]] || { log "must run as root"; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || { log "unsupported OS: ${ID}"; exit 1; }

# ensure_file <path> <mode> <content>: write only if content differs
ensure_file() {
  local path="$1" mode="$2" content="$3"
  if [[ -f "${path}" ]] && [[ "$(cat "${path}")" == "${content}" ]]; then
    return 0
  fi
  CHANGES=$((CHANGES + 1))
  if ${CHECK_ONLY}; then
    log "would update ${path}"
    return 0
  fi
  install -m "${mode}" -o root -g root /dev/null "${path}"
  printf '%s\n' "${content}" >"${path}"
  log "updated ${path}"
  return 1   # signal "changed" so callers can reload services
}

ensure_pkg() {
  local missing=()
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "install ok installed" || missing+=("${p}")
  done
  (( ${#missing[@]} == 0 )) && return 0
  CHANGES=$((CHANGES + 1))
  if ${CHECK_ONLY}; then log "would install: ${missing[*]}"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  log "installed: ${missing[*]}"
}

# 1. packages ------------------------------------------------------------------
${CHECK_ONLY} || apt-get update -qq
ensure_pkg ufw fail2ban auditd unattended-upgrades chrony apparmor-utils

# 2. SSH: keys/Entra only, no root, no forwarding ------------------------------
if ! ensure_file /etc/ssh/sshd_config.d/10-hardening.conf 0644 "# managed by harden-server.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no
PermitEmptyPasswords no"; then
  sshd -t && systemctl reload ssh
fi

# 3. firewall: deny inbound except SSH from inside the VNet --------------------
if ${CHECK_ONLY}; then
  ufw status | grep -q "Status: active" || { log "would enable ufw"; CHANGES=$((CHANGES + 1)); }
else
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow from "${SSH_ALLOW_CIDR}" to any port 22 proto tcp comment "ssh from vnet" >/dev/null
  ufw allow from "${SSH_ALLOW_CIDR}" to any port 9100 proto tcp comment "node_exporter" >/dev/null
  ufw --force enable >/dev/null
fi

# 4. brute-force protection -----------------------------------------------------
if ! ensure_file /etc/fail2ban/jail.d/sshd.local 0644 "[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h"; then
  systemctl restart fail2ban
fi

# 5. automatic security patches (reboots inside a maintenance window) ---------
# shellcheck disable=SC2016  # ${distro_id} is expanded by apt, not bash
ensure_file /etc/apt/apt.conf.d/52shopsphere-unattended 0644 'Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";' || true
ensure_file /etc/apt/apt.conf.d/20auto-upgrades 0644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' || true

# 6. kernel / network hardening -------------------------------------------------
if ! ensure_file /etc/sysctl.d/90-shopsphere.conf 0644 "net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0"; then
  sysctl --system >/dev/null
fi

# 7. audit trail for identity / privilege changes -------------------------------
if ! ensure_file /etc/audit/rules.d/50-shopsphere.rules 0640 "-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k privilege
-w /etc/sudoers.d/ -p wa -k privilege
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root-commands"; then
  augenrules --load >/dev/null
fi

# 8. bounded, persistent logs ---------------------------------------------------
if ! ensure_file /etc/systemd/journald.conf.d/90-shopsphere.conf 0644 "[Journal]
Storage=persistent
SystemMaxUse=1G
MaxRetentionSec=30day
Compress=yes"; then
  systemctl restart systemd-journald
fi

# 9. services that should never run on a server ---------------------------------
for svc in avahi-daemon cups bluetooth; do
  if systemctl is-enabled "${svc}" >/dev/null 2>&1; then
    CHANGES=$((CHANGES + 1))
    ${CHECK_ONLY} && { log "would disable ${svc}"; continue; }
    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
    log "disabled ${svc}"
  fi
done

${CHECK_ONLY} || systemctl enable --now auditd chrony fail2ban >/dev/null

if ${CHECK_ONLY}; then
  log "check complete: ${CHANGES} item(s) non-compliant"
  (( CHANGES == 0 ))
else
  log "hardening complete (${CHANGES} change(s) applied)"
fi
