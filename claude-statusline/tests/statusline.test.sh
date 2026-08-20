#!/bin/sh
# statusline.sh 렌더링 회귀 테스트
# 격리된 임시 PLUGIN_ROOT 에서 실제 소스 statusline.sh 를 실행하고,
# stdin JSON(rate_limits·effort 포함/미포함) fixture 로
# 80열 이하 3행과 81열 이상 7행 레이아웃 출력을 함께 검증한다.
#
# 레이아웃(위→아래, 값 없는 항목은 자연히 생략):
#   행1  시간 경로 브랜치
#   행2  claude이메일 gh@계정 aws:세션 v<버전> ⧉세션ID앞6자
#   행3  ctx <소진율>% <모델> <effort 글리프> 5h <소진율>%[▲] ↺리셋 7d <소진율>%[▲] ↺리셋
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
ESC=$(printf '\033')
RESET=$(printf '\033[0m')
RED=$(printf '\033[31m')
YELLOW=$(printf '\033[33m')
CYAN=$(printf '\033[36m')
DIMC=$(printf '\033[2m')
GREY=$(printf '\033[38;5;240m')
GREEN=$(printf '\033[32m')
LIME=$(printf '\033[38;5;148m')
AMBER=$(printf '\033[38;5;214m')
MAGENTA=$(printf '\033[35m')

TMPROOT=$(mktemp -d)
# bash 3.2 는 EXIT 트랩 진입에서 $? 를 0 으로 만든다. completed 플래그가 없으면 set -eu 중단이
# 종료코드 0 으로 보고된다. 정본은 AGENTS.md 의 Testing 절이다.
completed=0
trap 'rc=$?; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT
mkdir -p "$TMPROOT/scripts" "$TMPROOT/cache/claude-statusline"
ln -sf "$SRC/scripts/statusline.sh" "$TMPROOT/scripts/statusline.sh"
ln -sf "$SRC/scripts/shorten.sh" "$TMPROOT/scripts/shorten.sh"
ln -sf "$SRC/scripts/shorten-lib.sh" "$TMPROOT/scripts/shorten-lib.sh"
SL="$TMPROOT/scripts/statusline.sh"

# 렌더 본체는 Go 바이너리다. statusline.sh 는 XDG_CACHE_HOME 아래 포인터가 가리키는 그
# 바이너리로 exec 하는 shim 이므로, 스위트가 먼저 한 번 빌드해 포인터를 심는다.
# 빌드 실패를 건너뛰면 shim 이 저하 표시를 내고 이후 단언이 통째로 실패하거나, 더 나쁘게는
# 검사 0건이 통과로 읽힌다. 그래서 여기서 즉시 스위트를 실패시킨다.
BINARY="$TMPROOT/statusline-binary"
if ! command -v go >/dev/null 2>&1; then
  echo "FATAL: go 를 찾지 못해 렌더 바이너리를 빌드할 수 없습니다" >&2
  exit 1
fi
if ! ( cd "$SRC" && GOPROXY=off go build -o "$BINARY" ./cmd/statusline ) >&2; then
  echo "FATAL: 렌더 바이너리 빌드 실패" >&2
  exit 1
fi
printf '%s\n' "$BINARY" > "$TMPROOT/cache/claude-statusline/binary-path"

# gh 계정 fixture: 현재 계정명 캐시 + 계정→라벨 매핑 설정 파일. 실제 계정명 대신 테스트용
# handle(octocat)로 결정론화한다. format_gh 는 소스에 계정명을 박지 않고 이 매핑을 읽는다.
printf 'octocat' > "$TMPROOT/gh-prompt-user"
mkdir -p "$TMPROOT/claude-statusline"
printf 'octocat=personal,214\ntestwork=work,27\nbadcolor=weird,zz\n' > "$TMPROOT/claude-statusline/gh-accounts"

# Claude Code 계정 fixture: 실제 ~/.claude.json 대신 CLAUDE_CONFIG_DIR 을 TMPROOT 로 지정하고
# 그 아래 가짜 .claude.json 을 둔다. statusline 은 oauthAccount.emailAddress 를 읽는다.
# RFC 2606 예약 도메인으로 실재 계정과 충돌을 막는다.
printf '{"oauthAccount":{"emailAddress":"octocat@example.com"}}' > "$TMPROOT/.claude.json"

# AWS 세션 fixture: format_aws 가 개발자의 실제 ~/.aws/credentials 를 읽지 않도록 먼 미래의
# 만료 시각만 담은 자격증명 파일을 만든다. 진짜 액세스 키·시크릿 같은 키 자료는 없고, 파서가
# 읽는 x_security_token_expires 필드만 담는다. saml2aws 가 설치돼 있으면 이 fixture 가
# aws:✓ 를 결정론적으로 렌더하고, saml2aws 가 없으면 format_aws 는 이 파일을 열어보지도
# 않고 즉시 빈 문자열을 반환하므로(첫 줄의 command -v 가드) 두 환경 모두에서 suite 가
# 통과한다. 파일명을 T36 전용 fixture($TMPROOT/aws-credentials)와 다르게 둬, 공유 캐시
# ($CACHE_DIR/aws-exp.env)가 mtime 비교로 서로의 파싱 결과를 잘못 재사용하지 않게 한다.
# date 포맷팅은 -u 로 UTC 값을 찍는다 — 로컬 시각을 찍고 +0000 라벨만 붙이면(로컬 타임존이
# UTC 가 아닐 때) format_aws 가 파싱한 epoch 가 로컬 UTC 오프셋만큼 어긋난다.
AWS_FIXTURE_EXP=$(( $(date +%s) + 315360000 ))  # ~10년 뒤
AWS_CREDS_FIXTURE="$TMPROOT/aws-credentials-fixture"
printf '[default]\nx_security_token_expires = %s\n' \
  "$(date -u -r "$AWS_FIXTURE_EXP" '+%Y-%m-%dT%H:%M:%S+0000' 2>/dev/null || date -u -d "@$AWS_FIXTURE_EXP" '+%Y-%m-%dT%H:%M:%S+0000')" \
  > "$AWS_CREDS_FIXTURE"

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
# (resets_at 이 있으면 예산 초과 구간의 색이 얹혀 정확한 막대 문자열·색 임계 단언이 흔들린다.)
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

# 세션 공유 5h·7d 캐시. 렌더가 이 파일에 쓰므로 케이스마다 지워 앞 케이스의 값이 뒤로 새지
# 않게 한다. 캐시 디렉터리 전체를 지우면 같은 곳에 사는 binary-path 포인터까지 날아가 shim 이
# 저하 표시를 내므로 이 파일 하나만 지운다.
RATE_CACHE="$TMPROOT/cache/claude-statusline/rate-limits.env"
seed_rate_cache() { printf 'fivePct=%s\nfiveReset=%s\nweekPct=%s\nweekReset=%s\n' "$1" "$2" "$3" "$4" > "$RATE_CACHE"; }

# 색 코드 제거한 출력. XDG_DATA_HOME·XDG_CONFIG_HOME·XDG_CACHE_HOME 을 TMPROOT 로, AWS_SHARED_CREDENTIALS_FILE
# 을 위 fixture 로 고정해 gh 계정·매핑·비용 캐시·AWS 세션 표시를 모두 결정론화한다.
_render() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" AWS_SHARED_CREDENTIALS_FILE="$AWS_CREDS_FIXTURE" CLAUDE_STATUSLINE_WIDTH="$2" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g"; }
# 색 코드 포함 원본 출력
_render_raw() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" AWS_SHARED_CREDENTIALS_FILE="$AWS_CREDS_FIXTURE" CLAUDE_STATUSLINE_WIDTH="$2" sh "$SL" 2>/dev/null; }
# 폭 주입을 비우고 tty 장치 디렉터리를 존재하지 않는 곳으로 고정해 판정 불가 경로를 만든다.
_render_auto() {
  (
    unset CLAUDE_STATUSLINE_WIDTH
    printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" \
      XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
      AWS_SHARED_CREDENTIALS_FILE="$AWS_CREDS_FIXTURE" \
      CLAUDE_STATUSLINE_TTY_DIR="$TMPROOT/missing-dev" COLUMNS=40 sh "$SL" 2>/dev/null \
      | sed "s/${ESC}\[[0-9;]*m//g"
  )
}

# 기본 렌더는 공유 캐시를 지우고 시작한다. seed_rate_cache 로 심은 값을 그대로 쓰는 케이스만
# run_keep 을 부른다. `KEEP=1 run ...` 처럼 호출 앞에 변수를 붙이는 형태는 쓰지 않는다 — 그
# 할당이 호출 뒤에도 남는지를 POSIX 가 정하지 않아 macOS 의 /bin/sh 에서는 남고 dash 에서는
# 남지 않으며, 남는 쪽에서는 이후 모든 렌더가 격리를 잃은 채 스위트가 통과한다.
run()      { rm -f "$RATE_CACHE"; _render "$@"; }
run_raw()  { rm -f "$RATE_CACHE"; _render_raw "$@"; }
run_auto() { rm -f "$RATE_CACHE"; _render_auto "$@"; }
run_keep() { _render "$@"; }

# 출력 끝에 개행이 없어 명령 치환이 후행 개행을 지우므로, 한 줄을 다시 붙여 세면 정확하다.
# 폭 불변성 비교(T5)용. 두 렌더 사이 분 경계를 넘어도 흔들리지 않도록 시각(HH:MM)과
# rate 리셋 토큰(↺2h30m 등, 렌더 시점 date 로 계산돼 매 호출 달라짐)을 함께 마스킹한다.
mask_time() { printf '%s' "$1" | sed -e 's/[0-9][0-9]:[0-9][0-9]/HH:MM/' -e 's/↺[0-9dhm]*/↺RESET/g'; }
nlines()    { printf '%s\n' "$1" | wc -l | tr -d ' '; }
first_line(){ printf '%s\n' "$1" | sed -n '1p'; }
nth_line()  { printf '%s\n' "$2" | sed -n "${1}p"; }
count_char(){ printf '%s' "$2" | grep -o "$1" | wc -l | tr -d ' '; }
count_str() { printf '%s' "$2" | grep -oF "$1" | wc -l | tr -d ' '; }

# 문자열(색 코드 제거 후)이 완전한 UTF-8 시퀀스로만 이뤄져 있는지 검증한다. 잘린 다중바이트
# 문자(선행 바이트만 남거나 연속 바이트가 모자란 경우)가 있으면 "bad", 없으면 "ok".
# 첫 행 절단이 두 칸 문자를 반으로 쪼개지 않는지를 실제 렌더 결과로 확인할 때 쓴다.
utf8_intact() {
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g" | LC_ALL=C awk '
    {
      n = length($0); i = 1; ok = 1
      while (i <= n) {
        c = substr($0, i, 1)
        if (c < "\200")                    { L = 1 }
        else if (c >= "\300" && c < "\340") { L = 2 }
        else if (c >= "\340" && c < "\360") { L = 3 }
        else if (c >= "\360" && c < "\370") { L = 4 }
        else                                { ok = 0; break }
        if (i + L - 1 > n) { ok = 0; break }
        j = 1
        while (j < L) {
          cc = substr($0, i + j, 1)
          if (cc < "\200" || cc >= "\300") { ok = 0; break }
          j++
        }
        if (!ok) break
        i += L
      }
      print (ok ? "ok" : "bad")
    }'
}

# 색 코드를 뺀 표시 폭. 한글 등 두 칸 문자를 두 칸으로 센다(감지 폭 단언용).
# 구현(internal/width 의 wideRanges)이 다루는 8개 범위 중 이 스위트의 픽스처가 실제로 쓰는
# 3개(한글 자모·CJK·한글 음절)만 옮겼다. 의도적인 부분 오라클이다 — 구현에서 그대로 가져와
# 쓰지 않고 독립적으로 유지하기 위해서다. 완전한 폭 분류기로 오인하지 않는다.
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
# 폭 80 이하는 압축 레이아웃, 81 이상은 전체 레이아웃을 렌더한다.
# =====================================================================

# --- T46: 경계값에서 레이아웃이 갈리고 전체 레이아웃에만 비용이 나온다 ---
OUT80=$(run "$(json_with)" 80)
OUT81=$(run "$(json_with)" 81)
assert_equals     "T46 폭 80은 압축 3행" "3" "$(nlines "$OUT80")"
assert_equals     "T46 폭 81은 전체 7행" "7" "$(nlines "$OUT81")"
assert_not_contains "T46 압축 레이아웃은 비용 없음" "cost" "$OUT80"
assert_contains     "T46 전체 레이아웃은 비용 표시" "cost" "$OUT81"

# --- T47: 전체 레이아웃은 막대·비용·전체 세션 ID를 보존한다 ---
FULL=$(run "$(json_with)" 81)
assert_equals "T47 전체 레이아웃 5h 막대는 20칸" "20" "$(count_char '[█░]' "$(nth_line 4 "$FULL")")"
assert_contains "T47 전체 레이아웃 비용 금액" '$605' "$FULL"
# 예산은 10칸(경과 9000s / 창 18000s)이고 소진율 70% 는 14칸이므로 11번째 칸부터 끝까지가
# 초과 구간이다. 초과는 3칸을 넘어 빨강이고, 그 앞 열 칸은 회색으로 남는다.
PACE_ROW=$(nth_line 4 "$(run_raw "$(json_pct 70 10)" 81)")
assert_equals "T47 전체 레이아웃 예산 이내는 회색 10칸" "10" "$(count_str "$GREY" "$PACE_ROW")"
assert_equals "T47 전체 레이아웃 예산 초과는 빨강 10칸" "10" "$(count_str "$RED" "$PACE_ROW")"
assert_contains "T47 전체 레이아웃 예산 경계는 회색 다음이 빨강" "${GREY}█${RESET}${RED}█" "$PACE_ROW"
assert_not_contains "T47 전체 레이아웃은 압축 페이스 기호 없음" "▲" "$PACE_ROW"
if [ "$HAVE_GIT" = 1 ]; then
  FULL_SESSION=$(run "$(json_branch)" 81)
  assert_contains "T47 전체 레이아웃 푸터에 전체 세션 ID" "$KNOWN_SESSION" "$(nth_line 7 "$FULL_SESSION")"
fi

# --- T48: 폭을 못 재면 COLUMNS 값과 무관하게 전체 레이아웃을 쓴다 ---
AUTO=$(run_auto "$(json_with)")
assert_equals "T48 폭 판정 불가 시 전체 7행" "7" "$(nlines "$AUTO")"
assert_contains "T48 오래된 COLUMNS=40을 무시하고 비용 표시" "cost" "$AUTO"

# --- T1: rate_limits 있으면 5h/7d 라벨과 소진율이 나온다 ---
OUT=$(run "$(json_with)" 80)
assert_match "T1 5h 소진율 표시" '5h [0-9]+%' "$OUT"
assert_match "T1 7d 소진율 표시" '7d [0-9]+%' "$OUT"
assert_match "T1 5h 리셋 분 단위 표기" "↺[0-9]+h[0-9]+m" "$OUT"

# --- T2: 비용을 표시하지 않는다 ---
OUT=$(run "$(json_with)" 80)
assert_not_contains "T2 24h 비용 라벨 없음" "24h" "$OUT"
assert_not_contains "T2 7d 비용 금액 없음" "\$605" "$OUT"
assert_not_contains "T2 cost 라벨 없음" "cost" "$OUT"

# --- T4: 소진율 90% 이상이면 빨간색 경고 ---
RAW=$(run_raw "$(json_high)" 80)
assert_contains "T4 90%+ 빨간색 경고" "$RED" "$RAW"

# --- T5: 폭 경계를 넘으면 전체와 압축 레이아웃의 출력이 달라진다 ---
A=$(run "$(json_with)" 81)
B=$(run "$(json_with)" 80)
if [ "$(mask_time "$A")" != "$(mask_time "$B")" ]; then
  ok "T5 폭 81과 80의 출력이 다름"
else
  bad "T5 폭 81과 80의 출력이 다름" "identical output"
fi

# --- T7: 세 행 구성 (rate 있음, 브랜치 없음) ---
#    행1 시간·경로 / 행2 계정·버전·세션 / 행3 ctx·모델·effort·5h·7d.
OUT=$(run "$(json_with)" 80)
assert_equals "T7 총 3행" "3" "$(nlines "$OUT")"
assert_match  "T7 행3 ctx"  'ctx [0-9]'  "$(nth_line 3 "$OUT")"
assert_match  "T7 행3 5h"   '5h [0-9]'   "$(nth_line 3 "$OUT")"
assert_match  "T7 행3 7d"   '7d [0-9]'   "$(nth_line 3 "$OUT")"

# --- T7-model: 모델·effort 는 ctx 뒤에, 버전은 행2 에 온다 ---
OUT=$(run "$(json_with)" 80)
assert_match    "T7-model ctx 뒤 모델명" 'ctx [0-9]+% Opus 4\.8' "$(nth_line 3 "$OUT")"
assert_contains "T7-model 행2 버전" "v2.1.11" "$(nth_line 2 "$OUT")"

# --- T33: 모델명 파싱이 sed 없이도 "이름 버전" 표기를 유지한다 ---
OUT=$(run "$(json_with)" 80)
assert_match "T33 모델 이름+버전 표기 유지" 'Opus 4\.8' "$OUT"

# --- T8: 5h 와 7d 는 ctx 와 같은 행(행3)에 병합되어 나온다(파이프 없음) ---
#    Task 4 의 게이지 병합으로 각자 줄에 온다는 이전 기대는 성립하지 않는다. 5h·7d 는
#    행3 하나에만 나타나고(중복 없음), 그 행에 파이프 구분자는 쓰지 않는다.
OUT=$(run "$(json_with)" 80)
L3=$(nth_line 3 "$OUT")
assert_equals   "T8 5h 게이지 1개(행3)" "1" "$(printf '%s\n' "$OUT" | grep -c '5h [0-9]')"
assert_equals   "T8 7d 게이지 1개(행3)" "1" "$(printf '%s\n' "$OUT" | grep -c '7d [0-9]')"
assert_contains "T8 5h 는 행3 에 있음" "5h" "$L3"
assert_contains "T8 7d 는 행3 에 있음" "7d" "$L3"
assert_equals   "T8 행3 파이프 없음" "0" "$(count_char '|' "$L3")"

# --- T9: effort → Claude Code 원형 글리프 + 웜 게이지 색(low=초록 … max=빨강, ultracode=마젠타) ---
#    글리프 모양과 색이 함께 단계를 표현한다. rate 없는 json_eff 로 색 오염을 막고 색을 글리프에 직접 묶어 검증.
OUT=$(run "$(json_eff high)" 80)
assert_contains "T9 effort high 글리프(●)" "●" "$OUT"
RAW=$(run_raw "$(json_eff low)"       80); assert_contains "T9 low 초록 ○"        "${GREEN}○"    "$RAW"
RAW=$(run_raw "$(json_eff medium)"    80); assert_contains "T9 medium 연두 ◐"     "${LIME}◐"     "$RAW"
RAW=$(run_raw "$(json_eff high)"      80); assert_contains "T9 high 노랑 ●"       "${YELLOW}●"   "$RAW"
RAW=$(run_raw "$(json_eff xhigh)"     80); assert_contains "T9 xhigh 주황 ◉"      "${AMBER}◉"    "$RAW"
RAW=$(run_raw "$(json_eff max)"       80); assert_contains "T9 max 빨강 ◈"        "${RED}◈"      "$RAW"
RAW=$(run_raw "$(json_eff ultracode)" 80); assert_contains "T9 ultracode 마젠타 ✦" "${MAGENTA}✦" "$RAW"

# --- T10: effort 없으면 글리프 없이 모델명만 (데이터 부재의 정당한 부재 단언) ---
OUT=$(run "$(json_no_effort)" 80)
assert_no_match "T10 effort 부재 시 글리프 없음" "○|◐|●|◉|◈|✦" "$OUT"
assert_contains "T10 모델명은 유지" "Opus 4.8" "$OUT"

# --- T11: 행1 은 시간·경로만 — 계정·버전·세션은 행2 ---
OUT=$(run "$(json_with)" 80)
FIRST=$(first_line "$OUT")
assert_not_contains "T11 행1 에 gh 계정 없음" "gh@" "$FIRST"
assert_not_contains "T11 행1 에 버전 없음" "v2.1.11" "$FIRST"
assert_contains     "T11 행2 에 gh 계정" "gh@personal" "$(nth_line 2 "$OUT")"

# --- T13a: rate 도 캐시도 없으면 행3 에 ctx 만 남고 행 수는 그대로 3 ---
OUT=$(run "$(json_without)" 80)
assert_equals   "T13a rate 부재에도 3행" "3" "$(nlines "$OUT")"
assert_match    "T13a 행3 ctx 유지" 'ctx [0-9]' "$(nth_line 3 "$OUT")"
assert_no_match "T13a 캐시가 비면 5h 없음" '5h [0-9]' "$OUT"
assert_no_match "T13a 캐시가 비면 7d 없음" '7d [0-9]' "$OUT"

# --- T13b: rate 는 없어도 유효한 캐시가 있으면 그 값을 그린다 ---
seed_rate_cache 24 "$FIVE_RESET" 41 "$WEEK_RESET"
OUT=$(run_keep "$(json_without)" 80)
assert_match "T13b 캐시에서 5h 공급" '5h 24%' "$OUT"
assert_match "T13b 캐시에서 7d 공급" '7d 41%' "$OUT"
rm -f "$RATE_CACHE"

# --- T14: 버전 무손실 ---
OUT=$(run "$(json_with)" 80)
assert_contains "T14 버전 표시" "v2.1.11" "$OUT"

# --- T15: 리셋 무손실 — 5h·7d 리셋(↺) 둘 다 유지 ---
OUT=$(run "$(json_with)" 80)
assert_equals "T15 리셋 2개 유지" "2" "$(count_char '↺' "$OUT")"

# --- T16: 제거 안전 게이트 — 소스에 옛 화살표 글리프가 없다 (정적 검사) ---
if grep -q '╰─»' "$SRC/scripts/statusline.sh"; then
  bad "T16 옛 화살표 글리프 제거" "found ╰─» in statusline.sh"
else
  ok "T16 옛 화살표 글리프 제거"
fi

# --- T17: 절대 소진율 색 임계 — 노랑 80%, 빨강 90% (페이스 오버레이 없는 fixture 로 격리) ---
#    다른 색 소스(aws:⏳ 노랑, aws:expired 빨강)는 AWS_SHARED_CREDENTIALS_FILE 을 먼 미래
#    만료 fixture 로 고정해 격리했으므로 YELLOW/RED 존재가 절대색만 가리킨다.
#    json_pct_nr 로 reset 을 빼 예산 초과 구간의 색이 색 판정에 섞이지 않게 한다.
YELLOW=$(printf '\033[33m')
RAW=$(run_raw "$(json_pct_nr 80 10)" 80)
assert_contains     "T17 80%면 노란색 경고" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct_nr 75 10)" 80)
assert_not_contains "T17 75%면 노란색 없음(노랑 임계 미만)" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct_nr 90 10)" 80)
assert_contains     "T17 90%면 빨간색 경고" "$RED" "$RAW"
RAW=$(run_raw "$(json_pct_nr 85 10)" 80)
assert_not_contains "T17 85%면 빨강 없음(빨강 임계 미만)" "$RED" "$RAW"

# --- T18: 브랜치가 있으면 첫 줄(경로 옆)에 온다. 괄호 대신 브랜치 아이콘( ) 접두(사이 공백 없음) ---
BRANCH_GLYPH=$(printf '\356\202\240')   #  U+E0A0 (Powerline git branch)
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 80)
  FIRST=$(first_line "$OUT")
  SECOND=$(nth_line 2 "$OUT")
  assert_contains     "T18 첫 줄에 브랜치 아이콘+이름(사이 공백 없음)" "${BRANCH_GLYPH}wip" "$FIRST"
  assert_not_contains "T18 둘째 줄에 브랜치명 없음" "wip" "$SECOND"
  assert_contains     "T18 둘째 줄에 계정" "gh@personal" "$SECOND"
  assert_equals       "T18 첫 줄 파이프 없음" "0" "$(count_char '|' "$FIRST")"
else
  printf 'SKIP T18 (git fixture 미생성)\n'
fi

# --- T40: 압축 첫 행은 감지 폭을 넘지 않는다(긴 경로·브랜치를 폭 기준으로 절단) ---
#    브랜치명에 한글을 넣어 폭 계산과 절단을 internal/width 의 단위 테스트가 아니라 실제
#    렌더 경로를 거쳐 검증한다. 두 칸 문자를 한 칸으로 세는 회귀는 ASCII 브랜치 픽스처로는
#    드러나지 않는다.
if [ "$HAVE_GIT" = "1" ]; then
  LONGREPO="$TMPROOT/deep/aa/bb/cc/dd/very-long-project-directory-name"
  mkdir -p "$LONGREPO"
  ( cd "$LONGREPO" \
    && git init -q \
    && git symbolic-ref HEAD "refs/heads/한글브랜치이름아주길게테스트용문자열모음입니다" \
    && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
           commit -q --allow-empty -m init ) >/dev/null 2>&1
  OUT=$(HOME="$TMPROOT" run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$LONGREPO")" 80)
  FIRST=$(first_line "$OUT")
  W1=$(vwidth_of "$FIRST")
  assert_equals "T40 첫 행이 감지 폭 80칼럼 이내" "yes" "$([ "$W1" -le 80 ] && echo yes || echo "no($W1)")"
  assert_contains "T40 잘린 자리에 줄임표" "…" "$FIRST"
  assert_contains "T40 한글 브랜치가 첫 행에 온다" "한글브랜치" "$FIRST"
  assert_equals   "T40 한글 브랜치가 반으로 쪼개지지 않음(유효 UTF-8)" "ok" "$(utf8_intact "$FIRST")"
else
  printf 'SKIP T40 (git fixture 미생성)\n'
fi

# --- T26: Claude Code 계정 이메일이 둘째 줄에 나온다 (.claude.json 의 oauthAccount.emailAddress) ---
#    라벨 접두 없이 이메일 그대로, coral(173) 색으로 렌더한다. cwd=/tmp 라 브랜치 없이 계정만 있는 줄2.
OUT=$(run "$(json_without)" 80)
assert_contains "T26 둘째 줄에 Claude 계정 이메일" "octocat@example.com" "$(nth_line 2 "$OUT")"
assert_not_contains "T26 이메일 앞 cc: 접두 없음" "cc:octocat" "$OUT"
CORAL=$(printf '\033[38;5;173m')
RAW=$(run_raw "$(json_without)" 80)
assert_contains "T26 계정 이메일 coral(173) 색" "${CORAL}octocat@example.com" "$RAW"

# --- T27: 세션 ID 는 앞 6자만 행2 에 온다 ---
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 80)
  SESS6=$(printf '%s' "$KNOWN_SESSION" | cut -c1-6)
  assert_contains     "T27 행2 에 세션 마커+접두 6자" "⧉ ${SESS6}" "$(nth_line 2 "$OUT")"
  assert_not_contains "T27 전체 UUID 는 표시하지 않음" "$KNOWN_SESSION" "$OUT"
  assert_not_contains "T27 행1 에 세션 없음" "⧉" "$(first_line "$OUT")"
else
  printf 'SKIP T27 (git fixture 미생성)\n'
fi
OUT=$(run "$(json_without)" 80)
assert_not_contains "T27 session_id 부재 시 ⧉ 없음" "⧉" "$OUT"

# --- T44: 세션 id 가 6자 미만이면 접두 대신 전체 값을 그대로 쓴다 ---
#    ${var#??????} 는 6자 미만 문자열에 매치하지 않아 원본이 그대로 남고, 이어지는
#    ${var%"$var"} 는 빈 문자열이 된다 — 그 결과 마커만 남고 id 가 사라진다. 실제 세션 id 는
#    36자 UUID 라 이 경로를 타지 않지만, 가드 한 줄로 그 빈 접두를 막는다.
json_short_session() {
  printf '{"session_id":"abc","workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}'
}
OUT=$(run "$(json_short_session)" 80)
assert_contains "T44 6자 미만 세션 id 는 전체 값 표시" "⧉ abc" "$(nth_line 2 "$OUT")"

# --- T41: 짧은 압축 픽스처의 모든 행은 감지 폭 80 안에 든다(캐노리, 상한 아님) ---
#    2행과 3행은 설계상(비목표 문서 참고) 폭 상한이 없다. 아래 픽스처는 전부 cwd=/tmp 처럼
#    짧은 값만 쓰므로 이 단언은 "그 조합이 지금 이 정도"를 보는 캐노리일 뿐, 2·3행에 80칼럼
#    상한이 있다는 보증이 아니다. 상한은 T40 이 검증하는 1행에만 있다.
check_all_widths() {
  _bad=0
  printf '%s\n' "$1" | while IFS= read -r _l; do
    [ "$(vwidth_of "$_l")" -gt 80 ] && printf 'over\n'
  done | grep -q over && _bad=1
  [ "$_bad" -eq 0 ] && printf 'ok' || printf 'over80'
}
for _fx in "$(json_with)" "$(json_without)" "$(json_high)" "$(json_pct 100 100)"; do
  assert_equals "T41 짧은 압축 픽스처의 80칼럼 이내(캐노리, 상한 아님)" "ok" "$(check_all_widths "$(run "$_fx" 80)")"
done

# --- T25: gh 라벨을 설정 파일에서 매핑 (소스에 계정명 하드코딩 없음) ---
#    매핑된 계정은 라벨로, 미매핑은 계정명 그대로, 빈 값은 gh@---. 색코드 비숫자는 기본색으로 폴백.
printf 'testwork' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains "T25 config 매핑 계정 → 라벨(gh@work)" "gh@work" "$(nth_line 2 "$OUT")"
printf 'nobody-xyz' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains "T25 미매핑 계정 → gh@<계정명>" "gh@nobody-xyz" "$(nth_line 2 "$OUT")"
printf '' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains "T25 빈 캐시는 판정 이전이라 gh@?" "gh@?" "$(nth_line 2 "$OUT")"
printf 'badcolor' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains "T25 비숫자 색코드도 라벨은 렌더(가드)" "gh@weird" "$(nth_line 2 "$OUT")"
printf 'octocat' > "$TMPROOT/gh-prompt-user"   # 이후 테스트 위해 원복

# --- T45: 캐시의 탭 네 필드 레코드를 상태별로 렌더 ---
#    셸 프롬프트가 쓰는 레코드에서 계정명·상태·마감 시각을 각각 읽어 상태 문자(⏳Nm·!·?)와
#    색을 붙인다. 마감 시각은 고정 숫자로 두면 시간이 지나 항상 마감 후로 판정돼 마커 검증이
#    조용히 무력해지므로, 렌더 시점 기준 상대값으로 만든다.
gh_cache() { printf 'v2\t%s\t%s\t%s\n' "$1" "$2" "$3" > "$TMPROOT/gh-prompt-user"; }
GH_NOW=$(date +%s)

gh_cache octocat ok 0
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 ok 은 라벨만"              "gh@personal" "$(nth_line 2 "$OUT")"
assert_not_contains "T45 ok 에 인증 실패 문자 없음" "gh@personal!" "$(nth_line 2 "$OUT")"
assert_not_contains "T45 ok 에 판정 불가 문자 없음" "gh@personal?" "$(nth_line 2 "$OUT")"
assert_not_contains "T45 ok 에 한도 마커 없음"      "⏳" "$(nth_line 2 "$OUT")"

gh_cache octocat auth_failed 0
OUT=$(run "$(json_without)" 80)
RAW=$(run_raw "$(json_without)" 80)
assert_contains     "T45 auth_failed 는 gh@personal!" "gh@personal!" "$(nth_line 2 "$OUT")"
assert_contains     "T45 auth_failed 는 전체 빨강"    "${RED}gh@personal!" "$RAW"

gh_cache octocat unknown 0
OUT=$(run "$(json_without)" 80)
RAW=$(run_raw "$(json_without)" 80)
assert_contains     "T45 unknown 은 gh@personal?"  "gh@personal?" "$(nth_line 2 "$OUT")"
assert_contains     "T45 unknown 은 전체 회색"     "$(printf '\033[38;5;240m')gh@personal?" "$RAW"

gh_cache testwork rate_limited "$((GH_NOW + 540))"
OUT=$(run "$(json_without)" 80)
RAW=$(run_raw "$(json_without)" 80)
assert_contains     "T45 rate_limited 는 gh@work⏳9m" "gh@work⏳9m" "$(nth_line 2 "$OUT")"
assert_contains     "T45 라벨은 설정 색, 마커만 노랑" \
  "$(printf '\033[38;5;27m')gh@work$(printf '\033[0m')$(printf '\033[33m')⏳9m" "$RAW"

gh_cache testwork rate_limited "$((GH_NOW + 30))"
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 1분 미만 남으면 1m 으로 올림" "gh@work⏳1m" "$(nth_line 2 "$OUT")"

gh_cache testwork rate_limited "$((GH_NOW - 60))"
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 마감이 지나면 라벨만"     "gh@work" "$(nth_line 2 "$OUT")"
assert_not_contains "T45 마감이 지나면 마커 제거"  "⏳" "$(nth_line 2 "$OUT")"

gh_cache testwork rate_limited notanumber
OUT=$(run "$(json_without)" 80)
assert_not_contains "T45 마감 시각이 숫자가 아니면 마커 없음" "⏳" "$(nth_line 2 "$OUT")"

gh_cache - no_active 0
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 no_active 는 gh@---"      "gh@---" "$(nth_line 2 "$OUT")"

gh_cache - unknown 0
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 계정명 없는 unknown 은 gh@?" "gh@?" "$(nth_line 2 "$OUT")"

gh_cache - ok 0
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 계정명 자리가 - 이면 상태보다 먼저 걸러 gh@?" "gh@?" "$(nth_line 2 "$OUT")"
assert_no_match     "T45 gh@- 로 새지 않음" 'gh@-[[:space:]]' "$(nth_line 2 "$OUT")"

printf 'v1\toctocat\tok\t0\n' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 형식을 모르는 네 필드는 계정명만 살리고 판정 불가" \
  "gh@personal?" "$(nth_line 2 "$OUT")"

printf 'v2\toctocat\n' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 필드 수가 어긋나면 gh@?" "gh@?" "$(nth_line 2 "$OUT")"

printf 'octocat' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 80)
assert_contains     "T45 탭 없는 한 줄은 계정명으로 해석" "gh@personal" "$(nth_line 2 "$OUT")"

# --- T20: 요소별 색 — 모델명 시안, 파이프·라벨 등 dim 유지 ---
RAW=$(run_raw "$(json_with)" 80)
assert_contains "T20 모델명 시안(36)" "$CYAN" "$RAW"
assert_contains "T20 파이프·라벨 등 dim 유지" "$DIMC" "$RAW"

# --- T21: 압축 레이아웃은 막대를 쓰지 않고 전체 레이아웃은 20칸 막대를 쓴다 ---
COMPACT=$(run "$(json_with)" 80)
FULL=$(run "$(json_with)" 81)
assert_no_match "T21 압축 레이아웃은 막대 문자 없음" '█|░' "$COMPACT"
assert_match    "T21 전체 레이아웃은 막대 문자 있음" '█|░' "$FULL"

# --- T22: 소진율 경계값(0%/100%)이 숫자로 그대로 나온다 ---
OUT=$(run "$(json_pct_nr 0 100)" 80)
assert_match "T22 0% 표기" '5h 0%' "$OUT"
assert_match "T22 100% 표기" '7d 100%' "$OUT"

# --- T23: ctx 임계 색 — 40%+ 노랑, 70%+ 빨강, 미만은 색 없음 ---
ctx30=$(run_raw "$(json_ctx 60000)"  80 | grep 'ctx')
ctx45=$(run_raw "$(json_ctx 90000)"  80 | grep 'ctx')
ctx75=$(run_raw "$(json_ctx 150000)" 80 | grep 'ctx')
assert_not_contains "T23 30% ctx 노랑 없음" "$YELLOW" "$ctx30"
assert_not_contains "T23 30% ctx 빨강 없음" "$RED" "$ctx30"
assert_contains     "T23 45% ctx 노랑(40%+)" "$YELLOW" "$ctx45"
assert_not_contains "T23 45% ctx 빨강 없음(70% 미만)" "$RED" "$ctx45"
assert_contains     "T23 75% ctx 빨강(70%+)" "$RED" "$ctx75"

# --- T24: ctx 소진율 숫자에 임계 색이 붙는다 ---
ctx45r=$(run_raw "$(json_ctx 90000)" 80 | grep 'ctx')
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
OUT=$(run "$(json_pct 70 10)" 80)
assert_contains     "T31 초과 시 ▲ 표시" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
OUT=$(run "$(json_pct 40 10)" 80)
assert_not_contains "T31 여유면 ▲ 없음" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
RAW=$(run_raw "$(json_pct 70 10)" 80 | grep '5h')
assert_contains     "T31 큰 초과 빨강 ▲" "${RED}▲" "$RAW"
RAW=$(run_raw "$(json_pct 55 10)" 80 | grep '5h')
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
      CLAUDE_STATUSLINE_WIDTH=80 \
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
    run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$1")" 80
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
OUT_A=$(run "$(json_with)" 80)
assert_contains "T35 이메일 첫 렌더 표시" "octocat@example.com" "$OUT_A"
assert_match    "T35 캐시 파일 생성" "email=octocat@example.com" "$(cat "$TMPROOT/cache/claude-statusline/cc-account.env" 2>/dev/null)"

# .claude.json 을 캐시보다 새 것으로 만들고 이메일을 바꾸면 다음 렌더에 반영된다(무손실).
sleep 1
printf '{"oauthAccount":{"emailAddress":"newuser@example.com"}}' > "$TMPROOT/.claude.json"
OUT_B=$(run "$(json_with)" 80)
assert_contains "T35 파일 변경 시 새 이메일 반영" "newuser@example.com" "$OUT_B"
# 원복
printf '{"oauthAccount":{"emailAddress":"octocat@example.com"}}' > "$TMPROOT/.claude.json"

# --- T36: AWS 만료 파싱 캐시 (파일 파싱 경로에서만 캐시) ---
if command -v saml2aws >/dev/null 2>&1; then
  rm -f "$TMPROOT/cache/claude-statusline/aws-exp.env"
  FUT=$(( $(date +%s) + 7200 ))
  CREDS="$TMPROOT/aws-credentials"
  # date 포맷팅은 -u 로 UTC 값을 찍는다 — 로컬 시각을 찍고 +0000 라벨만 붙이면(로컬 타임존이
  # UTC 가 아닐 때) format_aws 가 파싱한 epoch 가 로컬 UTC 오프셋만큼 어긋난다.
  printf '[default]\nx_security_token_expires = %s\n' \
    "$(date -u -r "$FUT" '+%Y-%m-%dT%H:%M:%S+0000' 2>/dev/null || date -u -d "@$FUT" '+%Y-%m-%dT%H:%M:%S+0000')" > "$CREDS"
  OUT=$(printf '%s' "$(json_with)" | \
    CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" \
    XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
    CLAUDE_STATUSLINE_WIDTH=80 \
    AWS_SHARED_CREDENTIALS_FILE="$CREDS" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g")
  # 자릿수만 보는 정규식은 로컬 타임존 오프셋만큼 어긋난 epoch 도 통과시킨다. fixture 가
  # 만든 만료 시각($FUT)과 캐시된 값이 정확히 같은지까지 확인해야 그 어긋남을 잡는다.
  assert_equals "T36 파일 파싱 시 만료 epoch 캐시가 fixture 만료와 정확히 일치" "exp_epoch=$FUT" "$(cat "$TMPROOT/cache/claude-statusline/aws-exp.env" 2>/dev/null)"
else
  echo "warn: saml2aws 미설치 — T36 을 건너뜁니다" >&2
fi

# --- T42: 두 매니페스트의 버전이 같다 ---
#    불변은 두 매니페스트의 버전 동일성이다. 리터럴 버전을 못박으면 다음 기능 변경의
#    버전 범프(AGENTS.md 의 필수 절차)마다 이 테스트가 붉어진다 — 그래서 특정 값을 이름
#    붙이지 않고 SemVer 세 자리 형태인지만 모양으로 가드한다.
PV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -1)
MV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$(dirname "$SRC")/.claude-plugin/marketplace.json" | sed -n 2p)
assert_equals "T42 plugin.json 과 marketplace.json 버전 일치" "$PV" "$MV"
assert_match  "T42 버전이 SemVer 세 자리 형태" '^[0-9]+\.[0-9]+\.[0-9]+$' "$PV"

# --- T50: 만료된 캐시 창은 그리지 않는다. 지난 창의 소진율은 더 이상 참이 아니다 ---
seed_rate_cache 94 "$((NOW - 60))" 41 "$WEEK_RESET"
OUT=$(run_keep "$(json_without)" 80)
assert_no_match "T50 만료된 5h 는 감춘다" '5h [0-9]' "$OUT"
assert_match    "T50 만료 안 된 7d 는 남는다" '7d 41%' "$OUT"
rm -f "$RATE_CACHE"

# --- T51: stdin 값이 캐시보다 새것이면 파일이 갱신된다 ---
seed_rate_cache 24 "$FIVE_RESET" 41 "$WEEK_RESET"
run_keep "$(json_pct 55 60)" 80 >/dev/null
assert_contains "T51 새 소진율이 저장됨" "fivePct=55" "$(cat "$RATE_CACHE")"
rm -f "$RATE_CACHE"

# --- T52: 낡은 stdin 값은 파일도 화면도 되돌리지 못한다 ---
seed_rate_cache 60 "$FIVE_RESET" 90 "$WEEK_RESET"
OUT=$(run_keep "$(json_pct 24 41)" 80)
assert_contains "T52 파일은 그대로" "fivePct=60" "$(cat "$RATE_CACHE")"
assert_match    "T52 화면도 되돌아가지 않음" '5h 60%' "$OUT"
rm -f "$RATE_CACHE"

# --- T53: 세션 최초 렌더에서도 캐시가 두 줄을 공급한다(전체 레이아웃) ---
seed_rate_cache 24 "$FIVE_RESET" 41 "$WEEK_RESET"
OUT=$(run_keep "$(json_without)" 120)
assert_match "T53 전체 레이아웃 5h 행" '5h .*24%' "$OUT"
assert_match "T53 전체 레이아웃 7d 행" '7d .*41%' "$OUT"
rm -f "$RATE_CACHE"

# --- T54: 창이 넘어가면 소진율이 낮아도 뒤 리셋이 이긴다 ---
#    캐시는 아직 만료되지 않은 옛 창(94%)을, stdin 은 더 뒤 리셋의 새 창(3%)을 들고 있다.
#    소진율만 비교하면 옛 창이 이겨 화면이 새 창으로 넘어가지 못한다.
seed_rate_cache 94 "$((NOW + 100))" 41 "$WEEK_RESET"
OUT=$(run_keep "$(json_pct 3 41)" 80)
assert_match    "T54 새 창이 화면을 차지" '5h 3%' "$OUT"
assert_contains "T54 새 창이 파일에도 반영" "fivePct=3" "$(cat "$RATE_CACHE")"
rm -f "$RATE_CACHE"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
