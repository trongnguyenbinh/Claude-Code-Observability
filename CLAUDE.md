# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

A self-hosted stack that collects **Claude Code usage** (cost / tokens / sessions / logs) from a bunch of satellite machines (Ubuntu/Windows/macOS) and pulls it into one central server so you can see who's using what on a Grafana dashboard.

Flow:
```
Satellite (Claude Code built-in OTLP exporter)
  │ HTTPS 443 + Bearer token (one token per device)
  ▼
<OTEL_DOMAIN>  ── nginx (TLS, checks token) ──► OTel Collector :4318
                                                 ├─► Prometheus (metrics, scrape :8889)
                                                 └─► Loki (logs, OTLP /otlp)
                                                       ▼
<GRAFANA_DOMAIN> ── nginx (TLS) ──► Grafana :3000 (dashboard + login)
```

All containers publish to **localhost only**; the host nginx (reused, not in compose) terminates TLS and exposes 443.

## Layout

| Path | Role |
|---|---|
| `docker-compose.yml` | 4 services: otel-collector, prometheus, loki, grafana |
| `otel-collector/config.yaml` | OTLP in → Prometheus metrics + Loki logs |
| `prometheus/prometheus.yml` | scrapes collector `:8889` |
| `loki/loki-config.yaml` | single-binary Loki, filesystem store, 90d retention |
| `grafana/provisioning/` | datasources (Prom+Loki) + dashboard provider |
| `nginx/otel.conf` | ingest vhost — only `/v1/*`, requires valid token (`map $otel_device`) → 401 if missing |
| `nginx/grafana.conf` | dashboard vhost → Grafana, optional office-IP whitelist |
| `nginx/00-otel-tokens.conf` | token→device map. **Never edit by hand** — use scripts |
| `scripts/add-device.sh` / `revoke-device.sh` | issue / revoke per-device token (run on server as root) |
| `satellite/install-otel.{sh,ps1,bat}` | 1-click client config writer for `~/.claude/settings.json` |
| `docs/SETUP-GUIDE.md` | full server + satellite setup guide |
| `docs/claude-code-metrics-dashboard.json` | Grafana dashboard backup |

## Placeholders — IMPORTANT

This repo is scrubbed of private info. Real values are **not** committed; they appear as angle-bracket tokens:

- `<OTEL_DOMAIN>` — ingest domain (e.g. `otel.example.com`)
- `<GRAFANA_DOMAIN>` — dashboard domain (e.g. `grafana.example.com`)
- `<SERVER_PUBLIC_IP>` — central host public IP
- `<OFFICE_IP>` — optional nginx `allow` whitelist IP

When editing, **keep these tokens** unless the user gives a real value. Do **not** invent or re-introduce concrete IPs, domains, hostnames, usernames, or device names. Device/user identities are supplied at runtime via `add-device.sh` / `install-otel.*`, never hardcoded.

## Secrets — do NOT commit

`.gitignore` already excludes: `.env` (Grafana admin password), `nginx/otel-tokens.map`, `devices/*.token`, `satellite/dist/`. Only `.env.example` (placeholder password) is committed. Never write real tokens or passwords into tracked files.

## Real metric names (verified)

`claude_code_cost_usage_USD_total`, `claude_code_token_usage_tokens_total` (label `type`), `claude_code_session_count_total`, `claude_code_active_time_seconds_total`. Useful labels: `machine`, `user_id`, `user_email`, `model`, `query_source`, `effort`.

## Common ops (run on server, root)

```bash
sudo docker compose ps
sudo docker compose up -d
sudo docker compose logs otel-collector --tail=50
sudo bash scripts/add-device.sh <device-name>     # issue token + print client config
sudo bash scripts/revoke-device.sh <device-name>  # block device immediately
```

## Notes

- Docs/comments are in Vietnamese — match that when editing existing prose.
- Claude Code does **not** send prompt/tool content by default — only usage metrics + email. Do not enable `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` on prod.
