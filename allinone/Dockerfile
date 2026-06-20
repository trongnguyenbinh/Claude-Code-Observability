# Claude Code Observability — ALL-IN-ONE image
# Bundles OTel Collector + Prometheus + Loki + Grafana + nginx in ONE container,
# orchestrated by supervisord. Built for `docker pull` + `docker run` + `docker exec ccobs ...`.
#
# This is an ADDITION to the multi-container docker-compose.yml, not a replacement.
# Build locally requires Docker; in this repo the image is built/pushed by GitHub Actions
# (.github/workflows/docker-image.yml) to ghcr.io/trongnguyenbinh/claude-code-observability.
#
# Versions are pinned to match docker-compose.yml.
ARG OTELCOL_VERSION=0.119.0
ARG PROMETHEUS_VERSION=3.1.0
ARG LOKI_VERSION=3.3.2
ARG GRAFANA_VERSION=11.4.0

#####################################################################
# Stage 1 — grab the official upstream binaries / images' artifacts
#####################################################################

# OTel Collector contrib — copy the static binary out of the official image.
FROM otel/opentelemetry-collector-contrib:${OTELCOL_VERSION} AS otelcol

# Grafana — copy the whole install tree out of the official image (it expects
# its bundled plugins / public assets at /usr/share/grafana).
FROM grafana/grafana:${GRAFANA_VERSION} AS grafana

# Prometheus + Loki — fetch the release tarballs (these projects publish clean
# linux/amd64 + linux/arm64 archives).
FROM debian:bookworm-slim AS fetch
ARG PROMETHEUS_VERSION
ARG LOKI_VERSION
ARG TARGETARCH
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*; \
    arch="${TARGETARCH:-amd64}"; \
    # Prometheus
    curl -fsSL -o /tmp/prom.tar.gz \
      "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${arch}.tar.gz"; \
    mkdir -p /out/prometheus; \
    tar -xzf /tmp/prom.tar.gz -C /out/prometheus --strip-components=1; \
    # Loki
    curl -fsSL -o /tmp/loki.zip \
      "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${arch}.zip"; \
    unzip -o /tmp/loki.zip -d /tmp/loki; \
    mkdir -p /out/loki; \
    mv /tmp/loki/loki-linux-${arch} /out/loki/loki; \
    chmod +x /out/loki/loki

#####################################################################
# Stage 2 — final runtime image
#####################################################################
FROM debian:bookworm-slim AS runtime
ARG GRAFANA_VERSION
LABEL org.opencontainers.image.title="claude-code-observability (all-in-one)" \
      org.opencontainers.image.description="OTel Collector + Prometheus + Loki + Grafana + nginx in one container" \
      org.opencontainers.image.source="https://github.com/trongnguyenbinh/Claude-Code-Observability"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps: supervisor (process manager), nginx (ingest gate + grafana proxy),
# gettext-base (envsubst for templating), openssl (token generation), jq + curl + ca-certs,
# tzdata for sane timestamps.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      supervisor nginx gettext-base openssl jq curl ca-certificates tzdata bash; \
    rm -rf /var/lib/apt/lists/*; \
    # nginx default site off; we provide our own conf.d files.
    rm -f /etc/nginx/sites-enabled/default

# --- Binaries ---------------------------------------------------------------
COPY --from=otelcol /otelcol-contrib /usr/local/bin/otelcol-contrib
COPY --from=fetch /out/prometheus/prometheus /usr/local/bin/prometheus
COPY --from=fetch /out/prometheus/promtool   /usr/local/bin/promtool
COPY --from=fetch /out/loki/loki             /usr/local/bin/loki

# --- Grafana install tree ---------------------------------------------------
# Grafana needs its home (binaries + bundled plugins + public assets).
COPY --from=grafana /usr/share/grafana /usr/share/grafana
RUN ln -sf /usr/share/grafana/bin/grafana /usr/local/bin/grafana \
 && ln -sf /usr/share/grafana/bin/grafana-server /usr/local/bin/grafana-server

# --- Config templates + provisioning (reused from the repo) ------------------
# The .tmpl files contain ${ENV} placeholders that entrypoint.sh fills with envsubst.
COPY allinone/templates/ /etc/ccobs/templates/
COPY otel-collector/config.yaml      /etc/ccobs/static/otel-config.yaml
COPY prometheus/prometheus.yml       /etc/ccobs/static/prometheus.yml
COPY loki/loki-config.yaml           /etc/ccobs/static/loki-config.yaml
COPY grafana/provisioning/           /etc/grafana/provisioning/
# Auto-load the prebuilt dashboard (lives in docs/ in the repo) so Grafana shows data on first boot.
COPY docs/claude-code-metrics-dashboard.json /var/lib/grafana/dashboards/claude-code-metrics.json

# --- Management CLI + supervisor + entrypoint -------------------------------
COPY allinone/ccobs            /usr/local/bin/ccobs
COPY allinone/supervisord.conf /etc/supervisor/conf.d/ccobs.conf
COPY allinone/entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/ccobs /usr/local/bin/entrypoint.sh

# --- Data dirs (mount named volumes here to persist) ------------------------
RUN set -eux; \
    mkdir -p /data/prometheus /data/loki /data/grafana \
             /var/lib/grafana/dashboards /var/log/ccobs /run/ccobs; \
    # Grafana writes its sqlite + plugins under GF_PATHS_DATA=/data/grafana.
    chmod -R 0777 /data /var/lib/grafana /var/log/ccobs /run/ccobs

# Ports:
#   8443/8080 — nginx ingest gate (token-guarded OTLP) ; default HTTP 8080
#   3001      — Grafana UI via nginx-grafana vhost (Grafana itself stays on internal 3000; the vhost port MUST differ from 3000 in this single-container image)
#   9090      — Prometheus (debug, localhost-style; exposed for convenience)
# By default nginx serves ingest on $INGEST_PORT and grafana on $GRAFANA_PORT (default 3001).
EXPOSE 8080 3001 9090

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["supervisor"]
