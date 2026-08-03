#!/bin/sh
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# --- ANSI ---
ESC=$(printf '\033')
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
. "$PLUGIN_ROOT/scripts/term-width.sh"

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

# 두 렌더러가 같은 절대 소진율 색을 쓰도록 판정을 한 곳에 둔다. 결과는 GAUGE_COLOR 에 남긴다.
# 수정 시 검토 관점: 컨텍스트의 임계(40/70)와 rate 의 임계(80/90)는 호출자가 각각 넘긴다.
# 렌더러 안에서 임계를 다시 판정하면 두 레이아웃이 조용히 어긋나므로 표현만 렌더러에 둔다.
set_gauge_color() {
  local pct="$1" warn="$2" danger="$3"
  GAUGE_COLOR=""
  if [ "$pct" -ge "$danger" ]; then GAUGE_COLOR="$RED"
  elif [ "$pct" -ge "$warn" ]; then GAUGE_COLOR="$YELLOW"
  fi
}

set_context_gauge() {
  local current=$((input_tokens + cache_create + cache_read))
  local size="$window_size"
  [ "$size" -le 0 ] && size=200000
  CONTEXT_PCT=$((current * 100 / size))
  set_gauge_color "$CONTEXT_PCT" 40 70
  CONTEXT_COLOR="$GAUGE_COLOR"
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

# rate 의 절대 소진율과 시간 대비 페이스를 함께 계산한다. 전체 레이아웃은 RATE_BUDGET 뒤의
# 막대 칸을 강조하고, 압축 레이아웃은 RATE_PACE_COLOR 로 ▲ 하나를 그린다.
# 수정 시 검토 관점: 색 판정과 페이스 산술은 두 표현의 공통 의미다. 렌더러별 파일로 옮기면
# 같은 입력이 레이아웃에 따라 다른 경고를 내므로 이 함수에 남긴다.
set_rate_gauge() {
  local pct_raw="$1" reset="$2" window="${3:-}"
  RATE_PCT="${pct_raw%.*}"
  [ -z "$RATE_PCT" ] && RATE_PCT=0
  set_gauge_color "$RATE_PCT" 80 90
  RATE_COLOR="$GAUGE_COLOR"
  RATE_BUDGET=""
  RATE_OVER=0
  RATE_PACE_COLOR=""
  if [ -n "$reset" ] && [ -n "$window" ] && [ "$window" -gt 0 ]; then
    local diff elapsed fill
    diff=$((reset - NOW_EPOCH)); [ "$diff" -lt 0 ] && diff=0
    elapsed=$((window - diff)); [ "$elapsed" -lt 0 ] && elapsed=0
    RATE_BUDGET=$(( (elapsed * 20 + window / 2) / window ))
    [ "$RATE_BUDGET" -gt 20 ] && RATE_BUDGET=20
    fill=$(( RATE_PCT * 20 / 100 ))
    RATE_OVER=$(( fill - RATE_BUDGET ))
    if [ "$RATE_OVER" -ge 3 ]; then RATE_PACE_COLOR="$RED"
    elif [ "$RATE_OVER" -gt 0 ]; then RATE_PACE_COLOR="$YELLOW"
    fi
  fi
}

# tty-path.env·cc-account.env·aws-exp.env·git-branch.env 가 이 경로를 공유한다.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"

# 폭을 못 재면 정보를 덜어내지 않는 전체 레이아웃을 쓴다. 전용 주입 변수는 term_width 가
# 처리하며, 대화형 셸에서 오래된 값일 수 있는 COLUMNS 는 의도적으로 읽지 않는다.
status_width=$(term_width)
layout=full
case "$status_width" in
  ''|*[!0-9]*) ;;
  *) [ "$status_width" -le 80 ] && layout=compact ;;
esac

# --- GitHub 계정 표시기 ---
# 활성 GitHub 계정과 그 계정의 인증·한도 상태를 라벨·색·상태 문자로 구분한다. 계정명은 소스에
# 박지 않고 설정 파일에서 매핑을 읽는다: ${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts
#   한 줄에 하나: <github-login>=<라벨>,<256색코드>   예) octocat=personal,214   (# 로 시작하면 주석)
# 상태는 셸 프롬프트가 쓰는 캐시에서 읽는다: ${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user
#   탭 네 필드 한 줄: v2<TAB><계정명 또는 -><TAB><상태><TAB><마감 로컬 epoch 또는 0>
# 수정 시 검토 관점:
#   - 캐시를 명령 치환으로 통째로 읽지 않는다. 제어문자 제거가 필드 구분자인 탭까지 지워 네 필드가
#     한 덩어리로 붙는다. 내장 read 로 필드를 먼저 나눠야 이 손실이 구조적으로 생기지 않는다.
#   - 계정명 유무를 상태보다 먼저 가른다. 순서를 뒤집으면 계정명 자리가 빈 손상 레코드가 gh@- 로 샌다.
#   - 색코드와 마감 시각은 숫자만 허용해 설정·캐시 파일이 임의 이스케이프를 주입하지 못하게 막는다.
#   - 이 도구는 캐시를 읽기만 한다. 갱신과 신선도 판정은 셸 프롬프트가 맡는다.
format_gh() {
  local cache="${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user"
  [ -f "$cache" ] || return 0

  # 파일 끝에 개행이 없으면 read 가 비영 종료코드를 내므로 set -e 대비로 흡수한다. 다섯째 변수는
  # 필드가 넷을 넘는지 가리는 용도다(넘치면 마지막 변수에 나머지가 통째로 들어온다).
  local f1="" f2="" f3="" f4="" f5="" user state deadline
  IFS="$TAB" read -r f1 f2 f3 f4 f5 < "$cache" || true

  if [ -z "$f2" ]; then
    # 탭이 없는 한 줄은 계정명만 기록하는 프롬프트 구현을 위한 형식이다. 빈 파일도 여기로 들어와
    # 계정명이 비고, 아래 계정 미상 분기가 받는다.
    user="$f1"; state="ok"; deadline=0
  elif [ -n "$f4" ] && [ -z "$f5" ]; then
    user="$f2"; deadline="$f4"
    case "$f1" in
      v2) state="$f3" ;;
      *)  state="unknown"; deadline=0 ;;
    esac
  else
    user=""; state="unknown"; deadline=0
  fi

  case "$state" in ok|rate_limited|auth_failed|unknown|no_active) ;; *) state="unknown" ;; esac
  case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
  user=$(strip_control "$user")

  case "$user" in
    ''|-)
      case "$state" in
        no_active) printf '%sgh@---%s' "$GREY240" "$RST" ;;
        *)         printf '%sgh@?%s'   "$GREY240" "$RST" ;;
      esac
      return 0 ;;
  esac

  local label="$user" color="" base
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts"
  if [ -f "$conf" ]; then
    local line rest
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      case "$line" in
        "$user="*)
          rest="${line#*=}"
          label=$(strip_control "${rest%%,*}")
          case "$rest" in *,*) color=$(strip_control "${rest#*,}") ;; esac
          break ;;
      esac
    done < "$conf"
  fi
  case "$color" in
    ''|*[!0-9]*) base="$AMBER214" ;;
    *)           base="${ESC}[38;5;${color}m" ;;
  esac

  case "$state" in
    auth_failed) printf '%sgh@%s!%s' "$RED" "$label" "$RST" ;;
    unknown)     printf '%sgh@%s?%s' "$GREY240" "$label" "$RST" ;;
    no_active)   printf '%sgh@---%s' "$GREY240" "$RST" ;;
    rate_limited)
      if [ "$deadline" -gt "$NOW_EPOCH" ]; then
        printf '%sgh@%s%s%s⏳%sm%s' "$base" "$label" "$RST" "$YELLOW" \
          "$(( (deadline - NOW_EPOCH + 59) / 60 ))" "$RST"
      else
        printf '%sgh@%s%s' "$base" "$label" "$RST"
      fi ;;
    *)           printf '%sgh@%s%s' "$base" "$label" "$RST" ;;
  esac
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

# 공백 구분 메타 행을 두 렌더러가 같은 순서로 조립하도록 단일 헬퍼를 공유한다.
line_meta=""
append_meta() {
  [ -n "$1" ] || return 0
  if [ -n "$line_meta" ]; then line_meta="${line_meta} $1"; else line_meta="$1"; fi
}

# 선택한 파일만 읽어 상대 레이아웃의 비용 조회·절단·함수 파싱을 모두 건너뛴다.
case "$layout" in
  compact) . "$PLUGIN_ROOT/scripts/render-compact.sh" ;;
  *)       . "$PLUGIN_ROOT/scripts/render-full.sh" ;;
esac

printf '%s' "$output"
