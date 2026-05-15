#!/usr/bin/env bash
# =============================================================================
#  start-suricata.sh  — Suricata AF_PACKET inline IPS 시작
#
#  1. veth-sur 확인  (없으면 clab 배포 먼저)
#  2. veth-dmz 없으면 생성 + sw-dmz 연결
#  3. Suricata 시작 (--network host)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SURICATA_IMAGE="vts2-suricata:latest"
SURICATA_CONTAINER="suricata-ips"
VETH_SUR="veth-sur"
VETH_DMZ="veth-dmz"
VETH_DMZ_SW="veth-dmz-sw"
SW_DMZ_BRIDGE="sw-dmz"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()  { echo -e "  ${GREEN}✔${NC} $*"; }
warn(){ echo -e "  ${YELLOW}⚠${NC} $*"; }
die() { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"

# ── 1. veth-sur 확인 ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/3] veth-sur 확인${NC}"
ip link show "$VETH_SUR" &>/dev/null \
  || die "veth-sur 없음 → 먼저 실행:  sudo ./deploy-router-only.sh"
ip link set "$VETH_SUR" up
ok "veth-sur UP"

# ── 2. veth-dmz 없으면 생성 ──────────────────────────────────────────────────
echo -e "\n${BOLD}[2/3] veth-dmz 확인 / 생성${NC}"
if ip link show "$VETH_DMZ" &>/dev/null; then
  ok "veth-dmz 존재 (건너뜀)"
else
  ip link add "$VETH_DMZ" type veth peer name "$VETH_DMZ_SW"
  ip link set "$VETH_DMZ"    up
  ip link set "$VETH_DMZ_SW" up
  ok "veth-dmz ↔ veth-dmz-sw 생성"

  if ip link show "$SW_DMZ_BRIDGE" &>/dev/null; then
    ip link set "$VETH_DMZ_SW" master "$SW_DMZ_BRIDGE"
    ok "veth-dmz-sw → $SW_DMZ_BRIDGE 연결"
  else
    warn "sw-dmz 브리지 없음 — DMZ 추가 시:  ip link set $VETH_DMZ_SW master $SW_DMZ_BRIDGE"
  fi
fi

# ── 3. Suricata 시작 ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/3] Suricata 시작${NC}"
docker rm -f "$SURICATA_CONTAINER" 2>/dev/null || true
mkdir -p /var/log/suricata

docker run -d \
  --name    "$SURICATA_CONTAINER" \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_NICE \
  --restart unless-stopped \
  -e SURICATA_IFACE1="$VETH_SUR" \
  -e SURICATA_IFACE2="$VETH_DMZ" \
  -v "$SCRIPT_DIR/configs/suricata":/etc/suricata:ro \
  -v /var/log/suricata:/var/log/suricata \
  "$SURICATA_IMAGE"

ok "컨테이너 시작: $SURICATA_CONTAINER"
echo -e "\n  로그:  docker logs -f $SURICATA_CONTAINER"
echo ""
