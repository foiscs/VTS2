#!/usr/bin/env bash
# =============================================================================
#  cleanup.sh  — VTS2 배포 시 추가된 네트워크 자원 전체 제거
#
#  제거 대상:
#    1. Suricata 컨테이너
#    2. iptables NFQ / 기타 FORWARD 룰
#    3. br_netfilter sysctl 초기화
#    4. 호스트 라우팅 (10.0.10/20 via veth-ext)
#    5. veth 페어 (한쪽 삭제하면 반대쪽도 자동 삭제)
#    6. 브리지 (sw-dmz, sw-intranet, sw-db)
# =============================================================================
set -uo pipefail

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
    ip route del "$net" $rest 2>/dev/null && ok "라우트 삭제: $net $rest" || warn "라우트 삭제 실패: $net"
  else
    skip "라우트 $net"
  fi
}

# ── 1. Suricata 컨테이너 ─────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/6] Suricata 컨테이너 제거${NC}"
if docker inspect suricata-ips &>/dev/null; then
  docker rm -f suricata-ips && ok "suricata-ips 제거"
else
  skip "suricata-ips"
fi

# ── 2. iptables 룰 ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/6] iptables 룰 제거${NC}"

# Suricata NFQ 룰 (start-suricata.sh 추가분)
iptables -D FORWARD -i veth-sur -j NFQUEUE --queue-num 0 --queue-bypass 2>/dev/null \
  && ok "NFQ FORWARD -i veth-sur 삭제" || skip "NFQ -i veth-sur"
iptables -D FORWARD -o veth-sur -j NFQUEUE --queue-num 0 --queue-bypass 2>/dev/null \
  && ok "NFQ FORWARD -o veth-sur 삭제" || skip "NFQ -o veth-sur"

# deploy 스크립트가 만든 브리지 ACCEPT 룰 (ContainerLab 스타일)
for br in sw-dmz sw-intranet sw-db; do
  iptables -D FORWARD -i "$br" -j ACCEPT 2>/dev/null && ok "FORWARD -i $br ACCEPT 삭제" || skip "FORWARD -i $br"
  iptables -D FORWARD -o "$br" -j ACCEPT 2>/dev/null && ok "FORWARD -o $br ACCEPT 삭제" || skip "FORWARD -o $br"
done

# 혹시 남은 NFQUEUE 룰 전부 (중복 설정 대비)
while iptables -D FORWARD -j NFQUEUE 2>/dev/null; do true; done
ok "잔여 NFQUEUE 룰 정리"

# ── 3. br_netfilter sysctl 초기화 ────────────────────────────────────────────
echo -e "\n${BOLD}[3/6] br_netfilter sysctl 초기화${NC}"
if sysctl -q net.bridge.bridge-nf-call-iptables 2>/dev/null | grep -q "= 1"; then
  sysctl -w net.bridge.bridge-nf-call-iptables=0 -q && ok "bridge-nf-call-iptables=0"
else
  skip "bridge-nf-call-iptables (이미 0 또는 모듈 없음)"
fi

# ── 4. 호스트 라우팅 ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}[4/6] 호스트 라우팅 제거${NC}"
del_route 10.0.10.0/24 via 10.0.1.1 dev veth-ext
del_route 10.0.20.0/24 via 10.0.1.1 dev veth-ext

# ── 5. veth 인터페이스 ────────────────────────────────────────────────────────
echo -e "\n${BOLD}[5/6] veth 페어 제거${NC}"
# 호스트 측 한쪽만 지우면 반대쪽(컨테이너 netns 쪽)도 자동 삭제
for iface in \
  veth-ext \
  veth-sur \
  veth-dvwa \
  veth-spring \
  veth-fwdmz \
  veth-fwint \
  veth-fwdb \
  veth-was \
  veth-mysql \
  veth-dmz \
  veth-dmz-sw; do
  del_link "$iface"
done

# br 쪽 잔존 인터페이스 (혹시 남아있을 경우)
for iface in \
  veth-dvwa-br \
  veth-spring-br \
  veth-fwdmz-br \
  veth-fwint-br \
  veth-fwdb-br \
  veth-was-br \
  veth-mysql-br \
  veth-ext-r \
  veth-sur-r; do
  del_link "$iface"
done

# ── 6. 브리지 ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[6/6] 브리지 제거${NC}"
for br in sw-dmz sw-intranet sw-db; do
  del_link "$br"
done

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}정리 완료${NC}"
echo ""
echo "남은 네트워크 상태 확인:"
echo "  ip link show"
echo "  iptables -L FORWARD -n --line-numbers"
echo ""
echo "재배포하려면:"
echo "  sudo ./deploy-docker-compose.sh"
echo "  sudo ./start-suricata.sh"
