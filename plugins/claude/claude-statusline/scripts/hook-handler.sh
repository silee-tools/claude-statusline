#!/bin/sh
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
JSON_CMD="$PLUGIN_ROOT/scripts/json.awk"
UPD_CMD="$PLUGIN_ROOT/scripts/settings-update.awk"
TAB=$(printf '\t')

input=$(cat)

command -v awk >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$input" | awk -f "$JSON_CMD" \
  | awk -F"$TAB" '$1=="..hook_event_name"{print $2; exit}')

record_activity() {
  # 포인터 키의 정본은 statusline.sh 의 주석이다. 여기서도 같은 디렉터리 이름을 쓴다.
  ptr="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/binary-path-${PLUGIN_ROOT##*/}"
  binary=""
  if [ -f "$ptr" ]; then
    IFS= read -r binary < "$ptr" || binary=""
  fi
  if [ -n "$binary" ] && [ -x "$binary" ]; then
    printf '%s' "$input" | "$binary" hook >/dev/null 2>&1 || :
  fi
}

record_activity
[ "$event" != "SessionStart" ] && exit 0

run_background() {
  script="$PLUGIN_ROOT/scripts/$1"
  [ -f "$script" ] && nohup sh "$script" >/dev/null 2>&1 &
}

# statusLine.command 를 이 플러그인으로 가리킨다. settings.json 파손을 막기 위해
# tmp 에 쓴 뒤 재파싱으로 목표 값을 확인하고서만 교체한다.
auto_setup() {
  settings="$HOME/.claude/settings.json"
  quoted_path=$(printf '%s' "$PLUGIN_ROOT/scripts/statusline.sh" | sed "s/'/'\\\\''/g")
  sl_cmd="sh '$quoted_path'"
  escaped_cmd=$(printf '%s' "$sl_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
  new_obj="{\"type\":\"command\",\"command\":\"$escaped_cmd\"}"

  [ -f "$settings" ] || return 0

  current=$(awk -f "$JSON_CMD" < "$settings" 2>/dev/null \
    | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}') || return 0
  [ "$current" = "$sl_cmd" ] && return 0

  tmp="$settings.tmp.$$"
  mode=$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings" 2>/dev/null || printf '')
  STATUSLINE_NEW="$new_obj" awk -f "$UPD_CMD" < "$settings" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  [ -z "$mode" ] || chmod "$mode" "$tmp" || { rm -f "$tmp"; return 0; }

  verify=$(awk -f "$JSON_CMD" < "$tmp" 2>/dev/null \
    | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}') || { rm -f "$tmp"; return 0; }
  if [ "$verify" = "$sl_cmd" ]; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
    printf '[claude-statusline] settings.json 자동 설정 건너뜀(안전 확인 실패)\n' >&2
  fi
}

run_background refresh-cost.sh
# 렌더 바이너리는 hooks.json 의 5초 제한에 걸리지 않도록 배경에서 최초 1회 빌드한다.
run_background build-binary.sh
auto_setup
