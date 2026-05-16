#!/usr/bin/env bash
# =============================================================================
#  deploy-router-only.sh  — Phase 1: FRR router 배포
#
#  하는 일:
#    1. clab deploy  (router 노드 + host veth 링크 생성)
#    2. veth-ext IP 설정  (10.0.1.100/24, VM 역할)
#    3. router 연결 확인  (ping 10.0.1.1)
#
#  다음 단계:
#    sudo ./start-suricata.sh   ← veth-dmz 생성 + Suricata 시작
#
#  정리:
#    sudo ./deploy-router-only.sh --destroy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="$SCRIPT_DIR/router-only.yml"

VETH_EXT="veth-ext"          # clab 생성: router:eth1 ↔ host:veth-ext
IP_VETH_EXT="10.0.1.100/24"
IP_ROUTER_ETH1="10.0.1.1"
TOPO_NAME="router-only"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()  { echo -e "  ${GREEN}✔${NC} $*"; }
warn(){ echo -e "  ${YELLOW}⚠${NC} $*"; }
die() { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"
command -v clab &>/dev/null  || die "clab 없음"

cd "$SCRIPT_DIR"

# ── --destroy ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--destroy" ]; then
  echo "정리 중..."
  clab destroy -t "$TOPO_FILE" --cleanup 2>/dev/null && ok "clab 제거" || ok "없음"
  ip addr flush dev "$VETH_EXT" 2>/dev/null          && ok "veth-ext 플러시" || ok "없음"
  exit 0
fi

# ── 1. clab deploy ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/3] clab deploy${NC}"
clab deploy -t "$TOPO_FILE" --reconfigure
ok "ContainerLab 배포 완료"

# ── 2. veth-ext IP 설정 ──────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/3] veth-ext IP 설정${NC}"
ip addr flush dev "$VETH_EXT" 2>/dev/null || true
ip addr add "$IP_VETH_EXT" dev "$VETH_EXT"
ip link set "$VETH_EXT" up
ok "veth-ext  $IP_VETH_EXT"

# DMZ 서브넷 경로: 호스트 → router:eth1 → router → eth2(Suricata)
ip route replace 10.0.10.0/24 via 10.0.1.1 dev "$VETH_EXT"
ok "route  10.0.10.0/24 via 10.0.1.1 dev $VETH_EXT"

# ── 3. router 연결 확인 ──────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/3] router 연결 확인${NC}"
printf "  ping %s ... " "$IP_ROUTER_ETH1"
for i in $(seq 1 15); do
  ping -c 1 -W 1 "$IP_ROUTER_ETH1" &>/dev/null && break
  printf "(%d) " "$i"; sleep 1
done

if ping -c 2 -W 2 "$IP_ROUTER_ETH1" &>/dev/null; then
  echo -e "${GREEN}✔ OK${NC}"
else
  echo -e "${YELLOW}⚠ 응답 없음${NC}"
  warn "FRR 기동 중일 수 있습니다 — 잠시 후 재시도:  ping $IP_ROUTER_ETH1"
fi

# ── 4. DMZ 컨테이너 네트워크 설정 (nsenter) ─────────────────────────────────
# clab 토폴로지에 DMZ 노드가 있을 때만 실행
setup_container_net() {
  local node="$1" ip="$2" gw="$3"
  local cname="clab-${TOPO_NAME}-${node}"

  docker inspect "$cname" &>/dev/null || return 0  # 노드 없으면 건너뜀

  echo -e "\n${BOLD}[4] $node 네트워크 설정 (nsenter)${NC}"
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")

  nsenter -t "$pid" -n -- ip addr replace "$ip" dev eth1
  nsenter -t "$pid" -n -- ip link set eth1 up
  nsenter -t "$pid" -n -- ip route replace default via "$gw"
  ok "$node  eth1=$ip  gw=$gw"
}

setup_container_net "dvwa"       "10.0.10.10/24" "10.0.10.1"

# DVWA: Intranet 경로 추가 (fw-int 경유)
setup_extra_route() {
  local node="$1" dest="$2" gw="$3"
  local cname="clab-${TOPO_NAME}-${node}"
  docker inspect "$cname" &>/dev/null || return 0
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")
  nsenter -t "$pid" -n -- ip route replace "$dest" via "$gw"
  ok "$node  route $dest via $gw"
}
setup_extra_route "dvwa" "10.0.20.0/24" "10.0.10.254"

# fw-int: eth1/eth2 IP 설정 (FRR frr.conf가 라우팅 담당)
setup_fwint_net() {
  local cname="clab-${TOPO_NAME}-fw-int"
  docker inspect "$cname" &>/dev/null || return 0

  echo -e "\n${BOLD}[5] fw-int 네트워크 + 방화벽 설정${NC}"
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")

  nsenter -t "$pid" -n -- ip addr replace "10.0.10.254/24" dev eth1
  nsenter -t "$pid" -n -- ip link set eth1 up
  nsenter -t "$pid" -n -- ip addr replace "10.0.20.1/24"  dev eth2
  nsenter -t "$pid" -n -- ip link set eth2 up
  ok "fw-int  eth1=10.0.10.254/24  eth2=10.0.20.1/24"

  # ── iptables 방화벽 정책 ────────────────────────────────────────────────
  # FORWARD 체인: 기본 DROP
  docker exec "$cname" iptables -P FORWARD DROP

  # DVWA → MySQL (10.0.20.10:3306) ALLOW
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.10.10 -d 10.0.20.10 -p tcp --dport 3306 -j ACCEPT

  # MySQL → DVWA (ESTABLISHED 응답) ALLOW
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.20.10 -d 10.0.10.10 -p tcp --sport 3306 \
    -m state --state ESTABLISHED -j ACCEPT

  ok "fw-int  iptables: DVWA→MySQL ALLOW, 그 외 FORWARD DROP"
}
setup_fwint_net

# mysqlserver1: eth1 IP 설정
setup_mysql_net() {
  local cname="clab-${TOPO_NAME}-mysqlserver1"
  docker inspect "$cname" &>/dev/null || return 0

  echo -e "\n${BOLD}[6] mysqlserver1 네트워크 설정${NC}"
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")

  nsenter -t "$pid" -n -- ip addr replace "10.0.20.10/24" dev eth1
  nsenter -t "$pid" -n -- ip link set eth1 up
  nsenter -t "$pid" -n -- ip route replace default via "10.0.20.1"
  ok "mysqlserver1  eth1=10.0.20.10/24  gw=10.0.20.1"
}
setup_mysql_net

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}생성된 인터페이스:${NC}"
ip -br link show "$VETH_EXT" 2>/dev/null | awk '{print "    veth-ext  "$0}' || true
ip -br link show "veth-sur"  2>/dev/null | awk '{print "    veth-sur  "$0}' || true
echo ""
echo -e "  다음 단계:  ${BOLD}sudo ./start-suricata.sh${NC}"
echo ""
