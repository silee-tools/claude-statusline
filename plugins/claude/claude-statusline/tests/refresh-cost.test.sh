#!/bin/sh
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
completed=0
trap 'rc=$?; rm -rf "$WORK"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT

ROOT="$WORK/plugin"
HOME_DIR="$WORK/home"
mkdir -p "$ROOT/scripts" "$HOME_DIR/.claude/projects/example" "$WORK/bin"
cp "$SRC/scripts/refresh-cost.sh" "$SRC/scripts/aggregate-cost.awk" "$ROOT/scripts/"

cat > "$ROOT/scripts/fetch-prices.sh" <<'SH'
#!/bin/sh
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
printf 'claude-opus-4-8\t0.000005\t0.000025\t0.00000625\t0.0000005\n' \
  > "${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/prices.tsv"
SH
chmod +x "$ROOT/scripts/fetch-prices.sh"

# 2026-09-01은 화요일이다. 주 경계(8월 30일)가 월 경계보다 이르므로,
# 8월 31일 로그가 주간 합계에 남아야 한다.
cat > "$WORK/bin/date" <<'SH'
#!/bin/sh
case "$1" in
  '+%s') echo 1788264000 ;;
  '+%w') echo 2 ;;
  '-v0H') echo 1788220800 ;;
  '-v-2d') echo 1788048000 ;;
  '-v1d') echo 1788220800 ;;
  '-u') case "$3" in 1788220800) echo 2026-09-01T00:00:00Z ;; 1788048000) echo 2026-08-30T00:00:00Z ;; esac ;;
  '-r') case "$2" in 1788048000) echo 202608300000 ;; 1788220800) echo 202609010000 ;; esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$WORK/bin/date"

cat > "$HOME_DIR/.claude/projects/example/log.jsonl" <<'JSON'
{"timestamp":"2026-08-31T12:00:00Z","requestId":"r1","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSON
touch -t 202608311200 "$HOME_DIR/.claude/projects/example/log.jsonl"

CACHE="$WORK/cache"
PATH="$WORK/bin:$PATH" HOME="$HOME_DIR" XDG_CACHE_HOME="$CACHE" CLAUDE_PLUGIN_ROOT="$ROOT" \
  sh "$ROOT/scripts/refresh-cost.sh"

OUT="$CACHE/claude-statusline/cost-cache.env"
[ "$(awk -F= '$1=="weekly"{print $2}' "$OUT")" = 5 ] || {
  printf 'FAIL 전월 주간 로그가 weekly에 포함되지 않음\n'; cat "$OUT"; exit 1;
}
printf 'refresh-cost.test.sh: 1 passed, 0 failed\n'
completed=1
