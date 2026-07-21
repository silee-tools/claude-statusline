#!/bin/sh
set -eu
SRC=$(cd "$(dirname "$0")/.." && pwd)
AWK="$SRC/scripts/json.awk"
TAB=$(printf '\t')
pass=0; fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want=[%s]\n  got =[%s]\n' "$1" "$2" "$3"; fi
}
get() { printf '%s' "$1" | awk -f "$AWK" | awk -F"$TAB" -v k="$2" '$1==k{print $2; exit}'; }

J='{"workspace":{"current_dir":"/tmp/a b"},"model":{"display_name":"Claude Opus 4.8","version":"x"},"version":"2.1.11","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000}},"rate_limits":{"five_hour":{"used_percentage":24.5}}}'
check "cwd(공백)"        "/tmp/a b"        "$(get "$J" ..workspace.current_dir)"
check "동명 중첩키 구분"  "2.1.11"          "$(get "$J" ..version)"
check "model.version"    "x"              "$(get "$J" ..model.version)"
check "숫자"             "40000"          "$(get "$J" ..context_window.current_usage.input_tokens)"
check "소수 퍼센트"       "24.5"           "$(get "$J" ..rate_limits.five_hour.used_percentage)"
check "부재 필드는 빈값"  ""               "$(get "$J" ..rate_limits.seven_day.used_percentage)"

# 이스케이프된 따옴표·역슬래시가 값에 보존된다.
JE='{"path":"a\"b\\c"}'
check "이스케이프 보존"   'a"b\c'          "$(get "$JE" ..path)"

printf 'json.awk: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
