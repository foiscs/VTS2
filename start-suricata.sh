#!/usr/bin/env bash
# =============================================================================
#  start-suricata.sh  — Suricata NFQ IPS 시작
#
#  실행 순서:
#    Phase 0. 커널 준비    br_netfilter 로드 + sysctl
#                          (NFQUEUE가 브리지 트래픽을 잡으려면 반드시 먼저)
#    Phase 8. NFQUEUE 룰   veth-sur 양방향 FORWARD → 큐 0
#                          (--queue-bypass: Suricata 뜨기 전 패킷 드롭 방지)
#    Phase 9. Suricata     docker run --nfq
#
#  전제:
#    deploy-docker-compose.sh 완료 후 실행
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

# ── Phase 0. 커널 준비 ────────────────────────────────────────────────────────
# br_netfilter 없으면 브리지 트래픽이 iptables NFQUEUE를 통과하지 않음 (RC①)
echo -e "\n${BOLD}[Phase 0] 커널 준비 (br_netfilter + sysctl)${NC}"

modprobe br_netfilter 2>/dev/null && ok "br_netfilter 로드" || ok "br_netfilter 이미 로드됨"
sysctl -w net.ipv4.ip_forward=1 -q
ok "net.ipv4.ip_forward=1"
sysctl -w net.bridge.bridge-nf-call-iptables=1 -q
ok "net.bridge.bridge-nf-call-iptables=1"

# ── 사전 확인: veth-sur + sw-dmz ─────────────────────────────────────────────
echo -e "\n${BOLD}[사전 확인] veth-sur + sw-dmz${NC}"
ip link show "$VETH_SUR" &>/dev/null \
  || die "veth-sur 없음 → 먼저 실행:  sudo ./deploy-docker-compose.sh"
ip link set "$VETH_SUR" up
ip link set "$VETH_SUR" promisc on

MASTER=$(ip link show "$VETH_SUR" | grep -oP 'master \K\S+' || true)
if [ "$MASTER" != "$SW_DMZ_BRIDGE" ]; then
  ip link set "$VETH_SUR" master "$SW_DMZ_BRIDGE"
  ok "veth-sur → $SW_DMZ_BRIDGE 연결"
else
  ok "veth-sur 이미 $SW_DMZ_BRIDGE 연결됨"
fi

# ── Phase 8. iptables NFQUEUE 룰 ─────────────────────────────────────────────
# Suricata보다 반드시 먼저 설정 — 큐가 없으면 Suricata 감시 무의미 (RC⑦)
# --queue-bypass: Suricata 미기동 시 패킷 드롭 방지
echo -e "\n${BOLD}[Phase 8] iptables NFQUEUE 룰 설정${NC}"

# 중복 방지: 기존 룰 제거 후 재추가
iptables -D FORWARD -i "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass 2>/dev/null || true
iptables -D FORWARD -o "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass 2>/dev/null || true

iptables -I FORWARD -i "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass
iptables -I FORWARD -o "$VETH_SUR" -j NFQUEUE --queue-num "$NFQ_NUM" --queue-bypass
ok "FORWARD -i/-o $VETH_SUR → NFQUEUE $NFQ_NUM (--queue-bypass 활성)"

echo -e "  적용된 NFQUEUE 룰:"
iptables -L FORWARD -n --line-numbers | grep NFQUEUE | awk '{print "    " $0}'

# ── Phase 9. Suricata 시작 ────────────────────────────────────────────────────
# NFQUEUE 룰 완료 후 시작 — 큐를 Suricata가 인계받으면 bypass 모드 해제 (RC⑦)
echo -e "\n${BOLD}[Phase 9] Suricata 시작 (NFQ IPS)${NC}"

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
  -c /etc/suricata/suricata.yaml -q "$NFQ_NUM" -v

ok "컨테이너 시작: $SURICATA_CONTAINER (NFQ IPS 모드)"

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Suricata IPS 가동 완료 ✔${NC}"
echo -e "  로그:    docker logs -f $SURICATA_CONTAINER"
echo -e "  이벤트:  tail -f /var/log/suricata/eve.json"
echo ""
