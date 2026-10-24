#!/bin/sh
set -eu
SRC=${STATUSLINE_TEST_SRC:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d)
completed=0
LIVE_PIDS=""
LOCK_PID=""
trap 'rc=$?; kill $LIVE_PIDS $LOCK_PID 2>/dev/null; rm -rf "$WORK"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else printf 'FAIL %s expected=%s actual=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
HOME="$WORK/home"; export HOME
XDG_CACHE_HOME="$WORK/cache"; export XDG_CACHE_HOME
XDG_CONFIG_HOME="$WORK/config"; export XDG_CONFIG_HOME
XDG_STATE_HOME="$WORK/state"; export XDG_STATE_HOME
XDG_DATA_HOME="$WORK/data"; export XDG_DATA_HOME
CLAUDE_CONFIG_DIR="$WORK/claude-config"; export CLAUDE_CONFIG_DIR
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
(cd "$SRC" && GOPROXY=off go build -o "$WORK/statusline" ./cmd/statusline && GOPROXY=off go build -o "$WORK/lockholder" ./tests/testdata/lockholder)
CACHE="$XDG_CACHE_HOME/claude-statusline"
OTEL="$XDG_STATE_HOME/claude-statusline/otel"
mkdir -p "$CACHE" "$OTEL/sessions"
touch "$OTEL/heartbeat"
# 계정은 수신기가 쥔 잠금이 잡혀 있을 때만 믿는다. 시험은 수신기 없이 파일을 심으므로 같은 잠금을 쥐는 프로그램을 띄운다.
"$WORK/lockholder" "$XDG_STATE_HOME/claude-statusline" > "$WORK/lockhold.out" 2>&1 &
LOCK_PID=$!
_n=0
until grep -q locked "$WORK/lockhold.out" 2>/dev/null; do _n=$((_n + 1)); [ "$_n" -lt 100 ] || { echo "FATAL: 잠금 보유자가 뜨지 않았다" >&2; exit 1; }; sleep 0.05; done
# 계정은 설정 폴더의 .claude.json 이 아니라 세션별 앵커에서 온다. 미끼 .claude.json 은 서로 바꿔 둔다.
printf '{"oauthAccount":{"emailAddress":"custom@example.com"}}' > "$HOME/.claude.json"
printf '{"oauthAccount":{"emailAddress":"default@example.com"}}' > "$CUSTOM/.claude.json"
SEEN="$(date +%s)000"
printf '1\n' > "$OTEL/generation"
printf 'email=default@example.com\nkind=start\nts=1700000000000\nseen=%s\ngen=1\n' "$SEEN" > "$OTEL/sessions/sess-default.env"
printf 'email=custom@example.com\nkind=start\nts=1700000001000\nseen=%s\ngen=1\n' "$SEEN" > "$OTEL/sessions/sess-custom.env"
# 한도 캐시는 실행 프로세스별이다. 프로세스는 각 설정 폴더의 sessions/<pid>.json 으로 알아내고, 실행 중인 pid 만
# 프로세스로 인정하므로 시험의 프로세스는 살아 있는 sleep 이다.
mkdir -p "$HOME/.claude/sessions" "$CUSTOM/sessions"
sleep 900 &
P_DEFAULT=$!
sleep 900 &
P_CUSTOM=$!
LIVE_PIDS="$P_DEFAULT $P_CUSTOM"
printf '{"pid":%s,"sessionId":"sess-default","startedAt":1700000000000}\n' "$P_DEFAULT" > "$HOME/.claude/sessions/$P_DEFAULT.json"
printf '{"pid":%s,"sessionId":"sess-custom","startedAt":1700000000000}\n' "$P_CUSTOM" > "$CUSTOM/sessions/$P_CUSTOM.json"
render() { printf '{"session_id":"%s","workspace":{"current_dir":"/tmp"},"version":"test","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":1999999999}}}' "$2" "$3" | CLAUDE_CONFIG_DIR="$1" "$WORK/statusline"; }
render '' sess-default 12 > "$WORK/default.out" &
PID=$!
render "$CUSTOM/" sess-custom 67 > "$WORK/custom.out"
wait "$PID"
for entry in 'default:default@example.com:12:custom@example.com' 'custom:custom@example.com:67:default@example.com'; do
  name=${entry%%:*}; rest=${entry#*:}; email=${rest%%:*}; rest=${rest#*:}; pct=${rest%%:*}; other=${rest#*:}
  case "$(cat "$WORK/$name.out")" in *"$email"*) pass=$((pass+1));; *) printf 'FAIL %s account render\n' "$name"; fail=$((fail+1));; esac
  case "$(cat "$WORK/$name.out")" in *"$other"*) printf 'FAIL %s shows the other session account\n' "$name"; fail=$((fail+1));; *) pass=$((pass+1));; esac
  check "$name rate cache" "$pct" "$(if [ -f "$CACHE/rate-limits/sess-$name.env" ]; then awk -F= '$1=="fivePct"{print $2}' "$CACHE/rate-limits/sess-$name.env"; else printf missing; fi)"
done
check 'no shared rate-limits.env' missing "$(if [ -e "$CACHE/rate-limits.env" ]; then printf present; else printf missing; fi)"
check 'no cc-account.env' missing "$(if [ -e "$CACHE/cc-account.env" ]; then printf present; else printf missing; fi)"
check 'no accounts directory' missing "$(if [ -e "$CACHE/accounts" ]; then printf present; else printf missing; fi)"
# 창을 못 받은 렌더는 자기 세션의 캐시만 쓰고 그 파일을 바꾸지 않는다.
for name in default custom; do
  before=$(cksum < "$CACHE/rate-limits/sess-$name.env")
  config=''; [ "$name" = custom ] && config="$CUSTOM"
  printf '{"session_id":"sess-%s","workspace":{"current_dir":"/tmp"}}' "$name" | CLAUDE_CONFIG_DIR="$config" "$WORK/statusline" > "$WORK/$name.fallback.out"
  check "$name fallback preserves its rate cache" "$before" "$(cksum < "$CACHE/rate-limits/sess-$name.env")"
done
case "$(cat "$WORK/default.fallback.out")" in *"5h"*"12%"*) pass=$((pass+1));; *) printf 'FAIL default fallback shows its own window\n'; fail=$((fail+1));; esac
case "$(cat "$WORK/custom.fallback.out")" in *"5h"*"67%"*) pass=$((pass+1));; *) printf 'FAIL custom fallback shows its own window\n'; fail=$((fail+1));; esac
printf 'config-dir.test.sh: %d passed, %d failed\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
