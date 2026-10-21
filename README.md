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

## Deploy từng bước (podman)

Làm **đúng thứ tự**. Mỗi bước có lệnh, kết quả mong đợi, và cách xử lý khi sai.
Không bỏ bước kiểm tra.

### Quy tắc

1. Mọi lệnh chạy bằng **root** (`sudo -i` hoặc thêm `sudo`). Đây là podman
   **rootful**, không phải rootless, không phải docker.
2. Chạy lệnh trong thư mục repo (vd `/home/thepodman/docker-systemd`).
3. **Không** sửa `/etc/containers/systemd/supervisor.container`: file này do
   `deploy.sh` sinh ra từ `quadlet/supervisor.container.in`, sửa tay sẽ bị ghi đè.
4. **Không** in, log, hay commit nội dung `secrets/token` (token Cloudflare).
5. **Không** chạy `./deploy.sh --new-ip` trừ khi được yêu cầu: nó đổi IP
   container, domain sẽ hỏng cho tới khi sửa ingress trên Cloudflare.

### Bước 1. Kiểm tra máy host

```bash
podman --version                       # >= 4.4 (cần Quadlet). vd: podman version 4.9.3
stat -fc %T /sys/fs/cgroup             # phải là: cgroup2fs
nft --version && nsenter --version     # phải có cả hai (nftables, util-linux)
ip -4 route show default               # phải có 1 dòng "default via <gw> dev <card>"
```

Sai thì làm:

| Kết quả sai | Cách sửa |
|---|---|
| `podman: command not found` hoặc < 4.4 | `apt-get install -y podman` (Debian 12+/Ubuntu 24.04+) |
| `nft`/`nsenter` không có | `apt-get install -y nftables util-linux` |
| cgroup không phải `cgroup2fs` | dừng lại, máy không hỗ trợ (cần cgroup v2) |
| không có default route | dừng lại, báo người dùng (cần mạng LAN) |

### Bước 2. Lấy code

```bash
git clone https://github.com/khanh97dev/docker-systemd.git
cd docker-systemd
```

Đã có repo thì `git pull`.

### Bước 3. Token Cloudflare (bỏ qua nếu chưa có)

```bash
printf '%s' '<TUNNEL_TOKEN>' > secrets/token
chmod 600 secrets/token
```

- Không có token: container vẫn chạy, chỉ unit `cloudflared` bị skip (không lỗi).
- Mật khẩu code-server: `deploy.sh` tự tạo `secrets/code-server/config.yaml`
  với mật khẩu **`123`** nếu file chưa có. Đổi mật khẩu = sửa dòng `password:`
  trong file đó rồi `podman exec supervisor systemctl restart code-server`.

### Bước 4. Deploy lần đầu

```bash
sudo ./deploy.sh
```

Script tự làm: chọn IP LAN ngẫu nhiên `.180`-`.254` còn trống -> tạo network
macvlan `lan` -> render Quadlet -> build image -> start `supervisor.service`.
Build lần đầu mất vài phút.

Output cuối phải có các dòng (IP có thể khác):

```
>> random IP: 172.16.7.188
>> cho systemd trong container len. ... running
IP tren lan: 172.16.7.188
```

**Ghi lại IP này.** Lần đầu sẽ có cảnh báo
`!! LAN_ALLOW rong -> KHONG an container khoi LAN`: bình thường, bước 7 sẽ bật.

Muốn chọn IP thay vì random: `sudo LAN_IP=172.16.7.200 ./deploy.sh`.

### Bước 5. Kiểm tra container

```bash
systemctl is-active supervisor.service                    # active
podman exec supervisor systemctl is-system-running        # running
podman exec supervisor systemctl is-active code-server    # active
podman healthcheck run supervisor && echo healthy         # healthy (đợi ~40s sau start)
podman inspect supervisor --format '{{(index .NetworkSettings.Networks "lan").IPAddress}}'   # IP ở bước 4
```

| Kết quả sai | Cách xem lỗi |
|---|---|
| `supervisor.service` không `active` | `journalctl -u supervisor.service -n 50 --no-pager` |
| `degraded` | `podman exec supervisor systemctl --failed` rồi `podman exec supervisor journalctl -u <unit> -n 50` |
| container exit 255 ngay | thiếu cờ systemd, xem mục "Yêu cầu để systemd chạy trong container" |

> **Không** dùng `curl http://<IP container>` từ chính host để test: macvlan
> chặn host gọi container (giới hạn kernel), lúc nào cũng timeout. Test từ trong
> container: `podman exec supervisor curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/login` -> `200`.

### Bước 6. Trỏ domain trên Cloudflare

Zero Trust -> Networks -> Tunnels -> tunnel của token -> Public Hostname -> thêm:

| Field | Giá trị |
|---|---|
| Hostname | vd `code-188.aiai.io.vn` |
| Service | `http://<IP container>:8080` (vd `http://172.16.7.188:8080`) |

Dùng **IP container**, **không** dùng `localhost` (xem mục cloudflared). Kiểm tra:

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://<hostname>/login   # 200, < 1s
```

### Bước 7. Ẩn container khỏi LAN (bật firewall)

Tìm IP connector cloudflared đang gọi vào container: gọi domain vài lần rồi xem
nguồn kết nối vào cổng 8080:

```bash
for i in 1 2 3; do curl -s -o /dev/null https://<hostname>/login; done
nsenter -t $(podman inspect -f '{{.State.Pid}}' supervisor) -n ss -tn '( sport = :8080 )'
```

Cột `Peer Address` (bỏ phần `:port`) là IP connector, vd `172.16.7.73`.
**Bỏ qua** dòng có Peer là chính IP container (đó là connector trong container).
Không có dòng nào ngoài IP container -> chưa cần `LAN_ALLOW` cho máy khác, nhưng
vẫn nên bật để ẩn: dùng IP connector thấy được ở lần gọi sau. Bật firewall:

```bash
sudo LAN_ALLOW="172.16.7.73" ./deploy.sh        # nhiều IP: "172.16.7.73 172.16.7.74"
```

Kiểm tra:

```bash
journalctl -u supervisor.service -n 30 --no-pager | grep 'lan-firewall:' | tail -1
# lan-firewall: supervisor chi cho phep <gw>,172.16.7.73 -> tcp 8080
curl -s -o /dev/null -w '%{http_code}\n' https://<hostname>/login                 # vẫn 200
```

Domain mất (502 sau ~30s) sau khi bật -> IP connector sai/thiếu: làm lại bước 7.

### Cập nhật (sửa code, đổi version, thêm unit)

```bash
git pull
sudo ./deploy.sh          # không cần truyền lại LAN_IP / LAN_ALLOW / LAN_PORTS
```

`deploy.sh` đọc lại IP, `LAN_ALLOW`, `LAN_PORTS` từ Quadlet đã render, nên IP
và firewall **giữ nguyên**. Chỉ truyền biến khi muốn **đổi** giá trị.

### Biến của `deploy.sh`

| Biến / cờ | Mặc định | Ý nghĩa |
|---|---|---|
| `LAN_IP` | random `.180`-`.254` (lần đầu), sau đó giữ nguyên | IP LAN của container |
| `LAN_ALLOW` | rỗng = firewall tắt | IP được gọi vào container (connector cloudflared) |
| `LAN_PORTS` | `8080` | port mở cho `LAN_ALLOW`, vd `"8080 1111"` |
| `--new-ip` | | random lại IP (phải sửa ingress Cloudflare sau đó) |

### Lệnh vận hành

```bash
systemctl status supervisor.service
systemctl restart supervisor.service
systemctl stop supervisor.service              # dừng hẳn, không tự restart
journalctl -u supervisor.service -f            # log host-side (start/stop, firewall)

podman exec -it supervisor bash                # vào container
podman exec supervisor systemctl --failed
podman exec supervisor journalctl -u cloudflared -f
podman exec supervisor journalctl -u code-server -f
```

### Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| domain **502** sau đúng ~30s | connector không tới được `IP:port` | kiểm tra ingress đúng IP container; IP connector có trong `LAN_ALLOW`; port có trong `LAN_PORTS` |
| domain **530** / `error code: 1016` | hostname bị xoá hoặc DNS sai trên Cloudflare | sửa trên dashboard, không phải lỗi container |
| domain **530** / `error code: 1033` | không connector nào của tunnel online | kiểm tra cloudflared trên các máy chạy tunnel |
| `!! can chay bang root` | chạy không có sudo | chạy lại với `sudo` |
| `!! khong tim duoc IP ...` | dải `.180`-`.254` đã kín | chọn tay `LAN_IP=<ip trống>` |
| host `curl <IP container>` timeout | macvlan: host không gọi được container | bình thường, test bằng `podman exec` |

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
sudo ./deploy.sh
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

Ingress (hostname -> service) khai trên Cloudflare Zero Trust dashboard.

> **Tunnel dùng chung với connector ở máy khác** (cùng token) -> Cloudflare có
> thể đẩy request vào **bất kỳ** connector nào, không nhất thiết connector trong
> container. Vì vậy service đích phải là **IP LAN của container**, vd
> `http://172.16.7.188:8080`, không phải `localhost` (`localhost` của connector
> máy khác là chính máy đó). IP container phải nằm trong `LAN_ALLOW`/`LAN_PORTS`
> của firewall (xem Network).
>
> Chỉ dùng `http://localhost:<port>` khi tunnel là **riêng** của container
> (connector duy nhất chạy trong container).

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
sudo LAN_PORTS="8080 1111" ./deploy.sh                 # port được vào (mặc định 8080)
```

`host/lan-firewall.sh` (cài vào `/usr/local/sbin/supervisor-lan-firewall`, chạy
bằng `ExecStartPost=` của Quadlet mỗi lần container start) áp nftables vào
network namespace của container **từ host**:

| | |
|---|---|
| TCP vào | chỉ `LAN_ALLOW` -> `LAN_PORTS` (mặc định `8080`); còn lại (ssh 22, ...) drop |
| Ping | không trả lời |
| ARP | chỉ trả lời gateway + `LAN_ALLOW` -> `arp-scan`/`nmap` từ máy khác thấy IP trống |
| IPv6 | tắt (link-local `fe80::` vẫn bị dò qua NDP) |
| Đi ra | bình thường (internet, cloudflared, `ct state established`) |

Container không có `CAP_NET_ADMIN` nên root trong container không gỡ được rule.
`LAN_ALLOW`/`LAN_PORTS` đọc lại từ Quadlet nên chỉ cần truyền lần đầu.

Tìm IP connector: xem bước 7 của "Deploy từng bước".

> Connector cloudflared đổi máy -> domain lỗi cho tới khi thêm IP mới vào `LAN_ALLOW`.
>
> Port khác trong container cũng vào được qua proxy của code-server mà không
> cần mở firewall: `https://<domain code-server>/proxy/<port>/` (phải đăng nhập).

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
