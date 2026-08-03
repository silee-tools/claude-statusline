#!/bin/sh
# term-width.sh 의 term_width() 단위 테스트. ps·stty 를 가짜로 바꿔 호출 횟수까지 검증한다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
TW="$SRC/scripts/term-width.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/width-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN"
PS_TALLY="$TMPROOT/ps-calls"
STTY_TALLY="$TMPROOT/stty-calls"
PS_QUEUE="$TMPROOT/ps-queue"

# 가짜 ps: 실제 pid 인자는 무시하고, 호출 순번에 맞는 큐의 한 줄("tty ppid")을 낸다.
# 큐가 바닥나면 존재하지 않는 프로세스를 조회한 것처럼 실패(exit 1)한다.
cat > "$FAKEBIN/ps" <<'FAKEPS'
#!/bin/sh
printf 'call\n' >> "$PS_TALLY"
n=$(wc -l < "$PS_TALLY" | tr -d ' ')
line=$(sed -n "${n}p" "$PS_QUEUE" 2>/dev/null)
[ -z "$line" ] && exit 1
printf '%s\n' "$line"
FAKEPS
chmod +x "$FAKEBIN/ps"

# 가짜 stty: STTY_FAIL=1 이면 터미널이 사라진 상황을 흉내 내 실패하고, 아니면 STTY_SIZE 를 낸다.
cat > "$FAKEBIN/stty" <<'FAKESTTY'
#!/bin/sh
printf 'call\n' >> "$STTY_TALLY"
[ "${STTY_FAIL:-0}" = "1" ] && exit 1
printf '%s\n' "${STTY_SIZE:-24 80}"
FAKESTTY
chmod +x "$FAKEBIN/stty"

export PS_TALLY STTY_TALLY PS_QUEUE
PATH="$FAKEBIN:$PATH"
export PATH

CACHE_DIR="$TMPROOT/cache"
CACHE_FILE="$CACHE_DIR/tty-path.env"

ps_calls()   { wc -l < "$PS_TALLY" 2>/dev/null | tr -d ' '; }
stty_calls() { wc -l < "$STTY_TALLY" 2>/dev/null | tr -d ' '; }

# 각 테스트 전에 호출 기록·캐시·오버라이드·가짜 명령 동작을 알려진 상태로 되돌린다.
reset_env() {
  : > "$PS_TALLY"
  : > "$STTY_TALLY"
  rm -rf "$CACHE_DIR"
  unset CLAUDE_STATUSLINE_WIDTH
  # 가짜 stty 는 별도 프로세스라 export 해야 이 값을 물려받는다.
  STTY_FAIL=0
  STTY_SIZE="24 80"
  export STTY_FAIL STTY_SIZE
}

queue() { printf '%s\n' "$@" > "$PS_QUEUE"; }

. "$TW"

# T1: 오버라이드가 프로브보다 우선한다. ps 를 아예 부르지 않는다.
reset_env
queue "ttys001 100"
CLAUDE_STATUSLINE_WIDTH=123
OUT=$(term_width)
unset CLAUDE_STATUSLINE_WIDTH
assert_equals "T1 오버라이드 값 그대로 출력" "123" "$OUT"
assert_equals "T1 오버라이드는 ps 미호출" "0" "$(ps_calls)"

# T2: 숫자가 아닌 오버라이드는 무시하고 프로브로 진행한다(에러로 죽지 않는다).
reset_env
queue "ttys002 200"
STTY_SIZE="30 99"
CLAUDE_STATUSLINE_WIDTH="abc"
OUT=$(term_width)
unset CLAUDE_STATUSLINE_WIDTH
assert_equals "T2 비숫자 오버라이드 무시 후 프로브 값 사용" "99" "$OUT"
assert_equals "T2 비숫자 오버라이드는 프로브를 실제로 태운다" "1" "$(ps_calls)"

# T3: 부모가 tty 를 가지면 그 폭을 낸다.
reset_env
queue "ttys003 300"
STTY_SIZE="40 132"
OUT=$(term_width)
assert_equals "T3 부모 tty 로 폭 산출" "132" "$OUT"

# T4: 조상을 여러 단계 올라가야 tty 를 찾는 경우에도 폭을 낸다.
reset_env
queue "?? 401" "?? 402" "ttys004 403"
STTY_SIZE="50 210"
OUT=$(term_width)
assert_equals "T4 여러 단계 위 조상의 tty 로 폭 산출" "210" "$OUT"
assert_equals "T4 tty 를 찾을 때까지 ps 를 반복 호출" "3" "$(ps_calls)"

# T5: 네 단계를 다 올라가도 tty 를 못 찾으면 아무것도 내지 않는다(넉넉히 6줄을 준비해
# 캡이 4에서 멈추는지도 함께 확인한다).
reset_env
queue "?? 501" "?? 502" "?? 503" "?? 504" "?? 505" "?? 506"
OUT=$(term_width)
assert_equals "T5 tty 없는 조상 사슬이면 빈 문자열" "" "$OUT"
assert_equals "T5 최대 4단계까지만 ps 호출(캡 준수)" "4" "$(ps_calls)"

# T6: tty 는 찾았지만 창 크기 조회가 실패하면 아무것도 내지 않는다.
reset_env
queue "ttys006 600"
STTY_FAIL=1
OUT=$(term_width)
assert_equals "T6 창 크기 조회 실패 시 빈 문자열" "" "$OUT"

# T7: 두 번째 호출은 경로를 캐시에서 읽어 ps 를 다시 부르지 않는다. 다만 창 크기는
# 리사이즈를 놓치지 않도록 매번 다시 읽는다(stty 호출 수는 매 호출 +1).
reset_env
queue "ttys007 700"
STTY_SIZE="20 160"
OUT1=$(term_width)
CALLS_PS_1="$(ps_calls)"
assert_equals "T7 첫 호출(캐시 미스) 폭 산출" "160" "$OUT1"
assert_equals "T7 첫 호출은 ps 호출" "1" "$CALLS_PS_1"

: > "$PS_TALLY"   # 캐시 파일은 남기고 호출 기록만 초기화
STTY_SIZE="20 160"
OUT2=$(term_width)
assert_equals "T7 두 번째 호출(캐시 히트)도 같은 폭" "160" "$OUT2"
assert_equals "T7 캐시 히트면 ps 미호출" "0" "$(ps_calls)"
assert_equals "T7 캐시 히트여도 stty 는 다시 호출(리사이즈 반영)" "2" "$(stty_calls)"

# T8: 캐시된 경로의 창 크기 조회가 실패하면(터미널이 이미 닫힘) 캐시를 버리고
# 판정 불가로 보고한다 — 죽은 경로를 계속 재사용하지 않는다.
reset_env
queue "ttys008 800"
STTY_SIZE="20 88"
OUT1=$(term_width)
assert_equals "T8 사전 준비: 첫 호출로 캐시 확보" "88" "$OUT1"
[ -f "$CACHE_FILE" ] || bad "T8 사전 준비: 캐시 파일 존재" "no cache file"

: > "$PS_TALLY"
STTY_FAIL=1
OUT2=$(term_width)
assert_equals "T8 캐시된 경로가 죽었으면 빈 문자열(stale 값 반환 금지)" "" "$OUT2"
assert_equals "T8 캐시 히트 경로라 ps 는 안 부름" "0" "$(ps_calls)"
if [ -f "$CACHE_FILE" ]; then
  bad "T8 죽은 캐시 항목을 버림" "cache file still exists"
else
  ok "T8 죽은 캐시 항목을 버림"
fi

# T8 이어서: 캐시를 버렸으므로 다음 호출은 다시 ps 로 프로브해야 한다.
STTY_FAIL=0
STTY_SIZE="20 88"
queue "ttys009 900"
OUT3=$(term_width)
assert_equals "T8 폐기 후 다음 호출은 재프로브해 값 복구" "88" "$OUT3"
assert_equals "T8 폐기 후 다음 호출은 ps 를 다시 호출" "1" "$(ps_calls)"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
