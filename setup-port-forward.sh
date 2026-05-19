#!/usr/bin/env bash
# =============================================================================
#  setup-port-forward.sh — 외부 PC → DMZ 포트 포워딩
#
#  host:8001 → DVWA  (10.0.10.10:80)
#  host:8002 → Spring (10.0.10.20:8080)
#
#  트래픽 경로: 외부PC → host → veth-ext → router → Suricata → DMZ
#  (Suricata 모니터링 유지)
#
#  전제조건:
#    1. deploy-router-only.sh 실행 완료 (veth-ext, route 설정됨)
#    2. start-suricata.sh 실행 완료
#
#  정리:
#    sudo ./setup-port-forward.sh --flush
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
ok()  { echo -e "  ${GREEN}✔${NC} $*"; }
warn(){ echo -e "  ${YELLOW}⚠${NC} $*"; }
die() { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"

VETH_EXT="veth-ext"
DVWA_IP="10.0.10.10"
DVWA_PORT="80"
PHP_IP="10.0.10.11"
DVWA_PORT="80"
JUICE_IP="10.0.10.12"
JUICE_PORT="3000"
SPRING_IP="10.0.10.20"

SPRING_PORT="8080"
EXT_PORT_DVWA="8001"
EXT_PORT_PHP="8002"
EXT_PORT_JUICE="8003"
EXT_PORT_SPRING="8004"

# 외부 인터페이스 자동 감지
EXT_IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
[ -n "$EXT_IFACE" ] || die "외부 인터페이스를 찾을 수 없습니다"

# ── --flush ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--flush" ]; then
  echo "포트 포워딩 정리 중..."
  iptables -t nat -D PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_DVWA" \
    -j DNAT --to-destination "$DVWA_IP:$DVWA_PORT" 2>/dev/null && ok "DVWA DNAT 제거" || ok "없음"
  iptables -t nat -D PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_PHP" \
    -j DNAT --to-destination "$PHP_IP:$PHP_PORT" 2>/dev/null && ok "PHP DNAT 제거" || ok "없음"
  iptables -t nat -D PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_JUICE" \
    -j DNAT --to-destination "$JUICE_IP:$JUICE_PORT" 2>/dev/null && ok "JUICE DNAT 제거" || ok "없음"
  iptables -t nat -D PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_SPRING" \
    -j DNAT --to-destination "$SPRING_IP:$SPRING_PORT" 2>/dev/null && ok "Spring DNAT 제거" || ok "없음"
  iptables -t nat -D POSTROUTING -o "$VETH_EXT" \
    -j MASQUERADE 2>/dev/null && ok "MASQUERADE 제거" || ok "없음"
  iptables -D FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
    --dport "$DVWA_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
    --dport "$PHP_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
    --dport "$JUICE_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
    --dport "$SPRING_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$VETH_EXT" -o "$EXT_IFACE" \
    -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  exit 0
fi

# ── 사전 확인 ─────────────────────────────────────────────────────────────────
ip link show "$VETH_EXT" &>/dev/null || die "veth-ext 없음 — deploy-router-only.sh 먼저 실행"

echo -e "\n${BOLD}외부 인터페이스: $EXT_IFACE${NC}"
echo -e "  host IP: $(ip -4 addr show "$EXT_IFACE" | grep -oP '(?<=inet )\S+' | cut -d/ -f1)"

# ── IP 포워딩 활성화 ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/3] IP 포워딩 확인${NC}"
sysctl -w net.ipv4.ip_forward=1 > /dev/null
ok "ip_forward=1"

# ── DNAT 규칙 ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/3] DNAT 규칙 추가${NC}"

# DVWA: host:8001 → 10.0.10.10:80
iptables -t nat -C PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_DVWA" \
  -j DNAT --to-destination "$DVWA_IP:$DVWA_PORT" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_DVWA" \
       -j DNAT --to-destination "$DVWA_IP:$DVWA_PORT"
ok "DVWA   host:$EXT_PORT_DVWA → $DVWA_IP:$DVWA_PORT"

# PHP: host:8002 → 10.0.10.11:80
iptables -t nat -C PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_PHP" \
 -j DNAT --to-destination "$PHP_IP:$PHP_PORT" 2>/dev/null \
|| iptables -t nat -A PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_PHP" \
 -j DNAT --to-destination "$PHP_IP:$PHP_PORT"
ok "PHP   host:$EXT_PORT_PHP → $PHP_IP:$PHP_PORT"

# DVWA: host:8003 → 10.0.10.12:3000
iptables -t nat -C PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_JUICE" \
 -j DNAT --to-destination "$JUICE_IP:$JUICE_PORT" 2>/dev/null \
|| iptables -t nat -A PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_JUICE" \
 -j DNAT --to-destination "$JUICE_IP:$JUICE_PORT"
ok "JUICE   host:$EXT_PORT_JUICE → $JUICE_IP:$JUICE_PORT"

# Spring: host:8004 → 10.0.10.20:8080
iptables -t nat -C PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_SPRING" \
  -j DNAT --to-destination "$SPRING_IP:$SPRING_PORT" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$EXT_IFACE" -p tcp --dport "$EXT_PORT_SPRING" \
       -j DNAT --to-destination "$SPRING_IP:$SPRING_PORT"
ok "Spring host:$EXT_PORT_SPRING → $SPRING_IP:$SPRING_PORT"

# MASQUERADE: veth-ext로 나가는 패킷의 src를 10.0.1.100으로 변환 (리턴 경로 확보)
iptables -t nat -C POSTROUTING -o "$VETH_EXT" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$VETH_EXT" -j MASQUERADE
ok "MASQUERADE on $VETH_EXT"

# ── FORWARD 규칙 ──────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/3] FORWARD 규칙 추가${NC}"

iptables -C FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
  --dport "$DVWA_PORT" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
       --dport "$DVWA_PORT" -j ACCEPT
ok "FORWARD $EXT_IFACE → $VETH_EXT :$DVWA_PORT ACCEPT"

iptables -C FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
 --dport "$PHP_PORT" -j ACCEPT 2>/dev/null \
|| iptables -A FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
 --dport "$PHP_PORT" -j ACCEPT
ok "FORWARD $EXT_IFACE → $VETH_EXT :$PHP_PORT ACCEPT"

iptables -C FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
 --dport "$JUICE_PORT" -j ACCEPT 2>/dev/null \
|| iptables -A FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
 --dport "$JUICE_PORT" -j ACCEPT
ok "FORWARD $EXT_IFACE → $VETH_EXT :$JUICE_PORT ACCEPT"

iptables -C FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
  --dport "$SPRING_PORT" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$EXT_IFACE" -o "$VETH_EXT" -p tcp \
       --dport "$SPRING_PORT" -j ACCEPT
ok "FORWARD $EXT_IFACE → $VETH_EXT :$SPRING_PORT ACCEPT"

iptables -C FORWARD -i "$VETH_EXT" -o "$EXT_IFACE" \
  -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$VETH_EXT" -o "$EXT_IFACE" \
       -m state --state ESTABLISHED,RELATED -j ACCEPT
ok "FORWARD $VETH_EXT → $EXT_IFACE ESTABLISHED ACCEPT"

# ── 완료 ─────────────────────────────────────────────────────────────────────
HOST_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP '(?<=inet )\S+' | cut -d/ -f1)
echo ""
echo -e "  ${BOLD}접속 주소:${NC}"
echo -e "    DVWA   →  http://${HOST_IP}:${EXT_PORT_DVWA}/"
echo -e "    PHP   →  http://${HOST_IP}:${EXT_PORT_PHP}/"
echo -e "    JUICE   →  http://${HOST_IP}:${EXT_PORT_JUICE}/"
echo -e "    Spring →  http://${HOST_IP}:${EXT_PORT_SPRING}/main/login"
echo ""
echo -e "  정리:  ${BOLD}sudo ./setup-port-forward.sh --flush${NC}"
echo ""

