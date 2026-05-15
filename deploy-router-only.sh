#!/usr/bin/env bash
# =============================================================================
#  deploy-router-only.sh
#  Router + Suricata(AF_PACKET inline IPS) + DMZ 단계별 배포 & 연결 테스트
#
#  트래픽 흐름:
#    VM (veth-ext: 10.0.1.100)
#      │
#    router:eth1 (10.0.1.1)   ← FRR 외부 경계
#    router:eth2 (10.0.10.1)
#      │ veth-sur ←──────────────────────┐
#    [Suricata --network host]            │ AF_PACKET inline IPS
#      │ veth-dmz ─→ veth-dmz-sw ────────┘
#      └─→ sw-dmz (Linux bridge)
#           ├── dvwa       eth1 (10.0.10.10/24)
#           └── juice-shop eth1 (10.0.10.11/24)
#
#  사용법:
#    sudo ./deploy-router-only.sh
#    sudo ./deploy-router-only.sh --destroy   # 전체 정리만
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="$SCRIPT_DIR/router-only.yml"
TOPO_NAME="router-only"

SURICATA_DOCKERFILE="$SCRIPT_DIR/DockerContainers/Suricata"
SURICATA_IMAGE="vts2-suricata:latest"
SURICATA_CONTAINER="suricata-ips"
SURICATA_CONFIG="$SCRIPT_DIR/configs/suricata"
SURICATA_LOGS="/var/log/suricata"

# ── veth 이름 (router-only.yml links 섹션과 일치) ───────────────────────────
VETH_EXT="veth-ext"       # host ↔ router:eth1  (VM 역할)
VETH_SUR="veth-sur"       # host ↔ router:eth2  (Suricata 입력)
VETH_DMZ="veth-dmz"       # Suricata 출력       (→ sw-dmz 브리지)
VETH_DMZ_SW="veth-dmz-sw" # veth-dmz 페어 반대편 (sw-dmz 브리지에 연결)
SW_DMZ_BRIDGE="sw-dmz"    # ContainerLab kind:bridge 노드명 = 브리지명

# ── IP 주소 ─────────────────────────────────────────────────────────────────
IP_VETH_EXT="10.0.1.100/24"
IP_ROUTER_ETH1="10.0.1.1"
IP_ROUTER_ETH2="10.0.10.1"
IP_DVWA="10.0.10.10/24"
IP_JUICESHOP="10.0.10.11/24"
GW_DMZ="$IP_ROUTER_ETH2"

# ── 컬러 출력 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
}
step() { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}✘ $*${NC}"; }
die()  { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

# ── 연결 테스트 헬퍼 ────────────────────────────────────────────────────────
TOTAL_TESTS=0; PASS_TESTS=0; FAIL_TESTS=0

ping_test() {
  local label="$1" target="$2" src="${3:-}"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  printf "  %-45s" "ping $target  ($label)"
  local cmd
  [ -n "$src" ] && cmd="ping -c 2 -W 2 -I $src $target" || cmd="ping -c 2 -W 2 $target"
  if $cmd &>/dev/null; then
    echo -e "${GREEN}✔ OK${NC}"; PASS_TESTS=$((PASS_TESTS + 1)); return 0
  else
    echo -e "${RED}✘ FAIL${NC}"; FAIL_TESTS=$((FAIL_TESTS + 1)); return 1
  fi
}

http_test() {
  local label="$1" url="$2"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  printf "  %-45s" "HTTP $url  ($label)"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^[23] ]]; then
    echo -e "${GREEN}✔ HTTP $code${NC}"; PASS_TESTS=$((PASS_TESTS + 1)); return 0
  else
    echo -e "${YELLOW}⚠ HTTP $code${NC}"; FAIL_TESTS=$((FAIL_TESTS + 1)); return 1
  fi
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다.  sudo $0"
}

require_cmd() {
  command -v "$1" &>/dev/null || die "필수 명령어 없음: $1  (설치 필요)"
}

# =============================================================================
# destroy: 전체 환경 정리
# =============================================================================
destroy() {
  banner "환경 정리"

  step "Suricata 컨테이너 제거: $SURICATA_CONTAINER"
  docker rm -f "$SURICATA_CONTAINER" 2>/dev/null \
    && ok "suricata 컨테이너 제거" || ok "없음 (건너뜀)"

  step "ContainerLab 토폴로지 제거: $TOPO_NAME"
  clab destroy -t "$TOPO_FILE" --cleanup 2>/dev/null \
    && ok "clab 토폴로지 제거" || ok "없음 (건너뜀)"

  step "veth-dmz 페어 제거"
  ip link del "$VETH_DMZ" 2>/dev/null \
    && ok "veth-dmz 제거" || ok "없음 (건너뜀)"

  step "veth-ext IP 플러시"
  ip addr flush dev "$VETH_EXT" 2>/dev/null && ok "veth-ext 플러시" || ok "없음"

  ok "정리 완료"
}

# =============================================================================
# main
# =============================================================================
banner "Router + Suricata(inline IPS) + DMZ  배포 시작"

require_root
require_cmd clab
require_cmd docker

[ "${1:-}" = "--destroy" ] && { destroy; exit 0; }

cd "$SCRIPT_DIR"

# =============================================================================
# STEP 0 │ 기존 환경 정리 (clean slate)
# =============================================================================
banner "STEP 0 │ 기존 환경 정리"
destroy

# =============================================================================
# STEP 1 │ Suricata 이미지 빌드
# =============================================================================
banner "STEP 1 │ Suricata 이미지 빌드"

step "Docker build: $SURICATA_IMAGE"
docker build -t "$SURICATA_IMAGE" "$SURICATA_DOCKERFILE"
ok "이미지 빌드 완료: $SURICATA_IMAGE"

# =============================================================================
# STEP 2 │ ContainerLab 토폴로지 배포
#   생성되는 노드: router / sw-dmz / dvwa / juice-shop
#   생성되는 veth: veth-ext(host↔router:eth1) / veth-sur(host↔router:eth2)
# =============================================================================
banner "STEP 2 │ ContainerLab 토폴로지 배포"

step "clab deploy: $TOPO_FILE"
clab deploy -t "$TOPO_FILE" --reconfigure
ok "ContainerLab 배포 완료"

step "배포 상태 확인"
clab inspect -t "$TOPO_FILE" || true

# =============================================================================
# STEP 3 │ host:veth-ext IP 설정  (VM 역할 시뮬레이션)
#   veth-ext 는 clab이 router:eth1 ↔ host:veth-ext 링크로 생성
# =============================================================================
banner "STEP 3 │ host veth-ext 설정 + router 연결 테스트"

step "veth-ext IP 설정: $IP_VETH_EXT"
ip addr flush dev "$VETH_EXT" 2>/dev/null || true
ip addr add "$IP_VETH_EXT" dev "$VETH_EXT"
ip link set "$VETH_EXT" up
ok "veth-ext: $IP_VETH_EXT 설정 완료"

# 기본 경로가 없으면 DMZ 응답 패킷이 돌아올 경로 추가
# (VM 역할이므로 DMZ 서브넷 → router 경유)
ip route add 10.0.10.0/24 via "$IP_ROUTER_ETH1" dev "$VETH_EXT" 2>/dev/null \
  && ok "route add: 10.0.10.0/24 via $IP_ROUTER_ETH1" \
  || ok "route 이미 존재 (건너뜀)"

step "FRR router 기동 대기 (최대 20초)"
for i in $(seq 1 20); do
  ping -c 1 -W 1 "$IP_ROUTER_ETH1" &>/dev/null && break
  printf "  . (%d/20)\r" "$i"; sleep 1
done
echo ""

echo -e "\n  ${BOLD}[ 연결 테스트 A: VM → router ]${NC}"
ping_test "VM → router:eth1" "$IP_ROUTER_ETH1" "$VETH_EXT"

# =============================================================================
# STEP 4 │ veth-dmz 페어 생성 + sw-dmz 브리지 연결
#   ContainerLab kind:bridge 노드는 브리지명 = 노드명 ("sw-dmz")
#   veth-dmz   : Suricata (host 네임스페이스)  ← AF_PACKET 출력 인터페이스
#   veth-dmz-sw: sw-dmz 브리지에 연결          → DMZ 멤버로 전달
# =============================================================================
banner "STEP 4 │ veth-dmz 페어 생성 + sw-dmz 브리지 연결"

step "sw-dmz 브리지 존재 확인"
# clab kind:bridge 가 생성한 브리지 이름 자동 탐지
ACTUAL_BRIDGE=""
ACTUAL_BRIDGE=$(ip link show type bridge 2>/dev/null \
  | grep -oP '^\d+: \K[^:@]+' \
  | grep -i 'dmz\|sw.dmz' | head -1 || true)

if [ -z "$ACTUAL_BRIDGE" ]; then
  warn "브리지 자동 탐지 실패 → 기본값 사용: $SW_DMZ_BRIDGE"
  ACTUAL_BRIDGE="$SW_DMZ_BRIDGE"
  # clab이 아직 브리지를 못 만들었다면 직접 생성
  if ! ip link show "$ACTUAL_BRIDGE" &>/dev/null; then
    ip link add name "$ACTUAL_BRIDGE" type bridge
    ip link set "$ACTUAL_BRIDGE" up
    warn "sw-dmz 브리지를 직접 생성했습니다"
  fi
else
  ok "브리지 탐지: $ACTUAL_BRIDGE"
fi
ip link show "$ACTUAL_BRIDGE" | head -1

step "veth 페어 생성: $VETH_DMZ ↔ $VETH_DMZ_SW"
ip link add "$VETH_DMZ" type veth peer name "$VETH_DMZ_SW"
ok "veth 페어 생성 완료"

step "$VETH_DMZ_SW → $ACTUAL_BRIDGE 브리지 슬레이브 연결"
ip link set "$VETH_DMZ_SW" master "$ACTUAL_BRIDGE"
ip link set "$VETH_DMZ"    up
ip link set "$VETH_DMZ_SW" up
ok "$VETH_DMZ_SW 브리지($ACTUAL_BRIDGE) 연결 완료"

step "veth-sur 링크 UP 확인 (clab이 이미 생성)"
ip link set "$VETH_SUR" up 2>/dev/null && ok "veth-sur up" || warn "veth-sur 없음 (clab 링크 확인)"

step "네트워크 인터페이스 요약"
echo "  veth-ext  : $(ip -br addr show $VETH_EXT   2>/dev/null | awk '{print $1, $3}' || echo 'N/A')"
echo "  veth-sur  : $(ip -br addr show $VETH_SUR   2>/dev/null | awk '{print $1}' || echo 'N/A')  (Suricata 입력)"
echo "  veth-dmz  : $(ip -br addr show $VETH_DMZ   2>/dev/null | awk '{print $1}' || echo 'N/A')  (Suricata 출력)"
echo "  veth-dmz-sw: (브리지 슬레이브 → $ACTUAL_BRIDGE)"

# =============================================================================
# STEP 5 │ DMZ 컨테이너 IP / Gateway 설정
#   kind:linux 컨테이너는 eth1 IP를 직접 할당해야 함
#   nsenter 방식: 호스트의 ip 명령을 컨테이너 네트워크 네임스페이스에서 실행
# =============================================================================
banner "STEP 5 │ DMZ 컨테이너 IP / Gateway 설정"

configure_container_net() {
  local node="$1" ip="$2" gw="$3"
  local cname="clab-${TOPO_NAME}-${node}"

  step "$cname  IP: $ip  GW: $gw"

  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$cname" 2>/dev/null) \
    || die "$cname 컨테이너를 찾을 수 없습니다 (clab 배포 확인)"

  nsenter -t "$pid" -n -- ip addr flush  dev eth1   2>/dev/null || true
  nsenter -t "$pid" -n -- ip addr add    "$ip" dev eth1
  nsenter -t "$pid" -n -- ip link set    eth1  up
  nsenter -t "$pid" -n -- ip route del   default    2>/dev/null || true
  nsenter -t "$pid" -n -- ip route add   default via "$gw"

  ok "$node: $ip  (gw $gw) 설정 완료"
}

configure_container_net "dvwa"       "$IP_DVWA"      "$GW_DMZ"
configure_container_net "juice-shop" "$IP_JUICESHOP" "$GW_DMZ"

# Suricata 없이 router → DMZ 직접 도달 테스트 (브리지 경로 검증)
echo -e "\n  ${BOLD}[ 연결 테스트 B: router → DMZ (Suricata 미경유) ]${NC}"
docker exec "clab-${TOPO_NAME}-router" ping -c 2 -W 2 "${IP_DVWA%/*}"      &>/dev/null \
  && ok "router → dvwa (${IP_DVWA%/*}) OK"           \
  || warn "router → dvwa 실패 (Suricata 없이 직접 경로 확인)"
docker exec "clab-${TOPO_NAME}-router" ping -c 2 -W 2 "${IP_JUICESHOP%/*}" &>/dev/null \
  && ok "router → juice-shop (${IP_JUICESHOP%/*}) OK" \
  || warn "router → juice-shop 실패"

# =============================================================================
# STEP 6 │ Suricata 인라인 IPS 시작  (--network host)
#
#  AF_PACKET inline 동작 원리:
#    veth-sur (입력) ──[Suricata: inspect / drop]──▶ veth-dmz (출력)
#    veth-dmz (입력) ──[Suricata: inspect / drop]──▶ veth-sur (출력)
#
#  ※ suricata.yaml의 af-packet 섹션(copy-mode: ips)이 inline 쌍을 정의하므로
#     CLI --af-packet 플래그를 사용하지 않음 (entrypoint.sh 참조)
# =============================================================================
banner "STEP 6 │ Suricata 인라인 IPS 시작  (--network host)"

step "로그 디렉터리 준비: $SURICATA_LOGS"
mkdir -p "$SURICATA_LOGS"

step "Suricata 컨테이너 실행"
docker run -d \
  --name  "$SURICATA_CONTAINER" \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_NICE \
  -e SURICATA_IFACE1="$VETH_SUR" \
  -e SURICATA_IFACE2="$VETH_DMZ" \
  -v "$SURICATA_CONFIG":/etc/suricata:ro \
  -v "$SURICATA_LOGS":/var/log/suricata \
  "$SURICATA_IMAGE"
ok "컨테이너 시작: $SURICATA_CONTAINER"

step "Suricata 패킷 처리 시작 대기 (최대 40초)"
for i in $(seq 1 40); do
  logs=$(docker logs "$SURICATA_CONTAINER" 2>&1)
  if echo "$logs" | grep -q "Starting packet processing"; then
    ok "Suricata 패킷 처리 시작 확인 (${i}s)"
    break
  fi
  if echo "$logs" | grep -qi "FATAL\|Error opening"; then
    fail "Suricata 시작 오류"
    docker logs "$SURICATA_CONTAINER" 2>&1 | tail -20
    die "Suricata 시작 실패 (로그 확인)"
  fi
  printf "  . (%d/40)\r" "$i"; sleep 1
done
echo ""

step "Suricata 최근 로그 (15줄)"
docker logs "$SURICATA_CONTAINER" 2>&1 | tail -15

# =============================================================================
# STEP 7 │ End-to-End 연결 테스트  (Suricata inline 통과)
#   경로: VM(veth-ext) → router → veth-sur → Suricata → veth-dmz → sw-dmz → DMZ
# =============================================================================
banner "STEP 7 │ End-to-End 연결 테스트 (Suricata inline 통과)"

echo -e "\n  ${BOLD}[ 연결 테스트 C: VM → router (재확인) ]${NC}"
ping_test "VM(veth-ext) → router:eth1" "$IP_ROUTER_ETH1" "$VETH_EXT"

echo -e "\n  ${BOLD}[ 연결 테스트 D: VM → DMZ (Suricata inline 경유) ]${NC}"
ping_test "VM → dvwa       (10.0.10.10)" "${IP_DVWA%/*}"      "$VETH_EXT"
ping_test "VM → juice-shop (10.0.10.11)" "${IP_JUICESHOP%/*}" "$VETH_EXT"

echo -e "\n  ${BOLD}[ 연결 테스트 E: HTTP 서비스 ]${NC}"
http_test "DVWA    " "http://${IP_DVWA%/*}:80"
http_test "JuiceShop" "http://${IP_JUICESHOP%/*}:3000"

# =============================================================================
# 완료 요약
# =============================================================================
banner "배포 완료 요약"

cat <<EOF

  ${BOLD}토폴로지:${NC}
    VM  veth-ext (${IP_VETH_EXT%/*})
     │
    router eth1 (${IP_ROUTER_ETH1})
    router eth2 (${IP_ROUTER_ETH2})
     │ ${VETH_SUR}
    ┌──────────────────────────┐
    │  Suricata IPS            │  [--network host]
    │  AF_PACKET inline        │  veth-sur ↔ veth-dmz
    └──────────────────────────┘
     │ ${VETH_DMZ} → ${VETH_DMZ_SW} → ${ACTUAL_BRIDGE}
     ├── dvwa       ${IP_DVWA}   → http://${IP_DVWA%/*}:80
     └── juice-shop ${IP_JUICESHOP}  → http://${IP_JUICESHOP%/*}:3000

  ${BOLD}Suricata 로그:${NC}
    실시간:  docker logs -f ${SURICATA_CONTAINER}
    fast.log: tail -f ${SURICATA_LOGS}/fast.log
    eve.json: tail -f ${SURICATA_LOGS}/eve.json | jq .

  ${BOLD}정리:${NC}
    sudo ./deploy-router-only.sh --destroy

EOF

echo -e "  ${BOLD}테스트 결과:${NC}  ${PASS_TESTS}/${TOTAL_TESTS} 통과"

if [ "$FAIL_TESTS" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}✔ 모든 연결 테스트 통과${NC}\n"
else
  echo -e "  ${YELLOW}⚠ ${FAIL_TESTS}개 테스트 실패${NC}"
  echo -e "  ${YELLOW}  Suricata 기동 직후라면 잠시 후 재시도:${NC}"
  echo -e "  ${YELLOW}  ping -I ${VETH_EXT} ${IP_DVWA%/*}${NC}\n"
fi
