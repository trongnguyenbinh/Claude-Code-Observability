#!/usr/bin/env bash
# One-click setup to make Claude Code send telemetry to the server (Ubuntu/Linux/macOS).
# Usage:
#   OTEL_TOKEN='tok_...' bash install-otel.sh
#   (optional) OTEL_MACHINE='machine-name' OTEL_USER='user-name' OTEL_ENDPOINT='https://<OTEL_DOMAIN>'
set -euo pipefail

ENDPOINT="${OTEL_ENDPOINT:-https://<OTEL_DOMAIN>}"
TOKEN="${OTEL_TOKEN:-}"
MACHINE="${OTEL_MACHINE:-$(hostname)}"
USER_ID="${OTEL_USER:-$(whoami)}"

if [ -z "$TOKEN" ]; then
  read -rp "Enter the device token (provided by your admin): " TOKEN
fi
[ -z "$TOKEN" ] && { echo "Token missing. Aborting."; exit 1; }

DIR="$HOME/.claude"
SETTINGS="$DIR/settings.json"
mkdir -p "$DIR"

ENVJSON=$(cat <<EOF
{
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "${ENDPOINT}",
  "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer ${TOKEN}",
  "OTEL_RESOURCE_ATTRIBUTES": "machine=${MACHINE},user.id=${USER_ID}"
}
EOF
)

# Merge while keeping the existing config if jq is available; otherwise back up and write fresh.
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  jq --argjson e "$ENVJSON" '.env = ((.env // {}) + $e)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  printf '{\n  "env": %s\n}\n' "$ENVJSON" > "$SETTINGS"
fi
echo "✅ Config written to $SETTINGS (machine=${MACHINE}, user=${USER_ID})"

# Connection test: send an empty POST to /v1/metrics. 200/400/415 = server reachable & token OK; 401 = wrong token; 000 = no connection.
code=$(curl -s -o /dev/null -m 10 -w "%{http_code}" -X POST "${ENDPOINT}/v1/metrics" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data '{}' 2>/dev/null || echo 000)
case "$code" in
  200|202|400|415) echo "🔌 Connection test: HTTP $code → OK (server reachable, token valid).";;
  401|403)         echo "⛔ Connection test: HTTP $code → WRONG TOKEN or blocked. Double-check the token.";;
  000)             echo "⛔ Connection test: could not connect to ${ENDPOINT}. Check network/DNS/firewall.";;
  *)               echo "❓ Connection test: HTTP $code (review if this isn't a valid 2xx/4xx).";;
esac
echo "Done. Just use Claude Code as usual — data will be sent to the server automatically."
