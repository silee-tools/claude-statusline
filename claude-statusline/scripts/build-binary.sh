#!/bin/sh
set -eu
# 렌더 바이너리를 사용자 기계에서 최초 1회 빌드한다. SessionStart 훅이 배경으로 떼어 내 부르며,
# 대상이 이미 있으면 아무것도 하지 않는다.
#
# 바이너리를 저장소에 커밋하지 않는 이유는 릴리스마다 플랫폼당 수 MB 가 델타 압축되지 않는 채로
# git 히스토리에 영구히 쌓이고, 이 저장소는 마켓플레이스가 clone 해 가는 대상이라 그 무게를 모든
# 설치가 나눠 지기 때문이다.
#
# 수정 시 검토 관점:
#   - 어떤 실패도 종료코드 0 으로 끝낸다. 이 스크립트의 실패가 세션 시작을 막으면 안 된다.
#   - 파일명에 플러그인 버전과 플랫폼을 넣는다. 버전을 빼면 플러그인을 올린 뒤에도 옛 바이너리가
#     남아 쓰인다.
#   - GOPROXY=off 로 빌드한다. 외부 의존이 실수로 들어오면 조용히 내려받는 대신 빌드가 실패해
#     드러난다.
#   - 바이너리와 포인터를 모두 임시 파일에 쓴 뒤 rename 으로 바꾼다. shim 이 읽는 중에 반쯤
#     쓰인 내용을 보면 안 된다.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
BIN_DIR="$CACHE_DIR/bin"
PTR="$CACHE_DIR/binary-path"

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

if [ -x "$target" ]; then
  current=""
  if [ -f "$PTR" ]; then
    IFS= read -r current < "$PTR" || current=""
  fi
  [ "$current" = "$target" ] && exit 0
fi

mkdir -p "$BIN_DIR" || exit 0
tmp="$target.tmp.$$"
if ! ( cd "$PLUGIN_ROOT" && GOPROXY=off go build -trimpath -ldflags="-s -w" \
        -o "$tmp" ./cmd/statusline ) >/dev/null 2>&1; then
  rm -f "$tmp"
  printf '[claude-statusline] 렌더 바이너리 빌드에 실패했습니다.\n' >&2
  exit 0
fi
mv "$tmp" "$target"

ptmp="$PTR.tmp.$$"
printf '%s\n' "$target" > "$ptmp"
mv "$ptmp" "$PTR"

# 옛 버전과 다른 플랫폼의 바이너리를 정리한다. 지우지 않으면 플러그인을 올릴 때마다 캐시가
# 자란다.
for f in "$BIN_DIR"/*; do
  [ -e "$f" ] || continue
  [ "$f" = "$target" ] && continue
  rm -f "$f"
done
exit 0
