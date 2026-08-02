# 74칼럼 3행 압축 레이아웃 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** statusline 렌더를 세 행으로 줄이고 각 행을 74칼럼 안에 담는다.

**Architecture:** 게이지 막대와 비용 표시를 걷어내 세로 길이를 줄이고, 남는 가로 여백에 버전과
세션 식별자를 합류시킨다. 첫 행의 경로와 브랜치는 표시 폭 기준으로 예산을 나눠 갖고 넘치면
뒤쪽을 잘라 낸다. 폭 계산과 절단은 ANSI 이스케이프를 폭 0으로 세는 awk 프로그램 하나가 맡는다.

**Tech Stack:** POSIX sh, awk, 픽스처 기반 셸 테스트

## Global Constraints

- 모든 셸 스크립트는 POSIX `sh` 다. `[[ ]]`, 배열, `=~`, `${var,,}`, `<<<`, `(( ))` 를 쓰지 않는다.
- 실행형 진입점은 `#!/bin/sh` 와 `set -eu` 를 쓴다. `.` 으로 불러오는 helper 는 호출자의 셸 옵션을 바꾸지 않는다.
- 렌더 결과의 어떤 행도 표시 폭 74칼럼을 넘지 않는다.
- 렌더 결과는 세 행을 넘지 않는다.
- 테스트 픽스처에 실재 인물, 계정, 시크릿을 넣지 않는다. 계정은 `octocat`, 주소는 `@example.com` 을 쓴다.
- `gh@<account>` 매핑, 계정명, 라벨, 색은 소스에 넣지 않는다.
- GitHub 계정 세그먼트의 내부 동작은 이 계획의 범위가 아니다. `format_gh` 가 돌려주는 문자열을 배치만 한다.
- 비용 집계 파이프라인(`refresh-cost.sh`, `aggregate-cost.awk`, `hook-handler.sh` 의 갱신 호출)은 건드리지 않는다.
- 커밋 제목은 Conventional Commits 를 따른다.

## File Structure

| 파일 | 책임 | 처분 |
|---|---|---|
| `claude-statusline/scripts/fit-line1.awk` | 경로와 브랜치의 표시 폭을 재고 첫 행 예산에 맞춰 절단한다 | 생성 |
| `claude-statusline/tests/fit.test.sh` | `fit-line1.awk` 를 직접 호출해 폭 계산과 절단을 검증한다 | 생성 |
| `claude-statusline/scripts/statusline.sh` | 세그먼트를 만들어 세 행으로 조립한다 | 수정 |
| `claude-statusline/tests/statusline.test.sh` | 렌더 결과를 픽스처로 검증한다 | 수정 |
| `README.md` | 최종 사용자용 레이아웃 설명 | 수정 |
| `claude-statusline/.claude-plugin/plugin.json` | 플러그인 버전 | 수정 |
| `.claude-plugin/marketplace.json` | 마켓플레이스 카탈로그 버전 | 수정 |

---

### Task 1: 표시 폭 절단 awk 프로그램

**Files:**
- Create: `claude-statusline/scripts/fit-line1.awk`
- Test: `claude-statusline/tests/fit.test.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `fit-line1.awk` 는 stdin 에서 두 줄(1행 경로 세그먼트, 2행 브랜치 이름)을 읽어
  stdout 으로 두 줄(절단된 경로, 절단된 브랜치)을 낸다. `LC_ALL=C awk -f` 로 호출한다.
  브랜치 줄이 비어 있으면 빈 줄을 그대로 낸다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`claude-statusline/tests/fit.test.sh` 를 만든다.

```sh
#!/bin/sh
# fit-line1.awk 폭 계산·절단 테스트
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
AWKP="$SRC/scripts/fit-line1.awk"
ESC=$(printf '\033')

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

# 두 줄을 넣고 두 줄을 받는다.
fit() { printf '%s\n%s\n' "$1" "$2" | LC_ALL=C awk -f "$AWKP"; }
# 색 코드를 뺀 표시 폭. 한글 등 두 칸 문자를 두 칸으로 센다.
vwidth() {
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g" | LC_ALL=C awk '
    function wide(s) {
      if (length(s) == 4) return 1
      if (length(s) != 3) return 0
      if (s >= "\341\204\200" && s <= "\341\205\237") return 1
      if (s >= "\342\272\200" && s <= "\352\223\217") return 1
      if (s >= "\352\260\200" && s <= "\355\236\243") return 1
      return 0
    }
    { n=length($0); i=1; t=0
      while (i<=n) { c=substr($0,i,1)
        if (c < "\200") L=1; else if (c < "\340") L=2; else if (c < "\360") L=3; else L=4
        t += wide(substr($0,i,L)) ? 2 : 1; i += L }
      printf "%d", t }'
}
line1_width() {
  w=$(vwidth "$1"); [ -n "$2" ] && w=$((w + 1 + 1 + $(vwidth "$2")))
  printf '%d' $((5 + 1 + w))
}

# T1: 예산 안이면 그대로 통과한다
R=$(fit "~/↪2/claude-statusline" "main")
assert_equals "T1 짧은 경로 그대로" "~/↪2/claude-statusline" "$(printf '%s\n' "$R" | sed -n 1p)"
assert_equals "T1 짧은 브랜치 그대로" "main" "$(printf '%s\n' "$R" | sed -n 2p)"

# T2: 둘 다 33칼럼을 넘으면 각자 33칼럼으로 잘리고 첫 행이 74칼럼을 넘지 않는다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway" "feature/PROJ-1469-connect-api-secrets")
P=$(printf '%s\n' "$R" | sed -n 1p); B=$(printf '%s\n' "$R" | sed -n 2p)
assert_equals "T2 경로 33칼럼" "33" "$(vwidth "$P")"
assert_equals "T2 브랜치 33칼럼" "33" "$(vwidth "$B")"
assert_equals "T2 첫 행 74칼럼 이내" "74" "$(line1_width "$P" "$B")"

# T3: 브랜치가 짧으면 남는 몫이 경로로 간다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway-extra-long-name-here" "main")
P=$(printf '%s\n' "$R" | sed -n 1p)
assert_equals "T3 브랜치가 짧으면 경로가 62칼럼까지" "62" "$(vwidth "$P")"

# T4: 두 칸 문자를 반으로 쪼개지 않는다
R=$(fit "~/↪2/helper/↪2/성과-여정-2분기-리뷰-아주-긴-이름-테스트-문자열" "성과-여정-2분기-리뷰-아주-긴-브랜치-이름")
P=$(printf '%s\n' "$R" | sed -n 1p); B=$(printf '%s\n' "$R" | sed -n 2p)
assert_equals "T4 한글 경로 짝수 폭(반쪽 없음)" "32" "$(vwidth "$P")"
assert_equals "T4 한글 브랜치 짝수 폭(반쪽 없음)" "32" "$(vwidth "$B")"
assert_equals "T4 첫 행 74칼럼 이내" "72" "$(line1_width "$P" "$B")"

# T5: 잘리면 줄임표가 붙는다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway" "feature/PROJ-1469-connect-api-secrets")
case "$(printf '%s\n' "$R" | sed -n 1p)" in *…) ok "T5 경로 줄임표";; *) bad "T5 경로 줄임표" "$R";; esac
case "$(printf '%s\n' "$R" | sed -n 2p)" in *…) ok "T5 브랜치 줄임표";; *) bad "T5 브랜치 줄임표" "$R";; esac

# T6: 색 코드는 폭 0으로 세고 보존하며, 잘린 줄은 리셋으로 닫는다
COLORED="${ESC}[2m~/${ESC}[0m${ESC}[34mvery-long-project-directory-name-that-overflows${ESC}[0m"
R=$(fit "$COLORED" "feature/PROJ-1469-connect-api-secrets")
P=$(printf '%s\n' "$R" | sed -n 1p)
assert_equals "T6 색 코드 제외 폭 33" "33" "$(vwidth "$P")"
case "$P" in *"${ESC}[34m"*) ok "T6 색 코드 보존";; *) bad "T6 색 코드 보존" "$P";; esac
case "$P" in *"${ESC}[0m") ok "T6 잘린 줄이 리셋으로 닫힘";; *) bad "T6 잘린 줄이 리셋으로 닫힘" "$P";; esac

# T7: 브랜치가 없으면 경로가 68칼럼까지 쓴다
R=$(fit "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway-extra-long-name-here-more" "")
P=$(printf '%s\n' "$R" | sed -n 1p)
assert_equals "T7 브랜치 부재 시 경로 68칼럼" "68" "$(vwidth "$P")"
assert_equals "T7 브랜치 부재 시 첫 행 74칼럼 이내" "74" "$(line1_width "$P" "")"

# T8: 색 없는 짧은 입력에는 리셋을 덧붙이지 않는다
R=$(fit "~/short" "main")
case "$(printf '%s\n' "$R" | sed -n 1p)" in
  *"${ESC}["*) bad "T8 색 없는 입력에 이스케이프 미추가" "$R";;
  *) ok "T8 색 없는 입력에 이스케이프 미추가";;
esac

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `sh claude-statusline/tests/fit.test.sh`
Expected: FAIL. `awk: can't open file .../scripts/fit-line1.awk` 로 모든 단언이 실패한다.

- [ ] **Step 3: awk 프로그램을 쓴다**

`claude-statusline/scripts/fit-line1.awk` 를 만든다.

```awk
# 첫 행의 경로와 브랜치를 표시 폭 예산에 맞춰 줄인다.
# stdin 두 줄(경로, 브랜치) -> stdout 두 줄. LC_ALL=C 로 호출해 바이트 단위로 다룬다.
#
# 수정 시 검토 관점: 폭 계산은 UTF-8 의 바이트 순서가 코드포인트 순서를 보존한다는 성질에
# 기댄다. 경계 시퀀스를 옥탈 리터럴로 비교하므로 awk 구현의 유니코드 지원에 의존하지 않는다.
# 이 성질을 깨는 방식(코드포인트 산술, length() 의 문자 수 가정)으로 바꾸지 않는다.
# 예산 상수 66 과 68 은 statusline.sh 의 첫 행 조립과 짝이다. 한쪽만 바꾸면 74칼럼이 깨진다.

function is_wide(sq) {
  if (length(sq) == 4) return 1          # 4바이트 시퀀스는 이모지 평면으로 보고 두 칸
  if (length(sq) != 3) return 0          # 1~2바이트는 모두 한 칸
  if (sq >= "\341\204\200" && sq <= "\341\205\237") return 1   # U+1100..U+115F 한글 자모
  if (sq >= "\342\272\200" && sq <= "\352\223\217") return 1   # U+2E80..U+A4CF CJK
  if (sq >= "\352\260\200" && sq <= "\355\236\243") return 1   # U+AC00..U+D7A3 한글 음절
  if (sq >= "\357\244\200" && sq <= "\357\253\277") return 1   # U+F900..U+FAFF CJK 호환
  if (sq >= "\357\270\260" && sq <= "\357\271\257") return 1   # U+FE30..U+FE6F 세로형
  if (sq >= "\357\274\200" && sq <= "\357\275\240") return 1   # U+FF00..U+FF60 전각
  if (sq >= "\357\277\240" && sq <= "\357\277\246") return 1   # U+FFE0..U+FFE6 전각 기호
  return 0
}

function seqlen(c) {
  if (c < "\200") return 1
  if (c < "\340") return 2
  if (c < "\360") return 3
  return 4
}

# 표시 폭. ANSI 이스케이프(ESC [ ... m)는 0으로 센다.
function vwidth(s,   i, n, c, sq, L, tot) {
  n = length(s); i = 1; tot = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\033") {
      i++
      while (i <= n) { c = substr(s, i, 1); i++; if (c == "m") break }
      continue
    }
    L = seqlen(c); sq = substr(s, i, L)
    tot += is_wide(sq) ? 2 : 1
    i += L
  }
  return tot
}

# 표시 폭 limit 까지만 남긴다. 두 칸 문자가 한 칸 자리에 걸리면 넣지 않는다.
function cut(s, limit,   i, n, c, sq, L, wd, tot, out) {
  n = length(s); i = 1; tot = 0; out = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\033") {
      sq = c; i++
      while (i <= n) { c = substr(s, i, 1); sq = sq c; i++; if (c == "m") break }
      out = out sq
      continue
    }
    L = seqlen(c); sq = substr(s, i, L); wd = is_wide(sq) ? 2 : 1
    if (tot + wd > limit) break
    tot += wd; out = out sq; i += L
  }
  return out
}

# 넘칠 때만 자르고 줄임표를 붙인다. 줄임표 한 칸을 미리 빼서 결과가 limit 를 넘지 않게 한다.
# 색이 섞인 입력은 잘린 자리에서 색이 열린 채 끝날 수 있으므로 리셋으로 닫는다.
function fit(s, limit) {
  if (vwidth(s) <= limit) return s
  return cut(s, limit - 1) "…" (index(s, "\033") ? "\033[0m" : "")
}

BEGIN {
  getline path_seg
  getline branch_seg
  pw = vwidth(path_seg)
  bw = vwidth(branch_seg)
  budget = (bw > 0) ? 66 : 68
  if (pw + bw <= budget) {
    plim = pw; blim = bw
  } else {
    half = int(budget / 2)
    if (bw <= half)      { plim = budget - bw; blim = bw }
    else if (pw <= half) { plim = pw;          blim = budget - pw }
    else                 { plim = half;        blim = budget - half }
  }
  print fit(path_seg, plim)
  print fit(branch_seg, blim)
}
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run: `sh claude-statusline/tests/fit.test.sh`
Expected: PASS. `TOTAL pass=17 fail=0`

- [ ] **Step 5: 커밋한다**

```bash
git add claude-statusline/scripts/fit-line1.awk claude-statusline/tests/fit.test.sh
git commit -m "feat(statusline): add display-width truncation for the location line"
```

---

### Task 2: 첫 행에 예산 배분과 절단을 배선

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh:481-488`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: Task 1 의 `fit-line1.awk`
- Produces: 첫 행 `line_loc` 이 74칼럼을 넘지 않는다. 다른 행은 아직 그대로다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`claude-statusline/tests/statusline.test.sh` 의 T18 블록 바로 뒤에 넣는다.

```sh
# --- T40: 첫 행은 74칼럼을 넘지 않는다(긴 경로·브랜치를 폭 기준으로 절단) ---
if [ "$HAVE_GIT" = "1" ]; then
  LONGREPO="$TMPROOT/deep/aa/bb/cc/dd/very-long-project-directory-name"
  mkdir -p "$LONGREPO"
  ( cd "$LONGREPO" \
    && git init -q \
    && git symbolic-ref HEAD refs/heads/feature/PROJ-1469-connect-api-secrets-long \
    && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
           commit -q --allow-empty -m init ) >/dev/null 2>&1
  OUT=$(HOME="$TMPROOT" run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$LONGREPO")" 200)
  W1=$(vwidth_of "$(first_line "$OUT")")
  assert_equals "T40 첫 행 74칼럼 이내" "yes" "$([ "$W1" -le 74 ] && echo yes || echo "no($W1)")"
  assert_contains "T40 잘린 자리에 줄임표" "…" "$(first_line "$OUT")"
else
  printf 'SKIP T40 (git fixture 미생성)\n'
fi
```

같은 파일의 helper 모음(`count_char` 정의 바로 아래)에 폭 계산 helper 를 넣는다.

```sh
# 색 코드를 뺀 표시 폭. 한글 등 두 칸 문자를 두 칸으로 센다(74칼럼 단언용).
vwidth_of() {
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g" | LC_ALL=C awk '
    function wide(s) {
      if (length(s) == 4) return 1
      if (length(s) != 3) return 0
      if (s >= "\341\204\200" && s <= "\341\205\237") return 1
      if (s >= "\342\272\200" && s <= "\352\223\217") return 1
      if (s >= "\352\260\200" && s <= "\355\236\243") return 1
      return 0
    }
    { n=length($0); i=1; t=0
      while (i<=n) { c=substr($0,i,1)
        if (c < "\200") L=1; else if (c < "\340") L=2; else if (c < "\360") L=3; else L=4
        t += wide(substr($0,i,L)) ? 2 : 1; i += L }
      printf "%d", t }'
}
```

테스트 하네스가 새 awk 파일을 보도록 심볼릭 링크 목록(`ln -sf "$SRC/scripts/json.awk"` 줄 아래)에 한 줄 더한다.

```sh
ln -sf "$SRC/scripts/fit-line1.awk" "$TMPROOT/scripts/fit-line1.awk"
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep T40`
Expected: FAIL. 첫 행이 74보다 길어 `no(<숫자>)` 가 나오고 줄임표가 없다.

- [ ] **Step 3: 첫 행 조립을 고친다**

`claude-statusline/scripts/statusline.sh` 의 줄1 조립 블록을 아래로 바꾼다. 기존 블록은
`# 줄1: 시간 경로 브랜치...` 주석부터 `[ -n "$branch" ] && line_loc=...` 까지다.

```sh
# 줄1: 시간 경로 브랜치. 브랜치는 코드상 위치라 경로와 같은 줄에 둔다. 괄호 대신 아이콘( )을
# 이름 바로 앞에 붙인다(사이 공백 없음). 브랜치가 없으면 시간·경로만 남는다.
# 경로와 브랜치는 가변 길이라 fit-line1.awk 가 표시 폭 예산에 맞춰 줄인다. awk 는 색 코드를
# 폭 0으로 세므로 색이 입혀진 경로를 그대로 넘긴다. 브랜치는 색 없는 이름만 넘기고 아이콘과
# 색은 절단 뒤에 입힌다 — 아이콘 한 칸은 awk 의 예산 66 바깥에서 따로 셈한다.
# 수정 시 검토 관점: 여기의 시각·공백 폭과 fit-line1.awk 의 예산 상수는 한 쌍이다. 한쪽만
# 바꾸면 74칼럼 상한이 조용히 깨진다.
time_seg="${GREEN}${NOW_CLOCK}${RST}"
path_seg=$(shorten_path "$cwd")
branch_name=""
[ -n "$branch" ] && branch_name=$(shorten_branch "$branch")

_fit=$(printf '%s\n%s\n' "$path_seg" "$branch_name" \
  | LC_ALL=C awk -f "$PLUGIN_ROOT/scripts/fit-line1.awk")
{ IFS= read -r path_seg || true; IFS= read -r branch_name || true; } <<FITOUT
$_fit
FITOUT

line_loc="${time_seg} ${path_seg}"
[ -n "$branch_name" ] && line_loc="${line_loc} ${MAGENTA}${BRANCH_GLYPH}${branch_name}${RST}"
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh`
Expected: T40 두 단언이 PASS. T18, T37, T38, T39 도 그대로 PASS 를 유지한다.

- [ ] **Step 5: 커밋한다**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "feat(statusline): cap the location line at 74 display columns"
```

---

### Task 3: 게이지에서 막대를 걷어내고 페이스 초과를 기호로 바꾼다

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh:146-241`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `format_context` 는 `ctx <pct>%` 를, `format_rate <label> <pct> <reset> <window>` 는
  `<label> <pct>%[▲] ↺<남은시간>` 을 낸다. 둘 다 색 코드가 입혀진 한 세그먼트 문자열이다.
  `render_bar` 와 `format_context_bar` 는 사라진다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

기존 T1, T7, T8, T21, T22, T23, T24, T28, T31 은 막대를 전제하므로 아래로 바꾼다. 각 블록을
찾아 통째로 치환한다.

```sh
# --- T1: rate_limits 있으면 5h/7d 라벨과 소진율이 나온다 ---
OUT=$(run "$(json_with)" 200)
assert_match "T1 5h 소진율 표시" '5h [0-9]+%' "$OUT"
assert_match "T1 7d 소진율 표시" '7d [0-9]+%' "$OUT"
assert_match "T1 5h 리셋 분 단위 표기" "↺[0-9]+h[0-9]+m" "$OUT"

# --- T21: 막대 문자를 쓰지 않는다(정적 검사) ---
if grep -q '█' "$SRC/scripts/statusline.sh"; then
  bad "T21 막대 문자 제거" "found █ in statusline.sh"
else
  ok "T21 막대 문자 제거"
fi

# --- T22: 소진율 경계값(0%/100%)이 숫자로 그대로 나온다 ---
OUT=$(run "$(json_pct_nr 0 100)" 200)
assert_match "T22 0% 표기" '5h 0%' "$OUT"
assert_match "T22 100% 표기" '7d 100%' "$OUT"

# --- T23: ctx 임계 색 — 40%+ 노랑, 70%+ 빨강, 미만은 색 없음 ---
ctx30=$(run_raw "$(json_ctx 60000)"  200 | grep 'ctx')
ctx45=$(run_raw "$(json_ctx 90000)"  200 | grep 'ctx')
ctx75=$(run_raw "$(json_ctx 150000)" 200 | grep 'ctx')
assert_not_contains "T23 30% ctx 노랑 없음" "$YELLOW" "$ctx30"
assert_not_contains "T23 30% ctx 빨강 없음" "$RED" "$ctx30"
assert_contains     "T23 45% ctx 노랑(40%+)" "$YELLOW" "$ctx45"
assert_not_contains "T23 45% ctx 빨강 없음(70% 미만)" "$RED" "$ctx45"
assert_contains     "T23 75% ctx 빨강(70%+)" "$RED" "$ctx75"

# --- T24: ctx 소진율 숫자에 임계 색이 붙는다 ---
ctx45r=$(run_raw "$(json_ctx 90000)" 200 | grep 'ctx')
assert_contains "T24 45% ctx 숫자 노랑" "${YELLOW}45%" "$ctx45r"

# --- T31: 페이스 초과를 ▲ 로 표시한다 ---
#    FIVE_RESET=now+9000, 5h(18000s) 윈도우 → 경과 9000s → 예산 10칸. fill 이 예산을 넘으면
#    ▲ 가 붙고, 넘지 않으면 붙지 않는다. 초과 3칸 이상이면 빨강, 그보다 적으면 노랑.
OUT=$(run "$(json_pct 70 10)" 200)
assert_contains     "T31 초과 시 ▲ 표시" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
OUT=$(run "$(json_pct 40 10)" 200)
assert_not_contains "T31 여유면 ▲ 없음" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
RAW=$(run_raw "$(json_pct 70 10)" 200 | grep '5h')
assert_contains     "T31 큰 초과 빨강 ▲" "${RED}▲" "$RAW"
RAW=$(run_raw "$(json_pct 55 10)" 200 | grep '5h')
assert_contains     "T31 작은 초과 노랑 ▲" "${YELLOW}▲" "$RAW"
```

T7, T8, T12, T13, T19, T28 은 Task 4 에서 행 구성을 바꿀 때 함께 손대므로 이 단계에서는
막대를 가리키는 정규식만 소진율 표기로 바꾼다. `'ctx +█'` 는 `'ctx [0-9]'`, `"5h +█"` 는
`'5h [0-9]'`, `"7d +█"` 는 `'7d [0-9]'` 로 바꾸고, T19 의 `bar_col`·`lbl_col` 정렬 단언 블록과
T28 블록은 통째로 지운다. 라벨 우측 정렬이 사라지기 때문이다.

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T21|T31|T22'`
Expected: FAIL. T21 은 `found █`, T31 은 `▲` 부재, T22 는 `5h 0%` 불일치로 실패한다.

- [ ] **Step 3: 게이지 함수를 고친다**

`render_bar` 함수 전체(주석 포함)를 지운다. `format_context_bar` 를 아래 `format_context` 로
바꾼다.

```sh
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
```

`format_rate` 를 아래로 바꾼다.

```sh
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
```

조립부에서 `format_context_bar` 호출을 `format_context` 로 바꾸고, 라벨 우측 정렬을 없앤다.
`GW=4` 줄과 `ralign` 함수 정의를 지우고, 세 줄을 아래처럼 만든다.

```sh
model_str=$(format_model "$model_display")
effort_ind=$(format_effort "$effort")
line_ctx="$(format_context)"
[ -n "$model_str" ] && line_ctx="${line_ctx} ${CYAN}${model_str}${RST}"
[ -n "$effort_ind" ] && line_ctx="${line_ctx} ${effort_ind}"
line_5h=$(format_rate 5h "$five_h" "$five_reset" 18000)
line_7d=$(format_rate 7d "$week_h" "$week_reset" 604800)
```

`ralign` 을 쓰던 cost 줄은 Task 4 에서 사라지므로 이 단계에서는 `$(ralign cost "$GW")` 를
`cost` 문자열로 바꿔 임시로 통과시킨다.

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh`
Expected: 전부 PASS. 실패가 남으면 그 단언이 막대를 가리키는지 확인해 소진율 표기로 고친다.

- [ ] **Step 5: 커밋한다**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "refactor(statusline): replace gauge bars with percentages and a pace marker"
```

---

### Task 4: 비용을 걷어내고 세 행으로 조립한다

**Files:**
- Modify: `claude-statusline/scripts/statusline.sh:243-275,481-533`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: Task 2 의 `line_loc`, Task 3 의 `format_context`·`format_rate`
- Produces: 렌더가 세 행이다. 첫 행은 위치, 둘째 행은 계정과 버전과 세션 접두, 셋째 행은 게이지다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

T2, T3, T3-nobc, T12 블록을 지우고 아래를 넣는다. T7, T11, T13, T14, T27 은 아래처럼 바꾼다.

```sh
# --- T2: 비용을 표시하지 않는다 ---
OUT=$(run "$(json_with)" 200)
assert_not_contains "T2 24h 비용 라벨 없음" "24h" "$OUT"
assert_not_contains "T2 7d 비용 금액 없음" "\$605" "$OUT"
assert_not_contains "T2 cost 라벨 없음" "cost" "$OUT"

# --- T7: 세 행 구성 (rate 있음, 브랜치 없음) ---
#    행1 시간·경로 / 행2 계정·버전·세션 / 행3 ctx·모델·effort·5h·7d.
OUT=$(run "$(json_with)" 200)
assert_equals "T7 총 3행" "3" "$(nlines "$OUT")"
assert_match  "T7 행3 ctx"  'ctx [0-9]'  "$(nth_line 3 "$OUT")"
assert_match  "T7 행3 5h"   '5h [0-9]'   "$(nth_line 3 "$OUT")"
assert_match  "T7 행3 7d"   '7d [0-9]'   "$(nth_line 3 "$OUT")"

# --- T7-model: 모델·effort 는 ctx 뒤에, 버전은 행2 에 온다 ---
OUT=$(run "$(json_with)" 200)
assert_match    "T7-model ctx 뒤 모델명" 'ctx [0-9]+% Opus 4\.8' "$(nth_line 3 "$OUT")"
assert_contains "T7-model 행2 버전" "v2.1.11" "$(nth_line 2 "$OUT")"

# --- T11: 행1 은 시간·경로만 — 계정·버전·세션은 행2 ---
OUT=$(run "$(json_with)" 200)
FIRST=$(first_line "$OUT")
assert_not_contains "T11 행1 에 gh 계정 없음" "gh@" "$FIRST"
assert_not_contains "T11 행1 에 버전 없음" "v2.1.11" "$FIRST"
assert_contains     "T11 행2 에 gh 계정" "gh@personal" "$(nth_line 2 "$OUT")"

# --- T13: rate 부재면 행3 에 ctx 만 남고 행 수는 그대로 3 ---
OUT=$(run "$(json_without)" 200)
assert_equals   "T13 rate 부재에도 3행" "3" "$(nlines "$OUT")"
assert_match    "T13 행3 ctx 유지" 'ctx [0-9]' "$(nth_line 3 "$OUT")"
assert_no_match "T13 5h 없음" '5h [0-9]' "$OUT"
assert_no_match "T13 7d 없음" '7d [0-9]' "$OUT"

# --- T14: 버전 무손실 ---
OUT=$(run "$(json_with)" 200)
assert_contains "T14 버전 표시" "v2.1.11" "$OUT"

# --- T27: 세션 ID 는 앞 6자만 행2 에 온다 ---
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 200)
  SESS6=$(printf '%s' "$KNOWN_SESSION" | cut -c1-6)
  assert_contains     "T27 행2 에 세션 마커+접두 6자" "⧉ ${SESS6}" "$(nth_line 2 "$OUT")"
  assert_not_contains "T27 전체 UUID 는 표시하지 않음" "$KNOWN_SESSION" "$OUT"
  assert_not_contains "T27 행1 에 세션 없음" "⧉" "$(first_line "$OUT")"
else
  printf 'SKIP T27 (git fixture 미생성)\n'
fi
OUT=$(run "$(json_without)" 200)
assert_not_contains "T27 session_id 부재 시 ⧉ 없음" "⧉" "$OUT"

# --- T41: 모든 행이 74칼럼을 넘지 않는다 ---
check_all_widths() {
  _bad=0
  printf '%s\n' "$1" | while IFS= read -r _l; do
    [ "$(vwidth_of "$_l")" -gt 74 ] && printf 'over\n'
  done | grep -q over && _bad=1
  [ "$_bad" -eq 0 ] && printf 'ok' || printf 'over74'
}
for _fx in "$(json_with)" "$(json_without)" "$(json_high)" "$(json_pct 100 100)"; do
  assert_equals "T41 모든 행 74칼럼 이내" "ok" "$(check_all_widths "$(run "$_fx" 200)")"
done
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep -E 'T2 |T7 |T27'`
Expected: FAIL. 현재는 비용이 남아 있어 T2 가, 행이 7개라 T7 이, 전체 UUID 라 T27 이 실패한다.

- [ ] **Step 3: 비용 블록을 지우고 조립을 세 행으로 바꾼다**

`# --- 비용 데이터 ---` 주석부터 `daily_seg=...` 를 만드는 `fi` 까지 통째로 지운다. 지우는
범위에는 `mdays`, `daily_seg`, `weekly_seg`, `monthly_seg`, `cost_available`, `opus`, `sonnet`,
`haiku`, `w_cost`, `m_cost`, `cost_cache` 와 그 값을 읽는 while 루프가 들어간다. `ge_one`
함수와 `CACHE_DIR` 정의는 남긴다 — `CACHE_DIR` 는 계정·AWS·브랜치 캐시가 계속 쓴다.

`ge_one` 은 비용 판정에만 쓰였으므로 함께 지운다.

`SLASH` 정의와 `line_cost` 조립, `line_foot` 조립을 지운다.

둘째 행 조립에 버전과 세션 접두를 더한다.

```sh
# 줄2: Claude계정 gh계정 aws세션 버전 세션접두. 계정·인증과 실행을 규정하는 상수값을 모은다.
# 값 없는 항목은 자연히 빠지고 남은 항목만 공백으로 잇는다.
# 세션 ID 는 앞 6자만 쓴다. 이 식별자는 UUID 버전 4라 어느 자리에도 시간 정보가 없고, 접두
# 6자면 유일 식별에 충분하다.
# 수정 시 검토 관점: 조립 순서를 바꾸려면 이 append_meta 호출 순서만 바꾼다.
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
[ -n "$version" ] && append_meta "$(dimlabel "v${version}")"
if [ -n "$session_id" ]; then
  sid6="${session_id%"${session_id#??????}"}"
  append_meta "${GREY240}${SESSION_GLYPH} ${sid6}${RST}"
fi
```

게이지 세 개를 한 행으로 합친다. Task 3 에서 만든 `line_ctx`, `line_5h`, `line_7d` 조립 뒤에
아래를 둔다.

```sh
# 줄3: ctx 모델 effort 5h 7d. 게이지를 한 행에 모아 소진 상태를 한눈에 본다. rate 데이터가
# 없으면 format_rate 가 빈 문자열을 돌려주고 그 세그먼트만 빠진다.
line_gauge="$line_ctx"
[ -n "$line_5h" ] && line_gauge="${line_gauge} ${line_5h}"
[ -n "$line_7d" ] && line_gauge="${line_gauge} ${line_7d}"
```

마지막 출력을 세 행으로 바꾼다.

```sh
# --- 출력: 값 없는 행은 emit 이 생략한다. ---
output=$(emit "$line_loc" "$line_meta" "$line_gauge")

printf '%s' "$output"
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh`
Expected: 전부 PASS.

- [ ] **Step 5: 커밋한다**

```bash
git add claude-statusline/scripts/statusline.sh claude-statusline/tests/statusline.test.sh
git commit -m "feat(statusline): collapse the render into three rows and drop cost display"
```

---

### Task 5: 문서와 버전을 맞춘다

**Files:**
- Modify: `README.md:1-60`
- Modify: `claude-statusline/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Test: `claude-statusline/tests/statusline.test.sh`

**Interfaces:**
- Consumes: Task 4 의 세 행 렌더
- Produces: 없음(최종 작업)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

두 매니페스트의 버전이 같은지 정적으로 확인하는 단언을 `statusline.test.sh` 끝의 합계 출력
바로 위에 넣는다.

```sh
# --- T42: 두 매니페스트의 버전이 같다 ---
PV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -1)
MV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$(dirname "$SRC")/.claude-plugin/marketplace.json" | sed -n 2p)
assert_equals "T42 plugin.json 과 marketplace.json 버전 일치" "$PV" "$MV"
assert_equals "T42 버전이 3.0.0 으로 올라감" "3.0.0" "$PV"
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh 2>&1 | grep T42`
Expected: FAIL. 현재 버전이 `2.12.0` 이라 두 번째 단언이 실패한다.

- [ ] **Step 3: 버전을 올리고 README 를 고친다**

`claude-statusline/.claude-plugin/plugin.json` 의 `"version": "2.12.0"` 을 `"version": "3.0.0"`
으로 바꾼다. `.claude-plugin/marketplace.json` 의 플러그인 항목 `"version": "2.12.0"` 도 같은
값으로 바꾼다. 최상위 카탈로그의 `"version": "1.0.0"` 은 건드리지 않는다.

`README.md` 의 첫 문단과 예시 블록, 그 아래 설명 목록을 아래로 바꾼다.

````markdown
# claude-statusline

A compact, three-row statusline HUD for [Claude Code](https://code.claude.com).
It renders location, the logged-in Claude account, git branch, GitHub/AWS
session indicators, the Claude Code session id, context-window usage, rate
limits, and reasoning effort — in three rows that never exceed 74 columns.

```
17:14 ~/↪1/webapp/↪1/src  feature/PROJ-123-post-editor
dev@example.com gh@personal aws:✓ v2.8.0 ⧉ 3f9c1a
ctx 68% Opus 4.8 ▃ 5h 47% ↺2h30m 7d 83%▲ ↺3d16h
```

The statusline always renders three rows and caps each at 74 display columns.
Rows with no data are dropped entirely. The rows group by meaning: location,
then identity and constants, then the usage gauges.

- **Row 1 (location)** — time (`HH:MM`), the current path, and the git branch
  (prefixed with the ` ` branch icon, no space before the name). The path
  collapses `$HOME` to `~`, keeps git-repo names and the current folder, and marks
  skipped segments as `↪N` (N = folders omitted). Path and branch share a
  66-column budget; when they exceed it each is capped at 33 columns, with the
  unused remainder handed to the other. Whatever still overflows is cut and
  marked with `…`. Cutting counts display columns, so a wide character (Hangul,
  CJK) is never split in half.
- **Row 2 (identity and constants)** — the logged-in Claude account email,
  `gh@<account>`, `aws:<session>`, the Claude Code version, and the session id
  (`⧉ <first 6 chars>`). Each appears only when it has a value.
- **Row 3 (gauges)** — context-window usage (`ctx`), the model name and
  reasoning-effort indicator, then the 5-hour and 7-day usage limits. Each rate
  gauge carries its percentage, a pace marker (`▲`) when usage runs ahead of the
  elapsed-time budget, and time-until-reset (`↺`). A rate gauge is dropped when
  its data is absent.
- The branch icon and session marker need a Nerd Font to render; without one
  they show as `□`.
````

`README.md` 의 `## Bars` 절 전체를 아래 `## Gauges` 절로 바꾼다.

````markdown
## Gauges

Percentages are bright by default and escalate with usage: the context gauge
turns yellow at 40% and red at 70%; the rate gauges turn yellow at 80% and red
at 90%.

The `5h` and `7d` gauges also track a time-based pace budget. Over each window
the elapsed fraction defines how much you could spend and stay on pace. When
usage runs ahead of that budget a `▲` follows the percentage — yellow for a
small overshoot, red once it exceeds 15 percentage points. No marker means you
are on or under pace.

Costs are not displayed. The background cost cache is still refreshed, so
restoring the display later needs no new collection.
````

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

Run: `sh claude-statusline/tests/statusline.test.sh && sh claude-statusline/tests/fit.test.sh`
Expected: 두 스위트 모두 `fail=0`.

README 예시가 74칼럼을 지키는지 확인한다.

Run:
```bash
sed -n '/^```$/,/^```$/p' README.md | sed -n '2,4p' \
  | LC_ALL=C awk '{ n=length($0); i=1; t=0
      while (i<=n) { c=substr($0,i,1)
        if (c < "\200") L=1; else if (c < "\340") L=2; else if (c < "\360") L=3; else L=4
        s=substr($0,i,L)
        t += (L==3 && s >= "\352\260\200" && s <= "\355\236\243") ? 2 : 1
        i += L }
      printf "%d %s\n", t, ($0) }'
```
Expected: 세 줄 모두 폭이 74 이하.

- [ ] **Step 5: 커밋한다**

```bash
git add README.md claude-statusline/.claude-plugin/plugin.json .claude-plugin/marketplace.json claude-statusline/tests/statusline.test.sh
git commit -m "docs(statusline): document the three-row layout and bump to 3.0.0"
```

---

## 남은 검증

구현을 마친 뒤 실제 저장소에서 렌더를 확인한다. 아래는 이 저장소 자신과 깊은 worktree 경로,
한글 브랜치를 각각 넣어 세 행과 74칼럼을 눈으로 확인하는 절차다.

```bash
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 5 (1M context)"},"version":"3.0.0","session_id":"11111111-2222-3333-4444-555555555555","effort":{"level":"high"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":12000,"cache_creation_input_tokens":48000,"cache_read_input_tokens":260000}},"rate_limits":{"five_hour":{"used_percentage":37.4,"resets_at":%s},"seven_day":{"used_percentage":68.2,"resets_at":%s}}}' \
  "$PWD" "$(( $(date +%s) + 7200 ))" "$(( $(date +%s) + 320000 ))" \
  | sh claude-statusline/scripts/statusline.sh
```
