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
RST=$(printf '\033[0m')
SEP="${DIM} | ${RST}"

# --- 축약 스크립트 ---
SHORTEN_CMD="$PLUGIN_ROOT/scripts/shorten.sh"

# --- stdin JSON (한번에 파싱) ---
input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '%s  %s%s%sstatusline: jq not found%s' \
    "${GREEN}$(date +%H:%M)${RST}" \
    "${DIM}${PWD:-.}${RST}" \
    "$SEP" "$DIM" "$RST"
  exit 0
fi

eval "$(printf '%s' "$input" | jq -r '
  @sh "cwd=\(.workspace.current_dir // "")",
  @sh "model_display=\(.model.display_name // "")",
  @sh "version=\(.version // "")",
  @sh "effort=\(.effort.level // empty)",
  @sh "window_size=\(.context_window.context_window_size // 200000)",
  @sh "input_tokens=\(.context_window.current_usage.input_tokens // 0)",
  @sh "cache_create=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  @sh "cache_read=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  @sh "five_h=\(.rate_limits.five_hour.used_percentage // empty)",
  @sh "five_reset=\(.rate_limits.five_hour.resets_at // empty)",
  @sh "week_h=\(.rate_limits.seven_day.used_percentage // empty)",
  @sh "week_reset=\(.rate_limits.seven_day.resets_at // empty)"
')"
# rate_limits·effort 필드는 구독 종류/모델 지원 여부에 따라 부재할 수 있어 미정의로 남을 수 있다.
# 아래 참조 지점이 set -u 없이 동작하도록 빈 기본값을 보장한다.
five_h="${five_h:-}" five_reset="${five_reset:-}" week_h="${week_h:-}" week_reset="${week_reset:-}"
effort="${effort:-}"

# --- 유틸리티 ---

# 색 코드를 제거한 표시 폭(문자 수). 정렬 대상 세그먼트엔 2칸 이모지가 없어 wc -m 이 정확하다.
# 수정 시 검토 관점: 정렬(maxlen·align_line)은 wc -m 이 표시 칸 수와 일치한다는 전제 위에 선다.
# 막대 글리프(█ ░)와 ↺ 는 UTF-8 로캘에서 각 1칸으로 세지만, C/POSIX 로캘이면 바이트로 세어
# 막대가 있는 줄(ctx·5h)과 없는 줄(cost)의 폭이 서로 달리 부풀어 파이프 열이 어긋난다. 이 도구는
# 사용자의 UTF-8 터미널에서 실행되므로 성립한다. 비 UTF-8 환경으로 옮기면 이 전제부터 재검토한다.
vis_width() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -m | tr -d ' '
}

# 라벨(구조 안내)을 dim 으로 감싸는 단일 헬퍼. "라벨은 dim, 값은 기본 밝기" 규칙의 진실 소스다.
# 수정 시 검토 관점: 라벨 색을 바꾸려면 이 함수 하나만 고친다. 조립부에서 인라인 ${DIM}...${RST}
# 로 라벨을 다시 감싸지 말고 이 함수를 쓴다(규칙이 여러 곳으로 흩어지면 서로 어긋난다).
dimlabel() {
  printf '%s%s%s' "$DIM" "$1" "$RST"
}

# 소수 문자열 값이 1 이상인지 판정한다(bc 대체). 비음수에서 v>=1 은 floor(v)>=1 과 같다.
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
cost_cache="$PLUGIN_ROOT/data/cost-cache.json"
mdays=$(date -v1d -v+1m -v-1d +%d 2>/dev/null || date -d "$(date +%Y-%m-01) +1 month -1 day" +%d 2>/dev/null || echo 30)
# 라벨(24h/7d/당월/모델명)은 dim(dimlabel), 금액($..)은 기본 밝기로 색을 나눈다.
daily_seg="$(dimlabel 24h) \$--" weekly_seg="$(dimlabel 7d) \$--" monthly_seg="$(dimlabel "${mdays}d") \$--"
if [ -f "$cost_cache" ]; then
  cost_available=$(jq -r '.available // false' "$cost_cache" 2>/dev/null || echo false)
  if [ "$cost_available" = "true" ]; then
    eval "$(jq -r '
      @sh "opus=\(.dailyModels.opus // 0)",
      @sh "sonnet=\(.dailyModels.sonnet // 0)",
      @sh "haiku=\(.dailyModels.haiku // 0)",
      @sh "w_cost=\(.weeklyCost // 0 | round)",
      @sh "m_cost=\(.monthlyCost // 0 | round)"
    ' "$cost_cache" 2>/dev/null || echo 'opus=0 sonnet=0 haiku=0 w_cost=0 m_cost=0')"
    weekly_seg="$(dimlabel 7d) \$${w_cost}"
    monthly_seg="$(dimlabel "${mdays}d") \$${m_cost}"
    parts=""
    ge_one "$opus"   && parts="$(dimlabel Opus) \$$(printf '%.0f' "$opus")"
    ge_one "$sonnet" && { [ -n "$parts" ] && parts="$parts "; parts="${parts}$(dimlabel Sonnet) \$$(printf '%.0f' "$sonnet")"; }
    ge_one "$haiku"  && { [ -n "$parts" ] && parts="$parts "; parts="${parts}$(dimlabel Haiku) \$$(printf '%.0f' "$haiku")"; }
    daily_seg="$(dimlabel 24h) ${parts:-\$0}"
  fi
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

# 줄1: 시간(공백 2칸)경로. 브랜치·계정은 항상 다음 줄로 내린다.
time_seg="${GREEN}$(date +%H:%M)${RST}"
path_seg=$(shorten_path "$cwd")
line_loc="${time_seg}  ${path_seg}"

# 줄2: (브랜치) gh 계정 aws 세션. 값 없는 항목은 자연히 빠지고 남은 항목만 공백으로 잇는다.
branch_part=""
[ -n "$branch" ] && branch_part="${MAGENTA}($(shorten_branch "$branch"))${RST}"
seg_gh=$(format_gh)
seg_aws=$(format_aws)
line_meta="$branch_part"
[ -n "$seg_gh" ] && { [ -n "$line_meta" ] && line_meta="${line_meta} ${seg_gh}" || line_meta="$seg_gh"; }
[ -n "$seg_aws" ] && { [ -n "$line_meta" ] && line_meta="${line_meta} ${seg_aws}" || line_meta="$seg_aws"; }

# 모델 그룹: 버전(dim) 모델명(시안) effort 램프. 버전은 현재 표시 정보라 보존한다.
model_str=$(format_model "$model_display")
effort_ind=$(format_effort "$effort")
model_group="$(dimlabel "v${version}") ${CYAN}${model_str}${RST}"
[ -n "$effort_ind" ] && model_group="${model_group} ${effort_ind}"
context_bar=$(format_context_bar)

# --- 정렬 대상 세 줄(model·5h·cost)을 (왼쪽 | 오른쪽) 페어로 만든다 ---
# 줄3(model): v<버전> <모델> <effort 램프> | ctx <막대> %
row3_l="$model_group"
row3_r="$(dimlabel ctx) ${context_bar}"

# 줄4(rate): 5h <막대> % ↺ | 7d <막대> % ↺. 5h 라벨을 4칸 패딩해 model·cost 컬럼과 정렬한다.
# 수정 시 검토 관점: 5h·7d 는 한 줄에 | 로 묶는다. 5h 부재 시 7d 를 왼쪽으로 올려 손실을 막는다.
rate_l=$(format_rate "$(printf '%-4s' 5h)" "$five_h" "$five_reset")
rate_r=$(format_rate "7d" "$week_h" "$week_reset")
[ -z "$rate_l" ] && { rate_l="$rate_r"; rate_r=""; }

# 줄5(cost): cost 24h ... | 7d ... <당월일수>d ...  (7d·당월 사이는 파이프 없이 공백)
cost_l="$(dimlabel "$(printf '%-4s' cost)") ${daily_seg}"
cost_r="${weekly_seg} ${monthly_seg}"

# 파이프 왼쪽 세그먼트들(row3_l·rate_l·cost_l)의 최대 표시폭을 구해 정렬 목표폭으로 쓴다.
# 수정 시 검토 관점: 정렬 대상 집합은 이 maxlen 루프와 아래 align_line 호출부 두 곳이 같아야 한다.
# 정렬 줄을 추가·제거하면 양쪽을 함께 고친다 — 한쪽만 고치면 오류 없이 파이프 열만 조용히 어긋난다.
maxlen=0
for seg in "$row3_l" "$rate_l" "$cost_l"; do
  [ -n "$seg" ] || continue
  wv=$(vis_width "$seg")
  [ "$wv" -gt "$maxlen" ] && maxlen="$wv"
done

# 왼쪽을 목표폭(width)으로 우측 패딩한 뒤 SEP 로 오른쪽을 잇는다. 오른쪽이 없으면 왼쪽만, 왼쪽이
# 없으면 생략. width 는 전역 대신 인자로 받아 maxlen 계산과의 시간적 결합을 드러낸다.
align_line() {
  local left="$1" right="$2" width="$3"
  [ -n "$left" ] || return 0
  if [ -n "$right" ]; then
    printf '%s%*s%s%s' "$left" "$(( width - $(vis_width "$left") ))" '' "$SEP" "$right"
  else
    printf '%s' "$left"
  fi
}
line_ctx=$(align_line "$row3_l" "$row3_r" "$maxlen")
line_rate=$(align_line "$rate_l" "$rate_r" "$maxlen")
line_cost=$(align_line "$cost_l" "$cost_r" "$maxlen")

# --- 출력: 값 없는 줄은 emit 이 생략한다. 단일 줄이 폭을 넘으면 터미널 소프트랩에 맡긴다. ---
output=$(emit "$line_loc" "$line_meta" "$line_ctx" "$line_rate" "$line_cost")

printf '%s' "$output"
