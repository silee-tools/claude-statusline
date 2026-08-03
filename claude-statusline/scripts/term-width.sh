#!/bin/sh
# 터미널 폭 감지. `.` 으로 불러 쓴다 — 독립 프로세스로 실행하지 않는다.
# 이 파일은 set -eu 등 셸 옵션을 호출자에 강제하지 않는다.
# CACHE_DIR 은 호출자(statusline.sh)가 정의한다. shorten-lib.sh 의 색 변수 관례와 같다 —
# 호출자가 정의하지 않았거나 그 디렉터리에 쓸 수 없으면 캐싱 없이 감지만 수행한다.
#
# 수정 시 검토 관점:
#   - 폭을 못 정하면 반드시 빈 문자열을 낸다. 임의 기본값(80 등)으로 채우면 호출자가
#     "판정 불가"와 "실제로 그 칸수"를 구분하지 못해, 판정 불가 시 정보 손실 없는 넓은
#     레이아웃을 쓰는 상위 계약이 깨진다.
#   - 캐시는 tty 경로만 담는다. 창 크기는 폭이 바뀌었는지 매 렌더 새로 읽어야 하므로
#     캐시하지 않는다. 경로를 캐시하는 이유는 그 경로를 얻는 ps 호출 비용만 없애기
#     위해서다.
#   - 캐시 키는 부모 pid 다. 세션 동안 안정적이라 재검증 없이 재사용해도 안전하다.
#   - 캐시된 경로로 창 크기 조회가 실패하면(터미널이 이미 닫힘) 그 캐시 항목을 지운다.
#     지우지 않으면 다음 렌더도 같은 죽은 경로를 재사용해 계속 빈 결과만 낸다.

term_width() {
  # 1) 주입된 오버라이드: 숫자로만 이뤄지면 그대로 쓰고 끝낸다. 숫자가 아니면 무시하고
  #    프로브로 진행한다(오류로 죽지 않는다) — 테스트가 폭을 강제하는 수단이자
  #    사용자가 레이아웃을 고정하는 탈출구다.
  case "${CLAUDE_STATUSLINE_WIDTH:-}" in
    '') ;;
    *[!0-9]*) ;;
    *) printf '%s' "$CLAUDE_STATUSLINE_WIDTH"; return 0 ;;
  esac

  local ppid="$PPID"
  local cache="" tty_path=""
  [ -n "${CACHE_DIR:-}" ] && cache="$CACHE_DIR/tty-path.env"

  # 2) 캐시된 경로가 이번 부모 pid 것이면 ps 호출 없이 그대로 쓴다.
  if [ -n "$cache" ] && [ -f "$cache" ]; then
    local _c_ppid="" _c_path=""
    while IFS='=' read -r _k _v; do
      case "$_k" in
        ppid) _c_ppid="$_v" ;;
        path) _c_path="$_v" ;;
      esac
    done < "$cache"
    [ "$_c_ppid" = "$ppid" ] && tty_path="$_c_path"
  fi

  if [ -z "$tty_path" ]; then
    # 부모부터 최대 4단계까지 조상을 올라가며 tty 를 가진 프로세스를 찾는다. ps 는
    # tty 가 없으면 "??" 를 낸다. 래퍼가 하나 끼어 있을 수 있어 부모 한 단계만 보지
    # 않는다.
    local pid="$ppid" depth=0 line ptty pparent
    while [ "$depth" -lt 4 ]; do
      depth=$((depth + 1))
      line=$(ps -o tty=,ppid= -p "$pid" 2>/dev/null) || break
      [ -z "$line" ] && break
      ptty=$(printf '%s' "$line" | awk '{print $1}')
      pparent=$(printf '%s' "$line" | awk '{print $2}')
      if [ -n "$ptty" ] && [ "$ptty" != "??" ]; then
        tty_path="/dev/$ptty"
        break
      fi
      [ -z "$pparent" ] && break
      pid="$pparent"
    done

    if [ -n "$tty_path" ] && [ -n "$cache" ]; then
      if mkdir -p "$CACHE_DIR" 2>/dev/null; then
        {
          printf 'ppid=%s\n' "$ppid"
          printf 'path=%s\n' "$tty_path"
        } > "$cache" 2>/dev/null || true
      fi
    fi
  fi

  # 3) 조상 사슬 어디에도 tty 가 없으면 판정 불가.
  [ -z "$tty_path" ] && return 0

  local size cols
  if ! size=$(stty -f "$tty_path" size 2>/dev/null); then
    [ -n "$cache" ] && rm -f "$cache" 2>/dev/null
    return 0
  fi
  cols=$(printf '%s' "$size" | awk '{print $2}')
  case "$cols" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$cols"
}
