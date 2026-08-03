#!/bin/sh
# 폭 80 이하의 세 행 압축 레이아웃. statusline.sh 가 공통 상태와 함수를 준비한 뒤 불러 쓴다.
# 공유 helper 이므로 호출자의 셸 옵션을 바꾸지 않는다.

format_context_compact() {
  set_context_gauge
  printf '%s %s%d%%%s' "$(dimlabel ctx)" "$CONTEXT_COLOR" "$CONTEXT_PCT" "$RST"
}

format_rate_compact() {
  local label="$1" pct_raw="$2" reset="$3" window="${4:-}"
  [ -z "$pct_raw" ] && return 0
  set_rate_gauge "$pct_raw" "$reset" "$window"
  local pace="" reset_str=""
  [ -n "$RATE_PACE_COLOR" ] && pace="${RATE_PACE_COLOR}▲${RST}"
  [ -n "$reset" ] && reset_str=" ${DIM}$(format_reset "$reset")${RST}"
  printf '%s %s%d%%%s%s%s' \
    "$(dimlabel "$label")" "$RATE_COLOR" "$RATE_PCT" "$RST" "$pace" "$reset_str"
}

# 첫 행의 고정 폭은 시각 5칸과 공백 1칸이다. 브랜치가 있으면 공백과 아이콘 2칸을
# 추가로 빼고, 남은 예산을 경로와 브랜치가 나눠 쓴다.
time_seg="${GREEN}${NOW_CLOCK}${RST}"
path_seg=$(shorten_path "$cwd")
branch_name=""
[ -n "$branch" ] && branch_name=$(shorten_branch "$branch")
if [ -n "$branch_name" ]; then fit_budget=$((status_width - 8))
else fit_budget=$((status_width - 6))
fi
[ "$fit_budget" -lt 1 ] && fit_budget=1

# 절단 실패는 미절단 표시로 저하한다. 빈 둘째 줄은 명령 치환이 제거할 수 있으므로 read 직전에
# 두 변수를 비워, EOF가 이전 값을 남기지 않게 한다.
if _fit=$(printf '%s\n%s\n' "$path_seg" "$branch_name" \
  | LC_ALL=C awk -v budget="$fit_budget" -f "$PLUGIN_ROOT/scripts/fit-line1.awk" 2>/dev/null); then
  path_seg=""
  branch_name=""
  { IFS= read -r path_seg || true; IFS= read -r branch_name || true; } <<FITOUT
$_fit
FITOUT
fi

line_loc="${time_seg} ${path_seg}"
[ -n "$branch_name" ] && line_loc="${line_loc} ${MAGENTA}${BRANCH_GLYPH}${branch_name}${RST}"

# 둘째 행은 계정·인증·버전·세션 접두를 모은다.
line_meta=""
append_meta "$(format_cc_account)"
append_meta "$(format_gh)"
append_meta "$(format_aws)"
[ -n "$version" ] && append_meta "$(dimlabel "v${version}")"
if [ -n "$session_id" ]; then
  if [ "${#session_id}" -lt 6 ]; then sid6="$session_id"
  else sid6="${session_id%"${session_id#??????}"}"
  fi
  append_meta "${GREY240}${SESSION_GLYPH} ${sid6}${RST}"
fi

# 셋째 행은 막대 없이 ctx·모델·effort·5h·7d를 이어 붙인다.
model_str=$(format_model "$model_display")
effort_ind=$(format_effort "$effort")
line_ctx=$(format_context_compact)
[ -n "$model_str" ] && line_ctx="${line_ctx} ${CYAN}${model_str}${RST}"
[ -n "$effort_ind" ] && line_ctx="${line_ctx} ${effort_ind}"
line_5h=$(format_rate_compact 5h "$five_h" "$five_reset" 18000)
line_7d=$(format_rate_compact 7d "$week_h" "$week_reset" 604800)
line_gauge="$line_ctx"
[ -n "$line_5h" ] && line_gauge="${line_gauge} ${line_5h}"
[ -n "$line_7d" ] && line_gauge="${line_gauge} ${line_7d}"

output=$(emit "$line_loc" "$line_meta" "$line_gauge")
