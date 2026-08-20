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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
CACHE="$TMPROOT/cache"
PTR="$CACHE/claude-statusline/binary-path"
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

# --- 이하 build-binary.sh ---
BUILD="$SRC/scripts/build-binary.sh"
PLUGIN_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -1)
build() { iso "$1" env CLAUDE_PLUGIN_ROOT="$SRC" sh "$BUILD" 2>"$TMPROOT/build-err"; }

BC="$TMPROOT/build-cache"
if command -v go >/dev/null 2>&1; then
  # --- T6: 빌드 성공 뒤 포인터에 절대경로 한 줄을 남긴다 ---
  build "$BC"; RC=$?
  assert_equals "T6 빌드 종료코드 0" "0" "$RC"
  BINPATH=$(cat "$BC/claude-statusline/binary-path" 2>/dev/null || printf '')
  assert_equals   "T6 포인터가 한 줄" "1" "$(printf '%s\n' "$BINPATH" | wc -l | tr -d ' ')"
  assert_contains "T6 포인터가 절대경로" "/" "$BINPATH"
  assert_equals   "T6 포인터가 실행 가능한 파일을 가리킴" "yes" "$([ -x "$BINPATH" ] && echo yes || echo no)"
  assert_contains "T6 바이너리 이름에 플러그인 버전" "$PLUGIN_VERSION" "$BINPATH"

  # --- T7: 이미 있는 바이너리를 다시 빌드하지 않는다(mtime 불변) ---
  BEFORE=$(stat -f '%m' "$BINPATH" 2>/dev/null || stat -c '%Y' "$BINPATH")
  build "$BC" >/dev/null 2>&1
  AFTER=$(stat -f '%m' "$BINPATH" 2>/dev/null || stat -c '%Y' "$BINPATH")
  assert_equals "T7 재실행은 바이너리를 다시 만들지 않음" "$BEFORE" "$AFTER"

  # --- T8: bin 디렉터리의 옛 버전 바이너리를 지운다 ---
  BINDIR=$(dirname "$BINPATH")
  STALE="$BINDIR/statusline-0.0.0-old-arch"
  : > "$STALE"
  rm -f "$BINPATH" "$BC/claude-statusline/binary-path"
  build "$BC" >/dev/null 2>&1
  assert_equals "T8 옛 버전 바이너리 제거" "no" "$([ -e "$STALE" ] && echo yes || echo no)"
  assert_equals "T8 새 바이너리는 남음" "yes" "$([ -x "$BINPATH" ] && echo yes || echo no)"

  # --- T9: 빌드한 바이너리를 shim 이 실제로 실행해 렌더한다 ---
  OUT=$(printf '%s' "$JSON" | iso "$BC" env CLAUDE_STATUSLINE_WIDTH=81 sh "$SRC/scripts/statusline.sh")
  assert_contains "T9 shim 이 실제 바이너리로 렌더" "v9.9.9" "$OUT"
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
  "$([ -f "$NOGO/claude-statusline/binary-path" ] && echo yes || echo no)"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
