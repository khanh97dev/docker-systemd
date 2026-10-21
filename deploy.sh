#!/usr/bin/env bash
# Build image + (re)start container supervisor bang rootless podman (Quadlet).
# Chay bang user thuong (vd thepodman), KHONG can root:
#   ./deploy.sh            # lan dau (chua co network appnet): random subnet/IP 172.x
#   ./deploy.sh --new-ip   # xoa network appnet, random lai subnet/IP
#
# Subnet /24 duoc chon ngau nhien trong 172.16.0.0/12 (dai private), bo qua moi
# dai trung voi route/interface cua host va network podman khac. IP container
# random trong .2-.127; dynamic pool .128-.254 nen khong bao gio cap trung.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(pwd)

NET=appnet
SERVICE=supervisor.service
IMAGE=supervisor:latest
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Thieu bien nay podman se bao "no systemd user session available" va roi ve
# cgroupfs -> build/run that bai voi "Interactive authentication required".
# Phai GAN DE, khong duoc chi set khi rong: neu login bang `su - thepodman` tu
# root thi DBUS_SESSION_BUS_ADDRESS da tro san ve /run/user/0/bus cua root.
if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }

# Cac CIDR dang dung: route/interface cua host + network podman (tru $NET).
used_cidrs() {
  ip -4 route show | awk '$1 ~ /^[0-9.]+\/[0-9]+$/ {print $1}'
  ip -4 -o addr show | awk '{print $4}'
  podman network ls --format '{{.Name}}' | grep -vx "$NET" | while read -r n; do
    podman network inspect "$n" --format '{{range .Subnets}}{{.Subnet}}{{"\n"}}{{end}}'
  done | grep -E '^[0-9.]+/[0-9]+$' || true
}

# $1 = a.b.c.0 (/24). Tra 0 neu trung voi bat ky CIDR dang dung nao.
overlaps() {
  local lo=$(( $(ip2int "$1") )) hi cidr net len mask nlo nhi
  hi=$(( lo + 255 ))
  for cidr in $USED; do
    net=${cidr%/*} len=${cidr#*/}
    mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    nlo=$(( $(ip2int "$net") & mask ))
    nhi=$(( nlo | (~mask & 0xFFFFFFFF) ))
    if (( lo <= nhi && nlo <= hi )); then return 0; fi
  done
  return 1
}

rand() { shuf -i "$1-$2" -n 1; }

random_network() {
  USED=$(used_cidrs | sort -u)
  local i base
  for i in $(seq 1 200); do
    base="172.$(rand 16 31).$(rand 0 255).0"
    if ! overlaps "$base"; then
      APPNET_SUBNET="${base%.0}.0/24"
      SUPERVISOR_IP="${base%.0}.$(rand 2 127)"
      return 0
    fi
  done
  echo "!! khong tim duoc subnet 172.x trong sau 200 lan thu" >&2
  exit 1
}

QUADLET="$QUADLET_DIR/supervisor.container"

# Khong luu file trang thai: network $NET dang ton tai chinh la nguon su that
# cho subnet, IP doc lai tu Quadlet da render. Lan init (chua co network) hoac
# --new-ip thi random moi.
if [ "${1:-}" = "--new-ip" ] && podman network exists "$NET"; then
  echo ">> --new-ip: xoa network $NET cu"
  systemctl --user stop "$SERVICE" 2>/dev/null || true
  podman rm -f supervisor >/dev/null 2>&1 || true
  podman network rm "$NET"
fi

if podman network exists "$NET"; then
  APPNET_SUBNET=$(podman network inspect "$NET" --format '{{range .Subnets}}{{.Subnet}}{{end}}')
  PREFIX=${APPNET_SUBNET%.0/24}
  SUPERVISOR_IP=$(sed -n "s|^Network=$NET:ip=||p" "$QUADLET" 2>/dev/null || true)
  case "$SUPERVISOR_IP" in
    "$PREFIX".*) ;;
    *) SUPERVISOR_IP="$PREFIX.$(rand 2 127)" ;;
  esac
else
  random_network
  PREFIX=${APPNET_SUBNET%.0/24}
  echo ">> tao network $NET ($APPNET_SUBNET random, dynamic .128-.254)"
  podman network create \
    --subnet "$APPNET_SUBNET" \
    --gateway "$PREFIX.1" \
    --ip-range "$PREFIX.128/25" \
    "$NET"
fi
echo ">> $NET = $APPNET_SUBNET, supervisor = $SUPERVISOR_IP"

mkdir -p secrets/code-server "$QUADLET_DIR"

# code-server: chua co config thi tao mac dinh voi mat khau 123 (doi trong
# secrets/code-server/config.yaml). Da co thi giu nguyen.
CS_CONFIG=secrets/code-server/config.yaml
if [ ! -s "$CS_CONFIG" ]; then
  echo ">> tao $CS_CONFIG (password mac dinh: 123)"
  cat >"$CS_CONFIG" <<'EOF'
bind-addr: 0.0.0.0:8080
auth: password
password: "123"
cert: false
EOF
  chmod 600 "$CS_CONFIG"
fi

echo ">> render Quadlet -> $QUADLET"
sed -e "s|@NET@|$NET|g" -e "s|@IP@|$SUPERVISOR_IP|g" \
    -e "s|@SUBNET@|$APPNET_SUBNET|g" -e "s|@REPO@|$REPO|g" \
    quadlet/supervisor.container.in >"$QUADLET"

echo ">> build $IMAGE"
# --format docker: anh OCI bo qua HEALTHCHECK (Quadlet van khai lai --health-*)
podman build --format docker -t "$IMAGE" .

echo ">> restart $SERVICE"
systemctl --user daemon-reload
systemctl --user restart "$SERVICE"

echo -n ">> cho systemd trong container len"
for _ in $(seq 1 60); do
  if [ "$(podman exec supervisor systemctl is-system-running 2>/dev/null || true)" = "running" ]; then
    echo " ... running"
    break
  fi
  echo -n "."
  sleep 2
done

podman ps --filter name=supervisor --format '{{.Names}} | {{.Status}} | {{.Ports}}'
podman inspect supervisor --format "IP tren $NET: {{(index .NetworkSettings.Networks \"$NET\").IPAddress}}"
podman exec supervisor systemctl --failed --no-pager || true
