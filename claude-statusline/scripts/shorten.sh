#!/bin/sh
set -eu
# ═══════════════════════════════════════════════════════════════
# Shared shortening utility for paths and branch names
# Usage: shorten.sh [--ansi|--plain] <path|branch> <value>
#
# Subcommands:
#   path   <dir-path>     Shorten a directory path
#   branch <branch-name>  Shorten a git branch name
#
# Options:
#   --ansi   ANSI escape color codes (for statusline)
#   --plain  No color codes (default, for zsh prompt)
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────
# Color Mode
# ─────────────────────────────────────────────────────────────────
COLOR_MODE="plain"
while [ $# -gt 0 ]; do
  case "$1" in
    --ansi)  COLOR_MODE="ansi"; shift ;;
    --plain) COLOR_MODE="plain"; shift ;;
    --*)     shift ;;
    *)       break ;;
  esac
done

if [ "$COLOR_MODE" = "ansi" ]; then
  C_RESET=$(printf '\033[0m')
  C_DIM=$(printf '\033[2m')
  C_BLUE=$(printf '\033[34m')
else
  C_RESET="" C_DIM="" C_BLUE=""
fi

strip_control() {
  LC_ALL=C printf '%s' "$1" | tr -d '\000-\037\177'
}

# ─────────────────────────────────────────────────────────────────
# shorten_path: Shorten a directory path
# ─────────────────────────────────────────────────────────────────
# Rules:
#   1. Non-root home directory → ~; root HOME remains absolute
#   2. Absolute path (outside home) → first folder shown
#   3. All git repo names (including nested submodules)
#   4. Current folder
#   5. Gaps → ↪N (N = skipped count)
# Colors (ansi mode):
#   - Git repo names / current folder: blue
#   - Rest: dim
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

  # Preserve path boundaries, and keep root HOME absolute so every path does not appear under ~.
  if [ -n "$home" ] && [ "$home" != "/" ]; then
    case "$full_path" in
      "$home") display_path="~"; is_home_path=true ;;
      "$home"/*) display_path="~${full_path#"$home"}"; is_home_path=true ;;
    esac
  fi

  # 2. Detect and strip leading / (restored in output)
  case "$display_path" in
    /*) starts_with_slash=true; display_path="${display_path#/}" ;;
  esac

  # 3. Collect git repo paths (colon-delimited full paths for O(1) lookup).
  #    Match by full path, not basename: a non-repo directory that merely shares a repo's
  #    name (e.g. a `.worktrees/<repo>` container next to the real `<repo>`) must not be
  #    mistaken for a repo. Basename matching flagged such collisions as false positives.
  local git_repos=":" check_path="$full_path"
  while [ "$check_path" != "/" ] && [ "$check_path" != "${home:-/}" ]; do
    if [ -d "$check_path/.git" ] || [ -f "$check_path/.git" ]; then
      git_repos="${git_repos}${check_path}:"
    fi
    check_path=$(dirname "$check_path")
  done

  # 4. Split by / into positional params (1-indexed)
  local old_ifs="$IFS"
  IFS='/'
  set -f
  # shellcheck disable=SC2086
  set -- $display_path
  set +f
  IFS="$old_ifs"
  local total=$#

  # 5. Short path: display as-is
  #    Original ≤3 threshold included empty first element for absolute paths
  local threshold=3
  $starts_with_slash && threshold=2
  if [ "$total" -le "$threshold" ]; then
    local full_display="$display_path"
    $starts_with_slash && full_display="/$display_path"
    printf '%s%s%s\n' "$C_DIM" "$full_display" "$C_RESET"
    return
  fi

  # 6. Single-pass assembly
  local joined="" prev_shown=0 first_seg=true
  local i=1 p="" is_repo show acc=""
  while [ "$i" -le "$total" ]; do
    eval "p=\${$i}"

    # Rebuild this segment's absolute path so git-repo membership is tested by full path
    # (see step 3). Segment 1 anchors on HOME (~), a leading slash, or a relative root.
    if [ "$i" -eq 1 ]; then
      if $is_home_path; then acc="$home"
      elif $starts_with_slash; then acc="/$p"
      else acc="$p"; fi
    else
      acc="${acc%/}/$p"
    fi

    # Check if this is a git repo (full-path match)
    is_repo=false
    case "$git_repos" in *":$acc:"*) is_repo=true ;; esac

    # Determine visibility
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

      # Gap indicator
      if [ $((i - prev_shown)) -gt 1 ]; then
        joined="${joined}${C_DIM}↪$((i - prev_shown - 1))${C_RESET}${C_DIM}/${C_RESET}"
      fi

      # Color: git repos and last → blue, rest → dim
      if [ "$i" -eq "$total" ] || $is_repo; then
        joined="${joined}${C_BLUE}${p}${C_RESET}"
      else
        joined="${joined}${C_DIM}${p}${C_RESET}"
      fi
      prev_shown=$i
    fi

    i=$((i + 1))
  done

  # Prepend / for absolute paths
  if $starts_with_slash; then
    printf '%s/%s%s\n' "$C_DIM" "$C_RESET" "$joined"
  else
    printf '%s\n' "$joined"
  fi
}

# ─────────────────────────────────────────────────────────────────
# shorten_branch: Shorten a git branch slug
# ─────────────────────────────────────────────────────────────────
# Pattern: {prefix/}{TICKET-ID-}{slug}
# Slug shortening (max_words=4):
#   == max_words → first 1 + ↪(skipped) + last 1
#   >  max_words → first 2 + ↪(skipped) + last 2
shorten_branch() {
  local branch
  branch=$(strip_control "$1")
  local max_words=4
  local prefix="" ticket="" slug="" rest=""

  # Extract prefix
  case "$branch" in
    feature/*|hotfix/*|bugfix/*|release/*|change/*)
      prefix="${branch%%/*}/"
      rest="${branch#*/}"
      ;;
    *) rest="$branch" ;;
  esac

  # Extract ticket ID (e.g., PROJ-123-)
  ticket=$(expr "$rest" : '\([A-Z][A-Z]*-[0-9][0-9]*-\)' 2>/dev/null) || ticket=""
  if [ -n "$ticket" ]; then
    slug="${rest#"$ticket"}"
  else
    slug="$rest"
  fi

  # Split slug by - using positional parameters
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

# ─────────────────────────────────────────────────────────────────
# Main: Dispatch subcommand
# ─────────────────────────────────────────────────────────────────
case "$1" in
  path)   shorten_path "$2" ;;
  branch) shorten_branch "$2" ;;
  *)      printf 'Usage: shorten.sh [--ansi|--plain] <path|branch> <value>\n' >&2; exit 1 ;;
esac
