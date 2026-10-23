#!/bin/sh
# statusline.sh 렌더링 회귀 테스트
# 격리된 임시 PLUGIN_ROOT 에서 실제 소스 statusline.sh 를 실행하고,
# stdin JSON(rate_limits·effort 포함/미포함) fixture 로
# 80열 이하 압축 2행과 81열 이상 전체 레이아웃(최대 6행) 출력을 함께 검증한다.
#
# 압축 레이아웃(위→아래, 값 없는 행은 생략):
#   행1  브랜치 gh@계정 [aws 이상·불명]
#   행2  ctx <소진율>% <모델> <effort 글리프> 5h <소진율>%[▲] ↺리셋 7d <소진율>%[▲] ↺리셋
#
# 전체 레이아웃: 첫 줄은 버전, 시각, 계정, 세션, 경로, 브랜치, gh, aws 순서로 공백 한 칸씩 이어 붙이고 그
# 아래에 ctx, 5h, 7d 를 둔다. 줄이 칸 수 − 4 칸(Claude Code 가 상태줄에 쓰는 폭)을 넘으면 경로 앞에서
# 끊어 경로·브랜치·gh·aws 를 둘째 줄로 내리고(5행), 그 줄도 넘으면 경로·브랜치와 gh·aws 를 각자 줄에
# 두는 6행이다. 폭 판정 불가는 항상 한 줄로 이어 붙인다.
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
ESC=$(printf '\033')
RESET=$(printf '\033[0m')
RED=$(printf '\033[31m')
YELLOW=$(printf '\033[33m')
CYAN=$(printf '\033[36m')
DIMC=$(printf '\033[2m')
GREY=$(printf '\033[38;5;240m')
GREEN=$(printf '\033[32m')
LIME=$(printf '\033[38;5;148m')
AMBER=$(printf '\033[38;5;214m')
MAGENTA=$(printf '\033[35m')

TMPROOT=$(mktemp -d)
# bash 3.2 는 EXIT 트랩 진입에서 $? 를 0 으로 만든다. completed 플래그가 없으면 set -eu 중단이
# 종료코드 0 으로 보고된다. 정본은 AGENTS.md 의 Testing 절이다.
completed=0
LIVE_PIDS=""
trap 'rc=$?; kill $LIVE_PIDS 2>/dev/null; rm -rf "$TMPROOT"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT
# 이 스위트가 만들고 읽는 상태·데이터·캐시·설정은 모두 TMPROOT 안에 있다. 실제 홈의 설정 폴더, 상태 폴더,
# 수신기 게시 경로를 건드리지 않도록 환경을 먼저 고정하고, 어긋나 있으면 시작하지 않는다.
HOME="$TMPROOT/home"; CLAUDE_CONFIG_DIR="$TMPROOT"
XDG_DATA_HOME="$TMPROOT/data"; XDG_CACHE_HOME="$TMPROOT/cache"; XDG_CONFIG_HOME="$TMPROOT"
XDG_STATE_HOME="$TMPROOT/state-none"
export HOME CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_STATE_HOME
for _v in "$HOME" "$CLAUDE_CONFIG_DIR" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"; do
  case "$_v" in "$TMPROOT"*) ;; *) echo "FATAL: 격리되지 않은 경로 $_v" >&2; exit 1;; esac
done
mkdir -p "$HOME" "$TMPROOT/scripts" "$TMPROOT/cache/claude-statusline"
ln -sf "$SRC/scripts/statusline.sh" "$TMPROOT/scripts/statusline.sh"
SL="$TMPROOT/scripts/statusline.sh"

# 스위트는 실제 aws 를 부르지 않는다. 낡은 로그인 캐시는 백그라운드 aws sts 확인(SpawnAWSCheck)을 띄우고,
# 실제 aws 는 개발자의 ~/.aws 자격 증명으로 STS 를 호출하며 로그인 캐시를 다시 쓸 수 있다. 그래서 호출을
# 기록만 하는 가짜 aws 를 PATH 앞에 두고 aws 설정 파일도 빈 파일로 바꾸며, 스위트 끝에서 호출이 0회임을 단언한다.
AWS_CALLS="$TMPROOT/aws-calls"
mkdir -p "$TMPROOT/awsbin"
printf '#!/bin/sh\nprintf "call %%s\\n" "$*" >> "%s"\n' "$AWS_CALLS" > "$TMPROOT/awsbin/aws"
chmod +x "$TMPROOT/awsbin/aws"
: > "$TMPROOT/aws-config"
: > "$AWS_CALLS"
PATH="$TMPROOT/awsbin:$PATH"
AWS_CONFIG_FILE="$TMPROOT/aws-config"
export PATH AWS_CONFIG_FILE

# 렌더 본체는 Go 바이너리다. statusline.sh 는 XDG_CACHE_HOME 아래 포인터가 가리키는 그
# 바이너리로 exec 하는 shim 이므로, 스위트가 먼저 한 번 빌드해 포인터를 심는다.
# 빌드 실패를 건너뛰면 shim 이 저하 표시를 내고 이후 단언이 통째로 실패하거나, 더 나쁘게는
# 검사 0건이 통과로 읽힌다. 그래서 여기서 즉시 스위트를 실패시킨다.
BINARY="$TMPROOT/statusline-binary"
if ! command -v go >/dev/null 2>&1; then
  echo "FATAL: go 를 찾지 못해 렌더 바이너리를 빌드할 수 없습니다" >&2
  exit 1
fi
if ! ( cd "$SRC" && GOPROXY=off go build -o "$BINARY" ./cmd/statusline ) >&2; then
  echo "FATAL: 렌더 바이너리 빌드 실패" >&2
  exit 1
fi
# 포인터는 플러그인 루트 디렉터리 이름으로 갈린다. 스위트는 격리된 임시 루트의 shim 을
# 부르므로 그 루트 이름이 키다 — shim 이 자기 $0 에서 얻는 값과 같은 규칙으로 만든다.
SL_ROOT=${SL%/scripts/*}
printf '%s\n' "$BINARY" > "$TMPROOT/cache/claude-statusline/binary-path-${SL_ROOT##*/}"

# gh 계정 fixture: 저장소별 계정 캐시 + 계정→라벨 매핑 설정 파일. 실제 계정명 대신 테스트용
# handle(octocat)로 결정론화한다. format_gh 는 소스에 계정명을 박지 않고 이 매핑을 읽는다.
# 캐시 파일 이름은 저장소 루트의 물리 경로에서 / 를 % 로 바꾼 것이다. 저장소 판정은 .git 항목
# 존재만 보므로 빈 .git 디렉터리로 충분하다.
GH_CACHE_DIR="$TMPROOT/cache/gh-prompt"
GH_REPO="$TMPROOT/gh-repo"
mkdir -p "$GH_CACHE_DIR" "$GH_REPO/.git"
# 저장소 분류는 .git/config 의 origin 만 본다. 빈 .git 디렉터리에 origin 설정만 써 둔다.
set_origin() { printf '[remote "origin"]\n\turl = %s\n' "$2" > "$1/.git/config"; }
set_origin "$GH_REPO" git@github.com:o/r.git
gh_cache_file() { printf '%s/%s' "$GH_CACHE_DIR" "$(cd "$1" && pwd -P | sed 's#/#%#g')"; }
GH_CACHE_FILE=$(gh_cache_file "$GH_REPO")
printf 'octocat' > "$GH_CACHE_FILE"
mkdir -p "$TMPROOT/claude-statusline"
printf 'octocat=personal,214\ntestwork=work,27\nbadcolor=weird,zz\n' > "$TMPROOT/claude-statusline/gh-accounts"

# Claude Code 계정 fixture: 계정은 OTLP 수신기가 남긴 앵커(<상태>/claude-statusline/otel/sessions/<session.id>.env)
# 에서만 읽는다. 설정 폴더의 .claude.json 을 읽지 않는 것이 계약이므로, 다른 이메일을 담은 미끼로 둔다.
# STATE_HOME 이 STATE_NONE 이면 수신기가 한 번도 뜬 적 없는 기계(계정 칸 없음), STATE_ACCT 이면 설치된 기계다.
# RFC 2606 예약 도메인으로 실재 계정과 충돌을 막는다.
printf '{"oauthAccount":{"emailAddress":"decoy@example.com"}}' > "$TMPROOT/.claude.json"
STATE_NONE="$TMPROOT/state-none"
STATE_ACCT="$TMPROOT/state-acct"
STATE_HOME="$STATE_NONE"
OTEL_DIR="$STATE_ACCT/claude-statusline/otel"
mkdir -p "$STATE_NONE"
anchor_file() { printf '%s/sessions/%s.env' "$OTEL_DIR" "$1"; }
# seed_anchor <session.id> <email> <kind> <event time ms>. 수신기가 저장한 시각(seen)은 지금이고, 수신기 세대
# (otel/generation)는 그보다 이르다 — 세대보다 먼저 저장된 앵커는 이메일 뒤에 ? 가 붙는다.
seed_anchor() {
  mkdir -p "$OTEL_DIR/sessions"
  printf 'email=%s\nkind=%s\nts=%s\nseen=%s000\n' "$2" "$3" "$4" "$(date +%s)" > "$(anchor_file "$1")"
  printf '1\n' > "$OTEL_DIR/generation"
}
beat()       { mkdir -p "$OTEL_DIR"; touch "$OTEL_DIR/heartbeat"; }
stale_beat() { mkdir -p "$OTEL_DIR"; touch -t 200001010000 "$OTEL_DIR/heartbeat"; }

# AWS 세션 fixture: AWS 세그먼트가 개발자의 실제 ~/.aws/login/cache 를 읽지 않도록 전용
# 디렉터리에 방금 로그인한 캐시 파일 하나를 둔다. 세그먼트는 idToken 의 iat 에 12h 를 더한
# 시각을 만료로 읽는다. 방금 로그인했으므로 aws:✓ 로 렌더되어 노랑·빨강이 아니고, T17 의 절대
# 소진율 색 판정과 격리된다.
b64url() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
aws_id_token() { printf '%s.%s.sig' "$(b64url '{"alg":"none"}')" "$(b64url "{\"iat\":$1}")"; }
aws_cache() { printf '{"idToken":"%s"}' "$(aws_id_token "$2")" > "$1"; }
AWS_LOGIN_CACHE_FIXTURE="$TMPROOT/aws-login-cache-fixture"
mkdir -p "$AWS_LOGIN_CACHE_FIXTURE"
export AWS_LOGIN_CACHE_DIR="$AWS_LOGIN_CACHE_FIXTURE"   # 어느 렌더 헬퍼도 개발자의 실제 로그인 캐시를 읽지 않는다
aws_cache "$AWS_LOGIN_CACHE_FIXTURE/session.json" "$(date +%s)"

# 세션 ID fixture: 알려진 UUID. 축약 없이 전체가 그대로 렌더되는지 검증한다.
KNOWN_SESSION="11111111-2222-3333-4444-555555555555"

# 브랜치 fixture: 격리된 git repo 를 만들어 알려진 브랜치명(wip)을 갖게 한다.
# 브랜치가 둘째 줄로 내려갔는지 검증하려면 실제 git 컨텍스트가 필요하다.
GITREPO="$TMPROOT/repo"
# git 부재나 gpgsign 강제 같은 환경 문제로 fixture 생성이 실패해도 set -e 로 전체 suite 를
# 중단시키지 않는다. HAVE_GIT 플래그로 T18 만 조건 실행하고, 실패 원인은 stderr 로 남긴다.
HAVE_GIT=0
if command -v git >/dev/null 2>&1; then
  mkdir -p "$GITREPO"
  if ( cd "$GITREPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/wip \
       && git remote add origin git@github.com:o/r.git \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init ); then
    HAVE_GIT=1
  else
    echo "warn: git fixture 생성 실패 — T18 을 건너뜁니다" >&2
  fi
else
  echo "warn: git 미설치 — T18 을 건너뜁니다" >&2
fi

# 이전 판본의 비용 캐시가 있어도 두 레이아웃은 이를 무시한다.
cat > "$TMPROOT/cache/claude-statusline/cost-cache.env" <<'ENV'
available=true
dailyOpus=12
dailySonnet=0
dailyHaiku=0
weekly=605
monthly=605
cachedAt=1784000000
ENV

NOW=$(date +%s)
FIVE_RESET=$((NOW + 9000))    # 2h30m 뒤
WEEK_RESET=$((NOW + 200000))  # 약 2d7h 뒤

# rate limit + effort 모두 포함 (cwd=/tmp → 브랜치 없음)
json_with() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$FIVE_RESET" "$WEEK_RESET"
}
# rate limit 없음, effort 없음
json_without() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11"}'
}
# rate limit 있음(90%+), effort 있음 — 빨강 경고 검증용
json_high() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":%s},"seven_day":{"used_percentage":92,"resets_at":%s}}}' "$FIVE_RESET" "$WEEK_RESET"
}
# rate limit 있음, effort 없음 — effort 미지원 모델 경로 검증용
json_no_effort() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$FIVE_RESET" "$WEEK_RESET"
}
# 지정한 5h/7d 소진율로 rate limit 색 임계를 검증한다.
json_pct() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$FIVE_RESET" "$2" "$WEEK_RESET"
}
# resets_at 없는 변형: 페이스(예산) 오버레이가 없어 순수 막대·절대 소진율 색만 검증할 때 쓴다.
# (resets_at 이 있으면 예산 초과 구간의 색이 얹혀 정확한 막대 문자열·색 임계 단언이 흔들린다.)
json_pct_nr() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","rate_limits":{"five_hour":{"used_percentage":%s},"seven_day":{"used_percentage":%s}}}' "$1" "$2"
}
# gh 캐시가 있는 저장소를 cwd 로 주는 변형. rate limit 유무만 json_with·json_without 과 다르다.
json_with_gh() { json_with | sed "s#\"current_dir\":\"/tmp\"#\"current_dir\":\"$GH_REPO\"#"; }
json_gh()      { json_without | sed "s#\"current_dir\":\"/tmp\"#\"current_dir\":\"$GH_REPO\"#"; }

# 브랜치 fixture repo 를 cwd 로 주는 변형 (브랜치 위치·세션 ID 검증용). session_id 를 포함한다.
json_branch() {
  printf '{"session_id":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$KNOWN_SESSION" "$GITREPO" "$FIVE_RESET" "$WEEK_RESET"
}
# input_tokens 로 ctx 소진율을 제어한다(window 200000 기준). ctx 막대 임계 색 검증용. rate 없음.
json_ctx() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11"}' "$1"
}
# 지정한 effort level 로 effort 글리프 색·모양을 검증한다. rate 없음(색 오염 방지), ctx 20%(무색).
json_eff() {
  printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.1.11","effort":{"level":"%s"}}' "$1"
}

# 세션별 5h·7d 캐시(<캐시>/rate-limits/<session_id>.env). 렌더가 이 디렉터리에 쓰므로 케이스마다 지워 앞
# 케이스의 값이 뒤로 새지 않게 한다. 캐시 폴더 전체를 지우면 같은 곳에 사는 binary-path-<키> 포인터까지
# 날아가 shim 이 저하 표시를 내므로 rate-limits 폴더만 지운다. session_id 가 없는 페이로드는 캐시를 쓰지
# 않으므로, 캐시를 검증하는 케이스는 with_rl 로 이 세션 id 를 넣는다.
RL_SESSION="rl-test-session"
RATE_DIR="$TMPROOT/cache/claude-statusline/rate-limits"
RATE_CACHE="$RATE_DIR/$RL_SESSION.env"
# 한도 캐시는 실행 프로세스와 인증 경계별이다(anchor.Boundary). 프로세스는 <설정 폴더>/sessions/<pid>.json 으로
# 알아내므로 캐시를 쓰는 세션마다 프로세스 파일을 둔다. 경계는 <pid>-<startedAt>-<마지막 로그인 ts 또는 0> 이다.
# 프로세스 파일은 실행 중인 pid 만 인정하므로(죽은 프로세스가 남긴 파일은 그 프로세스가 아니다) 시험의 프로세스는
# 살아 있는 sleep 이다.
seed_proc() { mkdir -p "$TMPROOT/sessions"; printf '{"pid":%s,"sessionId":"%s","startedAt":%s}\n' "$2" "$1" "${3:-1700000000000}" > "$TMPROOT/sessions/$2.json"; }
live_proc() { sleep 900 & eval "$1=\$!"; LIVE_PIDS="$LIVE_PIDS $!"; }
live_proc P_RL
live_proc P_A
live_proc P_A2
live_proc P_B
live_proc P_C
RL_BOUNDARY="$P_RL-1700000000000-0"
seed_proc "$RL_SESSION" "$P_RL"
seed_proc rl-sess-a "$P_A"
seed_proc rl-sess-b "$P_B"
seed_proc rl-sess-c "$P_C"
seed_rate_cache() { mkdir -p "$RATE_DIR"; printf 'boundary=%s\nfivePct=%s\nfiveReset=%s\nweekPct=%s\nweekReset=%s\n' "$RL_BOUNDARY" "$1" "$2" "$3" "$4" > "$RATE_CACHE"; }
with_session() { printf '%s' "$2" | sed "s/^{/{\"session_id\":\"$1\",/"; }
with_rl() { with_session "$RL_SESSION" "$1"; }

# 색 코드 제거한 출력. XDG_CONFIG_HOME·XDG_CACHE_HOME 을 TMPROOT 로, AWS_LOGIN_CACHE_DIR
# 을 위 fixture 로 고정해 gh 계정·매핑·AWS 세션 표시를 모두 결정론화한다.
_render() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_STATE_HOME="$STATE_HOME" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" AWS_LOGIN_CACHE_DIR="$AWS_LOGIN_CACHE_FIXTURE" CLAUDE_STATUSLINE_WIDTH="$2" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g"; }
# 색 코드 포함 원본 출력
_render_raw() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_STATE_HOME="$STATE_HOME" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" AWS_LOGIN_CACHE_DIR="$AWS_LOGIN_CACHE_FIXTURE" CLAUDE_STATUSLINE_WIDTH="$2" sh "$SL" 2>/dev/null; }
# 폭 주입을 비우고 tty 장치 디렉터리를 존재하지 않는 곳으로 고정해 판정 불가 경로를 만든다.
_render_auto() {
  (
    unset CLAUDE_STATUSLINE_WIDTH
    printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMPROOT" \
      XDG_STATE_HOME="$STATE_HOME" XDG_CONFIG_HOME="$TMPROOT" XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
      AWS_LOGIN_CACHE_DIR="$AWS_LOGIN_CACHE_FIXTURE" \
      CLAUDE_STATUSLINE_TTY_DIR="$TMPROOT/missing-dev" COLUMNS=40 sh "$SL" 2>/dev/null \
      | sed "s/${ESC}\[[0-9;]*m//g"
  )
}

# 기본 렌더는 공유 캐시를 지우고 시작한다. seed_rate_cache 로 심은 값을 그대로 쓰는 케이스만
# run_keep 을 부른다. `KEEP=1 run ...` 처럼 호출 앞에 변수를 붙이는 형태는 쓰지 않는다 — 그
# 할당이 호출 뒤에도 남는지를 POSIX 가 정하지 않아 macOS 의 /bin/sh 에서는 남고 dash 에서는
# 남지 않으며, 남는 쪽에서는 이후 모든 렌더가 격리를 잃은 채 스위트가 통과한다.
run()      { rm -rf "$RATE_DIR"; _render "$@"; }
run_raw()  { rm -rf "$RATE_DIR"; _render_raw "$@"; }
run_auto() { rm -rf "$RATE_DIR"; _render_auto "$@"; }
run_keep() { _render "$@"; }

# 출력 끝에 개행이 없어 명령 치환이 후행 개행을 지우므로, 한 줄을 다시 붙여 세면 정확하다.
# 폭 불변성 비교(T5)용. 두 렌더 사이 분 경계를 넘어도 흔들리지 않도록 시각(HH:MM)과
# rate 리셋 토큰(↺2h30m 등, 렌더 시점 date 로 계산돼 매 호출 달라짐)을 함께 마스킹한다.
mask_time() { printf '%s' "$1" | sed -e 's/[0-9][0-9]:[0-9][0-9]/HH:MM/' -e 's/↺[0-9dhm]*/↺RESET/g'; }
nlines()    { printf '%s\n' "$1" | wc -l | tr -d ' '; }
first_line(){ printf '%s\n' "$1" | sed -n '1p'; }
last_line() { printf '%s\n' "$1" | tail -n 1; }
nth_line()  { printf '%s\n' "$2" | sed -n "${1}p"; }
row_with()  { printf '%s\n' "$2" | grep -F -- "$1" | sed -n '1p'; }
count_char(){ printf '%s' "$2" | grep -o "$1" | wc -l | tr -d ' '; }
count_str() { printf '%s' "$2" | grep -oF "$1" | wc -l | tr -d ' '; }

# 문자열(색 코드 제거 후)이 완전한 UTF-8 시퀀스로만 이뤄져 있는지 검증한다. 잘린 다중바이트
# 문자(선행 바이트만 남거나 연속 바이트가 모자란 경우)가 있으면 "bad", 없으면 "ok".
# 첫 행 절단이 두 칸 문자를 반으로 쪼개지 않는지를 실제 렌더 결과로 확인할 때 쓴다.
utf8_intact() {
  printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g" | LC_ALL=C awk '
    {
      n = length($0); i = 1; ok = 1
      while (i <= n) {
        c = substr($0, i, 1)
        if (c < "\200")                    { L = 1 }
        else if (c >= "\300" && c < "\340") { L = 2 }
        else if (c >= "\340" && c < "\360") { L = 3 }
        else if (c >= "\360" && c < "\370") { L = 4 }
        else                                { ok = 0; break }
        if (i + L - 1 > n) { ok = 0; break }
        j = 1
        while (j < L) {
          cc = substr($0, i + j, 1)
          if (cc < "\200" || cc >= "\300") { ok = 0; break }
          j++
        }
        if (!ok) break
        i += L
      }
      print (ok ? "ok" : "bad")
    }'
}

# 색 코드를 뺀 표시 폭. 한글 등 두 칸 문자를 두 칸으로 센다(감지 폭 단언용).
# 구현(internal/width 의 wideRanges)이 다루는 8개 범위 중 이 스위트의 픽스처가 실제로 쓰는
# 3개(한글 자모·CJK·한글 음절)만 옮겼다. 의도적인 부분 오라클이다 — 구현에서 그대로 가져와
# 쓰지 않고 독립적으로 유지하기 위해서다. 완전한 폭 분류기로 오인하지 않는다.
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

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }

assert_contains()     { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (expected to contain [$2])" "$3";; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1 (should NOT contain [$2])" "$3";; *) ok "$1";; esac; }
assert_match()        { if printf '%s' "$3" | grep -Eq "$2"; then ok "$1"; else bad "$1 (expected to match /$2/)" "$3"; fi; }
assert_no_match()     { if printf '%s' "$3" | grep -Eq "$2"; then bad "$1 (should NOT match /$2/)" "$3"; else ok "$1"; fi; }
assert_equals()       { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (expected [$2])" "$3"; fi; }

# =====================================================================
# 폭 80 이하는 압축 레이아웃, 81 이상은 전체 레이아웃을 렌더한다.
# =====================================================================

# --- T46: 경계값에서 레이아웃이 갈리고 이전 비용 캐시를 무시한다 ---
OUT80=$(run "$(json_with)" 80)
OUT81=$(run "$(json_with)" 81)
assert_equals     "T46 폭 80 저장소 밖은 게이지 1행(1행 생략)" "1" "$(nlines "$OUT80")"
assert_equals     "T46 폭 80 저장소 안은 압축 2행" "2" "$(nlines "$(run "$(json_with_gh)" 80)")"
# 이 fixture 는 경로 /tmp·브랜치 없음이라 이어 붙인 첫 줄이 81열(사용 폭 77칸) 안에 든다.
assert_equals     "T46 폭 81은 전체 4행(첫 줄에 이어 붙임)" "4" "$(nlines "$OUT81")"
assert_match      "T46 폭 81 첫 줄은 버전·시각·경로·aws 순서로 한 칸씩(수신기 미설치라 계정 칸 없음)" '^v2\.1\.11 [0-9][0-9]:[0-9][0-9] /tmp aws:✓$' "$(first_line "$OUT81")"
assert_not_contains "T46 미설치 기계는 settings 의 .claude.json 이메일을 쓰지 않음" "decoy@example.com" "$OUT81"
assert_not_contains "T46 압축 레이아웃은 비용 없음" "cost" "$OUT80"
assert_not_contains "T46 전체 레이아웃은 비용 없음" "cost" "$OUT81"

# --- T47: 전체 레이아웃은 막대·전체 세션 ID를 보존한다 ---
FULL=$(run "$(json_with)" 81)
# 첫 줄이 늘어 게이지가 한 행씩 밀리면 행 번호로 고른 단언이 ctx 막대(역시 20칸)를 재고도 통과하므로 행 수를 고정한다.
assert_equals "T47 폭 81 fixture 는 4행(첫 줄 1 + 게이지 3)" "4" "$(nlines "$FULL")"
assert_equals "T47 전체 레이아웃 5h 막대는 20칸" "20" "$(count_char '[█░]' "$(row_with ' 5h ' "$FULL")")"
assert_not_contains "T47 이전 비용 캐시 금액 없음" '$605' "$FULL"
# 예산은 10칸(경과 9000s / 창 18000s)이고 소진율 70% 는 14칸이므로 11번째 칸부터 끝까지가
# 초과 구간이다. 초과는 3칸을 넘어 빨강이고, 그 앞 열 칸은 회색으로 남는다.
PACE_OUT=$(run_raw "$(json_pct 70 10)" 81)
assert_equals "T47 예산 fixture 도 4행" "4" "$(nlines "$PACE_OUT")"
PACE_ROW=$(row_with '5h' "$PACE_OUT")   # 색 코드가 라벨 뒤 공백 앞에 끼므로 라벨만 찾는다
assert_equals "T47 전체 레이아웃 예산 이내는 회색 10칸" "10" "$(count_str "$GREY" "$PACE_ROW")"
assert_equals "T47 전체 레이아웃 예산 초과는 빨강 10칸" "10" "$(count_str "$RED" "$PACE_ROW")"
assert_contains "T47 전체 레이아웃 예산 경계는 회색 다음이 빨강" "${GREY}█${RESET}${RED}█" "$PACE_ROW"
assert_not_contains "T47 전체 레이아웃은 압축 페이스 기호 없음" "▲" "$PACE_ROW"
if [ "$HAVE_GIT" = 1 ]; then
  FULL_SESSION=$(run "$(json_branch)" 81)
  # 이어 붙인 첫 줄이 한 줄에 드는지 둘째 줄로 갈라지는지는 임시 경로 길이에 달려 있어 줄 위치를 보지 않는다.
  assert_contains "T47 전체 레이아웃에 전체 세션 ID" "⧉ $KNOWN_SESSION" "$FULL_SESSION"
fi

# --- T48: 폭을 못 재면 COLUMNS 값과 무관하게 전체 레이아웃을 쓰고, 첫 줄은 한 줄로 이어 붙인다 ---
AUTO=$(run_auto "$(json_with)")
assert_equals "T48 폭 판정 불가 시 전체 4행" "4" "$(nlines "$AUTO")"
assert_contains "T48 오래된 COLUMNS=40을 무시하고 전체 막대 표시" "█" "$AUTO"
assert_match "T48 폭 판정 불가는 첫 줄을 버전·시각·경로·aws 순서로 한 칸씩 이어 붙임" '^v2\.1\.11 [0-9][0-9]:[0-9][0-9] /tmp aws:✓$' "$(first_line "$AUTO")"

# --- T61: 이어 붙인 첫 줄이 칸 수 − 4 안에 들지 않으면 경로 앞에서 끊어 둘째 줄로 내리고, 그 줄도 넘으면 경로·브랜치와 gh·aws 를 따로 둔다 ---
#    긴 경로·긴 브랜치 저장소를 HOME=TMPROOT 로 렌더해 단계 경계를 만든다. 경계 폭은 폭을 모를 때 이어 붙인
#    줄의 표시 폭(vwidth_of)에서 구하고, Claude Code 가 상태줄 양쪽에 남기는 4칸을 더한다.
if [ "$HAVE_GIT" = "1" ]; then
  # 계정 칸이 첫 줄의 폭에 들어가도록 수신기가 설치된 기계로 렌더한다.
  # 로그인 앵커는 실행 중인 프로세스를 알 때만 확정으로 그려지므로 이 세션의 프로세스를 둔다.
  seed_anchor "$KNOWN_SESSION" octocat@example.com login 1700000000000
  live_proc P_KNOWN
  seed_proc "$KNOWN_SESSION" "$P_KNOWN"
  beat
  STATE_HOME="$STATE_ACCT"
  STAGE_REPO="$TMPROOT/stage/webapp/very-long-project-directory-name"
  mkdir -p "$STAGE_REPO"
  if ( cd "$STAGE_REPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/feature/PROJ-123-post-editor \
       && git remote add origin git@github.com:o/r.git \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init ) >/dev/null 2>&1; then
    printf 'octocat' > "$(gh_cache_file "$STAGE_REPO")"
    json_stage() { json_branch | sed "s#$GITREPO#$STAGE_REPO#"; }
    stage_out() { HOME="$TMPROOT" run "$(json_stage)" "$1"; }
    T61_HEAD='^v2\.1\.11 [0-9][0-9]:[0-9][0-9] octocat@example\.com ⧉ '"${KNOWN_SESSION}"'$'
    T61_TAIL='very-long-project-directory-name .*feature/PROJ-123-post-editor gh@personal aws:✓$'

    # 폭을 모르면 한 줄로 잇는다. 그 줄의 폭이 곧 1단계가 요구하는 폭이다.
    ONE=$(HOME="$TMPROOT" run_auto "$(json_stage)")
    assert_equals "T61 폭 판정 불가는 넘쳐도 4행으로 이어 붙임" "4" "$(nlines "$ONE")"
    assert_match  "T61 한 줄은 버전·시각·계정·세션·경로·브랜치·gh·aws 순서로 한 칸씩" "${T61_HEAD%\$} .*${T61_TAIL}" "$(first_line "$ONE")"
    ONE_WIDTH=$(( $(vwidth_of "$(first_line "$ONE")") + 4 ))
    # 81열은 가장 좁은 전체 레이아웃이다. 거기서 경로 줄(둘째 줄)이 2단계가 요구하는 폭을 알려 준다.
    NARROW=$(stage_out 81)
    assert_equals "T61 폭 81 은 6행(경계 폭 계산의 전제)" "6" "$(nlines "$NARROW")"
    TAIL_WIDTH=$(( $(vwidth_of "$(nth_line 2 "$NARROW")") + 1 + $(vwidth_of "$(nth_line 3 "$NARROW")") + 4 ))

    ONE_OUT=$(stage_out "$ONE_WIDTH")
    assert_equals "T61 이어 붙인 줄이 정확히 들면 4행" "4" "$(nlines "$ONE_OUT")"
    assert_equals "T61 4행 첫 줄은 폭을 모를 때와 같다" "$(mask_time "$(first_line "$ONE")")" "$(mask_time "$(first_line "$ONE_OUT")")"
    assert_no_match "T61 4행 첫 줄에 정렬 공백 없음" '  ' "$(first_line "$ONE_OUT")"

    TAIL_OUT=$(stage_out $((ONE_WIDTH - 1)))
    assert_equals       "T61 한 칸 모자라면 경로 앞에서 끊은 5행" "5" "$(nlines "$TAIL_OUT")"
    assert_match        "T61 5행 첫 줄은 버전·시각·계정·세션" "$T61_HEAD" "$(first_line "$TAIL_OUT")"
    assert_match        "T61 5행 둘째 줄은 경로·브랜치·gh·aws" "$T61_TAIL" "$(nth_line 2 "$TAIL_OUT")"
    assert_not_contains "T61 5행 둘째 줄에 세션 없음" "⧉" "$(nth_line 2 "$TAIL_OUT")"
    assert_match        "T61 5행 셋째 줄은 ctx 게이지" '^ctx ' "$(nth_line 3 "$TAIL_OUT")"
    assert_equals       "T61 경로 줄 폭이 정확히 폭이면 5행" "5" "$(nlines "$(stage_out "$TAIL_WIDTH")")"

    SPLIT_OUT=$(stage_out $((TAIL_WIDTH - 1)))
    assert_equals       "T61 경로 줄도 넘으면 6행" "6" "$(nlines "$SPLIT_OUT")"
    assert_match        "T61 6행 첫 줄은 버전·시각·계정·세션" "$T61_HEAD" "$(first_line "$SPLIT_OUT")"
    assert_match        "T61 6행 둘째 줄은 경로·브랜치" 'very-long-project-directory-name .*feature/PROJ-123-post-editor$' "$(nth_line 2 "$SPLIT_OUT")"
    assert_equals       "T61 6행 셋째 줄은 gh·aws" "gh@personal aws:✓" "$(nth_line 3 "$SPLIT_OUT")"
    assert_match        "T61 6행 넷째 줄은 ctx 게이지" '^ctx ' "$(nth_line 4 "$SPLIT_OUT")"

    for _w in 100 110 120 130 140 160 200 400; do
      _out=$(stage_out "$_w")
      _want=6
      if [ "$_w" -ge "$ONE_WIDTH" ]; then _want=4; elif [ "$_w" -ge "$TAIL_WIDTH" ]; then _want=5; fi
      assert_equals "T61 ${_w}열의 행 수" "$_want" "$(nlines "$_out")"
      _fit=""
      if [ "$_want" -eq 4 ]; then _fit=$(first_line "$_out"); elif [ "$_want" -eq 5 ]; then _fit=$(nth_line 2 "$_out"); fi
      if [ -n "$_fit" ]; then
        assert_equals "T61 ${_w}열에서 끊은 마지막 머리 줄이 폭 − 4 칸 이내" "yes" "$([ "$(vwidth_of "$_fit")" -le $((_w - 4)) ] && echo yes || echo no)"
      fi
      assert_contains "T61 ${_w}열에서도 세션 ID 를 자르지 않음" "$KNOWN_SESSION" "$_out"
    done
  else
    echo "warn: 긴 브랜치 fixture 생성 실패 — T61 을 건너뜁니다" >&2
  fi
  rm -f "$TMPROOT/sessions/$P_KNOWN.json"
  rm -rf "$RATE_DIR"
  STATE_HOME="$STATE_NONE"
else
  printf 'SKIP T61 (git fixture 미생성)\n'
fi

# --- T1: rate_limits 있으면 5h/7d 라벨과 소진율이 나온다 ---
OUT=$(run "$(json_with)" 80)
assert_match "T1 5h 소진율 표시" '5h [0-9]+%' "$OUT"
assert_match "T1 7d 소진율 표시" '7d [0-9]+%' "$OUT"
assert_match "T1 5h 리셋 분 단위 표기" "↺[0-9]+h[0-9]+m" "$OUT"

# --- T2: 비용을 표시하지 않는다 ---
OUT=$(run "$(json_with)" 80)
assert_not_contains "T2 24h 비용 라벨 없음" "24h" "$OUT"
assert_not_contains "T2 7d 비용 금액 없음" "\$605" "$OUT"
assert_not_contains "T2 cost 라벨 없음" "cost" "$OUT"

# --- T4: 소진율 90% 이상이면 빨간색 경고 ---
RAW=$(run_raw "$(json_high)" 80)
assert_contains "T4 90%+ 빨간색 경고" "$RED" "$RAW"

# --- T5: 폭 경계를 넘으면 전체와 압축 레이아웃의 출력이 달라진다 ---
A=$(run "$(json_with)" 81)
B=$(run "$(json_with)" 80)
if [ "$(mask_time "$A")" != "$(mask_time "$B")" ]; then
  ok "T5 폭 81과 80의 출력이 다름"
else
  bad "T5 폭 81과 80의 출력이 다름" "identical output"
fi

# --- T7: 압축 구성 — 저장소 안은 2행(gh 상시 + 게이지), 저장소 밖은 게이지 1행 ---
OUT=$(run "$(json_with_gh)" 80)
assert_equals "T7 총 2행" "2" "$(nlines "$OUT")"
assert_contains "T7 행1 gh 상시 표시" "gh@personal" "$(first_line "$OUT")"
assert_match  "T7 행2 ctx"  'ctx [0-9]'  "$(last_line "$OUT")"
assert_match  "T7 행2 5h"   '5h [0-9]'   "$(last_line "$OUT")"
assert_match  "T7 행2 7d"   '7d [0-9]'   "$(last_line "$OUT")"
assert_not_contains "T7 압축은 이메일·버전·세션·시각을 쓰지 않음" "octocat@example.com" "$OUT"
assert_not_contains "T7 압축은 버전 없음" "v2.1.11" "$OUT"
assert_not_contains "T7 압축은 aws:✓ 를 숨김" "aws:" "$OUT"
OUT=$(run "$(json_with)" 80)
assert_equals "T7 저장소 밖 정상 상태는 게이지 1행" "1" "$(nlines "$OUT")"
assert_match  "T7 저장소 밖 1행이 ctx" '^ctx [0-9]' "$OUT"

# --- T7-model: 모델·effort 는 ctx 뒤에 온다 ---
OUT=$(run "$(json_with)" 80)
assert_match    "T7-model ctx 뒤 모델명" 'ctx [0-9]+% Opus 4\.8' "$(last_line "$OUT")"

# --- T33: 모델명 파싱이 sed 없이도 "이름 버전" 표기를 유지한다 ---
OUT=$(run "$(json_with)" 80)
assert_match "T33 모델 이름+버전 표기 유지" 'Opus 4\.8' "$OUT"

# --- T8: 5h 와 7d 는 ctx 와 같은 게이지 행에 병합되어 나온다(파이프 없음) ---
#    Task 4 의 게이지 병합으로 각자 줄에 온다는 이전 기대는 성립하지 않는다. 5h·7d 는
#    행3 하나에만 나타나고(중복 없음), 그 행에 파이프 구분자는 쓰지 않는다.
OUT=$(run "$(json_with)" 80)
L3=$(last_line "$OUT")
assert_equals   "T8 5h 게이지 1개" "1" "$(printf '%s\n' "$OUT" | grep -c '5h [0-9]')"
assert_equals   "T8 7d 게이지 1개" "1" "$(printf '%s\n' "$OUT" | grep -c '7d [0-9]')"
assert_contains "T8 5h 는 게이지 행에 있음" "5h" "$L3"
assert_contains "T8 7d 는 게이지 행에 있음" "7d" "$L3"
assert_equals   "T8 게이지 행 파이프 없음" "0" "$(count_char '|' "$L3")"

# --- T9: effort → Claude Code 원형 글리프 + 웜 게이지 색(low=초록 … max=빨강, ultracode=마젠타) ---
#    글리프 모양과 색이 함께 단계를 표현한다. rate 없는 json_eff 로 색 오염을 막고 색을 글리프에 직접 묶어 검증.
OUT=$(run "$(json_eff high)" 80)
assert_contains "T9 effort high 글리프(●)" "●" "$OUT"
RAW=$(run_raw "$(json_eff low)"       80); assert_contains "T9 low 초록 ○"        "${GREEN}○"    "$RAW"
RAW=$(run_raw "$(json_eff medium)"    80); assert_contains "T9 medium 연두 ◐"     "${LIME}◐"     "$RAW"
RAW=$(run_raw "$(json_eff high)"      80); assert_contains "T9 high 노랑 ●"       "${YELLOW}●"   "$RAW"
RAW=$(run_raw "$(json_eff xhigh)"     80); assert_contains "T9 xhigh 주황 ◉"      "${AMBER}◉"    "$RAW"
RAW=$(run_raw "$(json_eff max)"       80); assert_contains "T9 max 빨강 ◈"        "${RED}◈"      "$RAW"
RAW=$(run_raw "$(json_eff ultracode)" 80); assert_contains "T9 ultracode 마젠타 ✦" "${MAGENTA}✦" "$RAW"

# --- T10: effort 없으면 글리프 없이 모델명만 (데이터 부재의 정당한 부재 단언) ---
OUT=$(run "$(json_no_effort)" 80)
assert_no_match "T10 effort 부재 시 글리프 없음" "○|◐|●|◉|◈|✦" "$OUT"
assert_contains "T10 모델명은 유지" "Opus 4.8" "$OUT"

# --- T11: 행1 은 브랜치·gh 지표만 — 시각·버전은 쓰지 않는다 ---
OUT=$(run "$(json_with_gh)" 80)
FIRST=$(first_line "$OUT")
assert_contains     "T11 행1 에 gh 계정" "gh@personal" "$FIRST"
assert_not_contains "T11 행1 에 버전 없음" "v2.1.11" "$FIRST"
assert_no_match     "T11 행1 에 시각 없음" '[0-9][0-9]:[0-9][0-9]' "$FIRST"

# --- T13a: rate 도 캐시도 없으면 게이지 행에 ctx 만 남는다(저장소 밖이라 1행) ---
OUT=$(run "$(json_without)" 80)
assert_equals   "T13a rate 부재 저장소 밖은 1행" "1" "$(nlines "$OUT")"
assert_match    "T13a 게이지 행 ctx 유지" 'ctx [0-9]' "$(last_line "$OUT")"
assert_no_match "T13a 캐시가 비면 5h 없음" '5h .*[0-9]+%' "$OUT"
assert_no_match "T13a 캐시가 비면 7d 없음" '7d .*[0-9]+%' "$OUT"

# --- T13b: rate 는 없어도 유효한 캐시가 있으면 그 값을 그린다 ---
seed_rate_cache 24 "$FIVE_RESET" 41 "$WEEK_RESET"
OUT=$(run_keep "$(with_rl "$(json_without)")" 80)
assert_match "T13b 캐시에서 5h 공급" '5h 24%' "$OUT"
assert_match "T13b 캐시에서 7d 공급" '7d 41%' "$OUT"
rm -f "$RATE_CACHE"

# --- T14: 버전은 전체 레이아웃에만 있다 ---
OUT=$(run "$(json_with)" 81)
assert_contains "T14 전체 레이아웃 버전 표시" "v2.1.11" "$OUT"

# --- T15: 리셋 무손실 — 5h·7d 리셋(↺) 둘 다 유지 ---
OUT=$(run "$(json_with)" 80)
assert_equals "T15 리셋 2개 유지" "2" "$(count_char '↺' "$OUT")"

# --- T16: 제거 안전 게이트 — 소스에 옛 화살표 글리프가 없다 (정적 검사) ---
if grep -q '╰─»' "$SRC/scripts/statusline.sh"; then
  bad "T16 옛 화살표 글리프 제거" "found ╰─» in statusline.sh"
else
  ok "T16 옛 화살표 글리프 제거"
fi

# --- T17: 절대 소진율 색 임계 — 노랑 80%, 빨강 90% (페이스 오버레이 없는 fixture 로 격리) ---
#    다른 색 소스(aws:⏳ 노랑, aws:expired 빨강)는 AWS_LOGIN_CACHE_DIR 을 방금 만든 캐시
#    fixture 로 고정해 격리했으므로(aws:✓ 만 나옴) YELLOW/RED 존재가 절대색만 가리킨다.
#    json_pct_nr 로 reset 을 빼 예산 초과 구간의 색이 색 판정에 섞이지 않게 한다.
YELLOW=$(printf '\033[33m')
RAW=$(run_raw "$(json_pct_nr 80 10)" 80)
assert_contains     "T17 80%면 노란색 경고" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct_nr 75 10)" 80)
assert_not_contains "T17 75%면 노란색 없음(노랑 임계 미만)" "$YELLOW" "$RAW"
RAW=$(run_raw "$(json_pct_nr 90 10)" 80)
assert_contains     "T17 90%면 빨간색 경고" "$RED" "$RAW"
RAW=$(run_raw "$(json_pct_nr 85 10)" 80)
assert_not_contains "T17 85%면 빨강 없음(빨강 임계 미만)" "$RED" "$RAW"

# --- T18: 브랜치가 있으면 첫 줄(gh 앞)에 온다. 괄호 대신 브랜치 아이콘( ) 접두(사이 공백 없음) ---
BRANCH_GLYPH=$(printf '\356\202\240')   #  U+E0A0 (Powerline git branch)
if [ "$HAVE_GIT" = "1" ]; then
  printf 'octocat' > "$(gh_cache_file "$GITREPO")"
  OUT=$(run "$(json_branch)" 80)
  FIRST=$(first_line "$OUT")
  SECOND=$(nth_line 2 "$OUT")
  assert_contains     "T18 첫 줄에 브랜치 아이콘+이름(사이 공백 없음)" "${BRANCH_GLYPH}wip" "$FIRST"
  assert_not_contains "T18 둘째 줄에 브랜치명 없음" "wip" "$SECOND"
  assert_contains     "T18 첫 줄 브랜치 뒤에 gh 계정" "wip gh@personal" "$FIRST"
  assert_equals       "T18 첫 줄 파이프 없음" "0" "$(count_char '|' "$FIRST")"
else
  printf 'SKIP T18 (git fixture 미생성)\n'
fi

# --- T40: 압축 첫 행은 감지 폭을 넘지 않는다(긴 브랜치를 폭 기준으로 절단) ---
#    브랜치명에 한글을 넣어 폭 계산과 절단을 internal/width 의 단위 테스트가 아니라 실제
#    렌더 경로를 거쳐 검증한다. 두 칸 문자를 한 칸으로 세는 회귀는 ASCII 브랜치 픽스처로는
#    드러나지 않는다.
if [ "$HAVE_GIT" = "1" ]; then
  LONGREPO="$TMPROOT/deep/aa/bb/cc/dd/very-long-project-directory-name"
  mkdir -p "$LONGREPO"
  ( cd "$LONGREPO" \
    && git init -q \
    && git symbolic-ref HEAD "refs/heads/한글브랜치이름아주길게테스트용문자열모음입니다" \
    && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
           commit -q --allow-empty -m init ) >/dev/null 2>&1
  OUT=$(HOME="$TMPROOT" run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$LONGREPO")" 40)
  FIRST=$(first_line "$OUT")
  W1=$(vwidth_of "$FIRST")
  assert_equals "T40 첫 행이 감지 폭 40칼럼 이내" "yes" "$([ "$W1" -le 40 ] && echo yes || echo "no($W1)")"
  assert_contains "T40 잘린 자리에 줄임표" "…" "$FIRST"
  assert_contains "T40 한글 브랜치가 첫 행에 온다" "한글브랜치" "$FIRST"
  assert_equals   "T40 한글 브랜치가 반으로 쪼개지지 않음(유효 UTF-8)" "ok" "$(utf8_intact "$FIRST")"
else
  printf 'SKIP T40 (git fixture 미생성)\n'
fi

# --- T26: Claude Code 계정 이메일이 전체 레이아웃 첫 줄에 나온다 (수신기가 남긴 세션 앵커) ---
#    라벨 접두 없이 이메일 그대로, coral(173) 색으로 렌더한다. cwd=/tmp 라 브랜치 없이 계정이 시각 뒤, 경로 앞에 온다.
seed_anchor acct-a octocat@example.com start 1700000000000
beat
STATE_HOME="$STATE_ACCT"
ACCT_A=$(with_session acct-a "$(json_without)")
OUT=$(run "$ACCT_A" 81)
assert_contains "T26 전체 레이아웃 첫 줄에 Claude 계정 이메일" "octocat@example.com" "$(first_line "$OUT")"
assert_contains "T26 시작 이벤트의 계정은 추정이라 물결표가 붙음" "~octocat@example.com" "$(first_line "$OUT")"
assert_not_contains "T26 이메일 앞 cc: 접두 없음" "cc:octocat" "$OUT"
assert_not_contains "T26 같은 설정 폴더의 .claude.json 이메일은 쓰지 않음" "decoy@example.com" "$OUT"
CORAL=$(printf '\033[38;5;173m')
RAW=$(run_raw "$ACCT_A" 81)
assert_contains "T26 계정 이메일 coral(173) 색" "${CORAL}octocat@example.com" "$RAW"
STATE_HOME="$STATE_NONE"

# --- T27: 세션 ID 는 전체 레이아웃에만 전체 값으로 나오고 압축에는 없다 ---
#    이어 붙인 첫 줄은 한 줄에 들거나 경로 앞에서 갈라지므로(T61) 줄 위치가 아니라 마커와 ID 의 붙음을 본다.
if [ "$HAVE_GIT" = "1" ]; then
  OUT=$(run "$(json_branch)" 81)
  assert_contains     "T27 전체 레이아웃에 세션 마커+전체 ID" "⧉ ${KNOWN_SESSION}" "$OUT"
  OUT=$(run "$(json_branch)" 80)
  assert_not_contains "T27 압축 레이아웃에는 세션 마커 없음" "⧉" "$OUT"
else
  printf 'SKIP T27 (git fixture 미생성)\n'
fi
OUT=$(run "$(json_without)" 81)
assert_not_contains "T27 session_id 부재 시 ⧉ 없음" "⧉" "$OUT"

# --- T44: 세션 id 가 짧아도 전체 값을 그대로 쓴다(전체 레이아웃) ---
json_short_session() {
  printf '{"session_id":"abc","workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}'
}
OUT=$(run "$(json_short_session)" 81)
assert_contains "T44 짧은 세션 id 는 전체 값 표시" "⧉ abc" "$OUT"

# --- T41: 압축 레이아웃의 모든 행은 감지 폭 이하다(30·40·50·60·80열) ---
#    gh 상시 표시와 aws 이상·불명을 함께 넣어 1행 지표가 가장 긴 조합도 확인한다.
check_all_widths() {  # $1 출력 $2 폭
  _bad=0
  printf '%s\n' "$1" | while IFS= read -r _l; do
    [ "$(vwidth_of "$_l")" -gt "$2" ] && printf 'over\n'
  done | grep -q over && _bad=1
  [ "$_bad" -eq 0 ] && printf 'ok' || printf 'over%s' "$2"
}
for _w in 30 40 50 60 80; do
  for _fx in "$(json_with)" "$(json_without)" "$(json_high)" "$(json_pct 100 100)" "$(json_with_gh)" "$(json_pct 70 10 | sed "s#\"current_dir\":\"/tmp\"#\"current_dir\":\"$GH_REPO\"#")"; do
    assert_equals "T41 압축 행이 ${_w}칼럼 이내" "ok" "$(check_all_widths "$(run "$_fx" "$_w")" "$_w")"
  done
done
printf 'v2\toctocat\tauth_failed\t0\n' > "$GH_CACHE_FILE"
printf '%s fail\n' "$NOW" > "$TMPROOT/cache/claude-statusline/aws-check"
aws_cache "$AWS_LOGIN_CACHE_FIXTURE/session.json" "$((NOW - 13 * 3600))"
for _w in 30 40 50 60 80; do
  _out=$(run "$(json_with_gh)" "$_w")
  assert_equals   "T41 gh 인증 실패+aws 만료도 ${_w}칼럼 이내" "ok" "$(check_all_widths "$_out" "$_w")"
  assert_contains "T41 ${_w}열에서도 지표를 자르지 않음" "gh@personal! aws:expired" "$(first_line "$_out")"
done
rm -f "$TMPROOT/cache/claude-statusline/aws-check"
aws_cache "$AWS_LOGIN_CACHE_FIXTURE/session.json" "$(date +%s)"
printf 'octocat' > "$GH_CACHE_FILE"

# --- T25: gh 라벨을 설정 파일에서 매핑 (소스에 계정명 하드코딩 없음) ---
#    매핑된 계정은 라벨로, 미매핑은 계정명 그대로, 빈 값은 gh@---. 색코드 비숫자는 기본색으로 폴백.
printf 'testwork' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains "T25 config 매핑 계정 → 라벨(gh@work)" "gh@work" "$(first_line "$OUT")"
printf 'nobody-xyz' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains "T25 미매핑 계정 → gh@<계정명>" "gh@nobody-xyz" "$(first_line "$OUT")"
printf '' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains "T25 빈 캐시는 판정 이전이라 gh@?" "gh@?" "$(first_line "$OUT")"
printf 'badcolor' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains "T25 비숫자 색코드도 라벨은 렌더(가드)" "gh@weird" "$(first_line "$OUT")"
printf 'octocat' > "$GH_CACHE_FILE"   # 이후 테스트 위해 원복

# --- T45: 캐시의 탭 네 필드 레코드를 상태별로 렌더 ---
#    셸 프롬프트가 쓰는 레코드에서 계정명·상태·마감 시각을 각각 읽어 상태 문자(⏳Nm·!·?)와
#    색을 붙인다. 마감 시각은 고정 숫자로 두면 시간이 지나 항상 마감 후로 판정돼 마커 검증이
#    조용히 무력해지므로, 렌더 시점 기준 상대값으로 만든다.
gh_cache() { printf 'v2\t%s\t%s\t%s\n' "$1" "$2" "$3" > "$GH_CACHE_FILE"; }
GH_NOW=$(date +%s)

gh_cache octocat ok 0
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 ok 은 라벨만"              "gh@personal" "$(first_line "$OUT")"
assert_not_contains "T45 ok 에 인증 실패 문자 없음" "gh@personal!" "$(first_line "$OUT")"
assert_not_contains "T45 ok 에 판정 불가 문자 없음" "gh@personal?" "$(first_line "$OUT")"
assert_not_contains "T45 ok 에 한도 마커 없음"      "⏳" "$(first_line "$OUT")"

gh_cache octocat auth_failed 0
OUT=$(run "$(json_gh)" 80)
RAW=$(run_raw "$(json_gh)" 80)
assert_contains     "T45 auth_failed 는 gh@personal!" "gh@personal!" "$(first_line "$OUT")"
assert_contains     "T45 auth_failed 는 전체 빨강"    "${RED}gh@personal!" "$RAW"

gh_cache octocat unknown 0
OUT=$(run "$(json_gh)" 80)
RAW=$(run_raw "$(json_gh)" 80)
assert_contains     "T45 unknown 은 gh@personal?"  "gh@personal?" "$(first_line "$OUT")"
assert_contains     "T45 unknown 은 전체 회색"     "$(printf '\033[38;5;240m')gh@personal?" "$RAW"

gh_cache testwork rate_limited "$((GH_NOW + 540))"
OUT=$(run "$(json_gh)" 80)
RAW=$(run_raw "$(json_gh)" 80)
assert_contains     "T45 rate_limited 는 gh@work⏳9m" "gh@work⏳9m" "$(first_line "$OUT")"
assert_contains     "T45 라벨은 설정 색, 마커만 노랑" \
  "$(printf '\033[38;5;27m')gh@work$(printf '\033[0m')$(printf '\033[33m')⏳9m" "$RAW"

gh_cache testwork rate_limited "$((GH_NOW + 30))"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 1분 미만 남으면 1m 으로 올림" "gh@work⏳1m" "$(first_line "$OUT")"

gh_cache testwork rate_limited "$((GH_NOW - 60))"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 마감이 지나면 라벨만"     "gh@work" "$(first_line "$OUT")"
assert_not_contains "T45 마감이 지나면 마커 제거"  "⏳" "$(first_line "$OUT")"

gh_cache testwork rate_limited notanumber
OUT=$(run "$(json_gh)" 80)
assert_not_contains "T45 마감 시각이 숫자가 아니면 마커 없음" "⏳" "$(first_line "$OUT")"

gh_cache - no_active 0
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 no_active 는 gh@---"      "gh@---" "$(first_line "$OUT")"

gh_cache - unknown 0
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 계정명 없는 unknown 은 gh@?" "gh@?" "$(first_line "$OUT")"

gh_cache - ok 0
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 계정명 자리가 - 이면 상태보다 먼저 걸러 gh@?" "gh@?" "$(first_line "$OUT")"
assert_no_match     "T45 gh@- 로 새지 않음" 'gh@-[[:space:]]' "$(first_line "$OUT")"

printf 'v1\toctocat\tok\t0\n' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 형식을 모르는 네 필드는 계정명만 살리고 판정 불가" \
  "gh@personal?" "$(first_line "$OUT")"

printf 'v2\toctocat\n' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 필드 수가 어긋나면 gh@?" "gh@?" "$(first_line "$OUT")"

printf 'octocat' > "$GH_CACHE_FILE"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T45 탭 없는 한 줄은 계정명으로 해석" "gh@personal" "$(first_line "$OUT")"

# --- T55: gh 세그먼트는 현재 저장소 기준이다 ---
#    저장소의 캐시가 없으면 그리지 않고, 저장소 캐시는 다른 저장소나 저장소 밖에 새지 않는다.
#    저장소 밖은 non-git 기록이 없으면 그리지 않는다(있을 때는 T57).
gh_cache testwork ok 0
OUT=$(run "$(json_without)" 80)
assert_not_contains "T55 저장소가 아닌 cwd(/tmp)에서는 non-git 기록이 없으면 gh 세그먼트 없음" "gh@" "$OUT"
GH_OTHER_REPO="$TMPROOT/gh-other-repo"
mkdir -p "$GH_OTHER_REPO/.git"
set_origin "$GH_OTHER_REPO" git@github.com:o/r.git
OUT=$(run "$(json_gh | sed "s#$GH_REPO#$GH_OTHER_REPO#")" 80)
assert_not_contains "T55 캐시가 없는 저장소에서는 gh 세그먼트 없음" "gh@" "$OUT"
printf 'octocat' > "$(gh_cache_file "$GH_OTHER_REPO")"
OUT=$(run "$(json_gh | sed "s#$GH_REPO#$GH_OTHER_REPO#")" 80)
assert_contains     "T55 저장소마다 자기 캐시를 읽는다(other=personal)" "gh@personal" "$(first_line "$OUT")"
mkdir -p "$GH_REPO/sub/deep"
OUT=$(run "$(json_gh | sed "s#$GH_REPO#$GH_REPO/sub/deep#")" 80)
assert_contains     "T55 저장소 하위 디렉터리에서도 그 저장소의 기록을 읽는다" "gh@work" "$(first_line "$OUT")"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T55 원래 저장소는 자기 기록(work)을 유지" "gh@work" "$(first_line "$OUT")"
printf 'octocat' > "$GH_CACHE_FILE"

# --- T56: origin 이 gh 슬롯을 정한다 — GitHub 는 계정, Forgejo 는 라벨만, 그 밖은 비표시 ---
#    Forgejo 호스트 목록은 설정 파일 forgejo-hosts 에서 읽는다(예약 도메인과 별칭으로 만든 fixture).
FORGEJO_HOSTS="$TMPROOT/claude-statusline/forgejo-hosts"
printf '# forge\nforgejo.example.test\nforge-alias\n' > "$FORGEJO_HOSTS"
gh_repo_with() { mkdir -p "$1/.git"; if [ -n "$2" ]; then set_origin "$1" "$2"; else : > "$1/.git/config"; fi; }
gh_render()   { run "$(json_gh | sed "s#$GH_REPO#$1#")" "${2:-80}"; }
FORGEJO_REPO="$TMPROOT/forge-repo"
gh_repo_with "$FORGEJO_REPO" ssh://git@forge-alias:2222/o/r.git
printf 'v2\t-\tno_active\t0\n' > "$(gh_cache_file "$FORGEJO_REPO")"
OUT=$(gh_render "$FORGEJO_REPO")
assert_contains     "T56 Forgejo 저장소는 forgejo 라벨" "forgejo" "$(first_line "$OUT")"
assert_not_contains "T56 Forgejo 저장소에 남은 옛 no_active 기록은 gh@--- 로 새지 않는다" "gh@" "$OUT"
printf 'v2\toctocat\tok\t0\n' > "$(gh_cache_file "$FORGEJO_REPO")"
OUT=$(gh_render "$FORGEJO_REPO")
assert_not_contains "T56 Forgejo 저장소에 남은 옛 계정 기록은 보이지 않는다" "gh@" "$OUT"
assert_contains     "T56 그 저장소도 forgejo 라벨" "forgejo" "$(first_line "$OUT")"
RAW=$(run_raw "$(json_gh | sed "s#$GH_REPO#$FORGEJO_REPO#")" 80)
assert_contains     "T56 forgejo 라벨은 기본 색(214)" "${AMBER}forgejo" "$RAW"
OUT=$(gh_render "$FORGEJO_REPO" 120)
assert_contains     "T56 전체 레이아웃의 계정 행에도 forgejo" "forgejo" "$OUT"
assert_not_contains "T56 전체 레이아웃에 gh@ 없음" "gh@" "$OUT"
mv "$FORGEJO_HOSTS" "$FORGEJO_HOSTS.off"
OUT=$(gh_render "$FORGEJO_REPO")
assert_not_contains "T56 호스트 목록이 없으면 Forgejo 도 다른 호스트로 보고 비표시(forgejo)" "forgejo" "$OUT"
assert_not_contains "T56 호스트 목록이 없어도 계정은 보이지 않는다" "gh@" "$OUT"
mv "$FORGEJO_HOSTS.off" "$FORGEJO_HOSTS"
OTHER_HOST_REPO="$TMPROOT/other-host-repo"
gh_repo_with "$OTHER_HOST_REPO" https://gitlab.example.com/o/r.git
printf 'octocat' > "$(gh_cache_file "$OTHER_HOST_REPO")"
OUT=$(gh_render "$OTHER_HOST_REPO")
assert_not_contains "T56 다른 호스트 저장소는 캐시가 있어도 gh@ 없음" "gh@" "$OUT"
assert_not_contains "T56 다른 호스트 저장소는 forgejo 도 없음" "forgejo" "$OUT"
NO_ORIGIN_REPO="$TMPROOT/no-origin-repo"
gh_repo_with "$NO_ORIGIN_REPO" ""
printf 'octocat' > "$(gh_cache_file "$NO_ORIGIN_REPO")"
OUT=$(gh_render "$NO_ORIGIN_REPO")
assert_not_contains "T56 origin 없는 저장소는 캐시가 있어도 gh@ 없음" "gh@" "$OUT"
assert_not_contains "T56 origin 없는 저장소는 forgejo 도 없음" "forgejo" "$OUT"
GH_ALIAS_REPO="$TMPROOT/gh-alias-repo"
gh_repo_with "$GH_ALIAS_REPO" git@github.com-work:o/r.git
printf 'testwork' > "$(gh_cache_file "$GH_ALIAS_REPO")"
OUT=$(gh_render "$GH_ALIAS_REPO")
assert_contains     "T56 GitHub ssh 별칭(github.com-*)은 GitHub 로 본다" "gh@work" "$(first_line "$OUT")"
# linked worktree 의 설정은 본 저장소의 .git 에 있다.
if [ "$HAVE_GIT" = 1 ]; then
  GH_WT="$TMPROOT/gh-worktree"
  ( cd "$GITREPO" && git worktree add -q "$GH_WT" -b gh-wt ) 2>/dev/null || true
  if [ -f "$GH_WT/.git" ]; then
    printf 'octocat' > "$(gh_cache_file "$GH_WT")"
    OUT=$(gh_render "$GH_WT")
    assert_contains "T56 linked worktree 도 본 저장소의 origin 으로 분류한다" "gh@personal" "$(first_line "$OUT")"
  fi
fi

# --- T57: 저장소 밖은 non-git 기록(프롬프트가 gh 기본 계정으로 쓴다)을 같은 형식으로 그린다 ---
printf 'octocat' > "$GH_CACHE_DIR/non-git"
OUT=$(run "$(json_without)" 80)
assert_contains     "T57 저장소 밖(/tmp)은 non-git 기록의 계정" "gh@personal" "$(first_line "$OUT")"
printf 'v2\toctocat\tauth_failed\t0\n' > "$GH_CACHE_DIR/non-git"
OUT=$(run "$(json_without)" 80)
assert_contains     "T57 non-git 기록의 상태도 같은 형식" "gh@personal!" "$(first_line "$OUT")"
printf 'v2\t-\tno_active\t0\n' > "$GH_CACHE_DIR/non-git"
OUT=$(run "$(json_without)" 120)
assert_contains     "T57 전체 레이아웃에서도 저장소 밖 gh 표시" "gh@---" "$OUT"
printf 'testwork' > "$(gh_cache_file "$GH_REPO")"
printf 'octocat' > "$GH_CACHE_DIR/non-git"
OUT=$(run "$(json_gh)" 80)
assert_contains     "T57 저장소 안에서는 non-git 기록이 아니라 저장소 기록(work)" "gh@work" "$(first_line "$OUT")"
rm -f "$GH_CACHE_DIR/non-git"
printf 'octocat' > "$GH_CACHE_FILE"

# --- T60: GIT_DIR·GIT_WORK_TREE 는 저장소를 걷기로 볼 수 없는 자리에 둔다 — 저장소 밖(non-git)으로 읽지 않고 gh 를 비운다 ---
printf 'octocat' > "$GH_CACHE_DIR/non-git"
OUT=$(export GIT_DIR="$GH_REPO/.git"; run "$(json_without)" 80)
assert_not_contains "T60 GIT_DIR 가 있으면 non-git 기록의 계정을 쓰지 않는다" "gh@" "$OUT"
OUT=$(export GIT_WORK_TREE="$GH_REPO"; run "$(json_without)" 80)
assert_not_contains "T60 GIT_WORK_TREE 가 있어도 같다" "gh@" "$OUT"
OUT=$(run '{"model":{"display_name":"Claude Opus 4.8"},"version":"2.11.0"}' 80)
assert_not_contains "T60 작업 디렉터리를 모르는 입력도 non-git 계정을 쓰지 않는다" "gh@" "$OUT"
rm -f "$GH_CACHE_DIR/non-git"

# --- T58: idToken 이 없는 aws login 캐시(awscli 2.37)는 ? 로 굳지 않고 백그라운드 확인 결과를 따른다 ---
#    확인 기록이 신선하면(10분 안) 확인 프로세스를 띄우지 않으므로 실제 aws 를 부르지 않는다.
AWS_CHECK="$TMPROOT/cache/claude-statusline/aws-check"
printf '{"accessToken":{"accessKeyId":"x","expiresAt":"2026-10-13T01:16:58Z"},"tokenType":"urn:x","refreshToken":"y"}' \
  > "$AWS_LOGIN_CACHE_FIXTURE/session.json"
printf '%s ok\n' "$(date +%s)" > "$AWS_CHECK"
OUT=$(run "$(json_without)" 80)
assert_not_contains "T58 새 형식 캐시 + 최근 확인 ok 는 aws:? 가 아니다" "aws:?" "$OUT"
OUT=$(run "$(json_without)" 120)
assert_contains     "T58 전체 레이아웃은 aws:✓" "aws:✓" "$OUT"
printf '%s fail\n' "$(date +%s)" > "$AWS_CHECK"
OUT=$(run "$(json_without)" 80)
assert_contains     "T58 새 형식 캐시 + 최근 확인 fail 은 aws:expired" "aws:expired" "$OUT"
rm -f "$AWS_CHECK"
aws_cache "$AWS_LOGIN_CACHE_FIXTURE/session.json" "$(date +%s)"

# --- T20: 요소별 색 — 모델명 시안, 파이프·라벨 등 dim 유지 ---
RAW=$(run_raw "$(json_with)" 80)
assert_contains "T20 모델명 시안(36)" "$CYAN" "$RAW"
assert_contains "T20 파이프·라벨 등 dim 유지" "$DIMC" "$RAW"

# --- T21: 압축 레이아웃은 막대를 쓰지 않고 전체 레이아웃은 20칸 막대를 쓴다 ---
COMPACT=$(run "$(json_with)" 80)
FULL=$(run "$(json_with)" 81)
assert_no_match "T21 압축 레이아웃은 막대 문자 없음" '█|░' "$COMPACT"
assert_match    "T21 전체 레이아웃은 막대 문자 있음" '█|░' "$FULL"

# --- T22: 소진율 경계값(0%/100%)이 숫자로 그대로 나온다 ---
OUT=$(run "$(json_pct_nr 0 100)" 80)
assert_match "T22 0% 표기" '5h 0%' "$OUT"
assert_match "T22 100% 표기" '7d 100%' "$OUT"

# --- T23: ctx 임계 색 — 40%+ 노랑, 70%+ 빨강, 미만은 색 없음 ---
ctx30=$(run_raw "$(json_ctx 60000)"  80 | grep 'ctx')
ctx45=$(run_raw "$(json_ctx 90000)"  80 | grep 'ctx')
ctx75=$(run_raw "$(json_ctx 150000)" 80 | grep 'ctx')
assert_not_contains "T23 30% ctx 노랑 없음" "$YELLOW" "$ctx30"
assert_not_contains "T23 30% ctx 빨강 없음" "$RED" "$ctx30"
assert_contains     "T23 45% ctx 노랑(40%+)" "$YELLOW" "$ctx45"
assert_not_contains "T23 45% ctx 빨강 없음(70% 미만)" "$RED" "$ctx45"
assert_contains     "T23 75% ctx 빨강(70%+)" "$RED" "$ctx75"

# --- T24: ctx 소진율 숫자에 임계 색이 붙는다 ---
ctx45r=$(run_raw "$(json_ctx 90000)" 80 | grep 'ctx')
assert_contains "T24 45% ctx 숫자 노랑" "${YELLOW}45%" "$ctx45r"

# --- T31: 페이스 초과를 ▲ 로 표시한다 ---
#    FIVE_RESET=now+9000, 5h(18000s) 윈도우 → 경과 9000s → 예산 10칸. fill 이 예산을 넘으면
#    ▲ 가 붙고, 넘지 않으면 붙지 않는다. 초과 3칸 이상이면 빨강, 그보다 적으면 노랑.
OUT=$(run "$(json_pct 70 10)" 80)
assert_contains     "T31 초과 시 ▲ 표시" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
OUT=$(run "$(json_pct 40 10)" 80)
assert_not_contains "T31 여유면 ▲ 없음" "▲" "$(printf '%s\n' "$OUT" | grep '5h')"
RAW=$(run_raw "$(json_pct 70 10)" 80 | grep '5h')
assert_contains     "T31 큰 초과 빨강 ▲" "${RED}▲" "$RAW"
RAW=$(run_raw "$(json_pct 55 10)" 80 | grep '5h')
assert_contains     "T31 작은 초과 노랑 ▲" "${YELLOW}▲" "$RAW"

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
      XDG_DATA_HOME="$TMPROOT/data" XDG_STATE_HOME="$STATE_HOME" XDG_CONFIG_HOME="$TMPROOT" \
      XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
      AWS_LOGIN_CACHE_DIR="$AWS_LOGIN_CACHE_FIXTURE" CLAUDE_STATUSLINE_WIDTH=80 \
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

# --- T37/T38/T39: git 브랜치 캐시가 "무손실"인 세 가지 위치 ---
#    naive 하게 .git/HEAD 를 직접 읽으면 아래 세 상태에서 브랜치를 잃는다.
#    (1) 저장소 하위 디렉터리 (2) git worktree(.git 이 파일) (3) detached HEAD.
#    git rev-parse --abbrev-ref HEAD 와 동일한 결과가 나와야 캐시가 안전하다.
if [ "$HAVE_GIT" -eq 1 ]; then
  # 렌더 직전 캐시를 비운다: 캐시 키가 cwd 이므로 다른 cwd 는 어차피 미스지만,
  # 상태 간 오염 가능성을 없애기 위해 명시적으로 지운다.
  render_at() {
    rm -f "$TMPROOT/cache/claude-statusline/git-branch.env"
    run "$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Claude Opus 4.8"},"context_window":{"current_usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":200000},"version":"2.11.0"}' "$1")" 80
  }

  # --- T37: 저장소 하위 디렉터리에서 렌더해도 브랜치가 표시된다 ---
  #    git 은 상위 디렉터리를 탐색해 .git 을 찾으므로, .git/HEAD 만 직접 읽는 구현은
  #    서브디렉터리에서 아무것도 찾지 못해 브랜치를 잃는다.
  mkdir -p "$GITREPO/sub/deep"
  OUT=$(render_at "$GITREPO/sub/deep")
  assert_contains "T37 저장소 하위 디렉터리에서도 브랜치 표시(wip)" "wip" "$OUT"

  # --- T38: git worktree(.git 이 디렉터리가 아니라 파일)에서도 브랜치가 표시된다 ---
  WTREPO="$TMPROOT/wtrepo"
  WTPATH="$TMPROOT/wtree-feat"
  mkdir -p "$WTREPO"
  if ( cd "$WTREPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/main \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init \
       && git worktree add -q "$WTPATH" -b feat ); then
    if [ -f "$WTPATH/.git" ]; then
      ok "T38 worktree 의 .git 이 파일(디렉터리 아님)"
    else
      bad "T38 worktree 의 .git 이 파일(디렉터리 아님)" "$(ls -la "$WTPATH/.git" 2>&1)"
    fi
    OUT=$(render_at "$WTPATH")
    assert_contains "T38 worktree 에서 브랜치 표시(feat)" "feat" "$OUT"
    git -C "$WTREPO" worktree remove --force "$WTPATH" >/dev/null 2>&1 || rm -rf "$WTPATH"
  else
    echo "warn: worktree fixture 생성 실패 — T38 을 건너뜁니다" >&2
  fi

  # --- T39: detached HEAD 에서는 브랜치가 렌더되지 않는다(정당한 부재) ---
  #    브랜치가 없는 상태이므로 첫 줄에 브랜치 글리프도, 원래 브랜치명도 나오면 안 된다.
  DETREPO="$TMPROOT/detrepo"
  mkdir -p "$DETREPO"
  if ( cd "$DETREPO" \
       && git init -q \
       && git symbolic-ref HEAD refs/heads/main \
       && git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=t \
              commit -q --allow-empty -m init ); then
    SHA=$(git -C "$DETREPO" rev-parse HEAD)
    ( cd "$DETREPO" && git -c advice.detachedHead=false checkout -q "$SHA" )
    OUT=$(render_at "$DETREPO")
    FIRST=$(first_line "$OUT")
    assert_not_contains "T39 detached HEAD 첫 줄에 브랜치 글리프 없음" "$BRANCH_GLYPH" "$FIRST"
    assert_not_contains "T39 detached HEAD 첫 줄에 원래 브랜치명(main) 없음" "main" "$FIRST"
  else
    echo "warn: detached HEAD fixture 생성 실패 — T39 를 건너뜁니다" >&2
  fi
else
  echo "warn: git 미설치 — T37/T38/T39 를 건너뜁니다" >&2
fi

# --- T35: 계정은 세션별 앵커에서만 정해지고, 설정 파일과 공용 캐시는 읽지도 쓰지도 않는다 ---
#    한 설정 폴더(CLAUDE_CONFIG_DIR=TMPROOT)를 쓰는 세션들이 서로 다른 계정이어도 각자 자기 계정을 보여 준다.
STATE_HOME="$STATE_ACCT"
seed_anchor acct-a a@example.com start 1700000000000
seed_anchor acct-b b@example.com start 1700000001000
beat
SESS_A=$(with_session acct-a "$(json_without)")
SESS_B=$(with_session acct-b "$(json_without)")
SESS_C=$(with_session acct-c "$(json_without)")
DECOY_SUM=$(cksum < "$TMPROOT/.claude.json")
OUT=$(run "$SESS_A" 120); assert_contains     "T35 세션 A 는 자기 앵커의 계정" "a@example.com" "$(first_line "$OUT")"
assert_contains     "T35 시작 이벤트의 계정은 추정(~)" "~a@example.com" "$(first_line "$OUT")"
assert_not_contains "T35 세션 A 에 세션 B 의 계정이 섞이지 않음" "b@example.com" "$OUT"
OUT=$(run "$SESS_B" 120); assert_contains     "T35 세션 B 는 자기 앵커의 계정" "b@example.com" "$(first_line "$OUT")"
assert_not_contains "T35 세션 B 에 세션 A 의 계정이 섞이지 않음" "a@example.com" "$OUT"
OUT=$(run "$SESS_C" 120)
assert_match "T35 앵커가 없는 세션은 흐린 ? 한 글자" '^v2\.1\.11 [0-9][0-9]:[0-9][0-9] \? ⧉ acct-c /tmp aws:✓$' "$(first_line "$OUT")"
assert_not_contains "T35 앵커가 없어도 .claude.json 의 이메일로 채우지 않음" "decoy@example.com" "$OUT"
OUT=$(run "$(json_without)" 120)
assert_match "T35 session_id 없는 페이로드도 ? 로 정직하게 모름" '^v2\.1\.11 [0-9][0-9]:[0-9][0-9] \? /tmp aws:✓$' "$(first_line "$OUT")"

# 세션 안 /login: 로그인 앵커가 그 세션만 바꾼다. 로그아웃은 ? 이다.
live_proc P_ACCT
seed_proc acct-a "$P_ACCT"
seed_anchor acct-a c@example.com login 1700000009000
OUT=$(run "$SESS_A" 120); assert_contains "T35 /login 뒤 그 세션이 새 계정을 보여 줌" "c@example.com" "$(first_line "$OUT")"
assert_not_contains "T35 /login 으로 확정된 계정에는 물결표가 없음" "~c@example.com" "$(first_line "$OUT")"
assert_not_contains "T35 /login 뒤 옛 계정이 남지 않음" "a@example.com" "$OUT"
OUT=$(run "$SESS_B" 120); assert_contains "T35 한 세션의 /login 은 다른 세션을 바꾸지 않음" "b@example.com" "$(first_line "$OUT")"
seed_anchor acct-a "" logout 1700000019000
OUT=$(run "$SESS_A" 120)
assert_match "T35 로그아웃 뒤는 ?" '^v2\.1\.11 [0-9][0-9]:[0-9][0-9] \? ⧉ acct-a /tmp aws:✓$' "$(first_line "$OUT")"
# 프로세스를 모르면 로그인 앵커도 추정(~)으로만 그린다. 그 앵커가 같은 대화를 돌린 이전 프로세스의 것일 수 있다.
rm -f "$TMPROOT/sessions/$P_ACCT.json"; rm -rf "$RATE_DIR"
seed_anchor acct-a c@example.com login 1700000029000
OUT=$(run "$SESS_A" 120)
assert_contains "T35 프로세스를 모르면 로그인 앵커는 추정(~)으로 그려짐" "~c@example.com" "$(first_line "$OUT")"

# 수신기가 멈춘 것처럼 보이면(하트비트가 120초보다 오래됨) 이메일 뒤에 ? 가 붙는다.
stale_beat
OUT=$(run "$SESS_B" 120); assert_contains "T35 하트비트가 정체되면 이메일 뒤 ?" "b@example.com?" "$(first_line "$OUT")"
beat
OUT=$(run "$SESS_B" 120); assert_not_contains "T35 하트비트가 신선하면 ? 없음" "b@example.com?" "$(first_line "$OUT")"

# 압축 레이아웃은 계정을 보이지 않는다.
OUT=$(run "$SESS_B" 80)
assert_not_contains "T35 압축 레이아웃에는 계정이 없음" "b@example.com" "$OUT"
assert_no_match     "T35 압축 레이아웃에는 계정 자리의 ? 도 없음" ' \? ' "$OUT"
STATE_HOME="$STATE_NONE"

# 옛 계약의 파일은 읽지도 쓰지도 않는다.
assert_equals "T35 .claude.json 은 읽기만 했더라도 바뀌지 않음" "$DECOY_SUM" "$(cksum < "$TMPROOT/.claude.json")"
assert_equals "T35 cc-account.env 를 만들지 않음" "no" "$([ -e "$TMPROOT/cache/claude-statusline/cc-account.env" ] && echo yes || echo no)"
assert_equals "T35 accounts/<해시> 폴더를 만들지 않음" "no" "$([ -e "$TMPROOT/cache/claude-statusline/accounts" ] && echo yes || echo no)"

# --- T62: 한도 캐시는 세션별이라 다른 세션의 창이 섞이지 않고, 공용 rate-limits.env 는 건드리지 않는다 ---
rm -rf "$RATE_DIR"
RL_A=$(with_session rl-sess-a "$(json_with)")
RL_A_NONE=$(with_session rl-sess-a "$(json_without)")
RL_B_NONE=$(with_session rl-sess-b "$(json_without)")
run_keep "$RL_A" 120 >/dev/null
assert_equals "T62 세션 A 의 캐시 파일은 세션 id 로 갈린다" "yes" "$([ -f "$RATE_DIR/rl-sess-a.env" ] && echo yes || echo no)"
OUT=$(run_keep "$RL_B_NONE" 120)
assert_no_match "T62 창을 못 받은 다른 세션에 세션 A 의 5h 가 섞이지 않음" '5h .*[0-9]+%' "$OUT"
assert_no_match "T62 창을 못 받은 다른 세션에 세션 A 의 7d 가 섞이지 않음" '7d .*[0-9]+%' "$OUT"
OUT=$(run_keep "$RL_A_NONE" 120)
assert_match "T62 창을 못 받은 같은 세션은 자기 캐시에서 5h 공급" '5h .*24%' "$OUT"
SHARED_BODY="fivePct=99
fiveReset=$((NOW + 9000))
weekPct=98
weekReset=$((NOW + 200000))"
printf '%s\n' "$SHARED_BODY" > "$TMPROOT/cache/claude-statusline/rate-limits.env"
OUT=$(run_keep "$RL_B_NONE" 120)
assert_no_match "T62 공용 rate-limits.env 의 5h 를 읽지 않음" '5h .*[0-9]+%' "$OUT"
run_keep "$(with_session rl-sess-c "$(json_pct 31 32)")" 120 >/dev/null
assert_equals "T62 공용 rate-limits.env 에 쓰지 않음" "$SHARED_BODY" "$(cat "$TMPROOT/cache/claude-statusline/rate-limits.env")"
rm -f "$TMPROOT/cache/claude-statusline/rate-limits.env"
rm -rf "$RATE_DIR"

# --- T63: 같은 대화를 새 프로세스가 이어 받으면(--continue) 이전 프로세스가 남긴 창은 그리지 않는다 ---
#    계정 A 로 돌던 대화를 계정 B 의 새 프로세스가 이어 받고 payload 에 한도가 아직 없을 때, 만료 전인 A 의 한도가
#    그려지면 SessionDesk 의 usageWindows 까지 틀린 값이 간다.
run_keep "$RL_A" 120 >/dev/null
OUT=$(run_keep "$RL_A_NONE" 120)
assert_match "T63 같은 프로세스는 자기 캐시에서 5h 공급" '5h .*24%' "$OUT"
rm -f "$TMPROOT/sessions/$P_A.json"
seed_proc rl-sess-a "$P_A2"
OUT=$(run_keep "$RL_A_NONE" 120)
assert_no_match "T63 새 프로세스는 이전 프로세스의 5h 를 그리지 않음" '5h .*[0-9]+%' "$OUT"
assert_no_match "T63 새 프로세스는 이전 프로세스의 7d 를 그리지 않음" '7d .*[0-9]+%' "$OUT"
rm -f "$TMPROOT/sessions/$P_A2.json"
seed_proc rl-sess-a "$P_A"
OUT=$(run_keep "$RL_A_NONE" 120)
assert_no_match "T63 옛 프로세스로 돌아가도 지워진 창은 돌아오지 않는다" '5h .*[0-9]+%' "$OUT"
rm -rf "$RATE_DIR"

# --- T64: 비정상 종료한 프로세스가 파일을 남겨도 그 프로세스의 창은 새 프로세스로 넘어가지 않는다 ---
#    강제 종료·충돌·재부팅은 <설정 폴더>/sessions/<pid>.json 을 지우지 못한다. 그 파일은 프로세스가 아니므로,
#    같은 대화를 --continue 한 새 프로세스는 죽은 프로세스의 한도를 물려받지 않는다. 생존 확인이 없으면 가장 늦게 시작한 파일이
#    이기므로, 죽은 쪽의 시작 시각을 더 늦게 시드해 파일 이름 순서와 무관하게 죽은 프로세스가 골라지게 한다.
live_proc P_DEAD
live_proc P_NEW
rm -f "$TMPROOT/sessions/$P_A.json"
seed_proc rl-sess-a "$P_DEAD" 1700000005000
run_keep "$RL_A" 120 >/dev/null
kill "$P_DEAD"; wait "$P_DEAD" 2>/dev/null || true
seed_proc rl-sess-a "$P_NEW"
OUT=$(run_keep "$RL_A_NONE" 120)
assert_no_match "T64 죽은 프로세스가 남긴 파일의 5h 를 새 프로세스가 그리지 않음" '5h .*[0-9]+%' "$OUT"
assert_no_match "T64 죽은 프로세스가 남긴 파일의 7d 를 새 프로세스가 그리지 않음" '7d .*[0-9]+%' "$OUT"
rm -f "$TMPROOT/sessions/$P_DEAD.json" "$TMPROOT/sessions/$P_NEW.json"
seed_proc rl-sess-a "$P_A"
rm -rf "$RATE_DIR"

# --- T36: aws login 캐시 디렉터리 규칙 — 캐시가 없으면 세그먼트가 통째로 빠지고,
#     AWS_LOGIN_CACHE_DIR 오버라이드가 실제로 반영된다. 전체 레이아웃(81)은 모든 상태를
#     보이고, 압축(80)은 aws:✓ 만 숨긴다 ---
AWS_EMPTY_CACHE="$TMPROOT/aws-login-cache-empty"
mkdir -p "$AWS_EMPTY_CACHE"
aws_render() { printf '%s' "$(json_with_gh)" | \
  CLAUDE_PLUGIN_ROOT="$TMPROOT" XDG_DATA_HOME="$TMPROOT/data" XDG_STATE_HOME="$STATE_HOME" XDG_CONFIG_HOME="$TMPROOT" \
  XDG_CACHE_HOME="$TMPROOT/cache" CLAUDE_CONFIG_DIR="$TMPROOT" \
  CLAUDE_STATUSLINE_WIDTH="${2:-81}" \
  AWS_LOGIN_CACHE_DIR="$1" sh "$SL" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g"; }
assert_not_contains "T36 캐시 디렉터리가 비어 있으면 aws 세그먼트가 빠진다" "aws:" "$(aws_render "$AWS_EMPTY_CACHE")"
assert_not_contains "T36 캐시 디렉터리가 비어 있으면 압축에서도 빠진다" "aws:" "$(aws_render "$AWS_EMPTY_CACHE" 80)"

AWS_ONE_CACHE="$TMPROOT/aws-login-cache-one"
mkdir -p "$AWS_ONE_CACHE"
aws_cache "$AWS_ONE_CACHE/session.json" "$(date +%s)"
assert_contains     "T36 AWS_LOGIN_CACHE_DIR 오버라이드가 새 캐시를 읽어 aws:✓" "aws:✓" "$(aws_render "$AWS_ONE_CACHE")"
assert_not_contains "T36 압축은 정상 aws:✓ 를 숨긴다" "aws:" "$(aws_render "$AWS_ONE_CACHE" 80)"

# iat 는 로그인이 아니라 마지막 갱신 시각이다. 낡은 iat 는 직전 확인 결과(aws-check)를 따르고,
# 확인이 신선하면 실제 aws 를 부르지 않는다.
AWS_CHECK="$TMPROOT/cache/claude-statusline/aws-check"
aws_cache "$AWS_ONE_CACHE/session.json" "$(( $(date +%s) - 13 * 3600 ))"
printf '%s fail\n' "$(date +%s)" > "$AWS_CHECK"
assert_contains "T36 iat 가 낡고 직전 확인이 fail 이면 aws:expired" "aws:expired" "$(aws_render "$AWS_ONE_CACHE")"
assert_contains "T36 압축 1행에 aws:expired 표시" "gh@personal aws:expired" "$(first_line "$(aws_render "$AWS_ONE_CACHE" 80)")"
printf '%s ok\n' "$(date +%s)" > "$AWS_CHECK"
assert_contains "T36 iat 가 낡아도 직전 확인이 ok 면 aws:✓" "aws:✓" "$(aws_render "$AWS_ONE_CACHE")"
rm -f "$AWS_CHECK"
aws_cache "$AWS_ONE_CACHE/session.json" "$(date +%s)"
assert_contains "T36 같은 파일에 재로그인하면 aws:✓ 로 돌아온다" "aws:✓" "$(aws_render "$AWS_ONE_CACHE")"
printf '{}' > "$AWS_ONE_CACHE/session.json"
printf '%s ?\n' "$(date +%s)" > "$AWS_CHECK"   # 판독 불가 캐시도 확인을 띄우므로, 결과가 불명인 신선한 기록으로 막는다
assert_contains "T36 idToken 을 읽지 못하면 aws:?" "aws:?" "$(aws_render "$AWS_ONE_CACHE")"
assert_contains "T36 압축도 불명(aws:?)을 표시" "gh@personal aws:?" "$(first_line "$(aws_render "$AWS_ONE_CACHE" 80)")"

# --- T42: 두 매니페스트의 버전이 같다 ---
#    불변은 두 매니페스트의 버전 동일성이다. 리터럴 버전을 못박으면 다음 기능 변경의
#    버전 범프(AGENTS.md 의 필수 절차)마다 이 테스트가 붉어진다 — 그래서 특정 값을 이름
#    붙이지 않고 SemVer 세 자리 형태인지만 모양으로 가드한다.
PV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -1)
MV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/../../../.claude-plugin/marketplace.json" | sed -n 2p)
assert_equals "T42 plugin.json 과 marketplace.json 버전 일치" "$PV" "$MV"
assert_match  "T42 버전이 SemVer 세 자리 형태" '^[0-9]+\.[0-9]+\.[0-9]+$' "$PV"

# --- T50: 만료된 캐시 창은 그리지 않는다. 지난 창의 소진율은 더 이상 참이 아니다 ---
seed_rate_cache 94 "$((NOW - 60))" 41 "$WEEK_RESET"
OUT=$(run_keep "$(with_rl "$(json_without)")" 80)
assert_no_match "T50 만료된 5h 는 감춘다" '5h .*[0-9]+%' "$OUT"
assert_match    "T50 만료 안 된 7d 는 남는다" '7d 41%' "$OUT"
rm -f "$RATE_CACHE"

# --- T51: stdin 값이 캐시보다 새것이면 파일이 갱신된다 ---
seed_rate_cache 24 "$FIVE_RESET" 41 "$WEEK_RESET"
run_keep "$(with_rl "$(json_pct 55 60)")" 80 >/dev/null
assert_contains "T51 새 소진율이 저장됨" "fivePct=55" "$(cat "$RATE_CACHE")"
rm -f "$RATE_CACHE"

# --- T52: stdin 값은 캐시보다 낮아도 화면과 파일을 차지한다 ---
#    페이로드는 이 세션이 방금 받은 지금의 계정 상태이고, 캐시에는 그 값이 언제 관측된
#    것인지가 없다. 낮다는 이유로 캐시를 남기면 낡은 값이 창이 끝날 때까지 화면을 붙든다.
seed_rate_cache 60 "$FIVE_RESET" 90 "$WEEK_RESET"
OUT=$(run_keep "$(with_rl "$(json_pct 24 41)")" 80)
assert_contains "T52 페이로드가 파일에 반영됨" "fivePct=24" "$(cat "$RATE_CACHE")"
assert_match    "T52 화면도 페이로드를 따른다" '5h 24%' "$OUT"
rm -f "$RATE_CACHE"

# --- T53: 세션 최초 렌더에서도 캐시가 두 줄을 공급한다(전체 레이아웃) ---
seed_rate_cache 24 "$FIVE_RESET" 41 "$WEEK_RESET"
OUT=$(run_keep "$(with_rl "$(json_without)")" 120)
assert_match "T53 전체 레이아웃 5h 행" '5h .*24%' "$OUT"
assert_match "T53 전체 레이아웃 7d 행" '7d .*41%' "$OUT"
rm -f "$RATE_CACHE"

# --- T54: 창이 넘어가면 캐시가 아직 만료 전이어도 새 창이 화면을 차지한다 ---
#    캐시는 아직 만료되지 않은 옛 창(94%)을, stdin 은 새 창(3%)을 들고 있다. 캐시가 만료
#    되기를 기다리면 이미 끝난 창의 소진율이 몇 시간 더 남는다.
seed_rate_cache 94 "$((NOW + 100))" 41 "$WEEK_RESET"
OUT=$(run_keep "$(with_rl "$(json_pct 3 41)")" 80)
assert_match    "T54 새 창이 화면을 차지" '5h 3%' "$OUT"
assert_contains "T54 새 창이 파일에도 반영" "fivePct=3" "$(cat "$RATE_CACHE")"
rm -f "$RATE_CACHE"

# --- T59: 스위트가 실제 aws 를 한 번도 부르지 않았다 ---
#    낡거나 판독할 수 없는 aws 캐시는 확인 프로세스를 띄운다. 그 시나리오는 신선한 aws-check 기록으로 막는다.
#    확인 프로세스는 렌더와 분리돼 늦게 호출을 남기므로 잠시 기다린 뒤 센다. 실제 로그인 캐시를 읽지 않는 것은
#    위 export 가 맡고, 이 단언은 확인 프로세스가 뜨지 않았음만 본다.
sleep 1
assert_equals "T59 가짜 aws 호출 기록 0줄" "0" "$(wc -l < "$AWS_CALLS" | tr -d ' ')"

printf '\n---\nTOTAL pass=%d fail=%d\n' "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
