#!/bin/sh
# 소스 가능한 축약 함수 모음. 경로·브랜치 축약과 제어문자 제거를 제공한다.
# 이 파일은 `.`으로 불러 쓴다. set -eu 같은 셸 옵션을 호출자에 강제하지 않는다.
# 색 변수 C_RESET·C_DIM·C_BLUE 는 호출자가 정의한다(미정의면 빈 문자열로 두어야 한다).
#
# 수정 시 검토 관점: 이 함수들은 statusline.sh(in-process)와 shorten.sh(CLI 래퍼) 두
# 호출자가 공유한다. 색 변수 이름과 함수 시그니처는 두 호출자와의 계약이므로 바꿀 때 둘 다 본다.

strip_control() {
  LC_ALL=C printf '%s' "$1" | tr -d '\000-\037\177'
}

shorten_path() {
  local full_path
  full_path=$(strip_control "$1")
  local home="${HOME:-}"
  local is_home_path=false
  local display_path="$full_path"
  local starts_with_slash=false

  while [ "$home" != "/" ] && [ "${home%/}" != "$home" ]; do
    home=${home%/}
  done

  if [ -n "$home" ] && [ "$home" != "/" ]; then
    case "$full_path" in
      "$home") display_path="~"; is_home_path=true ;;
      "$home"/*) display_path="~${full_path#"$home"}"; is_home_path=true ;;
    esac
  fi

  case "$display_path" in
    /*) starts_with_slash=true; display_path="${display_path#/}" ;;
  esac

  local git_repos=":" check_path="$full_path"
  while [ "$check_path" != "/" ] && [ "$check_path" != "${home:-/}" ]; do
    if [ -d "$check_path/.git" ] || [ -f "$check_path/.git" ]; then
      git_repos="${git_repos}${check_path}:"
    fi
    check_path=$(dirname "$check_path")
  done

  local old_ifs="$IFS"
  IFS='/'
  set -f
  # shellcheck disable=SC2086
  set -- $display_path
  set +f
  IFS="$old_ifs"
  local total=$#

  local threshold=3
  $starts_with_slash && threshold=2
  if [ "$total" -le "$threshold" ]; then
    local full_display="$display_path"
    $starts_with_slash && full_display="/$display_path"
    printf '%s%s%s\n' "$C_DIM" "$full_display" "$C_RESET"
    return
  fi

  local joined="" prev_shown=0 first_seg=true
  local i=1 p="" is_repo show acc=""
  while [ "$i" -le "$total" ]; do
    eval "p=\${$i}"

    if [ "$i" -eq 1 ]; then
      if $is_home_path; then acc="$home"
      elif $starts_with_slash; then acc="/$p"
      else acc="$p"; fi
    else
      acc="${acc%/}/$p"
    fi

    is_repo=false
    case "$git_repos" in *":$acc:"*) is_repo=true ;; esac

    show=false
    if [ "$i" -eq 1 ]; then show=true; fi
    if [ "$i" -eq "$total" ]; then show=true; fi
    $is_repo && show=true

    if $show; then
      if $first_seg; then
        first_seg=false
      else
        joined="${joined}${C_DIM}/${C_RESET}"
      fi

      if [ $((i - prev_shown)) -gt 1 ]; then
        joined="${joined}${C_DIM}↪$((i - prev_shown - 1))${C_RESET}${C_DIM}/${C_RESET}"
      fi

      if [ "$i" -eq "$total" ] || $is_repo; then
        joined="${joined}${C_BLUE}${p}${C_RESET}"
      else
        joined="${joined}${C_DIM}${p}${C_RESET}"
      fi
      prev_shown=$i
    fi

    i=$((i + 1))
  done

  if $starts_with_slash; then
    printf '%s/%s%s\n' "$C_DIM" "$C_RESET" "$joined"
  else
    printf '%s\n' "$joined"
  fi
}

shorten_branch() {
  local branch
  branch=$(strip_control "$1")
  local max_words=4
  local prefix="" ticket="" slug="" rest=""

  case "$branch" in
    feature/*|hotfix/*|bugfix/*|release/*|change/*)
      prefix="${branch%%/*}/"
      rest="${branch#*/}"
      ;;
    *) rest="$branch" ;;
  esac

  ticket=$(expr "$rest" : '\([A-Z][A-Z]*-[0-9][0-9]*-\)' 2>/dev/null) || ticket=""
  if [ -n "$ticket" ]; then
    slug="${rest#"$ticket"}"
  else
    slug="$rest"
  fi

  local old_ifs="$IFS"
  IFS='-'
  set -f
  # shellcheck disable=SC2086
  set -- $slug
  set +f
  IFS="$old_ifs"
  local word_count=$#

  if [ "$word_count" -eq "$max_words" ]; then
    local first="$1"
    shift $(($# - 1))
    slug="${first}-↪$((word_count - 2))-$1"
  elif [ "$word_count" -gt "$max_words" ]; then
    local first="$1" second="$2"
    shift $(($# - 2))
    slug="${first}-${second}-↪$((word_count - 4))-$1-$2"
  fi

  printf '%s\n' "${prefix}${ticket}${slug}"
}
