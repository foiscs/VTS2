#!/usr/bin/env bash
# =============================================================================
#  start-suricata.sh
#  Suricata AF_PACKET inline IPS 시작 스크립트
#
#  실행 전 필요:
#    sudo ./deploy-router-only.sh  (router + veth-ext / veth-sur 생성)
#
#  이 스크립트가 하는 일:
#    1. veth-sur  존재 확인  (clab이 router:eth2 ↔ host:veth-sur 링크로 생성)
#    2. veth-dmz  존재 확인  → 없으면 veth 페어 생성 + sw-dmz 브리지 연결
#    3. Suricata 컨테이너 시작 (--network host)
#    4. 인터페이스 바인딩 확인
#
#  재실행 시 멱등 동작:
#    veth-dmz 가 이미 있으면 생성을 건너뛰고 Suricata만 재시작
#
#  사용법:
#    sudo ./start-suricata.sh           # 시작
#    sudo ./start-suricata.sh --stop    # Suricata 컨테이너만 중지
#    sudo ./start-suricata.sh --status  # 인터페이스 + 컨테이너 상태 확인
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SURICATA_IMAGE="vts2-suricata:latest"
SURICATA_CONTAINER="suricata-ips"
SURICATA_CONFIG="$SCRIPT_DIR/configs/suricata"
SURICATA_LOGS="/var/log/suricata"

VETH_SUR="veth-sur"       # clab 생성: router:eth2 ↔ host:veth-sur (Suricata 입력)
VETH_DMZ="veth-dmz"       # 수동 생성: Suricata 출력
VETH_DMZ_SW="veth-dmz-sw" # veth-dmz 페어 반대편 → sw-dmz 브리지에 연결
SW_DMZ_BRIDGE="sw-dmz"    # Linux 브리지 이름 (DMZ 스위치)

# ── 컬러 출력 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
step()   { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()     { echo -e "  ${GREEN}✔ $*${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠ $*${NC}"; }
die()    { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"
}

# =============================================================================
# --status: 인터페이스 + 컨테이너 현재 상태 출력
# =============================================================================
show_status() {
  banner "인터페이스 상태"

  echo -e "\n  ${BOLD}[ veth 인터페이스 ]${NC}"
  for iface in "$VETH_SUR" "$VETH_DMZ" "$VETH_DMZ_SW"; do
    if ip link show "$iface" &>/dev/null; then
      state=$(ip -br link show "$iface" | awk '{print $2}')
      master=$(ip link show "$iface" | grep -oP 'master \K\S+' || echo "—")
      echo -e "  ${GREEN}✔${NC}  $iface  [$state]  master=$master"
    else
      echo -e "  ${RED}✘${NC}  $iface  (없음)"
    fi
  done

  echo -e "\n  ${BOLD}[ sw-dmz 브리지 ]${NC}"
  if ip link show "$SW_DMZ_BRIDGE" &>/dev/null 2>&1; then
    ip -br link show "$SW_DMZ_BRIDGE"
    echo "  슬레이브 포트:"
    bridge link show | grep "master $SW_DMZ_BRIDGE" | awk '{print "    " $2, $4, $6}' || echo "    (없음)"
  else
    echo -e "  ${YELLOW}⚠${NC}  $SW_DMZ_BRIDGE 브리지 없음"
  fi

  echo -e "\n  ${BOLD}[ Suricata 컨테이너 ]${NC}"
  if docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -q "^$SURICATA_CONTAINER"; then
    docker ps -a --format '  {{.Names}}  {{.Status}}  {{.Image}}' \
      | grep "$SURICATA_CONTAINER"
  else
    echo -e "  ${YELLOW}⚠${NC}  $SURICATA_CONTAINER 컨테이너 없음"
  fi
  echo ""
}

# =============================================================================
# --stop: Suricata 컨테이너 중지
# =============================================================================
stop_suricata() {
  banner "Suricata 중지"
  docker rm -f "$SURICATA_CONTAINER" 2>/dev/null \
    && ok "컨테이너 제거: $SURICATA_CONTAINER" \
    || ok "실행 중인 컨테이너 없음"
}

# =============================================================================
# main
# =============================================================================
require_root

case "${1:-}" in
  --status) show_status; exit 0 ;;
  --stop)   stop_suricata; exit 0 ;;
esac

banner "Suricata 인라인 IPS 시작"

# =============================================================================
# STEP 1: veth-sur 존재 확인  (clab이 만들어야 함)
# =============================================================================
step "STEP 1 │ veth-sur 확인 (clab router:eth2 ↔ host:veth-sur)"

if ip link show "$VETH_SUR" &>/dev/null; then
  ok "veth-sur 존재 확인"
  ip -br link show "$VETH_SUR"
else
  echo -e "  ${RED}✘ veth-sur 없음${NC}"
  echo ""
  echo "  veth-sur 는 ContainerLab 이 router:eth2 ↔ host:veth-sur 링크로 생성합니다."
  echo "  먼저 router를 배포하세요:"
  echo ""
  echo "    sudo clab deploy -t router-only.yml --reconfigure"
  echo ""
  die "veth-sur 없음 → clab 배포 필요"
fi

# veth-sur UP 보장
ip link set "$VETH_SUR" up
ok "veth-sur UP"

# =============================================================================
# STEP 2: veth-dmz 존재 확인 → 없으면 생성 + sw-dmz 연결
# =============================================================================
step "STEP 2 │ veth-dmz 확인 / 생성"

if ip link show "$VETH_DMZ" &>/dev/null; then
  ok "veth-dmz 이미 존재 — 생성 건너뜀"
  ip -br link show "$VETH_DMZ"

else
  warn "veth-dmz 없음 → 새로 생성합니다"

  # ── veth 페어 생성 ──────────────────────────────────────────────────────
  echo "  $ ip link add $VETH_DMZ type veth peer name $VETH_DMZ_SW"
  ip link add "$VETH_DMZ" type veth peer name "$VETH_DMZ_SW"

  echo "  $ ip link set $VETH_DMZ up"
  ip link set "$VETH_DMZ" up

  echo "  $ ip link set $VETH_DMZ_SW up"
  ip link set "$VETH_DMZ_SW" up

  ok "veth 페어 생성 완료: $VETH_DMZ ↔ $VETH_DMZ_SW"

  # ── sw-dmz 브리지에 연결 (브리지가 있을 때만) ───────────────────────────
  if ip link show "$SW_DMZ_BRIDGE" &>/dev/null; then
    echo "  $ ip link set $VETH_DMZ_SW master $SW_DMZ_BRIDGE"
    ip link set "$VETH_DMZ_SW" master "$SW_DMZ_BRIDGE"
    ok "$VETH_DMZ_SW → $SW_DMZ_BRIDGE 브리지 연결 완료"
  else
    warn "sw-dmz 브리지 없음 → $VETH_DMZ_SW 브리지 연결 건너뜀"
    warn "(DMZ 노드 추가 시 수동으로:  ip link set $VETH_DMZ_SW master $SW_DMZ_BRIDGE)"
  fi
fi

# veth-dmz-sw master 상태 재확인
if ip link show "$VETH_DMZ_SW" &>/dev/null; then
  master=$(ip link show "$VETH_DMZ_SW" | grep -oP 'master \K\S+' || echo "없음")
  echo -e "  ${BOLD}$VETH_DMZ_SW master:${NC} $master"
fi

# =============================================================================
# STEP 3: 기존 Suricata 컨테이너 정리 후 재시작
# =============================================================================
step "STEP 3 │ 기존 Suricata 컨테이너 정리"

docker rm -f "$SURICATA_CONTAINER" 2>/dev/null \
  && ok "기존 컨테이너 제거" \
  || ok "없음 (건너뜀)"

# =============================================================================
# STEP 4: Suricata 시작 (--network host)
# =============================================================================
step "STEP 4 │ Suricata 컨테이너 시작"

mkdir -p "$SURICATA_LOGS"

docker run -d \
  --name  "$SURICATA_CONTAINER" \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_NICE \
  --restart unless-stopped \
  -e SURICATA_IFACE1="$VETH_SUR" \
  -e SURICATA_IFACE2="$VETH_DMZ" \
  -v "$SURICATA_CONFIG":/etc/suricata:ro \
  -v "$SURICATA_LOGS":/var/log/suricata \
  "$SURICATA_IMAGE"

ok "컨테이너 시작: $SURICATA_CONTAINER"

# =============================================================================
# STEP 5: Suricata 인터페이스 바인딩 확인 (최대 40초)
# =============================================================================
step "STEP 5 │ Suricata 인터페이스 바인딩 대기"

for i in $(seq 1 40); do
  logs=$(docker logs "$SURICATA_CONTAINER" 2>&1)

  # 성공: 패킷 처리 시작
  if echo "$logs" | grep -q "Starting packet processing"; then
    ok "Suricata 패킷 처리 시작 확인 (${i}s)"
    break
  fi

  # 실패: FATAL 또는 인터페이스 오류
  if echo "$logs" | grep -qi "FATAL\|Error opening\|failed to open"; then
    echo -e "\n  ${RED}✘ Suricata 시작 오류 발생${NC}"
    echo ""
    docker logs "$SURICATA_CONTAINER" 2>&1 | tail -20
    echo ""

    # 인터페이스가 사라진 경우 안내
    if echo "$logs" | grep -qi "timeout\|$VETH_SUR\|$VETH_DMZ"; then
      echo -e "  ${YELLOW}인터페이스 소실 감지 — 다음을 실행하세요:${NC}"
      echo ""
      cat <<EOF
    # 1. veth-dmz 재생성
    sudo ip link add $VETH_DMZ type veth peer name $VETH_DMZ_SW
    sudo ip link set $VETH_DMZ up
    sudo ip link set $VETH_DMZ_SW up
    sudo ip link set $VETH_DMZ_SW master $SW_DMZ_BRIDGE

    # 2. Suricata 재시작
    sudo ./start-suricata.sh
EOF
    fi
    die "Suricata 시작 실패"
  fi

  printf "  . (%d/40)\r" "$i"
  sleep 1
done
echo ""

# =============================================================================
# 완료
# =============================================================================
banner "완료"

echo ""
docker ps --format '  {{.Names}}  {{.Status}}  {{.Image}}' \
  | grep "$SURICATA_CONTAINER" || true

cat <<EOF

  ${BOLD}inline 경로:${NC}
    router:eth2 ↔ ${VETH_SUR} ──[Suricata]── ${VETH_DMZ} ↔ ${VETH_DMZ_SW} → ${SW_DMZ_BRIDGE}

  ${BOLD}로그 확인:${NC}
    docker logs -f ${SURICATA_CONTAINER}
    tail -f ${SURICATA_LOGS}/fast.log

  ${BOLD}상태 확인:${NC}
    sudo ./start-suricata.sh --status

  ${BOLD}인터페이스 소실 시 복구:${NC}
    sudo ip link add ${VETH_DMZ} type veth peer name ${VETH_DMZ_SW}
    sudo ip link set ${VETH_DMZ} up
    sudo ip link set ${VETH_DMZ_SW} up
    sudo ip link set ${VETH_DMZ_SW} master ${SW_DMZ_BRIDGE}
    sudo ./start-suricata.sh
EOF
echo ""
