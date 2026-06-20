🇻🇳 Tiếng Việt | [🇬🇧 English](README.en.md)

# claude-code-observability

Thu thập dữ liệu sử dụng Claude Code (chi phí, token, phiên làm việc và log) từ bất kỳ
số lượng máy nào về một nơi duy nhất rồi xem trên Grafana. Mỗi máy chạy Claude Code sẽ
đẩy metric của nó về một server trung tâm, nhờ vậy một dashboard duy nhất cho biết ai
đang dùng bao nhiêu.

Stack khá gọn: OTel Collector → Prometheus (metrics) + Loki (logs) → Grafana, tất cả
nằm sau nginx với TLS.

## Hai cách chạy

- **Multi-container (README này, `docker-compose.yml`)**: bốn service chạy thành các
  container riêng, nằm sau nginx + certbot có sẵn trên host. Hợp cho production.
- **All-in-one image**: tất cả (OTel Collector, Prometheus, Loki, Grafana, nginx) gói
  trong một container duy nhất, quản lý bằng supervisord. Chỉ cần `docker pull` +
  `docker run`, sau đó quản lý device bằng `docker exec <container> ccobs add-device ...`.
  Xem [docs/all-in-one-docker.md](docs/all-in-one-docker.md). Image:
  `ghcr.io/trongnguyenbinh/claude-code-observability:latest` (build bằng GitHub Actions).

## Trước khi deploy: thay các placeholder

Repo này đã được bóc sạch thông tin riêng tư, nên code chứa các placeholder dạng
`<...>`. Tìm và thay bằng giá trị của bạn: chúng xuất hiện trong `nginx/*.conf`,
`docker-compose.yml`, `satellite/install-otel.*`, `scripts/add-device.sh`, và trong tài
liệu.

| Placeholder | Ý nghĩa | Ví dụ |
|---|---|---|
| `<OTEL_DOMAIN>` | Domain máy dùng để đẩy metric (OTLP) | `otel.example.com` |
| `<GRAFANA_DOMAIN>` | Domain cho dashboard Grafana | `grafana.example.com` |
| `<SERVER_PUBLIC_IP>` | IP public của host trung tâm | `203.0.113.10` |
| `<OFFICE_IP>` | IP để allowlist nếu muốn hạn chế truy cập (nginx `allow`) | `198.51.100.20` |

Tên máy và tên user không cần sửa trong repo, bạn truyền vào lúc chạy
`add-device.sh` / `install-otel.*`.

## Cách hoạt động

```
Satellite machine (Claude Code, built-in OTLP exporter)
   │  HTTPS 443 + Bearer token (one token per machine)
   ▼
<OTEL_DOMAIN>  ── nginx (TLS) validates token ──► OTel Collector :4318 (internal)
                                                   ├─► Prometheus (metrics)
                                                   └─► Loki (logs)
                                                         ▼
<GRAFANA_DOMAIN> ── nginx (TLS) ──► Grafana :3000 (dashboard, login)
```

Điểm chính: stack chạy trên host trung tâm (`<SERVER_PUBLIC_IP>`) và tái dùng nginx +
certbot có sẵn. Collector, Prometheus, Loki và Grafana đều chỉ bind vào `localhost`;
nginx là tiến trình duy nhất lộ ra cổng 443. TLS dùng một chứng chỉ duy nhất tên
`claude-code-observability` (SAN của nó phủ cả hai domain), tự gia hạn bởi Let's Encrypt.

## Dashboard có gì

Dashboard "Claude Code Metrics (Prometheus)" gom mọi thứ thành các section, với thanh
filter ở trên cùng cho Organization / User / Machine / Model và một khoảng thời gian.

![Claude Code Metrics dashboard](docs/claude-code-metrics.png)

- **Overview**: số liệu tổng nhìn nhanh: Sessions, Users, Total Cost, Total Tokens,
  Commits, Pull Requests, Lines Added/Removed. Kèm Active Time (tách CLI và user),
  Tokens by Type (cacheCreation / cacheRead / input / output), Tool Decisions
  (accept/reject), và một gauge Cache hit ratio.
- **Leaderboards**: bảng xếp hạng: Top Devices by Cost, Top Devices by Tokens, Top
  Sessions by Cost; thêm ba biểu đồ donut: Cost by Model, Edit Decisions by Language,
  Sessions by Terminal.
- **Cost & Tokens**: chuỗi thời gian: Cost Over Time, Cost by Model, Token Usage by
  Type, Token Usage by Model, rồi Cost theo `query_source` và theo `effort`.
- **Activity & Productivity**: Active Time mỗi giờ, Lines of Code mỗi giờ
  (added/removed), và Tool Decisions theo thời gian.
- **Cost by Machine / User & Logs**: hai bảng xếp hạng chi phí theo từng máy và từng
  user trong khoảng thời gian đã chọn, cùng một panel Claude Code Logs lấy trực tiếp từ
  Loki.

Mọi thứ đều cập nhật theo khoảng thời gian đã chọn; đổi một filter là mọi panel cập
nhật theo.

## Trạng thái hiện tại (kiểm tra lần cuối 2026-06-15)

Ở lần kiểm tra gần nhất mọi thứ đều ổn: cả bốn container đang chạy, metric Claude Code
chảy về đều (cost, token theo loại, session, và active time tới được Prometheus, Grafana
truy vấn ra dữ liệu). TLS hợp lệ trên cả hai domain, và đường ingest enforce token đúng:
thiếu hoặc sai token trả 401, đúng token trả 200 về Collector. Một bài test end-to-end
qua `https://<OTEL_DOMAIN>` đã đưa được dữ liệu vào Prometheus, với label `machine` phân
biệt từng host.

Token map hiện đang trống (chưa thêm máy nào); thêm bằng `add-device` ở dưới.

## Vận hành server

```bash
cd projects/observability
sudo docker compose ps              # status
sudo docker compose up -d           # start (comes back automatically after reboot via restart: unless-stopped)
sudo docker compose logs otel-collector --tail=50
```

Mật khẩu admin Grafana nằm trong `.env` (chmod 600, không bao giờ commit). Đổi nó sau
lần đăng nhập đầu tiên. Mở dashboard tại `https://<GRAFANA_DOMAIN>` (user `admin`);
dashboard "Claude Code Usage" cho thấy cost, token, và session theo từng máy và từng
user, kèm Loki logs bên cạnh.

## Thêm / gỡ device (một token cho mỗi máy)

Chạy trên server, với quyền root:

```bash
cd projects/observability
sudo bash scripts/add-device.sh machine-name        # generate a token, write the nginx map, reload, print the installer for that machine
sudo bash scripts/revoke-device.sh machine-name     # remove it: that machine is blocked immediately
```

Khi `add-device` chạy xong nó in ra token, một đoạn snippet `settings.json`, và một lệnh
cài đặt một dòng sẵn để chạy cho đúng máy đó: copy sang máy và chạy.

## Cài máy satellite (một lần bấm)

Copy thư mục `satellite/` sang máy bạn muốn theo dõi, rồi chạy.

Ubuntu / Linux / macOS:
```bash
OTEL_TOKEN='tok_...' bash install-otel.sh
# optional: OTEL_MACHINE='machine-name' OTEL_USER='user-name'
```

Trên Windows, double-click `install-otel.bat`, hoặc chạy
`powershell -ExecutionPolicy Bypass -File install-otel.ps1 -Token 'tok_...'`.

Script ghi vào `~/.claude/settings.json` (giữ nguyên config sẵn có), điền
`machine=hostname` và `user=login`, rồi test kết nối và báo OK/Fail. Sau đó cứ mở Claude
Code như bình thường, dữ liệu được gửi tự động.

## Bảo mật

Endpoint ingest lộ ra public nhưng bắt buộc phải có token per-machine mới qua được, và
mỗi máy có thể revoke riêng; bản thân Collector không bao giờ lộ ra internet. Grafana
được bảo vệ bằng đăng nhập. Để siết chặt hơn, bỏ comment `allow <IP>; deny all;` trong
`nginx/grafana.conf` (allowlist theo IP văn phòng), rồi `sudo cp` vào đúng chỗ và chạy
`sudo nginx -t && sudo systemctl reload nginx`.

Mặc định Claude Code không gửi nội dung prompt hay tham số tool, chỉ gửi metric usage và
email của user. Đừng bật `OTEL_LOG_USER_PROMPTS` hay `OTEL_LOG_TOOL_DETAILS` trên
production trừ khi bạn thật sự cần.

## Đổi domain / môi trường

Domain được đặt ở ba nơi: `nginx/*.conf` (`server_name`), `satellite/install-otel.*`
(mặc định `OTEL_ENDPOINT`), và biến môi trường `GF_SERVER_ROOT_URL` của Grafana.

Tên metric Prometheus (đã xác nhận trên stack đang chạy):
`claude_code_cost_usage_USD_total`, `claude_code_token_usage_tokens_total` (có label
`type`), `claude_code_session_count_total`, `claude_code_active_time_seconds_total`.
Các label thường dùng để filter: `machine`, `user_id`, `user_email`, `model`,
`query_source`.
