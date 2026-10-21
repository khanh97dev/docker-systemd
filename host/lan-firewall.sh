#!/bin/sh
# An container khoi LAN: chay tren HOST (Quadlet ExecStartPost), ap nftables
# vao network namespace cua container qua nsenter. Container khong co
# CAP_NET_ADMIN nen root trong container khong go duoc rule nay.
#   lan-firewall.sh <container> <ip duoc phep>...
#
# - Chi <ip duoc phep> vao duoc tcp/8080; moi thu khac (ssh, ping...) bi drop.
# - ARP request chi duoc tra loi cho gateway + <ip duoc phep> -> arp-scan/nmap
#   tu may khac thay IP nhu dang trong.
# - Tat IPv6 (link-local fe80:: van bi do qua NDP).
# - Ket noi container tu mo ra ngoai (internet, cloudflared) van chay binh thuong.
set -eu
NAME=$1; shift
[ $# -gt 0 ] || { echo "can it nhat 1 ip duoc phep" >&2; exit 1; }

PID=$(podman inspect -f '{{.State.Pid}}' "$NAME")
in_ns() { nsenter -t "$PID" -n "$@"; }

GW=$(in_ns ip -4 route show default | awk '{print $3; exit}')
ALLOW=$(echo "$GW" "$@" | tr ' ' ',')

in_ns sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1

in_ns nft -f - <<NFT
flush ruleset
table inet lanfw {
  set allow { type ipv4_addr; elements = { $ALLOW } }
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    ip saddr @allow tcp dport 8080 accept
  }
}
table arp lanfw {
  set allow { type ipv4_addr; elements = { $ALLOW } }
  chain input {
    type filter hook input priority 0; policy accept;
    arp operation request arp saddr ip != @allow drop
  }
}
NFT
echo "lan-firewall: $NAME chi cho phep $ALLOW"
