#!/usr/bin/env bash
# =============================================================================
#  cleanup.sh  — VTS2 전체 정리
#
#  제거 순서:
#    1. Suricata 컨테이너
#    2. docker compose down
#    3. iptables NFQUEUE / ACCEPT 룰
#    4. br_netfilter sysctl 초기화
#    5. 호스트 라우팅
#    6. veth 페어
#    7. 브리지 (sw-dmz, sw-intranet, sw-db)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
skip() { echo -e "  ${YELLOW}-${NC} $* (없음, 건너뜀)"; }

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}[FATAL]${NC} root 권한 필요: sudo $0"; exit 1; }

del_link() {
  local iface=$1
  if ip link show "$iface" &>/dev/null; then
    ip link delete "$iface" 2>/dev/null && ok "삭제: $iface" || warn "삭제 실패: $iface"
  else
    skip "$iface"
  fi
}

del_route() {
  local net=$1 rest="${@:2}"
  if ip route show "$net" $rest &>/dev/null; then
    ip route del "$net" $rest 2>/dev/null && ok "라우트 삭제: $net" || warn "라우트 삭제 실패: $net"
  else
    skip "라우트 $net"
  fi
}

# ── 1. Suricata 컨테이너 ─────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/7] Suricata 컨테이너 제거${NC}"
if docker inspect suricata-ips &>/dev/null; then
  docker rm -f suricata-ips && ok "suricata-ips 제거"
else
  skip "suricata-ips"
fi

# ── 2. docker compose down ────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/7] docker compose down${NC}"
if docker compose ps -q 2>/dev/null | grep -q .; then
  docker compose down && ok "compose 컨테이너 전체 종료"
else
  skip "실행 중인 compose 컨테이너 없음"
fi

# ── 3. iptables 룰 ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/7] iptables 룰 제거${NC}"

# NFQUEUE 룰 (sw-dmz 기준 — 현재 버전)
iptables -D FORWARD -i sw-dmz -j NFQUEUE --queue-num 0 --queue-bypass 2>/dev/null \
  && ok "NFQ -i sw-dmz 삭제" || skip "NFQ -i sw-dmz"
iptables -D FORWARD -o sw-dmz -j NFQUEUE --queue-num 0 --queue-bypass 2>/dev/null \
  && ok "NFQ -o sw-dmz 삭제" || skip "NFQ -o sw-dmz"

# NFQUEUE 룰 (veth-sur 기준 — 이전 버전 잔존 시 정리)
iptables -D FORWARD -i veth-sur -j NFQUEUE --queue-num 0 --queue-bypass 2>/dev/null \
  && ok "NFQ -i veth-sur 삭제" || skip "NFQ -i veth-sur"
iptables -D FORWARD -o veth-sur -j NFQUEUE --queue-num 0 --queue-bypass 2>/dev/null \
  && ok "NFQ -o veth-sur 삭제" || skip "NFQ -o veth-sur"

# 잔여 NFQUEUE 룰 전부 제거
while iptables -D FORWARD -j NFQUEUE 2>/dev/null; do true; done
ok "잔여 NFQUEUE 룰 정리"

# ContainerLab / deploy 스크립트가 추가한 브리지 ACCEPT 룰
for br in sw-dmz sw-intranet sw-db; do
  iptables -D FORWARD -i "$br" -j ACCEPT 2>/dev/null && ok "ACCEPT -i $br 삭제" || skip "ACCEPT -i $br"
  iptables -D FORWARD -o "$br" -j ACCEPT 2>/dev/null && ok "ACCEPT -o $br 삭제" || skip "ACCEPT -o $br"
done

# ── 4. br_netfilter sysctl 초기화 ────────────────────────────────────────────
echo -e "\n${BOLD}[4/7] br_netfilter sysctl 초기화${NC}"
if sysctl -q net.bridge.bridge-nf-call-iptables 2>/dev/null | grep -q "= 1"; then
  sysctl -w net.bridge.bridge-nf-call-iptables=0 -q && ok "bridge-nf-call-iptables=0"
else
  skip "bridge-nf-call-iptables (이미 0 또는 모듈 없음)"
fi

# ── 5. 호스트 라우팅 ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[5/7] 호스트 라우팅 제거${NC}"
del_route 10.0.10.0/24 via 10.0.1.1 dev veth-ext
del_route 10.0.20.0/24 via 10.0.1.1 dev veth-ext

# ── 6. veth 페어 ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[6/7] veth 페어 제거${NC}"
# 한쪽 삭제하면 반대쪽(컨테이너 netns)도 자동 삭제
for iface in \
  veth-ext veth-sur veth-dvwa veth-spring \
  veth-fwdmz veth-fwint veth-fwdb \
  veth-was veth-mysql veth-dmz veth-dmz-sw; do
  del_link "$iface"
done

# br 쪽 잔존 인터페이스
for iface in \
  veth-dvwa-br veth-spring-br veth-fwdmz-br \
  veth-fwint-br veth-fwdb-br veth-was-br \
  veth-mysql-br veth-ext-r veth-sur-r; do
  del_link "$iface"
done

# ── 7. 브리지 ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[7/7] 브리지 제거${NC}"
for br in sw-dmz sw-intranet sw-db; do
  del_link "$br"
done

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}정리 완료 ✔${NC}"
echo ""
echo "재배포하려면:"
echo "  sudo ./deploy-docker-compose.sh"
echo "  sudo ./start-suricata.sh"
echo ""
