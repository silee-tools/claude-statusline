#!/bin/sh
# fit-line1.awk 폭 계산·절단 테스트
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
AWKP="$SRC/scripts/fit-line1.awk"
ESC=$(printf '\033')

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

# 두 줄을 넣고 두 줄을 받는다.
fit() { printf '%s\n%s\n' "$1" "$2" | LC_ALL=C awk -f "$AWKP"; }
# 색 코드를 뺀 표시 폭. 한글 등 두 칸 문자를 두 칸으로 센다.
# fit-line1.awk 의 is_wide 가 다루는 8개 범위 중 이 스위트의 픽스처가 실제로 쓰는 3개
# (한글 자모·CJK·한글 음절)만 옮겼다. 의도적인 부분 오라클이다 — 구현에서 그대로 가져와
# 쓰지 않고 독립적으로 유지하기 위해서다. 완전한 폭 분류기로 오인하지 않는다.
vwidth() {
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g" | LC_ALL=C awk '
    function wide(s) {
      if (length(s) == 4) return 1
      if (length(s) != 3) return 0
      if (s >= "\341\204\200" && s <= "\341\205\237") return 1
      if (s >= "\342\272\200" && s <= "\352\223\217") return 1
      if (s >= "\352\260\200" && s <= "\355\236\243") return 1
      return 0
    }
    { n=length($0); i=1; t=0
      while (i<=n) { c=substr($0,i,1)
        if (c < "\200") L=1; else if (c < "\340") L=2; else if (c < "\360") L=3; else L=4
        t += wide(substr($0,i,L)) ? 2 : 1; i += L }
      printf "%d", t }'
}
line1_width() {
  w=$(vwidth "$1"); [ -n "$2" ] && w=$((w + 1 + 1 + $(vwidth "$2")))
  printf '%d' $((5 + 1 + w))
}

# T1: 예산 안이면 그대로 통과한다
R=$(fit "~/↪2/claude-statusline" "main")
assert_equals "T1 짧은 경로 그대로" "~/↪2/claude-statusline" "$(printf '%s\n' "$R" | sed -n 1p)"
assert_equals "T1 짧은 브랜치 그대로" "main" "$(printf '%s\n' "$R" | sed -n 2p)"

# T2: 둘 다 33칼럼을 넘으면 각자 33칼럼으로 잘리고 첫 행이 74칼럼을 넘지 않는다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway" "feature/PROJ-1469-connect-api-secrets")
P=$(printf '%s\n' "$R" | sed -n 1p); B=$(printf '%s\n' "$R" | sed -n 2p)
assert_equals "T2 경로 33칼럼" "33" "$(vwidth "$P")"
assert_equals "T2 브랜치 33칼럼" "33" "$(vwidth "$B")"
assert_equals "T2 첫 행 74칼럼 이내" "74" "$(line1_width "$P" "$B")"

# T3: 브랜치가 짧으면 남는 몫이 경로로 간다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway-extra-long-name-here" "main")
P=$(printf '%s\n' "$R" | sed -n 1p)
assert_equals "T3 브랜치가 짧으면 경로가 62칼럼까지" "62" "$(vwidth "$P")"

# T4: 두 칸 문자를 반으로 쪼개지 않는다
R=$(fit "~/↪2/helper/↪2/성과-여정-2분기-리뷰-아주-긴-이름-테스트-문자열" "성과-여정-2분기-리뷰-아주-긴-브랜치-이름")
P=$(printf '%s\n' "$R" | sed -n 1p); B=$(printf '%s\n' "$R" | sed -n 2p)
assert_equals "T4 한글 경로 짝수 폭(반쪽 없음)" "32" "$(vwidth "$P")"
assert_equals "T4 한글 브랜치 짝수 폭(반쪽 없음)" "32" "$(vwidth "$B")"
assert_equals "T4 첫 행 74칼럼 이내" "72" "$(line1_width "$P" "$B")"

# T5: 잘리면 줄임표가 붙는다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway" "feature/PROJ-1469-connect-api-secrets")
case "$(printf '%s\n' "$R" | sed -n 1p)" in *…) ok "T5 경로 줄임표";; *) bad "T5 경로 줄임표" "$R";; esac
case "$(printf '%s\n' "$R" | sed -n 2p)" in *…) ok "T5 브랜치 줄임표";; *) bad "T5 브랜치 줄임표" "$R";; esac

# T6: 색 코드는 폭 0으로 세고 보존하며, 잘린 줄은 리셋으로 닫는다
COLORED="${ESC}[2m~/${ESC}[0m${ESC}[34mvery-long-project-directory-name-that-overflows${ESC}[0m"
R=$(fit "$COLORED" "feature/PROJ-1469-connect-api-secrets")
P=$(printf '%s\n' "$R" | sed -n 1p)
assert_equals "T6 색 코드 제외 폭 33" "33" "$(vwidth "$P")"
case "$P" in *"${ESC}[34m"*) ok "T6 색 코드 보존";; *) bad "T6 색 코드 보존" "$P";; esac
case "$P" in *"${ESC}[0m") ok "T6 잘린 줄이 리셋으로 닫힘";; *) bad "T6 잘린 줄이 리셋으로 닫힘" "$P";; esac

# T7: 브랜치가 없으면 경로가 68칼럼까지 쓴다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway-extra-long-name-here-more" "")
P=$(printf '%s\n' "$R" | sed -n 1p)
assert_equals "T7 브랜치 부재 시 경로 68칼럼" "68" "$(vwidth "$P")"
assert_equals "T7 브랜치 부재 시 첫 행 74칼럼 이내" "74" "$(line1_width "$P" "")"

# T8: 색 없는 짧은 입력에는 리셋을 덧붙이지 않는다
R=$(fit "~/short" "main")
case "$(printf '%s\n' "$R" | sed -n 1p)" in
  *"${ESC}["*) bad "T8 색 없는 입력에 이스케이프 미추가" "$R";;
  *) ok "T8 색 없는 입력에 이스케이프 미추가";;
esac

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
