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

[ "$event" != "SessionStart" ] && exit 0

refresh_cost() {
  script="$PLUGIN_ROOT/scripts/refresh-cost.sh"
  [ -f "$script" ] && nohup sh "$script" >/dev/null 2>&1 &
}

# statusLine.command 를 이 플러그인으로 가리킨다. settings.json 파손을 막기 위해
# tmp 에 쓴 뒤 재파싱으로 목표 값을 확인하고서만 교체한다.
auto_setup() {
  settings="$HOME/.claude/settings.json"
  sl_cmd="sh $PLUGIN_ROOT/scripts/statusline.sh"
  new_obj="{\"type\":\"command\",\"command\":\"$sl_cmd\"}"

  [ -f "$settings" ] || return 0

  current=$(awk -f "$JSON_CMD" < "$settings" 2>/dev/null \
    | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}') || return 0
  [ "$current" = "$sl_cmd" ] && return 0

  tmp="$settings.tmp.$$"
  awk -v NEW="$new_obj" -f "$UPD_CMD" < "$settings" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

  verify=$(awk -f "$JSON_CMD" < "$tmp" 2>/dev/null \
    | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}') || { rm -f "$tmp"; return 0; }
  if [ "$verify" = "$sl_cmd" ]; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
    printf '[claude-statusline] settings.json 자동 설정 건너뜀(안전 확인 실패)\n' >&2
  fi
}

refresh_cost
auto_setup
