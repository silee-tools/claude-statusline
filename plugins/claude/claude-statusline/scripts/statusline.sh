#!/bin/sh
set -eu
# statusline 진입점. 렌더는 Go 바이너리가 한 프로세스 안에서 수행하고, 이 파일은 그 바이너리로
# 넘기는 shim 이다. settings.json 에 이미 기록된 명령과 테스트 스위트의 호출 경로가 이 파일을
# 가리키므로, 이 자리를 유지하는 것이 사용자 설정과 스위트를 건드리지 않는 조건이다.
#
# 수정 시 검토 관점: 이 shim 은 자식 프로세스를 하나도 만들지 않는다. 경로를 매 렌더 계산하려고
# uname 을 부르거나 빌드 스크립트를 부르면 그만큼 프로세스가 늘어 이식으로 줄인 시간을 도로
# 쓴다. 그래서 바이너리 위치는 셸 파라미터 확장으로만 얻는 포인터 파일 한 줄에서 읽는다.
# 포인터를 플러그인 버전으로 가르는 이유: shim 은 settings.json 에 한 버전 경로로 고정되지만
# 바이너리를 빌드하는 SessionStart 훅은 설치된 버전마다 따로 돈다. 포인터가 하나뿐이면 각
# 버전의 훅이 그 한 줄을 서로 덮어써, 고정된 shim 이 다른 버전의 바이너리를 실행한다.
# 키는 플러그인 루트 디렉터리 이름이다 — 설치본이면 버전, 저장소에서 직접 쓰면
# claude-statusline 이 된다. build-binary.sh 와 hook-handler.sh 는 같은 키를
# CLAUDE_PLUGIN_ROOT 에서 얻으므로 세 곳이 같은 디렉터리를 가리킨다.
ROOT=${0%/scripts/*}
PTR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/binary-path-${ROOT##*/}"
BIN=""
if [ -f "$PTR" ]; then
  IFS= read -r BIN < "$PTR" || BIN=""
fi
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  exec "$BIN"
fi

# 저하 표시: 바이너리가 준비되기 전에만 지나가는 한 줄이다. sh 렌더러를 남겨 두는 것이 아니라,
# 지금 무엇이 없는지를 알리는 표시다. 시각을 넣지 않는 이유는 date 가 프로세스를 하나 더
# 만들기 때문이다. SessionStart 훅이 떼어 낸 배경 빌드가 끝나면 다음 렌더부터 위로 간다.
# stdin 을 내장 read 로 비운다 — 읽지 않고 끝내면 JSON 을 쓰는 쪽이 SIGPIPE 를 받는다.
while IFS= read -r _; do :; done
printf '\033[2m%s\033[0m \033[2mstatusline: binary not built yet\033[0m' "${PWD:-.}"
