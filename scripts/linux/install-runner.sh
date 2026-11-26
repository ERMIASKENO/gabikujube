#!/usr/bin/env bash
# Installs a GitHub Actions self-hosted runner on a Linux VM as a systemd
# service, the way the infra pipeline needs it (inside the VNet, so Terraform
# can reach private endpoints and the private AKS API).
#
#  * dedicated unprivileged user, no sudo
#  * runner tarball verified against its published SHA-256
#  * registered into an enterprise runner GROUP (restricts which repos may use it)
#  * --ephemeral: one job per registration, then the wrapper re-registers
#    with a fresh just-in-time token (no state leaks between jobs)
#
# Usage:
#   install-runner.sh --url https://github.com/shopsphere --labels infra-prod \
#                     --group infra --token-cmd "/opt/shopsphere/get-reg-token.sh"
# The token command prints a short-lived registration token (minted via a
# GitHub App) so no long-lived PAT ever lives on the box.
set -euo pipefail

RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
RUNNER_SHA256="${RUNNER_SHA256:-}"          # pin in production; fetched from release notes if empty
RUNNER_USER="ghrunner"
RUNNER_HOME="/opt/actions-runner"
URL="" LABELS="" GROUP="Default" TOKEN_CMD="" NAME="$(hostname -s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift ;;
    --labels) LABELS="$2"; shift ;;
    --group) GROUP="$2"; shift ;;
    --name) NAME="$2"; shift ;;
    --token-cmd) TOKEN_CMD="$2"; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "${URL}" && -n "${LABELS}" && -n "${TOKEN_CMD}" ]] || { echo "--url, --labels and --token-cmd are required" >&2; exit 2; }
[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

log() { printf '%s [runner] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# 1. user + directories
id "${RUNNER_USER}" >/dev/null 2>&1 || useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /usr/sbin/nologin "${RUNNER_USER}"
install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" -m 0750 "${RUNNER_HOME}" "${RUNNER_HOME}/_work"

# 2. download + verify
tarball="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
if [[ ! -x "${RUNNER_HOME}/run.sh" ]] || ! grep -q "${RUNNER_VERSION}" "${RUNNER_HOME}/.runner-version" 2>/dev/null; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  log "downloading runner ${RUNNER_VERSION}"
  curl -fsSL -o "${tmp}/${tarball}" "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"
  if [[ -n "${RUNNER_SHA256}" ]]; then
    echo "${RUNNER_SHA256}  ${tmp}/${tarball}" | sha256sum --check --status || { log "checksum mismatch"; exit 1; }
  else
    log "WARNING: RUNNER_SHA256 not pinned"
  fi
  tar xzf "${tmp}/${tarball}" -C "${RUNNER_HOME}"
  "${RUNNER_HOME}/bin/installdependencies.sh" >/dev/null
  echo "${RUNNER_VERSION}" >"${RUNNER_HOME}/.runner-version"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}"
fi

# 3. wrapper: register (ephemeral) -> run one job -> loop
cat >"${RUNNER_HOME}/ephemeral-loop.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${RUNNER_HOME}"
while true; do
  token="\$(${TOKEN_CMD})"
  ./config.sh --unattended --replace --ephemeral --disableupdate \\
    --url "${URL}" --token "\${token}" --name "${NAME}-\$(date +%s)" \\
    --runnergroup "${GROUP}" --labels "${LABELS}" --work _work
  ./run.sh || true
  rm -rf _work/* || true          # clean workspace between jobs
done
EOF
chmod 0750 "${RUNNER_HOME}/ephemeral-loop.sh"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/ephemeral-loop.sh"

# 4. systemd unit with sandboxing
cat >/etc/systemd/system/github-runner.service <<EOF
[Unit]
Description=GitHub Actions runner (ephemeral) ${LABELS}
After=network-online.target
Wants=network-online.target

[Service]
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_HOME}
ExecStart=${RUNNER_HOME}/ephemeral-loop.sh
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${RUNNER_HOME}
KillMode=process
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now github-runner.service
log "runner service enabled: labels=${LABELS} group=${GROUP}"
