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
# 세션이 export 한 CLAUDE_CONFIG_DIR 는 HOME 보다 우선하므로, 격리를 빠뜨린 호출이 hook-handler.sh 로 실제
# settings.json 을 고치지 않게 스위트 기본값을 TMPROOT 안으로 돌린다.
CLAUDE_CONFIG_DIR="$TMPROOT/claude-config"; export CLAUDE_CONFIG_DIR
# 상태·데이터·캐시·설정도 같은 이유로 TMPROOT 안에 둔다. 호출마다 지정하지 않은 경로가 호출자의 값(실제 홈의
# 수신기 게시 경로나 상태 폴더)으로 새지 않게 하고, 어긋나 있으면 시작하지 않는다.
HOME="$TMPROOT/home"; XDG_DATA_HOME="$TMPROOT/data"; XDG_STATE_HOME="$TMPROOT/state"
XDG_CACHE_HOME="$TMPROOT/cache"; XDG_CONFIG_HOME="$TMPROOT/config"
export HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME
for _v in "$HOME" "$CLAUDE_CONFIG_DIR" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"; do
  case "$_v" in "$TMPROOT"*) ;; *) echo "FATAL: 격리되지 않은 경로 $_v" >&2; exit 1;; esac
done
mkdir -p "$HOME"
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
  env HOME="$TMPROOT" XDG_CACHE_HOME="$_cache" XDG_DATA_HOME="$TMPROOT/data" \
      XDG_STATE_HOME="$TMPROOT/state" XDG_CONFIG_HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$TMPROOT" \
      AWS_LOGIN_CACHE_DIR="$TMPROOT/no-aws-cache" "$@"
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

# 설정이 필요 없는 이벤트는 경로 helper를 실행하지 않는다.
HOOK_ROOT="$TMPROOT/activity-only"
mkdir -p "$HOOK_ROOT/scripts"
cp "$SRC/scripts/hook-handler.sh" "$SRC/scripts/json.awk" "$HOOK_ROOT/scripts/"
printf 'exit 99\n' > "$HOOK_ROOT/scripts/config-paths.sh"
if printf '{"hook_event_name":"UserPromptSubmit"}' | iso "$CACHE" env CLAUDE_PLUGIN_ROOT="$HOOK_ROOT" sh "$HOOK_ROOT/scripts/hook-handler.sh"; then
  ok "T15 activity 이벤트는 설정 helper를 실행하지 않음"
else
  bad "T15 activity 이벤트는 설정 helper를 실행하지 않음" "$?"
fi

# --- 이하 build-binary.sh ---
BUILD="$SRC/scripts/build-binary.sh"
PLUGIN_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -1)
build() { iso "$1" env CLAUDE_PLUGIN_ROOT="$SRC" sh "$BUILD" 2>"$TMPROOT/build-err"; }

# 서로 다른 계정의 plugin 판본은 공용 binary/pointer를 함께 사용한다.
MULTI="$TMPROOT/multi-account"
mkdir -p "$MULTI/tools"
cat > "$MULTI/tools/go" <<'GOEOF'
#!/bin/sh
if [ "$1" = env ]; then
  case "$2" in GOOS) echo fixture ;; GOARCH) echo arch ;; esac
  exit 0
fi
while [ "$1" != -o ]; do shift; done
shift
printf '#!/bin/sh\nexit 0\n' > "$1"
chmod +x "$1"
GOEOF
chmod +x "$MULTI/tools/go"
for pair in 'account-a:5.5.1' 'account-b:5.5.2'; do
  account=${pair%:*}; version=${pair#*:}
  root="$MULTI/$account/$version"
  mkdir -p "$root/.claude-plugin" "$root/scripts"
  printf '{"version":"%s"}\n' "$version" > "$root/.claude-plugin/plugin.json"
  cp "$BUILD" "$root/scripts/build-binary.sh"
done
multi_build() {
  root="$MULTI/$1/$2"
  env PATH="$MULTI/tools:$PATH" HOME="$TMPROOT" XDG_CACHE_HOME="$MULTI/cache" \
    XDG_DATA_HOME="$MULTI/data" XDG_STATE_HOME="$MULTI/state" \
    CLAUDE_CONFIG_DIR="$MULTI/$1" CLAUDE_PLUGIN_ROOT="$root" sh "$root/scripts/build-binary.sh"
}
multi_build account-a 5.5.1
A_PTR="$MULTI/cache/claude-statusline/binary-path-5.5.1"
A_BIN=$(cat "$A_PTR")
A_BEFORE=$(cksum < "$A_BIN")
GAP_BIN="$MULTI/cache/claude-statusline/bin/statusline-5.5.3-fixture-arch"
printf 'published-before-pointer\n' > "$GAP_BIN"
multi_build account-b 5.5.2
assert_equals "T14 다른 계정 binary 보존" "$A_BEFORE" "$(cksum < "$A_BIN")"
assert_equals "T14 다른 계정 pointer 보존" "$A_BIN" "$(cat "$A_PTR")"
assert_equals "T14 pointer publish 전 binary 보존" "published-before-pointer" "$(cat "$GAP_BIN")"
B_BIN=$(cat "$MULTI/cache/claude-statusline/binary-path-5.5.2")
rm -f "$A_BIN"
multi_build account-a 5.5.1
assert_equals "T14 반대 순서에서도 다른 계정 binary 보존" yes "$([ -x "$B_BIN" ] && echo yes || echo no)"

# --- T16: 수신기 바이너리는 렌더 바이너리와 같은 방식으로 빌드하고 공용 경로에 복사+rename 으로 게시한다 ---
#     LaunchAgent 는 판본이 들어간 캐시 경로를 따라갈 수 없으므로 고정 경로가 필요하다. 게시는 설치된
#     판본(.version)보다 같거나 높을 때만 하고, 같은 판본이 이미 게시돼 있으면 건드리지 않는다 — 수신기는
#     자기 실행 파일이 바뀌면 재시작하므로 쓸데없는 교체가 곧 재시작이다.
PUB_DIR="$MULTI/data/claude-statusline/bin"
PUB="$PUB_DIR/claude-statusline-otlp"
PUB_VER="$PUB.version"
file_id()  { ls -i "$1" | awk '{print $1}'; }
file_mode(){ stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
CACHE_BIN="$MULTI/cache/claude-statusline/bin"
assert_equals "T16 가장 높은 판본이 고정 경로에 실행 가능한 파일로 게시됨" yes "$([ -x "$PUB" ] && echo yes || echo no)"
assert_equals "T16 게시된 판본 파일은 가장 높은 판본" "5.5.2" "$(cat "$PUB_VER" 2>/dev/null)"
assert_equals "T16 게시 파일 mode 755" "755" "$(file_mode "$PUB")"
assert_equals "T16 캐시 쪽에도 판본이 들어간 수신기 바이너리" yes "$([ -x "$CACHE_BIN/claude-statusline-otlp-5.5.1-fixture-arch" ] && echo yes || echo no)"
assert_equals "T16 게시 파일은 가장 높은 판본(5.5.2)의 빌드와 같다" "$(cksum < "$CACHE_BIN/claude-statusline-otlp-5.5.2-fixture-arch")" "$(cksum < "$PUB")"
assert_equals "T16 게시 폴더에 임시 파일이 남지 않음" "claude-statusline-otlp claude-statusline-otlp.version" "$(ls "$PUB_DIR" | tr '\n' ' ' | sed 's/ $//')"

PUB_ID=$(file_id "$PUB")
multi_build account-b 5.5.2
assert_equals "T16 같은 판본 재실행은 게시 파일을 교체하지 않음(멱등)" "$PUB_ID" "$(file_id "$PUB")"

multi_build account-a 5.5.1
assert_equals "T16 낮은 판본은 게시하지 않음" "5.5.2" "$(cat "$PUB_VER")"
assert_equals "T16 낮은 판본은 게시 파일을 건드리지 않음" "$PUB_ID" "$(file_id "$PUB")"

rm -f "$PUB"
multi_build account-b 5.5.2
assert_equals "T16 게시 파일이 지워졌으면 같은 판본도 다시 게시" yes "$([ -x "$PUB" ] && echo yes || echo no)"

for v in 5.9.0 5.10.0; do
  mkdir -p "$MULTI/account-c/$v/.claude-plugin" "$MULTI/account-c/$v/scripts"
  printf '{"version":"%s"}\n' "$v" > "$MULTI/account-c/$v/.claude-plugin/plugin.json"
  cp "$BUILD" "$MULTI/account-c/$v/scripts/build-binary.sh"
done
multi_build account-c 5.9.0
assert_equals "T16 높은 판본(5.9.0)이 낮은 판본(5.5.2)을 교체" "5.9.0" "$(cat "$PUB_VER")"
OLD_ID=$(file_id "$PUB")
multi_build account-c 5.10.0
assert_equals "T16 판본은 숫자로 비교(5.10.0 > 5.9.0)" "5.10.0" "$(cat "$PUB_VER")"
assert_equals "T16 높은 판본을 게시하면 파일이 교체됨" "no" "$([ "$OLD_ID" = "$(file_id "$PUB")" ] && echo yes || echo no)"
multi_build account-c 5.9.0
assert_equals "T16 숫자 비교로 5.9.0 은 5.10.0 을 되돌리지 못함" "5.10.0" "$(cat "$PUB_VER")"

# --- T17: 수신기 게시 구간은 게시 폴더 단위로 직렬화된다 ---
#     서로 다른 판본의 훅이 동시에 옛 판본을 읽으면 낮은 판본이 높은 판본을 덮고 .version 이 실행 파일과
#     어긋난다. 잠금을 잡고 있는 동안에는 게시하지 않고, 풀리면 게시하며, 비정상 종료가 남긴 잠금은 버린다.
VERGO="$MULTI/vertools"
mkdir -p "$VERGO"
cat > "$VERGO/go" <<'GOEOF'
#!/bin/sh
if [ "$1" = env ]; then
  case "$2" in GOOS) echo fixture ;; GOARCH) echo arch ;; esac
  exit 0
fi
while [ "$1" != -o ]; do shift; done
shift
printf '#!/bin/sh\n# %s\nexit 0\n' "$1" > "$1"
chmod +x "$1"
GOEOF
chmod +x "$VERGO/go"
mkplug() {
  mkdir -p "$MULTI/account-e/$1/.claude-plugin" "$MULTI/account-e/$1/scripts"
  printf '{"version":"%s"}\n' "$1" > "$MULTI/account-e/$1/.claude-plugin/plugin.json"
  cp "$BUILD" "$MULTI/account-e/$1/scripts/build-binary.sh"
}
lock_build() {
  env PATH="$VERGO:$PATH" HOME="$TMPROOT" XDG_CACHE_HOME="$MULTI/lock-cache" XDG_DATA_HOME="$MULTI/lock-data" \
    XDG_STATE_HOME="$MULTI/lock-state" CLAUDE_CONFIG_DIR="$MULTI/account-e" CLAUDE_PLUGIN_ROOT="$MULTI/account-e/$1" \
    sh "$MULTI/account-e/$1/scripts/build-binary.sh"
}
LPUB_DIR="$MULTI/lock-data/claude-statusline/bin"
LOCK="$LPUB_DIR/.publish.lock"
mkplug 8.0.0
lock_build 8.0.0
assert_equals "T17 잠금이 없으면 게시함" "8.0.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
assert_equals "T17 게시가 끝나면 잠금을 풀어 둠" no "$([ -e "$LOCK" ] && echo yes || echo no)"

mkplug 8.1.0
mkdir "$LOCK"
lock_build 8.1.0 &
HELD_PID=$!
sleep 1
assert_equals "T17 잠금을 다른 게시자가 잡고 있는 동안에는 게시하지 않음" "8.0.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
rmdir "$LOCK"
wait "$HELD_PID"
assert_equals "T17 잠금이 풀리면 게시함" "8.1.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
assert_contains "T17 게시된 실행 파일이 .version 의 판본" "-8.1.0-" "$(cat "$LPUB_DIR/claude-statusline-otlp")"
assert_equals "T17 기다렸다 게시한 뒤에도 잠금을 풀어 둠" no "$([ -e "$LOCK" ] && echo yes || echo no)"

mkplug 8.2.0
mkdir "$LOCK"
touch -t 200001010000 "$LOCK"
lock_build 8.2.0
assert_equals "T17 비정상 종료가 남긴 낡은 잠금은 버리고 게시함" "8.2.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
assert_equals "T17 낡은 잠금을 치운 뒤 잠금을 풀어 둠" no "$([ -e "$LOCK" ] && echo yes || echo no)"

# 서로 다른 판본의 게시자가 한꺼번에 경합해도 최종 실행 파일과 .version 이 가장 높은 판본으로 일치한다.
for v in 9.0.0 9.1.0 9.2.0 9.3.0 9.4.0 9.5.0 9.6.0 9.7.0; do mkplug "$v"; done
for v in 9.3.0 9.7.0 9.0.0 9.5.0 9.1.0 9.6.0 9.2.0 9.4.0; do lock_build "$v" & done
wait
assert_equals "T17 동시 게시 뒤 .version 은 가장 높은 판본" "9.7.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
assert_contains "T17 동시 게시 뒤 실행 파일도 가장 높은 판본의 빌드" "-9.7.0-" "$(cat "$LPUB_DIR/claude-statusline-otlp")"
assert_equals "T17 동시 게시 뒤 잠금을 풀어 둠" no "$([ -e "$LOCK" ] && echo yes || echo no)"

# 두 게시자가 같은 낡은 잠금을 회수하는 교차: 둘째가 "낡았다"고 본 뒤 첫째가 그 잠금을 치우고 새 잠금을 잡아 복사
# 중일 때 둘째가 움직인다. 회수가 보고 지우는 두 단계라면 둘째가 첫째의 새 잠금을 지우고 같은 구간에 함께 들어간다.
# find 대역이 둘째의 첫 낡음 판정을 첫째가 구간 안에 들어갈 때까지 붙들고, cp 대역이 구간의 점유를 표시한다.
RACE="$MULTI/racetools"
mkdir -p "$RACE"
REAL_FIND=$(command -v find)
REAL_CP=$(command -v cp)
cat > "$RACE/find" <<FINDEOF
#!/bin/sh
if [ -n "\${HOLD_FIRST_FIND:-}" ] && [ ! -e "\$HOLD_FIRST_FIND" ]; then
  out=\$("$REAL_FIND" "\$@")
  : > "\$HOLD_FIRST_FIND"
  n=0
  while [ ! -d "\$RACE_OCCUPIED" ] && [ "\$n" -lt 100 ]; do sleep 0.05; n=\$((n + 1)); done
  [ -z "\$out" ] || printf '%s\n' "\$out"
  exit 0
fi
exec "$REAL_FIND" "\$@"
FINDEOF
cat > "$RACE/cp" <<CPEOF
#!/bin/sh
if mkdir "\$RACE_OCCUPIED" 2>/dev/null; then
  sleep 1
  "$REAL_CP" "\$@"
  rc=\$?
  rmdir "\$RACE_OCCUPIED"
  exit \$rc
fi
echo overlap >> "\$RACE_LOG"
exec "$REAL_CP" "\$@"
CPEOF
chmod +x "$RACE/find" "$RACE/cp"
race_build() {
  v=$1
  shift
  env "$@" PATH="$RACE:$VERGO:$PATH" HOME="$TMPROOT" XDG_CACHE_HOME="$MULTI/lock-cache" XDG_DATA_HOME="$MULTI/lock-data" \
    XDG_STATE_HOME="$MULTI/lock-state" CLAUDE_CONFIG_DIR="$MULTI/account-e" CLAUDE_PLUGIN_ROOT="$MULTI/account-e/$v" \
    RACE_OCCUPIED="$MULTI/race-occupied" RACE_LOG="$MULTI/race.log" \
    sh "$MULTI/account-e/$v/scripts/build-binary.sh"
}
mkplug 10.0.0
mkplug 10.1.0
rm -rf "$MULTI/race-occupied" "$MULTI/race.log" "$MULTI/race-held"
mkdir "$LOCK"
touch -t 200001010000 "$LOCK"
race_build 10.1.0 HOLD_FIRST_FIND="$MULTI/race-held" &
SECOND_PID=$!
n=0
while [ ! -e "$MULTI/race-held" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
race_build 10.0.0 &
FIRST_PID=$!
wait "$FIRST_PID"
wait "$SECOND_PID"
assert_equals "T17 낡은 잠금을 두 게시자가 동시에 회수해도 복사 구간에 함께 들어가지 않음" no "$([ -e "$MULTI/race.log" ] && echo yes || echo no)"
assert_equals "T17 낡은 잠금을 회수한 경합 뒤 .version 은 가장 높은 판본" "10.1.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
assert_contains "T17 낡은 잠금을 회수한 경합 뒤 실행 파일도 가장 높은 판본의 빌드" "-10.1.0-" "$(cat "$LPUB_DIR/claude-statusline-otlp")"
assert_equals "T17 낡은 잠금을 회수한 경합 뒤 잠금을 풀어 둠" no "$([ -e "$LOCK" ] && echo yes || echo no)"
assert_equals "T17 낡은 잠금을 회수한 경합 뒤 회수 가드를 풀어 둠" no "$([ -e "$LOCK.reclaim" ] && echo yes || echo no)"

# 회수 중에 죽은 프로세스가 남긴 낡은 가드는 10분 뒤 버리고, 그 뒤에도 낡은 잠금을 치워 게시한다.
mkplug 10.2.0
mkdir "$LOCK" "$LOCK.reclaim"
touch -t 200001010000 "$LOCK" "$LOCK.reclaim"
lock_build 10.2.0
assert_equals "T17 낡은 가드와 낡은 잠금이 함께 남아도 게시함" "10.2.0" "$(cat "$LPUB_DIR/claude-statusline-otlp.version")"
assert_equals "T17 낡은 가드를 치운 뒤 잠금과 가드를 풀어 둠" "no no" "$([ -e "$LOCK" ] && echo yes || echo no) $([ -e "$LOCK.reclaim" ] && echo yes || echo no)"

assert_equals "T16 빌드 스크립트는 LaunchAgent 를 다루지 않음" "0" \
  "$(grep -c 'launchctl\|kr\.silee\|LaunchAgent' "$BUILD" || true)"

# 수신기 빌드나 게시가 실패해도 세션 시작은 막히지 않고 렌더 바이너리는 그대로 준비된다.
FAILGO="$MULTI/failtools"
mkdir -p "$FAILGO"
cat > "$FAILGO/go" <<'GOEOF'
#!/bin/sh
if [ "$1" = env ]; then
  case "$2" in GOOS) echo fixture ;; GOARCH) echo arch ;; esac
  exit 0
fi
for last; do :; done
[ "$last" = ./cmd/claude-statusline-otlp ] && exit 1
while [ "$1" != -o ]; do shift; done
shift
printf '#!/bin/sh\nexit 0\n' > "$1"
chmod +x "$1"
GOEOF
chmod +x "$FAILGO/go"
mkdir -p "$MULTI/account-d/6.0.0/.claude-plugin" "$MULTI/account-d/6.0.0/scripts"
printf '{"version":"6.0.0"}\n' > "$MULTI/account-d/6.0.0/.claude-plugin/plugin.json"
cp "$BUILD" "$MULTI/account-d/6.0.0/scripts/build-binary.sh"
set +e
env PATH="$FAILGO:$PATH" HOME="$TMPROOT" XDG_CACHE_HOME="$MULTI/fail-cache" XDG_DATA_HOME="$MULTI/fail-data" \
  XDG_STATE_HOME="$MULTI/fail-state" CLAUDE_CONFIG_DIR="$MULTI/account-d" CLAUDE_PLUGIN_ROOT="$MULTI/account-d/6.0.0" \
  sh "$MULTI/account-d/6.0.0/scripts/build-binary.sh" 2>"$TMPROOT/otlp-fail-err"
RC=$?
set -e
assert_equals   "T16 수신기 빌드 실패에도 종료코드 0" "0" "$RC"
assert_equals   "T16 수신기 빌드가 실패해도 렌더 바이너리 포인터는 준비됨" yes "$([ -x "$(cat "$MULTI/fail-cache/claude-statusline/binary-path-6.0.0" 2>/dev/null)" ] && echo yes || echo no)"
assert_equals   "T16 수신기 빌드가 실패하면 게시하지 않음" no "$([ -e "$MULTI/fail-data/claude-statusline/bin/claude-statusline-otlp" ] && echo yes || echo no)"
assert_contains "T16 수신기 빌드 실패를 stderr 로 알림" "claude-statusline-otlp" "$(cat "$TMPROOT/otlp-fail-err")"

# 게시 폴더를 만들 수 없어도(데이터 홈이 일반 파일) 종료코드 0 이다.
printf 'x' > "$MULTI/data-is-a-file"
set +e
env PATH="$MULTI/tools:$PATH" HOME="$TMPROOT" XDG_CACHE_HOME="$MULTI/pubfail-cache" XDG_DATA_HOME="$MULTI/data-is-a-file" \
  XDG_STATE_HOME="$MULTI/pubfail-state" CLAUDE_CONFIG_DIR="$MULTI/account-d" CLAUDE_PLUGIN_ROOT="$MULTI/account-d/6.0.0" \
  sh "$MULTI/account-d/6.0.0/scripts/build-binary.sh" 2>"$TMPROOT/pub-fail-err"
RC=$?
set -e
assert_equals "T16 게시 폴더를 만들 수 없어도 종료코드 0" "0" "$RC"
assert_equals "T16 게시 실패에도 렌더 바이너리 포인터는 준비됨" yes "$([ -x "$(cat "$MULTI/pubfail-cache/claude-statusline/binary-path-6.0.0" 2>/dev/null)" ] && echo yes || echo no)"

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
  REAL_PUB="$TMPROOT/data/claude-statusline/bin/claude-statusline-otlp"
  assert_equals   "T6 수신기가 고정 경로에 게시됨" "yes" "$([ -x "$REAL_PUB" ] && echo yes || echo no)"
  assert_equals   "T6 게시 판본 파일이 플러그인 판본" "$PLUGIN_VERSION" "$(cat "$REAL_PUB.version" 2>/dev/null)"
  # 게시된 것이 진짜 수신기다: loopback 이 아닌 주소는 종료코드 1 로 거부한다.
  set +e; "$REAL_PUB" -addr 192.0.2.1:0 2>"$TMPROOT/real-pub.err"; RC=$?; set -e
  assert_equals   "T6 게시된 수신기는 loopback 아닌 주소를 거부(종료코드 1)" "1" "$RC"
  assert_contains "T6 게시된 수신기는 loopback 검사로 거부한다고 알림" "loopback" "$(cat "$TMPROOT/real-pub.err")"

  # --- T7: 이미 있는 바이너리를 다시 빌드하지 않는다(mtime 불변) ---
  BEFORE=$(stat -f '%m' "$BINPATH" 2>/dev/null || stat -c '%Y' "$BINPATH")
  build "$BC" >/dev/null 2>&1
  AFTER=$(stat -f '%m' "$BINPATH" 2>/dev/null || stat -c '%Y' "$BINPATH")
  assert_equals "T7 재실행은 바이너리를 다시 만들지 않음" "$BEFORE" "$AFTER"

  # 다른 계정의 설치 디렉터리는 현재 plugin의 sibling이 아닐 수 있다.
  BINDIR=$(dirname "$BINPATH")
  STALE="$BINDIR/statusline-0.0.0-old-arch"
  LIVE="$BINDIR/statusline-9.9.9-old-arch"
  : > "$STALE"
  : > "$LIVE"
  printf '%s\n' "$LIVE" > "$BC/claude-statusline/binary-path-9.9.9"
  mkdir -p "$(dirname "$SRC")/9.9.9"
  rm -f "$BINPATH" "$BC/claude-statusline/binary-path-$KEY"
  build "$BC" >/dev/null 2>&1
  rmdir "$(dirname "$SRC")/9.9.9"
  assert_equals "T8 다른 계정 설치 여부를 몰라도 바이너리 보존" "yes" "$([ -e "$STALE" ] && echo yes || echo no)"
  assert_equals "T8 설치돼 있는 버전은 보존" "yes" "$([ -e "$LIVE" ] && echo yes || echo no)"
  assert_equals "T8 새 바이너리는 남음" "yes" "$([ -x "$BINPATH" ] && echo yes || echo no)"
  assert_equals "T8 다른 계정 포인터 보존" "$LIVE" "$(cat "$BC/claude-statusline/binary-path-9.9.9")"
  rm -f "$LIVE" "$BC/claude-statusline/binary-path-9.9.9"

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
iso "$NOGO" env CLAUDE_PLUGIN_ROOT="$SRC" XDG_DATA_HOME="$NOGO/data" PATH="$EMPTYBIN" /bin/sh "$BUILD" >/dev/null 2>&1
RC=$?
set -e
assert_equals "T10 go 부재에도 종료코드 0" "0" "$RC"
assert_equals "T10 go 부재면 포인터를 만들지 않음" "no" \
  "$([ -f "$NOGO/claude-statusline/binary-path-$KEY" ] && echo yes || echo no)"
assert_equals "T10 go 부재면 수신기도 게시하지 않음" "no" \
  "$([ -e "$NOGO/data/claude-statusline/bin/claude-statusline-otlp" ] && echo yes || echo no)"

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
cp "$SRC/scripts/config-paths.sh" "$SRC/scripts/hook-handler.sh" "$SRC/scripts/json.awk" "$SRC/scripts/settings-update.awk" "$SETUP_ROOT/scripts/"
printf '%s\n' '{"permissions":{"allow":["Read"]}}' > "$SETUP_HOME/.claude/settings.json"
chmod 600 "$SETUP_HOME/.claude/settings.json"
OUT=$(printf '%s' '{"hook_event_name":"SessionStart"}' | \
  env HOME="$SETUP_HOME" CLAUDE_CONFIG_DIR="$SETUP_HOME/.claude" XDG_CACHE_HOME="$TMPROOT/setup-cache" CLAUDE_PLUGIN_ROOT="$SETUP_ROOT" \
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
env HOME="$GNU_HOME" CLAUDE_CONFIG_DIR="$GNU_HOME/.claude" XDG_CACHE_HOME="$TMPROOT/gnu-stat-cache" CLAUDE_PLUGIN_ROOT="$SETUP_ROOT" \
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
env HOME="$FAIL_HOME" CLAUDE_CONFIG_DIR="$FAIL_HOME/.claude" XDG_CACHE_HOME="$TMPROOT/fail-stat-cache" CLAUDE_PLUGIN_ROOT="$SETUP_ROOT" \
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
