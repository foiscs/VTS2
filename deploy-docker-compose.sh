#!/usr/bin/env bash
set -euo pipefail

# ── 헬퍼 ─────────────────────────────────────────────────────────────────────
pid_of() { docker inspect -f '{{.State.Pid}}' "$1"; }

net_add() {
  # net_add <container> <host_iface> <container_iface> <ip/prefix> <gw>
  local cname=$1 host_if=$2 con_if=$3 ip=$4 gw=$5
  local pid; pid=$(pid_of "$cname")
  ip link set "$host_if" netns "$pid"
  nsenter -t "$pid" -n -- ip link set "$host_if" name "$con_if"
  nsenter -t "$pid" -n -- ip addr add "$ip" dev "$con_if"
  nsenter -t "$pid" -n -- ip link set "$con_if" up
  [ -n "$gw" ] && nsenter -t "$pid" -n -- ip route replace default via "$gw"
  echo "  ✔ $cname  $con_if=$ip  gw=${gw:-none}"
}

br_add_port() {
  # 브리지에 veth 한쪽 끝 연결
  local br=$1 iface=$2
  ip link set "$iface" master "$br"
  ip link set "$iface" up
}

# ── 0. 컨테이너 기동 ──────────────────────────────────────────────────────────
echo "[0/5] docker compose up"
docker compose up -d
sleep 3   # 컨테이너 PID 안정화 대기

# ── 1. 브리지 생성 ────────────────────────────────────────────────────────────
echo "[1/5] 브리지 생성"
for br in sw-dmz sw-intranet sw-db; do
  ip link show "$br" &>/dev/null || { ip link add "$br" type bridge; ip link set "$br" up; }
  echo "  ✔ $br"
done

# ── 2. veth 페어 생성 및 연결 ─────────────────────────────────────────────────
echo "[2/5] veth 페어 생성"

# host ↔ router (eth1: WAN)
ip link add veth-ext   type veth peer name veth-ext-r
ip addr add 10.0.1.100/24 dev veth-ext
ip link set veth-ext up
net_add router veth-ext-r eth1 10.0.1.1/24 ""

# router (eth2) ↔ suricata (in1) — Suricata 인라인 입력
ip link add veth-sur   type veth peer name veth-sur-r
net_add router   veth-sur-r   eth2       10.0.10.1/24 ""
net_add suricata veth-sur     eth-in1    ""            ""   # IP 불필요 (inline)

# suricata (in2) ↔ sw-dmz — Suricata 인라인 출력
ip link add veth-dmz type veth peer name veth-dmz-br
net_add suricata veth-dmz    eth-in2    ""            ""   # IP 불필요 (inline)
br_add_port sw-dmz veth-dmz-br

# ── 3. DMZ 컨테이너 → sw-dmz 연결 ────────────────────────────────────────────
echo "[3/5] DMZ 컨테이너 연결"

# dvwa
ip link add veth-dvwa type veth peer name veth-dvwa-br
br_add_port sw-dmz veth-dvwa-br
net_add dvwa veth-dvwa eth1 10.0.10.10/24 10.0.10.1
nsenter -t "$(pid_of dvwa)" -n -- ip route add 10.0.20.0/24 via 10.0.10.254

# spring
ip link add veth-spring type veth peer name veth-spring-br
br_add_port sw-dmz veth-spring-br
net_add spring veth-spring eth1 10.0.10.20/24 10.0.10.1
nsenter -t "$(pid_of spring)" -n -- ip route add 10.0.20.0/24 via 10.0.10.254

# fw-int (eth1=DMZ, eth2=Intranet, eth3=DB)
ip link add veth-fwdmz type veth peer name veth-fwdmz-br
br_add_port sw-dmz veth-fwdmz-br
ip link add veth-fwint type veth peer name veth-fwint-br
br_add_port sw-intranet veth-fwint-br
ip link add veth-fwdb type veth peer name veth-fwdb-br
br_add_port sw-db veth-fwdb-br

pid_fw=$(pid_of fw-int)
for pair in "veth-fwdmz eth1 10.0.10.254/24" "veth-fwint eth2 10.0.20.1/24" "veth-fwdb eth3 10.0.30.1/24"; do
  read host_if con_if ip <<< "$pair"
  ip link set "$host_if" netns "$pid_fw"
  nsenter -t "$pid_fw" -n -- ip link set "$host_if" name "$con_if"
  nsenter -t "$pid_fw" -n -- ip addr add "$ip" dev "$con_if"
  nsenter -t "$pid_fw" -n -- ip link set "$con_if" up
done
nsenter -t "$pid_fw" -n -- ip route add default via 10.0.10.1
echo "  ✔ fw-int eth1/eth2/eth3"

# ── 4. Intranet / DB 연결 ─────────────────────────────────────────────────────
echo "[4/5] Intranet/DB 연결"

ip link add veth-was type veth peer name veth-was-br
br_add_port sw-intranet veth-was-br
net_add was veth-was eth1 10.0.20.10/24 10.0.20.1
nsenter -t "$(pid_of was)" -n -- ip route add 10.0.30.0/24 via 10.0.20.1

ip link add veth-mysql type veth peer name veth-mysql-br
br_add_port sw-db veth-mysql-br
net_add mysqlserver1 veth-mysql eth1 10.0.30.10/24 10.0.30.1

# ── 5. fw-int iptables ────────────────────────────────────────────────────────
echo "[5/5] fw-int iptables"
FW=fw-int
docker exec $FW iptables -P FORWARD DROP
docker exec $FW iptables -A FORWARD -s 10.0.10.10 -d 10.0.20.10 -p tcp --dport 3306 -j ACCEPT
docker exec $FW iptables -A FORWARD -s 10.0.20.10 -d 10.0.10.10 -p tcp --sport 3306 -m state --state ESTABLISHED -j ACCEPT
docker exec $FW iptables -A FORWARD -s 10.0.10.20 -d 10.0.20.10 -p tcp --dport 3306 -j ACCEPT
docker exec $FW iptables -A FORWARD -s 10.0.20.10 -d 10.0.10.20 -p tcp --sport 3306 -m state --state ESTABLISHED -j ACCEPT
docker exec $FW iptables -A FORWARD -s 10.0.20.10 -d 10.0.30.10 -p tcp --dport 3306 -j ACCEPT
docker exec $FW iptables -A FORWARD -s 10.0.30.10 -d 10.0.20.10 -p tcp --sport 3306 -m state --state ESTABLISHED -j ACCEPT
echo "  ✔ iptables 적용"

# ── 라우팅 ───────────────────────────────────────────────────────────────────
ip route replace 10.0.10.0/24 via 10.0.1.1 dev veth-ext
ip route replace 10.0.20.0/24 via 10.0.1.1 dev veth-ext

echo ""
echo "완료 — Suricata 시작: ./start-suricata.sh"