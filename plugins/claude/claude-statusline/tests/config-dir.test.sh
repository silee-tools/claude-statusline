#!/bin/sh
set -eu
SRC=${STATUSLINE_TEST_SRC:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d)
completed=0
trap 'rc=$?; rm -rf "$WORK"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else printf 'FAIL %s expected=%s actual=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
HOME="$WORK/home"; export HOME
XDG_CACHE_HOME="$WORK/cache"; export XDG_CACHE_HOME
XDG_CONFIG_HOME="$WORK/config"; export XDG_CONFIG_HOME
XDG_STATE_HOME="$WORK/state"; export XDG_STATE_HOME
AWS_LOGIN_CACHE_DIR="$WORK/no-aws"; export AWS_LOGIN_CACHE_DIR
CLAUDE_STATUSLINE_WIDTH=120; export CLAUDE_STATUSLINE_WIDTH
ROOT="$WORK/plugin"
CUSTOM="$HOME/별도 계정"
mkdir -p "$ROOT/scripts" "$HOME/.claude" "$CUSTOM"
cp "$SRC/scripts/hook-handler.sh" "$SRC/scripts/json.awk" "$SRC/scripts/settings-update.awk" "$ROOT/scripts/"
[ ! -f "$SRC/scripts/config-paths.sh" ] || cp "$SRC/scripts/config-paths.sh" "$ROOT/scripts/"
printf '{"account":"default"}\n' > "$HOME/.claude/settings.json"
printf '{"account":"custom"}\n' > "$CUSTOM/settings.json"
BEFORE=$(cksum < "$HOME/.claude/settings.json")
BEFORE_MTIME=$(stat -f '%m' "$HOME/.claude/settings.json" 2>/dev/null || stat -c '%Y' "$HOME/.claude/settings.json")
printf '{"hook_event_name":"SessionStart"}' | CLAUDE_CONFIG_DIR="$CUSTOM/" CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/scripts/hook-handler.sh"
check 'custom hook preserves default settings' "$BEFORE" "$(cksum < "$HOME/.claude/settings.json")"
check 'custom hook preserves default settings mtime' "$BEFORE_MTIME" "$(stat -f '%m' "$HOME/.claude/settings.json" 2>/dev/null || stat -c '%Y' "$HOME/.claude/settings.json")"
case "$(cat "$CUSTOM/settings.json")" in *statusLine*) pass=$((pass+1));; *) fail=$((fail+1)); printf 'FAIL custom settings not configured\n';; esac
CUSTOM_BEFORE=$(cksum < "$CUSTOM/settings.json")
printf '{"hook_event_name":"SessionStart"}' | CLAUDE_CONFIG_DIR= CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/scripts/hook-handler.sh"
check 'default hook preserves custom settings' "$CUSTOM_BEFORE" "$(cksum < "$CUSTOM/settings.json")"
(cd "$SRC" && GOPROXY=off go build -o "$WORK/statusline" ./cmd/statusline)
CACHE="$XDG_CACHE_HOME/claude-statusline"
HASH=$(printf '%s' "$CUSTOM" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')
CUSTOM_CACHE="$CACHE/accounts/$HASH"
mkdir -p "$CACHE" "$CUSTOM_CACHE"
printf '{"oauthAccount":{"emailAddress":"default@example.com"}}' > "$HOME/.claude.json"
printf '{"oauthAccount":{"emailAddress":"custom@example.com"}}' > "$CUSTOM/.claude.json"
printf 'available=true\ndailyOpus=7\nweekly=7\nmonthly=7\n' > "$CACHE/cost-cache.env"
printf 'available=true\ndailyOpus=13\nweekly=13\nmonthly=13\n' > "$CUSTOM_CACHE/cost-cache.env"
render() { printf '{"workspace":{"current_dir":"/tmp"},"version":"test","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":1999999999}}}' "$2" | CLAUDE_CONFIG_DIR="$1" "$WORK/statusline"; }
render '' 12 > "$WORK/default.out" &
PID=$!
render "$CUSTOM/" 67 > "$WORK/custom.out"
wait "$PID"
for entry in 'default:default@example.com:12:7' 'custom:custom@example.com:67:13'; do
  name=${entry%%:*}; rest=${entry#*:}; email=${rest%%:*}; rest=${rest#*:}; pct=${rest%%:*}; cost=${rest#*:}
  dir=$CACHE; [ "$name" = default ] || dir=$CUSTOM_CACHE
  case "$(cat "$WORK/$name.out")" in *"$email"*) pass=$((pass+1));; *) printf 'FAIL %s account render\n' "$name"; fail=$((fail+1));; esac
  case "$(cat "$WORK/$name.out")" in *"\$$cost"*) pass=$((pass+1));; *) printf 'FAIL %s cost render\n' "$name"; fail=$((fail+1));; esac
  check "$name rate cache" "$pct" "$(if [ -f "$dir/rate-limits.env" ]; then awk -F= '$1=="fivePct"{print $2}' "$dir/rate-limits.env"; else printf missing; fi)"
  check "$name account cache" "email=$email" "$(cat "$dir/cc-account.env" 2>/dev/null || printf missing)"
done
DEFAULT_CACHE_BEFORE=$(cksum < "$CACHE/rate-limits.env")
CUSTOM_CACHE_BEFORE=$(if [ -f "$CUSTOM_CACHE/rate-limits.env" ]; then cksum < "$CUSTOM_CACHE/rate-limits.env"; else printf missing; fi)
for config in '' "$CUSTOM"; do
  printf '{"workspace":{"current_dir":"/tmp"}}' | CLAUDE_CONFIG_DIR="$config" "$WORK/statusline" >/dev/null
done
check 'default fallback preserves its rate cache' "$DEFAULT_CACHE_BEFORE" "$(cksum < "$CACHE/rate-limits.env")"
check 'custom fallback preserves its rate cache' "$CUSTOM_CACHE_BEFORE" "$(if [ -f "$CUSTOM_CACHE/rate-limits.env" ]; then cksum < "$CUSTOM_CACHE/rate-limits.env"; else printf missing; fi)"
printf 'config-dir.test.sh: %d passed, %d failed\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
