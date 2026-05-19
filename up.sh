#!/usr/bin/env bash
# =============================================================================
#  up.sh  — VTS2 전체 배포 (원커맨드)
#
#  실행 순서:
#    1. deploy-docker-compose.sh   (브리지/이미지/컨테이너/네트워크 배선)
#    2. start-suricata.sh          (br_netfilter + NFQ 룰 + Suricata IPS)
#    3. setup-port-forward.sh      (외부 접근 포트 포워딩)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}✔${NC} $*"; }
die() { echo -e "\n${RED}[FATAL]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한 필요:  sudo $0"

run_step() {
  local step=$1 script=$2
  echo -e "\n${BOLD}━━━ $step ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  bash "$SCRIPT_DIR/$script" || die "$script 실패"
  ok "$script 완료"
}

run_step "[1/3] 컨테이너 배포"   deploy-docker-compose.sh
run_step "[2/3] Suricata IPS"    start-suricata.sh
run_step "[3/3] 포트 포워딩"     setup-port-forward.sh

echo ""
echo -e "${BOLD}━━━ 배포 완료 ✔ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
