#!/bin/sh
# resume.sh 계약 테스트. 실제 API 대신 훅 입력, 상태 루트, 시각과 대기를 제어한다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
RESUME="$SRC/scripts/resume.sh"
HOOKS="$SRC/hooks/hooks.json"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/resume-test.XXXXXX")
completed=0
STARTED_PIDS=
WORKER_PIDS=

stop_started_processes() {
  for started_pid in $WORKER_PIDS $STARTED_PIDS; do
    if kill -0 "$started_pid" 2>/dev/null; then
      kill -9 "$started_pid" 2>/dev/null || true
    fi
  done
  STARTED_PIDS=
  WORKER_PIDS=
}

trap 'rc=$?; stop_started_processes; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT

CLAUDE_RESUME_STATE_DIR="$TMPROOT/state"
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
export CLAUDE_RESUME_STATE_DIR CLAUDE_RESUME_TEST_SKIP_SLEEP
STATE_V2="$CLAUDE_RESUME_STATE_DIR/v2"

SESSION_A=11111111-2222-3333-4444-555555555555
SESSION_B=66666666-7777-8888-9999-000000000000
SESSION_C=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

failure_input() {
  printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"%s"}' "$1" "$2"
}

stop_input() {
  printf '{"session_id":"%s","hook_event_name":"Stop"}' "$1"
}

field() {
  sed -n "s/^$2=//p" "$STATE_V2/$1" 2>/dev/null | sed -n '1p'
}

waiter_path_for_token() {
  waiter_token=$1
  for waiter_path in "$STATE_V2/waiters"/*; do
    [ -f "$waiter_path" ] || continue
    [ "$(sed -n 's/^token=//p' "$waiter_path" | sed -n '1p')" = "$waiter_token" ] || continue
    printf '%s\n' "$waiter_path"
    return 0
  done
  return 1
}

file_mtime() {
  file_mtime_path=$1
  file_mtime_value=
  if file_mtime_value=$(stat -f %m "$file_mtime_path" 2>/dev/null); then
    case "$file_mtime_value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$file_mtime_value"; return 0 ;; esac
  fi
  if file_mtime_value=$(stat -c %Y "$file_mtime_path" 2>/dev/null); then
    case "$file_mtime_value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$file_mtime_value"; return 0 ;; esac
  fi
  return 1
}

set_now() {
  CLAUDE_RESUME_TEST_NOW=$1
  export CLAUDE_RESUME_TEST_NOW
}

set_global_field() {
  global_field=$1 global_value=$2
  if grep -q "^$global_field=" "$STATE_V2/global"; then
    sed "s/^$global_field=.*/$global_field=$global_value/" "$STATE_V2/global" > "$STATE_V2/global.$$.tmp"
  else
    cp "$STATE_V2/global" "$STATE_V2/global.$$.tmp"
    printf '%s=%s\n' "$global_field" "$global_value" >> "$STATE_V2/global.$$.tmp"
  fi
  mv "$STATE_V2/global.$$.tmp" "$STATE_V2/global"
}

wait_for_file() {
  path=$1
  limit=${2:-50}
  tries=0
  while [ ! -f "$path" ] && [ "$tries" -lt "$limit" ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -f "$path" ]
}

start_waiter() {
  waiter_input=$1 waiter_out=$2 waiter_errfile=$3 waiter_rcfile=$4
  (
    waiter_rc=0
    printf '%s' "$waiter_input" | sh "$RESUME" >"$waiter_out" 2>"$waiter_errfile" &
    waiter_child=$!
    printf '%s\n' "$waiter_child" > "$waiter_rcfile.pid"
    wait "$waiter_child" || waiter_rc=$?
    printf '%s\n' "$waiter_rc" > "$waiter_rcfile"
  ) &
  STARTED_PID=$!
  STARTED_PIDS="$STARTED_PIDS $STARTED_PID"
  if wait_for_file "$waiter_rcfile.pid"; then
    STARTED_CHILD_PID=$(sed -n '1p' "$waiter_rcfile.pid")
    WORKER_PIDS="$WORKER_PIDS $STARTED_CHILD_PID"
  else
    STARTED_CHILD_PID=
  fi
}

run() {
  rc=0
  err=$(printf '%s' "$1" | sh "$RESUME" 2>&1 >/dev/null) || rc=$?
}

reset_state() {
  stop_started_processes
  rm -rf "$CLAUDE_RESUME_STATE_DIR"
  unset CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS CLAUDE_RESUME_TEST_REGISTER_BARRIER CLAUDE_RESUME_TEST_SIGNAL_BARRIER CLAUDE_RESUME_TEST_RECLAIM_BARRIER CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER
  CLAUDE_RESUME_WAIT_SECONDS=0
  export CLAUDE_RESUME_WAIT_SECONDS
  CLAUDE_RESUME_TEST_SKIP_SLEEP=1
  export CLAUDE_RESUME_TEST_SKIP_SLEEP
  set_now 1787200000
}

# T1: 첫 rate_limit은 기본 30초 뒤 재개하고 전역 상태를 만든다.
reset_state
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T1 첫 rate_limit은 종료코드 2" "2" "$rc"
assert_equals "T1 사용량 한도 재개 문장" "Continue the work that was interrupted by the usage limit." "$err"
assert_equals "T1 기본 시작 지연" "30" "$(field global delay)"
assert_equals "T1 최초 탐침 시각" "1787200030" "$(field global last_attempt)"

# T2: 활성 세션의 재발화는 지연을 두 배로 올리고 480초에서 멈춘다.
for expected in 60 120 240 480 480; do
  set_now 1787200000
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T2 지연 $expected 초 재개" "2" "$rc"
  assert_equals "T2 전역 지연 $expected 초" "$expected" "$(field global delay)"
done

# T3: 첫 등록의 유효한 환경값이 시작 지연을 정하고 이후 지수 증가한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=5
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T3 시작 지연 5초" "5" "$(field global delay)"
for expected in 10 20 40 80 160 320 480 480; do
  set_now 1787200000
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T3 지연 $expected 초" "$expected" "$(field global delay)"
done

# T4: 잘못된 지연은 30초로 정규화하고 양수 상한은 직렬 탐침 수를 제한한다.
for invalid in 0 481 invalid; do
  reset_state
  CLAUDE_RESUME_WAIT_SECONDS=$invalid
  CLAUDE_RESUME_MAX_ATTEMPTS=2
  export CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T4 $invalid 지연은 기본값" "30" "$(field global base_delay)"
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T4 $invalid 두 번째 탐침" "2" "$rc"
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T4 $invalid 상한 뒤 중단" "0" "$rc"
  assert_equals "T4 $invalid 상한 뒤 빈 표준 오류" "" "$err"
done

# T5: 상한이 없거나 0이면 호출 수 대신 종료 시각만 적용한다.
for max in unset 0; do
  reset_state
  if [ "$max" = unset ]; then unset CLAUDE_RESUME_MAX_ATTEMPTS; else CLAUDE_RESUME_MAX_ATTEMPTS=0; export CLAUDE_RESUME_MAX_ATTEMPTS; fi
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T5 $max 상한은 0" "0" "$(field global max_attempts)"
  set_now 1787200000
  run "$(failure_input "$SESSION_A" rate_limit)"
  assert_equals "T5 $max 두 번째 탐침도 재개" "2" "$rc"
done

# T6: 새 세션은 첫 에피소드의 고정 설정을 유지하고 이전 탐침 뒤 최소 간격으로 시작한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=30
CLAUDE_RESUME_MAX_ATTEMPTS=7
export CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T6 A 최초 due" "1787200030" "$(field global last_attempt)"
CLAUDE_RESUME_WAIT_SECONDS=5
CLAUDE_RESUME_MAX_ATTEMPTS=1
export CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS
set_now 1787200000
run "$(failure_input "$SESSION_B" authentication_failed)"
assert_equals "T6 B는 이전 탐침 뒤 기본 간격" "1787200060" "$(field global last_attempt)"
set_now 1787200000
run "$(failure_input "$SESSION_C" server_error)"
assert_equals "T6 C는 이전 탐침 뒤 기본 간격" "1787200090" "$(field global last_attempt)"
assert_equals "T6 새 등록이 base_delay를 바꾸지 않음" "30" "$(field global base_delay)"
assert_equals "T6 새 등록이 max_attempts를 바꾸지 않음" "7" "$(field global max_attempts)"

# T7: 소유자 파일을 쓰는 동안의 새 잠금은 경쟁자가 삭제하지 않는다.
reset_state
unset CLAUDE_RESUME_TEST_NOW
mkdir -p "$STATE_V2/lock"
failure_input "$SESSION_A" rate_limit | sh "$RESUME" >"$TMPROOT/lock.out" 2>"$TMPROOT/lock.err" & lock_pid=$!
sleep 1
if kill -0 "$lock_pid" 2>/dev/null && [ -d "$STATE_V2/lock" ]; then
  ok "T7 소유자 없는 새 잠금을 기다림"
else
  bad "T7 소유자 없는 새 잠금을 기다림" "잠금을 회수하거나 worker가 끝남"
fi
rmdir "$STATE_V2/lock" 2>/dev/null || true
lock_rc=0; wait "$lock_pid" || lock_rc=$?
assert_equals "T7 회수 뒤 대기자가 재개" "2" "$lock_rc"

# T7: 30초가 지난 소유자 없는 잠금은 회수하고 탐침을 진행한다.
reset_state
mkdir -p "$STATE_V2/lock"
lock_created=$(file_mtime "$STATE_V2/lock")
set_now "$((lock_created + 30))"
failure_input "$SESSION_A" rate_limit | sh "$RESUME" >"$TMPROOT/stale-lock.out" 2>"$TMPROOT/stale-lock.err" & stale_lock_pid=$!
sleep 1
if kill -0 "$stale_lock_pid" 2>/dev/null; then
  bad "T7 30초 지난 소유자 없는 잠금을 회수" "contender가 대기 중"
  rmdir "$STATE_V2/lock" 2>/dev/null || true
else
  ok "T7 30초 지난 소유자 없는 잠금을 회수"
fi
stale_lock_rc=0; wait "$stale_lock_pid" || stale_lock_rc=$?
assert_equals "T7 만료 잠금 뒤 대기자가 재개" "2" "$stale_lock_rc"

# T8: 같은 due의 동시 등록은 C 바이트 순서가 빠른 세션 하나만 먼저 활성화한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=2
CLAUDE_RESUME_MAX_ATTEMPTS=1
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/register-barrier"
export CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS CLAUDE_RESUME_TEST_REGISTER_BARRIER
set_now 1787200000
mkdir -p "$CLAUDE_RESUME_TEST_REGISTER_BARRIER"
failure_input "$SESSION_B" rate_limit | sh "$RESUME" >"$TMPROOT/b.out" 2>"$TMPROOT/b.err" & bpid=$!
failure_input "$SESSION_A" rate_limit | sh "$RESUME" >"$TMPROOT/a.out" 2>"$TMPROOT/a.err" & apid=$!
for attempt in 1 2 3; do
  if [ -f "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_A" ] && [ -f "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_B" ]; then break; fi
  sleep 1
done
if [ -f "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_A" ] && [ -f "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_B" ]; then
  ok "T8 두 대기자가 같은 고정 시각에 등록"
else
  bad "T8 두 대기자가 같은 고정 시각에 등록" "등록 장벽 파일 없음"
fi
assert_equals "T8 A due_at은 고정 시각과 시작 지연의 합" "1787200002" "$(field "waiters/$SESSION_A" due_at)"
assert_equals "T8 B due_at은 고정 시각과 시작 지연의 합" "1787200002" "$(field "waiters/$SESSION_B" due_at)"
touch "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/release"
arc=0; wait "$apid" || arc=$?
brc=0; wait "$bpid" || brc=$?
unset CLAUDE_RESUME_TEST_REGISTER_BARRIER
assert_equals "T8 바이트 순서가 빠른 A만 첫 탐침" "2,0" "$arc,$brc"
assert_equals "T8 바이트 순서가 빠른 A가 활성화" "$SESSION_A" "$(field global active_session)"

# T9: 비정상 session_id와 error는 상태 루트 안의 unknown.other로 격리한다.
reset_state
run '{"session_id":"../../escaped","error":"../../escaped"}'
assert_equals "T9 비정상 입력도 재개" "2" "$rc"
assert_equals "T9 비정상 session_id 격리" "unknown" "$(field global active_session)"
if [ -f "$STATE_V2/causes/1.other" ] && [ ! -e "$TMPROOT/escaped" ]; then ok "T9 상태 루트 밖 파일 없음"; else bad "T9 상태 루트 밖 파일 없음" "escaped path"; fi

# T10: 네 원인은 기존 재개 문장을 유지한다.
for cause in rate_limit authentication_failed server_error overloaded; do
  reset_state
  run "$(failure_input "$SESSION_A" "$cause")"
  case "$cause" in
    rate_limit) expected='Continue the work that was interrupted by the usage limit.' ;;
    authentication_failed) expected='Continue the work that was interrupted by the expired login.' ;;
    *) expected='Continue the work that was interrupted by the API error.' ;;
  esac
  assert_equals "T10 $cause 재개 문장" "$expected" "$err"
done

# T11: 구조화된 resetsAt은 rate_limit 종료 시각의 기준이다.
reset_state
RESET_AT=1787230200
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"quotaLimits":{"status":"rejected","resetsAt":1787230200,"rateLimitType":"five_hour"}}' > "$TMPROOT/transcript.jsonl"
RATE_INPUT=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"rate_limit","transcript_path":"%s"}' "$SESSION_A" "$TMPROOT/transcript.jsonl")
run "$RATE_INPUT"
assert_equals "T11 구조화된 resetsAt 종료 시각" "1787233800" "$(field global deadline)"

# T12: 마지막 모델 메시지의 공식 resets 시각도 종료 시각의 기준이다.
reset_state
set_now 1787220000
run "$(printf '{"session_id":"%s","error":"rate_limit","last_assistant_message":"Your limit resets 3:45pm"}' "$SESSION_A")"
deadline=$(field global deadline)
if [ "$deadline" -gt 1787223600 ] && [ "$deadline" != 1787230800 ]; then ok "T12 메시지 resets 시각을 해석"; else bad "T12 메시지 resets 시각을 해석" "$deadline"; fi

# T13: 리셋 시각이 없으면 rate_limit은 최초 실패 뒤 10800초에 끝난다.
reset_state
set_now 1000
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T13 rate_limit 기본 종료 시각" "11800" "$(field global deadline)"

# T14: 나머지 원인도 최초 실패 뒤 10800초에 끝난다.
for cause in authentication_failed server_error overloaded; do
  reset_state
  set_now 1000
  run "$(failure_input "$SESSION_A" "$cause")"
  assert_equals "T14 $cause 종료 시각" "11800" "$(field global deadline)"
done

# T15: 원인별 종료 시각 최댓값을 전역에 쓰고 같은 원인은 연장하지 않는다.
reset_state
set_now 1000
run "$RATE_INPUT"
first_deadline=$(field global deadline)
set_now 2000
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T15 같은 원인의 종료 시각 유지" "$first_deadline" "$(field causes/1.rate_limit deadline)"
set_now 3000
run "$(failure_input "$SESSION_B" authentication_failed)"
assert_equals "T15 전역 종료 시각은 최댓값" "$first_deadline" "$(field global deadline)"

# T16: 종료 시각과 같거나 지난 훅은 모델을 깨우지 않는다.
set_now "$first_deadline"
run "$(failure_input "$SESSION_C" overloaded)"
assert_equals "T16 종료 시각 뒤 중단" "0" "$rc"
assert_equals "T16 종료 시각 뒤 빈 표준 오류" "" "$err"

# T17: 네 원인의 StopFailure와 Stop은 같은 스크립트를 정해진 계약으로 호출한다.
hooks_compact=$(tr -d '[:space:]' < "$HOOKS")
case "$hooks_compact" in
  *'"StopFailure":[{"matcher":"rate_limit|authentication_failed|server_error|overloaded","hooks":[{"type":"command","command":"sh${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh","asyncRewake":true,"timeout":600}]}]'*) ok "T17 StopFailure 훅 계약" ;;
  *) bad "T17 StopFailure 훅 계약" "$hooks_compact" ;;
esac
case "$hooks_compact" in
  *'"Stop":[{"hooks":[{"type":"command","command":"sh${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh","timeout":40}]}]'*) ok "T17 Stop 훅 계약" ;;
  *) bad "T17 Stop 훅 계약" "$hooks_compact" ;;
esac

# T18: 활성 A의 Stop은 대기 중인 B와 C에 성공을 전파한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=30
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR="$TMPROOT/t18-signals"
export CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR
unset CLAUDE_RESUME_TEST_SKIP_SLEEP
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t18-b.out" "$TMPROOT/t18-b.err" "$TMPROOT/t18-b.rc"
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t18-c.out" "$TMPROOT/t18-c.err" "$TMPROOT/t18-c.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T18 B waiter 등록" "waiter 파일 없음"
WORKER_PIDS="$WORKER_PIDS $(field "waiters/$SESSION_B" pid)"
wait_for_file "$STATE_V2/waiters/$SESSION_C" || bad "T18 C waiter 등록" "waiter 파일 없음"
WORKER_PIDS="$WORKER_PIDS $(field "waiters/$SESSION_C" pid)"
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
export CLAUDE_RESUME_TEST_SKIP_SLEEP
run "$(stop_input "$SESSION_A")"
if wait_for_file "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR/$SESSION_B" 20; then ok "T18 B 실제 USR1 수신"; else bad "T18 B 실제 USR1 수신" "신호 표식 없음"; fi
if wait_for_file "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR/$SESSION_C" 20; then ok "T18 C 실제 USR1 수신"; else bad "T18 C 실제 USR1 수신" "신호 표식 없음"; fi
wait_for_file "$TMPROOT/t18-b.rc" 20 || bad "T18 B 성공 신호 수신" "짧은 신호 창 안에 종료코드 파일 없음"
wait_for_file "$TMPROOT/t18-c.rc" 20 || bad "T18 C 성공 신호 수신" "짧은 신호 창 안에 종료코드 파일 없음"
assert_equals "T18 B 성공 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t18-b.rc" 2>/dev/null)"
assert_equals "T18 C 성공 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t18-c.rc" 2>/dev/null)"
assert_equals "T18 B 원인별 문장" "Continue the work that was interrupted by the expired login." "$(sed -n '1p' "$TMPROOT/t18-b.err" 2>/dev/null)"
assert_equals "T18 C 원인별 문장" "Continue the work that was interrupted by the API error." "$(sed -n '1p' "$TMPROOT/t18-c.err" 2>/dev/null)"
assert_equals "T18 성공 세대 기록" "3" "$(field global recovered_generation)"
if [ ! -e "$STATE_V2/waiters/$SESSION_B" ] && [ ! -e "$STATE_V2/waiters/$SESSION_C" ]; then ok "T18 소비한 waiter 파일 제거"; else bad "T18 소비한 waiter 파일 제거" "waiter 파일 잔존"; fi

# T19: 소비된 활성 세대의 두 번째 Stop은 상태를 다시 바꾸지 않는다.
t19_recovered=$(field global recovered_generation)
t19_hash=$(cksum < "$STATE_V2/global")
run "$(stop_input "$SESSION_A")"
assert_equals "T19 두 번째 Stop 성공 세대 유지" "$t19_recovered" "$(field global recovered_generation)"
assert_equals "T19 두 번째 Stop 전역 상태 유지" "$t19_hash" "$(cksum < "$STATE_V2/global")"

# T20: 활성 세션과 다른 B의 Stop은 대기자와 상태를 건드리지 않는다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=5
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
unset CLAUDE_RESUME_TEST_SKIP_SLEEP
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t20-b.out" "$TMPROOT/t20-b.err" "$TMPROOT/t20-b.rc"
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t20-c.out" "$TMPROOT/t20-c.err" "$TMPROOT/t20-c.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T20 B waiter 등록" "waiter 파일 없음"
t20_bpid=$(field "waiters/$SESSION_B" pid)
WORKER_PIDS="$WORKER_PIDS $t20_bpid"
wait_for_file "$STATE_V2/waiters/$SESSION_C" || bad "T20 C waiter 등록" "waiter 파일 없음"
t20_cpid=$(field "waiters/$SESSION_C" pid)
WORKER_PIDS="$WORKER_PIDS $t20_cpid"
t20_hash=$(cksum < "$STATE_V2/global")
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
export CLAUDE_RESUME_TEST_SKIP_SLEEP
run "$(stop_input "$SESSION_B")"
assert_equals "T20 무관한 Stop 전역 상태 유지" "$t20_hash" "$(cksum < "$STATE_V2/global")"
if kill -0 "$t20_bpid" 2>/dev/null && kill -0 "$t20_cpid" 2>/dev/null && [ ! -f "$TMPROOT/t20-b.rc" ] && [ ! -f "$TMPROOT/t20-c.rc" ]; then ok "T20 무관한 Stop은 대기자를 깨우지 않음"; else bad "T20 무관한 Stop은 대기자를 깨우지 않음" "대기 프로세스 종료"; fi
run "$(stop_input "$SESSION_A")"
wait_for_file "$TMPROOT/t20-b.rc" || true
wait_for_file "$TMPROOT/t20-c.rc" || true

# T21: 직접 신호를 놓친 waiter도 성공 세대를 소비한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=30
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t21-register"
CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR="$TMPROOT/t21-signals"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t21-b.out" "$TMPROOT/t21-b.err" "$TMPROOT/t21-b.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T21 B waiter 등록" "waiter 파일 없음"
WORKER_PIDS="$WORKER_PIDS $(field "waiters/$SESSION_B" pid)"
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
CLAUDE_RESUME_TEST_SIGNAL_BARRIER="$TMPROOT/t21-signal"
export CLAUDE_RESUME_TEST_SKIP_SLEEP CLAUDE_RESUME_TEST_SIGNAL_BARRIER
start_waiter "$(stop_input "$SESSION_A")" "$TMPROOT/t21-stop.out" "$TMPROOT/t21-stop.err" "$TMPROOT/t21-stop.rc"
if wait_for_file "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER/ready"; then ok "T21 Stop이 성공 세대를 기록하고 신호 직전 대기"; else bad "T21 Stop이 성공 세대를 기록하고 신호 직전 대기" "신호 장벽 없음"; fi
mkdir -p "$CLAUDE_RESUME_TEST_REGISTER_BARRIER"
touch "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/release"
wait_for_file "$TMPROOT/t21-b.rc" 20 || bad "T21 B가 직접 신호 없이 종료" "짧은 성공 세대 소비 창 안에 종료코드 파일 없음"
assert_equals "T21 놓친 신호의 성공 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t21-b.rc" 2>/dev/null)"
if [ ! -e "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR/$SESSION_B" ]; then ok "T21 B는 USR1 없이 성공 세대 소비"; else bad "T21 B는 USR1 없이 성공 세대 소비" "신호 표식 존재"; fi
mkdir -p "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER"
touch "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER/release"
wait_for_file "$TMPROOT/t21-stop.rc" || bad "T21 Stop 훅 종료" "종료코드 파일 없음"

# T22: 죽은 waiter의 PID는 남은 waiter 성공 전파를 막지 않는다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=30
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
unset CLAUDE_RESUME_TEST_SKIP_SLEEP
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t22-b.out" "$TMPROOT/t22-b.err" "$TMPROOT/t22-b.rc"
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t22-c.out" "$TMPROOT/t22-c.err" "$TMPROOT/t22-c.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T22 B waiter 등록" "waiter 파일 없음"
t22_dead_pid=$(field "waiters/$SESSION_B" pid)
WORKER_PIDS="$WORKER_PIDS $t22_dead_pid"
wait_for_file "$STATE_V2/waiters/$SESSION_C" || bad "T22 C waiter 등록" "waiter 파일 없음"
WORKER_PIDS="$WORKER_PIDS $(field "waiters/$SESSION_C" pid)"
kill -9 "$t22_dead_pid" 2>/dev/null || true
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
export CLAUDE_RESUME_TEST_SKIP_SLEEP
run "$(stop_input "$SESSION_A")"
wait_for_file "$TMPROOT/t22-c.rc" 20 || bad "T22 남은 C 성공 신호 수신" "짧은 신호 창 안에 종료코드 파일 없음"
assert_equals "T22 Stop은 죽은 PID가 있어도 성공" "0" "$rc"
assert_equals "T22 남은 C 성공 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t22-c.rc" 2>/dev/null)"

# T23: 결과 없이 인계 시각을 넘긴 A를 B가 이어받고 A의 늦은 Stop은 무시한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=5
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t23-c-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t23-c.out" "$TMPROOT/t23-c.err" "$TMPROOT/t23-c.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_C" || bad "T23 C waiter 등록" "waiter 파일 없음"
t23_cpid=$(field "waiters/$SESSION_C" pid)
WORKER_PIDS="$WORKER_PIDS $t23_cpid"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t23-b-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t23-b.out" "$TMPROOT/t23-b.err" "$TMPROOT/t23-b.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T23 B waiter 등록" "waiter 파일 없음"
WORKER_PIDS="$WORKER_PIDS $(field "waiters/$SESSION_B" pid)"
mkdir -p "$TMPROOT/t23-b-register"
touch "$TMPROOT/t23-b-register/release"
wait_for_file "$TMPROOT/t23-b.rc" || bad "T23 B 인계 완료" "종료코드 파일 없음"
assert_equals "T23 B 인계 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t23-b.rc" 2>/dev/null)"
assert_equals "T23 B가 활성 세션 인계" "$SESSION_B" "$(field global active_session)"
t23_hash=$(cksum < "$STATE_V2/global")
run "$(stop_input "$SESSION_A")"
assert_equals "T23 A의 늦은 Stop 전역 상태 유지" "$t23_hash" "$(cksum < "$STATE_V2/global")"
if kill -0 "$t23_cpid" 2>/dev/null && [ ! -f "$TMPROOT/t23-c.rc" ]; then ok "T23 A의 늦은 Stop은 C를 깨우지 않음"; else bad "T23 A의 늦은 Stop은 C를 깨우지 않음" "C 대기 종료"; fi
run "$(stop_input "$SESSION_B")"
mkdir -p "$TMPROOT/t23-c-register"
touch "$TMPROOT/t23-c-register/release"
wait_for_file "$TMPROOT/t23-c.rc" || true

# T24: 죽거나 30초 지난 잠금만 회수하고 바뀐 소유자는 보존한다.
reset_state
sleep 30 & t24_dead_owner=$!
WORKER_PIDS="$WORKER_PIDS $t24_dead_owner"
mkdir -p "$STATE_V2/lock"
printf 'pid=%s\nacquired_at=1787199970\n' "$t24_dead_owner" > "$STATE_V2/lock/owner"
kill -9 "$t24_dead_owner" 2>/dev/null || true
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T24 죽은 잠금 소유자 회수" "2" "$rc"

reset_state
sleep 30 & t24_old_owner=$!
sleep 30 & t24_new_owner=$!
WORKER_PIDS="$WORKER_PIDS $t24_old_owner $t24_new_owner"
mkdir -p "$STATE_V2/lock"
printf 'pid=%s\nacquired_at=1787199970\n' "$t24_old_owner" > "$STATE_V2/lock/owner"
CLAUDE_RESUME_TEST_RECLAIM_BARRIER="$TMPROOT/t24-reclaim"
export CLAUDE_RESUME_TEST_RECLAIM_BARRIER
start_waiter "$(failure_input "$SESSION_A" rate_limit)" "$TMPROOT/t24-a.out" "$TMPROOT/t24-a.err" "$TMPROOT/t24-a.rc"
if wait_for_file "$CLAUDE_RESUME_TEST_RECLAIM_BARRIER/ready"; then ok "T24 만료 잠금 회수 전 소유자 재확인"; else bad "T24 만료 잠금 회수 전 소유자 재확인" "회수 장벽 없음"; fi
printf 'pid=%s\nacquired_at=1787200000\n' "$t24_new_owner" > "$STATE_V2/lock/owner"
mkdir -p "$CLAUDE_RESUME_TEST_RECLAIM_BARRIER"
touch "$CLAUDE_RESUME_TEST_RECLAIM_BARRIER/release"
sleep 1
assert_equals "T24 바뀐 잠금 소유자 보존" "$t24_new_owner" "$(field lock/owner pid)"
kill -9 "$t24_new_owner" 2>/dev/null || true
wait "$t24_new_owner" 2>/dev/null || true
wait_for_file "$TMPROOT/t24-a.rc" || bad "T24 바뀐 소유자 종료 뒤 회수" "종료코드 파일 없음"
assert_equals "T24 안전 회수 뒤 재개" "2" "$(sed -n '1p' "$TMPROOT/t24-a.rc" 2>/dev/null)"

# T25: handoff_at이 지난 활성 세션의 늦은 Stop은 성공으로 전파하지 않는다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=5
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t25-c-register"
CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR="$TMPROOT/t25-signals"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t25-c.out" "$TMPROOT/t25-c.err" "$TMPROOT/t25-c.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_C" || bad "T25 C waiter 등록" "waiter 파일 없음"
t25_cpid=$(field "waiters/$SESSION_C" pid)
WORKER_PIDS="$WORKER_PIDS $t25_cpid"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t25-b-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t25-b.out" "$TMPROOT/t25-b.err" "$TMPROOT/t25-b.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T25 B waiter 등록" "waiter 파일 없음"
t25_bpid=$(field "waiters/$SESSION_B" pid)
WORKER_PIDS="$WORKER_PIDS $t25_bpid"
t25_recovered=$(field global recovered_generation)
set_now "$(field global handoff_at)"
run "$(stop_input "$SESSION_A")"
assert_equals "T25 만료된 A의 Stop은 성공 세대를 바꾸지 않음" "$t25_recovered" "$(field global recovered_generation)"
assert_equals "T25 만료된 A의 활성 상태 해제" "-,0,-,0" "$(field global active_session),$(field global active_generation),$(field global active_cause),$(field global handoff_at)"
if [ ! -e "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR/$SESSION_B" ] && [ ! -e "$CLAUDE_RESUME_TEST_SIGNAL_RECEIVED_DIR/$SESSION_C" ]; then ok "T25 만료된 A의 Stop은 USR1을 보내지 않음"; else bad "T25 만료된 A의 Stop은 USR1을 보내지 않음" "신호 표식 존재"; fi
if kill -0 "$t25_bpid" 2>/dev/null && kill -0 "$t25_cpid" 2>/dev/null && [ ! -f "$TMPROOT/t25-b.rc" ] && [ ! -f "$TMPROOT/t25-c.rc" ]; then ok "T25 다음 waiter가 점유하기 전에는 성공 신호 없음"; else bad "T25 다음 waiter가 점유하기 전에는 성공 신호 없음" "waiter가 종료됨"; fi
touch "$TMPROOT/t25-b-register/release"
wait_for_file "$TMPROOT/t25-b.rc" || bad "T25 B 인계 완료" "종료코드 파일 없음"
assert_equals "T25 만료 정리 뒤 B가 활성 세션 인계" "$SESSION_B" "$(field global active_session)"
run "$(stop_input "$SESSION_B")"
touch "$TMPROOT/t25-c-register/release"
wait_for_file "$TMPROOT/t25-c.rc" || true

# T26: 두 회수자가 오래된 빈 잠금을 보아도 먼저 획득한 새 잠금을 삭제하지 않는다.
reset_state
mkdir -p "$STATE_V2/lock"
t26_lock_created=$(file_mtime "$STATE_V2/lock")
set_now "$((t26_lock_created + 30))"
CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER="$TMPROOT/t26-empty"
CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER="$TMPROOT/t26-acquired"
export CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER
start_waiter "$(failure_input "$SESSION_A" rate_limit)" "$TMPROOT/t26-a.out" "$TMPROOT/t26-a.err" "$TMPROOT/t26-a.rc"
t26_apid=$STARTED_CHILD_PID
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t26-b.out" "$TMPROOT/t26-b.err" "$TMPROOT/t26-b.rc"
t26_bpid=$STARTED_CHILD_PID
wait_for_file "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER/ready.$t26_apid" 20 || bad "T26 A가 빈 잠금 회수 직전 대기" "A 회수 장벽 없음"
wait_for_file "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER/ready.$t26_bpid" 20 || bad "T26 B가 빈 잠금 회수 직전 대기" "B 회수 장벽 없음"
mkdir -p "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER"
touch "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER/release.$t26_apid"
wait_for_file "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/ready.$t26_apid" 20 || bad "T26 A가 새 잠금 획득" "A 획득 장벽 없음"
assert_equals "T26 첫 회수자 A가 새 잠금 소유" "$t26_apid" "$(field lock/owner pid)"
touch "$CLAUDE_RESUME_TEST_EMPTY_RECLAIM_BARRIER/release.$t26_bpid"
sleep 1
assert_equals "T26 두 번째 회수자가 A의 잠금을 보존" "$t26_apid" "$(field lock/owner pid)"
if [ ! -e "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/ready.$t26_bpid" ] && kill -0 "$t26_bpid" 2>/dev/null; then ok "T26 B는 A의 잠금이 풀릴 때까지 대기"; else bad "T26 B는 A의 잠금이 풀릴 때까지 대기" "B가 새 잠금을 삭제하거나 종료함"; fi
mkdir -p "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER"
touch "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/release.$t26_apid"
wait_for_file "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/ready.$t26_bpid" || bad "T26 A 해제 뒤 B가 잠금 획득" "B 획득 장벽 없음"
touch "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/release.$t26_bpid"
wait_for_file "$TMPROOT/t26-a.rc" || bad "T26 A 종료" "종료코드 파일 없음"
wait_for_file "$TMPROOT/t26-b.rc" || bad "T26 B 종료" "종료코드 파일 없음"

# T27: 파일 수정 시각 도우미는 지원 플랫폼에서 실제 epoch 초만 반환한다.
reset_state
t27_file="$TMPROOT/t27-mtime"
: > "$t27_file"
TZ=UTC0 touch -t 202001020304.05 "$t27_file"
assert_equals "T27 파일 수정 시각은 실제 epoch 초" "1577934245" "$(file_mtime "$t27_file" 2>/dev/null || true)"

# T28: 새 잠금의 owner 게시 전에는 다른 실제 프로세스가 빈 디렉터리를 회수하지 않는다.
reset_state
CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER="$TMPROOT/t28-publish"
CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER="$TMPROOT/t28-acquired"
export CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER
start_waiter "$(failure_input "$SESSION_A" rate_limit)" "$TMPROOT/t28-a.out" "$TMPROOT/t28-a.err" "$TMPROOT/t28-a.rc"
t28_apid=$STARTED_CHILD_PID
wait_for_file "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/ready.$t28_apid" 20 || bad "T28 A가 owner 게시 직전 대기" "A 게시 장벽 없음"
assert_equals "T28 게시 중인 잠금에는 아직 owner가 없음" "" "$(field lock/owner pid)"
t28_lock_created=$(file_mtime "$STATE_V2/lock")
set_now "$((t28_lock_created + 30))"
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t28-b.out" "$TMPROOT/t28-b.err" "$TMPROOT/t28-b.rc"
t28_bpid=$STARTED_CHILD_PID
sleep 1
if [ -d "$STATE_V2/lock" ] && [ -z "$(field lock/owner pid)" ] && kill -0 "$t28_apid" 2>/dev/null && kill -0 "$t28_bpid" 2>/dev/null; then ok "T28 B가 A의 게시 중 잠금을 보존"; else bad "T28 B가 A의 게시 중 잠금을 보존" "잠금 삭제, owner 조기 게시 또는 프로세스 종료"; fi
if [ ! -e "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/ready.$t28_bpid" ]; then ok "T28 B는 A의 게시 완료까지 대기"; else bad "T28 B는 A의 게시 완료까지 대기" "B가 게시 구간에 진입함"; fi
mkdir -p "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER"
touch "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/release.$t28_apid"
wait_for_file "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/ready.$t28_apid" 20 || bad "T28 A가 owner 게시 완료" "A 획득 장벽 없음"
assert_equals "T28 게시 완료 뒤 A가 잠금 소유" "$t28_apid" "$(field lock/owner pid)"
touch "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/release.$t28_apid"
wait_for_file "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/ready.$t28_bpid" 20 || bad "T28 A 해제 뒤 B가 게시 구간 진입" "B 게시 장벽 없음"
assert_equals "T28 B 게시 전 잠금에는 owner가 없음" "" "$(field lock/owner pid)"
touch "$CLAUDE_RESUME_TEST_LOCK_PUBLISH_BARRIER/release.$t28_bpid"
wait_for_file "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/ready.$t28_bpid" 20 || bad "T28 B가 owner 게시 완료" "B 획득 장벽 없음"
touch "$CLAUDE_RESUME_TEST_LOCK_ACQUIRED_BARRIER/release.$t28_bpid"
wait_for_file "$TMPROOT/t28-a.rc" || bad "T28 A 종료" "종료코드 파일 없음"
wait_for_file "$TMPROOT/t28-b.rc" || bad "T28 B 종료" "종료코드 파일 없음"

# T29: publication guard의 PID가 같은 역할의 다른 토큰 프로세스에 재사용되면 기존 소유자로 보지 않는다.
reset_state
mkdir -p "$STATE_V2"
(
  CLAUDE_RESUME_STATE_DIR="$TMPROOT/t29-other-state"
  CLAUDE_RESUME_WORKER_SESSION=$SESSION_B
  CLAUDE_RESUME_WORKER_ERROR=server_error
  CLAUDE_RESUME_WORKER_TRANSCRIPT=
  CLAUDE_RESUME_WORKER_LAST_MESSAGE=
  CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t29-other-register"
  export CLAUDE_RESUME_STATE_DIR CLAUDE_RESUME_WORKER_SESSION CLAUDE_RESUME_WORKER_ERROR CLAUDE_RESUME_WORKER_TRANSCRIPT CLAUDE_RESUME_WORKER_LAST_MESSAGE CLAUDE_RESUME_TEST_REGISTER_BARRIER
  exec sh "$RESUME" --worker live-publisher
) &
t29_reused_pid=$!
WORKER_PIDS="$WORKER_PIDS $t29_reused_pid"
wait_for_file "$TMPROOT/t29-other-register/$SESSION_B" || bad "T29 같은 역할의 다른 토큰 프로세스 준비" "worker 등록 장벽 없음"
printf 'pid=%s\nacquired_at=1787200000\nrole=worker\ntoken=stale-publisher\n' "$t29_reused_pid" > "$STATE_V2/lock-publish"
start_waiter "$(failure_input "$SESSION_A" rate_limit)" "$TMPROOT/t29-a.out" "$TMPROOT/t29-a.err" "$TMPROOT/t29-a.rc"
if wait_for_file "$TMPROOT/t29-a.rc" 20; then ok "T29 재사용된 PID의 guard 회수"; else bad "T29 재사용된 PID의 guard 회수" "새 worker가 재사용된 PID를 기존 게시자로 오인해 대기함"; fi
assert_equals "T29 guard 회수 뒤 재개" "2" "$(sed -n '1p' "$TMPROOT/t29-a.rc" 2>/dev/null)"
if kill -0 "$t29_reused_pid" 2>/dev/null; then ok "T29 PID가 같은 다른 프로세스 보존"; else bad "T29 PID가 같은 다른 프로세스 보존" "guard 회수가 다른 프로세스를 종료함"; fi

# T30: 같은 세션의 실제 호출마다 session-PID에서 파생되지 않은 새 identity 토큰을 만든다.
reset_state
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t30-first-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_A" rate_limit)" "$TMPROOT/t30-first.out" "$TMPROOT/t30-first.err" "$TMPROOT/t30-first.rc"
wait_for_file "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_A" || bad "T30 첫 호출 등록" "worker 등록 장벽 없음"
t30_first_pid=$(field "waiters/$SESSION_A" pid)
t30_first_token=$(field "waiters/$SESSION_A" token)

CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t30-second-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_A" rate_limit)" "$TMPROOT/t30-second.out" "$TMPROOT/t30-second.err" "$TMPROOT/t30-second.rc"
wait_for_file "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_A" || bad "T30 두 번째 호출 등록" "worker 등록 장벽 없음"
t30_first_waiter=$(waiter_path_for_token "$t30_first_token" || true)
t30_second_waiter="$STATE_V2/waiters/$SESSION_A"
if [ "$(field "waiters/$SESSION_A" token)" = "$t30_first_token" ]; then
  t30_second_waiter=$(find "$STATE_V2/waiters" -type f ! -name "$SESSION_A" -print | sed -n '1p')
fi
t30_second_pid=$(sed -n 's/^pid=//p' "$t30_second_waiter" | sed -n '1p')
t30_second_token=$(sed -n 's/^token=//p' "$t30_second_waiter" | sed -n '1p')

if [ -n "$t30_first_token" ] && [ -n "$t30_second_token" ] && [ "$t30_first_token" != "$t30_second_token" ]; then ok "T30 같은 세션의 두 호출은 서로 다른 토큰"; else bad "T30 같은 세션의 두 호출은 서로 다른 토큰" "$t30_first_token / $t30_second_token"; fi
if [ "$t30_first_token" != "$SESSION_A-$t30_first_pid" ] && [ "$t30_second_token" != "$SESSION_A-$t30_second_pid" ]; then ok "T30 토큰은 session-PID 결정값과 다름"; else bad "T30 토큰은 session-PID 결정값과 다름" "$t30_first_token / $t30_second_token"; fi
if [ -n "$t30_first_waiter" ] && [ -f "$t30_first_waiter" ] && [ -f "$STATE_V2/$t30_first_token" ] && [ -f "$STATE_V2/$t30_second_token" ]; then ok "T30 실행 중 identity 파일 유지"; else bad "T30 실행 중 identity 파일 유지" "identity 파일 없음"; fi
t30_first_command=$(ps -ww -p "$t30_first_pid" -o command= 2>/dev/null || true)
t30_second_command=$(ps -ww -p "$t30_second_pid" -o command= 2>/dev/null || true)
case " $t30_first_command " in *" --worker $t30_first_token "*) t30_first_argv=1 ;; *) t30_first_argv=0 ;; esac
case " $t30_second_command " in *" --worker $t30_second_token "*) t30_second_argv=1 ;; *) t30_second_argv=0 ;; esac
assert_equals "T30 토큰은 exec 뒤 argv에 유지" "1,1" "$t30_first_argv,$t30_second_argv"
touch "$TMPROOT/t30-first-register/release" "$TMPROOT/t30-second-register/release"
wait_for_file "$TMPROOT/t30-first.rc" || bad "T30 첫 호출 종료" "종료코드 파일 없음"
wait_for_file "$TMPROOT/t30-second.rc" || bad "T30 두 번째 호출 종료" "종료코드 파일 없음"
if [ ! -e "$STATE_V2/$t30_first_token" ] && [ ! -e "$STATE_V2/$t30_second_token" ]; then ok "T30 정상 종료 뒤 identity 파일 정리"; else bad "T30 정상 종료 뒤 identity 파일 정리" "identity 파일 잔존"; fi

# T31: Stop 신호 전 새 StopFailure가 시작해도 기존 waiter는 성공을 소비한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=30
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
unset CLAUDE_RESUME_TEST_SKIP_SLEEP
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t31-b.out" "$TMPROOT/t31-b.err" "$TMPROOT/t31-b.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T31 B waiter 등록" "waiter 파일 없음"
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
CLAUDE_RESUME_TEST_SIGNAL_BARRIER="$TMPROOT/t31-signal"
export CLAUDE_RESUME_TEST_SKIP_SLEEP CLAUDE_RESUME_TEST_SIGNAL_BARRIER
start_waiter "$(stop_input "$SESSION_A")" "$TMPROOT/t31-stop.out" "$TMPROOT/t31-stop.err" "$TMPROOT/t31-stop.rc"
if wait_for_file "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER/ready"; then ok "T31 Stop이 신호 직전 대기"; else bad "T31 Stop이 신호 직전 대기" "신호 장벽 없음"; fi
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t31-c.out" "$TMPROOT/t31-c.err" "$TMPROOT/t31-c.rc"
wait_for_file "$TMPROOT/t31-c.rc" 20 || bad "T31 새 StopFailure가 새 에피소드에서 재개" "C 종료코드 파일 없음"
assert_equals "T31 새 StopFailure 재개 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t31-c.rc" 2>/dev/null)"
if [ -f "$STATE_V2/waiters/$SESSION_B" ]; then ok "T31 새 에피소드가 기존 B waiter 보존"; else bad "T31 새 에피소드가 기존 B waiter 보존" "B waiter 파일 없음"; fi
touch "$CLAUDE_RESUME_TEST_SIGNAL_BARRIER/release"
wait_for_file "$TMPROOT/t31-b.rc" 20 || bad "T31 B 성공 종료" "B 종료코드 파일 없음"
assert_equals "T31 B 성공 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t31-b.rc" 2>/dev/null)"
wait_for_file "$TMPROOT/t31-stop.rc" || bad "T31 Stop 훅 종료" "종료코드 파일 없음"

# T32: 활성 재시도 세대가 없는 Stop은 상태 경로를 만들지 않는다.
reset_state
run "$(stop_input "$SESSION_B")"
if [ ! -e "$STATE_V2" ]; then ok "T32 global 부재 Stop은 상태를 만들지 않음"; else bad "T32 global 부재 Stop은 상태를 만들지 않음" "상태 경로가 생성됨"; fi
mkdir -p "$STATE_V2"
printf 'active_session=-\n' > "$STATE_V2/global"
t32_global=$(cksum < "$STATE_V2/global")
run "$(stop_input "$SESSION_B")"
assert_equals "T32 inactive sentinel Stop은 global 유지" "$t32_global" "$(cksum < "$STATE_V2/global")"
if [ ! -e "$STATE_V2/causes" ] && [ ! -e "$STATE_V2/waiters" ] && [ ! -e "$STATE_V2/lock" ] && [ ! -e "$STATE_V2/lock-publish" ]; then ok "T32 inactive sentinel Stop은 잠금과 대기 경로를 만들지 않음"; else bad "T32 inactive sentinel Stop은 잠금과 대기 경로를 만들지 않음" "불필요한 상태 경로가 생성됨"; fi

# T33: 죽은 미복구 waiter를 건너뛰고 살아 있는 C가 인계한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=30
export CLAUDE_RESUME_WAIT_SECONDS
run "$(failure_input "$SESSION_A" rate_limit)"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t33-b-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
unset CLAUDE_RESUME_TEST_SKIP_SLEEP
start_waiter "$(failure_input "$SESSION_B" authentication_failed)" "$TMPROOT/t33-b.out" "$TMPROOT/t33-b.err" "$TMPROOT/t33-b.rc"
wait_for_file "$STATE_V2/waiters/$SESSION_B" || bad "T33 B waiter 등록" "waiter 파일 없음"
t33_bpid=$(field "waiters/$SESSION_B" pid)
kill -9 "$t33_bpid" 2>/dev/null || true
set_global_field active_session -
set_global_field active_generation 0
set_global_field handoff_at 0
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t33-c-register"
export CLAUDE_RESUME_TEST_SKIP_SLEEP CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t33-c.out" "$TMPROOT/t33-c.err" "$TMPROOT/t33-c.rc"
wait_for_file "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_C" || bad "T33 C waiter 등록" "C 등록 장벽 파일 없음"
if [ ! -e "$STATE_V2/waiters/$SESSION_B" ]; then ok "T33 C 등록 전 죽은 B waiter 정리"; else bad "T33 C 등록 전 죽은 B waiter 정리" "B waiter 파일 잔존"; fi
touch "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/release"
wait_for_file "$TMPROOT/t33-c.rc" 20 || bad "T33 C가 죽은 B 대신 인계" "C 종료코드 파일 없음"
assert_equals "T33 C 인계 종료코드" "2" "$(sed -n '1p' "$TMPROOT/t33-c.rc" 2>/dev/null)"
if [ ! -e "$STATE_V2/waiters/$SESSION_B" ]; then ok "T33 죽은 B waiter 정리"; else bad "T33 죽은 B waiter 정리" "B waiter 파일 잔존"; fi

# T34: 데드라인이 지난 에피소드와 미복구 세대 차이가 남아 있어도 새 실패는 새 에피소드로 다시 깨어난다.
reset_state
set_now 1787565014
mkdir -p "$STATE_V2/causes" "$STATE_V2/waiters"
printf 'episode=5\ngeneration=73\nrecovered_generation=44\ndelay=480\nlast_attempt=1787568055\nattempts=26\nbase_delay=30\nmax_attempts=0\nactive_session=-\nactive_generation=0\nhandoff_at=0\ndeadline=1787571600\n' > "$STATE_V2/global"
printf 'first_seen=1787565014\ndeadline=1787571600\n' > "$STATE_V2/causes/5.rate_limit"
set_now 1787627460
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T34 만료 에피소드 뒤 재개 종료코드" "2" "$rc"
assert_equals "T34 만료 에피소드 뒤 재개 문장" "Continue the work that was interrupted by the usage limit." "$err"
assert_equals "T34 새 에피소드 번호" "6" "$(field global episode)"
assert_equals "T34 오래된 원인 파일 정리" "" "$(ls "$STATE_V2/causes" | grep -v '^6\.' || true)"
assert_equals "T34 새 원인 파일 최초 발견 시각" "1787627460" "$(field causes/6.rate_limit first_seen)"
assert_equals "T34 탐침 상태 초기화" "1787627490,1,30" "$(field global last_attempt),$(field global attempts),$(field global delay)"

# T35: active_cause는 활성 세션과 함께 설정되고 재발·Stop·새 에피소드에서 해제된다.
reset_state
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T35 활성 원인 설정" "rate_limit" "$(field global active_cause)"
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t35-recurrence-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_A" authentication_failed)" "$TMPROOT/t35-recurrence.out" "$TMPROOT/t35-recurrence.err" "$TMPROOT/t35-recurrence.rc"
wait_for_file "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_A" || bad "T35 재발 waiter 등록" "등록 장벽 파일 없음"
assert_equals "T35 재발 중 활성 원인 해제" "-,0,-,0" "$(field global active_session),$(field global active_generation),$(field global active_cause),$(field global handoff_at)"
touch "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/release"
wait_for_file "$TMPROOT/t35-recurrence.rc" || bad "T35 재발 waiter 종료" "종료코드 파일 없음"
assert_equals "T35 새 활성 원인 설정" "$SESSION_A,authentication_failed" "$(field global active_session),$(field global active_cause)"
run "$(stop_input "$SESSION_A")"
assert_equals "T35 Stop 뒤 활성 원인 해제" "-,-" "$(field global active_session),$(field global active_cause)"

set_global_field active_cause overloaded
CLAUDE_RESUME_TEST_REGISTER_BARRIER="$TMPROOT/t35-new-episode-register"
export CLAUDE_RESUME_TEST_REGISTER_BARRIER
start_waiter "$(failure_input "$SESSION_C" server_error)" "$TMPROOT/t35-new-episode.out" "$TMPROOT/t35-new-episode.err" "$TMPROOT/t35-new-episode.rc"
wait_for_file "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/$SESSION_C" || bad "T35 새 에피소드 waiter 등록" "등록 장벽 파일 없음"
assert_equals "T35 새 에피소드의 stale 활성 원인 해제" "-" "$(field global active_cause)"
touch "$CLAUDE_RESUME_TEST_REGISTER_BARRIER/release"
wait_for_file "$TMPROOT/t35-new-episode.rc" || bad "T35 새 에피소드 waiter 종료" "종료코드 파일 없음"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
