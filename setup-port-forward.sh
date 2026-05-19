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
DVWA_IP="10.0.10.10";   DVWA_PORT="80";   EXT_PORT_DVWA="8001"
PHP_IP="10.0.10.30";    PHP_PORT="80";    EXT_PORT_PHP="8002"
JUICE_IP="10.0.10.40";  JUICE_PORT="3000"; EXT_PORT_JUICE="8003"
SPRING_IP="10.0.10.20"; SPRING_PORT="8080"; EXT_PORT_SPRING="8004"
VM_SUBNET="192.168.146.0/24"   # VM NAT 서브넷 (PC 라우팅용)

# 외부 인터페이스 자동 감지
EXT_IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
[ -n "$EXT_IFACE" ] || die "외부 인터페이스를 찾을 수 없습니다"

# DNAT 인터페이스 — 빈 문자열이면 모든 인터페이스에 적용
# 특정 인터페이스만 허용하려면: DNAT_IFACE="-i $EXT_IFACE"
DNAT_IFACE=""

# ── --flush ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--flush" ]; then
  echo "포트 포워딩 정리 중..."
  iptables -t nat -D PREROUTING -p tcp --dport "$EXT_PORT_DVWA" \
    -j DNAT --to-destination "$DVWA_IP:$DVWA_PORT" 2>/dev/null && ok "DVWA DNAT 제거" || ok "없음"
  iptables -t nat -D PREROUTING -p tcp --dport "$EXT_PORT_PHP" \
    -j DNAT --to-destination "$PHP_IP:$PHP_PORT" 2>/dev/null && ok "PHP DNAT 제거" || ok "없음"
  iptables -t nat -D PREROUTING -p tcp --dport "$EXT_PORT_JUICE" \
    -j DNAT --to-destination "$JUICE_IP:$JUICE_PORT" 2>/dev/null && ok "Juice DNAT 제거" || ok "없음"
  iptables -t nat -D PREROUTING -p tcp --dport "$EXT_PORT_SPRING" \
    -j DNAT --to-destination "$SPRING_IP:$SPRING_PORT" 2>/dev/null && ok "Spring DNAT 제거" || ok "없음"
  iptables -t nat -D POSTROUTING -o "$VETH_EXT" \
    -j MASQUERADE 2>/dev/null && ok "MASQUERADE 제거" || ok "없음"
  iptables -t nat -D POSTROUTING -s "$VM_SUBNET" -d 10.0.0.0/8 \
    -j MASQUERADE 2>/dev/null && ok "PC 직접접근 MASQUERADE 제거" || ok "없음"
  iptables -D FORWARD -o "$VETH_EXT" -p tcp \
    --dport "$DVWA_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$VETH_EXT" -p tcp \
    --dport "$PHP_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$VETH_EXT" -p tcp \
    --dport "$JUICE_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$VETH_EXT" -p tcp \
    --dport "$SPRING_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$VETH_EXT" \
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
iptables -t nat -C PREROUTING -p tcp --dport "$EXT_PORT_DVWA" \
  -j DNAT --to-destination "$DVWA_IP:$DVWA_PORT" 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport "$EXT_PORT_DVWA" \
       -j DNAT --to-destination "$DVWA_IP:$DVWA_PORT"
ok "DVWA   host:$EXT_PORT_DVWA → $DVWA_IP:$DVWA_PORT"

# PHP: host:8002 → 10.0.10.30:80
iptables -t nat -C PREROUTING -p tcp --dport "$EXT_PORT_PHP" \
  -j DNAT --to-destination "$PHP_IP:$PHP_PORT" 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport "$EXT_PORT_PHP" \
       -j DNAT --to-destination "$PHP_IP:$PHP_PORT"
ok "PHP    host:$EXT_PORT_PHP → $PHP_IP:$PHP_PORT"

# Juice Shop: host:8003 → 10.0.10.40:3000
iptables -t nat -C PREROUTING -p tcp --dport "$EXT_PORT_JUICE" \
  -j DNAT --to-destination "$JUICE_IP:$JUICE_PORT" 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport "$EXT_PORT_JUICE" \
       -j DNAT --to-destination "$JUICE_IP:$JUICE_PORT"
ok "Juice  host:$EXT_PORT_JUICE → $JUICE_IP:$JUICE_PORT"

# Spring: host:8004 → 10.0.10.20:8080
iptables -t nat -C PREROUTING -p tcp --dport "$EXT_PORT_SPRING" \
  -j DNAT --to-destination "$SPRING_IP:$SPRING_PORT" 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport "$EXT_PORT_SPRING" \
       -j DNAT --to-destination "$SPRING_IP:$SPRING_PORT"
ok "Spring host:$EXT_PORT_SPRING → $SPRING_IP:$SPRING_PORT"

# MASQUERADE: veth-ext로 나가는 패킷의 src를 10.0.1.100으로 변환 (리턴 경로 확보)
iptables -t nat -C POSTROUTING -o "$VETH_EXT" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$VETH_EXT" -j MASQUERADE
ok "MASQUERADE on $VETH_EXT"

# PC → 내부망 직접 접근용 마스커레이드 (VM NAT 환경)
# PC에서 route add 10.0.x.x/24 via 192.168.146.128 설정 시 리턴 경로 확보
iptables -t nat -C POSTROUTING -s "$VM_SUBNET" -d 10.0.0.0/8 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$VM_SUBNET" -d 10.0.0.0/8 -j MASQUERADE
ok "MASQUERADE  $VM_SUBNET → 10.0.0.0/8 (PC 직접 접근 리턴 경로)"

# ── FORWARD 규칙 ──────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/3] FORWARD 규칙 추가${NC}"

# FORWARD 규칙을 맨 앞에 삽입 (Docker 체인보다 먼저 처리되어야 함)
# -C 체크 후 없을 때만 -I 1 삽입
iptables -C FORWARD -o "$VETH_EXT" \
  -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -o "$VETH_EXT" \
       -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -C FORWARD -i "$VETH_EXT" \
  -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -i "$VETH_EXT" \
       -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -C FORWARD -o "$VETH_EXT" -p tcp --dport "$SPRING_PORT" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -o "$VETH_EXT" -p tcp --dport "$SPRING_PORT" -j ACCEPT
ok "FORWARD → $VETH_EXT :$SPRING_PORT ACCEPT"

iptables -C FORWARD -o "$VETH_EXT" -p tcp --dport "$JUICE_PORT" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -o "$VETH_EXT" -p tcp --dport "$JUICE_PORT" -j ACCEPT
ok "FORWARD → $VETH_EXT :$JUICE_PORT ACCEPT"

iptables -C FORWARD -o "$VETH_EXT" -p tcp --dport "$PHP_PORT" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -o "$VETH_EXT" -p tcp --dport "$PHP_PORT" -j ACCEPT
ok "FORWARD → $VETH_EXT :$PHP_PORT ACCEPT"

iptables -C FORWARD -o "$VETH_EXT" -p tcp --dport "$DVWA_PORT" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -o "$VETH_EXT" -p tcp --dport "$DVWA_PORT" -j ACCEPT
ok "FORWARD → $VETH_EXT :$DVWA_PORT ACCEPT (최상단 삽입, Docker 체인 우선)"

# ── 완료 ─────────────────────────────────────────────────────────────────────
HOST_IP=$(ip -4 addr show "$EXT_IFACE" | grep -oP '(?<=inet )\S+' | cut -d/ -f1)
echo ""
echo -e "  ${BOLD}접속 주소:${NC}"
echo -e "    DVWA       →  http://${HOST_IP}:${EXT_PORT_DVWA}/"
echo -e "    PHP        →  http://${HOST_IP}:${EXT_PORT_PHP}/"
echo -e "    Juice Shop →  http://${HOST_IP}:${EXT_PORT_JUICE}/"
echo -e "    Spring     →  http://${HOST_IP}:${EXT_PORT_SPRING}/main/login"
echo ""
echo -e "  정리:  ${BOLD}sudo ./setup-port-forward.sh --flush${NC}"
echo ""
