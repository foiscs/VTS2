#!/usr/bin/env bash
# =============================================================================
#  start-suricata.sh  — Suricata NFQ IPS 시작
#
#  구조: Router ↔ veth-sur ↔ sw-dmz ↔ DMZ
#         br_netfilter + iptables NFQUEUE → Suricata --nfq
#
#  1. veth-sur 확인 + sw-dmz 브리지 연결 확인
#  2. br_netfilter 로드 + iptables NFQ 규칙 설정
#  3. Suricata 시작 (NFQ 모드)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SURICATA_IMAGE="jasonish/suricata:8.0.4-amd64"
SURICATA_CONTAINER="suricata-ips"
VETH_SUR="veth-sur"
SW_DMZ_BRIDGE="sw-dmz"
NFQ_NUM=0

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()  { echo -e "  ${GREEN}✔${NC} $*"; }
warn(){ echo -e "  ${YELLOW}⚠${NC} $*"; }
die() { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"

# ── 1. veth-sur 확인 + sw-dmz 연결 ──────────────────────────────────────────
echo -e "\n${BOLD}[1/3] veth-sur 확인${NC}"
ip link show "$VETH_SUR" &>/dev/null \
  || die "veth-sur 없음 → 먼저 실행:  sudo ./deploy-docker-compose.sh"
ip link set "$VETH_SUR" up
ip link set "$VETH_SUR" promisc on

# sw-dmz 브리지에 연결되어 있지 않으면 연결
MASTER=$(ip link show "$VETH_SUR" | grep -oP 'master \K\S+' || true)
if [ "$MASTER" != "$SW_DMZ_BRIDGE" ]; then
  ip link set "$VETH_SUR" master "$SW_DMZ_BRIDGE"
  ok "veth-sur → $SW_DMZ_BRIDGE 연결"
else
  ok "veth-sur 이미 $SW_DMZ_BRIDGE 연결됨"
fi

# ── 2. br_netfilter + iptables NFQ 규칙 ──────────────────────────────────────
echo -e "\n${BOLD}[2/3] br_netfilter + NFQ 규칙 설정${NC}"

# br_netfilter 로드 (브리지 트래픽을 iptables로 전달)
modprobe br_netfilter 2>/dev/null || warn "br_netfilter 이미 로드됨"
sysctl -w net.bridge.bridge-nf-call-iptables=1 -q
ok "br_netfilter 활성화"

# 기존 NFQ 규칙 제거 (중복 방지)
iptables -D FORWARD -i "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass 2>/dev/null || true
iptables -D FORWARD -o "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass 2>/dev/null || true

# 새 NFQ 규칙 추가 (veth-sur 양방향 — 외부↔DMZ 트래픽 전량)
iptables -I FORWARD -i "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass
iptables -I FORWARD -o "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass
ok "iptables NFQUEUE 규칙 설정 (queue $NFQ_NUM, bypass)"

# ── 3. Suricata 시작 (NFQ 모드) ───────────────────────────────────────────────
echo -e "\n${BOLD}[3/3] Suricata 시작 (NFQ IPS)${NC}"
docker rm -f "$SURICATA_CONTAINER" 2>/dev/null || true
mkdir -p /var/log/suricata

docker run -d \
  --name    "$SURICATA_CONTAINER" \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_NICE \
  --restart unless-stopped \
  -v "$SCRIPT_DIR/configs/suricata":/etc/suricata \
  -v /var/log/suricata:/var/log/suricata \
  "$SURICATA_IMAGE" \
  -c /etc/suricata/suricata.yaml --nfq -v

ok "컨테이너 시작: $SURICATA_CONTAINER (NFQ 모드)"
echo -e "\n  로그:  docker logs -f $SURICATA_CONTAINER"
echo ""
