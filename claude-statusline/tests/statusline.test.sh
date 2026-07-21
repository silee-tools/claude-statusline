#!/bin/sh
# statusline.sh 렌더링 회귀 테스트
# 격리된 임시 PLUGIN_ROOT 에서 실제 소스 statusline.sh 를 실행하고,
# stdin JSON(rate_limits·effort 포함/미포함)과 cost-cache fixture 로
# 폭 무관 단일 레이아웃(세로 스택) 출력을 검증한다.
#
# 레이아웃(위→아래, 값 없는 줄은 자연히 생략):
#   줄1  시간  경로
#   줄2  (브랜치) gh@계정 aws:세션
#   줄3  v<버전> <모델> <effort 램프> | ctx <컨텍스트 막대> %
#   줄4  5h   <막대> % ↺리셋 | 7d <막대> % ↺리셋
#   줄5  cost 24h ... | 7d ... | <당월일수>d ...
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
ESC=$(printf '\033')
RED=$(printf '\033[31m')
YELLOW=$(printf '\033[33m')
CYAN=$(printf '\033[36m')
DIMC=$(printf '\033[2m')
GREEN=$(printf '\033[32m')
LIME=$(printf '\033[38;5;148m')
AMBER=$(printf '\033[38;5;214m')

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/scripts" "$TMPROOT/cache/claude-statusline"
ln -sf "$SRC/scripts/statusline.sh" "$TMPROOT/scripts/statusline.sh"
ln -sf "$SRC/scripts/shorten.sh" "$TMPROOT/scripts/shorten.sh"
ln -sf "$SRC/scripts/json.awk" "$TMPROOT/scripts/json.awk"
SL="$TMPROOT/scripts/statusline.sh"

# gh 계정 fixture: 현재 계정명 캐시 + 계정→라벨 매핑 설정 파일. 실제 계정명 대신 테스트용
# handle(octocat)로 결정론화한다. format_gh 는 소스에 계정명을 박지 않고 이 매핑을 읽는다.
printf 'octocat' > "$TMPROOT/gh-prompt-user"
mkdir -p "$TMPROOT/claude-statusline"
printf 'octocat=personal,214\ntestwork=work,27\nbadcolor=weird,zz\n' > "$TMPROOT/claude-statusline/gh-accounts"

# 브랜치 fixture: 격리된 git repo 를 만들어 알려진 브랜치명(wip)을 갖게 한다.
# 브랜치가 둘째 줄로 내려갔는지 검증하려면 실제 git 컨텍스트가 필요하다.
GITREPO="$TMPROOT/repo"
# git 부재나 gpgsign 강제 같은 환경 문제로 fixture 생성이 실패해도 set -e 로 전체 suite 를
# 중단시키지 않는다. HAVE_GIT 플래그로 T18 만 조건 실행하고, 실패 원인은 stderr 로 남긴다.
HAVE_GIT=0
if command -v git >/dev/null 2>&1; then
  mkdir -p "$GITREPO"
  if ( cd "$GITREPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/wip \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init ); then
    HAVE_GIT=1
  else
    echo "warn: git fixture 생성 실패 — T18 을 건너뜁니다" >&2
  fi
else
  echo "warn: git 미설치 — T18 을 건너뜁니다" >&2
fi

# 비용 fixture: 오늘 Opus $12, 주간 $605, 월간 $605
cat > "$TMPROOT/cache/claude-statusline/cost-cache.env" <<'ENV'
available=true
dailyOpus=12
dailySonnet=0
dailyHaiku=0
weekly=605
monthly=605
cachedAt=1784000000
ENV
rm -f "$TMPROOT/cache/claude-statusline/cost-cache.json"

# bc 미존재 환경 테스트용: 고의로 실패하는 bc stub (정수부 비교로 bc 제거를 검증).
# PATH 에 이 디렉터리를 추가하면 진정한 bc 대신 실패 스텁이 호출되므로,
# 코드가 여전히 bc 를 쓰고 있으면 비용 세그먼트가 사라진다.
mkdir -p "$TMPROOT/nobc-bin"
cat > "$TMPROOT/nobc-bin/bc" <<'BCSTUB'
#!/bin/sh
exit 127
BCSTUB
chmod +x "$TMPROOT/nobc-bin/bc"

# 이번 달 총 일수 (라벨 기대값)
MDAYS=$(date -v1d -v+1m -v-1d +%d 2>/dev/null || date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)

NOW=$(date +%s)
FIVE_RESET=$((NOW + 9000))    # 2h30m 뒤
WEEK_RESET=$((NOW + 200000))  # 약 2d7h 뒤

# rate limit + effort 모두 포함 (cwd=/tmp → 브랜치 없음)
json_with() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$FIVE_RESET" "$WEEK_RESET"
}
# rate limit 없음, effort 없음
json_without() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11"}'
}
# rate limit 있음(90%+), effort 있음 — 빨강 경고 검증용
json_high() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":%s},"seven_day":{"used_percentage":92,"resets_at":%s}}}' "$FIVE_RESET" "$WEEK_RESET"
}
# rate limit 있음, effort 없음 — effort 미지원 모델 경로 검증용
json_no_effort() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$FIVE_RESET" "$WEEK_RESET"
}
# 지정한 5h/7d 소진율로 rate limit 색 임계를 검증한다.
json_pct() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$FIVE_RESET" "$2" "$WEEK_RESET"
}
# 브랜치 fixture repo 를 cwd 로 주는 변형 (브랜치 위치 검증용)
json_branch() {
  printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$GITREPO" "$FIVE_RESET" "$WEEK_RESET"
}
# input_tokens 로 ctx 소진율을 제어한다(window 200000 기준). ctx 막대 임계 색 검증용. rate 없음.
json_ctx() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11"}' "$1"
}
# 지정한 effort level 로 effort 램프 색·글리프를 검증한다. rate 없음(색 오염 방지), ctx 20%(무색).
json_eff() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"%s"}}' "$1"
}

# 색 코드 제거한 출력. XDG_DATA_HOME·XDG_CONFIG_HOME·XDG_CACHE_HOME 을 TMPROOT 로 고정해 gh 계정·매핑·비용 캐시를 결정론화한다.
run() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" COLUMNS="$2" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g"; }
# 색 코드 포함 원본 출력
run_raw() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" COLUMNS="$2" sh "$SL" 2>/dev/null; }

# 출력 끝에 개행이 없어 명령 치환이 후행 개행을 지우므로, 한 줄을 다시 붙여 세면 정확하다.
# 폭 불변성 비교(T5/T19)용. 두 렌더 사이 분 경계를 넘어도 흔들리지 않도록 시각(HH:MM)과
# rate 리셋 토큰(↺2h30m 등, 렌더 시점 date 로 계산돼 매 호출 달라짐)을 함께 마스킹한다.
mask_time() { printf '%s' "$1" | sed -e 's/[0-9][0-9]:[0-9][0-9]/HH:MM/' -e 's/↺[0-9dhm]*/↺RESET/g'; }
nlines()    { printf '%s\n' "$1" | wc -l | tr -d ' '; }
first_line(){ printf '%s\n' "$1" | sed -n '1p'; }
nth_line()  { printf '%s\n' "$2" | sed -n "${1}p"; }
count_char(){ printf '%s' "$2" | grep -o "$1" | wc -l | tr -d ' '; }

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }

assert_contains()     { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (expected to contain [$2])" "$3";; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1 (should NOT contain [$2])" "$3";; *) ok "$1";; esac; }
assert_match()        { if printf '%s' "$3" | grep -Eq "$2"; then ok "$1"; else bad "$1 (expected to match /$2/)" "$3"; fi; }
assert_no_match()     { if printf '%s' "$3" | grep -Eq "$2"; then bad "$1 (should NOT match /$2/)" "$3"; else ok "$1"; fi; }
assert_equals()       { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

# =====================================================================
# 폭은 렌더에 영향을 주지 않는다(단일 레이아웃). 폭 상수는 불변성 검증에만 쓴다.
# 넓음=200, 좁음=55.
# =====================================================================

# --- T1: rate_limits 있으면 5h/7d 라벨과 막대가 나온다 ---
OUT=$(run "$(json_with)" 200)
assert_contains "T1 5h 라벨 표시" "5h" "$OUT"
assert_contains "T1 7d 라벨 표시" "7d" "$OUT"
assert_contains "T1 막대 문자 표시" "█" "$OUT"
assert_match    "T1 5h 리셋 분 단위 표기" "↺[0-9]+h[0-9]+m" "$OUT"

# --- T2: rate_limits 없으면 rate 막대 줄이 없고, 비용은 남는다 ---
#    비용의 '7d $605' 라벨과 구분되도록 '막대를 동반한 rate' 부재로 검사한다.
OUT=$(run "$(json_without)" 200)
assert_no_match "T2 5h rate 세그먼트 부재" "5h +█" "$OUT"
assert_no_match "T2 7d rate 세그먼트 부재" "7d +█" "$OUT"
assert_contains "T2 24h 비용 라벨 유지" "24h" "$OUT"

# --- T3: 비용이 새 형태로 나온다: 24h Opus $12 | 7d $605 | 30d $605 ---
OUT=$(run "$(json_with)" 200)
assert_contains "T3 24h 접두" "24h Opus" "$OUT"
assert_match    "T3 주간 비용 7d 라벨" '7d \$605' "$OUT"
assert_match    "T3 당월 일수 라벨" "${MDAYS}"'d \$605' "$OUT"
assert_match    "T3 비용: 24h·7d 파이프, 7d·당월은 공백 구분" '\$12 +\| 7d \$605 '"${MDAYS}"'d \$605' "$OUT"

# --- T3-nobc: bc 없는 환경에서도 비용 세그먼트 유지(정수부 비교로 독립) ---
#    비용 세그먼트는 costv >= 1 판정이 필요하다. bc 가 없거나 실패해도 정수부 비교로 동작해야 한다.
#    opus=12 이므로 'Opus $12' 가 나타나야 하고, bc 대신 정수부 비교를 쓰고 있음을 증명한다.
OUT=$(PATH="$TMPROOT/nobc-bin:$PATH" run "$(json_with)" 200)
assert_contains "T3-nobc bc 미존재에도 비용 Opus 세그먼트 유지" "Opus" "$OUT"
assert_match    "T3-nobc 정수부 비교로 opus>=1 판정" 'Opus.*\$12' "$OUT"

# --- T4: 소진율 90% 이상이면 빨간색 경고 ---
RAW=$(run_raw "$(json_high)" 200)
assert_contains "T4 90%+ 빨간색 경고" "$RED" "$RAW"

# --- T5: 폭 불변성 — 넓음(200)과 좁음(55) 출력이 완전히 동일 ---
#    tier 사다리 제거의 핵심 회귀. 폭이 달라도 같은 레이아웃을 렌더한다.
A=$(run "$(json_with)" 200)
B=$(run "$(json_with)" 55)
assert_equals "T5 폭 200과 55 출력 동일" "$(mask_time "$A")" "$(mask_time "$B")"

# --- T7: 단일 레이아웃 줄 구성 (rate 있음, 브랜치 없음) = 5줄 ---
#    줄1 시간·경로 / 줄2 계정 / 줄3 model / 줄4 5h|7d / 줄5 cost.
#    cwd=/tmp 는 브랜치가 없어 줄2에 계정만 남는다.
OUT=$(run "$(json_with)" 200)
assert_equals   "T7 총 5줄(시간·계정·model·rate·cost)" "5" "$(nlines "$OUT")"
assert_match    "T7 ctx 라벨 줄(오른쪽)"  '\| ctx +█'  "$OUT"
assert_match    "T7 5h rate 존재" "5h +█"    "$OUT"
assert_match    "T7 7d rate 존재" "7d +█"    "$OUT"
assert_contains "T7 cost 줄 존재" "cost " "$OUT"

# --- T7-swap: 셋째 줄 좌우 교체 — 모델 그룹 왼쪽, ctx 오른쪽 ---
OUT=$(run "$(json_with)" 200)
LINE3=$(nth_line 3 "$OUT")
assert_match "T7-swap 모델 그룹 왼쪽, ctx 오른쪽" '^v2\.1\.11 Opus 4\.8.*\| ctx' "$LINE3"

# --- T8: 5h 와 7d 가 같은 한 줄에 파이프로 이어진다 ---
OUT=$(run "$(json_with)" 200)
RATE=$(printf '%s\n' "$OUT" | grep '5h')
assert_contains "T8 rate 한 줄에 7d 도 포함" "7d" "$RATE"
assert_match    "T8 rate 줄 5h|7d 파이프 구분" '5h +█.* \| 7d +█' "$OUT"
assert_equals   "T8 rate 는 단 한 줄" "1" "$(printf '%s\n' "$OUT" | grep -c '5h .*█')"

# --- T9: effort → 세로 램프 글리프 + 웜 게이지 색(low=초록 … max=빨강) ---
#    높이(글리프)와 색이 함께 단계를 표현한다. rate 없는 json_eff 로 색 오염을 막고 색을 글리프에 직접 묶어 검증.
OUT=$(run "$(json_eff high)" 200)
assert_contains "T9 effort high 램프 글리프(▃)" "▃" "$OUT"
RAW=$(run_raw "$(json_eff low)"    200); assert_contains "T9 low 초록 ▁"    "${GREEN}▁"  "$RAW"
RAW=$(run_raw "$(json_eff medium)" 200); assert_contains "T9 medium 연두 ▂" "${LIME}▂"   "$RAW"
RAW=$(run_raw "$(json_eff high)"   200); assert_contains "T9 high 노랑 ▃"   "${YELLOW}▃" "$RAW"
RAW=$(run_raw "$(json_eff xhigh)"  200); assert_contains "T9 xhigh 주황 ▅"  "${AMBER}▅"  "$RAW"
RAW=$(run_raw "$(json_eff max)"    200); assert_contains "T9 max 빨강 ▇"    "${RED}▇"    "$RAW"

# --- T10: effort 없으면 램프 없이 모델명만 (데이터 부재의 정당한 부재 단언) ---
OUT=$(run "$(json_no_effort)" 200)
assert_no_match "T10 effort 부재 시 램프 글리프 없음" "▁|▂|▃|▅|▇" "$OUT"
assert_contains "T10 모델명은 유지" "Opus 4.8" "$OUT"

# --- T11: 첫 줄은 시간·경로만 — 계정·브랜치는 첫 줄에 없다 ---
OUT=$(run "$(json_with)" 200)
FIRST=$(first_line "$OUT")
assert_equals   "T11 첫 줄 파이프 없음" "0" "$(count_char '|' "$FIRST")"
assert_not_contains "T11 첫 줄에 gh 계정 없음" "gh@" "$FIRST"
assert_contains "T11 둘째 줄에 gh 계정" "gh@personal" "$(nth_line 2 "$OUT")"

# --- T12: 비용 줄은 24h·7d 사이만 파이프, 7d·당월 사이 파이프 제거 ---
OUT=$(run "$(json_with)" 55)
COSTLN=$(printf '%s\n' "$OUT" | grep '^cost')
assert_match  "T12 cost 24h·7d 파이프" '^cost +24h .*\$.* \| 7d' "$COSTLN"
assert_equals "T12 cost 줄 파이프 정확히 1개" "1" "$(count_char '|' "$COSTLN")"

# --- T13: rate 부재 시 rate 줄 통째 생략 (폭 무관, 시간·계정·ctx·cost 4줄) ---
#    데이터가 없는 경우의 정당한 부재 단언(안전 게이트).
OUT=$(run "$(json_without)" 55)
assert_equals   "T13 rate 부재 시 4줄" "4" "$(nlines "$OUT")"
assert_no_match "T13 5h rate 줄 없음" "5h +█" "$OUT"
assert_no_match "T13 7d rate 줄 없음" "7d +█" "$OUT"
assert_contains "T13 cost 줄은 유지" "cost " "$OUT"

# --- T14: 버전 무손실 — 버전 표시 (폭 무관 동일) ---
OUT=$(run "$(json_with)" 55)
assert_contains "T14 버전 표시" "v2.1.11" "$OUT"

# --- T15: 리셋 무손실 — 5h·7d 리셋(↺) 둘 다 유지 ---
OUT=$(run "$(json_with)" 200)
assert_equals "T15 리셋 2개 유지" "2" "$(count_char '↺' "$OUT")"

# --- T16: 제거 안전 게이트 — 소스에 옛 화살표 글리프가 없다 (정적 검사) ---
if grep -q '╰─»' "$SRC/scripts/statusline.sh"; then
  bad "T16 옛 화살표 글리프 제거" "found ╰─» in statusline.sh"
else
  ok "T16 옛 화살표 글리프 제거"
fi

# --- T17: rate limit 색 임계 — 노랑 80%, 빨강 90% ---
#    다른 색 소스(aws:⏳ 노랑, aws:expired 빨강)는 이 환경에 없으므로 YELLOW/RED 존재가 rate 색을 가린다.
YELLOW=$(printf '\033[33m')
RAW=$(run_raw "$(json_pct 80 10)" 200)
assert_contains     "T17 80%면 노란색 경고" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct 75 10)" 200)
assert_not_contains "T17 75%면 노란색 없음(노랑 임계 미만)" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct 90 10)" 200)
assert_contains     "T17 90%면 빨간색 경고" "$RED" "$RAW"
RAW=$(run_raw "$(json_pct 85 10)" 200)
assert_not_contains "T17 85%면 빨강 없음(빨강 임계 미만)" "$RED" "$RAW"

# --- T18: 브랜치가 있으면 둘째 줄로 내려가고 첫 줄엔 없다 (git fixture 있을 때만) ---
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 200)
  FIRST=$(first_line "$OUT")
  SECOND=$(nth_line 2 "$OUT")
  assert_no_match  "T18 첫 줄에 브랜치 괄호 없음" '\(wip\)' "$FIRST"
  assert_match     "T18 둘째 줄에 브랜치 표시" '\(wip\)' "$SECOND"
  assert_contains  "T18 둘째 줄에 브랜치와 계정 공존" "gh@personal" "$SECOND"
  assert_equals    "T18 둘째 줄(브랜치·계정)은 정렬·파이프 없음" "0" "$(count_char '|' "$SECOND")"
else
  printf 'SKIP T18 (git fixture 미생성)\n'
fi

# --- T25: gh 라벨을 설정 파일에서 매핑 (소스에 계정명 하드코딩 없음) ---
#    매핑된 계정은 라벨로, 미매핑은 계정명 그대로, 빈 값은 gh@---. 색코드 비숫자는 기본색으로 폴백.
printf 'testwork' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains "T25 config 매핑 계정 → 라벨(gh@work)" "gh@work" "$(nth_line 2 "$OUT")"
printf 'nobody-xyz' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains "T25 미매핑 계정 → gh@<계정명>" "gh@nobody-xyz" "$(nth_line 2 "$OUT")"
printf '' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains "T25 계정명 비면 gh@---" "gh@---" "$(nth_line 2 "$OUT")"
printf 'badcolor' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains "T25 비숫자 색코드도 라벨은 렌더(가드)" "gh@weird" "$(nth_line 2 "$OUT")"
printf 'octocat' > "$TMPROOT/gh-prompt-user"   # 이후 테스트 위해 원복

# --- T19: model·5h·cost 첫 파이프가 같은 열에 정렬된다 ---
#    파이프 앞부분(패딩 포함)의 표시폭이 세 줄 모두 같아야 세로 정렬이 맞다.
#    model 줄은 v로 시작, 5h와 cost는 라벨으로 시작.
OUT=$(run "$(json_with)" 200)
MODELLN=$(printf '%s\n' "$OUT" | grep '^v')
H5LN=$(printf '%s\n' "$OUT" | grep '^5h')
COSTLN2=$(printf '%s\n' "$OUT" | grep '^cost')
pipe_col() { p="${1%%|*}"; printf '%s' "$p" | wc -m | tr -d ' '; }
MC=$(pipe_col "$MODELLN"); HC=$(pipe_col "$H5LN"); OC=$(pipe_col "$COSTLN2")
assert_equals "T19 model·5h 파이프 열 동일" "$HC" "$MC"
assert_equals "T19 cost·5h 파이프 열 동일" "$HC" "$OC"
# 폭이 달라도 정렬은 유지된다(정렬은 세그먼트 내용 기반, COLUMNS 무관).
OUTN=$(run "$(json_with)" 55)
assert_equals "T19 폭 55에서도 정렬 동일" "$(mask_time "$OUT")" "$(mask_time "$OUTN")"

# --- T20: 요소별 색 — 모델명 시안, 파이프·라벨 등 dim 유지 ---
RAW=$(run_raw "$(json_with)" 200)
assert_contains "T20 모델명 시안(36)" "$CYAN" "$RAW"
assert_contains "T20 파이프·라벨 등 dim 유지" "$DIMC" "$RAW"

# --- T21: 막대 20칸·5% 해상도(내림) (rate 막대로 검증) ---
#    24%→4칸(20%), 27%→5칸(25%). 25% 경계를 사이에 둬 칸 수가 갈린다.
#    10%단위(10칸)였다면 둘 다 2칸으로 같았다.
OUT=$(run "$(json_pct 24 10)" 200)
assert_match "T21 24% 4칸 채움(내림)" '5h +████░' "$OUT"
OUT=$(run "$(json_pct 27 10)" 200)
assert_match "T21 27% 5칸 채움(내림)" '5h +█████░' "$OUT"
A=$(run "$(json_pct 24 10)" 200); B=$(run "$(json_pct 27 10)" 200)
assert_equals "T21 5% 경계 넘는 24%·27% 막대 구분됨" "diff" "$([ "$A" != "$B" ] && echo diff || echo same)"

# --- T22: 막대 경계값(0%/100%)과 rate 승격 경로 커버리지 ---
#    render_bar 내림: 0%→채움 0칸, 100%→20칸 꽉. 회귀(round/ceil 로 바뀜)를 잡는다.
OUT=$(run "$(json_pct 0 100)" 200)
assert_match "T22 0% 5h 막대 빈칸 20개" '5h +░░░░░░░░░░░░░░░░░░░░' "$OUT"
assert_match "T22 100% 7d 막대 20칸 꽉" '7d ████████████████████' "$OUT"
# 5h 없이 7d 만 있으면 7d 를 왼쪽으로 승격하고 5h 라벨은 나타나지 않는다.
json_7d_only() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$WEEK_RESET"
}
OUT=$(run "$(json_7d_only)" 200)
assert_match    "T22 rate승격: 7d 막대 존재" '7d +█' "$OUT"
assert_no_match "T22 rate승격: 5h 라벨 없음" '5h' "$OUT"

# --- T23: ctx 막대 임계 색 — 40%+ 노랑, 70%+ 빨강, 미만은 색 없음(dim) ---
#    ctx 줄만 추출해 판정한다. json_ctx 는 rate 가 없어 노랑/빨강 소스가 ctx 막대뿐이다.
#    rate 막대의 80/90 과 별개인 ctx 전용 임계(40/70)를 고정한다.
ctx30=$(run_raw "$(json_ctx 60000)"  200 | grep 'ctx')   # 30% (<40)
ctx45=$(run_raw "$(json_ctx 90000)"  200 | grep 'ctx')   # 45% (40+)
ctx75=$(run_raw "$(json_ctx 150000)" 200 | grep 'ctx')   # 75% (70+)
assert_not_contains "T23 30% ctx 노랑 없음" "$YELLOW" "$ctx30"
assert_not_contains "T23 30% ctx 빨강 없음" "$RED" "$ctx30"
assert_contains     "T23 45% ctx 채움 노랑(40%+)" "$YELLOW" "$ctx45"
assert_not_contains "T23 45% ctx 빨강 없음(70% 미만)" "$RED" "$ctx45"
assert_contains     "T23 75% ctx 채움 빨강(70%+)" "$RED" "$ctx75"

# --- T24: ctx 막대 색상 방식 = rate 막대와 동일(채움·빈칸·% 같은 색). 임계는 ctx 40/70 유지 ---
#    45%(40+)면 채움뿐 아니라 빈칸(░)과 % 까지 노랑을 따라간다(예전엔 빈칸 항상 흐림·% 기본밝기).
ctx45r=$(run_raw "$(json_ctx 90000)" 200 | grep 'ctx')
assert_contains "T24 45% ctx 빈칸도 노랑(채움색 따라감)" "${YELLOW}░"   "$ctx45r"
assert_contains "T24 45% ctx % 도 노랑(채움색 따라감)"   "${YELLOW}45%" "$ctx45r"

# --- T6: HOME 경계는 문자열 접두사가 아니라 경로 구성요소로 판정한다 ---
OUT=$(HOME=/opt/a sh "$TMPROOT/scripts/shorten.sh" --plain path /opt/a)
assert_equals "T6 HOME 자체 축약" "~" "$OUT"

OUT=$(HOME=/opt/a sh "$TMPROOT/scripts/shorten.sh" --plain path /opt/a/project)
assert_equals "T6 HOME 하위 경로 축약" "~/project" "$OUT"

OUT=$(HOME=/opt/a sh "$TMPROOT/scripts/shorten.sh" --plain path /opt/abc/project)
assert_equals "T6 유사 접두사 경로 제외" "/opt/↪1/project" "$OUT"

OUT=$(HOME=/opt/a/ sh "$TMPROOT/scripts/shorten.sh" --plain path /opt/a/project)
assert_equals "T6 후행 슬래시 HOME 정규화" "~/project" "$OUT"

OUT=$(HOME=/ sh "$TMPROOT/scripts/shorten.sh" --plain path /)
assert_equals "T6 루트 HOME 자체 절대경로 유지" "/" "$OUT"

OUT=$(HOME=/ sh "$TMPROOT/scripts/shorten.sh" --plain path /child)
assert_equals "T6 루트 HOME 하위 절대경로 유지" "/child" "$OUT"

OUT=$(HOME=//// sh "$TMPROOT/scripts/shorten.sh" --plain path /child)
assert_equals "T6 정규화된 루트 HOME 절대경로 유지" "/child" "$OUT"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
