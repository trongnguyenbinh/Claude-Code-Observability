# Setting up Claude Code usage monitoring

This guide has two parts: Part A builds the central server (the collect-and-display
stack: OTel Collector → Prometheus/Loki → Grafana, behind nginx TLS), and Part B
configures Claude Code on each machine so it sends usage back automatically.

A ready-made dashboard file, `claude-code-metrics-dashboard.json`, is included for
import into Grafana.

---

## Architecture overview

```
Satellite machine (Claude Code, built-in OTLP exporter)
   │  HTTPS 443 + Bearer token (one token per machine)
   ▼
<OTEL_DOMAIN> ── nginx (TLS) validates token ──► OTel Collector :4318 (internal)
                                                 ├─► Prometheus  (metrics, scrape :8889)
                                                 └─► Loki        (logs, OTLP /otlp)
                                                       ▼
<GRAFANA_DOMAIN> ── nginx (TLS) ──► Grafana :3000 (dashboard, login)
```

Every container binds to `localhost` only; nginx (on the host) is the sole process
exposed on port 443. The ingest endpoint is public but gated by a per-machine token,
so any machine can be revoked individually. Note that by default Claude Code does not
send prompt content or tool arguments — only usage metrics and the user's email.

---

## Part A — Build the central server

### A0. Prerequisites

A Linux host with Docker + Docker Compose and nginx + certbot already installed (this
guide reuses the host's nginx). Point two DNS records at the host: `<OTEL_DOMAIN>` for
ingest and `<GRAFANA_DOMAIN>` for the dashboard. Open ports 80/443 to the internet
(required for TLS and ingest); keep 3000/4318/9090 closed.

### A1. Get the source and set the password

```bash
cd projects/observability
cp .env.example .env
# Edit .env and set a strong GF_ADMIN_PASSWORD (this file is gitignored)
chmod 600 .env
```

### A2. Obtain a TLS certificate (one cert for both domains)

```bash
sudo certbot certonly --webroot -w /var/www/html \
  -d <OTEL_DOMAIN> -d <GRAFANA_DOMAIN> \
  --cert-name claude-code-observability
```

This creates `/etc/letsencrypt/live/claude-code-observability/{fullchain,privkey}.pem`;
certbot handles renewal.

### A3. Install the nginx vhosts (on the host)

Copy the three files in `nginx/` into `/etc/nginx/conf.d/`:

```bash
sudo cp nginx/otel.conf            /etc/nginx/conf.d/
sudo cp nginx/grafana.conf         /etc/nginx/conf.d/
sudo cp nginx/00-otel-tokens.conf  /etc/nginx/conf.d/   # token map, empty to begin with
sudo nginx -t && sudo systemctl reload nginx
```

What each file does: `otel.conf` accepts only `/v1/*` paths and requires a valid token
(`map $otel_device`) before proxying to `127.0.0.1:4318`, returning 401 otherwise.
`00-otel-tokens.conf` is the `Bearer token → machine name` map — don't edit it by hand;
use the `add-device.sh` / `revoke-device.sh` scripts. `grafana.conf` proxies to
`127.0.0.1:3000`; to restrict it, uncomment `allow <IP>; deny all;` (an office-IP
allowlist) and reload.

### A4. Start the stack

```bash
sudo docker compose up -d
sudo docker compose ps        # you should see 4 containers: otel-collector, prometheus, loki, grafana
```

The stack uses `restart: unless-stopped`, so it comes back automatically after a reboot.
The four components (see `docker-compose.yml` for details):

| Service | Image | Port (localhost) | Role |
|---|---|---|---|
| otel-collector | otel/opentelemetry-collector-contrib:0.119.0 | 4318 | Receives OTLP, forwards metrics→Prometheus, logs→Loki |
| prometheus | prom/prometheus:v3.1.0 | 9090 | Stores metrics (90-day retention) |
| loki | grafana/loki:3.3.2 | (internal) | Stores logs |
| grafana | grafana/grafana:11.4.0 | 3000 | Dashboard + login |

### A5. Log in to Grafana and import the dashboard

Open `https://<GRAFANA_DOMAIN>`, user `admin`, with the `GF_ADMIN_PASSWORD` from
`.env` — change the password immediately after logging in. The Prometheus and Loki
datasources are already provisioned (`grafana/provisioning/datasources/`), so no
manual setup is needed.

Import the dashboard: **Dashboards → New → Import → Upload JSON**, choose
`docs/claude-code-metrics-dashboard.json`, select the Prometheus datasource, and
import. The dashboard is named "Claude Code Metrics (Prometheus)" and includes filters
for Organization / User / Machine / Model, plus two leaderboard panels — "Top Devices
by Cost" and "Top Devices by Tokens" — ranking the top 10 machines.

### A6. Quick check on the server

```bash
# Is the Collector receiving data?
sudo docker compose logs otel-collector --tail=50
# Does Prometheus have Claude Code metrics yet?
curl -s 'http://localhost:9090/api/v1/query?query=claude_code_session_count_total' | head
```

The real metric names to query: `claude_code_cost_usage_USD_total`,
`claude_code_token_usage_tokens_total` (`type` label), `claude_code_session_count_total`,
`claude_code_active_time_seconds_total`. Common labels: `machine`, `user_id`,
`user_email`, `model`, `query_source`, `effort`.

---

## Part B — Configure a satellite machine

Each machine needs its own token (issued on the server), then Claude Code is configured
to push telemetry back.

### B1. Issue a token (run on the server, as root)

```bash
cd projects/observability
sudo bash scripts/add-device.sh machine-name      # e.g. dev-01, laptop-02, server-01
```

The script handles everything: it generates a `tok_<name>_<random>` token, writes it
into `00-otel-tokens.conf`, runs `nginx -t` and reloads, and finally prints the token,
a `settings.json` snippet, and a one-click command for that machine.

Remove a machine (blocked immediately):

```bash
sudo bash scripts/revoke-device.sh machine-name
```

### B2. Install on the satellite machine

Copy the `satellite/` folder to the machine and run it.

**Ubuntu / Linux / macOS:**
```bash
OTEL_TOKEN='tok_...' bash install-otel.sh
# optional: OTEL_MACHINE='machine-name' OTEL_USER='user-name' OTEL_ENDPOINT='https://<OTEL_DOMAIN>'
```

**Windows:** double-click `install-otel.bat`, or:
```powershell
powershell -ExecutionPolicy Bypass -File install-otel.ps1 -Token 'tok_...' -Machine 'machine-name'
```

The script writes `~/.claude/settings.json` (merging with your existing config if `jq`
is present), fills in `machine`/`user`, then tests the connection: 200/400/415 means the
server was reached and the token is valid, 401 means a bad token, and 000 means the
server is unreachable. Then open Claude Code and data is sent automatically.

### B3. Manual configuration (if not using the script)

Add to `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://<OTEL_DOMAIN>",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer tok_...",
    "OTEL_RESOURCE_ATTRIBUTES": "machine=machine-name,user.id=user-name"
  }
}
```

`machine` is the label that identifies the MACHINE (the "Machine" dropdown on the
dashboard); `user.id` identifies the USER. Do not enable `OTEL_LOG_USER_PROMPTS` or
`OTEL_LOG_TOOL_DETAILS` in production — they cause prompt and tool content to be sent.

### B4. Verify the data arrives

Open Claude Code, run a few commands, then on the server:

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (machine)(claude_code_cost_usage_USD_total)'
```

If `machine=machine-name` shows a value, you're set. The Grafana "Machine" dropdown
will also list that machine (within the selected time range).

A common false alarm: the `claude_code_session_count_total` metric is only emitted when
a new session opens. A machine configured mid-session may not show a session count until
a new Claude window is opened.

---

## Operations & security (summary)

For status / restart: `sudo docker compose ps`, `sudo docker compose up -d`,
`sudo docker compose restart grafana`. View logs with
`sudo docker compose logs <service> --tail=50`.

On security: each machine's token can be revoked individually, the Collector is never
exposed to the internet, and Grafana is protected by login (tighten further with an IP
allowlist). The `.env` file holding the Grafana password is not committed (gitignored).
Provisioned dashboards live in `grafana/dashboards/` (mounted read-only); the "Metrics"
dashboard is currently managed via import, so it's stored in Grafana's database, with a
backup at `docs/claude-code-metrics-dashboard.json`.

## Changing domains / environment

Domains are set in `nginx/*.conf` (`server_name`), `satellite/install-otel.*` (the
default `OTEL_ENDPOINT`), and `docker-compose.yml` (`GF_SERVER_ROOT_URL`). The
certificate is a single one named `claude-code-observability`, with both domains in its
SAN.
