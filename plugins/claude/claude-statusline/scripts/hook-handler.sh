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

refresh_cost() {
  script="$PLUGIN_ROOT/scripts/refresh-cost.sh"
  [ -f "$script" ] && nohup sh "$script" >/dev/null 2>&1 &
}

# 렌더 바이너리를 최초 1회 빌드한다. 배경으로 떼어 내는 이유는 hooks.json 의 SessionStart
# 제한 시간이 5초인데 캐시가 빈 상태의 빌드가 그 값에 붙기 때문이다.
build_binary() {
  script="$PLUGIN_ROOT/scripts/build-binary.sh"
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
  new="$settings.new.$$"
  printf '%s\n' "$new_obj" > "$new" || return 0
  mode=$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings" 2>/dev/null || printf '')
  awk -v NEW_FILE="$new" -f "$UPD_CMD" < "$settings" > "$tmp" 2>/dev/null || { rm -f "$tmp" "$new"; return 0; }
  [ -z "$mode" ] || chmod "$mode" "$tmp" || { rm -f "$tmp" "$new"; return 0; }

  verify=$(awk -f "$JSON_CMD" < "$tmp" 2>/dev/null \
    | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}') || { rm -f "$tmp" "$new"; return 0; }
  if [ "$verify" = "$sl_cmd" ]; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
    printf '[claude-statusline] settings.json 자동 설정 건너뜀(안전 확인 실패)\n' >&2
  fi
  rm -f "$new"
}

refresh_cost
build_binary
auto_setup
