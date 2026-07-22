#!/bin/sh
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# --- ANSI ---
DIM=$(printf '\033[2m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RED=$(printf '\033[31m')
MAGENTA=$(printf '\033[35m')
CYAN=$(printf '\033[36m')
AMBER214=$(printf '\033[38;5;214m')
LIME=$(printf '\033[38;5;148m')
GREY240=$(printf '\033[38;5;240m')
CORAL173=$(printf '\033[38;5;173m')
RST=$(printf '\033[0m')
SEP="${DIM} | ${RST}"

# 브랜치 아이콘(Powerline git branch, U+E0A0)과 세션 마커(U+29C9). 아이콘 글리프는 Nerd Font 가
# 있어야 제대로 보인다(없으면 □). 소스에 리터럴 대신 코드포인트로 두어 인코딩 사고를 피한다.
BRANCH_GLYPH=$(printf '\356\202\240')
SESSION_GLYPH=$(printf '\342\247\211')

# --- 축약 스크립트 ---
SHORTEN_CMD="$PLUGIN_ROOT/scripts/shorten.sh"

# --- stdin JSON (한번에 파싱) ---
JSON_CMD="$PLUGIN_ROOT/scripts/json.awk"

input=$(cat)

if ! command -v awk >/dev/null 2>&1; then
  printf '%s  %s%s%sstatusline: awk not found%s' \
    "${GREEN}$(date +%H:%M)${RST}" \
    "${DIM}${PWD:-.}${RST}" \
    "$SEP" "$DIM" "$RST"
  exit 0
fi

# 필드별 `// default` 의미: 먼저 기본값을 두고 파서 출력으로 덮어쓴다.
cwd="" model_display="" version="" effort="" session_id=""
window_size=200000 input_tokens=0 cache_create=0 cache_read=0
five_h="" five_reset="" week_h="" week_reset=""
TAB=$(printf '\t')
# 주의: 아래 필드는 모두 단일 줄 값(경로·모델명·숫자·타임스탬프)이고 strip_control 로
# 제어문자를 제거하므로 while read(개행 단위)로 안전하다. 개행이 든 값은 가정하지 않는다.
while IFS="$TAB" read -r _p _v; do
  case "$_p" in
    ..workspace.current_dir) cwd="$_v" ;;
    ..model.display_name) model_display="$_v" ;;
    ..version) version="$_v" ;;
    ..session_id) session_id="$_v" ;;
    ..effort.level) effort="$_v" ;;
    ..context_window.context_window_size) window_size="$_v" ;;
    ..context_window.current_usage.input_tokens) input_tokens="$_v" ;;
    ..context_window.current_usage.cache_creation_input_tokens) cache_create="$_v" ;;
    ..context_window.current_usage.cache_read_input_tokens) cache_read="$_v" ;;
    ..rate_limits.five_hour.used_percentage) five_h="$_v" ;;
    ..rate_limits.five_hour.resets_at) five_reset="$_v" ;;
    ..rate_limits.seven_day.used_percentage) week_h="$_v" ;;
    ..rate_limits.seven_day.resets_at) week_reset="$_v" ;;
  esac
done <<EOF
$(printf '%s' "$input" | awk -f "$JSON_CMD")
EOF

# --- 유틸리티 ---

# 라벨(구조 안내)을 dim 으로 감싸는 단일 헬퍼. "라벨은 dim, 값은 기본 밝기" 규칙의 진실 소스다.
# 수정 시 검토 관점: 라벨 색을 바꾸려면 이 함수 하나만 고친다. 조립부에서 인라인 ${DIM}...${RST}
# 로 라벨을 다시 감싸지 말고 이 함수를 쓴다(규칙이 여러 곳으로 흩어지면 서로 어긋난다).
dimlabel() {
  printf '%s%s%s' "$DIM" "$1" "$RST"
}

# 라벨 텍스트를 지정 폭으로 우측 정렬한다(앞에 공백 채움). 색 코드가 없는 순수 텍스트에만 쓰고
# 결과를 dimlabel 로 감싼다 — 정렬 폭은 표시 문자 수 기준이라 색 코드가 섞이면 어긋난다.
# 수정 시 검토 관점: 정렬 대상 라벨(왼쪽 v버전·5h·cost, 오른쪽 ctx·7d)은 같은 폭 인자를 공유해야
# 값 열이 세로로 맞는다. 한 열의 폭 계산을 바꾸면 그 열의 모든 라벨 호출을 함께 본다.
ralign() { printf '%*s' "$2" "$1"; }

# 소수 문자열 값이 1 이상인지 판정한다(부동소수 비교 대체). 비음수에서 v>=1 은 floor(v)>=1 과 같다.
# 수정 시 검토 관점: 음수 입력은 가정하지 않는다(비용은 항상 0 이상).
ge_one() {
  _ip=${1%.*}
  case "$_ip" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_ip" -ge 1 ]
}

strip_control() {
  LC_ALL=C printf '%s' "$1" | tr -d '\000-\037\177'
}

cwd=$(strip_control "$cwd")
model_display=$(strip_control "$model_display")
version=$(strip_control "$version")
session_id=$(strip_control "$session_id")

shorten_path() {
  if [ -x "$SHORTEN_CMD" ]; then
    "$SHORTEN_CMD" --ansi path "$1"
  else
    printf '%s not executable, using fallback\n' "$SHORTEN_CMD" >&2
    printf '%s%s%s' "$DIM" "$1" "$RST"
  fi
}

shorten_branch() {
  if [ -x "$SHORTEN_CMD" ]; then
    "$SHORTEN_CMD" --ansi branch "$1"
  else
    printf '%s not executable, using fallback\n' "$SHORTEN_CMD" >&2
    printf '%s' "$1"
  fi
}

format_model() {
  local d="$1" name="" ver=""
  ver=$(printf '%s' "$d" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*\(Opus\|Sonnet\|Haiku\).*/\1/p')
  if [ -n "$ver" ]; then
    name=$(printf '%s' "$d" | sed -n 's/.*[0-9][0-9]*\.[0-9][0-9]*[[:space:]]*\(Opus\|Sonnet\|Haiku\).*/\1/p')
  else
    name=$(printf '%s' "$d" | sed -n 's/.*\(Opus\|Sonnet\|Haiku\)[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    ver=$(printf '%s' "$d" | sed -n 's/.*\(Opus\|Sonnet\|Haiku\)[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\2/p')
  fi
  if [ -n "$name" ] && [ -n "$ver" ]; then
    printf '%s %s' "$name" "$ver"
  else
    printf '%s' "$d" | sed 's/Claude //; s/ *(.*//'
  fi
}

# effort(추론 강도) → 세로 램프 글리프(▁▂▃▅▇) + 웜 게이지 색(초록→빨강). 미지원/부재면 빈 문자열.
# 높이와 색이 함께 단계를 표현한다: low=초록·낮음 → max=빨강·높음. ctx·rate 막대(█ ░)와 글리프가
# 겹치지 않아 회귀 테스트가 램프 글리프로 effort 를 특정할 수 있다.
format_effort() {
  case "$1" in
    low)    printf '%s▁%s' "$GREEN" "$RST" ;;
    medium) printf '%s▂%s' "$LIME" "$RST" ;;
    high)   printf '%s▃%s' "$YELLOW" "$RST" ;;
    xhigh)  printf '%s▅%s' "$AMBER214" "$RST" ;;
    max)    printf '%s▇%s' "$RED" "$RST" ;;
    *)      ;;
  esac
}

# 소진율(0~100)을 20칸 막대로 만든다(한 칸 5%, 내림). fill_color·empty_color 로 채움/빈칸
# 색을 입힌다(빈 문자열이면 기본 밝기). 컨텍스트·rate 막대가 같은 폭·모양을 쓰도록 공용화한다.
# 수정 시 검토 관점: 채움은 내림이라 100% 전에는 20칸이 다 차지 않는다(예 99%→19칸). 인접
# 5% 구간을 구분하려면 내림을 유지한다(반올림은 25% 경계 양쪽 값을 같은 칸으로 묶는다).
render_bar() {
  local pct="$1" fc="${2:-}" ec="${3:-}"
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  local filled=$(( pct * 20 / 100 ))  # 내림한 채움 칸 수(0~20)
  local bar="" i=0
  while [ "$i" -lt 20 ]; do
    if [ "$i" -lt "$filled" ]; then bar="${bar}${fc}█${RST}"
    else bar="${bar}${ec}░${RST}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$bar"
}

# 컨텍스트 막대: rate 막대와 같은 색 방식을 쓴다 — 채움·빈칸·% 가 한 색(cc)을 따라가고 평상시
# 기본 밝기다. 소진율 40% 이상 노랑·70% 이상 빨강으로 승격한다(임계값만 rate 의 80/90 과 다르게
# 더 일찍 경고). 수정 시 검토 관점: cc 를 render_bar 의 채움·빈칸 인자와 % 에 모두 넘겨 세 요소가
# 같은 색을 쓴다는 불변조건을 유지한다 — 한 곳만 바꾸면 rate 와 색 방식이 다시 어긋난다.
format_context_bar() {
  local current=$((input_tokens + cache_create + cache_read))
  if [ "$window_size" -le 0 ]; then
    window_size=200000
  fi
  local pct=$((current * 100 / window_size))
  local cc=""  # 평상시 기본 밝기
  if [ "$pct" -ge 70 ]; then cc="$RED"
  elif [ "$pct" -ge 40 ]; then cc="$YELLOW"
  fi
  printf '%s %s%d%%%s' "$(render_bar "$pct" "$cc" "$cc")" "$cc" "$pct" "$RST"
}

# 리셋까지 남은 시간을 분 단위까지 표기한다: ↺2d3h / ↺1h23m / ↺48m
format_reset() {
  local target="$1" now diff d h m
  now=$(date +%s)
  diff=$((target - now))
  [ "$diff" -lt 0 ] && diff=0
  if [ "$diff" -ge 86400 ]; then
    d=$((diff / 86400)); h=$(((diff % 86400) / 3600))
    printf '↺%dd%dh' "$d" "$h"
  elif [ "$diff" -ge 3600 ]; then
    h=$((diff / 3600)); m=$(((diff % 3600) / 60))
    printf '↺%dh%dm' "$h" "$m"
  else
    m=$((diff / 60))
    printf '↺%dm' "$m"
  fi
}

# rate limit 세그먼트를 만든다. 소진율이 비어 있으면(구독 없음/응답 전) 빈 문자열.
# label 은 컬럼 정렬용 라벨(dim). 막대·% 는 평상시 기본 밝기, 한도가 임박하면 노랑→빨강으로
# 승격해 경고한다(임계 상수는 아래 분기 참조). 리셋(↺)은 dim.
# 수정 시 검토 관점: 정보 무손실 원칙상 리셋(↺)은 항상 켠다. 폭 압박에도 떼지 않는다.
format_rate() {
  local label="$1" pct_raw="$2" reset="$3"
  [ -z "$pct_raw" ] && return 0
  local pct="${pct_raw%.*}"
  [ -z "$pct" ] && pct=0
  local vc=""  # 값(막대·%) 색: 평상시 기본 밝기
  if [ "$pct" -ge 90 ]; then vc="$RED"
  elif [ "$pct" -ge 80 ]; then vc="$YELLOW"
  fi
  local reset_str=""
  [ -n "$reset" ] && reset_str=" ${DIM}$(format_reset "$reset")${RST}"
  printf '%s %s %s%d%%%s%s' \
    "$(dimlabel "$label")" \
    "$(render_bar "$pct" "$vc" "$vc")" \
    "$vc" "$pct" "$RST" \
    "$reset_str"
}

# --- 비용 데이터 ---
# 시간 축 세그먼트: 24h(당일 모델별) / 7d(주간) / 그 달 일수(당월). 조립부에서 24h 는 cost 라벨과
# 함께 파이프 왼쪽에, 7d·당월은 파이프 오른쪽 한 묶음(공백 구분)에 놓인다.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
cost_cache="$CACHE_DIR/cost-cache.env"
mdays=$(date -v1d -v+1m -v-1d +%d 2>/dev/null || date -d "$(date +%Y-%m-01) +1 month -1 day" +%d 2>/dev/null || echo 30)
# 라벨(24h/7d/당월/모델명)은 dim(dimlabel), 금액($..)은 기본 밝기로 색을 나눈다.
daily_seg="$(dimlabel 24h) \$--" weekly_seg="$(dimlabel 7d) \$--" monthly_seg="$(dimlabel "${mdays}d") \$--"

cost_available=false opus=0 sonnet=0 haiku=0 w_cost=0 m_cost=0
if [ -f "$cost_cache" ]; then
  # sh-safe key=value. 값은 숫자·true/false 뿐이라 while read 로 안전하다(eval·source 아님).
  while IFS='=' read -r _k _val; do
    case "$_k" in
      available) cost_available="$_val" ;;
      dailyOpus) opus="$_val" ;;
      dailySonnet) sonnet="$_val" ;;
      dailyHaiku) haiku="$_val" ;;
      weekly) w_cost="$_val" ;;
      monthly) m_cost="$_val" ;;
    esac
  done < "$cost_cache"
fi

if [ "$cost_available" = "true" ]; then
  weekly_seg="$(dimlabel 7d) \$${w_cost}"
  monthly_seg="$(dimlabel "${mdays}d") \$${m_cost}"
  parts=""
  ge_one "$opus"   && parts="$(dimlabel Opus) \$$(printf '%.0f' "$opus")"
  ge_one "$sonnet" && { [ -n "$parts" ] && parts="$parts "; parts="${parts}$(dimlabel Sonnet) \$$(printf '%.0f' "$sonnet")"; }
  ge_one "$haiku"  && { [ -n "$parts" ] && parts="$parts "; parts="${parts}$(dimlabel Haiku) \$$(printf '%.0f' "$haiku")"; }
  daily_seg="$(dimlabel 24h) ${parts:-\$0}"
fi

# --- GitHub 계정 표시기 ---
# 현재 활성 GitHub 계정(로그인명)을 라벨·색으로 구분한다. 계정명은 소스에 박지 않고 설정 파일에서
# 매핑을 읽는다: ${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts
#   한 줄에 하나: <github-login>=<라벨>,<256색코드>   예) octocat=personal,214   (# 로 시작하면 주석)
# 현재 계정명은 캐시(${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user)에서 읽는다(셸 프롬프트가 기록).
# 매핑에 있으면 gh@<라벨>(지정 색), 없으면 gh@<계정명>(기본색), 계정명이 비면 gh@---(흐림).
# 수정 시 검토 관점: 색코드는 숫자만 허용해 설정 파일이 임의 이스케이프를 주입하지 못하게 가드한다.
format_gh() {
  local cache="${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user"
  [ -f "$cache" ] || return 0
  local user
  user=$(strip_control "$(cat "$cache")")
  [ -z "$user" ] && { printf '%sgh@---%s' "$GREY240" "$RST"; return 0; }

  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts"
  if [ -f "$conf" ]; then
    local line rest label color
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      case "$line" in
        "$user="*)
          rest="${line#*=}"
          label=$(strip_control "${rest%%,*}")
          case "$rest" in *,*) color=$(strip_control "${rest#*,}") ;; *) color="" ;; esac
          case "$color" in
            ''|*[!0-9]*) printf '%sgh@%s%s' "$AMBER214" "$label" "$RST" ;;
            *)           printf '\033[38;5;%smgh@%s%s' "$color" "$label" "$RST" ;;
          esac
          return 0 ;;
      esac
    done < "$conf"
  fi
  printf '%sgh@%s%s' "$AMBER214" "$user" "$RST"
}

# --- Claude Code 계정 표시기 ---
# 현재 로그인된 Claude Code 계정 이메일을 표시한다. 입력 JSON 에는 계정 정보가 없어
# ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json 의 oauthAccount.emailAddress 를 읽는다(읽기 전용).
# 이 파일은 projects 키가 파일경로(점 다수)라 json.awk 의 점-조인 경로 스택을 깨뜨리고 크기도 커서
# (수백 KB) 매 렌더 전체 파싱은 느리다. 그래서 oauthAccount 블록에 진입한 뒤 첫 emailAddress 한 줄만
# 뽑는 줄 기반 awk 로 좁게 추출한다. 부재·미설치·미매치면 빈 문자열(줄에서 자연히 빠짐).
# 수정 시 검토 관점: 이 파일은 Claude Code 런타임 상태라 이 도구는 절대 쓰지 않는다(조회만).
format_cc_account() {
  local cf="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  [ -f "$cf" ] || return 0
  local email
  email=$(awk '
    /"oauthAccount"[[:space:]]*:[[:space:]]*\{/ { oa=1 }
    oa && match($0, /"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      v=substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
      print v; exit
    }
  ' "$cf" 2>/dev/null || true)
  email=$(strip_control "$email")
  [ -z "$email" ] && return 0
  printf '%s%s%s' "$CORAL173" "$email" "$RST"
}

# --- AWS 세션 표시기 ---

format_aws() {
  command -v saml2aws >/dev/null 2>&1 || return 0
  local exp="${AWS_SESSION_EXPIRATION:-}"
  if [ -z "$exp" ]; then
    exp=$(sed -n 's/^x_security_token_expires *= *//p' \
      "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}" 2>/dev/null | head -1)
  fi
  [ -z "$exp" ] && { printf '%saws:?%s' "$DIM" "$RST"; return 0; }

  local now exp_epoch remaining
  now=$(date +%s)
  local exp_norm
  exp_norm=$(printf '%s' "$exp" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
  exp_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$exp_norm" +%s 2>/dev/null || \
              date -d "$exp" +%s 2>/dev/null || echo 0)
  remaining=$(( (exp_epoch - now) / 60 ))

  if [ "$remaining" -gt 10 ]; then
    printf '%saws:✓%s' "$GREEN" "$RST"
  elif [ "$remaining" -gt 0 ]; then
    printf '%saws:⏳%sm%s' "$YELLOW" "$remaining" "$RST"
  else
    sf="${XDG_DATA_HOME:-$HOME/.local/share}/saml2aws-login-suppress"
    today=$(date +%Y-%m-%d)
    if [ -f "$sf" ] && grep -q "^value=${today}$" "$sf" 2>/dev/null; then
      printf '%saws:-%s' "$DIM" "$RST"
    else
      printf '%saws:expired%s' "$RED" "$RST"
    fi
  fi
}

# --- git branch ---
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  branch=$(strip_control "$branch")
  [ "$branch" = "HEAD" ] && branch=""
fi

# 비어 있지 않은 줄만 개행으로 이어 출력한다(끝에 개행 없음).
emit() {
  local out="" ln
  for ln in "$@"; do
    [ -n "$ln" ] || continue
    if [ -z "$out" ]; then
      out="$ln"
    else
      out="${out}
${ln}"
    fi
  done
  printf '%s' "$out"
}

# --- 세그먼트 조립 (폭 무관 단일 세로 스택) ---

# 줄1: 시간 경로 브랜치. 브랜치는 코드상 위치라 경로와 같은 줄에 둔다. 괄호 대신 아이콘( )을
# 이름 바로 앞에 붙인다(사이 공백 없음). 브랜치가 없으면 시간·경로만 남는다.
time_seg="${GREEN}$(date +%H:%M)${RST}"
path_seg=$(shorten_path "$cwd")
line_loc="${time_seg} ${path_seg}"
[ -n "$branch" ] && line_loc="${line_loc} ${MAGENTA}${BRANCH_GLYPH}$(shorten_branch "$branch")${RST}"

# 줄2: Claude계정 gh계정 aws세션. 계정·인증만 모은다. 값 없는 항목은 자연히 빠지고 남은 항목만
# 공백으로 잇는다. 수정 시 검토 관점: 조립 순서를 바꾸려면 이 append_meta 호출 순서만 바꾼다.
seg_cc=$(format_cc_account)
seg_gh=$(format_gh)
seg_aws=$(format_aws)
line_meta=""
append_meta() {
  [ -n "$1" ] || return 0
  if [ -n "$line_meta" ]; then line_meta="${line_meta} $1"; else line_meta="$1"; fi
}
append_meta "$seg_cc"
append_meta "$seg_gh"
append_meta "$seg_aws"

# 줄3(런 메타): 모델 effort v버전 ⧉세션ID. 이 실행을 규정하는 상수값을 한 줄에 모은다. 밝은
# 모델명(시안)이 게이지 클러스터를 여는 머리가 되고, 버전·세션 ID 는 흐림으로 뒤에 붙는다.
# 수정 시 검토 관점: 세션 ID 는 다른 세션이 참조하도록 복사하는 값이라 축약하지 않고 전체 UUID 를
# 그대로 둔다. 값 없는 항목(effort·버전·세션)은 각각 자연히 빠진다.
model_str=$(format_model "$model_display")
effort_ind=$(format_effort "$effort")
line_model="${CYAN}${model_str}${RST}"
[ -n "$effort_ind" ] && line_model="${line_model} ${effort_ind}"
[ -n "$version" ] && line_model="${line_model} $(dimlabel "v${version}")"
[ -n "$session_id" ] && line_model="${line_model} ${GREY240}${SESSION_GLYPH} ${session_id}${RST}"

# 게이지 3종(ctx·5h·7d)은 각자 한 줄로 세로로 쌓아 채움 정도를 한눈에 비교하게 한다. 라벨
# (ctx·5h·7d)과 cost 를 같은 폭 GW 에 우측 정렬해 뒤따르는 값(막대·금액)이 같은 열에서 시작한다.
# 수정 시 검토 관점: 네 라벨(ctx·5h·7d·cost)이 같은 GW 를 공유해야 값 열이 세로로 맞는다 — 한 곳만
# 바꾸면 오류 없이 정렬만 조용히 어긋난다. rate 는 데이터가 없으면 format_rate 가 빈 문자열을
# 돌려주고 emit 이 그 줄을 생략하므로, 5h·7d 는 각각 독립적으로 빠질 수 있다.
GW=4
line_ctx="$(dimlabel "$(ralign ctx "$GW")") $(format_context_bar)"
line_5h=$(format_rate "$(ralign 5h "$GW")" "$five_h" "$five_reset")
line_7d=$(format_rate "$(ralign 7d "$GW")" "$week_h" "$week_reset")

# 줄7(cost): cost 24h ... / 7d ... / <당월일수>d ...  (그룹 구분은 흐린 슬래시, 좌우 공백 한 칸)
SLASH=" ${DIM}/${RST} "
line_cost="$(dimlabel "$(ralign cost "$GW")") ${daily_seg}${SLASH}${weekly_seg}${SLASH}${monthly_seg}"

# --- 출력: 값 없는 줄은 emit 이 생략한다. 단일 줄이 폭을 넘으면 터미널 소프트랩에 맡긴다. ---
output=$(emit "$line_loc" "$line_meta" "$line_model" "$line_ctx" "$line_5h" "$line_7d" "$line_cost")

printf '%s' "$output"
