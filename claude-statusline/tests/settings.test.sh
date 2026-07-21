#!/bin/sh
set -eu
SRC=$(cd "$(dirname "$0")/.." && pwd)
UPD="$SRC/scripts/settings-update.awk"
JSON="$SRC/scripts/json.awk"
TAB=$(printf '\t')
pass=0; fail=0
cmd() { awk -f "$JSON" | awk -F"$TAB" -v k="$1" '$1==k{print $2; exit}'; }
NEW='{"type":"command","command":"sh /p/scripts/statusline.sh"}'

# A: 부재 → 삽입
a=$(printf '{\n  "model":"opus"\n}\n' | awk -v NEW="$NEW" -f "$UPD")
[ "$(printf '%s' "$a" | cmd ..statusLine.command)" = "sh /p/scripts/statusline.sh" ] \
  && [ "$(printf '%s' "$a" | cmd ..model)" = "opus" ] \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL A"; }

# B: 존재(중첩 브레이스) → 치환, 다른 키 보존
b=$(printf '{\n  "statusLine":{"type":"command","command":"old","env":{"X":"y"}},\n  "model":"opus"\n}\n' | awk -v NEW="$NEW" -f "$UPD")
[ "$(printf '%s' "$b" | cmd ..statusLine.command)" = "sh /p/scripts/statusline.sh" ] \
  && [ "$(printf '%s' "$b" | cmd ..model)" = "opus" ] \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL B"; }

# C: 빈 객체
c=$(printf '{}\n' | awk -v NEW="$NEW" -f "$UPD")
[ "$(printf '%s' "$c" | cmd ..statusLine.command)" = "sh /p/scripts/statusline.sh" ] \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL C"; }

# D: 문자열 내 브레이스가 혼동시키지 않는다
d=$(printf '{\n  "greeting":"hi {there}",\n  "statusLine":"x",\n  "z":1\n}\n' | awk -v NEW="$NEW" -f "$UPD")
[ "$(printf '%s' "$d" | cmd ..statusLine.command)" = "sh /p/scripts/statusline.sh" ] \
  && [ "$(printf '%s' "$d" | cmd ..greeting)" = "hi {there}" ] \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL D"; }

printf 'settings-update.awk: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
