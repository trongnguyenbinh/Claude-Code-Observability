#!/usr/bin/env bash
# Entrypoint for the all-in-one image.
# 1) Apply env defaults (sane localhost / no-TLS first-run mode).
# 2) Template every config from /etc/ccobs/templates with envsubst.
# 3) Wire nginx (ingest gate + grafana proxy) and the persistent token map.
# 4) Hand off to supervisord (or run `ccobs` if invoked directly).
set -euo pipefail

# If the container is run as `... ccobs <cmd>` use the management CLI directly.
if [ "${1:-}" = "ccobs" ]; then
  shift
  exec /usr/local/bin/ccobs "$@"
fi

##############################################################################
# Defaults — easy first run: plain HTTP, localhost, no allowlist.
##############################################################################
export OTEL_DOMAIN="${OTEL_DOMAIN:-_}"            # nginx server_name; "_" = match any host
export GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-_}"
export INGEST_PORT="${INGEST_PORT:-8080}"         # token-guarded OTLP ingest port
export GRAFANA_PORT="${GRAFANA_PORT:-3000}"       # Grafana dashboard port (nginx-proxied)
export OFFICE_IP="${OFFICE_IP:-}"                 # optional allowlist IP for Grafana
export TLS_ENABLED="${TLS_ENABLED:-false}"
export TLS_CERT="${TLS_CERT:-/certs/fullchain.pem}"
export TLS_KEY="${TLS_KEY:-/certs/privkey.pem}"

export GF_ADMIN_USER="${GF_ADMIN_USER:-admin}"
export GF_ADMIN_PASSWORD="${GF_ADMIN_PASSWORD:-changeme}"
# Grafana root_url: default to localhost on the published grafana port.
export GF_ROOT_URL="${GF_ROOT_URL:-http://localhost:${GRAFANA_PORT}/}"

export PROM_RETENTION="${PROM_RETENTION:-90d}"
export LOKI_RETENTION="${LOKI_RETENTION:-90d}"

# Where the management CLI reads the public ingest endpoint from when it prints
# installer snippets. Defaults to the local published port; override in prod.
export OTEL_PUBLIC_ENDPOINT="${OTEL_PUBLIC_ENDPOINT:-http://localhost:${INGEST_PORT}}"

TPL=/etc/ccobs/templates
RUNTIME=/etc/ccobs/runtime
TOKENS_DIR="${CCOBS_TOKENS_DIR:-/data/tokens}"
mkdir -p "$RUNTIME" "$TOKENS_DIR" /etc/nginx/conf.d \
         /data/prometheus /data/loki /data/grafana/plugins \
         /var/log/ccobs /run/ccobs

##############################################################################
# Persistent token map: keep it on the volume, expose it to nginx via conf.d.
##############################################################################
TOKEN_MAP="$TOKENS_DIR/00-otel-tokens.conf"
if [ ! -f "$TOKEN_MAP" ]; then
  cp "$TPL/00-otel-tokens.conf" "$TOKEN_MAP"
fi
# nginx includes /etc/nginx/conf.d/*.conf in the http context.
cp "$TOKEN_MAP" /etc/nginx/conf.d/00-otel-tokens.conf

##############################################################################
# Render service configs.
##############################################################################
render() { envsubst "$2" < "$1" > "$3"; }

# Only substitute the vars we own, so nginx's own $variables are left intact.
NGINX_VARS='${OTEL_DOMAIN} ${GRAFANA_DOMAIN} ${INGEST_PORT} ${GRAFANA_PORT} ${TLS_CERT} ${TLS_KEY} ${OFFICE_IP_ALLOW}'
GF_VARS='${GF_ROOT_URL} ${GF_ADMIN_USER} ${GF_ADMIN_PASSWORD}'
LOKI_VARS='${LOKI_RETENTION}'

# OTel / Prometheus / Loki
cp  "$TPL/otel-config.yaml.tmpl"  "$RUNTIME/otel-config.yaml"
cp  "$TPL/prometheus.yml.tmpl"    "$RUNTIME/prometheus.yml"
render "$TPL/loki-config.yaml.tmpl" "$LOKI_VARS" "$RUNTIME/loki-config.yaml"

# Grafana ini + datasources (point Grafana at localhost services)
render "$TPL/grafana.ini.tmpl" "$GF_VARS" "$RUNTIME/grafana.ini"
# datasources has no placeholders — just install the localhost-pointing version.
cp "$TPL/datasources.yaml.tmpl" /etc/grafana/provisioning/datasources/datasources.yaml

# nginx grafana vhost — inject office-IP allowlist only when OFFICE_IP is set.
if [ -n "$OFFICE_IP" ]; then
  export OFFICE_IP_ALLOW="allow ${OFFICE_IP}; deny all;"
else
  export OFFICE_IP_ALLOW=""
fi
render "$TPL/nginx-grafana.conf.tmpl" "$NGINX_VARS" /etc/nginx/conf.d/grafana.conf

# nginx ingest vhost — TLS or plain.
if [ "$TLS_ENABLED" = "true" ]; then
  if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
    echo "[entrypoint] TLS_ENABLED=true but cert/key not found at $TLS_CERT / $TLS_KEY" >&2
    exit 1
  fi
  render "$TPL/nginx-ingest-tls.conf.tmpl" "$NGINX_VARS" /etc/nginx/conf.d/ingest.conf
else
  render "$TPL/nginx-ingest.conf.tmpl" "$NGINX_VARS" /etc/nginx/conf.d/ingest.conf
fi

# Persist runtime knobs the CLI needs (endpoint, token map path) for docker exec.
cat > /etc/ccobs/env <<EOF
OTEL_PUBLIC_ENDPOINT=${OTEL_PUBLIC_ENDPOINT}
OTEL_TOKEN_MAP=${TOKEN_MAP}
NGINX_CONF_TOKEN_MAP=/etc/nginx/conf.d/00-otel-tokens.conf
EOF

# Validate nginx config early so a typo fails fast at boot, not later.
nginx -t

echo "[entrypoint] config rendered. ingest=:${INGEST_PORT} grafana=:${GRAFANA_PORT} tls=${TLS_ENABLED}"

##############################################################################
# Start everything.
##############################################################################
if [ "${1:-supervisor}" = "supervisor" ]; then
  exec /usr/bin/supervisord -c /etc/supervisor/conf.d/ccobs.conf
else
  exec "$@"
fi
