#!/usr/bin/env bash
# Build image + (re)start container supervisor bang podman ROOTFUL (Quadlet).
# Phai chay bang root:
#   sudo ./deploy.sh                      # lan dau: random IP LAN .180-.254
#   sudo ./deploy.sh --new-ip             # random lai IP
#   sudo LAN_IP=172.16.7.188 ./deploy.sh  # chon IP co dinh thay vi random
#
# Container nam thang tren LAN (macvlan) voi IP that, nen cloudflared o bat ky
# may nao trong LAN cung goi duoc. Bridge rieng (rootless hay rootful) thi chi
# may nay thay -> connector cloudflared o may khac goi IP container bi timeout
# -> Cloudflare tra 502.
#
# IP random trong .180-.254 cua dai /24 chua IP host, bo qua IP dang co may
# tra loi ARP. Khong luu file trang thai: IP doc lai tu Quadlet da render.
#
# Luu y macvlan: chinh host KHONG goi duoc IP container (gioi han cua kernel).
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(pwd)

if [ "$(id -u)" -ne 0 ]; then
  echo "!! can chay bang root (podman rootful): sudo $0 $*" >&2
  exit 1
fi

NET=lan
SERVICE=supervisor.service
IMAGE=supervisor:latest
QUADLET_DIR=/etc/containers/systemd
QUADLET="$QUADLET_DIR/supervisor.container"
IP_MIN=180
IP_MAX=254

DEV=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}')
GW=$(ip -4 route show default dev "$DEV" | awk '{print $3; exit}')
SUBNET=$(ip -4 route show dev "$DEV" scope link proto kernel | awk '{print $1; exit}')
HOST_IP=$(ip -4 -o addr show dev "$DEV" | awk '{split($4, a, "/"); print a[1]; exit}')
PREFIX=${HOST_IP%.*}

# 0 neu IP dang co may dung (tra loi ping hoac ARP).
ip_in_use() {
  ping -c1 -W1 "$1" >/dev/null 2>&1 && return 0
  ip neigh show "$1" dev "$DEV" | grep -q lladdr
}

random_ip() {
  local i ip
  for i in $(seq 1 50); do
    ip="$PREFIX.$(shuf -i "$IP_MIN-$IP_MAX" -n 1)"
    if [ "$ip" != "$GW" ] && [ "$ip" != "$HOST_IP" ] && ! ip_in_use "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  echo "!! khong tim duoc IP trong $PREFIX.$IP_MIN-$IP_MAX sau 50 lan thu" >&2
  exit 1
}

if [ -z "${LAN_IP:-}" ] && [ "${1:-}" != "--new-ip" ]; then
  LAN_IP=$(sed -n "s|^Network=$NET:ip=||p" "$QUADLET" 2>/dev/null || true)
fi
if [ -z "${LAN_IP:-}" ]; then
  # dung container truoc, neu khong IP cu cua no se bi tinh la "dang dung"
  systemctl stop "$SERVICE" 2>/dev/null || true
  LAN_IP=$(random_ip)
  echo ">> random IP: $LAN_IP"
fi

if ! podman network exists "$NET"; then
  echo ">> tao macvlan $NET tren $DEV ($SUBNET, gw $GW)"
  podman network create -d macvlan -o parent="$DEV" \
    --subnet "$SUBNET" --gateway "$GW" "$NET"
fi
echo ">> $NET = $SUBNET, supervisor = $LAN_IP"

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
sed -e "s|@NET@|$NET|g" -e "s|@IP@|$LAN_IP|g" \
    -e "s|@SUBNET@|$SUBNET|g" -e "s|@REPO@|$REPO|g" \
    quadlet/supervisor.container.in >"$QUADLET"

echo ">> build $IMAGE"
# --format docker: anh OCI bo qua HEALTHCHECK (Quadlet van khai lai --health-*)
podman build --format docker -t "$IMAGE" .

echo ">> restart $SERVICE"
systemctl daemon-reload
systemctl restart "$SERVICE"

echo -n ">> cho systemd trong container len"
for _ in $(seq 1 60); do
  if [ "$(podman exec supervisor systemctl is-system-running 2>/dev/null || true)" = "running" ]; then
    echo " ... running"
    break
  fi
  echo -n "."
  sleep 2
done

podman ps --filter name=supervisor --format '{{.Names}} | {{.Status}}'
podman inspect supervisor --format "IP tren $NET: {{(index .NetworkSettings.Networks \"$NET\").IPAddress}}"
podman exec supervisor systemctl --failed --no-pager || true
