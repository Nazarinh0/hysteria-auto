#!/usr/bin/env bash
set -euo pipefail

IMAGE="tobyxdd/hysteria:latest"
CONTAINER_NAME="hysteria2"
DEFAULT_INSTALL_DIR="/opt/hysteria2"
DEFAULT_PORT="8443"
DEFAULT_NAME="nasha-hy2"
LETSENCRYPT_EMAIL="admin@hy2.com"

IP=""
PROFILE_NAME="$DEFAULT_NAME"
PORT="$DEFAULT_PORT"
TLS_MODE="letsencrypt-ip"
AUTH_PASSWORD=""
OBFS_PASSWORD=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CERTBOT_MODE="standalone"
NO_FIREWALL=0
FORCE=0
JSON_OUTPUT=0
CERTBOT_BIN=""

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage:
  install.sh --ip <IPv4> [options]

Required:
  --ip <IP>                         Public IPv4 address.

Options:
  --name <NAME>                     URI fragment/profile name. Default: "nasha-hy2".
  --port <PORT>                     UDP Hysteria port. Default: 8443.
  --tls <letsencrypt-ip|self-signed> Default: letsencrypt-ip.
  --auth-password <PASSWORD>        Hysteria auth password. Generated if omitted.
  --obfs-password <PASSWORD>        Salamander obfs password. Generated if omitted.
  --install-dir <PATH>              Install directory. Default: /opt/hysteria2.
  --certbot-mode <standalone|webroot> Default: standalone. MVP implements standalone only.
  --no-firewall                     Do not change local firewall.
  --force                           Replace existing hysteria2 container and backup files.
  --json-output                     Also print install-result JSON to stdout.
  --help                            Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip) IP="${2:-}"; shift 2 ;;
      --email) die "--email is not a user-facing option. Let's Encrypt account email is fixed by the deployer." ;;
      --name) PROFILE_NAME="${2:-}"; shift 2 ;;
      --port) PORT="${2:-}"; shift 2 ;;
      --tls) TLS_MODE="${2:-}"; shift 2 ;;
      --auth-password) AUTH_PASSWORD="${2:-}"; shift 2 ;;
      --obfs-password) OBFS_PASSWORD="${2:-}"; shift 2 ;;
      --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --certbot-mode) CERTBOT_MODE="${2:-}"; shift 2 ;;
      --no-firewall) NO_FIREWALL=1; shift ;;
      --force) FORCE=1; shift ;;
      --json-output) JSON_OUTPUT=1; shift ;;
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

valid_ipv4() {
  local ip="$1" part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$ip"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_password() {
  local label="$1" value="$2" min_len="$3"
  [[ -n "$value" ]] || die "$label must not be empty."
  (( ${#value} >= min_len )) || die "$label must be at least ${min_len} characters."
  [[ ! "$value" =~ [[:space:]] ]] || die "$label must not contain whitespace."
}

generate_password() {
  local value=""
  while [[ ${#value} -lt 16 ]]; do
    value="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16 || true)"
  done
  printf '%s' "$value"
}

validate_args() {
  [[ -n "$IP" ]] || die "--ip is required."
  valid_ipv4 "$IP" || die "--ip must be a valid IPv4 address."
  valid_port "$PORT" || die "--port must be a number from 1 to 65535."
  [[ "$TLS_MODE" == "letsencrypt-ip" || "$TLS_MODE" == "self-signed" ]] || die "--tls must be letsencrypt-ip or self-signed."
  [[ "$CERTBOT_MODE" == "standalone" || "$CERTBOT_MODE" == "webroot" ]] || die "--certbot-mode must be standalone or webroot."
  [[ "$CERTBOT_MODE" == "standalone" ]] || die "certbot webroot mode is planned but not implemented in this MVP."
  [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" == /* ]] || die "--install-dir must be an absolute path."
  if [[ -n "$AUTH_PASSWORD" ]]; then
    validate_password "--auth-password" "$AUTH_PASSWORD" 8
  else
    AUTH_PASSWORD="$(generate_password)"
  fi
  if [[ -n "$OBFS_PASSWORD" ]]; then
    validate_password "--obfs-password" "$OBFS_PASSWORD" 8
  else
    OBFS_PASSWORD="$(generate_password)"
  fi
}

check_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release is missing."
  # shellcheck disable=SC1091
  . /etc/os-release
  local os_id="${ID:-}" version_id="${VERSION_ID:-}"
  case "$os_id:$version_id" in
    ubuntu:22.04|ubuntu:24.04|debian:12) ;;
    ubuntu:*|debian:*) warn "Unsupported ${PRETTY_NAME:-$os_id $version_id}. Supported MVP targets: Ubuntu 22.04, Ubuntu 24.04, Debian 12." ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported MVP targets: Ubuntu 22.04, Ubuntu 24.04, Debian 12." ;;
  esac
}

apt_install_minimal() {
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_base_tools() {
  local missing=()
  have openssl || missing+=(openssl)
  have ss || missing+=(iproute2)
  have curl || missing+=(curl)
  have python3 || missing+=(python3)
  if (( ${#missing[@]} > 0 )); then
    apt_install_minimal "${missing[@]}"
  fi
}

port_is_listening_udp() {
  ss -H -lunp 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\\])${1}$"
}

port_is_listening_tcp() {
  ss -H -lntp 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${1}$"
}

check_ports() {
  if port_is_listening_udp "$PORT"; then
    echo "UDP port ${PORT} is already in use. Hysteria cannot bind to this port. Use --port <another_udp_port> or free this UDP port."
    ss -lunp | grep ":${PORT}" || true
    exit 1
  fi
  if port_is_listening_tcp "$PORT"; then
    warn "TCP port ${PORT} is in use. Hysteria uses UDP ${PORT}, so this is not a hard conflict."
  fi
  if port_is_listening_tcp 443; then
    log "TCP 443 may be used by Amnezia Xray/REALITY. This does not conflict with Hysteria on UDP ${PORT}."
  fi
  if [[ "$TLS_MODE" == "letsencrypt-ip" && "$CERTBOT_MODE" == "standalone" ]]; then
    if port_is_listening_tcp 80; then
      echo "TCP port 80 is already in use. Certbot standalone mode needs TCP 80 for Let's Encrypt IP certificate validation. This script will not stop existing services automatically."
      ss -lntp | grep ':80' || true
      exit 1
    fi
  fi
}

detect_amnezia_containers() {
  if have docker && docker info >/dev/null 2>&1; then
    log "Current Docker containers:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
    if docker ps --format '{{.Names}}' | grep -Eiq '(amnezia|xray|awg|wireguard|openvpn)'; then
      log "Existing Amnezia-related containers detected. They will not be modified."
    fi
  fi
}

install_docker() {
  # shellcheck disable=SC1091
  . /etc/os-release
  apt_install_minimal ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || die "Cannot detect OS codename for Docker repository."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${codename} stable" > /etc/apt/sources.list.d/docker.list
  apt_install_minimal docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  systemctl enable --now docker
}

ensure_docker() {
  if have docker; then
    if docker info >/dev/null 2>&1; then
      log "Docker is installed and running. It will not be reinstalled, upgraded, or restarted."
      return
    fi
    log "Docker command exists, but daemon is not running. Starting docker.service without restart."
    systemctl start docker
    docker info >/dev/null 2>&1 || die "Docker daemon did not become available after systemctl start docker."
    return
  fi
  log "Docker is not installed. Installing Docker Engine without Docker Compose."
  install_docker
  docker info >/dev/null 2>&1 || die "Docker is installed but docker info failed."
}

check_docker_iptables() {
  if [[ -f /etc/docker/daemon.json ]] && grep -Eq '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json; then
    echo "Docker iptables management appears to be disabled. This deployer relies on Docker port publishing (-p ${PORT}:${PORT}/udp). Enable Docker iptables management or configure networking manually."
    exit 1
  fi
}

prepare_install_dir() {
  install -d -m 700 "$INSTALL_DIR"
  install -d -m 700 "$INSTALL_DIR/backups"
}

backup_existing_files() {
  local paths=(
    "$INSTALL_DIR/config.yaml"
    "$INSTALL_DIR/server.crt"
    "$INSTALL_DIR/server.key"
    "$INSTALL_DIR/client-uri.txt"
    "$INSTALL_DIR/install-result.json"
    "$INSTALL_DIR/server-info.txt"
    "$INSTALL_DIR/docker-run-command.sh"
    "$INSTALL_DIR/renew-cert.sh"
  )
  local any=0 timestamp backup_dir path
  for path in "${paths[@]}"; do
    [[ -e "$path" ]] && any=1
  done
  (( any == 0 )) && return
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$INSTALL_DIR/backups/$timestamp"
  install -d -m 700 "$backup_dir"
  for path in "${paths[@]}"; do
    if [[ -e "$path" ]]; then
      cp -a "$path" "$backup_dir/"
    fi
  done
  log "Existing install files backed up to $backup_dir"
}

handle_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    if (( FORCE == 0 )); then
      die "Container ${CONTAINER_NAME} already exists. Re-run with --force to stop and remove only this container after backing up files."
    fi
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

version_ge() {
  local need="$1" got="$2"
  [[ "$(printf '%s\n%s\n' "$need" "$got" | sort -V | head -n1)" == "$need" ]]
}

system_certbot_ok() {
  have certbot || return 1
  local version
  version="$(certbot --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
  [[ -n "$version" ]] || return 1
  version_ge "5.4" "$version"
}

ensure_certbot() {
  [[ "$TLS_MODE" == "letsencrypt-ip" ]] || return
  if system_certbot_ok; then
    CERTBOT_BIN="$(command -v certbot)"
    log "Using system certbot: $CERTBOT_BIN"
    return
  fi
  log "Installing isolated certbot >= 5.4 into ${INSTALL_DIR}/certbot-venv"
  apt_install_minimal python3 python3-venv python3-pip
  python3 -m venv "$INSTALL_DIR/certbot-venv"
  "$INSTALL_DIR/certbot-venv/bin/pip" install --upgrade pip
  "$INSTALL_DIR/certbot-venv/bin/pip" install "certbot>=5.4"
  CERTBOT_BIN="$INSTALL_DIR/certbot-venv/bin/certbot"
  "$CERTBOT_BIN" --version | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1 | while read -r version; do
    version_ge "5.4" "$version" || die "Installed certbot version $version is below 5.4."
  done
}

configure_firewall() {
  if (( NO_FIREWALL == 1 )); then
    warn "--no-firewall set. Local firewall was not changed."
    return
  fi
  if have ufw; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow "${PORT}/udp"
      [[ "$TLS_MODE" == "letsencrypt-ip" ]] && ufw allow 80/tcp
      return
    fi
    warn "ufw is inactive. It was not enabled automatically to avoid locking out SSH."
  fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/udp"
    [[ "$TLS_MODE" == "letsencrypt-ip" ]] && firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --reload
    return
  fi
  warn "No active local firewall manager detected. Docker port publishing is configured, but you must ensure UDP ${PORT} is allowed. For Let's Encrypt IP certificates, TCP 80 must also be allowed."
}

issue_letsencrypt_ip_cert() {
  [[ "$TLS_MODE" == "letsencrypt-ip" ]] || return
  log "Requesting Let's Encrypt IP certificate for ${IP}. TCP 80 must be reachable from the internet."
  "$CERTBOT_BIN" certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "$LETSENCRYPT_EMAIL" \
    --cert-name "$IP" \
    --preferred-profile shortlived \
    --ip-address "$IP"
  [[ -f "/etc/letsencrypt/live/${IP}/fullchain.pem" ]] || die "Certificate file missing: /etc/letsencrypt/live/${IP}/fullchain.pem"
  [[ -f "/etc/letsencrypt/live/${IP}/privkey.pem" ]] || die "Private key file missing: /etc/letsencrypt/live/${IP}/privkey.pem"
}

create_self_signed_cert() {
  [[ "$TLS_MODE" == "self-signed" ]] || return
  openssl req -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -nodes \
    -keyout "$INSTALL_DIR/server.key" \
    -out "$INSTALL_DIR/server.crt" \
    -subj "/CN=${IP}" \
    -addext "subjectAltName = IP:${IP}"
  chmod 600 "$INSTALL_DIR/server.key"
  chmod 644 "$INSTALL_DIR/server.crt"
}

write_config() {
  local cert_path key_path
  if [[ "$TLS_MODE" == "letsencrypt-ip" ]]; then
    cert_path="/etc/letsencrypt/live/${IP}/fullchain.pem"
    key_path="/etc/letsencrypt/live/${IP}/privkey.pem"
  else
    cert_path="/etc/hysteria/server.crt"
    key_path="/etc/hysteria/server.key"
  fi
  cat >"$INSTALL_DIR/config.yaml" <<EOF
listen: :${PORT}

tls:
  cert: ${cert_path}
  key: ${key_path}
  sniGuard: disable

auth:
  type: password
  password: ${AUTH_PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}

masquerade:
  type: string
  string:
    content: "404 Not Found"
    headers:
      content-type: text/plain
    statusCode: 404
EOF
  chmod 600 "$INSTALL_DIR/config.yaml"
}

write_docker_run_command() {
  if [[ "$TLS_MODE" == "letsencrypt-ip" ]]; then
    cat >"$INSTALL_DIR/docker-run-command.sh" <<EOF
#!/usr/bin/env bash
docker run -d \\
  --name ${CONTAINER_NAME} \\
  --restart unless-stopped \\
  -p ${PORT}:${PORT}/udp \\
  -v ${INSTALL_DIR}/config.yaml:/etc/hysteria/config.yaml:ro \\
  -v /etc/letsencrypt:/etc/letsencrypt:ro \\
  ${IMAGE} \\
  server -c /etc/hysteria/config.yaml
EOF
  else
    cat >"$INSTALL_DIR/docker-run-command.sh" <<EOF
#!/usr/bin/env bash
docker run -d \\
  --name ${CONTAINER_NAME} \\
  --restart unless-stopped \\
  -p ${PORT}:${PORT}/udp \\
  -v ${INSTALL_DIR}/config.yaml:/etc/hysteria/config.yaml:ro \\
  -v ${INSTALL_DIR}/server.crt:/etc/hysteria/server.crt:ro \\
  -v ${INSTALL_DIR}/server.key:/etc/hysteria/server.key:ro \\
  ${IMAGE} \\
  server -c /etc/hysteria/config.yaml
EOF
  fi
  chmod 700 "$INSTALL_DIR/docker-run-command.sh"
}

pull_image_and_run() {
  docker pull "$IMAGE" || die "docker pull ${IMAGE} failed."
  write_docker_run_command
  "$INSTALL_DIR/docker-run-command.sh"
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

json_escape() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

write_renew_script() {
  [[ "$TLS_MODE" == "letsencrypt-ip" ]] || return
  cat >"$INSTALL_DIR/renew-cert.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

CERTBOT_BIN="${CERTBOT_BIN}"
CONTAINER_NAME="${CONTAINER_NAME}"
CERT_NAME="${IP}"

if ! docker ps -a --format '{{.Names}}' | grep -Fxq "\${CONTAINER_NAME}"; then
  echo "Container \${CONTAINER_NAME} does not exist. Certificate renewal skipped." >&2
  exit 1
fi

"\${CERTBOT_BIN}" renew --cert-name "\${CERT_NAME}" --quiet --deploy-hook "docker restart \${CONTAINER_NAME}"
EOF
  chmod 700 "$INSTALL_DIR/renew-cert.sh"
}

install_renew_timer() {
  [[ "$TLS_MODE" == "letsencrypt-ip" ]] || return
  cat >/etc/systemd/system/hysteria2-cert-renew.service <<EOF
[Unit]
Description=Renew Let's Encrypt IP certificate for Hysteria 2

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/renew-cert.sh
EOF
  cat >/etc/systemd/system/hysteria2-cert-renew.timer <<'EOF'
[Unit]
Description=Run Hysteria 2 certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 03,15:20:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hysteria2-cert-renew.timer
}

generate_uri_and_artifacts() {
  local encoded_name insecure uri cert_path key_path renewal_timer
  encoded_name="$(urlencode "$PROFILE_NAME")"
  if [[ "$TLS_MODE" == "letsencrypt-ip" ]]; then
    insecure="0"
    cert_path="/etc/letsencrypt/live/${IP}/fullchain.pem"
    key_path="/etc/letsencrypt/live/${IP}/privkey.pem"
    renewal_timer="hysteria2-cert-renew.timer"
  else
    insecure="1"
    cert_path="${INSTALL_DIR}/server.crt"
    key_path="${INSTALL_DIR}/server.key"
    renewal_timer=""
  fi
  uri="hysteria2://${AUTH_PASSWORD}@${IP}:${PORT}/?obfs=salamander&obfs-password=${OBFS_PASSWORD}&sni=${IP}&insecure=${insecure}#${encoded_name}"
  printf '%s\n' "$uri" >"$INSTALL_DIR/client-uri.txt"

  cat >"$INSTALL_DIR/install-result.json" <<EOF
{
  "ip": $(json_escape "$IP"),
  "port": ${PORT},
  "container": $(json_escape "$CONTAINER_NAME"),
  "image": $(json_escape "$IMAGE"),
  "install_dir": $(json_escape "$INSTALL_DIR"),
  "tls_mode": $(json_escape "$TLS_MODE"),
  "insecure": $([[ "$insecure" == "0" ]] && echo false || echo true),
  "auth_password": $(json_escape "$AUTH_PASSWORD"),
  "obfs_password": $(json_escape "$OBFS_PASSWORD"),
  "uri": $(json_escape "$uri"),
  "config_path": $(json_escape "$INSTALL_DIR/config.yaml"),
  "cert_path": $(json_escape "$cert_path"),
  "key_path": $(json_escape "$key_path"),
  "renew_timer": $(json_escape "$renewal_timer")
}
EOF

  cat >"$INSTALL_DIR/server-info.txt" <<EOF
IP: ${IP}
UDP port: ${PORT}
TCP 80 requirement: required for Let's Encrypt IP certificate issuance and renewal in standalone mode
Container name: ${CONTAINER_NAME}
Image: ${IMAGE}
Install dir: ${INSTALL_DIR}
Config path: ${INSTALL_DIR}/config.yaml
TLS mode: ${TLS_MODE}
Certificate path: ${cert_path}
Private key path: ${key_path}
Auth password: ${AUTH_PASSWORD}
Obfs password: ${OBFS_PASSWORD}
Client URI: ${uri}
Renewal timer: ${renewal_timer}

Useful commands:
  docker ps --filter name=${CONTAINER_NAME}
  docker logs ${CONTAINER_NAME}
  docker port ${CONTAINER_NAME}
  ss -lunp | grep ${PORT}
  systemctl list-timers | grep hysteria2-cert-renew
  journalctl -u hysteria2-cert-renew.service --no-pager -e
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
EOF
  chmod 600 "$INSTALL_DIR/client-uri.txt" "$INSTALL_DIR/install-result.json" "$INSTALL_DIR/server-info.txt"

  CLIENT_URI="$uri"
  CERT_PATH="$cert_path"
  RENEWAL_TIMER="$renewal_timer"
}

verify_container() {
  local status
  status="$(docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}} {{.Status}}' || true)"
  if [[ "$status" != ${CONTAINER_NAME}\ * ]]; then
    docker logs "$CONTAINER_NAME" || true
    die "Container ${CONTAINER_NAME} is not running."
  fi
  docker port "$CONTAINER_NAME" || true
  if ! ss -lunp | grep -q ":${PORT}"; then
    warn "ss did not show UDP ${PORT}. If docker port shows ${PORT}/udp and the container is running, Docker UDP publishing may still be active."
  fi
}

final_output() {
  cat <<EOF
Hysteria 2 Docker deployment completed.

Server:
  IP: ${IP}
  UDP port: ${PORT}
  Container: ${CONTAINER_NAME}
  Image: ${IMAGE}
  Install dir: ${INSTALL_DIR}
  Config: ${INSTALL_DIR}/config.yaml
  TLS mode: ${TLS_MODE}
  Certificate: ${CERT_PATH}
  Renewal timer: ${RENEWAL_TIMER:-none}

Client URI:
  ${CLIENT_URI}

Important:
  This deployment uses a ${TLS_MODE} certificate mode.
  Client URI uses insecure=$([[ "$TLS_MODE" == "letsencrypt-ip" ]] && echo 0 || echo 1).
  Make sure UDP ${PORT} is open in your VPS provider firewall/security group.
  $([[ "$TLS_MODE" == "letsencrypt-ip" ]] && echo "Make sure TCP 80 is open for certificate issuance and renewal." || echo "Self-signed mode does not use Let's Encrypt or TCP 80 renewal.")
  Existing Amnezia containers were not modified.
  Certificate renewal may briefly restart only the hysteria2 container.

Useful commands:
  docker ps --filter name=${CONTAINER_NAME}
  docker logs ${CONTAINER_NAME}
  docker port ${CONTAINER_NAME}
  ss -lunp | grep ${PORT}
  systemctl list-timers | grep hysteria2-cert-renew
  journalctl -u hysteria2-cert-renew.service --no-pager -e
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
EOF
  if (( JSON_OUTPUT == 1 )); then
    cat "$INSTALL_DIR/install-result.json"
  fi
}

main() {
  parse_args "$@"
  require_root
  validate_args
  check_os
  ensure_base_tools
  check_ports
  prepare_install_dir
  backup_existing_files
  ensure_docker
  check_docker_iptables
  detect_amnezia_containers
  handle_existing_container
  ensure_certbot
  configure_firewall
  issue_letsencrypt_ip_cert
  create_self_signed_cert
  write_config
  pull_image_and_run
  write_renew_script
  install_renew_timer
  verify_container
  generate_uri_and_artifacts
  log "Also open UDP ${PORT} in your VPS provider firewall/security group."
  [[ "$TLS_MODE" == "letsencrypt-ip" ]] && log "For Let's Encrypt IP certificate issuance and renewal, also open TCP 80 in your VPS provider firewall/security group."
  final_output
}

main "$@"
