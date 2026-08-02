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

# --- stdin JSON (한번에 파싱) ---
JSON_CMD="$PLUGIN_ROOT/scripts/json.awk"

# --- 축약 함수(in-process) ---
# shorten-lib.sh 는 색 변수 C_RESET·C_DIM·C_BLUE 를 참조한다(ansi 모드 값). 여기서 매핑해
# 정의한 뒤 소스하면 statusline 이 서브프로세스 없이 shorten_path·shorten_branch 를 직접 쓴다.
C_RESET="$RST" C_DIM="$DIM" C_BLUE=$(printf '\033[34m')
. "$PLUGIN_ROOT/scripts/shorten-lib.sh"

input=$(cat)

# 현재 시각을 한 번만 얻어 리셋·rate·aws·시간 세그먼트가 공유한다(date fork 축소).
_now=$(date '+%s %H:%M')
NOW_EPOCH="${_now%% *}"
NOW_CLOCK="${_now#* }"

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

# 소수 문자열 값이 1 이상인지 판정한다(부동소수 비교 대체). 비음수에서 v>=1 은 floor(v)>=1 과 같다.
# 수정 시 검토 관점: 음수 입력은 가정하지 않는다(비용은 항상 0 이상).
ge_one() {
  _ip=${1%.*}
  case "$_ip" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_ip" -ge 1 ]
}

cwd=$(strip_control "$cwd")
model_display=$(strip_control "$model_display")
version=$(strip_control "$version")
session_id=$(strip_control "$session_id")

format_model() {
  local d="$1" name="" ver="" w
  # 공백으로 토큰을 나눠 이름(Opus/Sonnet/Haiku)과 버전(N.N)을 찾는다. sed 없이 fork 0.
  local old_ifs="$IFS"
  IFS=' '
  set -f
  # shellcheck disable=SC2086
  set -- $d
  set +f
  IFS="$old_ifs"
  for w in "$@"; do
    case "$w" in
      Opus|Sonnet|Haiku) name="$w" ;;
      [0-9]*.[0-9]*) case "$w" in *[!0-9.]*) ;; *) ver="$w" ;; esac ;;
    esac
  done
  if [ -n "$name" ] && [ -n "$ver" ]; then
    printf '%s %s' "$name" "$ver"
  else
    # 폴백(인식 안 되는 이름): 원본과 바이트 동일해야 하므로 sed 를 그대로 쓴다. 이 분기는
    # 실제 Claude 모델명이 타지 않는 드문 경로라 성능에 영향이 없다. 메인 경로는 sed 가 없다.
    printf '%s' "$d" | sed 's/Claude //; s/ *(.*//'
  fi
}

# effort(추론 강도) → Claude Code 세션 헤더와 같은 원형 글리프(low ○ / medium ◐ / high ● /
# xhigh ◉ / max ◈ / ultracode ✦) + 웜 게이지 색(초록→빨강, ultracode 는 마젠타). 미지원·부재면 빈 문자열.
# 모양과 색이 함께 단계를 표현한다: low=빈 원·초록 → max=채운 마름모·빨강, ultracode 는 별·마젠타.
# 수정 시 검토 관점: 이 글리프들은 페이스 마커(▲)나 다른 렌더 기호와 겹치지 않아야 회귀 테스트가
# 글리프로 effort 를 특정할 수 있다. 겹치는 글리프를 새로 넣지 않는다.
format_effort() {
  case "$1" in
    low)       printf '%s○%s' "$GREEN" "$RST" ;;
    medium)    printf '%s◐%s' "$LIME" "$RST" ;;
    high)      printf '%s●%s' "$YELLOW" "$RST" ;;
    xhigh)     printf '%s◉%s' "$AMBER214" "$RST" ;;
    max)       printf '%s◈%s' "$RED" "$RST" ;;
    ultracode) printf '%s✦%s' "$MAGENTA" "$RST" ;;
    *)         ;;
  esac
}

# 컨텍스트 소진율. 라벨은 dim, 숫자는 임계에 따라 색이 오른다(40% 노랑, 70% 빨강).
# 수정 시 검토 관점: 이 임계(40/70)는 rate 의 80/90 과 별개다. 컨텍스트는 더 일찍 경고한다.
format_context() {
  local current=$((input_tokens + cache_create + cache_read))
  if [ "$window_size" -le 0 ]; then
    window_size=200000
  fi
  local pct=$((current * 100 / window_size))
  local cc=""
  if [ "$pct" -ge 70 ]; then cc="$RED"
  elif [ "$pct" -ge 40 ]; then cc="$YELLOW"
  fi
  printf '%s %s%d%%%s' "$(dimlabel ctx)" "$cc" "$pct" "$RST"
}

# 리셋까지 남은 시간을 분 단위까지 표기한다: ↺2d3h / ↺1h23m / ↺48m
format_reset() {
  local target="$1" diff d h m
  diff=$((target - NOW_EPOCH))
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
# 소진율 숫자는 평상시 기본 밝기, 한도가 임박하면 노랑(80%)→빨강(90%)으로 승격한다.
# window(윈도우 초: 5h=18000, 7d=604800)가 주어지면 경과 시간 비례 예산을 계산해, 그보다 앞서
# 쓴 만큼을 ▲ 로 표시한다. 앞선 폭이 3칸(15%p) 이상이면 빨강, 그보다 적으면 노랑, 앞서지
# 않았으면 기호를 붙이지 않는다.
# 수정 시 검토 관점: 정보 무손실 원칙상 리셋(↺)은 항상 켠다. 절대 소진율 색과 페이스 색은 별개
# 신호다 — 앞의 것은 한도까지의 거리, 뒤의 것은 시간 대비 속도다. 둘을 한 색으로 합치지 않는다.
format_rate() {
  local label="$1" pct_raw="$2" reset="$3" window="${4:-}"
  [ -z "$pct_raw" ] && return 0
  local pct="${pct_raw%.*}"
  [ -z "$pct" ] && pct=0
  local vc=""
  if [ "$pct" -ge 90 ]; then vc="$RED"
  elif [ "$pct" -ge 80 ]; then vc="$YELLOW"
  fi
  local pace=""
  if [ -n "$reset" ] && [ -n "$window" ] && [ "$window" -gt 0 ]; then
    local diff elapsed budget fill over
    diff=$((reset - NOW_EPOCH)); [ "$diff" -lt 0 ] && diff=0
    elapsed=$((window - diff)); [ "$elapsed" -lt 0 ] && elapsed=0
    budget=$(( (elapsed * 20 + window / 2) / window ))
    [ "$budget" -gt 20 ] && budget=20
    fill=$(( pct * 20 / 100 ))
    over=$(( fill - budget ))
    if [ "$over" -ge 3 ]; then pace="${RED}▲${RST}"
    elif [ "$over" -gt 0 ]; then pace="${YELLOW}▲${RST}"
    fi
  fi
  local reset_str=""
  [ -n "$reset" ] && reset_str=" ${DIM}$(format_reset "$reset")${RST}"
  printf '%s %s%d%%%s%s%s' \
    "$(dimlabel "$label")" "$vc" "$pct" "$RST" "$pace" "$reset_str"
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
  local cache="$CACHE_DIR/cc-account.env"
  local email=""
  # 캐시가 있고 .claude.json 이 그보다 새 것이 아니면(변경 없음) 캐시된 이메일을 쓴다.
  # test -nt 는 프로세스를 만들지 않는다. .claude.json 은 런타임이 자주 다시 쓰므로 그때만
  # 재스캔한다. 파일이 다시 쓰이면 이메일이 바뀌었어도 다음 렌더에 반영되어 손실이 없다.
  if [ -f "$cache" ] && [ ! "$cf" -nt "$cache" ]; then
    while IFS='=' read -r _k _v; do
      [ "$_k" = email ] && email="$_v"
    done < "$cache"
  else
    email=$(awk '
      /"oauthAccount"[[:space:]]*:[[:space:]]*\{/ { oa=1 }
      oa && match($0, /"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"/) {
        v=substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", v); sub(/"$/, "", v)
        print v; exit
      }
    ' "$cf" 2>/dev/null || true)
    email=$(strip_control "$email")
    mkdir -p "$CACHE_DIR"
    printf 'email=%s\n' "$email" > "$cache"
  fi
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

  local exp_epoch remaining
  local creds="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
  local cache="$CACHE_DIR/aws-exp.env"
  # env 로 만료가 주어졌으면(AWS_SESSION_EXPIRATION) 파일·캐시 없이 그대로 파싱한다.
  # 파일에서 읽은 경우에만, credentials 가 캐시보다 새 것이 아니면 캐시된 epoch 를 쓴다.
  exp_epoch=""
  if [ -z "${AWS_SESSION_EXPIRATION:-}" ] && [ -f "$creds" ] && [ -f "$cache" ] && [ ! "$creds" -nt "$cache" ]; then
    while IFS='=' read -r _k _v; do
      [ "$_k" = exp_epoch ] && exp_epoch="$_v"
    done < "$cache"
  fi
  if [ -z "$exp_epoch" ]; then
    local exp_norm
    exp_norm=$(printf '%s' "$exp" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
    exp_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$exp_norm" +%s 2>/dev/null || \
                date -d "$exp" +%s 2>/dev/null || echo 0)
    # env 가 아니라 파일에서 읽은 경우에만 캐시한다.
    if [ -z "${AWS_SESSION_EXPIRATION:-}" ] && [ -f "$creds" ]; then
      mkdir -p "$CACHE_DIR"
      printf 'exp_epoch=%s\n' "$exp_epoch" > "$cache"
    fi
  fi
  remaining=$(( (exp_epoch - NOW_EPOCH) / 60 ))

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

# --- git branch (캐시) ---
# git 을 진실의 원천으로 유지한다. 캐시 미스에서만 git 을 한 번 불러 브랜치와 HEAD 파일
# 경로를 얻고, 이후 렌더는 저장된 HEAD 파일 첫 줄을 내장 read 로 읽어(프로세스 없음) 토큰과
# 비교해 변경 여부를 판정한다. 내용 비교라 같은 초에 일어난 브랜치 전환도 잡는다.
# 수정 시 검토 관점: 무효화는 HEAD 파일 mtime 이 아니라 첫 줄 내용으로 한다(mtime 은 test -nt
# 의 1초 granularity 때문에 같은 초 전환을 놓친다). HEAD 경로는 서브디렉토리에서 cwd 상대
# 경로로 나올 수 있어 cwd 기준 절대경로로 저장한다.
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  _gbc="$CACHE_DIR/git-branch.env"
  _c_cwd="" _c_head="" _c_token="" _c_branch=""
  if [ -f "$_gbc" ]; then
    while IFS='=' read -r _k _v; do
      case "$_k" in
        cwd) _c_cwd="$_v" ;;
        head) _c_head="$_v" ;;
        token) _c_token="$_v" ;;
        branch) _c_branch="$_v" ;;
      esac
    done < "$_gbc"
  fi

  _hit=0
  if [ "$_c_cwd" = "$cwd" ] && [ -n "$_c_head" ] && [ -f "$_c_head" ]; then
    _cur=""
    IFS= read -r _cur < "$_c_head" 2>/dev/null || _cur=""
    if [ "$_cur" = "$_c_token" ]; then
      branch="$_c_branch"
      _hit=1
    fi
  fi

  if [ "$_hit" -eq 0 ]; then
    # 미스: git 한 번 호출로 HEAD 경로와 브랜치를 함께 얻는다(출력 두 줄).
    _gp=$(git -C "$cwd" --no-optional-locks rev-parse --git-path HEAD --abbrev-ref HEAD 2>/dev/null || true)
    _head_rel="" _br=""
    { IFS= read -r _head_rel || true; IFS= read -r _br || true; } <<GITOUT
$_gp
GITOUT
    _br=$(strip_control "$_br")
    [ "$_br" = "HEAD" ] && _br=""
    branch="$_br"

    # HEAD 경로 정규화: 절대경로면 그대로, 상대경로면 cwd 기준으로 붙인다(.. 는 커널이 해석).
    _head_abs=""
    case "$_head_rel" in
      /*) _head_abs="$_head_rel" ;;
      "") _head_abs="" ;;
      *)  _head_abs="$cwd/$_head_rel" ;;
    esac

    # 토큰: HEAD 파일 첫 줄. 저장소가 아니거나 파일이 없으면 캐시를 쓰지 않는다.
    if [ -n "$_head_abs" ] && [ -f "$_head_abs" ]; then
      _tok=""
      IFS= read -r _tok < "$_head_abs" 2>/dev/null || _tok=""
      mkdir -p "$CACHE_DIR"
      {
        printf 'cwd=%s\n' "$cwd"
        printf 'head=%s\n' "$_head_abs"
        printf 'token=%s\n' "$_tok"
        printf 'branch=%s\n' "$branch"
      } > "$_gbc"
    else
      # 저장소가 아니면(브랜치 없음) 캐시를 지워 다음 렌더가 다시 판정하게 둔다.
      rm -f "$_gbc" 2>/dev/null || true
    fi
  fi
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
# 경로와 브랜치는 가변 길이라 fit-line1.awk 가 표시 폭 예산에 맞춰 줄인다. awk 는 색 코드를
# 폭 0으로 세므로 색이 입혀진 경로를 그대로 넘긴다. 브랜치는 색 없는 이름만 넘기고 아이콘과
# 색은 절단 뒤에 입힌다 — 아이콘 한 칸은 awk 의 예산 66 바깥에서 따로 셈한다.
# 수정 시 검토 관점: 여기의 시각·공백 폭과 fit-line1.awk 의 예산 상수는 한 쌍이다. 한쪽만
# 바꾸면 74칼럼 상한이 조용히 깨진다. 또한 read 가 줄을 찾지 못하면 그 변수는 빈 세그먼트를
# 뜻해야 한다 — 브랜치가 없어 awk 가 둘째 줄을 빈 문자열로 낼 때 $(...) 가 후행 개행을 모두
# 지워 그 줄 자체가 사라질 수 있고, 그러면 read 가 EOF 로 실패한다. read 직전에 두 변수를
# 비워 두어, 그 실패가 이전 값이 아니라 항상 빈 문자열로 귀결되게 한다.
time_seg="${GREEN}${NOW_CLOCK}${RST}"
path_seg=$(shorten_path "$cwd")
branch_name=""
[ -n "$branch" ] && branch_name=$(shorten_branch "$branch")

_fit=$(printf '%s\n%s\n' "$path_seg" "$branch_name" \
  | LC_ALL=C awk -f "$PLUGIN_ROOT/scripts/fit-line1.awk")
path_seg=""
branch_name=""
{ IFS= read -r path_seg || true; IFS= read -r branch_name || true; } <<FITOUT
$_fit
FITOUT

line_loc="${time_seg} ${path_seg}"
[ -n "$branch_name" ] && line_loc="${line_loc} ${MAGENTA}${BRANCH_GLYPH}${branch_name}${RST}"

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

# 게이지 3종(ctx·5h·7d)은 각자 한 줄로 세로로 쌓아 소진율을 한눈에 비교하게 한다. 막대 없이
# 라벨과 소진율(%)만 보여준다. ctx 는 곧 그 모델의 컨텍스트 창이므로 모델명(시안)과 effort
# 글리프를 ctx 줄의 % 뒤에 붙인다.
# 수정 시 검토 관점: rate 는 데이터가 없으면 format_rate 가 빈 문자열을 돌려주고 emit 이 그 줄을
# 생략하므로, 5h·7d 는 각각 독립적으로 빠질 수 있다.
model_str=$(format_model "$model_display")
effort_ind=$(format_effort "$effort")
line_ctx="$(format_context)"
[ -n "$model_str" ] && line_ctx="${line_ctx} ${CYAN}${model_str}${RST}"
[ -n "$effort_ind" ] && line_ctx="${line_ctx} ${effort_ind}"
line_5h=$(format_rate 5h "$five_h" "$five_reset" 18000)
line_7d=$(format_rate 7d "$week_h" "$week_reset" 604800)

# 줄6(cost): cost 24h ... / 7d ... / <당월일수>d ...  (그룹 구분은 흐린 슬래시, 좌우 공백 한 칸)
SLASH=" ${DIM}/${RST} "
line_cost="$(dimlabel cost) ${daily_seg}${SLASH}${weekly_seg}${SLASH}${monthly_seg}"

# 줄7(푸터): v버전 ⧉세션ID. 실행을 규정하는 저관심 상수값을 맨 아래 흐린 푸터로 내린다.
# 수정 시 검토 관점: 세션 ID 는 다른 세션이 참조하도록 복사하는 값이라 축약하지 않고 전체 UUID 를
# 그대로 둔다. 버전·세션이 모두 없으면 emit 이 이 줄을 생략한다.
line_foot=""
[ -n "$version" ] && line_foot="$(dimlabel "v${version}")"
[ -n "$session_id" ] && { [ -n "$line_foot" ] && line_foot="${line_foot} "; line_foot="${line_foot}${GREY240}${SESSION_GLYPH} ${session_id}${RST}"; }

# --- 출력: 값 없는 줄은 emit 이 생략한다. 단일 줄이 폭을 넘으면 터미널 소프트랩에 맡긴다. ---
output=$(emit "$line_loc" "$line_meta" "$line_ctx" "$line_5h" "$line_7d" "$line_cost" "$line_foot")

printf '%s' "$output"
