# All-in-one Docker image

Cách chạy toàn bộ stack observability (OTel Collector + Prometheus + Loki + Grafana + nginx)
trong MỘT container duy nhất. Bạn chỉ cần `docker pull` rồi `docker run`, sau đó quản lý
device/token bằng `docker exec ... ccobs`.

Đây là phương án bổ sung, KHÔNG thay thế bản multi-container. Bạn vẫn có thể dùng
`docker-compose.yml` như cũ (xem `README.md`). Hai lựa chọn:

- Multi-container (compose): tách service, hợp cho production có sẵn nginx + certbot ngoài.
- All-in-one (image này): gọn, một lệnh chạy được ngay, hợp cho thử nhanh / self-host nhỏ.

## Image

```
ghcr.io/trongnguyenbinh/claude-code-observability:latest
```

Image build và push tự động bằng GitHub Actions (`.github/workflows/docker-image.yml`).
Không build trên máy dev; cứ pull bản CI đã build.

## Chạy nhanh (no-TLS, localhost)

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

Sau đó:

- Grafana: http://localhost:3000 (user `admin`, mật khẩu là `GF_ADMIN_PASSWORD`). Dashboard
  "Claude Code Metrics" đã được nạp sẵn.
- Ingest OTLP (cho máy satellite): http://localhost:8080 (cần token, xem phần dưới).
- Health check ingest: `curl http://localhost:8080/healthz`.

## Thêm / gỡ / liệt kê device

Quản lý device qua `ccobs` bên trong container (logic lấy từ `scripts/add-device.sh` và
`scripts/revoke-device.sh`, giữ nguyên cơ chế một token cho mỗi máy):

```bash
# Tạo token cho một máy (kèm user tuỳ chọn). In ra token + snippet settings.json + lệnh cài.
docker exec ccobs ccobs add-device macbook-cua-edward edward

# Gỡ device theo TÊN máy ...
docker exec ccobs ccobs revoke-device macbook-cua-edward
# ... hoặc gỡ theo TOKEN
docker exec ccobs ccobs revoke-device tok_macbook_xxxxxxxxxxxxxxxx

# Liệt kê device đang đăng ký
docker exec ccobs ccobs list-devices

# Xem endpoint, đường dẫn token map, trạng thái từng service
docker exec ccobs ccobs status
```

`add-device` in ra block JSON để dán vào `~/.claude/settings.json` của máy cần theo dõi, kèm
lệnh chạy `satellite/install-otel.sh`. Token map được lưu bền trên volume `/data/tokens`, nên
device vẫn còn sau khi restart container. Mỗi lần thêm/gỡ, nginx tự reload nên có hiệu lực ngay.

Lưu ý endpoint trong snippet: mặc định là `http://localhost:8080`. Khi deploy thật, set
`OTEL_PUBLIC_ENDPOINT` (ví dụ `https://otel.example.com`) để snippet in đúng địa chỉ public.

## Cài máy satellite

Copy thư mục `satellite/` sang máy cần theo dõi rồi chạy, dùng đúng token và endpoint mà
`add-device` in ra:

```bash
OTEL_TOKEN='tok_...' OTEL_MACHINE='ten-may' OTEL_ENDPOINT='http://server:8080' bash install-otel.sh
```

## Biến môi trường (ENV)

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `GF_ADMIN_USER` | `admin` | User admin Grafana |
| `GF_ADMIN_PASSWORD` | `changeme` | Mật khẩu admin Grafana (đổi ngay) |
| `GF_ROOT_URL` | `http://localhost:<GRAFANA_PORT>/` | `root_url` của Grafana (đặt domain thật khi deploy) |
| `INGEST_PORT` | `8080` | Cổng nginx nhận OTLP (có token) |
| `GRAFANA_PORT` | `3000` | Cổng nginx phục vụ Grafana |
| `OTEL_DOMAIN` | `_` | `server_name` cho vhost ingest (`_` = match mọi host) |
| `GRAFANA_DOMAIN` | `_` | `server_name` cho vhost Grafana |
| `OTEL_PUBLIC_ENDPOINT` | `http://localhost:<INGEST_PORT>` | Endpoint public dùng trong snippet `add-device` |
| `OFFICE_IP` | (trống) | Nếu set, Grafana chỉ cho IP này truy cập (`allow/deny`) |
| `PROM_RETENTION` | `90d` | Thời gian giữ metrics Prometheus |
| `LOKI_RETENTION` | `90d` | Thời gian giữ logs Loki |
| `TLS_ENABLED` | `false` | Bật TLS trong container (xem dưới) |
| `TLS_CERT` | `/certs/fullchain.pem` | Đường dẫn cert khi `TLS_ENABLED=true` |
| `TLS_KEY` | `/certs/privkey.pem` | Đường dẫn private key khi `TLS_ENABLED=true` |

## Volumes (cần mount để giữ dữ liệu)

| Mount trong container | Nội dung |
|---|---|
| `/data/prometheus` | TSDB metrics |
| `/data/loki` | Chunks + index logs |
| `/data/grafana` | SQLite Grafana, session, plugin |
| `/data/tokens` | Token map per-device (nguồn sống của danh sách device) |

Không mount thì dữ liệu mất khi xoá container. Luôn mount `/data/tokens` để không mất token.

## Cổng (ports)

| Cổng | Service | Ghi chú |
|---|---|---|
| `8080` (INGEST_PORT) | nginx ingest OTLP | Public; chặn bằng token, sai/thiếu token trả 401 |
| `3000` (GRAFANA_PORT) | nginx -> Grafana | Đăng nhập Grafana |
| `9090` | Prometheus | Chỉ bind localhost trong container; chỉ để debug |

Prometheus, Loki, Grafana đều nghe `127.0.0.1` bên trong container; chỉ nginx là cổng ra
bên ngoài, giống thiết kế bản multi-container.

## Bật TLS trong container (tuỳ chọn)

Mặc định nên để container chạy HTTP và đặt TLS ở reverse proxy / load balancer phía trước.
Nếu muốn container tự terminate TLS:

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

## Vận hành

```bash
docker logs -f ccobs                       # log tổng (supervisord)
docker exec ccobs supervisorctl -c /etc/supervisor/conf.d/ccobs.conf status
docker exec ccobs cat /var/log/ccobs/otel-collector.log
docker restart ccobs
```

## Bảo mật

- Endpoint ingest public nhưng bắt buộc token per-device; gỡ một máy là chặn ngay máy đó.
- Collector/Prometheus/Loki không lộ ra internet, chỉ nghe localhost trong container.
- Grafana có đăng nhập; siết thêm bằng `OFFICE_IP` nếu muốn whitelist.
- Claude Code mặc định KHÔNG gửi nội dung prompt / tool, chỉ gửi metric usage + email. Đừng
  bật `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` trên production trừ khi thật sự cần.

## So sánh hai cách chạy

| | Multi-container (compose) | All-in-one (image này) |
|---|---|---|
| TLS | nginx + certbot ngoài | reverse proxy ngoài, hoặc `TLS_ENABLED` trong container |
| Quy mô | fleet vừa đến lớn, tách tài nguyên | self-host nhỏ, demo, một host |
| Quản lý device | `scripts/add-device.sh` trên host | `docker exec ccobs ccobs add-device` |
| Cập nhật | `docker compose pull` từng image | `docker pull` một image |
