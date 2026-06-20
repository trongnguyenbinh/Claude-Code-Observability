🇻🇳 Tiếng Việt | [🇬🇧 English](CLAUDE.en.md)

# CLAUDE.md

Hướng dẫn cho Claude Code khi làm việc trong repo này.

## Đây là gì

Một stack tự host, thu thập **dữ liệu sử dụng Claude Code** (cost / token / session /
log) từ nhiều máy satellite (Ubuntu/Windows/macOS) rồi gom về một server trung tâm để
xem ai đang dùng cái gì trên dashboard Grafana.

Luồng:
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

Tất cả container đều publish **chỉ vào localhost**; nginx trên host (tái dùng, không
nằm trong compose) terminate TLS và lộ ra cổng 443.

## Bố cục

| Path | Vai trò |
|---|---|
| `docker-compose.yml` | 4 service: otel-collector, prometheus, loki, grafana |
| `otel-collector/config.yaml` | OTLP vào → Prometheus metrics + Loki logs |
| `prometheus/prometheus.yml` | scrape collector `:8889` |
| `loki/loki-config.yaml` | Loki single-binary, lưu filesystem, giữ 90 ngày |
| `grafana/provisioning/` | datasource (Prom+Loki) + dashboard provider |
| `nginx/otel.conf` | vhost ingest, chỉ `/v1/*`, cần token hợp lệ (`map $otel_device`) → 401 nếu thiếu |
| `nginx/grafana.conf` | vhost dashboard → Grafana, tuỳ chọn whitelist IP văn phòng |
| `nginx/00-otel-tokens.conf` | map token→device. **Không bao giờ sửa tay**, dùng script |
| `scripts/add-device.sh` / `revoke-device.sh` | cấp / thu hồi token per-device (chạy trên server với quyền root) |
| `satellite/install-otel.{sh,ps1,bat}` | trình ghi config client 1-click cho `~/.claude/settings.json` |
| `docs/SETUP-GUIDE.md` | hướng dẫn setup đầy đủ server + satellite |
| `docs/claude-code-metrics-dashboard.json` | bản backup dashboard Grafana |

## Placeholder: QUAN TRỌNG

Repo này đã bóc sạch thông tin riêng tư. Giá trị thật **không** được commit; chúng xuất
hiện dưới dạng token trong dấu ngoặc nhọn:

- `<OTEL_DOMAIN>`: domain ingest (ví dụ `otel.example.com`)
- `<GRAFANA_DOMAIN>`: domain dashboard (ví dụ `grafana.example.com`)
- `<SERVER_PUBLIC_IP>`: IP public của host trung tâm
- `<OFFICE_IP>`: IP whitelist tuỳ chọn cho nginx `allow`

Khi sửa, **giữ nguyên các token này** trừ khi user cung cấp giá trị thật. **Đừng** bịa
hay đưa lại IP, domain, hostname, username, hay tên device cụ thể. Danh tính device/user
được cấp lúc runtime qua `add-device.sh` / `install-otel.*`, không bao giờ hardcode.

## Secret: KHÔNG commit

`.gitignore` đã loại trừ: `.env` (mật khẩu admin Grafana), `nginx/otel-tokens.map`,
`devices/*.token`, `satellite/dist/`. Chỉ `.env.example` (mật khẩu placeholder) được
commit. Không bao giờ ghi token hay mật khẩu thật vào file được track.

## Tên metric thật (đã xác minh)

`claude_code_cost_usage_USD_total`, `claude_code_token_usage_tokens_total` (label
`type`), `claude_code_session_count_total`, `claude_code_active_time_seconds_total`.
Các label hữu ích: `machine`, `user_id`, `user_email`, `model`, `query_source`,
`effort`.

## Lệnh vận hành thường dùng (chạy trên server, root)

```bash
sudo docker compose ps
sudo docker compose up -d
sudo docker compose logs otel-collector --tail=50
sudo bash scripts/add-device.sh <device-name>     # issue token + print client config
sudo bash scripts/revoke-device.sh <device-name>  # block device immediately
```

## Ghi chú

- Tài liệu/comment dùng tiếng Việt, bám theo đó khi sửa prose có sẵn.
- Claude Code mặc định **không** gửi nội dung prompt/tool, chỉ gửi metric usage + email.
  Đừng bật `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` trên prod.
