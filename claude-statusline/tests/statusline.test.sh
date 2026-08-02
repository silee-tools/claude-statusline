#!/bin/sh
# statusline.sh 렌더링 회귀 테스트
# 격리된 임시 PLUGIN_ROOT 에서 실제 소스 statusline.sh 를 실행하고,
# stdin JSON(rate_limits·effort 포함/미포함)과 cost-cache fixture 로
# 폭 무관 단일 레이아웃(세로 스택) 출력을 검증한다.
#
# 레이아웃(위→아래, 값 없는 줄은 자연히 생략):
#   줄1  시간 경로 브랜치
#   줄2  claude이메일 gh@계정 aws:세션
#   줄3   ctx <소진율>% <모델> <effort 글리프>
#   줄4   5h  <소진율>%[▲] ↺리셋   (페이스 초과 시 ▲)
#   줄5   7d  <소진율>%[▲] ↺리셋   (페이스 초과 시 ▲)
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
ln -sf "$SRC/scripts/fit-line1.awk" "$TMPROOT/scripts/fit-line1.awk"
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

# 색 코드를 뺀 표시 폭. 한글 등 두 칸 문자를 두 칸으로 센다(74칼럼 단언용).
vwidth_of() {
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

# --- T1: rate_limits 있으면 5h/7d 라벨과 소진율이 나온다 ---
OUT=$(run "$(json_with)" 200)
assert_match "T1 5h 소진율 표시" '5h [0-9]+%' "$OUT"
assert_match "T1 7d 소진율 표시" '7d [0-9]+%' "$OUT"
assert_match "T1 5h 리셋 분 단위 표기" "↺[0-9]+h[0-9]+m" "$OUT"

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
assert_match    "T7 ctx 게이지 줄"  'ctx [0-9]'  "$OUT"
assert_match    "T7 5h rate 존재" '5h [0-9]'    "$OUT"
assert_match    "T7 7d rate 존재" '7d [0-9]'    "$OUT"
assert_contains "T7 cost 줄 존재" "cost " "$OUT"

# --- T7-model: 모델·effort 는 ctx 줄 % 뒤에, 버전은 맨 아래 푸터 줄에 온다 ---
OUT=$(run "$(json_with)" 200)
CTXLN=$(printf '%s\n' "$OUT" | grep '^ctx ')
FOOT=$(printf '%s\n' "$OUT" | tail -1)
assert_match "T7-model ctx 줄 % 뒤 모델명" 'ctx .*% Opus 4\.8' "$CTXLN"
assert_match "T7-model 푸터 줄 버전" '^v2\.1\.11' "$FOOT"

# --- T33: 모델명 파싱이 sed 없이도 "이름 버전" 표기를 유지한다 ---
OUT=$(run "$(json_with)" 200)
assert_match "T33 모델 이름+버전 표기 유지" 'Opus 4\.8' "$OUT"

# --- T8: 5h 와 7d 가 각자 다른 줄에 온다(세로 스택, 파이프 없음) ---
OUT=$(run "$(json_with)" 200)
H5=$(printf '%s\n' "$OUT" | grep '5h [0-9]')
assert_equals       "T8 5h 게이지 줄 1개" "1" "$(printf '%s\n' "$OUT" | grep -c '5h [0-9]')"
assert_equals       "T8 7d 게이지 줄 1개" "1" "$(printf '%s\n' "$OUT" | grep -c '7d [0-9]')"
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
assert_no_match "T13 5h rate 줄 없음" '5h [0-9]' "$OUT"
assert_no_match "T13 7d rate 줄 없음" '7d [0-9]' "$OUT"
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

# --- T40: 첫 행은 74칼럼을 넘지 않는다(긴 경로·브랜치를 폭 기준으로 절단) ---
if [ "$HAVE_GIT" = "1" ]; then
  LONGREPO="$TMPROOT/deep/aa/bb/cc/dd/very-long-project-directory-name"
  mkdir -p "$LONGREPO"
  ( cd "$LONGREPO" \
    && git init -q \
    && git symbolic-ref HEAD refs/heads/feature/PROJ-1469-connect-api-secrets-long \
    && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
           commit -q --allow-empty -m init ) >/dev/null 2>&1
  OUT=$(HOME="$TMPROOT" run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$LONGREPO")" 200)
  W1=$(vwidth_of "$(first_line "$OUT")")
  assert_equals "T40 첫 행 74칼럼 이내" "yes" "$([ "$W1" -le 74 ] && echo yes || echo "no($W1)")"
  assert_contains "T40 잘린 자리에 줄임표" "…" "$(first_line "$OUT")"
else
  printf 'SKIP T40 (git fixture 미생성)\n'
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

# --- T20: 요소별 색 — 모델명 시안, 파이프·라벨 등 dim 유지 ---
RAW=$(run_raw "$(json_with)" 200)
assert_contains "T20 모델명 시안(36)" "$CYAN" "$RAW"
assert_contains "T20 파이프·라벨 등 dim 유지" "$DIMC" "$RAW"

# --- T21: 막대 문자를 쓰지 않는다(정적 검사) ---
if grep -q '█' "$SRC/scripts/statusline.sh"; then
  bad "T21 막대 문자 제거" "found █ in statusline.sh"
else
  ok "T21 막대 문자 제거"
fi

# --- T22: 소진율 경계값(0%/100%)이 숫자로 그대로 나온다 ---
OUT=$(run "$(json_pct_nr 0 100)" 200)
assert_match "T22 0% 표기" '5h 0%' "$OUT"
assert_match "T22 100% 표기" '7d 100%' "$OUT"

# --- T23: ctx 임계 색 — 40%+ 노랑, 70%+ 빨강, 미만은 색 없음 ---
ctx30=$(run_raw "$(json_ctx 60000)"  200 | grep 'ctx')
ctx45=$(run_raw "$(json_ctx 90000)"  200 | grep 'ctx')
ctx75=$(run_raw "$(json_ctx 150000)" 200 | grep 'ctx')
assert_not_contains "T23 30% ctx 노랑 없음" "$YELLOW" "$ctx30"
assert_not_contains "T23 30% ctx 빨강 없음" "$RED" "$ctx30"
assert_contains     "T23 45% ctx 노랑(40%+)" "$YELLOW" "$ctx45"
assert_not_contains "T23 45% ctx 빨강 없음(70% 미만)" "$RED" "$ctx45"
assert_contains     "T23 75% ctx 빨강(70%+)" "$RED" "$ctx75"

# --- T24: ctx 소진율 숫자에 임계 색이 붙는다 ---
ctx45r=$(run_raw "$(json_ctx 90000)" 200 | grep 'ctx')
assert_contains "T24 45% ctx 숫자 노랑" "${YELLOW}45%" "$ctx45r"

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

# --- T31: 페이스 초과를 ▲ 로 표시한다 ---
#    FIVE_RESET=now+9000, 5h(18000s) 윈도우 → 경과 9000s → 예산 10칸. fill 이 예산을 넘으면
#    ▲ 가 붙고, 넘지 않으면 붙지 않는다. 초과 3칸 이상이면 빨강, 그보다 적으면 노랑.
OUT=$(run "$(json_pct 70 10)" 200)
assert_contains     "T31 초과 시 ▲ 표시" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
OUT=$(run "$(json_pct 40 10)" 200)
assert_not_contains "T31 여유면 ▲ 없음" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
RAW=$(run_raw "$(json_pct 70 10)" 200 | grep '5h')
assert_contains     "T31 큰 초과 빨강 ▲" "${RED}▲" "$RAW"
RAW=$(run_raw "$(json_pct 55 10)" 200 | grep '5h')
assert_contains     "T31 작은 초과 노랑 ▲" "${YELLOW}▲" "$RAW"

# --- T34: git 브랜치 캐시 — 미스 때 git 호출, 히트 때 git 미호출 ---
if [ "$HAVE_GIT" -eq 1 ]; then
  CTALLY="$TMPROOT/git-calls"
  mkdir -p "$TMPROOT/fakebin"
  # 가짜 git: 호출을 기록하고 실제 git 으로 위임한다.
  REAL_GIT=$(command -v git)
  cat > "$TMPROOT/fakebin/git" <<FAKEGIT
#!/bin/sh
printf 'call\n' >> "$CTALLY"
exec "$REAL_GIT" "\$@"
FAKEGIT
  chmod +x "$TMPROOT/fakebin/git"

  rm -f "$CTALLY" "$TMPROOT/cache/claude-statusline/git-branch.env"
  # 브랜치 fixture 를 cwd 로 주는 JSON
  json_branch() {
    printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$GITREPO"
  }
  run_branch() {
    printf '%s' "$(json_branch)" | \
      PATH="$TMPROOT/fakebin:$PATH" CLAUDE_PLUGIN_ROOT="$TMPROOT" \
      XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" \
      XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
      sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g"
  }

  OUT1=$(run_branch)
  CALLS1=$(wc -l < "$CTALLY" 2>/dev/null | tr -d ' ')
  assert_contains "T34 캐시 미스 렌더에 브랜치 표시" "wip" "$OUT1"
  assert_match    "T34 캐시 미스면 git 을 호출" "^[1-9]" "$CALLS1"

  : > "$CTALLY"   # 호출 기록 초기화
  OUT2=$(run_branch)
  CALLS2=$(wc -l < "$CTALLY" 2>/dev/null | tr -d ' ')
  assert_contains "T34 캐시 히트 렌더에도 브랜치 표시" "wip" "$OUT2"
  assert_equals   "T34 캐시 히트면 git 미호출" "0" "$CALLS2"
else
  echo "warn: git 미설치 — T34 를 건너뜁니다" >&2
fi

# --- T37/T38/T39: git 브랜치 캐시가 "무손실"인 세 가지 위치 ---
#    naive 하게 .git/HEAD 를 직접 읽으면 아래 세 상태에서 브랜치를 잃는다.
#    (1) 저장소 하위 디렉터리 (2) git worktree(.git 이 파일) (3) detached HEAD.
#    git rev-parse --abbrev-ref HEAD 와 동일한 결과가 나와야 캐시가 안전하다.
if [ "$HAVE_GIT" -eq 1 ]; then
  # 렌더 직전 캐시를 비운다: 캐시 키가 cwd 이므로 다른 cwd 는 어차피 미스지만,
  # 상태 간 오염 가능성을 없애기 위해 명시적으로 지운다.
  render_at() {
    rm -f "$TMPROOT/cache/claude-statusline/git-branch.env"
    run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$1")" 200
  }

  # --- T37: 저장소 하위 디렉터리에서 렌더해도 브랜치가 표시된다 ---
  #    git 은 상위 디렉터리를 탐색해 .git 을 찾으므로, .git/HEAD 만 직접 읽는 구현은
  #    서브디렉터리에서 아무것도 찾지 못해 브랜치를 잃는다.
  mkdir -p "$GITREPO/sub/deep"
  OUT=$(render_at "$GITREPO/sub/deep")
  assert_contains "T37 저장소 하위 디렉터리에서도 브랜치 표시(wip)" "wip" "$OUT"

  # --- T38: git worktree(.git 이 디렉터리가 아니라 파일)에서도 브랜치가 표시된다 ---
  WTREPO="$TMPROOT/wtrepo"
  WTPATH="$TMPROOT/wtree-feat"
  mkdir -p "$WTREPO"
  if ( cd "$WTREPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/main \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init \
       && git worktree add -q "$WTPATH" -b feat ); then
    if [ -f "$WTPATH/.git" ]; then
      ok "T38 worktree 의 .git 이 파일(디렉터리 아님)"
    else
      bad "T38 worktree 의 .git 이 파일(디렉터리 아님)" "$(ls -la "$WTPATH/.git" 2>&1)"
    fi
    OUT=$(render_at "$WTPATH")
    assert_contains "T38 worktree 에서 브랜치 표시(feat)" "feat" "$OUT"
    git -C "$WTREPO" worktree remove --force "$WTPATH" >/dev/null 2>&1 || rm -rf "$WTPATH"
  else
    echo "warn: worktree fixture 생성 실패 — T38 을 건너뜁니다" >&2
  fi

  # --- T39: detached HEAD 에서는 브랜치가 렌더되지 않는다(정당한 부재) ---
  #    브랜치가 없는 상태이므로 첫 줄에 브랜치 글리프도, 원래 브랜치명도 나오면 안 된다.
  DETREPO="$TMPROOT/detrepo"
  mkdir -p "$DETREPO"
  if ( cd "$DETREPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/main \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init ); then
    SHA=$(git -C "$DETREPO" rev-parse HEAD)
    ( cd "$DETREPO" && git -c advice.detachedHead=false checkout -q "$SHA" )
    OUT=$(render_at "$DETREPO")
    FIRST=$(first_line "$OUT")
    assert_not_contains "T39 detached HEAD 첫 줄에 브랜치 글리프 없음" "$BRANCH_GLYPH" "$FIRST"
    assert_not_contains "T39 detached HEAD 첫 줄에 원래 브랜치명(main) 없음" "main" "$FIRST"
  else
    echo "warn: detached HEAD fixture 생성 실패 — T39 를 건너뜁니다" >&2
  fi
else
  echo "warn: git 미설치 — T37/T38/T39 를 건너뜁니다" >&2
fi

# --- T35: Claude 계정 이메일 캐시 ---
rm -f "$TMPROOT/cache/claude-statusline/cc-account.env"
OUT_A=$(run "$(json_with)" 200)
assert_contains "T35 이메일 첫 렌더 표시" "octocat@example.com" "$OUT_A"
assert_match    "T35 캐시 파일 생성" "email=octocat@example.com" "$(cat "$TMPROOT/cache/claude-statusline/cc-account.env" 2>/dev/null)"

# .claude.json 을 캐시보다 새 것으로 만들고 이메일을 바꾸면 다음 렌더에 반영된다(무손실).
sleep 1
printf '{"oauthAccount":{"emailAddress":"newuser@example.com"}}' > "$TMPROOT/.claude.json"
OUT_B=$(run "$(json_with)" 200)
assert_contains "T35 파일 변경 시 새 이메일 반영" "newuser@example.com" "$OUT_B"
# 원복
printf '{"oauthAccount":{"emailAddress":"octocat@example.com"}}' > "$TMPROOT/.claude.json"

# --- T36: AWS 만료 파싱 캐시 (파일 파싱 경로에서만 캐시) ---
if command -v saml2aws >/dev/null 2>&1; then
  rm -f "$TMPROOT/cache/claude-statusline/aws-exp.env"
  FUT=$(( $(date +%s) + 7200 ))
  CREDS="$TMPROOT/aws-credentials"
  printf '[default]\nx_security_token_expires = %s\n' \
    "$(date -r "$FUT" '+%Y-%m-%dT%H:%M:%S+0000' 2>/dev/null || date -d "@$FUT" '+%Y-%m-%dT%H:%M:%S+0000')" > "$CREDS"
  OUT=$(printf '%s' "$(json_with)" | \
    CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" \
    XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
    AWS_SHARED_CREDENTIALS_FILE="$CREDS" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g")
  assert_match "T36 파일 파싱 시 만료 epoch 캐시 생성" "exp_epoch=[0-9]+" "$(cat "$TMPROOT/cache/claude-statusline/aws-exp.env" 2>/dev/null)"
else
  echo "warn: saml2aws 미설치 — T36 을 건너뜁니다" >&2
fi

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
