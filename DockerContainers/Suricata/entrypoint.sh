#!/bin/bash
# =============================================================================
#  entrypoint.sh — Suricata 인라인 IPS 래퍼
#  ContainerLab 이 eth1/eth2 veth 를 붙여줄 때까지 대기 후 Suricata 시작
# =============================================================================

IFACE1="${SURICATA_IFACE1:-eth1}"
IFACE2="${SURICATA_IFACE2:-eth2}"
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
    echo "[entrypoint] ERROR: timeout waiting for interfaces"
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

# 인터페이스 promisc 모드 활성화 (인라인 IPS 필수)
ip link set "$IFACE1" promisc on
ip link set "$IFACE2" promisc on
echo "[entrypoint] Promisc mode enabled on $IFACE1, $IFACE2"

echo "[entrypoint] Starting Suricata IPS (AF_PACKET inline mode)"
# -D (daemonize) 제거: PID 1이 살아있어야 Docker가 컨테이너를 재시작하지 않음
exec suricata -c "$CONFIG" \
  --af-packet="$IFACE1" \
  --af-packet="$IFACE2" \
  -v
