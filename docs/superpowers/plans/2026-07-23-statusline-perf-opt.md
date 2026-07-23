# statusline 극한 최적화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 매 렌더 실행되는 `statusline.sh`의 벽시계 시간을, POSIX sh 계약과 표시 기능을 그대로 둔 채 프로세스 fork를 줄여 최소화한다.

**Architecture:** 축약 로직을 소스 가능한 lib으로 분리해 statusline이 서브프로세스 없이 in-process로 호출하고, 함수 내부의 `dirname`·`expr`·`sed` fork를 파라미터 확장으로 없앤다. git 브랜치·Claude 계정·AWS 만료는 권위 있는 출처를 유지한 채 캐싱하되, 무효화 신호는 각각 HEAD 파일 첫 줄 내용(내장 `read`)과 파일 최신성(`test -nt`)으로 fork 없이 판정한다. 현재 시각은 렌더 앞에서 한 번만 얻어 공유한다.

**Tech Stack:** POSIX sh, git, awk, date.

## Global Constraints

- 모든 셸 스크립트는 POSIX sh(`#!/bin/sh`)다. 실행 진입점은 `set -eu`를 쓰고, `.`으로 불러오는 공유 helper는 호출자의 셸 옵션을 강제하지 않는다.
- bashism 금지: `[[ ]]`, 배열, `=~`/`BASH_REMATCH`, `${var,,}`, `<<<`, `(( ))`, `function foo()`.
- 표시 항목·레이아웃·색·막대를 바꾸지 않는다. 출력은 모든 상태에서 지금과 동일해야 한다.
- `gh@<account>` 매핑 등 설정은 소스에 박지 않는다. 계정명·라벨·색을 스크립트에 하드코딩하지 않는다.
- 기능 변경 시 `claude-statusline/.claude-plugin/plugin.json`과 `.claude-plugin/marketplace.json`의 plugin 항목 `version`을 같은 값으로 올린다. 현재 `2.10.0` → `2.11.0`.
- 커밋은 Conventional Commits를 따른다.
- 테스트는 Red → Green. 동작을 바꾸기 전에 실패하는 테스트를 먼저 추가한다. 테스트 fixture에 실존 인물·계정·시크릿을 넣지 않는다. 주소가 필요하면 `@example.com`을 쓴다.

## File Structure

- `claude-statusline/scripts/shorten-lib.sh` (신규): 소스 가능한 축약 함수 모음. `strip_control`, `shorten_path`, `shorten_branch`. 색 변수는 정의하지 않고 호출자가 `C_RESET`/`C_DIM`/`C_BLUE`를 미리 정의한다는 계약으로 참조한다.
- `claude-statusline/scripts/shorten.sh` (수정): lib을 `.`으로 불러온 뒤 색 모드를 파싱하고 하위 명령을 분기하는 얇은 CLI 래퍼. zsh 프롬프트가 쓰는 CLI 인자 계약은 그대로.
- `claude-statusline/scripts/statusline.sh` (수정): lib 소스, in-process 축약, 캐싱, 단일 date, sed 없는 모델 파싱.
- `claude-statusline/tests/statusline.test.sh` (수정): `shorten-lib.sh` 심볼릭 링크 추가, 회귀 테스트 추가.
- `claude-statusline/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (수정): 버전 번프.

---

## Task 1: 축약 함수를 소스 가능한 lib으로 분리하고 shorten.sh를 얇은 래퍼로

**Files:**
- Create: `claude-statusline/scripts/shorten-lib.sh`
- Modify: `claude-statusline/scripts/shorten.sh`
- Test: `claude-statusline/tests/statusline.test.sh` (심볼릭 링크 추가)

**Interfaces:**
- Produces: 소스 가능한 함수 `strip_control(value)`, `shorten_path(dir)`, `shorten_branch(name)`. 각 함수는 색 변수 `C_RESET`/`C_DIM`/`C_BLUE`가 환경에 정의돼 있다고 가정하고 참조한다(미정의면 빈 문자열로 동작하도록 호출자가 설정).

이 태스크는 동작을 바꾸지 않는 리팩터다. 기존 테스트(shorten CLI 테스트 T6·T30 등, statusline 렌더 테스트)가 그대로 통과하는 것이 성공 기준이다.

- [ ] **Step 1: 테스트 하니스에 shorten-lib.sh 심볼릭 링크를 추가한다**

`tests/statusline.test.sh`에서 기존 심볼릭 링크 블록(`ln -sf "$SRC/scripts/statusline.sh" ...` 부근, 약 32~34행)에 한 줄을 더한다.

```sh
ln -sf "$SRC/scripts/statusline.sh" "$TMPROOT/scripts/statusline.sh"
ln -sf "$SRC/scripts/shorten.sh" "$TMPROOT/scripts/shorten.sh"
ln -sf "$SRC/scripts/shorten-lib.sh" "$TMPROOT/scripts/shorten-lib.sh"
ln -sf "$SRC/scripts/json.awk" "$TMPROOT/scripts/json.awk"
```

- [ ] **Step 2: 리팩터 전 baseline 테스트가 통과하는지 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=101 fail=0` (심볼릭 링크만 추가했고 lib은 아직 없으므로 shorten.sh는 변경 전이라 통과)

- [ ] **Step 3: shorten-lib.sh를 만든다 (기존 함수를 그대로 옮김, 동작 불변)**

현재 `shorten.sh`의 `strip_control`(37~39행), `shorten_path`(53~167행), `shorten_branch`(176~220행)를 그대로 옮긴다. 색 변수는 lib에서 정의하지 않는다(호출자 계약). 파일 전체:

```sh
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
```

- [ ] **Step 4: shorten.sh를 lib 소스 + 색 정의 + 분기만 하는 래퍼로 바꾼다**

`shorten.sh` 전체를 아래로 교체한다. 함수 정의는 lib으로 옮겼으므로 여기서는 사라진다.

```sh
#!/bin/sh
set -eu
# ═══════════════════════════════════════════════════════════════
# Shared shortening utility for paths and branch names (CLI wrapper)
# Usage: shorten.sh [--ansi|--plain] <path|branch> <value>
#
# 함수 본체는 shorten-lib.sh 에 있다. 이 래퍼는 색 모드를 정하고 lib 을 소스한 뒤
# 하위 명령을 분기한다. statusline.sh 는 이 CLI 대신 lib 을 직접 소스해 in-process 로 쓴다.
# ═══════════════════════════════════════════════════════════════

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

. "$(dirname "$0")/shorten-lib.sh"

case "$1" in
  path)   shorten_path "$2" ;;
  branch) shorten_branch "$2" ;;
  *)      printf 'Usage: shorten.sh [--ansi|--plain] <path|branch> <value>\n' >&2; exit 1 ;;
esac
```

- [ ] **Step 5: 전체 테스트로 동작 불변을 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=101 fail=0` (리팩터라 기존 테스트 전부 통과)

- [ ] **Step 6: 커밋**

```bash
git add claude-statusline/scripts/shorten-lib.sh claude-statusline/scripts/shorten.sh claude-statusline/tests/statusline.test.sh
git commit -m "refactor(statusline): extract shorten functions into sourceable lib"
```

---

## Task 2: 축약 함수 내부의 fork 제거 (dirname·expr)

**Files:**
- Modify: `claude-statusline/scripts/shorten-lib.sh`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: Task 1의 `shorten_path`, `shorten_branch`.
- Produces: 시그니처 동일, 내부 fork만 제거된 같은 함수.

`shorten_path`의 상위 탐색 루프가 쓰는 `dirname`을 파라미터 확장으로 바꾼다. `${var%/*}`는 슬래시 없는 문자열을 줄이지 못해 무한 루프가 되므로, 슬래시 유무를 `case`로 가르는 가드를 함께 둔다. `shorten_branch`의 `expr` 티켓 추출은 `case` 패턴으로 바꾼다.

- [ ] **Step 1: 무한 루프 가드 회귀 테스트를 먼저 추가한다 (Red)**

`tests/statusline.test.sh`의 shorten CLI 테스트 구역(약 415~446행, `HOME=... sh "$TMPROOT/scripts/shorten.sh" --plain path ...` 묶음) 끝에 추가한다. 슬래시 없는 상대 경로 세그먼트를 줘도 축약이 정상 종료하고 값을 반환하는지 확인한다.

```sh
# --- T32: 슬래시 없는 세그먼트에서 상위탐색이 무한 루프에 빠지지 않는다 ---
#   dirname 을 ${var%/*} 로 바꾸면 슬래시 없는 문자열이 안 줄어 무한 루프가 될 수 있다.
#   상대경로(선행 슬래시 없음)로 호출해 정상 종료와 출력 존재를 확인한다.
OUT=$(HOME=/nonexistent-home sh "$TMPROOT/scripts/shorten.sh" --plain path "aaa/bbb/ccc/ddd/eee")
assert_contains "T32 슬래시 없는 선행 세그먼트 정상 종료" "eee" "$OUT"
```

- [ ] **Step 2: 테스트를 실행해 현재 통과하는지 본다 (기준선)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T32|TOTAL'`
Expected: `PASS T32 ...`와 `TOTAL pass=102 fail=0`. 이 테스트는 현재 `dirname` 구현에서도 통과한다. 이 태스크의 목적은 fork 제거 후에도 이 안전성이 유지됨을 보장하는 것이므로, 회귀 가드로 남긴다.

- [ ] **Step 3: shorten_path의 dirname을 파라미터 확장 + 가드로 바꾼다**

`shorten-lib.sh`의 상위 탐색 루프를 교체한다.

기존:
```sh
  local git_repos=":" check_path="$full_path"
  while [ "$check_path" != "/" ] && [ "$check_path" != "${home:-/}" ]; do
    if [ -d "$check_path/.git" ] || [ -f "$check_path/.git" ]; then
      git_repos="${git_repos}${check_path}:"
    fi
    check_path=$(dirname "$check_path")
  done
```

교체:
```sh
  local git_repos=":" check_path="$full_path"
  while [ "$check_path" != "/" ] && [ "$check_path" != "${home:-/}" ]; do
    if [ -d "$check_path/.git" ] || [ -f "$check_path/.git" ]; then
      git_repos="${git_repos}${check_path}:"
    fi
    # dirname 대체(fork 0). ${var%/*} 는 슬래시가 없으면 문자열을 줄이지 못해 무한 루프가
    # 되므로, 슬래시 유무를 case 로 가른다. 슬래시가 없거나 결과가 비면 루트로 수렴시켜 종료한다.
    case "$check_path" in
      */*) check_path="${check_path%/*}"; [ -z "$check_path" ] && check_path="/" ;;
      *)   check_path="/" ;;
    esac
  done
```

- [ ] **Step 4: shorten_branch의 expr를 case로 바꾼다**

기존:
```sh
  ticket=$(expr "$rest" : '\([A-Z][A-Z]*-[0-9][0-9]*-\)' 2>/dev/null) || ticket=""
  if [ -n "$ticket" ]; then
    slug="${rest#"$ticket"}"
  else
    slug="$rest"
  fi
```

교체(선행 대문자 토큰 `PROJ-123-` 형태를 파라미터 확장으로 추출; fork 0):
```sh
  # 티켓 접두(예: PROJ-123-) 추출. expr 대체(fork 0).
  # rest 가 "대문자들-숫자들-" 로 시작하면 그 접두를 ticket 으로 떼어 낸다.
  ticket=""
  local _head="${rest%%-*}"                 # 첫 하이픈 전(프로젝트 키 후보)
  case "$_head" in
    ''|*[!A-Z]*) : ;;                        # 대문자로만 이뤄지지 않으면 티켓 아님
    *)
      local _afterkey="${rest#"$_head"-}"    # 키와 첫 하이픈 제거
      if [ "$_afterkey" != "$rest" ]; then
        local _num="${_afterkey%%-*}"        # 다음 하이픈 전(번호 후보)
        case "$_num" in
          ''|*[!0-9]*) : ;;                  # 숫자로만 이뤄지지 않으면 티켓 아님
          *)
            local _afternum="${_afterkey#"$_num"-}"
            [ "$_afternum" != "$_afterkey" ] && ticket="${_head}-${_num}-"
            ;;
        esac
      fi
      ;;
  esac
  if [ -n "$ticket" ]; then
    slug="${rest#"$ticket"}"
  else
    slug="$rest"
  fi
```

- [ ] **Step 5: 전체 테스트로 동작 불변 + 무한루프 가드를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=102 fail=0`. 특히 티켓 축약 관련 기존 테스트(있다면)와 T32가 통과한다.

- [ ] **Step 6: 티켓 접두 축약이 실제로 유지되는지 수동 확인한다**

Run:
```bash
HOME=/x sh claude-statusline/scripts/shorten.sh --plain branch "PROJ-123-alpha-beta-gamma-delta-epsilon"
```
Expected: 접두 `PROJ-123-`가 보존되고 슬러그가 축약된 문자열(예: `PROJ-123-alpha-beta-↪...-delta-epsilon` 형태). expr 제거 전 출력과 동일해야 한다.

- [ ] **Step 7: 커밋**

```bash
git add claude-statusline/scripts/shorten-lib.sh claude-statusline/tests/statusline.test.sh
git commit -m "perf(statusline): replace dirname/expr forks with parameter expansion in shorten-lib"
```

---

## Task 3: statusline.sh가 lib을 소스해 in-process로 축약

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh`
- Test: `claude-statusline/tests/statusline.test.sh` (기존 렌더 테스트로 검증)

**Interfaces:**
- Consumes: `shorten-lib.sh`의 `strip_control`, `shorten_path`, `shorten_branch`.
- Produces: 동작 불변. `sh shorten.sh` 서브프로세스 호출 제거.

statusline.sh는 자체 `strip_control`(91~93행)과 색 변수를 이미 정의한다. lib이 요구하는 색 변수 이름은 `C_RESET`/`C_DIM`/`C_BLUE`이므로, lib을 소스하기 전에 이 이름으로 매핑해 정의한다. statusline의 기존 `strip_control`은 lib의 것과 동일하므로 lib 소스로 대체한다.

- [ ] **Step 1: statusline.sh에서 lib을 소스하고 색 변수를 매핑한다**

`SHORTEN_CMD`·`JSON_CMD` 정의부(26~29행) 부근을 수정한다. 기존:
```sh
# --- 축약 스크립트 ---
SHORTEN_CMD="$PLUGIN_ROOT/scripts/shorten.sh"

# --- stdin JSON (한번에 파싱) ---
JSON_CMD="$PLUGIN_ROOT/scripts/json.awk"
```

교체(lib이 쓰는 색 변수 이름으로 매핑한 뒤 소스; shorten.sh CLI 경로 상수는 제거):
```sh
# --- stdin JSON (한번에 파싱) ---
JSON_CMD="$PLUGIN_ROOT/scripts/json.awk"

# --- 축약 함수(in-process) ---
# shorten-lib.sh 는 색 변수 C_RESET·C_DIM·C_BLUE 를 참조한다(ansi 모드 값). 여기서 매핑해
# 정의한 뒤 소스하면 statusline 이 서브프로세스 없이 shorten_path·shorten_branch 를 직접 쓴다.
C_RESET="$RST" C_DIM="$DIM" C_BLUE=$(printf '\033[34m')
. "$PLUGIN_ROOT/scripts/shorten-lib.sh"
```

- [ ] **Step 2: statusline.sh의 중복 strip_control 정의를 제거한다**

lib이 `strip_control`을 제공하므로 statusline.sh의 자체 정의(91~93행)를 삭제한다.

삭제 대상:
```sh
strip_control() {
  LC_ALL=C printf '%s' "$1" | tr -d '\000-\037\177'
}
```

주의: 이 삭제는 Step 1에서 lib을 소스한 뒤여야 유효하다. lib 소스가 파일 앞쪽(색 변수 정의 이후)에 오므로, 91행의 재정의를 지워도 lib 정의가 남는다.

- [ ] **Step 3: shorten_path·shorten_branch 래퍼를 in-process 호출로 바꾼다**

기존 래퍼(100~116행)는 `sh shorten.sh`를 서브프로세스로 부른다. lib 함수가 이미 같은 이름으로 정의됐으므로 래퍼 전체를 삭제한다.

삭제 대상:
```sh
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
```

조립부(약 400~402행)는 `$(shorten_path "$cwd")`·`$(shorten_branch "$branch")`를 그대로 호출하므로 변경이 없다. lib 함수가 개행으로 끝나는 값을 반환하는데 명령 치환 `$(...)`이 후행 개행을 제거하므로 기존 서브프로세스 호출과 결과가 같다.

- [ ] **Step 4: 전체 테스트로 동작 불변을 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=102 fail=0`

- [ ] **Step 5: 서브프로세스 제거를 정적으로 확인한다**

Run: `grep -n 'SHORTEN_CMD\|shorten.sh' claude-statusline/scripts/statusline.sh || echo "no shorten.sh subprocess refs"`
Expected: `no shorten.sh subprocess refs` (statusline이 더는 CLI를 부르지 않음)

- [ ] **Step 6: 커밋**

```bash
git add claude-statusline/scripts/statusline.sh
git commit -m "perf(statusline): call shorten functions in-process via sourced lib"
```

---

## Task 4: 현재 시각을 한 번만 얻어 공유

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh`
- Test: `claude-statusline/tests/statusline.test.sh` (기존 리셋·시각 테스트로 검증)

**Interfaces:**
- Produces: 전역 `NOW_EPOCH`(현재 epoch 초), `NOW_CLOCK`(HH:MM 문자열). `format_reset`·`format_rate`·`format_aws`·시간 세그먼트가 이 값을 공유한다.

- [ ] **Step 1: 렌더 앞에서 시각을 한 번 얻는다**

`input=$(cat)` 직후(31행 아래)에 추가한다.

```sh
# 현재 시각을 한 번만 얻어 리셋·rate·aws·시간 세그먼트가 공유한다(date fork 축소).
_now=$(date '+%s %H:%M')
NOW_EPOCH="${_now%% *}"
NOW_CLOCK="${_now#* }"
```

- [ ] **Step 2: format_reset이 공유 epoch를 쓰게 한다**

`format_reset`(189~204행)의 `now=$(date +%s)`를 제거하고 `NOW_EPOCH`를 쓴다.

기존:
```sh
format_reset() {
  local target="$1" now diff d h m
  now=$(date +%s)
  diff=$((target - now))
```
교체:
```sh
format_reset() {
  local target="$1" diff d h m
  diff=$((target - NOW_EPOCH))
```

- [ ] **Step 3: format_rate가 공유 epoch를 쓰게 한다**

`format_rate`(215~244행) 안의 페이스 계산부 `now=$(date +%s); diff=$((reset - now))`를 바꾼다.

기존:
```sh
    local now diff elapsed fill over
    now=$(date +%s); diff=$((reset - now)); [ "$diff" -lt 0 ] && diff=0
```
교체:
```sh
    local diff elapsed fill over
    diff=$((reset - NOW_EPOCH)); [ "$diff" -lt 0 ] && diff=0
```

- [ ] **Step 4: format_aws가 공유 epoch를 쓰게 한다**

`format_aws`(340~370행)의 `now=$(date +%s)`를 제거하고 `NOW_EPOCH`를 쓴다.

기존:
```sh
  local now exp_epoch remaining
  now=$(date +%s)
  local exp_norm
```
교체:
```sh
  local exp_epoch remaining
  local exp_norm
```
그리고 같은 함수 안 `remaining=$(( (exp_epoch - now) / 60 ))`를:
```sh
  remaining=$(( (exp_epoch - NOW_EPOCH) / 60 ))
```

- [ ] **Step 5: 시간 세그먼트가 공유 시계 문자열을 쓰게 한다**

조립부 `time_seg`(399행)를 바꾼다.

기존:
```sh
time_seg="${GREEN}$(date +%H:%M)${RST}"
```
교체:
```sh
time_seg="${GREEN}${NOW_CLOCK}${RST}"
```

- [ ] **Step 6: 전체 테스트로 리셋·시각 표기 불변을 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=102 fail=0`

- [ ] **Step 7: 커밋**

```bash
git add claude-statusline/scripts/statusline.sh
git commit -m "perf(statusline): capture current time once per render"
```

---

## Task 5: format_model에서 sed 제거

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Produces: `format_model(display_name)` — 시그니처·출력 불변, sed 호출 없음.

- [ ] **Step 1: 모델명 파싱 회귀 테스트를 먼저 추가한다 (Red 대비)**

`tests/statusline.test.sh`의 모델 관련 테스트(약 219행 `T7-model` 부근) 뒤에 추가한다. 이미 기존 테스트가 `ctx .*% Opus 4\.8`을 검증하므로 fixture 모델명 "Claude Opus 4.8"에 대한 커버리지는 있다. sed 제거 후에도 이 표기가 유지되는지 확인하는 가드를 명시적으로 하나 더 둔다.

```sh
# --- T33: 모델명 파싱이 sed 없이도 "이름 버전" 표기를 유지한다 ---
OUT=$(run "$(json_with)" 200)
assert_match "T33 모델 이름+버전 표기 유지" 'Opus 4\.8' "$OUT"
```

- [ ] **Step 2: 테스트가 현재 통과하는지 확인한다 (기준선)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T33|TOTAL'`
Expected: `PASS T33 ...`, `TOTAL pass=103 fail=0` (현재 sed 구현에서도 통과)

- [ ] **Step 3: format_model을 case/파라미터 확장으로 다시 쓴다**

`format_model`(118~132행) 전체를 교체한다.

```sh
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
    # 폴백: "Claude " 접두와 후행 " (...)" 를 떼어 원문을 최대한 보존한다.
    d="${d#Claude }"
    d="${d%% (*}"
    printf '%s' "$d"
  fi
}
```

- [ ] **Step 4: 전체 테스트로 동작 불변을 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=103 fail=0`

- [ ] **Step 5: 폴백 경로를 수동 확인한다**

Run:
```bash
printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Sonnet 4.5"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' | CLAUDE_PLUGIN_ROOT="$PWD/claude-statusline" sh claude-statusline/scripts/statusline.sh | sed 's/\x1b\[[0-9;]*m//g'
```
Expected: ctx 줄에 `Sonnet 4.5`가 보인다. 이름·버전 순서 파싱이 정상.

- [ ] **Step 6: 커밋**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "perf(statusline): parse model name without sed"
```

---

## Task 6: git 브랜치 캐시 (HEAD 내용 토큰, fork 없는 캐시 적중)

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Produces: 전역 변수 `branch`를 채우는 캐시 경로. 캐시 파일 `$CACHE_DIR/git-branch.env`에 `cwd`·`head`(HEAD 절대경로)·`token`(HEAD 첫 줄)·`branch`를 저장한다.

git을 진실의 원천으로 유지한다. 캐시 미스에서만 `git rev-parse --git-path HEAD --abbrev-ref HEAD`를 한 번 호출해 브랜치와 HEAD 경로를 얻고, 다음 렌더의 빠른 경로는 저장된 HEAD 파일의 첫 줄을 내장 `read`로 읽어 토큰과 비교한다(프로세스 없음). 토큰이 같으면 캐시 브랜치를 쓰고 git을 부르지 않는다.

- [ ] **Step 1: 캐시 동작을 관찰하는 회귀 테스트를 먼저 추가한다 (Red)**

`tests/statusline.test.sh` 끝부분(TOTAL 출력 직전)에 추가한다. 가짜 git을 PATH 앞에 두어 호출 여부를 기록하고, 캐시 적중 시 git이 불리지 않는지 확인한다. 기존 fixture의 `GITREPO`(브랜치 `wip`)를 재사용한다.

```sh
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
```

- [ ] **Step 2: 테스트를 실행해 실패를 확인한다 (Red)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T34|TOTAL'`
Expected: `T34 캐시 히트면 git 미호출`이 FAIL. 현재 statusline은 매 렌더 git을 부르므로 두 번째 렌더에서도 호출 기록이 남는다(`CALLS2` ≠ 0).

- [ ] **Step 3: git 브랜치 조회를 캐시 경로로 바꾼다**

`statusline.sh`의 git 브랜치 블록(372~378행)을 교체한다. `CACHE_DIR`는 비용 캐시 정의(249행 부근)에서 이미 `CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"`로 정의돼 있으므로 그 변수를 재사용한다. 단, 이 블록이 `CACHE_DIR` 정의보다 뒤(374행 > 249행)에 있으므로 순서 문제는 없다.

기존:
```sh
# --- git branch ---
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  branch=$(strip_control "$branch")
  [ "$branch" = "HEAD" ] && branch=""
fi
```

교체:
```sh
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
    { IFS= read -r _head_rel; IFS= read -r _br; } <<GITOUT
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
```

- [ ] **Step 4: 테스트를 실행해 통과를 확인한다 (Green)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T34|TOTAL'`
Expected: `PASS T34 ...`(4개), `TOTAL pass=107 fail=0`

- [ ] **Step 5: worktree 무손실을 수동 확인한다**

Run:
```bash
cd /tmp && rm -rf wtx && mkdir wtx && cd wtx && git init -q && git commit -q --allow-empty -m i
git worktree add -q /tmp/wtx-wt -b feat >/dev/null 2>&1
printf '{"workspace":{"current_dir":"/tmp/wtx-wt"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' | XDG_CACHE_HOME=/tmp/wtx-cache CLAUDE_PLUGIN_ROOT="$OLDPWD/claude-statusline" sh "$OLDPWD/claude-statusline/scripts/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g'
git worktree remove --force /tmp/wtx-wt; cd "$OLDPWD"; rm -rf /tmp/wtx /tmp/wtx-wt /tmp/wtx-cache
```
Expected: 출력 첫 줄에 브랜치 `feat`가 보인다. worktree(.git이 파일)에서도 브랜치가 정확히 표시됨.

- [ ] **Step 6: 커밋**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "perf(statusline): cache git branch via HEAD content token"
```

---

## Task 7: Claude 계정 이메일 캐시 (test -nt, fork 없는 적중)

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: 전역 `CACHE_DIR`.
- Produces: `format_cc_account`가 캐시 파일 `$CACHE_DIR/cc-account.env`(`email=`)를 읽고 쓴다. 무효화는 `~/.claude.json`이 캐시 파일보다 새 것인지(`test -nt`)로 판정한다.

- [ ] **Step 1: 캐시 동작 회귀 테스트를 먼저 추가한다 (Red)**

`tests/statusline.test.sh` 끝부분에 추가한다. `.claude.json`이 그대로면 캐시 파일이 생기고 이메일이 유지되며, `.claude.json`을 더 새 것으로 만들면 재스캔되는지 확인한다.

```sh
# --- T35: Claude 계정 이메일 캐시 ---
rm -f "$TMPROOT/cache/claude-statusline/cc-account.env"
OUT_A=$(run "$(json_with)" 200)
assert_contains "T35 이메일 첫 렌더 표시" "octocat@example.com" "$OUT_A"
assert_match    "T35 캐시 파일 생성" "email=octocat@example.com" "$(cat "$TMPROOT/cache/claude-statusline/cc-account.env" 2>/dev/null)"

# .claude.json 을 캐시보다 새 것으로 만들고 이메일을 바꾸면 다음 렌더에 반영된다(무손실).
sleep 1
printf '{"oauthAccount":{"emailAddress":"newuser@example.com"}}' > "$TMPROOT/.claude.json"
OUT_B=$(run "$(json_with)" 200)
assert_contains "T35 파일 변경 시 새 이메일 반영" "newuser@example.com" "$OUT_B"
# 원복
printf '{"oauthAccount":{"emailAddress":"octocat@example.com"}}' > "$TMPROOT/.claude.json"
```

- [ ] **Step 2: 테스트를 실행해 실패를 확인한다 (Red)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T35|TOTAL'`
Expected: `T35 캐시 파일 생성`이 FAIL(현재 캐시 파일을 안 만든다).

- [ ] **Step 3: format_cc_account를 캐시 경로로 바꾼다**

`format_cc_account`(322~336행)를 교체한다.

```sh
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
```

- [ ] **Step 4: 테스트를 실행해 통과를 확인한다 (Green)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T35|TOTAL'`
Expected: `PASS T35 ...`(3개), `TOTAL pass=110 fail=0`

- [ ] **Step 5: 커밋**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "perf(statusline): cache Claude account email keyed on config mtime"
```

---

## Task 8: AWS 만료 파싱 캐시 (test -nt)

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: 전역 `CACHE_DIR`, `NOW_EPOCH`.
- Produces: `format_aws`가 credentials 파일 파싱 결과(만료 epoch)를 `$CACHE_DIR/aws-exp.env`(`exp_epoch=`)에 캐시한다. 잔여 시간은 매 렌더 `NOW_EPOCH`로 다시 계산한다.

이 태스크는 `AWS_SESSION_EXPIRATION` 환경변수가 없을 때 credentials 파일을 sed·date로 파싱하는 비용만 캐시한다. saml2aws가 없으면 함수는 즉시 반환하므로 캐시도 없다.

- [ ] **Step 1: 파싱 결과 캐시가 만료 epoch를 저장하는지 회귀 테스트를 추가한다 (Red)**

이 경로는 saml2aws와 credentials 파일에 의존해 테스트 fixture 구성이 무겁다. 파싱 캐시의 존재만 확인하는 가벼운 테스트를 둔다. `AWS_SESSION_EXPIRATION`을 미래 시각으로 주면 파일 파싱 없이 그 값을 쓰므로, 이 경우 캐시 파일이 생기지 않아야 한다(파일 파싱 경로만 캐시). saml2aws 부재 환경에서는 건너뛴다.

```sh
# --- T36: AWS 만료 파싱 캐시 (파일 파싱 경로에서만 캐시) ---
if command -v saml2aws >/dev/null 2>&1; then
  rm -f "$TMPROOT/cache/claude-statusline/aws-exp.env"
  FUT=$(( $(date +%s) + 7200 ))
  CREDS="$TMPROOT/aws-credentials"
  printf '[default]\nx_security_token_expires = %s\n' \
    "$(date -r "$FUT" '+%Y-%m-%dT%H:%M:%S+0000' 2>/dev/null || date -d "@$FUT" '+%Y-%m-%dT%H:%M:%S+0000')" > "$CREDS"
  OUT=$(printf '%s' "$(json_with)" | \
    CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT" XDG_CONFIG_HOME="$TMPROOT" \
    XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
    AWS_SHARED_CREDENTIALS_FILE="$CREDS" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g")
  assert_match "T36 파일 파싱 시 만료 epoch 캐시 생성" "exp_epoch=[0-9]+" "$(cat "$TMPROOT/cache/claude-statusline/aws-exp.env" 2>/dev/null)"
else
  echo "warn: saml2aws 미설치 — T36 을 건너뜁니다" >&2
fi
```

- [ ] **Step 2: 테스트를 실행해 실패를 확인한다 (Red, saml2aws 있을 때)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T36|TOTAL'`
Expected: saml2aws가 있으면 `T36 ...`이 FAIL(현재 캐시 파일을 안 만든다). 없으면 건너뜀 경고와 함께 `TOTAL pass=110 fail=0` 유지.

- [ ] **Step 3: format_aws의 파일 파싱 경로에 캐시를 넣는다**

`format_aws`(340~370행, Task 4에서 `now` 제거 반영됨)의 만료 시각 파싱부를 캐시로 감싼다. `exp`(만료 문자열)를 얻은 뒤 epoch로 변환하는 구간을 바꾼다.

기존(Task 4 적용 후):
```sh
  [ -z "$exp" ] && { printf '%saws:?%s' "$DIM" "$RST"; return 0; }

  local exp_epoch remaining
  local exp_norm
  exp_norm=$(printf '%s' "$exp" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
  exp_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$exp_norm" +%s 2>/dev/null || \
              date -d "$exp" +%s 2>/dev/null || echo 0)
  remaining=$(( (exp_epoch - NOW_EPOCH) / 60 ))
```

교체:
```sh
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
```

- [ ] **Step 4: 테스트를 실행해 통과를 확인한다 (Green)**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T36|TOTAL'`
Expected: saml2aws가 있으면 `PASS T36 ...`, `TOTAL pass=111 fail=0`. 없으면 건너뜀과 함께 `TOTAL pass=110 fail=0`.

- [ ] **Step 5: 커밋**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "perf(statusline): cache AWS expiration parse keyed on credentials mtime"
```

---

## Task 9: 버전 번프와 전체 벤치마크 기록

**Files:**
- Modify: `claude-statusline/.claude-plugin/plugin.json:4`
- Modify: `.claude-plugin/marketplace.json:15`

**Interfaces:** 없음(메타데이터·측정).

- [ ] **Step 1: plugin.json 버전을 올린다**

`claude-statusline/.claude-plugin/plugin.json`의 `"version": "2.10.0"`을 `"version": "2.11.0"`으로 바꾼다.

- [ ] **Step 2: marketplace.json plugin 항목 버전을 맞춘다**

`.claude-plugin/marketplace.json` 15행의 plugin 항목 `"version": "2.10.0"`을 `"version": "2.11.0"`으로 바꾼다. 8행의 marketplace 카탈로그 버전(`1.0.0`)은 건드리지 않는다.

- [ ] **Step 3: 두 버전이 같은지 확인한다**

Run: `grep -h '"version"' claude-statusline/.claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: `2.11.0`이 두 번(plugin.json 1회, marketplace.json plugin 항목 1회), `1.0.0`이 한 번.

- [ ] **Step 4: 전체 테스트를 최종 실행한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | tail -3`
Expected: `TOTAL pass=110 fail=0`(saml2aws 없는 환경) 또는 `pass=111`(있는 환경), `fail=0`.

- [ ] **Step 5: 최적화 전후 벤치마크를 측정해 기록한다**

git 저장소를 현재 디렉터리로 둔 렌더 30회를 측정한다(캐시 예열 후).

Run:
```bash
cd claude-statusline
FIVE=$(($(date +%s)+7200)); WEEK=$(($(date +%s)+400000))
J=$(printf '{"session_id":"abc-123","workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$PWD" "$FIVE" "$WEEK")
printf '%s' "$J" | CLAUDE_PLUGIN_ROOT="$PWD" sh scripts/statusline.sh >/dev/null 2>&1  # 캐시 예열
time (for i in $(seq 30); do printf '%s' "$J" | CLAUDE_PLUGIN_ROOT="$PWD" sh scripts/statusline.sh >/dev/null 2>&1; done)
cd ..
```
Expected: 총 시간이 기준점(30회 4.690초, 회당 156ms)보다 확연히 낮다. 실제 측정값을 커밋 메시지에 기록한다.

- [ ] **Step 6: 커밋**

```bash
git add claude-statusline/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(statusline): bump version to 2.11.0

before: 30 renders in 4.690s (~156ms/render)
after:  30 renders in <측정값>s (~<측정값>ms/render)"
```

---

## Self-Review

**Spec coverage:**
- 축약 in-process 흡수 → Task 1, 3.
- 함수 내부 fork 제거(dirname·expr) → Task 2.
- git 브랜치 캐시(내용 토큰, 절대경로 정규화, 무손실) → Task 6.
- Claude 계정 이메일 캐시(-nt) → Task 7.
- AWS 캐시(-nt) → Task 8.
- date 1회화 → Task 4.
- format_model sed 제거 → Task 5.
- 무한 루프 가드 회귀 테스트 → Task 2 Step 1.
- 캐시 미스/히트·worktree·서브디렉토리 무손실 테스트 → Task 6.
- 버전 번프·벤치마크 → Task 9.
- 모든 spec 항목이 태스크에 대응한다.

**Placeholder scan:** 각 코드 스텝은 실제 코드를 담았고 TBD·"적절히 처리" 류 표현이 없다.

**Type consistency:** 캐시 변수 이름(`CACHE_DIR`, `_gbc`, `cc-account.env`, `aws-exp.env`), 함수 이름(`shorten_path`, `shorten_branch`, `strip_control`, `format_model`, `format_cc_account`, `format_aws`), 색 변수(`C_RESET`/`C_DIM`/`C_BLUE`)가 태스크 전반에서 일치한다. 전역 `NOW_EPOCH`/`NOW_CLOCK`은 Task 4에서 정의하고 Task 6·8이 소비한다.
