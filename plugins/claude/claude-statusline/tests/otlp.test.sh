#!/bin/sh
# 수신기(claude-statusline-otlp) 종단 시험: 수신기 바이너리를 임시 포트(127.0.0.1:0)로 띄우고 OTLP/HTTP JSON
# 로그 요청을 curl 로 보낸 뒤, 상태줄 shim 이 그린 첫 줄의 계정 칸을 확인한다. 요청 형태는 Claude Code 2.1.x 가
# 보내는 것을 따르고(auth 이벤트는 번들 소스로만 확인한 합성 fixture), 계정은 예약 도메인으로만 쓴다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
TMPROOT=$(mktemp -d)
completed=0
RECV_PID=""
# bash 3.2 는 EXIT 트랩 진입에서 $? 를 0 으로 만든다. completed 플래그가 없으면 set -eu 중단이
# 종료코드 0 으로 보고된다. 정본은 AGENTS.md 의 Testing 절이다. 수신기는 이 스위트가 띄운 pid 로만 끈다.
LIVE_PIDS=""
trap 'rc=$?; [ -z "$RECV_PID" ] || kill "$RECV_PID" 2>/dev/null || true; kill $LIVE_PIDS 2>/dev/null || true; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT

HOME="$TMPROOT/home"; CLAUDE_CONFIG_DIR="$TMPROOT/claude-config"
XDG_DATA_HOME="$TMPROOT/data"; XDG_CACHE_HOME="$TMPROOT/cache"; XDG_CONFIG_HOME="$TMPROOT/config"
XDG_STATE_HOME="$TMPROOT/state"; AWS_LOGIN_CACHE_DIR="$TMPROOT/no-aws"
export HOME CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_STATE_HOME AWS_LOGIN_CACHE_DIR
for _v in "$HOME" "$CLAUDE_CONFIG_DIR" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"; do
  case "$_v" in "$TMPROOT"*) ;; *) echo "FATAL: 격리되지 않은 경로 $_v" >&2; exit 1;; esac
done
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$XDG_CACHE_HOME/claude-statusline" "$TMPROOT/scripts" "$TMPROOT/bin"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals()       { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }
assert_contains()     { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (expected to contain [$2])" "$3";; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1 (should NOT contain [$2])" "$3";; *) ok "$1";; esac; }

for tool in go curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool 를 찾지 못했습니다" >&2; exit 1; }
done
RECV="$TMPROOT/bin/claude-statusline-otlp"
RENDER="$TMPROOT/bin/statusline"
if ! ( cd "$SRC" && GOPROXY=off go build -o "$RECV" ./cmd/claude-statusline-otlp && GOPROXY=off go build -o "$RENDER" ./cmd/statusline ) >&2; then
  echo "FATAL: 바이너리 빌드 실패" >&2
  exit 1
fi
ln -sf "$SRC/scripts/statusline.sh" "$TMPROOT/scripts/statusline.sh"
SL="$TMPROOT/scripts/statusline.sh"
printf '%s\n' "$RENDER" > "$XDG_CACHE_HOME/claude-statusline/binary-path-${TMPROOT##*/}"

ESC=$(printf '\033')
STATE="$XDG_STATE_HOME/claude-statusline"

# 로그인 앵커는 실행 중인 프로세스를 알 때만 확정으로 그려진다. 세션마다 살아 있는 sleep 을 그 프로세스로 둔다.
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
running_session() {
  sleep 900 &
  LIVE_PIDS="$LIVE_PIDS $!"
  printf '{"pid":%s,"sessionId":"%s","startedAt":1}\n' "$!" "$1" > "$CLAUDE_CONFIG_DIR/sessions/$!.json"
}

# 한 줄짜리 계정 칸: 첫 줄에서 색 코드를 지운다.
first_line() {
  printf '{"session_id":"%s","workspace":{"current_dir":"/tmp"},"version":"9.9.9"}' "$1" \
    | CLAUDE_STATUSLINE_WIDTH=120 sh "$SL" | sed -n '1p' | sed "s/${ESC}\[[0-9;]*m//g"
}

# --- 요청 만들기 ---
TICK=0
now_nano() { TICK=$((TICK + 1)); printf '%s000000000' $((1700000000 + TICK)); }
attr() { printf '{"key":"%s","value":{"stringValue":"%s"}}' "$1" "$2"; }
# record <event name> <session id> <email> [extra attributes, each starting with a comma]
record() {
  printf '{"timeUnixNano":"%s","body":{"stringValue":"claude_code.%s"},"attributes":[%s,%s,%s%s]}' \
    "$(now_nano)" "$1" "$(attr event.name "$1")" "$(attr session.id "$2")" "$(attr user.email "$3")" "${4:-}"
}
auth_extra() { printf ',%s,%s' "$(attr action "$1")" "$(attr success "$2")"; }
request() {
  printf '{"resourceLogs":[{"resource":{"attributes":[%s]},"scopeLogs":[{"scope":{"name":"com.anthropic.claude_code.events"},"logRecords":[%s]}]}]}' \
    "$(attr service.name claude-code)" "$1"
}
post() {
  curl -sS -o "$TMPROOT/response" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary "$(request "$1")" "http://127.0.0.1:$PORT/v1/logs"
}

# --- 수신기 시작 ---
start_receiver() { # <binary> <stderr file>
  "$1" -addr "${ADDR:-127.0.0.1:0}" -watch 100ms -beat 200ms 2>"$2" &
  RECV_PID=$!
  _n=0
  until grep -q 'listening on' "$2" 2>/dev/null; do
    _n=$((_n + 1))
    kill -0 "$RECV_PID" 2>/dev/null && [ "$_n" -lt 100 ] || return 1
    sleep 0.1
  done
}
start_receiver "$RECV" "$TMPROOT/recv.err" || { echo "FATAL: 수신기가 뜨지 않았다" >&2; cat "$TMPROOT/recv.err" >&2; exit 1; }
PORT=$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$TMPROOT/recv.err" | head -1)
assert_contains "수신기는 loopback 임시 포트에서 받는다" "127.0.0.1:" "$(cat "$TMPROOT/recv.err")"

running_session s1
running_session s2

# --- 앵커가 없는 동안은 ? (수신기는 떠 있다) ---
assert_contains "수신기가 뜬 기계에서 앵커 없는 세션은 ?" " ? ⧉ s1" "$(first_line s1)"

# --- 시작 이벤트: 한 설정 폴더의 두 세션이 각자 자기 계정을 보인다 ---
assert_equals "시작 이벤트 요청은 200" "200" "$(post "$(record managed_settings_resolved s1 a@example.com),$(record plugin_loaded s1 a@example.com),$(record managed_settings_resolved s2 b@example.com)")"
assert_contains "세션 s1 은 자기 시작 계정(추정이라 물결표)" " ~a@example.com ⧉ s1" "$(first_line s1)"
assert_contains "세션 s2 는 자기 시작 계정(추정이라 물결표)" " ~b@example.com ⧉ s2" "$(first_line s2)"

# --- 세션 안 /login: 그 세션만 새 계정으로 바뀐다 ---
post "$(record auth s1 c@example.com "$(auth_extra login true)")" >/dev/null
assert_contains "/login 뒤 s1 은 새 계정(확정이라 물결표 없음)" " c@example.com ⧉ s1" "$(first_line s1)"
assert_contains "/login 은 s2 를 바꾸지 않는다" " ~b@example.com ⧉ s2" "$(first_line s2)"

# 실패한 로그인은 앵커를 바꾸지 않는다.
post "$(record auth s2 d@example.com "$(auth_extra login false)")" >/dev/null
assert_contains "실패한 로그인은 무시" " ~b@example.com ⧉ s2" "$(first_line s2)"

# --- 로그아웃 → ? ---
post "$(record auth s1 '' "$(auth_extra logout true)")" >/dev/null
assert_contains "로그아웃 뒤 s1 은 ?" " ? ⧉ s1" "$(first_line s1)"

# --- 「Not logged in」 세션도 시작 이벤트의 이메일을 앵커로 삼는다(알려진 한계를 못박는다) ---
post "$(record managed_settings_resolved s3 a@example.com)" >/dev/null
post "$(record auth s3 a@example.com "$(auth_extra login false)")" >/dev/null
assert_contains "로그인에 실패한 세션도 시작 계정이 앵커(추정)" " ~a@example.com ⧉ s3" "$(first_line s3)"

# --- /clear 로 만든 세션의 첫 이벤트 user_prompt 는 앵커가 아니다 ---
post "$(record user_prompt s4 z@example.com ",$(attr prompt SENTINEL_PROMPT),$(attr prompt_text SENTINEL_TEXT)")" >/dev/null
assert_contains "user_prompt 만 있는 세션은 ?" " ? ⧉ s4" "$(first_line s4)"
assert_not_contains "user_prompt 의 이메일은 보이지 않음" "z@example.com" "$(first_line s4)"

# --- 허용 키 외 값은 저장하지 않는다 ---
LEFT=$(grep -rl 'SENTINEL' "$STATE" 2>/dev/null || true)
assert_equals "프롬프트 내용이 상태 폴더에 남지 않음" "" "$LEFT"
assert_not_contains "stderr 에 요청 값이 섞이지 않음" "a@example.com" "$(cat "$TMPROOT/recv.err")"
assert_equals "앵커 파일은 0600" "600" "$(stat -f '%Lp' "$STATE/otel/sessions/s1.env" 2>/dev/null || stat -c '%a' "$STATE/otel/sessions/s1.env")"

# --- 허용하지 않는 요청 ---
assert_equals "text/plain 은 415" "415" "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: text/plain' --data-binary '{}' "http://127.0.0.1:$PORT/v1/logs")"
assert_equals "GET 은 405" "405" "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/logs")"
assert_equals "다른 경로는 404" "404" "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary '{}' "http://127.0.0.1:$PORT/v1/metrics")"

# --- 포트가 이미 쓰이면 종료코드 1 ---
set +e
"$RECV" -addr "127.0.0.1:$PORT" -watch 100ms -beat 200ms 2>/dev/null
RC=$?
set -e
assert_equals "점유된 포트면 종료코드 1" "1" "$RC"
set +e
"$RECV" -addr 0.0.0.0:0 2>"$TMPROOT/nonloopback.err"
RC=$?
set -e
assert_equals   "loopback 이 아닌 주소면 종료코드 1" "1" "$RC"
assert_contains "loopback 검사로 거부했다고 stderr 에 남김" "loopback" "$(cat "$TMPROOT/nonloopback.err")"

# --- 하트비트: 수신기가 죽은 뒤 120초가 지나면 이메일 뒤에 ? ---
HEARTBEAT="$STATE/otel/heartbeat"
assert_equals "수신기가 도는 동안 하트비트가 있다" "yes" "$([ -f "$HEARTBEAT" ] && echo yes || echo no)"
kill "$RECV_PID"
set +e; wait "$RECV_PID"; RC=$?; set -e
RECV_PID=""
assert_equals "SIGTERM 으로 끝나면 종료코드 0" "0" "$RC"
assert_contains "멈춘 직후엔 아직 신선한 하트비트라 ? 가 없다" " ~b@example.com ⧉ s2" "$(first_line s2)"
touch -t 200001010000 "$HEARTBEAT"
assert_contains "하트비트가 정체되면 이메일 뒤에 ?" " ~b@example.com? ⧉ s2" "$(first_line s2)"

# --- 실행 파일이 교체되면 종료코드 75 로 스스로 끝난다 ---
cp "$RECV" "$TMPROOT/bin/receiver-live"
start_receiver "$TMPROOT/bin/receiver-live" "$TMPROOT/recv2.err" || { echo "FATAL: 두 번째 수신기가 뜨지 않았다" >&2; exit 1; }

# --- 재시작: 멈춰 있던 동안의 /login 이 유실됐을 수 있어, 이전 세대의 앵커는 하트비트가 신선해도 ? 가 붙는다 ---
assert_contains "재시작한 수신기의 하트비트는 신선해도 이전 세대 앵커는 의심" " ~b@example.com? ⧉ s2" "$(first_line s2)"
PORT=$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$TMPROOT/recv2.err" | head -1)
post "$(record auth s2 e@example.com "$(auth_extra login true)")" >/dev/null
assert_contains "새 세대가 받은 /login 은 다시 신뢰한다" " e@example.com ⧉ s2" "$(first_line s2)"
cp "$RECV" "$TMPROOT/bin/receiver-live.next"
mv "$TMPROOT/bin/receiver-live.next" "$TMPROOT/bin/receiver-live"
_n=0
while kill -0 "$RECV_PID" 2>/dev/null && [ "$_n" -lt 100 ]; do _n=$((_n + 1)); sleep 0.1; done
set +e; wait "$RECV_PID"; RC=$?; set -e
RECV_PID=""
assert_equals "실행 파일이 교체되면 종료코드 75" "75" "$RC"
assert_contains "교체 종료 이유가 stderr 에 남음" "executable replaced" "$(cat "$TMPROOT/recv2.err")"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
