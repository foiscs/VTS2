#!/bin/bash
# =============================================================================
#  entrypoint.sh — Suricata 인라인 IPS 래퍼
#
#  실행 방식:
#    --network host  +  SURICATA_IFACE1=veth-sur  SURICATA_IFACE2=veth-dmz
#
#  AF_PACKET inline IPS 쌍(copy-mode: ips)은 suricata.yaml의 af-packet: 섹션에
#  정의되므로 CLI --af-packet 플래그를 사용하지 않습니다.
#
#  ※ CLI --af-packet=iface 를 같이 쓰면 yaml의 af-packet 섹션(copy-mode,
#     copy-iface, cluster-id 등)이 무시되어 inline IPS가 동작하지 않습니다.
# =============================================================================

IFACE1="${SURICATA_IFACE1:-veth-sur}"
IFACE2="${SURICATA_IFACE2:-veth-dmz}"
CONFIG="${SURICATA_CONFIG:-/etc/suricata/suricata.yaml}"
TIMEOUT=60

echo "[entrypoint] Waiting for interfaces: $IFACE1 / $IFACE2 (timeout: ${TIMEOUT}s)"

elapsed=0
while true; do
  if ip link show "$IFACE1" &>/dev/null && ip link show "$IFACE2" &>/dev/null; then
    echo "[entrypoint] Interfaces ready: $IFACE1, $IFACE2"
    break
  fi
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "[entrypoint] ERROR: timeout waiting for interfaces ($IFACE1 / $IFACE2)"
    echo "[entrypoint] Available interfaces:"
    ip -br link show | awk '{print "  " $1, $2}'
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

# 인터페이스 promisc 모드 활성화 (AF_PACKET inline IPS 필수)
ip link set "$IFACE1" promisc on
ip link set "$IFACE2" promisc on
echo "[entrypoint] Promisc mode enabled on $IFACE1, $IFACE2"

# 인터페이스 정보 출력 (디버그용)
echo "[entrypoint] Interface state:"
ip -br link show "$IFACE1"
ip -br link show "$IFACE2"

echo "[entrypoint] Starting Suricata IPS (AF_PACKET inline, config-driven)"
echo "[entrypoint] Config: $CONFIG"
echo "[entrypoint] Inline pair: $IFACE1 <-> $IFACE2  (copy-mode: ips)"

# -D (daemonize) 제거: PID 1이 살아있어야 컨테이너가 재시작되지 않음
# --af-packet 플래그 미사용: yaml af-packet 섹션이 inline 쌍을 완전히 정의함
exec suricata -c "$CONFIG" -v
