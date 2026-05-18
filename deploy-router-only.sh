#!/usr/bin/env bash
# =============================================================================
#  deploy-router-only.sh  — Phase 1: 이미지 빌드 + FRR router 배포
#
#  하는 일:
#    0. Docker 이미지 빌드  (DVWA, Spring — 없을 때만)
#    1. bridge 사전 생성  (sw-dmz, sw-intranet, sw-db)
#    2. clab deploy  (router 노드 + host veth 링크 생성)
#    3. veth-ext IP 설정  (10.0.1.100/24, VM 역할)
#    4. router 연결 확인  (ping 10.0.1.1)
#    5. 컨테이너 네트워크 설정  (nsenter)
#
#  옵션:
#    --rebuild   이미지가 있어도 강제 재빌드
#    --destroy   배포 전체 정리
#
#  다음 단계:
#    sudo ./start-suricata.sh   ← Suricata 시작
#
#  정리:
#    sudo ./deploy-router-only.sh --destroy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="$SCRIPT_DIR/router-only.yml"

VETH_EXT="veth-ext"
IP_VETH_EXT="10.0.1.100/24"
IP_ROUTER_ETH1="10.0.1.1"
TOPO_NAME="router-only"

# 빌드 대상 이미지
DVWA_IMAGE="vulnerables/web-dvwa:local"
DVWA_CONTEXT="$SCRIPT_DIR/DockerContainers/DVWA"

SPRING_IMAGE="vts-spring:latest"
SPRING_CONTEXT="$SCRIPT_DIR/DockerContainers/SpringServer"

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
  for br in sw-dmz sw-intranet sw-db; do
    ip link delete "$br" 2>/dev/null && ok "$br 제거" || ok "$br 없음"
  done
  exit 0
fi

REBUILD="${1:-}"

# ── 0. Docker 이미지 빌드 ─────────────────────────────────────────────────────
echo -e "\n${BOLD}[0/5] Docker 이미지 빌드${NC}"

build_image() {
  local image="$1" context="$2" label="$3"

  if [ "$REBUILD" = "--rebuild" ] || ! docker image inspect "$image" &>/dev/null; then
    echo -e "  빌드: ${BOLD}$image${NC}  (context: $context)"
    docker build -t "$image" "$context" \
      && ok "$label 이미지 빌드 완료: $image" \
      || die "$label 빌드 실패"
  else
    ok "$label 이미지 존재 (건너뜀): $image  → 강제 재빌드: --rebuild"
  fi
}

build_image "$DVWA_IMAGE"   "$DVWA_CONTEXT"   "DVWA"
build_image "$SPRING_IMAGE" "$SPRING_CONTEXT" "Spring"

# ── 1. bridge 사전 생성 ───────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/5] bridge 사전 생성${NC}"
for br in sw-dmz sw-intranet sw-db; do
  if ip link show "$br" &>/dev/null; then
    ok "$br 존재 (건너뜀)"
  else
    ip link add "$br" type bridge
    ip link set "$br" up
    ok "$br 생성"
  fi
done

# ── 2. clab deploy ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/5] clab deploy${NC}"
clab deploy -t "$TOPO_FILE" --reconfigure
ok "ContainerLab 배포 완료"

# ── 3. veth-ext IP 설정 ──────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/5] veth-ext IP 설정${NC}"
ip addr flush dev "$VETH_EXT" 2>/dev/null || true
ip addr add "$IP_VETH_EXT" dev "$VETH_EXT"
ip link set "$VETH_EXT" up
ok "veth-ext  $IP_VETH_EXT"

ip route replace 10.0.10.0/24 via 10.0.1.1 dev "$VETH_EXT"
ok "route  10.0.10.0/24 via 10.0.1.1 dev $VETH_EXT"

# ── 4. router 연결 확인 ──────────────────────────────────────────────────────
echo -e "\n${BOLD}[4/5] router 연결 확인${NC}"
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

# ── 5. 컨테이너 네트워크 설정 ────────────────────────────────────────────────
echo -e "\n${BOLD}[5/5] 컨테이너 네트워크 설정${NC}"

# 공통: eth1 IP + default gw 설정
setup_container_net() {
  local node="$1" ip="$2" gw="$3"
  local cname="clab-${TOPO_NAME}-${node}"
  docker inspect "$cname" &>/dev/null || return 0

  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")
  nsenter -t "$pid" -n -- ip addr replace "$ip" dev eth1
  nsenter -t "$pid" -n -- ip link set eth1 up
  nsenter -t "$pid" -n -- ip route replace default via "$gw"
  ok "$node  eth1=$ip  gw=$gw"
}

# 추가 경로 설정
setup_extra_route() {
  local node="$1" dest="$2" gw="$3"
  local cname="clab-${TOPO_NAME}-${node}"
  docker inspect "$cname" &>/dev/null || return 0
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")
  nsenter -t "$pid" -n -- ip route replace "$dest" via "$gw"
  ok "$node  route $dest via $gw"
}

# DVWA: eth1=10.0.10.10, gw=10.0.10.1(router)
setup_container_net "dvwa" "10.0.10.10/24" "10.0.10.1"
setup_extra_route   "dvwa" "10.0.20.0/24"  "10.0.10.254"

# Spring: eth1=10.0.10.20, gw=10.0.10.1(router)
setup_container_net "spring" "10.0.10.20/24" "10.0.10.1"
setup_extra_route   "spring" "10.0.20.0/24"  "10.0.10.254"

# fw-int: eth1(DMZ) + eth2(Intranet) + eth3(DB) + iptables
setup_fwint_net() {
  local cname="clab-${TOPO_NAME}-fw-int"
  docker inspect "$cname" &>/dev/null || return 0

  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")

  nsenter -t "$pid" -n -- ip addr replace "10.0.10.254/24" dev eth1
  nsenter -t "$pid" -n -- ip link set eth1 up
  nsenter -t "$pid" -n -- ip addr replace "10.0.20.1/24"   dev eth2
  nsenter -t "$pid" -n -- ip link set eth2 up
  nsenter -t "$pid" -n -- ip addr replace "10.0.30.1/24"   dev eth3
  nsenter -t "$pid" -n -- ip link set eth3 up
  ok "fw-int  eth1=10.0.10.254/24  eth2=10.0.20.1/24  eth3=10.0.30.1/24"

  # ── iptables 방화벽 정책 ────────────────────────────────────────────────
  docker exec "$cname" iptables -P FORWARD DROP

  # DVWA(10.0.10.10) → WAS(10.0.20.10):3306
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.10.10 -d 10.0.20.10 -p tcp --dport 3306 -j ACCEPT
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.20.10 -d 10.0.10.10 -p tcp --sport 3306 \
    -m state --state ESTABLISHED -j ACCEPT

  # Spring(10.0.10.20) → WAS(10.0.20.10):3306
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.10.20 -d 10.0.20.10 -p tcp --dport 3306 -j ACCEPT
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.20.10 -d 10.0.10.20 -p tcp --sport 3306 \
    -m state --state ESTABLISHED -j ACCEPT

  # WAS(10.0.20.10) → MySQL(10.0.30.10):3306
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.20.10 -d 10.0.30.10 -p tcp --dport 3306 -j ACCEPT
  docker exec "$cname" iptables -A FORWARD \
    -s 10.0.30.10 -d 10.0.20.10 -p tcp --sport 3306 \
    -m state --state ESTABLISHED -j ACCEPT

  ok "fw-int  iptables: DVWA→WAS, Spring→WAS, WAS→MySQL ALLOW, 그 외 FORWARD DROP"
}
setup_fwint_net

# WAS(ProxySQL): eth1=10.0.20.10, gw=10.0.20.1
setup_container_net "was" "10.0.20.10/24" "10.0.20.1"
setup_extra_route   "was" "10.0.30.0/24"  "10.0.20.1"

# MySQL(DB 존): eth1=10.0.30.10, gw=10.0.30.1
setup_mysql_net() {
  local cname="clab-${TOPO_NAME}-mysqlserver1"
  docker inspect "$cname" &>/dev/null || return 0

  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname")
  nsenter -t "$pid" -n -- ip addr replace "10.0.30.10/24" dev eth1
  nsenter -t "$pid" -n -- ip link set eth1 up
  nsenter -t "$pid" -n -- ip route replace default via "10.0.30.1"
  ok "mysqlserver1  eth1=10.0.30.10/24  gw=10.0.30.1"
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
