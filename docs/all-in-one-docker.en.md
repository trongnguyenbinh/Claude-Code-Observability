[🇻🇳 Tiếng Việt](all-in-one-docker.md) | 🇬🇧 English

# All-in-one Docker image

How to run the entire observability stack (OTel Collector + Prometheus + Loki + Grafana + nginx)
in ONE single container. You just `docker pull` then `docker run`, after which you manage
devices/tokens with `docker exec ... ccobs`.

This is a complementary option, NOT a replacement for the multi-container build. You can still
use `docker-compose.yml` as before (see `README.md`). Two choices:

- Multi-container (compose): separate services, suited for production that already has external nginx + certbot.
- All-in-one (this image): compact, one command to get running, suited for quick trials / small self-host.

## Image

```
ghcr.io/trongnguyenbinh/claude-code-observability:latest
```

The image is built and pushed automatically by GitHub Actions (`.github/workflows/docker-image.yml`).
Do not build on the dev machine; just pull the CI-built image.

## Quick run (no-TLS, localhost)

```bash
docker pull ghcr.io/trongnguyenbinh/claude-code-observability:latest

docker run -d --name ccobs \
  -p 8080:8080 \
  -p 3000:3000 \
  -e GF_ADMIN_PASSWORD='doi-mat-khau-manh' \
  -v ccobs-prometheus:/data/prometheus \
  -v ccobs-loki:/data/loki \
  -v ccobs-grafana:/data/grafana \
  -v ccobs-tokens:/data/tokens \
  ghcr.io/trongnguyenbinh/claude-code-observability:latest
```

Then:

- Grafana: http://localhost:3000 (user `admin`, password is `GF_ADMIN_PASSWORD`). The
  "Claude Code Metrics" dashboard is preloaded.
- OTLP ingest (for satellite machines): http://localhost:8080 (needs a token, see below).
- Ingest health check: `curl http://localhost:8080/healthz`.

## Add / remove / list devices

Manage devices via `ccobs` inside the container (logic taken from `scripts/add-device.sh` and
`scripts/revoke-device.sh`, keeping the same one-token-per-machine mechanism):

```bash
# Create a token for a machine (with optional user). Prints token + settings.json snippet + install command.
docker exec ccobs ccobs add-device macbook-cua-edward edward

# Remove a device by machine NAME ...
docker exec ccobs ccobs revoke-device macbook-cua-edward
# ... or remove by TOKEN
docker exec ccobs ccobs revoke-device tok_macbook_xxxxxxxxxxxxxxxx

# List registered devices
docker exec ccobs ccobs list-devices

# Show endpoint, token map path, status of each service
docker exec ccobs ccobs status
```

`add-device` prints a JSON block to paste into `~/.claude/settings.json` on the machine you want
to monitor, along with the command to run `satellite/install-otel.sh`. The token map is persisted
on the `/data/tokens` volume, so devices survive a container restart. On each add/remove, nginx
reloads itself so the change takes effect immediately.

Note the endpoint in the snippet: the default is `http://localhost:8080`. For a real deployment, set
`OTEL_PUBLIC_ENDPOINT` (e.g. `https://otel.example.com`) so the snippet prints the correct public address.

## Install a satellite machine

Copy the `satellite/` folder to the machine to monitor and run it, using the exact token and
endpoint that `add-device` printed:

```bash
OTEL_TOKEN='tok_...' OTEL_MACHINE='ten-may' OTEL_ENDPOINT='http://server:8080' bash install-otel.sh
```

## Environment variables (ENV)

| Variable | Default | Meaning |
|---|---|---|
| `GF_ADMIN_USER` | `admin` | Grafana admin user |
| `GF_ADMIN_PASSWORD` | `changeme` | Grafana admin password (change immediately) |
| `GF_ROOT_URL` | `http://localhost:<GRAFANA_PORT>/` | Grafana's `root_url` (set the real domain when deploying) |
| `INGEST_PORT` | `8080` | nginx port that receives OTLP (token-gated) |
| `GRAFANA_PORT` | `3001` | nginx-grafana vhost port. MUST differ from 3000 (internal Grafana keeps 3000; same container so a clash crashes it) |
| `OTEL_DOMAIN` | `_` | `server_name` for the ingest vhost (`_` = match any host) |
| `GRAFANA_DOMAIN` | `_` | `server_name` for the Grafana vhost |
| `OTEL_PUBLIC_ENDPOINT` | `http://localhost:<INGEST_PORT>` | Public endpoint used in the `add-device` snippet |
| `OFFICE_IP` | (empty) | If set, Grafana only allows this IP (`allow/deny`) |
| `PROM_RETENTION` | `90d` | Prometheus metric retention period |
| `LOKI_RETENTION` | `90d` | Loki log retention period |
| `TLS_ENABLED` | `false` | Enable TLS inside the container (see below) |
| `TLS_CERT` | `/certs/fullchain.pem` | Cert path when `TLS_ENABLED=true` |
| `TLS_KEY` | `/certs/privkey.pem` | Private key path when `TLS_ENABLED=true` |

## Volumes (mount these to keep data)

| Mount in container | Contents |
|---|---|
| `/data/prometheus` | Metrics TSDB |
| `/data/loki` | Log chunks + index |
| `/data/grafana` | Grafana SQLite, sessions, plugins |
| `/data/tokens` | Per-device token map (the live source of the device list) |

Without mounting, data is lost when the container is removed. Always mount `/data/tokens` so you don't lose tokens.

## Ports

| Port | Service | Note |
|---|---|---|
| `8080` (INGEST_PORT) | nginx OTLP ingest | Public; token-gated, wrong/missing token returns 401 |
| `3000` (GRAFANA_PORT) | nginx -> Grafana | Grafana login |
| `9090` | Prometheus | Bound to localhost only inside the container; debug-only |

Prometheus, Loki, and Grafana all listen on `127.0.0.1` inside the container; only nginx is the
externally exposed port, same as the multi-container design.

## Enable TLS inside the container (optional)

By default you should keep the container on HTTP and put TLS at a reverse proxy / load balancer
in front. If you want the container to terminate TLS itself:

```bash
docker run -d --name ccobs \
  -p 443:8443 -p 3000:3000 \
  -e TLS_ENABLED=true \
  -e INGEST_PORT=8443 \
  -e OTEL_DOMAIN=otel.example.com \
  -e OTEL_PUBLIC_ENDPOINT=https://otel.example.com \
  -e TLS_CERT=/certs/fullchain.pem \
  -e TLS_KEY=/certs/privkey.pem \
  -v /etc/letsencrypt/live/otel.example.com:/certs:ro \
  -v ccobs-prometheus:/data/prometheus \
  -v ccobs-loki:/data/loki \
  -v ccobs-grafana:/data/grafana \
  -v ccobs-tokens:/data/tokens \
  ghcr.io/trongnguyenbinh/claude-code-observability:latest
```

## Operations

```bash
docker logs -f ccobs                       # overall log (supervisord)
docker exec ccobs supervisorctl -c /etc/supervisor/conf.d/ccobs.conf status
docker exec ccobs cat /var/log/ccobs/otel-collector.log
docker restart ccobs
```

## Security

- The ingest endpoint is public but requires a per-device token; removing a machine blocks it immediately.
- Collector/Prometheus/Loki are not exposed to the internet, they listen on localhost inside the container.
- Grafana has login; tighten further with `OFFICE_IP` if you want a whitelist.
- By default Claude Code does NOT send prompt / tool content, only usage metrics + email. Don't
  enable `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` in production unless you truly need them.

## Comparing the two run modes

| | Multi-container (compose) | All-in-one (this image) |
|---|---|---|
| TLS | external nginx + certbot | external reverse proxy, or `TLS_ENABLED` inside the container |
| Scale | medium to large fleet, separated resources | small self-host, demo, single host |
| Device management | `scripts/add-device.sh` on the host | `docker exec ccobs ccobs add-device` |
| Updates | `docker compose pull` per image | `docker pull` a single image |
