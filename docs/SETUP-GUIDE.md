🇻🇳 Tiếng Việt | [🇬🇧 English](SETUP-GUIDE.en.md)

# Thiết lập giám sát mức dùng Claude Code

Hướng dẫn này có hai phần: Phần A dựng server trung tâm (stack thu thập và hiển thị:
OTel Collector → Prometheus/Loki → Grafana, nằm sau nginx TLS), và Phần B cấu hình
Claude Code trên từng máy để nó tự gửi dữ liệu sử dụng về.

Một file dashboard dựng sẵn, `claude-code-metrics-dashboard.json`, đã được kèm theo để
import vào Grafana.

---

## Tổng quan kiến trúc

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

Mọi container chỉ bind vào `localhost`; nginx (trên host) là tiến trình duy nhất lộ ra
cổng 443. Endpoint ingest public nhưng được khoá bằng token per-machine, nên có thể
revoke từng máy riêng. Lưu ý mặc định Claude Code không gửi nội dung prompt hay tham số
tool, chỉ gửi metric usage và email của user.

---

## Phần A: Dựng server trung tâm

### A0. Yêu cầu

Một host Linux đã cài Docker + Docker Compose và nginx + certbot (hướng dẫn này tái dùng
nginx của host). Trỏ hai bản ghi DNS về host: `<OTEL_DOMAIN>` cho ingest và
`<GRAFANA_DOMAIN>` cho dashboard. Mở cổng 80/443 ra internet (cần cho TLS và ingest);
giữ 3000/4318/9090 đóng.

### A1. Lấy mã nguồn và đặt mật khẩu

```bash
cd projects/observability
cp .env.example .env
# Edit .env and set a strong GF_ADMIN_PASSWORD (this file is gitignored)
chmod 600 .env
```

### A2. Lấy chứng chỉ TLS (một cert cho cả hai domain)

```bash
sudo certbot certonly --webroot -w /var/www/html \
  -d <OTEL_DOMAIN> -d <GRAFANA_DOMAIN> \
  --cert-name claude-code-observability
```

Lệnh này tạo `/etc/letsencrypt/live/claude-code-observability/{fullchain,privkey}.pem`;
certbot lo việc gia hạn.

### A3. Cài nginx vhost (trên host)

Copy ba file trong `nginx/` vào `/etc/nginx/conf.d/`:

```bash
sudo cp nginx/otel.conf            /etc/nginx/conf.d/
sudo cp nginx/grafana.conf         /etc/nginx/conf.d/
sudo cp nginx/00-otel-tokens.conf  /etc/nginx/conf.d/   # token map, empty to begin with
sudo nginx -t && sudo systemctl reload nginx
```

Mỗi file làm gì: `otel.conf` chỉ chấp nhận path `/v1/*` và bắt buộc token hợp lệ
(`map $otel_device`) trước khi proxy tới `127.0.0.1:4318`, ngược lại trả 401.
`00-otel-tokens.conf` là map `Bearer token → tên máy`, đừng sửa tay; hãy dùng script
`add-device.sh` / `revoke-device.sh`. `grafana.conf` proxy tới `127.0.0.1:3000`; để hạn
chế, bỏ comment `allow <IP>; deny all;` (allowlist theo IP văn phòng) rồi reload.

### A4. Khởi động stack

```bash
sudo docker compose up -d
sudo docker compose ps        # you should see 4 containers: otel-collector, prometheus, loki, grafana
```

Stack dùng `restart: unless-stopped`, nên tự bật lại sau khi reboot. Bốn thành phần (xem
`docker-compose.yml` để biết chi tiết):

| Service | Image | Port (localhost) | Vai trò |
|---|---|---|---|
| otel-collector | otel/opentelemetry-collector-contrib:0.119.0 | 4318 | Nhận OTLP, chuyển metric→Prometheus, log→Loki |
| prometheus | prom/prometheus:v3.1.0 | 9090 | Lưu metric (giữ 90 ngày) |
| loki | grafana/loki:3.3.2 | (internal) | Lưu log |
| grafana | grafana/grafana:11.4.0 | 3000 | Dashboard + đăng nhập |

### A5. Đăng nhập Grafana và import dashboard

Mở `https://<GRAFANA_DOMAIN>`, user `admin`, với `GF_ADMIN_PASSWORD` lấy từ `.env`, đổi
mật khẩu ngay sau khi đăng nhập. Hai datasource Prometheus và Loki đã được provision sẵn
(`grafana/provisioning/datasources/`), nên không phải cấu hình tay.

Import dashboard: **Dashboards → New → Import → Upload JSON**, chọn
`docs/claude-code-metrics-dashboard.json`, chọn datasource Prometheus, rồi import.
Dashboard tên "Claude Code Metrics (Prometheus)" và có sẵn filter cho
Organization / User / Machine / Model, cùng hai panel leaderboard: "Top Devices by Cost"
và "Top Devices by Tokens", xếp hạng 10 máy cao nhất.

### A6. Kiểm tra nhanh trên server

```bash
# Is the Collector receiving data?
sudo docker compose logs otel-collector --tail=50
# Does Prometheus have Claude Code metrics yet?
curl -s 'http://localhost:9090/api/v1/query?query=claude_code_session_count_total' | head
```

Tên metric thật để truy vấn: `claude_code_cost_usage_USD_total`,
`claude_code_token_usage_tokens_total` (label `type`),
`claude_code_session_count_total`, `claude_code_active_time_seconds_total`. Các label
thường dùng: `machine`, `user_id`, `user_email`, `model`, `query_source`, `effort`.

---

## Phần B: Cấu hình máy satellite

Mỗi máy cần token riêng (cấp trên server), rồi Claude Code được cấu hình để đẩy telemetry
về.

### B1. Cấp token (chạy trên server, với quyền root)

```bash
cd projects/observability
sudo bash scripts/add-device.sh machine-name      # e.g. dev-01, laptop-02, server-01
```

Script lo hết: nó sinh token `tok_<name>_<random>`, ghi vào `00-otel-tokens.conf`, chạy
`nginx -t` và reload, rồi cuối cùng in ra token, một đoạn snippet `settings.json`, và một
lệnh 1-click cho đúng máy đó.

Gỡ một máy (chặn ngay lập tức):

```bash
sudo bash scripts/revoke-device.sh machine-name
```

### B2. Cài trên máy satellite

Copy thư mục `satellite/` sang máy rồi chạy.

**Ubuntu / Linux / macOS:**
```bash
OTEL_TOKEN='tok_...' bash install-otel.sh
# optional: OTEL_MACHINE='machine-name' OTEL_USER='user-name' OTEL_ENDPOINT='https://<OTEL_DOMAIN>'
```

**Windows:** double-click `install-otel.bat`, hoặc:
```powershell
powershell -ExecutionPolicy Bypass -File install-otel.ps1 -Token 'tok_...' -Machine 'machine-name'
```

Script ghi `~/.claude/settings.json` (merge với config sẵn có nếu có `jq`), điền
`machine`/`user`, rồi test kết nối: 200/400/415 nghĩa là tới được server và token hợp lệ,
401 nghĩa là token sai, và 000 nghĩa là không tới được server. Sau đó mở Claude Code và
dữ liệu được gửi tự động.

### B3. Cấu hình thủ công (nếu không dùng script)

Thêm vào `~/.claude/settings.json`:

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

`machine` là label nhận diện MÁY (dropdown "Machine" trên dashboard); `user.id` nhận
diện USER. Đừng bật `OTEL_LOG_USER_PROMPTS` hay `OTEL_LOG_TOOL_DETAILS` trên production,
chúng khiến nội dung prompt và tool bị gửi đi.

### B4. Xác minh dữ liệu về tới nơi

Mở Claude Code, chạy vài lệnh, rồi trên server:

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (machine)(claude_code_cost_usage_USD_total)'
```

Nếu `machine=machine-name` hiện ra một giá trị thì xong. Dropdown "Machine" của Grafana
cũng sẽ liệt kê máy đó (trong khoảng thời gian đã chọn).

Một báo động giả thường gặp: metric `claude_code_session_count_total` chỉ được phát ra
khi mở một session mới. Một máy được cấu hình giữa chừng session có thể chưa hiện session
count cho tới khi mở một cửa sổ Claude mới.

---

## Vận hành & bảo mật (tóm tắt)

Để xem trạng thái / restart: `sudo docker compose ps`, `sudo docker compose up -d`,
`sudo docker compose restart grafana`. Xem log bằng
`sudo docker compose logs <service> --tail=50`.

Về bảo mật: token của mỗi máy có thể revoke riêng, Collector không bao giờ lộ ra
internet, và Grafana được bảo vệ bằng đăng nhập (siết thêm bằng IP allowlist). File
`.env` chứa mật khẩu Grafana không được commit (gitignored). Dashboard provision nằm ở
`grafana/dashboards/` (mount read-only); dashboard "Metrics" hiện được quản lý qua
import, nên nó lưu trong database của Grafana, kèm một bản backup ở
`docs/claude-code-metrics-dashboard.json`.

## Đổi domain / môi trường

Domain được đặt ở `nginx/*.conf` (`server_name`), `satellite/install-otel.*` (mặc định
`OTEL_ENDPOINT`), và `docker-compose.yml` (`GF_SERVER_ROOT_URL`). Chứng chỉ là một cert
duy nhất tên `claude-code-observability`, với cả hai domain nằm trong SAN của nó.
