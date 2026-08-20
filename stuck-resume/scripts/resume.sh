#!/bin/sh
# Claude Code 는 이 훅이 종료코드 2 로 끝날 때만 모델을 깨우고, stderr 로 쓴 텍스트만
# 프롬프트로 주입한다. stdout 은 주입되지 않는다.
set -eu

STATE_DIR="${CLAUDE_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume}"

input=$(cat)

session=$(printf '%s' "$input" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || session=""
case "$session" in
  '' | *[!0-9A-Za-z_-]*) session=unknown ;;
esac

error=$(printf '%s' "$input" \
  | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || error=""
case "$error" in
  rate_limit|authentication_failed|server_error|overloaded) ;;
  *) error=other ;;
esac

# 과부하와 일시적 서버 오류는 대개 분 단위로 풀리므로 자주 짧게 두드리고, 사용량 한도와 만료된
# 로그인은 시간이나 사람이 풀어 줄 때까지 드물게 오래 기다린다. 대기가 hooks.json 의 timeout 을
# 넘으면 훅이 잘려 재개되지 않으므로 그 값과 함께 조정한다.
case "$error" in
  server_error|overloaded) wait_default=30;  attempts_default=240 ;;
  *)                       wait_default=120; attempts_default=90 ;;
esac
WAIT_SECONDS="${CLAUDE_RESUME_WAIT_SECONDS:-$wait_default}"
MAX_ATTEMPTS="${CLAUDE_RESUME_MAX_ATTEMPTS:-$attempts_default}"

mkdir -p "$STATE_DIR"
find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

counter="$STATE_DIR/$session.$error"
attempts=$(cat "$counter" 2>/dev/null || echo 0)
case "$attempts" in
  '' | *[!0-9]*) attempts=0 ;;
esac
attempts=$((attempts + 1))
printf '%s\n' "$attempts" > "$counter"

[ "$attempts" -le "$MAX_ATTEMPTS" ] || exit 0

sleep "$WAIT_SECONDS"

case "$error" in
  rate_limit)
    printf 'Continue the work that was interrupted by the usage limit.\n' >&2 ;;
  authentication_failed)
    printf 'Continue the work that was interrupted by the expired login.\n' >&2 ;;
  *)
    printf 'Continue the work that was interrupted by the API error.\n' >&2 ;;
esac
exit 2
