# GitHub 계정 세그먼트 네 필드 캐시 해석 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 셸 프롬프트가 남긴 탭 네 필드 캐시를 필드 단위로 읽어, 활성 GitHub 계정과 그 계정의 인증·한도 상태를 `gh@` 세그먼트에 표시한다.

**Architecture:** `format_gh()` 한 함수만 바꾼다. 파일을 명령 치환으로 통째로 받던 방식을 셸 내장 `read` 로 바꿔 탭 네 필드를 먼저 나눈 뒤, 계정명 유무를 상태보다 먼저 가르고 상태별로 렌더한다. 라벨과 색은 지금처럼 설정 파일에서 읽는다.

**Tech Stack:** POSIX sh, 픽스처 기반 렌더 테스트(`claude-statusline/tests/statusline.test.sh`)

정본 설계는 [2026-08-02-gh-account-v2-cache-design.md](../specs/2026-08-02-gh-account-v2-cache-design.md) 다.

## Global Constraints

- 모든 셸 스크립트는 POSIX sh 를 유지한다. `[[ ]]`, 배열, `=~`, `${var,,}`, `<<<`, `(( ))` 를 쓰지 않는다.
- 계정명, 라벨, 색을 소스에 넣지 않는다. 설정 파일에서 읽는다.
- 테스트 픽스처는 실재 계정과 충돌하지 않는 값만 쓴다. 계정명은 `octocat`, `testwork` 를 쓰고 이메일이 필요하면 `@example.com` 을 쓴다.
- 캐시 파일에 쓰지 않고 `gh` 명령과 네트워크를 호출하지 않는다.
- 커밋 제목은 Conventional Commits 형식을 따른다.
- 기능 변경은 `claude-statusline/.claude-plugin/plugin.json` 과 `.claude-plugin/marketplace.json` 의 버전을 같은 값으로 올려야 사용자에게 닿는다.

---

### Task 1: 네 필드 레코드 해석과 상태별 렌더

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh:6-18` (ANSI 상수 블록에 `ESC` 추가)
- Modify: `claude-statusline/scripts/statusline.sh:277-310` (`format_gh` 교체)
- Test: `claude-statusline/tests/statusline.test.sh:337-351` (T25 의 빈 값 기대 변경), 같은 파일 끝부분에 T37 추가

**Interfaces:**
- Consumes: 스크립트 시작 시 한 번 잡아 둔 `NOW_EPOCH`(초 단위 epoch), `TAB`, 색 상수 `AMBER214`·`GREY240`·`YELLOW`·`RED`·`RST`, `shorten-lib.sh` 의 `strip_control`
- Produces: `format_gh` 는 인자 없이 호출되고 색 코드가 섞인 세그먼트 문자열 한 개를 표준출력으로 낸다. 캐시 파일이 없으면 아무것도 내지 않고 0 으로 끝난다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`claude-statusline/tests/statusline.test.sh` 의 T25 블록에서 빈 값 기대를 바꾼다. 빈 파일은 활성 계정 부재가 아니라 판정 이전 상태다.

기존 세 줄(345-347)을 다음으로 바꾼다.

```sh
printf '' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains "T25 빈 캐시는 판정 이전이라 gh@?" "gh@?" "$(nth_line 2 "$OUT")"
```

같은 파일에서 T25 블록이 끝나는 줄(`printf 'octocat' > "$TMPROOT/gh-prompt-user"` 원복 줄) 바로 다음에 T37 블록을 넣는다.

```sh
# --- T37: 캐시의 탭 네 필드 레코드를 상태별로 렌더 ---
#    셸 프롬프트가 쓰는 레코드에서 계정명·상태·마감 시각을 각각 읽어 상태 문자(⏳Nm·!·?)와
#    색을 붙인다. 마감 시각은 고정 숫자로 두면 시간이 지나 항상 마감 후로 판정돼 마커 검증이
#    조용히 무력해지므로, 렌더 시점 기준 상대값으로 만든다.
gh_cache() { printf 'v2\t%s\t%s\t%s\n' "$1" "$2" "$3" > "$TMPROOT/gh-prompt-user"; }
GH_NOW=$(date +%s)

gh_cache octocat ok 0
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 ok 은 라벨만"              "gh@personal" "$(nth_line 2 "$OUT")"
assert_not_contains "T37 ok 에 인증 실패 문자 없음" "gh@personal!" "$(nth_line 2 "$OUT")"
assert_not_contains "T37 ok 에 판정 불가 문자 없음" "gh@personal?" "$(nth_line 2 "$OUT")"
assert_not_contains "T37 ok 에 한도 마커 없음"      "⏳" "$(nth_line 2 "$OUT")"

gh_cache octocat auth_failed 0
OUT=$(run "$(json_without)" 200)
RAW=$(run_raw "$(json_without)" 200)
assert_contains     "T37 auth_failed 는 gh@personal!" "gh@personal!" "$(nth_line 2 "$OUT")"
assert_contains     "T37 auth_failed 는 전체 빨강"    "${RED}gh@personal!" "$RAW"

gh_cache octocat unknown 0
OUT=$(run "$(json_without)" 200)
RAW=$(run_raw "$(json_without)" 200)
assert_contains     "T37 unknown 은 gh@personal?"  "gh@personal?" "$(nth_line 2 "$OUT")"
assert_contains     "T37 unknown 은 전체 회색"     "$(printf '\033[38;5;240m')gh@personal?" "$RAW"

gh_cache testwork rate_limited "$((GH_NOW + 540))"
OUT=$(run "$(json_without)" 200)
RAW=$(run_raw "$(json_without)" 200)
assert_contains     "T37 rate_limited 는 gh@work⏳9m" "gh@work⏳9m" "$(nth_line 2 "$OUT")"
assert_contains     "T37 라벨은 설정 색, 마커만 노랑" \
  "$(printf '\033[38;5;27m')gh@work$(printf '\033[0m')$(printf '\033[33m')⏳9m" "$RAW"

gh_cache testwork rate_limited "$((GH_NOW + 30))"
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 1분 미만 남으면 1m 으로 올림" "gh@work⏳1m" "$(nth_line 2 "$OUT")"

gh_cache testwork rate_limited "$((GH_NOW - 60))"
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 마감이 지나면 라벨만"     "gh@work" "$(nth_line 2 "$OUT")"
assert_not_contains "T37 마감이 지나면 마커 제거"  "⏳" "$(nth_line 2 "$OUT")"

gh_cache testwork rate_limited notanumber
OUT=$(run "$(json_without)" 200)
assert_not_contains "T37 마감 시각이 숫자가 아니면 마커 없음" "⏳" "$(nth_line 2 "$OUT")"

gh_cache - no_active 0
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 no_active 는 gh@---"      "gh@---" "$(nth_line 2 "$OUT")"

gh_cache - unknown 0
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 계정명 없는 unknown 은 gh@?" "gh@?" "$(nth_line 2 "$OUT")"

gh_cache - ok 0
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 계정명 자리가 - 이면 상태보다 먼저 걸러 gh@?" "gh@?" "$(nth_line 2 "$OUT")"
assert_no_match     "T37 gh@- 로 새지 않음" 'gh@-[[:space:]]' "$(nth_line 2 "$OUT")"

printf 'v1\toctocat\tok\t0\n' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 형식을 모르는 네 필드는 계정명만 살리고 판정 불가" \
  "gh@personal?" "$(nth_line 2 "$OUT")"

printf 'v2\toctocat\n' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 필드 수가 어긋나면 gh@?" "gh@?" "$(nth_line 2 "$OUT")"

printf 'octocat' > "$TMPROOT/gh-prompt-user"
OUT=$(run "$(json_without)" 200)
assert_contains     "T37 탭 없는 한 줄은 계정명으로 해석" "gh@personal" "$(nth_line 2 "$OUT")"
```

마지막 줄이 캐시를 옛 형식 `octocat` 으로 되돌리므로 뒤따르는 테스트는 영향을 받지 않는다.

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

실행: `sh claude-statusline/tests/statusline.test.sh`

기대: T37 의 v2 레코드 단언과 T25 의 빈 캐시 단언이 실패한다. 실패 메시지에 `gh@v2octocatok0` 처럼 네 필드가 한 덩어리로 붙은 값이 보인다. 탭 없는 한 줄 단언은 이미 통과한다.

- [ ] **Step 3: 색 상수에 ESC 를 추가한다**

`claude-statusline/scripts/statusline.sh` 의 6번째 줄 `# --- ANSI ---` 바로 다음에 한 줄을 넣는다. 설정 파일이 준 색 번호로 이스케이프를 조립할 때 명령 치환 없이 쓰기 위한 값이다.

```sh
ESC=$(printf '\033')
```

기존 상수들은 그대로 둔다.

- [ ] **Step 4: format_gh 를 교체한다**

`claude-statusline/scripts/statusline.sh` 의 `# --- GitHub 계정 표시기 ---` 주석부터 `format_gh` 함수 닫는 괄호까지를 다음으로 바꾼다.

```sh
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
```

- [ ] **Step 5: 테스트를 돌려 통과를 확인한다**

실행: `sh claude-statusline/tests/statusline.test.sh`

기대: 전부 통과한다. 실패 0 이 아니면 다음 단계로 가지 않는다.

- [ ] **Step 6: 실제 캐시로 렌더를 확인한다**

실행:

```sh
printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"version":"2.12.0","session_id":"11111111-2222-3333-4444-555555555555"}' \
  | sh claude-statusline/scripts/statusline.sh | sed -n '2p'
```

기대: 둘째 줄의 `gh@` 세그먼트가 설정 파일의 라벨로 보이고, 네 필드가 붙은 문자열이 남아 있지 않다.

- [ ] **Step 7: 커밋한다**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "fix(statusline): read gh cache as tab-separated fields and render account status"
```

---

### Task 2: README 의 캐시 형식과 상태 표시 설명 갱신

**Files:**
- Modify: `README.md:114-117`

**Interfaces:**
- Consumes: Task 1 이 확정한 표시 계약
- Produces: 없음. 문서만 바뀐다.

- [ ] **Step 1: 캐시 형식과 상태 표시를 적는다**

`README.md` 의 다음 문단을 바꾼다.

```markdown
The current login is read from
`${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user` (written by your shell
prompt). An unmapped login shows `gh@<login>`; an empty value shows `gh@---`;
color codes must be numeric.
```

바꾼 뒤:

````markdown
The current login and its status are read from
`${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user` (written by your shell
prompt). The file holds one tab-separated record:

```
v2	<login-or-->	<state>	<deadline-epoch-or-0>
```

Each state renders differently: `ok` shows `gh@<label>`, `rate_limited`
appends a yellow `⏳<minutes>m` until the deadline passes, `auth_failed` shows
a red `gh@<label>!`, `unknown` shows a grey `gh@<label>?`, and `no_active`
shows `gh@---`. A single line without tabs is read as a bare login, so a
prompt that records only the login still works. An unmapped login shows
`gh@<login>`; an empty or malformed file shows `gh@?`; color codes must be
numeric.
````

- [ ] **Step 2: 렌더가 설명과 맞는지 확인한다**

실행: `sh claude-statusline/tests/statusline.test.sh`

기대: 전부 통과한다. README 의 각 상태 서술이 T37 의 단언과 어긋나지 않는지 눈으로 대조한다.

- [ ] **Step 3: 커밋한다**

```bash
git add README.md
git commit -m "docs(statusline): document gh cache record format and status markers"
```

---

### Task 3: 버전 올리기

**Files:**
- Modify: `claude-statusline/.claude-plugin/plugin.json:4`
- Modify: `.claude-plugin/marketplace.json:15`

**Interfaces:**
- Consumes: Task 1 과 Task 2 의 변경
- Produces: 없음.

- [ ] **Step 1: 두 매니페스트의 버전을 2.13.0 으로 맞춘다**

`claude-statusline/.claude-plugin/plugin.json` 의 `"version": "2.12.0"` 을 `"version": "2.13.0"` 으로 바꾼다.

`.claude-plugin/marketplace.json` 의 플러그인 항목(15번째 줄) `"version": "2.12.0"` 을 `"version": "2.13.0"` 으로 바꾼다. 같은 파일 8번째 줄의 `"version": "1.0.0"` 은 마켓플레이스 자체 버전이므로 건드리지 않는다.

- [ ] **Step 2: 두 값이 같은지 확인한다**

실행:

```sh
grep -h '"version"' claude-statusline/.claude-plugin/plugin.json .claude-plugin/marketplace.json
```

기대: `2.13.0` 이 두 번 보이고 `2.12.0` 은 보이지 않는다.

- [ ] **Step 3: 테스트를 다시 돌린다**

실행: `sh claude-statusline/tests/statusline.test.sh`

기대: 전부 통과한다.

- [ ] **Step 4: 커밋한다**

```bash
git add claude-statusline/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(statusline): bump version to 2.13.0"
```
