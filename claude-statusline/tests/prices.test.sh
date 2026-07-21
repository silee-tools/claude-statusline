#!/bin/sh
# fetch-prices.sh 회귀 테스트
# 3단 폴백(fetch 성공 / 기존 캐시 유지 / 내장 테이블) 중 아래 두 경로를 결정론적으로 검증한다.
#   1) fetch 성공: 가짜 curl 이 4대상 모델 + 점 포함 키(gpt-3.5-turbo) + prefix 변형
#      (anthropic.claude-opus-4-8, 다른 숫자) 을 담은 fixture JSON 을 내려받게 하고,
#      추출기가 bare 키(점 없는 "claude-opus-4-8":) 값만 뽑는지 확인한다.
#   2) 폴백: curl 부재 + 기존 prices.tsv 없음 → 내장 테이블 4줄이 그대로 쓰이는지 확인한다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$SRC/scripts/fetch-prices.sh"
TAB=$(printf '\t')

pass=0; fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want=[%s]\n  got =[%s]\n' "$1" "$2" "$3"; fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# 케이스 1: fetch 성공 — 가짜 curl 로 fixture JSON 을 내려받게 한다.
# ---------------------------------------------------------------------------
CASE1="$TMPROOT/case1"
mkdir -p "$CASE1/cache" "$CASE1/bin"
export XDG_CACHE_HOME="$CASE1/cache"

FIXTURE="$CASE1/fixture.json"
cat > "$FIXTURE" <<'JSON'
{
  "gpt-3.5-turbo": {
    "input_cost_per_token": 0.0000015,
    "output_cost_per_token": 0.000002
  },
  "anthropic.claude-opus-4-8": {
    "input_cost_per_token": 0.999,
    "output_cost_per_token": 0.999,
    "cache_creation_input_token_cost": 0.999,
    "cache_read_input_token_cost": 0.999
  },
  "claude-fable-5": {
    "input_cost_per_token": 0.00001,
    "output_cost_per_token": 0.00005,
    "cache_creation_input_token_cost": 0.0000125,
    "cache_read_input_token_cost": 0.000001
  },
  "claude-opus-4-8": {
    "input_cost_per_token": 0.000005,
    "output_cost_per_token": 0.000025,
    "cache_creation_input_token_cost": 0.00000625,
    "cache_read_input_token_cost": 0.0000005
  },
  "claude-sonnet-5": {
    "input_cost_per_token": 0.000002,
    "output_cost_per_token": 0.00001,
    "cache_creation_input_token_cost": 0.0000025,
    "cache_read_input_token_cost": 0.0000002
  },
  "claude-haiku-4-5": {
    "input_cost_per_token": 0.000001,
    "output_cost_per_token": 0.000005,
    "cache_creation_input_token_cost": 0.00000125,
    "cache_read_input_token_cost": 0.0000001
  }
}
JSON

# 가짜 curl: 인자를 무시하고 -o 뒤 경로에 fixture 를 복사한 뒤 exit 0.
cat > "$CASE1/bin/curl" <<EOF
#!/bin/sh
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; fi
  prev="\$a"
done
[ -n "\$out" ] && cp "$FIXTURE" "\$out"
exit 0
EOF
chmod +x "$CASE1/bin/curl"

PATH="$CASE1/bin:$PATH" "$SCRIPT"

OUT1="$CASE1/cache/claude-statusline/prices.tsv"
check "case1: prices.tsv 존재"     "1" "$([ -f "$OUT1" ] && echo 1 || echo 0)"
check "case1: 정확히 4줄"          "4" "$(wc -l < "$OUT1" | tr -d ' ')"

get_row() { awk -F"$TAB" -v m="$1" '$1==m{print; exit}' "$OUT1"; }

check "case1: fable-5 bare 값"      "claude-fable-5${TAB}0.00001${TAB}0.00005${TAB}0.0000125${TAB}0.000001" "$(get_row claude-fable-5)"
check "case1: opus-4-8 bare 값(prefix 아님)" "claude-opus-4-8${TAB}0.000005${TAB}0.000025${TAB}0.00000625${TAB}0.0000005" "$(get_row claude-opus-4-8)"
check "case1: sonnet-5 bare 값"     "claude-sonnet-5${TAB}0.000002${TAB}0.00001${TAB}0.0000025${TAB}0.0000002" "$(get_row claude-sonnet-5)"
check "case1: haiku-4-5 bare 값"    "claude-haiku-4-5${TAB}0.000001${TAB}0.000005${TAB}0.00000125${TAB}0.0000001" "$(get_row claude-haiku-4-5)"

# ---------------------------------------------------------------------------
# 케이스 2: 폴백 — curl 실패(non-zero exit) + 기존 캐시 없음 → 내장 테이블 4줄.
# 실제 PATH 전체를 비우면 mkdir/awk 등 기본 유틸까지 못 찾으므로, curl 자리에
# 항상 실패하는 스텁을 놓아 "fetch 실패"를 재현한다(원본 PATH 는 그대로 유지).
# ---------------------------------------------------------------------------
CASE2="$TMPROOT/case2"
mkdir -p "$CASE2/cache" "$CASE2/bin"
export XDG_CACHE_HOME="$CASE2/cache"

cat > "$CASE2/bin/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$CASE2/bin/curl"

PATH="$CASE2/bin:$PATH" "$SCRIPT"

OUT2="$CASE2/cache/claude-statusline/prices.tsv"
check "case2: prices.tsv 존재(내장 폴백)" "1" "$([ -f "$OUT2" ] && echo 1 || echo 0)"
check "case2: 정확히 4줄"                "4" "$(wc -l < "$OUT2" | tr -d ' ')"
check "case2: fable-5 내장 값"           "claude-fable-5${TAB}0.00001${TAB}0.00005${TAB}0.0000125${TAB}0.000001" "$(awk -F"$TAB" '$1=="claude-fable-5"{print; exit}' "$OUT2")"
check "case2: opus-4-8 내장 값"          "claude-opus-4-8${TAB}0.000005${TAB}0.000025${TAB}0.00000625${TAB}0.0000005" "$(awk -F"$TAB" '$1=="claude-opus-4-8"{print; exit}' "$OUT2")"

printf 'prices.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
