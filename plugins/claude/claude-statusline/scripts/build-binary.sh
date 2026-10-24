#!/bin/sh
set -eu
# 렌더 바이너리와 OTLP 수신기를 사용자 기계에서 최초 1회 빌드한다. SessionStart 훅이 배경으로 떼어 내
# 부르며, 대상이 이미 있으면 다시 빌드하지 않는다.
#
# 바이너리를 저장소에 커밋하지 않는 이유는 릴리스마다 플랫폼당 수 MB 가 델타 압축되지 않는 채로
# git 히스토리에 영구히 쌓이고, 이 저장소는 마켓플레이스가 clone 해 가는 대상이라 그 무게를 모든
# 설치가 나눠 지기 때문이다.
#
# 수신기(claude-statusline-otlp)는 판본이 들어간 캐시 경로에 빌드한 뒤 고정 경로
# ${XDG_DATA_HOME:-$HOME/.local/share}/claude-statusline/bin/claude-statusline-otlp 에 게시한다. 상시
# 수신기를 띄우는 쪽(서비스 정의)은 판본이 들어간 경로를 따라갈 수 없고, 캐시 정리가 지우지 않는 자리가
# 필요하기 때문이다. 수신기는 자기 실행 파일이 바뀐 것을 스스로 알아채 종료코드 75 로 끝나므로, 이 스크립트는
# 수신기를 재시작하지 않는다.
#
# 수정 시 검토 관점:
#   - 어떤 실패도 종료코드 0 으로 끝낸다. 이 스크립트의 실패가 세션 시작을 막으면 안 된다.
#   - 파일명에 플러그인 버전과 플랫폼을 넣는다. 버전을 빼면 플러그인을 올린 뒤에도 옛 바이너리가
#     남아 쓰인다.
#   - GOPROXY=off 로 빌드한다. 외부 의존이 실수로 들어오면 조용히 내려받는 대신 빌드가 실패해
#     드러난다.
#   - 바이너리와 포인터를 모두 임시 파일에 쓴 뒤 rename 으로 바꾼다. shim 이 읽는 중에 반쯤
#     쓰인 내용을 보면 안 된다. 게시 파일도 같은 폴더의 임시 파일을 rename 해 바꾼다 — 도는 수신기의
#     파일을 제자리에서 덮어쓰면 수신기가 종료코드 0 으로 죽어 정상 종료와 구별되지 않는다.
#   - 설치된 판본을 읽고 비교하고 실행 파일과 .version 을 바꾸는 구간 전체를 게시 폴더의 잠금
#     (mkdir)으로 직렬화하고, 판본은 잠금 안에서 다시 읽는다. 계정마다 훅이 따로 도는 탓에 서로 다른
#     판본이 동시에 옛 판본을 읽으면 낮은 판본이 높은 판본을 덮고 .version 이 실행 파일과 어긋나, 이후
#     같은 판본의 게시까지 생략된다. 빌드는 잠금 밖이다.
#   - 게시는 설치된 판본(.version)보다 같거나 높을 때만 한다. 계정마다 플러그인 갱신 시점이 달라 낮은
#     판본의 훅이 높은 판본을 덮으면 수신기가 판본 사이를 오가며 재시작한다. 같은 판본이 이미 게시돼
#     있으면 건드리지 않는다. 비교는 숫자 순서(5.10.0 > 5.9.0)다.
#   - 이 스크립트는 수신기를 띄우거나 재시작하는 서비스 이름을 알지 못한다.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
BIN_DIR="$CACHE_DIR/bin"
PTR="$CACHE_DIR/binary-path-${PLUGIN_ROOT##*/}"
PUB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-statusline/bin"

version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' \
  "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1 || printf '')
[ -n "$version" ] || exit 0

if ! command -v go >/dev/null 2>&1; then
  printf '[claude-statusline] go 를 찾지 못해 렌더 바이너리를 빌드하지 않았습니다.\n' >&2
  printf '[claude-statusline] Go 1.26 이상을 설치하면 다음 세션에 자동으로 빌드됩니다.\n' >&2
  exit 0
fi

goos=$(go env GOOS 2>/dev/null || printf '')
goarch=$(go env GOARCH 2>/dev/null || printf '')
[ -n "$goos" ] && [ -n "$goarch" ] || exit 0
target="$BIN_DIR/statusline-$version-$goos-$goarch"
otlp_target="$BIN_DIR/claude-statusline-otlp-$version-$goos-$goarch"

# build_to <패키지> <대상 경로> <이름>: 임시 파일에 빌드한 뒤 rename 으로 바꾼다.
build_to() {
  mkdir -p "$BIN_DIR" || return 1
  _tmp="$2.tmp.$$"
  if ! ( cd "$PLUGIN_ROOT" && GOPROXY=off go build -trimpath -ldflags="-s -w" \
          -o "$_tmp" "$1" ) >/dev/null 2>&1; then
    rm -f "$_tmp"
    printf '[claude-statusline] %s 빌드에 실패했습니다.\n' "$3" >&2
    return 1
  fi
  mv "$_tmp" "$2"
}

# publish_receiver: 수신기를 고정 경로에 게시한다. 이미 같거나 높은 판본이 게시돼 있으면 건드리지 않는다.
publish_receiver() {
  _pub="$PUB_DIR/claude-statusline-otlp"
  _ver="$_pub.version"
  _installed=""
  if [ -f "$_ver" ]; then
    IFS= read -r _installed < "$_ver" || _installed=""
  fi
  case "$_installed" in "" | *[!0-9.]*) _installed="" ;; esac
  if [ -n "$_installed" ] && [ -x "$_pub" ]; then
    [ "$_installed" = "$version" ] && return 0
    _newest=$(printf '%s\n%s\n' "$_installed" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    [ "$_newest" = "$version" ] || return 0
  fi
  mkdir -p "$PUB_DIR" || return 1
  _ptmp="$PUB_DIR/.claude-statusline-otlp.tmp.$$"
  if ! { cp "$otlp_target" "$_ptmp" && chmod 755 "$_ptmp" && mv "$_ptmp" "$_pub"; }; then
    rm -f "$_ptmp"
    return 1
  fi
  [ -x "$_pub" ] || return 1
  _vtmp="$_ver.tmp.$$"
  printf '%s\n' "$version" > "$_vtmp" && mv "$_vtmp" "$_ver"
}

# reclaim_stale_lock: 비정상 종료한 게시자가 남긴 낡은 잠금(2분 넘게 그대로)을 치운다. 낡은지 보고 지우는 두
# 단계 사이에 다른 프로세스가 먼저 치우고 새 잠금을 잡을 수 있어, 그냥 지우거나 rename 으로 치우면 새 잠금을
# 지운다(둘째 프로세스의 rename 이 첫째가 잡은 새 잠금에 성공한다). 그래서 회수 가드(mkdir)를 잡은 프로세스만
# 치우고, 가드를 잡은 뒤에 다시 본다. 낡은 잠금이 자리를 차지하는 동안에는 아무도 새 잠금을 만들 수 없고 치우는 쪽은
# 가드 보유자 하나뿐이라, 보고 지우는 사이에 잠금이 바뀌지 않는다.
# shortcut: 2분 넘게 멈춘 살아 있는 보유자(노트북 절전 등)의 잠금도 낡은 것으로 보고 치운다, 복사 한 번이 걸리는
# 구간이라 겹치려면 그 구간에서 멈춰야 한다. 회수 중 SIGKILL 로 죽은 가드는 10분 뒤 나이로 버리는데, 이 폐기도 보고 지우는
# 두 단계라 같은 틈이 한 단계 위에 남는다: 가드가 10분 넘게 남은 뒤 세 프로세스가 동시에 시작하면 둘이 가드를 함께 쥐고 한쪽이
# 다른 쪽의 새 잠금을 지울 수 있다. 결과는 낮은 판본이 한 번 덮이거나 한 번 더 게시하는 정도이고 다음 게시가 바로잡는다.
# 이 틈을 받아들이는 기준: 열리려면 가드가 10분 넘게 남을 만큼 회수 중 SIGKILL 이 있고 세 게시자가 같은 순간에 시작해야
# 하며, 그 결과가 수신기를 한 번 더 재시작시키는 데 그친다. 낮은 판본이 게시된 채 남은 것이 한 번이라도 관찰되거나 한
# 장비에서 판본이 다른 게시자 셋 이상이 늘 동시에 도는 구성이 생기면, 가드를 pid·시작 시각을 적은 소유 토큰과 rename 으로
# 원자적으로 소유하는 방식으로 올린다.
reclaim_stale_lock() {
  [ -n "$(find "$_lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 0
  if [ -n "$(find "$_guard" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$_guard" 2>/dev/null || true
  fi
  mkdir "$_guard" 2>/dev/null || return 0
  trap 'rmdir "$_guard" 2>/dev/null; exit 0' HUP INT TERM
  if [ -n "$(find "$_lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    rmdir "$_lock" 2>/dev/null || true
  fi
  trap - HUP INT TERM
  rmdir "$_guard" 2>/dev/null || true
}

# publish_receiver_locked: publish_receiver 를 게시 폴더 단위 잠금 안에서 실행한다. 정상 보유 시간은
# 복사 한 번이라 10초 안에 잡히지 않으면 포기하고(다음 세션 시작에 다시 시도한다), 비정상 종료한 게시자가 남긴
# 잠금은 2분이 지나면 reclaim_stale_lock 이 버린다.
publish_receiver_locked() {
  _lock="$PUB_DIR/.publish.lock"
  _guard="$_lock.reclaim"
  mkdir -p "$PUB_DIR" || return 1
  _tries=0
  while ! mkdir "$_lock" 2>/dev/null; do
    reclaim_stale_lock
    _tries=$((_tries + 1))
    [ "$_tries" -le 50 ] || return 1
    sleep 0.2
  done
  trap 'rmdir "$_lock" 2>/dev/null; exit 0' HUP INT TERM
  _rc=0
  publish_receiver || _rc=$?
  trap - HUP INT TERM
  rmdir "$_lock" 2>/dev/null || true
  return "$_rc"
}

render_ready=0
if [ -x "$target" ]; then
  current=""
  if [ -f "$PTR" ]; then
    IFS= read -r current < "$PTR" || current=""
  fi
  [ "$current" = "$target" ] && render_ready=1
fi
if [ "$render_ready" = 0 ] && build_to ./cmd/statusline "$target" "렌더 바이너리"; then
  ptmp="$PTR.tmp.$$"
  printf '%s\n' "$target" > "$ptmp"
  mv "$ptmp" "$PTR"
fi

# 수신기 빌드·게시가 실패해도 렌더 바이너리는 이미 준비돼 있다.
if [ -x "$otlp_target" ] || build_to ./cmd/claude-statusline-otlp "$otlp_target" "claude-statusline-otlp"; then
  publish_receiver_locked || printf '[claude-statusline] claude-statusline-otlp 게시에 실패했습니다.\n' >&2
fi

# 다른 설정 디렉터리의 설치와 진행 중인 빌드도 같은 bin을 쓰므로 자동 삭제하지 않는다.
exit 0
