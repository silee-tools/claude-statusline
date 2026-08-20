#!/bin/sh
# resume.sh 계약 테스트. 실제 API 대신 훅 입력, 상태 루트, 시각과 대기를 제어한다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
RESUME="$SRC/scripts/resume.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/resume-test.XXXXXX")
completed=0
trap 'rc=$?; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT

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

field() {
  sed -n "s/^$2=//p" "$STATE_V2/$1" 2>/dev/null | sed -n '1p'
}

set_now() {
  CLAUDE_RESUME_TEST_NOW=$1
  export CLAUDE_RESUME_TEST_NOW
}

run() {
  rc=0
  err=$(printf '%s' "$1" | sh "$RESUME" 2>&1 >/dev/null) || rc=$?
}

reset_state() {
  rm -rf "$CLAUDE_RESUME_STATE_DIR"
  unset CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS
  CLAUDE_RESUME_WAIT_SECONDS=0
  export CLAUDE_RESUME_WAIT_SECONDS
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

# T7: 같은 due의 동시 등록은 C 바이트 순서가 빠른 세션 하나만 먼저 활성화한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=2
CLAUDE_RESUME_MAX_ATTEMPTS=1
export CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS
unset CLAUDE_RESUME_TEST_NOW CLAUDE_RESUME_TEST_SKIP_SLEEP
failure_input "$SESSION_B" rate_limit | sh "$RESUME" >"$TMPROOT/b.out" 2>"$TMPROOT/b.err" & bpid=$!
failure_input "$SESSION_A" rate_limit | sh "$RESUME" >"$TMPROOT/a.out" 2>"$TMPROOT/a.err" & apid=$!
arc=0; wait "$apid" || arc=$?
brc=0; wait "$bpid" || brc=$?
CLAUDE_RESUME_TEST_SKIP_SLEEP=1
export CLAUDE_RESUME_TEST_SKIP_SLEEP
set_now 1787200000
assert_equals "T7 바이트 순서가 빠른 A만 첫 탐침" "2,0" "$arc,$brc"
assert_equals "T7 바이트 순서가 빠른 A가 활성화" "$SESSION_A" "$(field global active_session)"

# T8: 비정상 session_id와 error는 상태 루트 안의 unknown.other로 격리한다.
reset_state
run '{"session_id":"../../escaped","error":"../../escaped"}'
assert_equals "T8 비정상 입력도 재개" "2" "$rc"
assert_equals "T8 비정상 session_id 격리" "unknown" "$(field global active_session)"
if [ -f "$STATE_V2/causes/1.other" ] && [ ! -e "$TMPROOT/escaped" ]; then ok "T8 상태 루트 밖 파일 없음"; else bad "T8 상태 루트 밖 파일 없음" "escaped path"; fi

# T9: 네 원인은 기존 재개 문장을 유지한다.
for cause in rate_limit authentication_failed server_error overloaded; do
  reset_state
  run "$(failure_input "$SESSION_A" "$cause")"
  case "$cause" in
    rate_limit) expected='Continue the work that was interrupted by the usage limit.' ;;
    authentication_failed) expected='Continue the work that was interrupted by the expired login.' ;;
    *) expected='Continue the work that was interrupted by the API error.' ;;
  esac
  assert_equals "T9 $cause 재개 문장" "$expected" "$err"
done

# T10: 구조화된 resetsAt은 rate_limit 종료 시각의 기준이다.
reset_state
RESET_AT=1787230200
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"quotaLimits":{"status":"rejected","resetsAt":1787230200,"rateLimitType":"five_hour"}}' > "$TMPROOT/transcript.jsonl"
RATE_INPUT=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"rate_limit","transcript_path":"%s"}' "$SESSION_A" "$TMPROOT/transcript.jsonl")
run "$RATE_INPUT"
assert_equals "T10 구조화된 resetsAt 종료 시각" "1787233800" "$(field global deadline)"

# T11: 마지막 모델 메시지의 공식 resets 시각도 종료 시각의 기준이다.
reset_state
set_now 1787220000
run "$(printf '{"session_id":"%s","error":"rate_limit","last_assistant_message":"Your limit resets 3:45pm"}' "$SESSION_A")"
deadline=$(field global deadline)
if [ "$deadline" -gt 1787223600 ] && [ "$deadline" != 1787230800 ]; then ok "T11 메시지 resets 시각을 해석"; else bad "T11 메시지 resets 시각을 해석" "$deadline"; fi

# T12: 리셋 시각이 없으면 rate_limit은 최초 실패 뒤 10800초에 끝난다.
reset_state
set_now 1000
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T12 rate_limit 기본 종료 시각" "11800" "$(field global deadline)"

# T13: 나머지 원인도 최초 실패 뒤 10800초에 끝난다.
for cause in authentication_failed server_error overloaded; do
  reset_state
  set_now 1000
  run "$(failure_input "$SESSION_A" "$cause")"
  assert_equals "T13 $cause 종료 시각" "11800" "$(field global deadline)"
done

# T14: 원인별 종료 시각 최댓값을 전역에 쓰고 같은 원인은 연장하지 않는다.
reset_state
set_now 1000
run "$RATE_INPUT"
first_deadline=$(field global deadline)
set_now 2000
run "$(failure_input "$SESSION_A" rate_limit)"
assert_equals "T14 같은 원인의 종료 시각 유지" "$first_deadline" "$(field causes/1.rate_limit deadline)"
set_now 3000
run "$(failure_input "$SESSION_B" authentication_failed)"
assert_equals "T14 전역 종료 시각은 최댓값" "$first_deadline" "$(field global deadline)"

# T15: 종료 시각과 같거나 지난 훅은 모델을 깨우지 않는다.
set_now "$first_deadline"
run "$(failure_input "$SESSION_C" overloaded)"
assert_equals "T15 종료 시각 뒤 중단" "0" "$rc"
assert_equals "T15 종료 시각 뒤 빈 표준 오류" "" "$err"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
