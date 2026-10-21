# supervisor

**1 container Debian chạy systemd làm PID 1.** Service quản bằng `systemctl`,
cloudflared chạy trong cùng container.

| Thiết lập | Giá trị |
|---|---|
| Base image | `debian:13-slim` (trixie) |
| PID 1 | `systemd` (`/sbin/init`) |
| CPU limit | 4 (`cpu.max = 400000 100000`) |
| RAM limit | 6 GiB (swap tắt) |
| Restart policy | `always` |
| privileged | **không** (chỉ `SYS_ADMIN` + `apparmor=unconfined`) |
| Network | `appnet` — `172.28.0.0/24` |
| IP tĩnh | `172.28.0.10` |
| Port | `2222 -> 22` (sshd) |
| cloudflared | 2026.10.2, `.deb` chính thức, pin + verify sha256 |
| Service sẵn | `ssh`, `cron`, `app` (enabled) · `cloudflared` (cần token) |

## Lệnh

```bash
docker compose up -d --build
docker compose logs -f
docker compose down

docker exec supervisor systemctl status
docker exec supervisor systemctl is-system-running      # phải là "running"
docker exec supervisor systemctl --failed
docker exec supervisor systemctl restart app
docker exec supervisor journalctl -u app -f
```

## Yêu cầu để systemd chạy trong container

Đã test trên host này (cgroup v2, AppArmor bật). **Thiếu bất kỳ dòng nào -> container exit 255:**

```yaml
cap_add: [SYS_ADMIN]
security_opt: [apparmor=unconfined]
cgroup: host
tmpfs: [/run, /run/lock, /tmp]
volumes: ["/sys/fs/cgroup:/sys/fs/cgroup:rw", "./secrets:/etc/cloudflared"]
init: false
stop_signal: SIGRTMIN+3
```

Kết quả test từng biến thể:

| Cấu hình | Kết quả |
|---|---|
| `SYS_ADMIN` + tmpfs + cgroup rw | ❌ exit 255 |
| `privileged: true` | ⚠️ boot được nhưng `degraded` |
| `SYS_ADMIN` + `apparmor=unconfined` + `cgroupns=host` | ✅ `running` |
| thêm `seccomp=unconfined` | ✅ (không cần) |
| `cgroupns=private` | ❌ exit 255 — **phải** là `host` |

- **`apparmor=unconfined` là cái quyết định.** Host bật AppArmor, profile
  `docker-default` chặn systemd. Không cần `privileged`.
- **`init: false`** — systemd *là* init, không chồng thêm `docker-init`.
- **`stop_signal: SIGRTMIN+3`** — systemd shutdown bằng signal này, không phải
  SIGTERM. Thiếu -> `docker stop` phải chờ hết `stop_grace_period` rồi SIGKILL.
- `cgroup: host` + `/sys/fs/cgroup:rw` cho container thấy cgroup của host.
  Limits của chính nó **vẫn enforce** (đã verify `cpu.max`), nhưng đây là quyền
  rộng hơn mặc định — đừng chạy code không tin cậy trong container này.

## Thêm service

Tạo `units/<ten>.service`, rồi:

```bash
docker compose up -d --build
docker exec supervisor systemctl enable --now <ten>
```

```ini
[Unit]
Description=My service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/app
ExecStart=/app/myservice --flag
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

> `units/` cũng được mount read-only vào `/etc/systemd/system/custom` để xem
> nhanh, nhưng unit **có hiệu lực** là bản `COPY` vào image lúc build.

## cloudflared

Binary trong image, chạy như unit systemd trong **cùng container**. Chưa enable
sẵn vì cần token trước.

`./secrets` được mount **read-write** vào `/etc/cloudflared`, nên cả hai cách đều được.

Cách A — ghi token từ host:

```bash
printf '%s' '<TUNNEL_TOKEN>' > secrets/token
chmod 600 secrets/token
docker exec supervisor systemctl enable --now cloudflared
```

Cách B — dùng chính lệnh của cloudflared trong container:

```bash
docker exec supervisor cloudflared service install '<TUNNEL_TOKEN>'
docker exec supervisor systemctl enable --now cloudflared
```

Token ghi kiểu nào cũng rơi ra `./secrets/token` trên host nên **sống qua rebuild**.

```bash
docker exec supervisor journalctl -u cloudflared -f
```

> Mount này **không** `:ro`. Nếu để `:ro`, `cloudflared service install` sẽ báo
> `cannot create /etc/cloudflared/token: Read-only file system`.
> `service install` cũng tự validate token (base64 JSON) và **xoá file token cũ**
> nếu token mới không hợp lệ.

Hai chi tiết trong `units/cloudflared.service` (đã test):

1. **`Type=simple`, KHÔNG `notify`.** Binary cloudflared không hỗ trợ sd_notify
   (không có `NOTIFY_SOCKET`). `Type=notify` -> unit treo ở `activating` mãi.
2. **`ConditionFileNotEmpty`, không `ConditionPathExists`.** File token rỗng ->
   unit bị skip sạch, không tính `failed`, systemd vẫn `running`.

> **Tạo tunnel MỚI cho container.** Host đã chạy `cloudflared.service` riêng
> (systemd của host). Dùng lại token đó = 2 replica cùng tunnel -> Cloudflare
> chia traffic ngẫu nhiên giữa host và container -> routing thất thường.

Ingress (hostname -> service) khai trên Cloudflare Zero Trust dashboard; service
đích viết theo góc nhìn trong container, vd `http://localhost:8080`.

## Network

Static IP `172.28.0.10` trên `appnet` (`172.28.0.0/24`). Dynamic pool để riêng ở
`172.28.0.128/25` nên IP tĩnh `.2`-`.127` không bị Docker cấp trùng.

Container khác muốn gọi vào:

```yaml
services:
  other:
    networks: [appnet]
networks:
  appnet:
    external: true
```

Rồi dùng `supervisor:22` (DNS) hoặc `172.28.0.10:22`.

> Đổi `subnet`/`ip_range` cần `down` rồi `up` — Docker không sửa IPAM của network
> đang tồn tại. Báo `Address already in use` -> tìm network cũ giữ subnet bằng
> `docker network ls` + `docker network inspect`.

## Healthcheck

`bin/healthcheck.sh` map `systemctl is-system-running`:

| systemd | healthcheck |
|---|---|
| `running` | healthy |
| `starting` / `initializing` | unhealthy (để `start-period` lo) |
| `degraded` | unhealthy + in ra unit failed |

## Lưu ý về restart

- `docker stop` / `docker kill` **không** trigger `restart: always` — Docker coi
  là *manual stop* và cố ý bỏ qua policy. Đã verify: container nằm `exited`,
  `RestartCount` không tăng.
- Policy chỉ áp dụng khi container tự chết, hoặc Docker daemon khởi động lại.
  Test đúng: `docker exec supervisor systemctl reboot` -> `RestartCount` tăng.
