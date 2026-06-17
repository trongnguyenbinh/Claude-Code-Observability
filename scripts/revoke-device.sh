#!/usr/bin/env bash
# Revoke a device: remove its token line from the nginx map and reload → that machine is blocked immediately.
# Usage:  sudo ./revoke-device.sh <machine-name>
set -euo pipefail

NAME="${1:?Usage: revoke-device.sh <machine-name>}"
MAP="${OTEL_TOKEN_MAP:-/etc/nginx/conf.d/00-otel-tokens.conf}"

if ! grep -q "\"${NAME}\";[[:space:]]*$" "$MAP"; then
  echo "Device '${NAME}' not found in the map." >&2
  exit 1
fi

sed -i "/\"${NAME}\";[[:space:]]*$/d" "$MAP"
nginx -t && (systemctl reload nginx || nginx -s reload)
echo "✅ Revoked '${NAME}' — token disabled, that machine can no longer send data."
