#!/usr/bin/env bash
# =============================================================================
#  deploy-docker-compose.sh  — VTS2 Docker Compose 배포
#
#  실행 순서 (레이스 컨디션 방지):
#    Phase 1. 호스트 브리지 생성       (sw-dmz, sw-intranet, sw-db)
#    Phase 2. Docker 이미지 빌드       (DVWA, Spring — 없을 때만)
#    Phase 3. docker compose up -d
#    Phase 4. 컨테이너 PID 폴링 대기   (sleep 3 대신 실제 확인)
#    Phase 5. veth 페어 생성 + 배선    (브리지 ↔ 컨테이너 netns)
#    Phase 6. 컨테이너 추가 라우팅     (nsenter)
#    Phase 7. fw-int iptables 정책     (인터페이스 UP 후에)
#    Phase 8. 호스트 라우팅
#
#  다음 단계:
#    sudo ./start-suricata.sh   ← br_netfilter + NFQ 룰 + Suricata 시작
#
#  정리:
#    sudo docker compose down
#    sudo ./cleanup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DVWA_IMAGE="vulnerables/web-dvwa:local"
DVWA_CONTEXT="$SCRIPT_DIR/DockerContainers/DVWA"
SPRING_IMAGE="vts-spring:latest"
SPRING_CONTEXT="$SCRIPT_DIR/DockerContainers/SpringServer"
PHP_IMAGE="vts-php:latest"
PHP_CONTEXT="$SCRIPT_DIR/DockerContainers/PhpServer"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()  { echo -e "  ${GREEN}✔${NC} $*"; }
warn(){ echo -e "  ${YELLOW}⚠${NC} $*"; }
die() { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"

# ── 헬퍼 ─────────────────────────────────────────────────────────────────────

# 컨테이너 PID가 0보다 클 때까지 폴링 (최대 30초)
wait_pid() {
  local cname=$1 timeout=60 elapsed=0
  while true; do
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$cname" 2>/dev/null || echo 0)
    [ "$pid" -gt 0 ] && return 0
    [ "$elapsed" -ge "$timeout" ] && die "$cname PID 확보 타임아웃 (${timeout}s)"
    sleep 0.5; elapsed=$((elapsed + 1))
  done
}

get_pid() { docker inspect -f '{{.State.Pid}}' "$1"; }

net_add() {
  # net_add <container> <host_iface> <container_iface> <ip/prefix> <gw>
  local cname=$1 host_if=$2 con_if=$3 ip=$4 gw=$5
  local pid; pid=$(get_pid "$cname")
  ip link set "$host_if" netns "$pid"
  nsenter -t "$pid" -n -- ip link set "$host_if" name "$con_if"
  nsenter -t "$pid" -n -- ip addr add "$ip" dev "$con_if"
  nsenter -t "$pid" -n -- ip link set "$con_if" up
  [ -n "$gw" ] && nsenter -t "$pid" -n -- ip route replace default via "$gw"
  ok "$cname  $con_if=$ip  gw=${gw:-(없음)}"
}

br_add_port() {
  local br=$1 iface=$2
  ip link set "$iface" master "$br"
  ip link set "$iface" up
}

# ── Phase 1. 호스트 브리지 생성 ───────────────────────────────────────────────
# veth를 브리지에 붙이기 전에 반드시 브리지가 존재해야 함 (RC②)
echo -e "\n${BOLD}[Phase 1/8] 호스트 브리지 생성${NC}"
for br in sw-dmz sw-intranet sw-db; do
  if ip link show "$br" &>/dev/null; then
    ok "$br 이미 존재 (건너뜀)"
  else
    ip link add "$br" type bridge
    ip link set "$br" up
    ok "$br 생성"
  fi
done

# ── Phase 2. Docker 이미지 빌드 ───────────────────────────────────────────────
# compose up 전에 이미지가 없으면 pull 실패 → 먼저 빌드 (RC③)
echo -e "\n${BOLD}[Phase 2/8] Docker 이미지 빌드${NC}"

build_image() {
  local image=$1 context=$2 label=$3
  if ! docker image inspect "$image" &>/dev/null; then
    echo -e "  빌드: ${BOLD}$image${NC}"
    docker build -t "$image" "$context" && ok "$label 빌드 완료" || die "$label 빌드 실패"
  else
    ok "$label 이미지 존재 (건너뜀): $image"
  fi
}

build_image "$DVWA_IMAGE"   "$DVWA_CONTEXT"   "DVWA"
build_image "$SPRING_IMAGE" "$SPRING_CONTEXT" "Spring"
build_image "$PHP_IMAGE"    "$PHP_CONTEXT"    "PHP"

# ── Phase 3. docker compose up ────────────────────────────────────────────────
echo -e "\n${BOLD}[Phase 3/8] docker compose up -d${NC}"
docker compose up -d
ok "compose 기동 요청 완료"

# ── Phase 4. 컨테이너 PID 폴링 ───────────────────────────────────────────────
# compose -d 리턴 시점 ≠ PID 안정화 시점 → sleep 3 대신 실제 폴링 (RC④)
echo -e "\n${BOLD}[Phase 4/8] 컨테이너 PID 안정화 대기${NC}"
for cname in router dvwa php juice spring fw-int was mysqlserver1; do
  printf "  대기: %-20s" "$cname"
  wait_pid "$cname"
  printf "PID=%-6s %b\n" "$(get_pid "$cname")" "${GREEN}✔${NC}"
done

# ── Phase 5. veth 페어 생성 + 배선 ───────────────────────────────────────────
# PID 검증 후 netns 이동 — 잘못된 PID로 이동하면 복구 불가 (RC⑤)
echo -e "\n${BOLD}[Phase 5/8] veth 페어 생성 + 브리지/netns 배선${NC}"

# ① host ↔ router eth1 (WAN: 10.0.1.0/24)
ip link add veth-ext type veth peer name veth-ext-r
ip addr add 10.0.1.100/24 dev veth-ext
ip link set veth-ext up
net_add router veth-ext-r eth1 10.0.1.1/24 ""

# ② router eth2 → veth-sur → sw-dmz
ip link add veth-sur type veth peer name veth-sur-r
net_add router veth-sur-r eth2 10.0.10.1/24 ""
ip link set veth-sur up
ip link set veth-sur promisc on
ip link set veth-sur master sw-dmz
ok "veth-sur → sw-dmz 연결 (Suricata 모니터링 경로)"

# ③ DVWA → sw-dmz
ip link add veth-dvwa type veth peer name veth-dvwa-br
br_add_port sw-dmz veth-dvwa-br
net_add dvwa veth-dvwa eth1 10.0.10.10/24 10.0.10.1

# ④ PHP → sw-dmz
ip link add veth-php type veth peer name veth-php-br
br_add_port sw-dmz veth-php-br
net_add php veth-php eth1 10.0.10.30/24 10.0.10.1

# ⑤ Juice Shop → sw-dmz
ip link add veth-juice type veth peer name veth-juice-br
br_add_port sw-dmz veth-juice-br
net_add juice veth-juice eth1 10.0.10.40/24 10.0.10.1

# ⑥ Spring → sw-dmz
ip link add veth-spring type veth peer name veth-spring-br
br_add_port sw-dmz veth-spring-br
net_add spring veth-spring eth1 10.0.10.20/24 10.0.10.1

# ⑦ fw-int: eth1→sw-dmz / eth2→sw-intranet / eth3→sw-db
ip link add veth-fwdmz type veth peer name veth-fwdmz-br
br_add_port sw-dmz veth-fwdmz-br

ip link add veth-fwint type veth peer name veth-fwint-br
br_add_port sw-intranet veth-fwint-br

ip link add veth-fwdb type veth peer name veth-fwdb-br
br_add_port sw-db veth-fwdb-br

pid_fw=$(get_pid fw-int)
for pair in "veth-fwdmz eth1 10.0.10.254/24" "veth-fwint eth2 10.0.20.1/24" "veth-fwdb eth3 10.0.30.1/24"; do
  read -r host_if con_if ip <<< "$pair"
  ip link set "$host_if" netns "$pid_fw"
  nsenter -t "$pid_fw" -n -- ip link set "$host_if" name "$con_if"
  nsenter -t "$pid_fw" -n -- ip addr add "$ip" dev "$con_if"
  nsenter -t "$pid_fw" -n -- ip link set "$con_if" up
done
ok "fw-int  eth1(DMZ)/eth2(Intranet)/eth3(DB) 배선 완료"

# ⑧ WAS → sw-intranet
ip link add veth-was type veth peer name veth-was-br
br_add_port sw-intranet veth-was-br
net_add was veth-was eth1 10.0.20.10/24 10.0.20.1

# ⑨ MySQL → sw-db
ip link add veth-mysql type veth peer name veth-mysql-br
br_add_port sw-db veth-mysql-br
net_add mysqlserver1 veth-mysql eth1 10.0.30.10/24 10.0.30.1

# ── Phase 6. 컨테이너 추가 라우팅 ────────────────────────────────────────────
echo -e "\n${BOLD}[Phase 6/8] 컨테이너 추가 라우팅 설정${NC}"

# router: Intranet/DB 존 경로 (fw-int 경유)
# 없으면 외부→Intranet/DB 트래픽이 라우터에서 드롭되어 Suricata가 못 봄
pid_router=$(get_pid router)
nsenter -t "$pid_router" -n -- ip route replace 10.0.20.0/24 via 10.0.10.254
ok "router  10.0.20.0/24 via 10.0.10.254 (fw-int)"
nsenter -t "$pid_router" -n -- ip route replace 10.0.30.0/24 via 10.0.10.254
ok "router  10.0.30.0/24 via 10.0.10.254 (fw-int)"

pid_fw=$(get_pid fw-int)
nsenter -t "$pid_fw" -n -- ip route replace default via 10.0.10.1
ok "fw-int  default gw → 10.0.10.1"

pid_dvwa=$(get_pid dvwa)
nsenter -t "$pid_dvwa" -n -- ip route replace 10.0.20.0/24 via 10.0.10.254
ok "dvwa  10.0.20.0/24 via 10.0.10.254"

pid_php=$(get_pid php)
nsenter -t "$pid_php" -n -- ip route replace 10.0.20.0/24 via 10.0.10.254
ok "php  10.0.20.0/24 via 10.0.10.254"

pid_juice=$(get_pid juice)
nsenter -t "$pid_juice" -n -- ip route replace 10.0.20.0/24 via 10.0.10.254
ok "juice  10.0.20.0/24 via 10.0.10.254"

pid_spring=$(get_pid spring)
nsenter -t "$pid_spring" -n -- ip route replace 10.0.20.0/24 via 10.0.10.254
ok "spring  10.0.20.0/24 via 10.0.10.254"

pid_was=$(get_pid was)
nsenter -t "$pid_was" -n -- ip route replace 10.0.30.0/24 via 10.0.20.1
ok "was  10.0.30.0/24 via 10.0.20.1"

# ── Phase 7. fw-int iptables ──────────────────────────────────────────────────
# 인터페이스 UP(Phase 5) 완료 후 설정해야 룰이 유효함 (RC⑥)
echo -e "\n${BOLD}[Phase 7/8] fw-int iptables 정책${NC}"

FW=fw-int
# 모의해킹 테스트 환경 — 전체 포워딩 허용
# 실제 차단은 Suricata가 담당 (drop 룰 추가 시 IPS 동작)
docker exec $FW iptables -P FORWARD ACCEPT
ok "fw-int iptables: FORWARD ACCEPT (모의해킹 환경 — Suricata가 탐지/차단 담당)"

# ── Phase 8. 호스트 라우팅 ────────────────────────────────────────────────────
echo -e "\n${BOLD}[Phase 8/8] 호스트 라우팅${NC}"
ip route replace 10.0.10.0/24 via 10.0.1.1 dev veth-ext
ok "route  10.0.10.0/24 via 10.0.1.1"
ip route replace 10.0.20.0/24 via 10.0.1.1 dev veth-ext
ok "route  10.0.20.0/24 via 10.0.1.1"

# ── 룰 파일 권한 설정 ────────────────────────────────────────────────────────
RULES_FILE="$SCRIPT_DIR/configs/suricata/rules/local.rules"
if [ -f "$RULES_FILE" ]; then
  chown "$SUDO_USER":"$SUDO_USER" "$RULES_FILE" 2>/dev/null || true
  chmod 664 "$RULES_FILE"
  ok "룰 파일 권한 설정: $RULES_FILE"
fi

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}배포 완료 ✔${NC}"
echo -e "  다음 단계:  ${BOLD}sudo ./start-suricata.sh${NC}"
echo ""
