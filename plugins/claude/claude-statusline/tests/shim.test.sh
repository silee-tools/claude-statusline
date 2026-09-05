#!/bin/sh
# statusline.sh(shim)와 build-binary.sh 의 계약 테스트.
# shim 은 포인터 파일이 가리키는 바이너리로 exec 하고, 없으면 종료코드 0 으로 한 줄 저하
# 표시를 낸다. build-binary.sh 는 멱등이고, go 가 없어도 세션 시작을 막지 않는다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }
assert_equals()   { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (expected to contain [$2])" "$3";; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1 (expected not to contain [$2])" "$3";; *) ok "$1";; esac; }

TMPROOT=$(mktemp -d)
# bash 3.2 는 EXIT 트랩 진입에서 $? 를 0 으로 만든다. completed 플래그가 없으면 set -eu 중단이
# 종료코드 0 으로 보고된다. 정본은 AGENTS.md 의 Testing 절이다.
completed=0
trap 'rc=$?; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT
CACHE="$TMPROOT/cache"
# 포인터는 플러그인 루트 디렉터리 이름으로 갈린다. 스위트는 저장소에서 직접 돌므로 그
# 이름이 곧 키다 — 설치본이라면 여기에 버전이 온다.
KEY=${SRC##*/}
PTR="$CACHE/claude-statusline/binary-path-$KEY"
mkdir -p "$CACHE/claude-statusline"

JSON='{"workspace":{"current_dir":"/tmp"},"version":"9.9.9"}'

# 실제 홈의 계정·자격증명을 읽지 않도록 모든 조회 경로를 TMPROOT 로 돌린다. 첫 인자는
# 그 실행이 쓸 캐시 디렉터리이고 나머지가 실행할 명령이다.
iso() {
  _cache="$1"; shift
  env HOME="$TMPROOT" XDG_CACHE_HOME="$_cache" XDG_DATA_HOME="$TMPROOT" \
      XDG_CONFIG_HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$TMPROOT" \
      AWS_SHARED_CREDENTIALS_FILE="$TMPROOT/no-aws" "$@"
}
run_shim() { printf '%s' "$JSON" | iso "$CACHE" sh "$SRC/scripts/statusline.sh"; }

# --- T1: 포인터가 가리키는 바이너리의 출력을 그대로 낸다 ---
STUB="$TMPROOT/stub-binary"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin:%s' "$line"; done
printf ' rendered-by-binary'
STUBEOF
chmod +x "$STUB"
printf '%s\n' "$STUB" > "$PTR"
OUT=$(run_shim); RC=$?
assert_equals   "T1 바이너리가 있으면 종료코드 0" "0" "$RC"
assert_contains "T1 바이너리 출력을 그대로 낸다" "rendered-by-binary" "$OUT"
assert_contains "T1 stdin 을 바이너리에 그대로 넘긴다" '"current_dir":"/tmp"' "$OUT"

# --- T2: 바이너리가 없으면 종료코드 0 으로 한 줄 저하 표시 ---
rm -f "$PTR"
OUT=$(run_shim); RC=$?
assert_equals "T2 포인터 부재에도 종료코드 0" "0" "$RC"
assert_equals "T2 출력이 비지 않음" "no" "$([ -z "$OUT" ] && echo yes || echo no)"
assert_equals "T2 저하 표시는 한 줄" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

# --- T3: 저하 표시에 현재 경로와 무엇이 없는지가 들어간다 ---
#     시각은 넣지 않는다 — date 가 프로세스를 하나 더 만들어 shim 이 지불하는 비용이 늘고,
#     이 경로는 바이너리가 준비되기 전에만 지나가므로 경로와 상태만 알리면 된다.
assert_contains "T3 저하 표시에 현재 경로" "$PWD" "$OUT"
assert_contains "T3 저하 표시에 준비 상태" "statusline" "$OUT"

# --- T4: 포인터가 실행 불가 경로를 가리켜도 저하로 내려간다 ---
printf '%s\n' "$TMPROOT/nope" > "$PTR"
OUT=$(run_shim); RC=$?
assert_equals   "T4 실행 불가 포인터에도 종료코드 0" "0" "$RC"
assert_contains "T4 실행 불가 포인터는 저하 표시" "statusline" "$OUT"

# --- T5: shim 은 저하 경로에서도 외부 명령을 부르지 않는다 ---
#     PATH 를 비우면 내장 명령만 산다. 저하 표시가 그대로 나오고 stderr 가 비면 외부 명령이
#     없다는 뜻이다.
rm -f "$PTR"
OUT=$(printf '%s' "$JSON" | iso "$CACHE" env PATH= /bin/sh "$SRC/scripts/statusline.sh" 2>"$TMPROOT/err"); RC=$?
assert_equals   "T5 빈 PATH 에서도 종료코드 0" "0" "$RC"
assert_contains "T5 빈 PATH 에서도 저하 표시" "statusline" "$OUT"
assert_equals   "T5 빈 PATH 에서 stderr 가 비어 있음(외부 명령 미호출)" "" "$(cat "$TMPROOT/err")"

# --- T12: shim 은 자기 플러그인 루트 이름을 키로 한 포인터를 읽는다 ---
#     shim 은 settings.json 에 한 버전 경로로 고정되지만 SessionStart 훅은 버전마다 따로
#     돈다. 포인터가 하나면 각 버전의 훅이 그 한 줄을 서로 덮어써, 고정된 shim 이 다른
#     버전의 바이너리를 실행하거나 지워진 경로를 실행한다.
KEYROOT="$TMPROOT/keyed/5.9.9"
mkdir -p "$KEYROOT/scripts"
cp "$SRC/scripts/statusline.sh" "$KEYROOT/scripts/statusline.sh"
printf '%s\n' "$STUB" > "$CACHE/claude-statusline/binary-path-5.9.9"
printf '%s\n' "$TMPROOT/nope" > "$CACHE/claude-statusline/binary-path"
OUT=$(printf '%s' "$JSON" | iso "$CACHE" sh "$KEYROOT/scripts/statusline.sh")
assert_contains "T12 자기 키의 포인터로 렌더" "rendered-by-binary" "$OUT"
rm -f "$CACHE/claude-statusline/binary-path-5.9.9" "$CACHE/claude-statusline/binary-path"

# --- 이하 build-binary.sh ---
BUILD="$SRC/scripts/build-binary.sh"
PLUGIN_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -1)
build() { iso "$1" env CLAUDE_PLUGIN_ROOT="$SRC" sh "$BUILD" 2>"$TMPROOT/build-err"; }

BC="$TMPROOT/build-cache"
if command -v go >/dev/null 2>&1; then
  # --- T6: 빌드 성공 뒤 포인터에 절대경로 한 줄을 남긴다 ---
  build "$BC"; RC=$?
  assert_equals "T6 빌드 종료코드 0" "0" "$RC"
  BINPATH=$(cat "$BC/claude-statusline/binary-path-$KEY" 2>/dev/null || printf '')
  assert_equals   "T6 포인터가 한 줄" "1" "$(printf '%s\n' "$BINPATH" | wc -l | tr -d ' ')"
  assert_contains "T6 포인터가 절대경로" "/" "$BINPATH"
  assert_equals   "T6 포인터가 실행 가능한 파일을 가리킴" "yes" "$([ -x "$BINPATH" ] && echo yes || echo no)"
  assert_contains "T6 바이너리 이름에 플러그인 버전" "$PLUGIN_VERSION" "$BINPATH"

  # --- T7: 이미 있는 바이너리를 다시 빌드하지 않는다(mtime 불변) ---
  BEFORE=$(stat -f '%m' "$BINPATH" 2>/dev/null || stat -c '%Y' "$BINPATH")
  build "$BC" >/dev/null 2>&1
  AFTER=$(stat -f '%m' "$BINPATH" 2>/dev/null || stat -c '%Y' "$BINPATH")
  assert_equals "T7 재실행은 바이너리를 다시 만들지 않음" "$BEFORE" "$AFTER"

  # --- T8: 설치돼 있지 않은 버전의 바이너리만 지운다 ---
  #     지워진 바이너리의 주인 세션은 다음 렌더에서 저하 표시로 떨어진다. 그래서 정리는
  #     플러그인 루트의 형제로 남아 있지 않은 버전에만 미친다.
  BINDIR=$(dirname "$BINPATH")
  STALE="$BINDIR/statusline-0.0.0-old-arch"
  LIVE="$BINDIR/statusline-9.9.9-old-arch"
  : > "$STALE"
  : > "$LIVE"
  mkdir -p "$(dirname "$SRC")/9.9.9"
  rm -f "$BINPATH" "$BC/claude-statusline/binary-path-$KEY"
  build "$BC" >/dev/null 2>&1
  rmdir "$(dirname "$SRC")/9.9.9"
  assert_equals "T8 설치돼 있지 않은 버전은 제거" "no" "$([ -e "$STALE" ] && echo yes || echo no)"
  assert_equals "T8 설치돼 있는 버전은 보존" "yes" "$([ -e "$LIVE" ] && echo yes || echo no)"
  assert_equals "T8 새 바이너리는 남음" "yes" "$([ -x "$BINPATH" ] && echo yes || echo no)"
  rm -f "$LIVE"

  # --- T8b: 다른 빌드가 원자 교체를 위해 둔 임시 바이너리는 건드리지 않는다 ---
  OTHER_TMP="$BINDIR/statusline-other-goos-goarch.tmp.99999"
  : > "$OTHER_TMP"
  rm -f "$BINPATH" "$BC/claude-statusline/binary-path-$KEY"
  build "$BC" >/dev/null 2>&1
  assert_equals "T8b 다른 빌드 임시 바이너리 보존" "yes" "$([ -e "$OTHER_TMP" ] && echo yes || echo no)"
  rm -f "$OTHER_TMP"

  # --- T8a: 다른 키의 포인터를 건드리지 않는다 ---
  OTHER="$BC/claude-statusline/binary-path-4.0.0"
  printf '%s\n' "/nonexistent/other-binary" > "$OTHER"
  build "$BC" >/dev/null 2>&1
  assert_equals "T8a 다른 버전의 포인터는 그대로" "/nonexistent/other-binary" "$(cat "$OTHER")"
  rm -f "$OTHER"

  # --- T9: 빌드한 바이너리를 shim 이 실제로 실행해 렌더한다 ---
  OUT=$(printf '%s' "$JSON" | iso "$BC" env CLAUDE_STATUSLINE_WIDTH=81 sh "$SRC/scripts/statusline.sh")
  assert_contains "T9 shim 이 실제 바이너리로 렌더" "v9.9.9" "$OUT"

  # --- T9a: hook handler가 준비된 같은 바이너리로 activity를 기록한다 ---
  STATE="$TMPROOT/agent-status"
  SECRET="SENTINEL_PROMPT_AND_TOOL_ARGUMENT"
  HOOK_JSON="{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"placeholder-session\",\"cwd\":\"/tmp/example-project\",\"prompt\":\"$SECRET\",\"response\":\"$SECRET\",\"tool_input\":{\"value\":\"$SECRET\"}}"
  OUT=$(printf '%s' "$HOOK_JSON" | iso "$BC" env CLAUDE_PLUGIN_ROOT="$SRC" \
    AGENT_STATUS_STATE_DIR="$STATE" sh "$SRC/scripts/hook-handler.sh"); RC=$?
  assert_equals "T9a hook handler 종료코드 0" "0" "$RC"
  assert_equals "T9a hook handler는 화면 출력을 만들지 않음" "" "$OUT"
  set -- "$STATE/sessions/claude/"*.json
  SNAPSHOT="$1"
  assert_equals "T9a session snapshot 생성" "yes" "$([ -f "$SNAPSHOT" ] && echo yes || echo no)"
  SNAPSHOT_BODY=$(cat "$SNAPSHOT")
  assert_contains "T9a UserPromptSubmit은 working" '"activity":"working"' "$SNAPSHOT_BODY"
  assert_not_contains "T9a prompt 원문은 기록하지 않음" "$SECRET" "$SNAPSHOT_BODY"

# --- T9b: render는 activity를 보존하며 resolved usage를 같은 snapshot에 기록한다 ---
  RENDER_JSON='{"session_id":"placeholder-session","workspace":{"current_dir":"/tmp/render-project"},"model":{"display_name":"example-model"},"context_window":{"current_usage":{"input_tokens":1},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1890000000},"seven_day":{"used_percentage":41,"resets_at":1890600000}}}'
  RENDER_JSON="${RENDER_JSON%?},\"prompt\":\"$SECRET\",\"response\":\"$SECRET\",\"tool_arguments\":{\"value\":\"$SECRET\"}}"
  OUT=$(printf '%s' "$RENDER_JSON" | iso "$BC" env AGENT_STATUS_STATE_DIR="$STATE" \
    CLAUDE_STATUSLINE_WIDTH=81 sh "$SRC/scripts/statusline.sh"); RC=$?
  assert_equals "T9b render 종료코드 0" "0" "$RC"
  assert_contains "T9b 기존 statusline 출력 유지" "v2.1.11" "$OUT"
  SNAPSHOT_BODY=$(cat "$SNAPSHOT")
  assert_contains "T9b render가 activity 보존" '"activity":"working"' "$SNAPSHOT_BODY"
  assert_contains "T9b five-hour usage 기록" '"id":"five-hour","label":"5 hour","usedPercent":24' "$SNAPSHOT_BODY"
  assert_contains "T9b seven-day usage 기록" '"id":"seven-day","label":"7 day","usedPercent":41' "$SNAPSHOT_BODY"
  assert_not_contains "T9b render 원문은 기록하지 않음" "$SECRET" "$SNAPSHOT_BODY"

  # --- T9c: 상태 저장 실패가 render를 실패시키거나 출력을 바꾸지 않는다 ---
  BAD_STATE="$TMPROOT/not-a-directory"
  : > "$BAD_STATE"
  OUT=$(printf '%s' "$RENDER_JSON" | iso "$BC" env AGENT_STATUS_STATE_DIR="$BAD_STATE" \
    CLAUDE_STATUSLINE_WIDTH=81 sh "$SRC/scripts/statusline.sh"); RC=$?
  assert_equals "T9c 상태 저장 실패에도 render 종료코드 0" "0" "$RC"
  assert_contains "T9c 상태 저장 실패에도 화면 출력 유지" "v2.1.11" "$OUT"
else
  printf 'SKIP T6~T9 (go 미설치)\n'
fi

# --- T10: go 가 없으면 종료코드 0 으로 조용히 끝난다(세션 시작을 막지 않는다) ---
NOGO="$TMPROOT/nogo-cache"
EMPTYBIN="$TMPROOT/emptybin"
mkdir -p "$EMPTYBIN"
for c in sed rm mv mkdir cat head dirname; do
  real=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$real" "$EMPTYBIN/$c"
done
set +e
iso "$NOGO" env CLAUDE_PLUGIN_ROOT="$SRC" PATH="$EMPTYBIN" /bin/sh "$BUILD" >/dev/null 2>&1
RC=$?
set -e
assert_equals "T10 go 부재에도 종료코드 0" "0" "$RC"
assert_equals "T10 go 부재면 포인터를 만들지 않음" "no" \
  "$([ -f "$NOGO/claude-statusline/binary-path-$KEY" ] && echo yes || echo no)"

# --- T11: 지원하는 모든 Claude event가 같은 handler에 등록돼 있다 ---
HOOKS=$(awk -f "$SRC/scripts/json.awk" "$SRC/hooks/hooks.json")
TAB=$(printf '\t')
for event in SessionStart UserPromptSubmit PermissionRequest Notification Stop SessionEnd; do
  assert_contains "T11 $event hook 등록" \
    "..hooks.$event.hooks.command${TAB}sh \"\${CLAUDE_PLUGIN_ROOT}/scripts/hook-handler.sh\"" "$HOOKS"
done

# --- T13: 공백이 있는 설치 경로도 statusLine.command 로 원자적으로 설정한다 ---
SETUP_ROOT="$TMPROOT/plugin \" root\\slash"
SETUP_HOME="$TMPROOT/setup-home"
mkdir -p "$SETUP_ROOT/scripts" "$SETUP_HOME/.claude"
cp "$SRC/scripts/hook-handler.sh" "$SRC/scripts/json.awk" "$SRC/scripts/settings-update.awk" "$SETUP_ROOT/scripts/"
printf '%s\n' '{"permissions":{"allow":["Read"]}}' > "$SETUP_HOME/.claude/settings.json"
chmod 600 "$SETUP_HOME/.claude/settings.json"
OUT=$(printf '%s' '{"hook_event_name":"SessionStart"}' | \
  env HOME="$SETUP_HOME" XDG_CACHE_HOME="$TMPROOT/setup-cache" CLAUDE_PLUGIN_ROOT="$SETUP_ROOT" \
  sh "$SETUP_ROOT/scripts/hook-handler.sh"); RC=$?
assert_equals "T13 공백 설치 경로 자동 설정 종료코드 0" "0" "$RC"
SETUP_CMD=$(awk -f "$SETUP_ROOT/scripts/json.awk" "$SETUP_HOME/.claude/settings.json" \
  | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}')
assert_equals "T13 공백 설치 경로를 shell 인용으로 보존" "sh '$SETUP_ROOT/scripts/statusline.sh'" "$SETUP_CMD"
SETUP_ALLOW=$(awk -f "$SETUP_ROOT/scripts/json.awk" "$SETUP_HOME/.claude/settings.json" \
  | awk -F"$TAB" '$1=="..permissions.allow"{print $2; exit}')
assert_equals "T13 기존 permissions 보존" "Read" "$SETUP_ALLOW"
SETUP_MODE=$(stat -c '%a' "$SETUP_HOME/.claude/settings.json" 2>/dev/null || stat -f '%Lp' "$SETUP_HOME/.claude/settings.json")
assert_equals "T13 기존 settings 권한 보존" "600" "$SETUP_MODE"

# --- T13b: GNU stat 호환 경로가 BSD 형식 시도의 부분 stdout과 섞이지 않는다 ---
STAT_BIN="$TMPROOT/stat-bin"
mkdir -p "$STAT_BIN"
cat > "$STAT_BIN/stat" <<'STATEOF'
#!/bin/sh
case "$1" in
  -f) printf 'filesystem-description\n'; exit 1 ;;
  -c) printf '600\n' ;;
  *) exit 1 ;;
esac
STATEOF
chmod +x "$STAT_BIN/stat"
GNU_HOME="$TMPROOT/gnu-stat-home"
mkdir -p "$GNU_HOME/.claude"
printf '%s\n' '{"permissions":{"allow":["Read"]}}' > "$GNU_HOME/.claude/settings.json"
chmod 600 "$GNU_HOME/.claude/settings.json"
env HOME="$GNU_HOME" XDG_CACHE_HOME="$TMPROOT/gnu-stat-cache" CLAUDE_PLUGIN_ROOT="$SETUP_ROOT" \
  PATH="$STAT_BIN:/usr/bin:/bin" sh "$SETUP_ROOT/scripts/hook-handler.sh" \
  <<'GNUJSON'
{"hook_event_name":"SessionStart"}
GNUJSON
GNU_CMD=$(awk -f "$SETUP_ROOT/scripts/json.awk" "$GNU_HOME/.claude/settings.json" \
  | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}')
assert_equals "T13b GNU stat 부분 stdout 뒤에도 statusLine 자동 설정" "sh '$SETUP_ROOT/scripts/statusline.sh'" "$GNU_CMD"
GNU_MODE=$(stat -c '%a' "$GNU_HOME/.claude/settings.json" 2>/dev/null || stat -f '%Lp' "$GNU_HOME/.claude/settings.json")
assert_equals "T13b GNU stat 부분 stdout 뒤에도 settings 권한 보존" "600" "$GNU_MODE"

# --- T13c: 권한 조회가 모두 실패하면 원본 settings를 유지한다 ---
FAIL_STAT_BIN="$TMPROOT/fail-stat-bin"
mkdir -p "$FAIL_STAT_BIN"
cat > "$FAIL_STAT_BIN/stat" <<'FAILSTATEOF'
#!/bin/sh
printf 'unusable-stat-output\n'
exit 1
FAILSTATEOF
chmod +x "$FAIL_STAT_BIN/stat"
FAIL_HOME="$TMPROOT/fail-stat-home"
mkdir -p "$FAIL_HOME/.claude"
printf '%s\n' '{"permissions":{"allow":["Read"]}}' > "$FAIL_HOME/.claude/settings.json"
chmod 600 "$FAIL_HOME/.claude/settings.json"
env HOME="$FAIL_HOME" XDG_CACHE_HOME="$TMPROOT/fail-stat-cache" CLAUDE_PLUGIN_ROOT="$SETUP_ROOT" \
  PATH="$FAIL_STAT_BIN:/usr/bin:/bin" sh "$SETUP_ROOT/scripts/hook-handler.sh" \
  2>"$TMPROOT/fail-stat.err" \
  <<'FAILJSON'
{"hook_event_name":"SessionStart"}
FAILJSON
FAIL_CMD=$(awk -f "$SETUP_ROOT/scripts/json.awk" "$FAIL_HOME/.claude/settings.json" \
  | awk -F"$TAB" '$1=="..statusLine.command"{print $2; exit}')
assert_equals "T13c 권한 조회 실패 시 statusLine 자동 설정 건너뜀" "" "$FAIL_CMD"
assert_equals "T13c 권한 조회 실패 시 chmod를 호출하지 않음" "" "$(cat "$TMPROOT/fail-stat.err")"
FAIL_MODE=$(stat -c '%a' "$FAIL_HOME/.claude/settings.json" 2>/dev/null || stat -f '%Lp' "$FAIL_HOME/.claude/settings.json")
assert_equals "T13c 권한 조회 실패 시 settings 권한 보존" "600" "$FAIL_MODE"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
