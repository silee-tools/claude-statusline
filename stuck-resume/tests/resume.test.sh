#!/bin/sh
# resume.sh 단위 테스트. 실제 한도 도달은 재현할 수 없으므로, 훅이 받는 입력과
# 재시도 상한만 주입해 종료코드와 주입 문자열과 카운터를 검증한다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
RESUME="$SRC/scripts/resume.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/resume-test.XXXXXX")
# bash 3.2 는 EXIT 트랩 진입에서 $? 를 0 으로 만든다. completed 플래그가 없으면 set -eu 중단이
# 종료코드 0 으로 보고된다. 정본은 AGENTS.md 의 Testing 절이다.
completed=0
trap 'rc=$?; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT

CLAUDE_RESUME_STATE_DIR="$TMPROOT/state"
CLAUDE_RESUME_WAIT_SECONDS=0
CLAUDE_RESUME_MAX_ATTEMPTS=72
export CLAUDE_RESUME_STATE_DIR CLAUDE_RESUME_WAIT_SECONDS CLAUDE_RESUME_MAX_ATTEMPTS

SESSION=11111111-2222-3333-4444-555555555555
INPUT=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"rate_limit"}' "$SESSION")

rc=0
err=""
run() {
  rc=0
  err=$(printf '%s' "$1" | sh "$RESUME" 2>&1 >/dev/null) || rc=$?
}

counter_value() { cat "$CLAUDE_RESUME_STATE_DIR/$1" 2>/dev/null || echo "(none)"; }

reset_state() { rm -rf "$CLAUDE_RESUME_STATE_DIR"; }

# T1: 상한 안의 첫 시도는 모델을 깨우는 종료코드 2 로 끝나고 재개 프롬프트를 stderr 에 낸다.
reset_state
run "$INPUT"
assert_equals "T1 상한 안에서는 종료코드 2 로 모델을 깨움" "2" "$rc"
assert_equals "T1 재개 프롬프트를 stderr 로 주입" \
  "Continue the work that was interrupted by the usage limit." "$err"
assert_equals "T1 세션별 카운터를 1 로 기록" "1" "$(counter_value "$SESSION.rate_limit")"

# T2: 같은 세션의 재발화는 카운터를 누적한다.
run "$INPUT"
assert_equals "T2 같은 세션의 두 번째 발화도 재개" "2" "$rc"
assert_equals "T2 카운터 누적" "2" "$(counter_value "$SESSION.rate_limit")"

# T3: 상한을 넘으면 아무것도 주입하지 않고 조용히 멈춘다. 종료코드 0 이라 모델이 깨지 않는다.
reset_state
CLAUDE_RESUME_MAX_ATTEMPTS=2
run "$INPUT"; assert_equals "T3 사전 준비: 1회차 재개" "2" "$rc"
run "$INPUT"; assert_equals "T3 사전 준비: 2회차 재개" "2" "$rc"
run "$INPUT"
assert_equals "T3 상한 초과분은 종료코드 0 으로 멈춤" "0" "$rc"
assert_equals "T3 상한 초과분은 아무것도 주입하지 않음" "" "$err"
CLAUDE_RESUME_MAX_ATTEMPTS=72

# T4: 세션마다 카운터가 분리돼, 한 세션의 소진이 다른 세션의 재개를 막지 않는다.
reset_state
OTHER=99999999-8888-7777-6666-555555555555
CLAUDE_RESUME_MAX_ATTEMPTS=1
run "$INPUT"; run "$INPUT"
assert_equals "T4 사전 준비: 첫 세션은 상한 소진" "0" "$rc"
run "$(printf '{"session_id":"%s","error":"rate_limit"}' "$OTHER")"
assert_equals "T4 다른 세션은 자기 카운터로 재개" "2" "$rc"
assert_equals "T4 다른 세션의 카운터는 1" "1" "$(counter_value "$OTHER.rate_limit")"
CLAUDE_RESUME_MAX_ATTEMPTS=72

# T5: session_id 가 없는 입력에도 죽지 않고 공용 카운터로 재개한다.
reset_state
run '{"error":"rate_limit"}'
assert_equals "T5 session_id 없는 입력도 재개" "2" "$rc"
assert_equals "T5 session_id 없으면 unknown 카운터 사용" "1" "$(counter_value unknown.rate_limit)"

# T6: 경로 구분자가 섞인 session_id 는 상태 디렉터리 밖에 파일을 만들지 않는다.
reset_state
run '{"session_id":"../../escaped","error":"rate_limit"}'
assert_equals "T6 비정상 session_id 도 재개" "2" "$rc"
assert_equals "T6 비정상 session_id 는 unknown 으로 격리" "1" "$(counter_value unknown.rate_limit)"
ENTRIES=$(ls -A "$CLAUDE_RESUME_STATE_DIR" | tr '\n' ' ')
assert_equals "T6 상태 디렉터리에는 unknown 만 존재" "unknown.rate_limit " "$ENTRIES"

# T7: 재개 전에 실제로 대기한다. 대기하지 않으면 한도가 풀리기 전에 다시 시도한다.
reset_state
CLAUDE_RESUME_WAIT_SECONDS=2
START=$(date +%s)
run "$INPUT"
ELAPSED=$(( $(date +%s) - START ))
CLAUDE_RESUME_WAIT_SECONDS=0
assert_equals "T7 대기 뒤에도 종료코드 2" "2" "$rc"
if [ "$ELAPSED" -ge 2 ]; then
  ok "T7 재개 전 대기 시간을 실제로 소비"
else
  bad "T7 재개 전 대기 시간을 실제로 소비 (expected >=2s)" "${ELAPSED}s"
fi

AUTH_INPUT=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"authentication_failed","last_assistant_message":"Login expired \302\267 Please run /login"}' "$SESSION")

# T8: 로그인 만료도 재개 대상이고, 문구가 원인을 정확히 말한다.
reset_state
run "$AUTH_INPUT"
assert_equals "T8 로그인 만료도 종료코드 2 로 재개" "2" "$rc"
assert_equals "T8 로그인 만료 문구를 주입" \
  "Continue the work that was interrupted by the expired login." "$err"
assert_equals "T8 원인별 카운터에 기록" "1" "$(counter_value "$SESSION.authentication_failed")"

# T9: 한 원인으로 상한을 소진해도 다른 원인의 재개를 막지 않는다.
reset_state
CLAUDE_RESUME_MAX_ATTEMPTS=1
run "$INPUT"; run "$INPUT"
assert_equals "T9 사전 준비: 사용량 한도 상한 소진" "0" "$rc"
run "$AUTH_INPUT"
assert_equals "T9 로그인 만료는 자기 카운터로 재개" "2" "$rc"
CLAUDE_RESUME_MAX_ATTEMPTS=72

# T10: 모르는 원인은 원인을 특정하지 않는 문구를 쓰고, 죽지 않는다.
reset_state
run '{"session_id":"'"$SESSION"'","error":"billing_error"}'
assert_equals "T10 모르는 원인도 재개" "2" "$rc"
assert_equals "T10 원인을 특정하지 않는 문구" \
  "Continue the work that was interrupted by the API error." "$err"
assert_equals "T10 모르는 원인은 other 로 모은다" "1" "$(counter_value "$SESSION.other")"

# T11: error 가 아예 없어도 죽지 않는다.
reset_state
run '{"session_id":"'"$SESSION"'"}'
assert_equals "T11 error 없는 입력도 재개" "2" "$rc"
assert_equals "T11 error 없으면 other 카운터" "1" "$(counter_value "$SESSION.other")"

# T12: 경로 구분자가 섞인 error 는 상태 디렉터리 밖에 파일을 만들지 않는다.
reset_state
run '{"session_id":"'"$SESSION"'","error":"../../escaped"}'
assert_equals "T12 비정상 error 도 재개" "2" "$rc"
ENTRIES=$(ls -A "$CLAUDE_RESUME_STATE_DIR" | tr '\n' ' ')
assert_equals "T12 상태 디렉터리에는 격리된 이름만" "$SESSION.other " "$ENTRIES"

# T13: 일시적인 API 실패 둘도 재개 대상이며 각자의 카운터를 쓴다. 문구는 원인을 특정하지 않는
#      기본 문장인데, "API unavailable" 과 "API overloaded" 를 한 문장으로 덮기 때문이다.
for cause in server_error overloaded; do
  reset_state
  run '{"session_id":"'"$SESSION"'","error":"'"$cause"'"}'
  assert_equals "T13 $cause 는 종료코드 2 로 재개" "2" "$rc"
  assert_equals "T13 $cause 는 원인을 특정하지 않는 문구" \
    "Continue the work that was interrupted by the API error." "$err"
  assert_equals "T13 $cause 는 자기 카운터에 기록" "1" "$(counter_value "$SESSION.$cause")"
done

# T14: 기본 상한이 원인별로 갈린다. 상한까지 실제로 돌리면 수백 번을 실행해야 하므로, 카운터
#      파일에 직전 값을 심어 경계 두 번만 실행한다. 카운터는 그 파일의 정수 한 줄이 전부다.
#      환경변수 상한을 걷어야 스크립트의 기본값이 드러나므로 이 구간에서만 unset 한다.
unset CLAUDE_RESUME_MAX_ATTEMPTS
for probe in "server_error:240" "overloaded:240" "rate_limit:90" "authentication_failed:90"; do
  cause=${probe%%:*}; cap=${probe##*:}
  reset_state
  mkdir -p "$CLAUDE_RESUME_STATE_DIR"
  printf '%s\n' "$((cap - 1))" > "$CLAUDE_RESUME_STATE_DIR/$SESSION.$cause"
  run '{"session_id":"'"$SESSION"'","error":"'"$cause"'"}'
  assert_equals "T14 $cause 는 $cap 회까지 재개" "2" "$rc"
  run '{"session_id":"'"$SESSION"'","error":"'"$cause"'"}'
  assert_equals "T14 $cause 는 $cap 회를 넘기면 멈춤" "0" "$rc"
done
CLAUDE_RESUME_MAX_ATTEMPTS=72
export CLAUDE_RESUME_MAX_ATTEMPTS

# T15: 훅이 네 원인 모두에 발화하도록 등록돼 있다. 스크립트가 원인을 알아도 matcher 가 그
#      원인에 걸리지 않으면 스크립트는 호출조차 되지 않는다.
MATCHER=$(sed -n 's/.*"matcher"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/hooks/hooks.json")
for cause in rate_limit authentication_failed server_error overloaded; do
  case "|$MATCHER|" in
    *"|$cause|"*) ok "T15 matcher 에 $cause 가 있다" ;;
    *) bad "T15 matcher 에 $cause 가 있다" "$MATCHER" ;;
  esac
done

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
