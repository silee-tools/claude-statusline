#!/bin/sh
# 폭 81 이상이거나 폭을 판정하지 못했을 때 쓰는 일곱 행 전체 레이아웃.
# statusline.sh 가 공통 상태와 함수를 준비한 뒤 불러 쓰며, 호출자의 셸 옵션을 바꾸지 않는다.

ralign() { printf '%*s' "$2" "$1"; }

ge_one() {
  local ip
  ip=${1%.*}
  case "$ip" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ip" -ge 1 ]
}

render_bar() {
  local pct="$1" fill_color="${2:-}" empty_color="${3:-}" budget="${4:-}" over_color="${5:-}"
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  local filled=$(( pct * 20 / 100 ))
  local bar="" i=0
  while [ "$i" -lt 20 ]; do
    if [ "$i" -lt "$filled" ]; then
      if [ -n "$budget" ] && [ "$i" -ge "$budget" ]; then
        bar="${bar}${over_color}▓${RST}"
      else
        bar="${bar}${fill_color}█${RST}"
      fi
    else
      bar="${bar}${empty_color}░${RST}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$bar"
}

format_context_full() {
  set_context_gauge
  printf '%s %s%d%%%s' \
    "$(render_bar "$CONTEXT_PCT" "$CONTEXT_COLOR" "$CONTEXT_COLOR")" \
    "$CONTEXT_COLOR" "$CONTEXT_PCT" "$RST"
}

format_rate_full() {
  local label="$1" pct_raw="$2" reset="$3" window="${4:-}"
  [ -z "$pct_raw" ] && return 0
  set_rate_gauge "$pct_raw" "$reset" "$window"
  local reset_str=""
  [ -n "$reset" ] && reset_str=" ${DIM}$(format_reset "$reset")${RST}"
  printf '%s %s %s%d%%%s%s' \
    "$(dimlabel "$label")" \
    "$(render_bar "$RATE_PCT" "$RATE_COLOR" "$RATE_COLOR" "$RATE_BUDGET" "$RATE_PACE_COLOR")" \
    "$RATE_COLOR" "$RATE_PCT" "$RST" "$reset_str"
}

# 비용 캐시는 전체 레이아웃에서만 읽는다. 압축 레이아웃은 이 파일을 불러오지 않으므로
# 파일 읽기와 당월 일수 계산을 모두 건너뛴다.
cost_cache="$CACHE_DIR/cost-cache.env"
mdays=$(date -v1d -v+1m -v-1d +%d 2>/dev/null || \
  date -d "$(date +%Y-%m-01) +1 month -1 day" +%d 2>/dev/null || printf '30')
daily_seg="$(dimlabel 24h) \$--"
weekly_seg="$(dimlabel 7d) \$--"
monthly_seg="$(dimlabel "${mdays}d") \$--"
cost_available=false
opus=0 sonnet=0 haiku=0 w_cost=0 m_cost=0
if [ -f "$cost_cache" ]; then
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
if [ "$cost_available" = true ]; then
  weekly_seg="$(dimlabel 7d) \$${w_cost}"
  monthly_seg="$(dimlabel "${mdays}d") \$${m_cost}"
  parts=""
  ge_one "$opus" && parts="$(dimlabel Opus) \$$(printf '%.0f' "$opus")"
  ge_one "$sonnet" && { [ -n "$parts" ] && parts="$parts "; parts="${parts}$(dimlabel Sonnet) \$$(printf '%.0f' "$sonnet")"; }
  ge_one "$haiku" && { [ -n "$parts" ] && parts="$parts "; parts="${parts}$(dimlabel Haiku) \$$(printf '%.0f' "$haiku")"; }
  daily_seg="$(dimlabel 24h) ${parts:-\$0}"
fi

# 첫 행은 절단하지 않고 시간·축약 경로·축약 브랜치를 표시한다.
time_seg="${GREEN}${NOW_CLOCK}${RST}"
path_seg=$(shorten_path "$cwd")
line_loc="${time_seg} ${path_seg}"
[ -n "$branch" ] && line_loc="${line_loc} ${MAGENTA}${BRANCH_GLYPH}$(shorten_branch "$branch")${RST}"

# 둘째 행은 계정과 인증만 표시한다.
line_meta=""
append_meta "$(format_cc_account)"
append_meta "$(format_gh)"
append_meta "$(format_aws)"

# ctx·5h·7d를 같은 라벨 폭과 같은 20칸 막대로 세로 정렬한다.
GW=4
model_str=$(format_model "$model_display")
effort_ind=$(format_effort "$effort")
line_ctx="$(dimlabel "$(ralign ctx "$GW")") $(format_context_full)"
[ -n "$model_str" ] && line_ctx="${line_ctx} ${CYAN}${model_str}${RST}"
[ -n "$effort_ind" ] && line_ctx="${line_ctx} ${effort_ind}"
line_5h=$(format_rate_full "$(ralign 5h "$GW")" "$five_h" "$five_reset" 18000)
line_7d=$(format_rate_full "$(ralign 7d "$GW")" "$week_h" "$week_reset" 604800)

SLASH=" ${DIM}/${RST} "
line_cost="$(dimlabel "$(ralign cost "$GW")") ${daily_seg}${SLASH}${weekly_seg}${SLASH}${monthly_seg}"

# 푸터는 버전과 복사 가능한 전체 세션 ID를 보존한다.
line_foot=""
[ -n "$version" ] && line_foot="$(dimlabel "v${version}")"
if [ -n "$session_id" ]; then
  [ -n "$line_foot" ] && line_foot="${line_foot} "
  line_foot="${line_foot}${GREY240}${SESSION_GLYPH} ${session_id}${RST}"
fi

output=$(emit "$line_loc" "$line_meta" "$line_ctx" "$line_5h" "$line_7d" "$line_cost" "$line_foot")
