#!/usr/bin/env bash
set -euo pipefail

CERTBOT_BIN="${CERTBOT_BIN:-certbot}"
CONTAINER_NAME="${CONTAINER_NAME:-hysteria2}"
CERT_NAME="${CERT_NAME:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hysteria2}"

if [[ -z "$CERT_NAME" && -f "$INSTALL_DIR/install-result.json" ]] && command -v python3 >/dev/null 2>&1; then
  CERT_NAME="$(python3 - "$INSTALL_DIR/install-result.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get("ip", ""))
PY
)"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not in PATH." >&2
  exit 1
fi

if ! command -v "$CERTBOT_BIN" >/dev/null 2>&1; then
  echo "certbot binary not found: $CERTBOT_BIN" >&2
  exit 1
fi

if ! docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME does not exist. Certificate renewal skipped." >&2
  exit 1
fi

if [[ -z "$CERT_NAME" ]]; then
  echo "CERT_NAME is required. Set CERT_NAME=<IP> or keep $INSTALL_DIR/install-result.json readable." >&2
  exit 1
fi

"$CERTBOT_BIN" renew --cert-name "$CERT_NAME" --quiet --deploy-hook "docker restart $CONTAINER_NAME"
