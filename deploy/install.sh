#!/usr/bin/env bash
# Ferry installer / upgrader for Ubuntu Server 24.04.
# Run from an extracted release package: sudo ./deploy/install.sh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this script with sudo: sudo ./deploy/install.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BINARY_SOURCE="${PACKAGE_ROOT}/ferry"
ENV_FILE="/etc/ferry/ferry.env"
UNIT_FILE="/etc/systemd/system/ferry.service"

if [[ ! -f "${BINARY_SOURCE}" ]]; then
  echo "ERROR: ferry binary not found at ${BINARY_SOURCE}" >&2
  echo "Extract the whole release archive and run deploy/install.sh from it." >&2
  exit 1
fi
for required in \
  "${SCRIPT_DIR}/ferry.service" \
  "${SCRIPT_DIR}/ferry.env.example" \
  "${SCRIPT_DIR}/Caddyfile.example" \
  "${PACKAGE_ROOT}/README.md"; do
  if [[ ! -f "${required}" ]]; then
    echo "ERROR: package is incomplete, missing ${required}" >&2
    exit 1
  fi
done

# System user and directories. Safe to repeat on upgrade.
if ! getent group ferry >/dev/null 2>&1; then
  groupadd --system ferry
fi
if ! id -u ferry >/dev/null 2>&1; then
  useradd --system --gid ferry --home-dir /var/lib/ferry --shell /usr/sbin/nologin ferry
fi
install -d -o ferry -g ferry -m 0750 /var/lib/ferry
install -d -o root -g ferry -m 0750 /etc/ferry

# Install the binary atomically so an interrupted copy cannot leave a partial
# executable in place.
install -m 0755 -o root -g root "${BINARY_SOURCE}" /usr/local/bin/ferry.new
mv -f /usr/local/bin/ferry.new /usr/local/bin/ferry

# First install only: create the environment file, never overwrite it.
FIRST_INSTALL=0
if [[ ! -f "${ENV_FILE}" ]]; then
  FIRST_INSTALL=1
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to generate FERRY_SECRET_KEY." >&2
    echo "Install it with: sudo apt-get install -y openssl" >&2
    exit 1
  fi
  install -m 0640 -o root -g ferry "${SCRIPT_DIR}/ferry.env.example" "${ENV_FILE}"
  SECRET="$(openssl rand -hex 32)"
  sed -i "s|^FERRY_SECRET_KEY=.*|FERRY_SECRET_KEY=${SECRET}|" "${ENV_FILE}"
fi
chown root:ferry "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

# Install/refresh the systemd unit.
install -m 0644 -o root -g root "${SCRIPT_DIR}/ferry.service" "${UNIT_FILE}"
systemctl daemon-reload
systemctl enable ferry >/dev/null

# Check whether the required values have been filled in.
PROBLEMS=()
if grep -q '^FERRY_USERNAME=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("FERRY_USERNAME")
fi
if grep -q '^DOCKERHUB_USERNAME=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("DOCKERHUB_USERNAME")
fi
if grep -q '^DOCKERHUB_TOKEN=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("DOCKERHUB_TOKEN")
fi
if grep -q '^FERRY_SECRET_KEY=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("FERRY_SECRET_KEY")
fi
PASSWORD_OK=0
if grep -Eq '^FERRY_PASSWORD_HASH=\$2[aby]\$' "${ENV_FILE}"; then
  PASSWORD_OK=1
elif ! grep -q '^FERRY_PASSWORD=CHANGE_ME$' "${ENV_FILE}" && \
     ! grep -q '^FERRY_PASSWORD=$' "${ENV_FILE}"; then
  PASSWORD_OK=1
fi
if [[ "${PASSWORD_OK}" -eq 0 ]]; then
  PROBLEMS+=("FERRY_PASSWORD (or FERRY_PASSWORD_HASH)")
fi

if [[ "${#PROBLEMS[@]}" -gt 0 ]]; then
  echo
  echo "======================================================================"
  echo " Ferry is installed, but it is NOT running yet."
  echo " Edit these values first: ${PROBLEMS[*]}"
  echo
  echo "   sudo nano ${ENV_FILE}"
  echo
  echo " Then start it with:"
  echo "   sudo systemctl restart ferry"
  echo "   sudo systemctl status ferry"
  echo "======================================================================"
  if [[ "${FIRST_INSTALL}" -eq 1 ]]; then
    echo "A random FERRY_SECRET_KEY was generated for you."
  fi
  exit 0
fi

systemctl restart ferry
ACTIVE=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet ferry; then
    ACTIVE=1
    break
  fi
  sleep 1
done
if [[ "${ACTIVE}" -ne 1 ]]; then
  echo
  echo "ERROR: Ferry did not stay running. Recent log lines:" >&2
  systemctl --no-pager --full status ferry || true
  journalctl -u ferry -n 40 --no-pager || true
  echo >&2
  echo "Fix ${ENV_FILE}, then run: sudo systemctl restart ferry" >&2
  exit 1
fi

systemctl --no-pager --full status ferry || true
echo
echo "Installed version: $(/usr/local/bin/ferry --version 2>/dev/null || echo unknown)"

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="YOUR_SERVER_IP"
fi
LISTEN_ADDR="$(grep -E '^FERRY_LISTEN_ADDR=' "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
if [[ "${LISTEN_ADDR}" == 127.0.0.1:* ]]; then
  echo "Ferry is listening on ${LISTEN_ADDR} (behind Caddy)."
  echo "Open https://YOUR_DOMAIN after configuring Caddy."
else
  PORT="${LISTEN_ADDR##*:}"
  if [[ -z "${PORT}" || "${PORT}" == "${LISTEN_ADDR}" ]]; then
    PORT="8080"
  fi
  echo "Ferry should now be available at: http://${SERVER_IP}:${PORT}"
  echo "Open the firewall port: sudo ufw allow ${PORT}/tcp"
fi
if [[ "${FIRST_INSTALL}" -eq 1 ]]; then
  echo "A random FERRY_SECRET_KEY was generated for you."
fi
