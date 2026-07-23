#!/bin/sh
# statusline.sh 렌더링 회귀 테스트
# 격리된 임시 PLUGIN_ROOT 에서 실제 소스 statusline.sh 를 실행하고,
# stdin JSON(rate_limits·effort 포함/미포함)과 cost-cache fixture 로
# 폭 무관 단일 레이아웃(세로 스택) 출력을 검증한다.
#
# 레이아웃(위→아래, 값 없는 줄은 자연히 생략):
#   줄1  시간 경로 브랜치
#   줄2  claude이메일 gh@계정 aws:세션
#   줄3   ctx <컨텍스트 막대> % <모델> <effort 글리프>
#   줄4   5h  <막대> % ↺리셋   (초과분은 ▓ 로 강조)
#   줄5   7d  <막대> % ↺리셋   (초과분은 ▓ 로 강조)
#   줄6  cost 24h ... / 7d ... / <당월일수>d ...
#   줄7  v<버전> ⧉세션ID
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
MAGENTA=$(printf '\033[35m')

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/scripts" "$TMPROOT/cache/claude-statusline"
ln -sf "$SRC/scripts/statusline.sh" "$TMPROOT/scripts/statusline.sh"
ln -sf "$SRC/scripts/shorten.sh" "$TMPROOT/scripts/shorten.sh"
ln -sf "$SRC/scripts/shorten-lib.sh" "$TMPROOT/scripts/shorten-lib.sh"
ln -sf "$SRC/scripts/json.awk" "$TMPROOT/scripts/json.awk"
SL="$TMPROOT/scripts/statusline.sh"

# gh 계정 fixture: 현재 계정명 캐시 + 계정→라벨 매핑 설정 파일. 실제 계정명 대신 테스트용
# handle(octocat)로 결정론화한다. format_gh 는 소스에 계정명을 박지 않고 이 매핑을 읽는다.
printf 'octocat' > "$TMPROOT/gh-prompt-user"
mkdir -p "$TMPROOT/claude-statusline"
printf 'octocat=personal,214\ntestwork=work,27\nbadcolor=weird,zz\n' > "$TMPROOT/claude-statusline/gh-accounts"

# Claude Code 계정 fixture: 실제 ~/.claude.json 대신 CLAUDE_CONFIG_DIR 을 TMPROOT 로 지정하고
# 그 아래 가짜 .claude.json 을 둔다. statusline 은 oauthAccount.emailAddress 를 읽는다.
# RFC 2606 예약 도메인으로 실재 계정과 충돌을 막는다.
printf '{"oauthAccount":{"emailAddress":"octocat@example.com"}}' > "$TMPROOT/.claude.json"

# 세션 ID fixture: 알려진 UUID. 축약 없이 전체가 그대로 렌더되는지 검증한다.
KNOWN_SESSION="11111111-2222-3333-4444-555555555555"

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
# resets_at 없는 변형: 페이스(예산) 오버레이가 없어 순수 막대·절대 소진율 색만 검증할 때 쓴다.
# (resets_at 이 있으면 초과분 ▓ 강조가 얹혀 정확한 막대 문자열·색 임계 단언이 흔들린다.)
json_pct_nr() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":%s},"seven_day":{"used_percentage":%s}}}' "$1" "$2"
}
# 브랜치 fixture repo 를 cwd 로 주는 변형 (브랜치 위치·세션 ID 검증용). session_id 를 포함한다.
json_branch() {
  printf '{"session_id":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$KNOWN_SESSION" "$GITREPO" "$FIVE_RESET" "$WEEK_RESET"
}
# input_tokens 로 ctx 소진율을 제어한다(window 200000 기준). ctx 막대 임계 색 검증용. rate 없음.
json_ctx() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11"}' "$1"
}
# 지정한 effort level 로 effort 글리프 색·모양을 검증한다. rate 없음(색 오염 방지), ctx 20%(무색).
json_eff() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"%s"}}' "$1"
}

# 색 코드 제거한 출력. XDG_DATA_HOME·XDG_CONFIG_HOME·XDG_CACHE_HOME 을 TMPROOT 로 고정해 gh 계정·매핑·비용 캐시를 결정론화한다.
run() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" COLUMNS="$2" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g"; }
# 색 코드 포함 원본 출력
run_raw() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" COLUMNS="$2" sh "$SL" 2>/dev/null; }

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

# --- T3: 비용이 새 형태로 나온다: 24h Opus $12 / 7d $605 / 30d $605 (흐린 슬래시 구분) ---
OUT=$(run "$(json_with)" 200)
assert_contains "T3 24h 접두" "24h Opus" "$OUT"
assert_match    "T3 주간 비용 7d 라벨" '7d \$605' "$OUT"
assert_match    "T3 당월 일수 라벨" "${MDAYS}"'d \$605' "$OUT"
assert_match    "T3 비용: 24h/7d/당월 슬래시 구분" '\$12 +/ +7d \$605 +/ +'"${MDAYS}"'d \$605' "$OUT"

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

# --- T7: 단일 세로 스택 줄 구성 (rate 있음, 브랜치·세션 없음) = 7줄 ---
#    줄1 시간·경로 / 줄2 계정 / 줄3 ctx+모델 / 줄4 5h / 줄5 7d / 줄6 cost / 줄7 푸터(버전).
#    cwd=/tmp 는 브랜치가 없어 줄1은 시간·경로만, 줄2엔 계정만 남는다.
OUT=$(run "$(json_with)" 200)
assert_equals   "T7 총 7줄(시간·계정·ctx·5h·7d·cost·푸터)" "7" "$(nlines "$OUT")"
assert_match    "T7 ctx 게이지 줄"  'ctx +█'  "$OUT"
assert_match    "T7 5h rate 존재" "5h +█"    "$OUT"
assert_match    "T7 7d rate 존재" "7d +█"    "$OUT"
assert_contains "T7 cost 줄 존재" "cost " "$OUT"

# --- T7-model: 모델·effort 는 ctx 줄 % 뒤에, 버전은 맨 아래 푸터 줄에 온다 ---
OUT=$(run "$(json_with)" 200)
CTXLN=$(printf '%s\n' "$OUT" | grep ' ctx ')
FOOT=$(printf '%s\n' "$OUT" | tail -1)
assert_match "T7-model ctx 줄 % 뒤 모델명" 'ctx .*% Opus 4\.8' "$CTXLN"
assert_match "T7-model 푸터 줄 버전" '^v2\.1\.11' "$FOOT"

# --- T33: 모델명 파싱이 sed 없이도 "이름 버전" 표기를 유지한다 ---
OUT=$(run "$(json_with)" 200)
assert_match "T33 모델 이름+버전 표기 유지" 'Opus 4\.8' "$OUT"

# --- T8: 5h 와 7d 가 각자 다른 줄에 온다(세로 스택, 파이프 없음) ---
OUT=$(run "$(json_with)" 200)
H5=$(printf '%s\n' "$OUT" | grep '5h .*█')
assert_equals       "T8 5h 게이지 줄 1개" "1" "$(printf '%s\n' "$OUT" | grep -c '5h .*█')"
assert_equals       "T8 7d 게이지 줄 1개" "1" "$(printf '%s\n' "$OUT" | grep -c '7d .*█')"
assert_not_contains "T8 5h 줄에 7d 없음(각자 줄)" "7d" "$H5"
assert_equals       "T8 5h 줄 파이프 없음" "0" "$(count_char '|' "$H5")"

# --- T9: effort → Claude Code 원형 글리프 + 웜 게이지 색(low=초록 … max=빨강, ultracode=마젠타) ---
#    글리프 모양과 색이 함께 단계를 표현한다. rate 없는 json_eff 로 색 오염을 막고 색을 글리프에 직접 묶어 검증.
OUT=$(run "$(json_eff high)" 200)
assert_contains "T9 effort high 글리프(●)" "●" "$OUT"
RAW=$(run_raw "$(json_eff low)"       200); assert_contains "T9 low 초록 ○"        "${GREEN}○"    "$RAW"
RAW=$(run_raw "$(json_eff medium)"    200); assert_contains "T9 medium 연두 ◐"     "${LIME}◐"     "$RAW"
RAW=$(run_raw "$(json_eff high)"      200); assert_contains "T9 high 노랑 ●"       "${YELLOW}●"   "$RAW"
RAW=$(run_raw "$(json_eff xhigh)"     200); assert_contains "T9 xhigh 주황 ◉"      "${AMBER}◉"    "$RAW"
RAW=$(run_raw "$(json_eff max)"       200); assert_contains "T9 max 빨강 ◈"        "${RED}◈"      "$RAW"
RAW=$(run_raw "$(json_eff ultracode)" 200); assert_contains "T9 ultracode 마젠타 ✦" "${MAGENTA}✦" "$RAW"

# --- T10: effort 없으면 글리프 없이 모델명만 (데이터 부재의 정당한 부재 단언) ---
OUT=$(run "$(json_no_effort)" 200)
assert_no_match "T10 effort 부재 시 글리프 없음" "○|◐|●|◉|◈|✦" "$OUT"
assert_contains "T10 모델명은 유지" "Opus 4.8" "$OUT"

# --- T11: 첫 줄은 시간·경로만 — 계정·브랜치는 첫 줄에 없다 ---
OUT=$(run "$(json_with)" 200)
FIRST=$(first_line "$OUT")
assert_equals   "T11 첫 줄 파이프 없음" "0" "$(count_char '|' "$FIRST")"
assert_not_contains "T11 첫 줄에 gh 계정 없음" "gh@" "$FIRST"
assert_contains "T11 둘째 줄에 gh 계정" "gh@personal" "$(nth_line 2 "$OUT")"

# --- T12: 비용 줄은 24h/7d/당월을 흐린 슬래시로 구분(파이프 없음) ---
OUT=$(run "$(json_with)" 55)
COSTLN=$(printf '%s\n' "$OUT" | grep 'cost ')
assert_match  "T12 cost 24h/7d 슬래시" '^cost +24h .*\$.* +/ +7d' "$COSTLN"
assert_equals "T12 cost 줄 파이프 없음" "0" "$(count_char '|' "$COSTLN")"
assert_equals "T12 cost 줄 슬래시 정확히 2개" "2" "$(count_char '/' "$COSTLN")"

# --- T13: rate 부재 시 rate 줄(5h·7d) 통째 생략 (시간·계정·ctx+모델·cost·푸터 5줄) ---
#    데이터가 없는 경우의 정당한 부재 단언(안전 게이트).
OUT=$(run "$(json_without)" 55)
assert_equals   "T13 rate 부재 시 5줄" "5" "$(nlines "$OUT")"
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

# --- T17: 절대 소진율 색 임계 — 노랑 80%, 빨강 90% (페이스 오버레이 없는 fixture 로 격리) ---
#    다른 색 소스(aws:⏳ 노랑, aws:expired 빨강)는 이 환경에 없으므로 YELLOW/RED 존재가 절대색을 가린다.
#    json_pct_nr 로 reset 을 빼 초과분 ▓ 강조가 색 판정에 섞이지 않게 한다.
YELLOW=$(printf '\033[33m')
RAW=$(run_raw "$(json_pct_nr 80 10)" 200)
assert_contains     "T17 80%면 노란색 경고" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct_nr 75 10)" 200)
assert_not_contains "T17 75%면 노란색 없음(노랑 임계 미만)" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct_nr 90 10)" 200)
assert_contains     "T17 90%면 빨간색 경고" "$RED" "$RAW"
RAW=$(run_raw "$(json_pct_nr 85 10)" 200)
assert_not_contains "T17 85%면 빨강 없음(빨강 임계 미만)" "$RED" "$RAW"

# --- T18: 브랜치가 있으면 첫 줄(경로 옆)에 온다. 괄호 대신 브랜치 아이콘( ) 접두(사이 공백 없음) ---
BRANCH_GLYPH=$(printf '\356\202\240')   #  U+E0A0 (Powerline git branch)
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 200)
  FIRST=$(first_line "$OUT")
  SECOND=$(nth_line 2 "$OUT")
  assert_contains     "T18 첫 줄에 브랜치 아이콘+이름(사이 공백 없음)" "${BRANCH_GLYPH}wip" "$FIRST"
  assert_not_contains "T18 둘째 줄에 브랜치명 없음" "wip" "$SECOND"
  assert_contains     "T18 둘째 줄에 계정" "gh@personal" "$SECOND"
  assert_equals       "T18 첫 줄 파이프 없음" "0" "$(count_char '|' "$FIRST")"
else
  printf 'SKIP T18 (git fixture 미생성)\n'
fi

# --- T26: Claude Code 계정 이메일이 둘째 줄에 나온다 (.claude.json 의 oauthAccount.emailAddress) ---
#    라벨 접두 없이 이메일 그대로, coral(173) 색으로 렌더한다. cwd=/tmp 라 브랜치 없이 계정만 있는 줄2.
OUT=$(run "$(json_without)" 200)
assert_contains "T26 둘째 줄에 Claude 계정 이메일" "octocat@example.com" "$(nth_line 2 "$OUT")"
assert_not_contains "T26 이메일 앞 cc: 접두 없음" "cc:octocat" "$OUT"
CORAL=$(printf '\033[38;5;173m')
RAW=$(run_raw "$(json_without)" 200)
assert_contains "T26 계정 이메일 coral(173) 색" "${CORAL}octocat@example.com" "$RAW"

# --- T27: 세션 ID(전체 UUID)가 맨 아래 푸터 줄의 ⧉ 뒤에 축약 없이 나온다 ---
#    브랜치 fixture 는 session_id 를 포함한다. 부재 fixture(json_without)에는 ⧉ 가 없다.
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 200)
  assert_contains "T27 푸터 줄에 세션 ID 마커+전체 UUID" "⧉ ${KNOWN_SESSION}" "$(printf '%s\n' "$OUT" | tail -1)"
  assert_not_contains "T27 첫 줄엔 세션 ID 없음" "⧉" "$(first_line "$OUT")"
else
  printf 'SKIP T27 (git fixture 미생성)\n'
fi
OUT=$(run "$(json_without)" 200)
assert_not_contains "T27 session_id 부재 시 ⧉ 없음" "⧉" "$OUT"

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

# --- T19: 게이지(ctx·5h·7d)와 cost 값이 같은 열에서 시작한다(라벨 폭4 우측정렬) ---
#    라벨(ctx/5h/7d/cost)을 폭4에 우측정렬해 뒤따르는 값(막대·24h)이 세로로 한 열에 선다.
OUT=$(run "$(json_with)" 200)
CTXLN=$(printf '%s\n' "$OUT" | grep ' ctx ')
H5LN=$(printf '%s\n' "$OUT" | grep ' 5h ')
D7LN=$(printf '%s\n' "$OUT" | grep ' 7d ')
COSTLN3=$(printf '%s\n' "$OUT" | grep 'cost ')
bar_col() { p="${1%%█*}"; printf '%s' "$p" | wc -m | tr -d ' '; }
lbl_col() { p="${1%%24h*}"; printf '%s' "$p" | wc -m | tr -d ' '; }
CC=$(bar_col "$CTXLN"); HC=$(bar_col "$H5LN"); DC=$(bar_col "$D7LN"); OC=$(lbl_col "$COSTLN3")
assert_equals "T19 ctx·5h 막대 시작 열 동일" "$CC" "$HC"
assert_equals "T19 ctx·7d 막대 시작 열 동일" "$CC" "$DC"
assert_equals "T19 ctx 막대·cost 값 시작 열 동일" "$CC" "$OC"
# 폭이 달라도 정렬은 유지된다(정렬은 세그먼트 내용 기반, COLUMNS 무관).
OUTN=$(run "$(json_with)" 55)
assert_equals "T19 폭 55에서도 정렬 동일" "$(mask_time "$OUT")" "$(mask_time "$OUTN")"

# --- T28: 왼쪽 라벨 폭4 우측 정렬 — ctx/5h/7d 는 앞 공백, cost 는 flush(폭4 꽉) ---
OUT=$(run "$(json_with)" 200)
assert_match "T28 ctx 우측정렬(앞 공백1)"  '^ ctx █'   "$(printf '%s\n' "$OUT" | grep ' ctx ')"
assert_match "T28 5h 우측정렬(앞 공백2)"   '^  5h █'    "$(printf '%s\n' "$OUT" | grep ' 5h ')"
assert_match "T28 7d 우측정렬(앞 공백2)"   '^  7d █'    "$(printf '%s\n' "$OUT" | grep ' 7d ')"
assert_match "T28 cost flush(줄 시작)"     '^cost 24h'  "$(printf '%s\n' "$OUT" | grep 'cost ')"

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
# reset 없는 fixture 로 페이스 초과분 ▓ 강조 없이 순수 render_bar 경계값을 본다.
OUT=$(run "$(json_pct_nr 0 100)" 200)
assert_match "T22 0% 5h 막대 빈칸 20개" '5h +░░░░░░░░░░░░░░░░░░░░' "$OUT"
assert_match "T22 100% 7d 막대 20칸 꽉" '7d ████████████████████' "$OUT"
# 5h 없이 7d 만 있으면 7d 는 자기 줄에 그대로 나오고 5h 줄은 생략된다(세로 스택).
json_7d_only() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$WEEK_RESET"
}
OUT=$(run "$(json_7d_only)" 200)
assert_match    "T22 7d 게이지 줄 존재" '7d +█' "$OUT"
assert_no_match "T22 5h 라벨 없음(데이터 부재)" '5h' "$OUT"

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

# --- T30: git 저장소 판정은 basename 이 아니라 전체 경로로 한다(동명 비저장소 오탐 방지) ---
#    실제 저장소 foo(.git 있음) 아래에 .git 없는 동명 디렉터리 foo 를 두고, 안쪽 foo 가
#    저장소로 오인돼 파랗게 표시되지 않는지 검증한다. worktree 컨테이너가 저장소명과 겹치는
#    실제 상황의 회귀 가드다.
COLLIDE="$TMPROOT/collide"
mkdir -p "$COLLIDE/foo/sub/foo/bar"
mkdir -p "$COLLIDE/foo/.git"   # 바깥 foo 만 저장소
OUT=$(HOME="$TMPROOT" sh "$TMPROOT/scripts/shorten.sh" --plain path "$COLLIDE/foo/sub/foo/bar")
assert_equals "T30 동명 비저장소 오탐 없음(전체 경로 매칭)" "~/↪1/foo/↪2/bar" "$OUT"

# --- T32: 슬래시 없는 세그먼트에서 상위탐색이 무한 루프에 빠지지 않는다 ---
#   dirname 을 ${var%/*} 로 바꾸면 슬래시 없는 문자열이 안 줄어 무한 루프가 될 수 있다.
#   상대경로(선행 슬래시 없음)로 호출해 정상 종료와 출력 존재를 확인한다.
OUT=$(HOME=/nonexistent-home sh "$TMPROOT/scripts/shorten.sh" --plain path "aaa/bbb/ccc/ddd/eee")
assert_contains "T32 슬래시 없는 선행 세그먼트 정상 종료" "eee" "$OUT"

# --- T31: rate 막대 페이스(예산) 초과분 강조 — 시간 대비 빨리 쓴 채움 칸을 ▓ 로 표시 ---
#    FIVE_RESET=now+9000, 5h(18000s) 윈도우 → 경과 9000s → 예산 10칸. 5h fill 이 10칸을 넘으면
#    초과분이 ▓ 로 뜨고, 넘지 않으면 표시되지 않는다. 초과 폭이 크면(≥3칸) 빨강, 작으면 노랑.
OUT=$(run "$(json_pct 70 10)" 200)                 # 5h fill14 > 예산10 → 초과 4칸
assert_contains     "T31 초과분 ▓ 표시" "▓" "$(printf '%s\n' "$OUT" | grep '5h')"
OUT=$(run "$(json_pct 40 10)" 200)                 # 5h fill8 < 예산10 → 초과 없음
assert_not_contains "T31 여유면 ▓ 없음" "▓" "$(printf '%s\n' "$OUT" | grep '5h')"
RAW=$(run_raw "$(json_pct 70 10)" 200 | grep '5h')  # 초과 4칸(≥3) → 빨강 ▓
assert_contains     "T31 큰 초과분 빨강 ▓" "${RED}▓" "$RAW"
RAW=$(run_raw "$(json_pct 55 10)" 200 | grep '5h')  # fill11, 초과 1칸(<3) → 노랑 ▓
assert_contains     "T31 작은 초과분 노랑 ▓" "${YELLOW}▓" "$RAW"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
