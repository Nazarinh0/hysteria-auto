#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/hysteria2"
KEEP_FILES=0
REMOVE_FILES=0
REMOVE_CERT=0
FORCE=0
IP=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  uninstall.sh [options]

Options:
  --install-dir <PATH>  Install directory. Default: /opt/hysteria2.
  --keep-files          Stop/remove hysteria2 container, keep files.
  --remove-files        Stop/remove hysteria2 container, remove install dir after confirmation.
  --remove-cert         Also delete Let's Encrypt certificate lineage for IP after confirmation.
  --ip <IP>             IP lineage to delete with --remove-cert. If omitted, read from install-result.json.
  --force               Do not ask confirmation.
  --help                Show help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --keep-files) KEEP_FILES=1; shift ;;
      --remove-files) REMOVE_FILES=1; shift ;;
      --remove-cert) REMOVE_CERT=1; shift ;;
      --ip) IP="${2:-}"; shift 2 ;;
      --force) FORCE=1; shift ;;
      --help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi
}

confirm() {
  local prompt="$1"
  (( FORCE == 1 )) && return 0
  printf '%s [y/N]: ' "$prompt"
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

read_ip_from_json() {
  [[ -n "$IP" ]] && return
  [[ -f "$INSTALL_DIR/install-result.json" ]] || return
  if command -v python3 >/dev/null 2>&1; then
    IP="$(python3 - "$INSTALL_DIR/install-result.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get("ip", ""))
PY
)"
  fi
}

remove_container_and_timer() {
  docker stop hysteria2 || true
  docker rm hysteria2 || true
  systemctl disable --now hysteria2-cert-renew.timer || true
  rm -f /etc/systemd/system/hysteria2-cert-renew.service
  rm -f /etc/systemd/system/hysteria2-cert-renew.timer
  systemctl daemon-reload || true
}

remove_files_if_requested() {
  if (( REMOVE_FILES == 1 )); then
    confirm "Remove install directory ${INSTALL_DIR}?" || die "Install directory removal cancelled."
    rm -rf "$INSTALL_DIR"
  else
    echo "Install files kept in ${INSTALL_DIR}."
  fi
}

remove_cert_if_requested() {
  (( REMOVE_CERT == 1 )) || return
  read_ip_from_json
  [[ -n "$IP" ]] || die "--remove-cert needs --ip <IP> or readable ${INSTALL_DIR}/install-result.json."
  confirm "Delete Let's Encrypt certificate lineage for ${IP}?" || die "Certificate deletion cancelled."
  if command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$IP" --non-interactive || true
  elif [[ -x "$INSTALL_DIR/certbot-venv/bin/certbot" ]]; then
    "$INSTALL_DIR/certbot-venv/bin/certbot" delete --cert-name "$IP" --non-interactive || true
  else
    die "certbot not found. Certificate lineage was not removed."
  fi
}

main() {
  parse_args "$@"
  require_root
  [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" == /* ]] || die "--install-dir must be an absolute path."
  (( KEEP_FILES == 1 && REMOVE_FILES == 1 )) && die "Choose either --keep-files or --remove-files, not both."
  (( KEEP_FILES == 0 && REMOVE_FILES == 0 )) && KEEP_FILES=1
  remove_container_and_timer
  remove_cert_if_requested
  remove_files_if_requested
  echo "Uninstall completed. Docker Engine, Docker networks, firewall, iptables, and Amnezia containers were not modified."
}

main "$@"
