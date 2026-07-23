#!/bin/sh
set -eu
# ═══════════════════════════════════════════════════════════════
# Shared shortening utility for paths and branch names (CLI wrapper)
# Usage: shorten.sh [--ansi|--plain] <path|branch> <value>
#
# 함수 본체는 shorten-lib.sh 에 있다. 이 래퍼는 색 모드를 정하고 lib 을 소스한 뒤
# 하위 명령을 분기한다. statusline.sh 는 이 CLI 대신 lib 을 직접 소스해 in-process 로 쓴다.
# ═══════════════════════════════════════════════════════════════

COLOR_MODE="plain"
while [ $# -gt 0 ]; do
  case "$1" in
    --ansi)  COLOR_MODE="ansi"; shift ;;
    --plain) COLOR_MODE="plain"; shift ;;
    --*)     shift ;;
    *)       break ;;
  esac
done

if [ "$COLOR_MODE" = "ansi" ]; then
  C_RESET=$(printf '\033[0m')
  C_DIM=$(printf '\033[2m')
  C_BLUE=$(printf '\033[34m')
else
  C_RESET="" C_DIM="" C_BLUE=""
fi

. "$(dirname "$0")/shorten-lib.sh"

case "$1" in
  path)   shorten_path "$2" ;;
  branch) shorten_branch "$2" ;;
  *)      printf 'Usage: shorten.sh [--ansi|--plain] <path|branch> <value>\n' >&2; exit 1 ;;
esac
