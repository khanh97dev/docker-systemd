# supervisor

**1 container Debian chạy systemd làm PID 1.** Service quản bằng `systemctl`,
cloudflared chạy trong cùng container.

| Thiết lập | Giá trị |
|---|---|
| Base image | `debian:13-slim` (trixie) |
| PID 1 | `systemd` (`/sbin/init`) |
| CPU limit | 4 (`cpu.max = 400000 100000`) |
| RAM limit | 6 GiB (swap tắt) |
| Restart policy | systemd unit `Restart=always` (Quadlet) |
| privileged | **không** (chỉ `SYS_ADMIN` + `apparmor=unconfined`) |
| Runtime | **podman rootful** (Quadlet ở `/etc/containers/systemd`) |
| Network | `lan` — **macvlan** trên card mạng chính, container có IP thật trên LAN |
| IP tĩnh | random `.180`-`.254` trong dải `/24` của host, lúc init |
| Port | không publish ra host — truy cập qua cloudflared hoặc `podman exec` |
| cloudflared | 2026.10.2, `.deb` chính thức, pin + verify sha256 |
| opencode | v2.1.1 (npm registry), pin + verify sha256 |
| code-server | 4.141.0, `.deb` chính thức, pin + verify sha256 — `0.0.0.0:8080` |
| Service sẵn | `ssh`, `cron`, `app`, `code-server` (enabled) · `cloudflared` (enable sẵn, có `ConditionFileNotEmpty=/etc/cloudflared/token` nên chưa có token thì unit bị skip, không fail) |

## Lệnh

Chạy bằng **root**:

```bash
sudo ./deploy.sh                       # build + render Quadlet + restart (lần đầu: random IP)
sudo ./deploy.sh --new-ip              # random lại IP
sudo LAN_IP=172.16.7.188 ./deploy.sh   # chọn IP cố định

systemctl status supervisor.service
systemctl stop supervisor.service
journalctl -u supervisor.service -f

podman exec supervisor systemctl status
podman exec supervisor systemctl is-system-running      # phải là "running"
podman exec supervisor systemctl --failed
podman exec supervisor systemctl restart app
podman exec supervisor journalctl -u app -f
```

## Yêu cầu để systemd chạy trong container

Đã test (cgroup v2, AppArmor bật, podman 4.9). **Thiếu bất kỳ dòng nào -> container exit 255:**

Khai trong `quadlet/supervisor.container.in` (`PodmanArgs=`/`Volume=`):

```
--cgroupns=host --cap-add=SYS_ADMIN --security-opt apparmor=unconfined
--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec,mode=1777,size=2g
-v /sys/fs/cgroup:/sys/fs/cgroup:rw -v ./secrets:/etc/cloudflared
--stop-signal=SIGRTMIN+3
```

> Không dùng `podman-compose`: nó bỏ qua `cgroup: host` -> container exit 255.

Kết quả test từng biến thể:

| Cấu hình | Kết quả |
|---|---|
| `SYS_ADMIN` + tmpfs + cgroup rw | ❌ exit 255 |
| `--privileged` | ⚠️ boot được nhưng `degraded` |
| `SYS_ADMIN` + `apparmor=unconfined` + `cgroupns=host` | ✅ `running` |
| thêm `seccomp=unconfined` | ✅ (không cần) |
| `cgroupns=private` | ❌ exit 255 — **phải** là `host` |

- **`apparmor=unconfined` là cái quyết định.** Host bật AppArmor, profile
  mặc định chặn systemd. Không cần `--privileged`.
- Không dùng `--init` — systemd *là* init.
- **`--stop-signal=SIGRTMIN+3`** — systemd shutdown bằng signal này, không phải
  SIGTERM. Thiếu -> `podman stop` phải chờ hết `--stop-timeout` rồi SIGKILL.
- `--cgroupns=host` + `/sys/fs/cgroup:rw` cho container thấy cgroup của host.
  Limits của chính nó **vẫn enforce** (đã verify `cpu.max`), nhưng đây là quyền
  rộng hơn mặc định — đừng chạy code không tin cậy trong container này.

## Thêm service

Tạo `units/<ten>.service`, rồi:

```bash
./deploy.sh
podman exec supervisor systemctl enable --now <ten>
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

Binary trong image, chạy như unit systemd trong **cùng container**. Unit được
`enable` sẵn; token phải ở `./secrets/token` (mount vào `/etc/cloudflared/token`),
không có/nhập nội dung rỗng thì unit bị skip sạch (không fail).

`./secrets` được mount **read-write** vào `/etc/cloudflared`, nên cả hai cách đều được.

Cách A — ghi token từ host:

```bash
printf '%s' '<TUNNEL_TOKEN>' > secrets/token
chmod 600 secrets/token
mkdir -p secrets/code-server
systemctl restart supervisor.service
podman exec supervisor systemctl enable --now cloudflared
```

Cách B — dùng chính lệnh của cloudflared trong container:

```bash
podman exec supervisor cloudflared service install '<TUNNEL_TOKEN>'
podman exec supervisor systemctl enable --now cloudflared
```

Token ghi kiểu nào cũng rơi ra `./secrets/token` trên host nên **sống qua rebuild**.

```bash
podman exec supervisor journalctl -u cloudflared -f
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

Container nằm **thẳng trên LAN** qua macvlan `lan` (card mạng có default route),
nên có IP thật mà máy nào trong LAN cũng gọi được. Không hardcode IP: lần init
`deploy.sh` random một IP `.180`-`.254` trong dải `/24` chứa IP host, bỏ qua IP
gateway/host và IP nào đang trả lời ping/ARP.

Không có file state: lần chạy sau đọc lại IP từ Quadlet đã render
(`/etc/containers/systemd/supervisor.container`, `Network=lan:ip=...`), nên IP
**giữ nguyên** qua mỗi lần deploy. Đổi: `sudo ./deploy.sh --new-ip`, hoặc chọn
tay `sudo LAN_IP=<ip> ./deploy.sh`. Xem IP hiện tại:

```bash
podman inspect supervisor --format '{{(index .NetworkSettings.Networks "lan").IPAddress}}'
```

Ingress cloudflared trỏ vào `http://<ip container>:8080`.

> **Vì sao không dùng bridge?** Bridge (rootless là netns riêng, rootful là
> bridge trên host) chỉ máy này thấy. Tunnel có connector ở máy khác cùng LAN
> -> connector đó gọi IP container bị timeout 30s -> Cloudflare trả **502**.
> Macvlan cho IP thật trên LAN nên connector nào cũng gọi được.
>
> **Giới hạn macvlan:** chính host **không** gọi được IP container (kernel chặn
> host <-> macvlan con). Từ host dùng `podman exec`.

### Ẩn khỏi LAN (chống scan)

```bash
sudo LAN_ALLOW="<ip connector cloudflared>" ./deploy.sh   # nhiều IP: cách nhau bằng dấu cách
```

`host/lan-firewall.sh` (cài vào `/usr/local/sbin/supervisor-lan-firewall`, chạy
bằng `ExecStartPost=` của Quadlet mỗi lần container start) áp nftables vào
network namespace của container **từ host**:

| | |
|---|---|
| TCP vào | chỉ `LAN_ALLOW` -> `:8080`; còn lại (ssh 22, ...) drop |
| Ping | không trả lời |
| ARP | chỉ trả lời gateway + `LAN_ALLOW` -> `arp-scan`/`nmap` từ máy khác thấy IP trống |
| IPv6 | tắt (link-local `fe80::` vẫn bị dò qua NDP) |
| Đi ra | bình thường (internet, cloudflared, `ct state established`) |

Container không có `CAP_NET_ADMIN` nên root trong container không gỡ được rule.
`LAN_ALLOW` đọc lại từ Quadlet nên chỉ cần truyền lần đầu. Tìm IP connector:
gọi domain rồi xem nguồn kết nối vào 8080:

```bash
nsenter -t $(podman inspect -f '{{.State.Pid}}' supervisor) -n ss -tn '( sport = :8080 )'
```

> Connector cloudflared đổi máy -> domain lỗi cho tới khi thêm IP mới vào `LAN_ALLOW`.

## Healthcheck

`bin/healthcheck.sh` map `systemctl is-system-running`:

| systemd | healthcheck |
|---|---|
| `running` | healthy |
| `starting` / `initializing` | unhealthy (để `start-period` lo) |
| `degraded` | unhealthy + in ra unit failed |

## Lưu ý về restart

- Restart do systemd lo (`Restart=always` trong Quadlet): container
  chết (kể cả `kill -9` PID 1) -> unit tự chạy lại.
- `systemctl stop supervisor.service` là dừng có chủ đích, không restart.
- Tự chạy khi boot (`WantedBy=default.target` trong Quadlet).

## opencode

Đã cài sẵn trong image, `opencode v2.1.1`.

**v2 phát hành qua npm registry, không qua GitHub releases** — GitHub `sst/opencode`
chỉ có tag `1.x`. Version mới nhất lấy ở:

```bash
curl -fsSL https://opencode.ai/update/api/latest/cli/npm
```

rồi đổi `ARG OPENCODE_VERSION` + sha256 trong `Containerfile`.

### `/tmp` phải có `exec`

```
--tmpfs /tmp:exec,mode=1777,size=2g
```

Mặc định tmpfs mount tmpfs là `noexec,size=64m`. opencode (Bun) giải nén native
lib ra `/tmp` rồi `dlopen()`, nên `noexec` làm nó chết với:

```
Failed to initialize OpenTUI render library: Failed to open library
"/tmp/.xxx.so": failed to map segment from shared object
```

64MB cũng không đủ chỗ. Đây là lỗi dễ tưởng là bug của opencode nhưng thực ra do
cấu hình tmpfs của container.
