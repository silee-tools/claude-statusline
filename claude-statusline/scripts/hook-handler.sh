#!/bin/sh
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')

[ "$event" != "SessionStart" ] && exit 0

refresh_cost() {
  local script="$PLUGIN_ROOT/scripts/refresh-cost.ts"
  [ -f "$script" ] && nohup bun run "$script" >/dev/null 2>&1 &
}

auto_setup() {
  command -v jq >/dev/null 2>&1 || return 0

  local settings="$HOME/.claude/settings.json"
  local sl_cmd="sh $PLUGIN_ROOT/scripts/statusline.sh"

  [ ! -f "$settings" ] && return 0

  local current
  current=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null) || return 0
  [ "$current" = "$sl_cmd" ] && return 0

  local tmp="$settings.tmp.$$"
  jq --arg cmd "$sl_cmd" '.statusLine = {"type": "command", "command": $cmd}' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

refresh_cost
auto_setup
