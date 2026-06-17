#!/usr/bin/env bash
# Add a device: generate a unique token, write it into the nginx map, reload, and print the install config for that machine.
# Usage:  sudo ./add-device.sh <machine-name>
set -euo pipefail

NAME="${1:?Usage: add-device.sh <machine-name>}"
MAP="${OTEL_TOKEN_MAP:-/etc/nginx/conf.d/00-otel-tokens.conf}"
DOMAIN="${OTEL_DOMAIN:-<OTEL_DOMAIN>}"

# sanitize the name for use in the token
SAFE=$(printf '%s' "$NAME" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')
TOKEN="tok_${SAFE}_$(openssl rand -hex 16)"

# create the map if it doesn't exist yet
if [ ! -f "$MAP" ]; then
  printf 'map $http_authorization $otel_device {\n    default "";\n}\n' > "$MAP"
fi

# reject if the name already exists
if grep -q "\"${NAME}\";[[:space:]]*$" "$MAP"; then
  echo "Device '${NAME}' already exists in the map. Revoke it first if you want to reissue." >&2
  exit 1
fi

# insert the line before the map's closing }
LINE="    \"Bearer ${TOKEN}\"  \"${NAME}\";"
sed -i "/^}/i\\${LINE}" "$MAP"

nginx -t && (systemctl reload nginx || nginx -s reload)

cat <<EOF

✅ Device provisioned: ${NAME}
Token: ${TOKEN}

=== Config for this machine — paste into ~/.claude/settings.json ===
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://${DOMAIN}",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer ${TOKEN}",
    "OTEL_RESOURCE_ATTRIBUTES": "machine=${NAME}"
  }
}

Or run the one-click installer on that machine:
  Ubuntu:  OTEL_TOKEN='${TOKEN}' OTEL_MACHINE='${NAME}' bash install-otel.sh
  Windows: powershell -ExecutionPolicy Bypass -File install-otel.ps1 -Token '${TOKEN}' -Machine '${NAME}'
EOF
