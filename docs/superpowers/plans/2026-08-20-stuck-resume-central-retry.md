# stuck-resume 전역 재시도 조정 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 같은 로컬 머신의 `StopFailure` 세션을 하나의 상태로 조정해 실패 탐침을 전역 지수 백오프로 직렬화하고, 현재 탐침 세션의 `Stop`이 발생하면 대기 중인 모든 세션을 즉시 재개한다. 중복 호출과 대화 기록 오염과 자원 사용을 줄이되 재시도를 맡은 프로세스의 종료가 영구 대기로 이어지지 않아야 한다.

**Architecture:** `resume.sh` 하나가 `StopFailure`와 `Stop` 입력을 모두 처리하며 XDG 상태 디렉터리의 버전 전용 파일과 원자적 디렉터리 잠금으로 세션을 조정한다. 각 대기 훅은 자기 예약 시각까지 잠들고, 현재 탐침 세션의 `Stop` 훅은 성공 세대를 기록한 뒤 등록된 대기 훅을 로컬 신호로 한꺼번에 깨운다. SQLite와 상주 제어기와 상태 폴링은 두지 않는다.

**Tech Stack:** POSIX `sh`, Claude Code `StopFailure`·`Stop` 훅, XDG 상태 파일, 셸 기반 계약 테스트

**Spec:** [2026-08-20-stuck-resume-central-retry-design.md](../specs/2026-08-20-stuck-resume-central-retry-design.md)

## Global Constraints

- `stuck-resume`의 모든 실행 경로는 `#!/bin/sh`와 `set -eu`를 사용하며 Bash 전용 문법을 쓰지 않는다.
- `StopFailure`와 `Stop`은 기존 `stuck-resume/scripts/resume.sh` 하나를 호출하고 새 런타임 스크립트나 상주 프로세스를 추가하지 않는다.
- 상태 루트는 `${CLAUDE_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume}`이며 새 중앙 상태는 그 아래의 `v2` 디렉터리에 둔다.
- `CLAUDE_RESUME_WAIT_SECONDS`의 기본값은 30초이며 1초 이상 480초 이하의 정수만 허용한다. 이 값은 최초 지연과 전역 최소 간격과 지수 백오프 시작값이고 최대 지연은 480초다. 범위 제한은 비동기 `StopFailure` 훅의 600초 제한 시간 안에서 다음 상태 전이에 도달하게 한다.
- `CLAUDE_RESUME_MAX_ATTEMPTS`의 기본값은 `0`이며 0 이상의 정수만 허용한다. 잘못된 값은 `0`으로 바꾸고 양수를 명시하면 복구 확인 전의 직렬 탐침에 오류별 종료 시각보다 먼저 적용할 전역 호출 상한이 된다. `Stop` 성공 뒤 전체 조기 재개는 이 수에 포함하지 않는다.
- `server_error`, `overloaded`, `authentication_failed`는 원인별 최초 실패부터 3시간 뒤까지 재시도한다.
- `rate_limit`은 구조화된 리셋 시각이나 오류 문구의 리셋 시각을 얻으면 그 시각에서 1시간 뒤까지 재시도하고, 둘 다 없으면 최초 실패부터 3시간 뒤까지 재시도한다.
- 여러 오류가 겹치면 원인별 종료 시각 가운데 가장 늦은 값을 사용하고 같은 오류 반복은 종료 시각을 연장하지 않는다.
- Claude Code의 `autoContinueAtUsageLimit`을 읽거나 변경하지 않으며 자체 자동 재개와의 중복을 허용한다.
- 세션별 등록 시각이 탐침 시각을 분산하므로 무작위 지터와 난수 상태를 추가하지 않는다.
- 테스트의 `EXIT` 정리는 기존 `completed` 플래그 계약을 유지하고 실제 종료코드로 성패를 정한다.
- 기능 변경은 `stuck-resume/.claude-plugin/plugin.json`과 `.claude-plugin/marketplace.json`의 버전을 `0.4.0`으로 함께 올린다.
- 테스트 픽스처에는 실재 인물과 계정과 시크릿을 넣지 않는다.
- 커밋 제목은 Conventional Commits 형식을 따르고 Claude 세션 URL이나 생성 도구 서명을 넣지 않는다.

## 파일 구성

- `stuck-resume/scripts/resume.sh`는 훅 입력 정규화, 전역 상태 전이, 예약 대기, 성공 신호 수신과 재개 출력을 맡는다.
- `stuck-resume/hooks/hooks.json`은 기존 `StopFailure` 비동기 재개 훅과 새 동기 `Stop` 성공 훅을 같은 스크립트에 연결한다.
- `stuck-resume/tests/resume.test.sh`는 단일 훅 결과와 상태·시간 경계와 실제 복수 프로세스 신호 경로를 검증한다.
- `README.md`는 전역 조정 범위와 환경변수의 새 의미와 종료 시각과 성공 전파를 설명한다.
- `stuck-resume/.claude-plugin/plugin.json`과 `.claude-plugin/marketplace.json`은 배포 버전을 함께 선언한다.

---

### Task 1: 전역 상태와 StopFailure 재시도 스케줄러

**Files:**
- Modify: `stuck-resume/tests/resume.test.sh:1-181`
- Modify: `stuck-resume/scripts/resume.sh:1-56`

**Interfaces:**
- Consumes: 한 줄 JSON 훅 입력의 `hook_event_name`, `session_id`, `error`, `transcript_path`, `last_assistant_message`
- Produces: `${CLAUDE_RESUME_STATE_DIR}/v2/global`, `causes/<episode>.<error>`, `waiters/<session>` 상태와 재개 시 표준 오류 문장 및 종료코드 2
- Test seam: `CLAUDE_RESUME_TEST_NOW`가 숫자면 현재 epoch 대신 사용하고, `CLAUDE_RESUME_TEST_SKIP_SLEEP=1`이면 계산한 예약 시각까지 실제로 잠들지 않는다. 두 값은 README에 사용자 설정으로 공개하지 않는다.

#### 테스트 전략

**위험과 불변조건:** 여러 프로세스가 같은 상태를 갱신할 때 실제 호출이 겹치거나 지연 단계와 종료 시각이 유실될 수 있다. 잠금 안에서 하나의 전역 호출만 선택하고, 신규 세션의 최초 탐침이 기존 백오프 단계를 초기화하지 않으며, 같은 오류 반복이 종료 시각을 늘리지 않아야 한다.

**핵심 시나리오:** 세션 A와 B와 C가 서로 다른 시각에 등록될 때 각자의 최초 탐침 시각과 전역 최소 간격을 확인한다. 같은 세션의 재개가 다시 `StopFailure`로 끝날 때 직전 값의 2배로 증가해 480초에서 멈추는 지연과 원인별 종료 시각을 확인한다.

**통제할 의존성:** 실제 Claude API는 호출하지 않고 훅 JSON을 표준입력으로 주입한다. 상태 루트는 테스트 전용 디렉터리로 돌리고 현재 시각과 실제 대기만 위의 두 테스트 전용 환경변수로 통제한다. 리셋 시각 추출은 테스트 JSONL 파일과 오류 문구를 사용해 실제 파서를 지난다.

**실패 신호:** 재개 허용은 종료코드 2와 원인별 표준 오류 문장으로 관찰한다. 대기나 중단은 종료코드 0과 빈 표준 오류로 관찰하고, 상태 전이는 버전 전용 상태 파일의 정수 필드와 등록 레코드로 확인한다.

**유틸리티 판단:** 기존 `run`, `assert_equals`, `reset_state`를 유지하고 상태 한 줄을 읽는 좁은 테스트 함수만 추가한다. 전제와 기대를 감추는 범용 시나리오 실행기는 만들지 않는다.

**검증 레이어:** `resume.test.sh`의 단일 프로세스 검사는 입력 정규화와 산술 경계를 가장 이른 지점에서 검증한다. 같은 파일의 백그라운드 프로세스 검사는 잠금과 실제 종료코드를 함께 검증하되 외부 서비스는 사용하지 않는다.

**완료 증거:** 새 계약만 추가한 Red 실행에서 기존 구현이 전역 상태와 지수 백오프 단언을 실패하는지 확인한다. 구현 뒤 같은 스위트가 실패 0으로 끝나고 상태 루트 밖 파일이 생기지 않는지 확인한다.

- [ ] **Step 1: 기존 테스트의 종료코드 계약과 입력 검사를 보존하고 새 Red 계약을 추가한다**

`resume.test.sh`의 `completed` 트랩과 단언 함수는 유지한다. 기존 고정 간격과 원인별 카운터 상한을 기대하는 T1부터 T14는 새 정책과 충돌하므로, 원인별 재개 문장과 입력 격리 검사는 보존하고 다음 상태 검사 함수를 추가한다.

```sh
STATE_V2="$CLAUDE_RESUME_STATE_DIR/v2"

field() {
  sed -n "s/^$2=//p" "$STATE_V2/$1" 2>/dev/null | sed -n '1p'
}

set_now() {
  CLAUDE_RESUME_TEST_NOW=$1
  export CLAUDE_RESUME_TEST_NOW
}
```

다음 입력을 사용해 T1부터 순서대로 새 계약을 작성한다.

```sh
SESSION_A=11111111-2222-3333-4444-555555555555
SESSION_B=66666666-7777-8888-9999-000000000000
SESSION_C=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

failure_input() {
  printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"%s"}' "$1" "$2"
}
```

검사는 다음 결과를 각각 독립된 T 번호와 단언 이름으로 고정한다.

```text
T1  최초 rate_limit은 기본 시작 지연 30초 뒤 종료코드 2와 usage-limit 재개 문장을 낸다.
T2  현재 활성 세션의 다음 StopFailure는 다음 지연을 60초로 만들고 이후 120초, 240초, 480초에서 멈춘다.
T3  CLAUDE_RESUME_WAIT_SECONDS=5이면 지연이 5초, 10초, 20초, 40초, 80초, 160초, 320초, 480초에서 멈춘다.
T4  0과 481과 숫자가 아닌 CLAUDE_RESUME_WAIT_SECONDS는 30초를 쓰고, CLAUDE_RESUME_MAX_ATTEMPTS=2이면 직렬 탐침 두 번 뒤 새 탐침을 멈춘다.
T5  CLAUDE_RESUME_MAX_ATTEMPTS가 없거나 0이면 호출 횟수 대신 종료 시각만 적용한다.
T6  A, B, C의 등록 시각은 각각 시작 지연을 더한 최초 due를 가지며 새 등록은 global.delay와 base_delay와 max_attempts를 바꾸지 않는다.
T7  같은 due에서는 세션 식별자의 LC_ALL=C 바이트 순서로 우선순위가 정해진다.
T8  session_id와 error의 비정상 값은 unknown 또는 other로 격리되고 상태 루트 밖에 파일을 만들지 않는다.
T9  rate_limit, authentication_failed, server_error, overloaded가 기존 원인별 재개 문장을 유지한다.
```

- [ ] **Step 2: 종료 시각과 리셋 시각의 Red 계약을 추가한다**

`TMPROOT/transcript.jsonl`에 구조화된 리셋 시각을 가진 최신 API 오류 레코드를 쓴 뒤 입력의 `transcript_path`로 전달한다.

```sh
RESET_AT=1787230200
printf '%s\n' \
  '{"type":"assistant","isApiErrorMessage":true,"quotaLimits":{"status":"rejected","resetsAt":1787230200,"rateLimitType":"five_hour"}}' \
  > "$TMPROOT/transcript.jsonl"
RATE_INPUT=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"rate_limit","transcript_path":"%s"}' "$SESSION_A" "$TMPROOT/transcript.jsonl")
```

다음 경계를 고정한다.

```text
T10 구조화된 resetsAt이 있으면 rate_limit 종료 시각은 RESET_AT+3600이다.
T11 구조화된 값이 없고 last_assistant_message에 resets 시각이 있으면 로컬 시각을 epoch로 해석해 3600초를 더한다.
T12 두 리셋 시각 경로가 모두 없으면 rate_limit 최초 실패+10800을 쓴다.
T13 나머지 세 원인은 각각 최초 실패+10800을 쓴다.
T14 여러 원인이 있으면 가장 늦은 종료 시각을 global.deadline에 쓰고 같은 원인의 반복은 바꾸지 않는다.
T15 현재 시각이 global.deadline과 같거나 크면 종료코드 0으로 끝나며 프롬프트를 내지 않는다.
```

- [ ] **Step 3: 집중 테스트를 실행해 Red를 확인한다**

실행: `sh stuck-resume/tests/resume.test.sh`

기대: 기존 스크립트가 `v2/global`과 지수 백오프와 종료 시각을 만들지 못해 새 T1부터 실패한다. 스위트 자체는 끝까지 도달하고 마지막 합계의 `fail`이 0보다 크며 프로세스 종료코드도 0이 아니다.

- [ ] **Step 4: 상태 형식과 입력 정규화를 구현한다**

`resume.sh`에서 기존 원인별 카운터 구현을 교체하고 다음 경로와 레코드 형식을 사용한다.

```sh
STATE_ROOT="${CLAUDE_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume}"
STATE_DIR="$STATE_ROOT/v2"
LOCK_DIR="$STATE_DIR/lock"
CAUSE_DIR="$STATE_DIR/causes"
WAITER_DIR="$STATE_DIR/waiters"
GLOBAL="$STATE_DIR/global"
```

`global`은 한 줄씩 `key=value`로 다음 키를 가진다.

```text
episode=<non-negative integer>
generation=<non-negative integer>
recovered_generation=<non-negative integer>
delay=<integer from 1 through 480>
last_attempt=<non-negative epoch>
attempts=<non-negative integer>
base_delay=<integer from 1 through 480>
max_attempts=<non-negative integer>
active_session=<sanitized session or ->
active_generation=<non-negative integer>
handoff_at=<non-negative epoch>
deadline=<non-negative epoch>
```

`causes/<episode>.<error>`는 `first_seen=<epoch>`와 `deadline=<epoch>`를 가진다. `waiters/<session>`은 `pid`, `token`, `cause`, `episode`, `generation`, `registered_at`, `due_at`, `initial_used`를 같은 `key=value` 형식으로 가진다.

다음 함수 이름과 책임을 그대로 사용해 뒤 작업이 같은 인터페이스를 소비하게 한다.

```sh
now_epoch()                 # CLAUDE_RESUME_TEST_NOW 또는 date +%s를 표준출력에 쓴다.
number_or_default VALUE N   # 0 이상의 정수면 VALUE, 아니면 N을 쓴다.
base_delay_or_default VALUE # 1 이상 480 이하의 정수면 VALUE, 아니면 30을 쓴다.
read_field FILE KEY         # 첫 KEY=value의 value를 쓰고 없으면 빈 값을 쓴다.
write_atomic FILE CONTENT   # CONTENT를 같은 디렉터리의 임시 파일에 쓴 뒤 mv해 FILE로 바꾼다.
acquire_lock                # mkdir 잠금, 살아 있지 않거나 30초 지난 소유자 회수, 성공할 때만 반환한다.
release_lock                # 현재 프로세스가 소유한 잠금만 제거한다.
```

잠금 소유 파일에는 `pid`와 `acquired_at`을 기록한다. `release_lock`은 `trap`에서도 호출하되 다른 프로세스가 회수한 잠금을 지우지 않도록 저장된 `pid`가 `$$`와 같은지 확인한다.

- [ ] **Step 5: 오류별 종료 시각 계산을 구현한다**

다음 함수 경계를 사용한다.

```sh
transcript_reset_epoch TRANSCRIPT
message_reset_epoch MESSAGE NOW
cause_deadline ERROR NOW TRANSCRIPT MESSAGE
```

`transcript_reset_epoch`은 읽을 수 있는 일반 파일의 마지막 200줄만 `tail`과 `awk`로 읽고, `isApiErrorMessage`와 `quotaLimits`가 있는 레코드의 마지막 숫자형 `resetsAt`을 반환한다. `message_reset_epoch`은 `LC_ALL=C`에서 공식 문구의 `resets 3:45pm`과 `resets Mon 12:00am` 두 형식만 처리하며 BSD `date -j -f`와 GNU `date -d` 가운데 현재 플랫폼에서 성공하는 경로를 사용한다. 결과가 `NOW`보다 과거면 시간만 있는 형식은 다음 날로, 요일이 있는 형식은 다음 주 같은 요일로 옮긴다. 파싱 실패는 빈 출력으로 끝낸다.

`cause_deadline`의 우선순위는 다음과 같다.

```sh
case "$error" in
  rate_limit)
    reset=$(transcript_reset_epoch "$transcript")
    [ -n "$reset" ] || reset=$(message_reset_epoch "$last_message" "$now")
    if [ -n "$reset" ]; then printf '%s\n' "$((reset + 3600))"
    else printf '%s\n' "$((now + 10800))"
    fi ;;
  *) printf '%s\n' "$((now + 10800))" ;;
esac
```

원인 파일이 이미 있으면 기존 `first_seen`과 `deadline`을 유지한다. 새 원인 파일을 만들거나 기존 원인을 읽은 뒤 모든 현재 에피소드 원인 파일의 `deadline` 최댓값을 `global.deadline`에 쓴다.

- [ ] **Step 6: 등록과 전역 지수 백오프를 구현한다**

`handle_stop_failure`는 잠금 안에서 다음 순서로 상태를 바꾼다.

```text
1. 현재 에피소드가 없거나 활성 시도가 없고 recovered_generation보다 큰 미복구 등록도 없는 종료된 에피소드이면 episode를 1 올리고 첫 등록 훅의 정규화된 환경변수로 base_delay와 max_attempts를 고정하며 delay=base_delay, attempts=0으로 시작한다. 여기서 미복구 등록은 waiter의 generation이 recovered_generation보다 큰 경우다.
2. 현재 active_session이 입력 session과 같으면 활성 시도를 실패로 닫고 delay=min(delay*2, 480)으로 올린다.
3. 원인별 최초 시각과 종료 시각을 만들고 global.deadline을 최댓값으로 갱신한다.
4. now>=deadline이거나 양수 max_attempts에 도달했으면 새 직렬 탐침 등록을 제거하고 종료코드 0 경로로 보내되 현재 활성 시도의 Stop 성공 전파는 계속 허용한다.
5. 새 세션이면 due_at=max(now+base_delay, last_attempt+base_delay)와 initial_used=0을 기록한다.
6. 실패 뒤 다시 등록한 세션이면 due_at=max(now+delay, last_attempt+base_delay)와 initial_used=1을 기록한다.
7. generation을 1 올려 waiter 레코드에 기록한 뒤 잠금을 푼다.
```

대기 루프는 `due_at`까지 한 번 잠들고 잠금을 다시 얻는다. 자기 등록이 현재 파일의 `pid`와 `generation`과 일치하지 않으면 종료코드 0으로 끝난다. 자기 `generation`이 `recovered_generation` 이하이면 성공 전파 경로로 이동한다. 활성 시도의 `handoff_at`이 지났으면 그 활성 시도를 만료시키고, 아직 유효하면 그 시각까지 다시 잠든다. 자격이 있는 waiter 가운데 자기 레코드가 가장 이르면 waiter를 제거하고 `active_session`, `active_generation`, `handoff_at=attempt_at+delay`, `last_attempt`, `attempts`를 갱신한 뒤 잠금을 풀고 원인별 문장을 써서 종료코드 2로 끝난다.

대기 훅이 시작할 때 `USR1` 처리기를 먼저 설치한다. 처리기는 자기 sleep 자식만 종료하고 상태의 성공 세대를 확인한 뒤 재개 문장과 종료코드 2를 사용한다. 성공 세대가 확인되지 않으면 신호를 무시하고 대기를 계속한다.

- [ ] **Step 7: 집중 테스트를 실행해 Green을 확인한다**

실행: `sh stuck-resume/tests/resume.test.sh`

기대: 새 T1부터 T15와 보존한 입력·문장 검사가 모두 통과하고 마지막 합계가 `fail=0`이며 종료코드가 0이다.

- [ ] **Step 8: 변경을 커밋한다**

```bash
git add stuck-resume/scripts/resume.sh stuck-resume/tests/resume.test.sh
git commit -m "feat(stuck-resume): coordinate retries across sessions"
```

---

### Task 2: Stop 성공 전파와 프로세스 사망 인계

**Files:**
- Modify: `stuck-resume/hooks/hooks.json:3-17`
- Modify: `stuck-resume/tests/resume.test.sh`의 Task 1 검사 뒤
- Modify: `stuck-resume/scripts/resume.sh`의 이벤트 분기와 신호 처리

**Interfaces:**
- Consumes: Task 1의 `global` 레코드와 `waiters/<session>` 레코드, `acquire_lock`, `release_lock`, 원인별 재개 문장 함수
- Produces: 현재 활성 세션의 `Stop`이 기록하는 `recovered_generation`과 모든 기존 waiter 프로세스에 전달하는 `USR1` 신호

#### 테스트 전략

**위험과 불변조건:** 정상 세션의 무관한 `Stop`이나 늦은 `Stop`이 전체 재개를 일으키면 중복 호출이 폭증한다. 반대로 현재 활성 세션의 `Stop` 신호를 일부 훅이 놓치거나 활성 훅이 죽으면 세션이 영구 대기할 수 있다.

**핵심 시나리오:** A를 현재 활성 대상으로 만들고 B와 C의 실제 훅 프로세스를 대기시킨 뒤 A의 `Stop` 한 번으로 둘 다 종료코드 2가 되는지 검증한다. 다른 세션의 `Stop`, 소비된 활성 세대의 두 번째 `Stop`, 강제 종료된 waiter와 활성 대상의 인계를 함께 검증한다.

**통제할 의존성:** 신호 전달은 모의 함수로 바꾸지 않고 테스트 전용 상태 디렉터리에서 실제 POSIX 프로세스와 `USR1`을 사용한다. 대기는 5초 이하의 짧은 값으로 두고 테스트 종료 트랩이 자신이 만든 프로세스만 정리한다.

**실패 신호:** 대기 훅의 종료코드와 표준 오류 문장, `global.recovered_generation`, waiter 파일의 잔존 여부를 관찰한다. 무관한 `Stop`에서는 대기 프로세스가 계속 살아 있고 상태 해시가 바뀌지 않아야 한다.

**유틸리티 판단:** 백그라운드 훅의 프로세스 식별자와 출력 파일을 모으는 좁은 `start_waiter`와 `wait_for_file`만 추가한다. 임의 프로세스를 종료하는 범용 도구는 만들지 않는다.

**검증 레이어:** 실제 여러 `sh` 프로세스가 같은 상태와 신호를 사용하는 통합 검사를 `resume.test.sh` 안에 둔다. Claude 모델 호출은 `asyncRewake`의 종료코드 계약으로 경계를 닫고 실제 한도 도달 E2E는 수행하지 않는다.

**완료 증거:** Stop 훅 설정을 추가하기 전 Red에서 성공 전파 검사가 실패하고, 구현 뒤 B와 C가 모두 즉시 종료코드 2로 끝난다. 활성 대상과 다른 세션의 `Stop`은 아무 상태도 바꾸지 않는다.

- [ ] **Step 1: 성공 전파와 인계 Red 계약을 추가한다**

테스트에서 다음 보조 함수를 추가한다.

```sh
wait_for_file() {
  path=$1
  tries=0
  while [ ! -f "$path" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -f "$path" ]
}

start_waiter() {
  input=$1 out=$2 errfile=$3 rcfile=$4
  (
    waiter_rc=0
    printf '%s' "$input" | sh "$RESUME" >"$out" 2>"$errfile" || waiter_rc=$?
    printf '%s\n' "$waiter_rc" > "$rcfile"
  ) &
  STARTED_PID=$!
}
```

다음 계약을 추가한다.

```text
T16 hooks.json은 네 원인의 StopFailure asyncRewake와 같은 resume.sh를 부르는 Stop 훅을 각각 한 번 등록하고 제한 시간을 각각 600초와 40초로 둔다.
T17 A가 active이고 B와 C가 waiter이면 A의 Stop 한 번이 B와 C를 모두 종료코드 2와 각 원인별 문장으로 끝낸다.
T18 A의 두 번째 Stop은 recovered_generation을 다시 바꾸거나 추가 신호를 보내지 않는다.
T19 active가 A일 때 B의 Stop은 B와 C를 깨우지 않고 global 파일의 해시를 바꾸지 않는다.
T20 Stop 성공과 waiter 등록이 경합해 직접 신호를 못 받은 waiter도 generation<=recovered_generation이면 종료코드 2로 끝난다.
T21 waiter 하나를 강제 종료해도 A의 Stop은 남은 waiter를 깨우고 죽은 PID의 신호 실패로 중단되지 않는다.
T22 active A가 결과 없이 handoff_at을 넘기면 B가 이어받고, 이후 A의 늦은 Stop은 B와 C를 깨우지 않는다.
T23 잠금 소유 프로세스를 강제 종료하면 30초가 지난 테스트 시각에 다른 훅이 잠금을 회수한다.
```

테스트의 정리 트랩은 `STARTED_PID` 하나만 가정하지 않고 이 스위트가 시작한 PID 목록을 순회해 살아 있는 프로세스만 종료한 뒤 기존 `TMPROOT`를 제거한다. glob으로 다른 세션 파일이나 프로세스를 찾지 않는다.

- [ ] **Step 2: 집중 테스트를 실행해 Red를 확인한다**

실행: `sh stuck-resume/tests/resume.test.sh`

기대: T16이 `Stop` 등록 부재로 실패하고 T17부터 T23이 성공 신호와 인계 상태 부재로 실패한다. 기존 Task 1 검사는 계속 통과하며 스위트 종료코드는 0이 아니다.

- [ ] **Step 3: hooks.json에 Stop 성공 훅을 추가한다**

기존 `StopFailure` 배열은 유지하고 `hooks` 객체에 다음 항목을 추가한다.

```json
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "sh ${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh",
        "timeout": 40
      }
    ]
  }
]
```

`Stop`에는 `asyncRewake`를 두지 않는다. 현재 활성 세션의 정상 완료를 같은 훅 호출 안에서 확정하고 신호를 보낸 뒤 끝내야 하기 때문이다. 제한 시간 40초는 30초 된 잠금을 회수하고 성공 세대를 기록할 여유를 보장하며, 정상 경로에서는 짧은 파일 처리 뒤 즉시 끝난다.

- [ ] **Step 4: handle_stop과 성공 세대 소비를 구현한다**

`resume.sh`의 마지막 이벤트 분기는 다음 형태를 사용한다.

```sh
case "$hook_event" in
  StopFailure) handle_stop_failure ;;
  Stop)        handle_stop ;;
  *)           exit 0 ;;
esac
```

`handle_stop`은 잠금을 얻은 뒤 `active_session`이 입력 세션과 같은지 확인한다. 다르면 파일을 쓰지 않고 잠금을 푼다. 같으면 `recovered_generation=global.generation`을 기록하고 활성 세션과 세대와 인계 시각을 비운 뒤, 현재 `recovered_generation` 이하의 waiter PID와 등록 세대 목록을 잠금 안에서 스냅샷 파일에 쓴다. 잠금을 푼 뒤 검증된 PID 목록을 한 번의 셸 내장 `kill -USR1` 호출에 전달하고 일부 대상의 종료는 전체 실패로 취급하지 않는다.

잠금이 풀린 뒤 새로 등록된 waiter는 더 큰 세대 번호를 가지므로 이전 성공 전파에 포함되지 않는다. 활성 시도가 없고 `recovered_generation`보다 큰 waiter도 없으면 다음 `StopFailure`가 새 에피소드를 시작하며, 성공 전파를 아직 소비하지 않은 이전 세대의 파일은 새 에피소드 시작을 막지 않는다.

`StopFailure` 진입 프로세스는 입력을 정규화한 뒤 필요한 값을 환경변수로 내보내고 `exec sh "$0" --worker "$token"`으로 자기 프로세스를 교체한다. `exec` 뒤 PID는 유지되고 명령행에는 영문자와 숫자와 밑줄과 하이픈만 포함한 등록 토큰이 남으며, worker가 `pid`와 `token`을 waiter 레코드에 함께 쓴다.

`handle_stop`은 모든 waiter PID를 쉼표로 연결해 `ps -ww -p "$pid_csv" -o pid= -o command=`를 한 번 실행한다. 각 출력 행의 PID를 waiter 레코드와 대조하고 명령행에 정확한 `--worker <token>` 인자가 있는 대상만 신호 목록에 넣어, 종료된 훅의 PID가 재사용됐을 때 다른 프로세스에 `USR1`을 보내지 않는다. 신호 전송 뒤 스냅샷 파일을 제거한다.

- [ ] **Step 5: 결과 없는 활성 세대와 오래된 잠금의 인계를 구현한다**

대기 훅이 예약 시각에 잠금을 얻었을 때 `active_session`이 있고 `now>=handoff_at`이면 활성 세션과 세대와 인계 시각을 비운다. 이 전이는 성공이나 실패로 기록하지 않으므로 지연 단계와 호출 횟수를 바꾸지 않는다. 이어서 현재 due가 지난 waiter 가운데 가장 이른 대상을 고르는 Task 1 경로를 그대로 실행한다.

`acquire_lock`은 소유 PID가 살아 있더라도 `now-acquired_at>=30`이면 잠금을 회수한다. 회수할 때 소유 파일을 다시 읽어 처음 확인한 PID와 획득 시각이 같은 경우에만 기존 잠금 디렉터리를 제거해 새 소유자가 만든 잠금을 지우지 않는다.

- [ ] **Step 6: 집중 테스트를 실행해 Green을 확인한다**

실행: `sh stuck-resume/tests/resume.test.sh`

기대: T1부터 T23까지 모두 통과하고 마지막 합계가 `fail=0`이며 종료코드가 0이다. 테스트 종료 뒤 이 스위트가 시작한 백그라운드 프로세스가 남지 않는다.

- [ ] **Step 7: 변경을 커밋한다**

```bash
git add stuck-resume/hooks/hooks.json stuck-resume/scripts/resume.sh stuck-resume/tests/resume.test.sh
git commit -m "feat(stuck-resume): wake all waiters after recovery"
```

---

### Task 3: 사용자 계약 문서화

**Files:**
- Modify: `README.md:238-336`

**Interfaces:**
- Consumes: Task 1과 Task 2가 구현한 전역 상태와 오류별 종료 시각과 성공 전파 계약
- Produces: 설치 사용자가 별도 소스 확인 없이 재시도 순서와 설정 의미와 한계를 이해할 수 있는 문서

#### 테스트 전략

**위험과 불변조건:** README가 기존 고정 간격과 세션별 카운터를 계속 설명하면 사용자가 새 동작과 호출량을 잘못 예측한다. 환경변수의 이름은 같지만 의미가 달라졌다는 사실과 기본값을 정확히 설명해야 한다.

**핵심 시나리오:** A와 B와 C가 시간차를 두고 실패한 예시에서 최초 탐침과 전역 최소 간격과 성공 후 전체 즉시 재개가 구현 계약과 일치하는지 대조한다. 네 오류의 종료 시각과 `rate_limit` 리셋 시각 누락 시 3시간 대체값을 확인한다.

**통제할 의존성:** README의 수치와 필드명은 승인된 설계 문서와 테스트 이름에서 직접 대조한다. 외부 Claude 계정이나 실제 한도 도달은 문서 검증에 사용하지 않는다.

**실패 신호:** `attempt counter`, 원인별 30초와 120초 고정 간격, 240회와 90회 기본 상한, 서버 오류 2시간처럼 제거해야 할 설명이 남으면 실패다. 새 설정 표의 수치가 테스트와 다르거나 `autoContinueAtUsageLimit`을 끈다고 서술해도 실패다.

**유틸리티 판단:** 문서 전용 검사 스크립트를 추가하지 않는다. 제거 대상 문구의 검색과 설계·테스트의 직접 대조가 이 한 파일 변경에 충분하다.

**검증 레이어:** 정적 문서 대조가 README 계약을 맡고 `resume.test.sh`가 그 설명의 실행 근거를 맡는다.

**완료 증거:** 제거 대상 문구 검색 결과가 0건이고 README의 기본 지연, 지수 상한, 원인별 종료 시각, 전체 성공 전파가 집중 테스트의 관찰과 일치한다.

- [ ] **Step 1: stuck-resume 설명을 새 동작으로 바꾼다**

`How it works` 절은 다음 순서를 완전한 문장으로 설명한다.

```text
1. StopFailure 훅이 같은 머신의 전역 상태에 세션과 원인을 등록한다.
2. 새 세션은 등록 시각에서 시작 지연 뒤 최초 탐침 자격을 한 번 얻는다.
3. 실패가 확인되면 전역 지연이 시작값의 두 배씩 늘어 최대 480초에서 멈춘다.
4. 결과가 없으면 다음 예약 시각에 다른 대기 세션이 이어받는다.
5. 현재 탐침 세션의 Stop이 발생하면 모든 대기 훅이 즉시 종료코드 2로 끝난다.
```

`Settings` 표는 다음 세 행으로 바꾼다.

```markdown
| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_RESUME_WAIT_SECONDS` | `30` | first retry delay, minimum spacing before recovery, and exponential-backoff base from 1 through 480 seconds; the maximum delay is 480 seconds |
| `CLAUDE_RESUME_MAX_ATTEMPTS` | `0` | maximum serialized probes before recovery in one global episode; `0` leaves the error deadline as the only cap, and a successful broadcast is never limited |
| `CLAUDE_RESUME_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume` | shared state for all local sessions |
```

오류별 종료 설명에는 세 일반 오류가 최초 실패에서 3시간 뒤까지 재시도하고, `rate_limit`은 리셋 예정 시각에서 1시간 뒤까지 재시도하며 시각이 없으면 최초 실패에서 3시간 뒤를 사용한다고 적는다. 여러 오류의 종료 시각은 가장 늦은 값을 사용한다고 적는다.

Claude Code 자체 자동 재개 설정은 검사하거나 변경하지 않고 두 재개가 겹칠 수 있다고 명시한다. 실제 한도 E2E를 수행하지 않았다는 `Limits` 절의 사실은 유지한다.

- [ ] **Step 2: 오래된 계약 문구가 제거됐는지 확인한다**

실행:

```sh
if rg -n 'attempt counter|30.*server_error|120.*otherwise|240.*server_error|90.*otherwise|transient API failure for roughly two' README.md; then
  exit 1
fi
```

기대: 출력 없이 종료코드 0이다. 이어서 `README.md`의 stuck-resume 절을 설계 문서의 목표, 비목표, 지수 백오프, 정상 완료, 오류별 종료 시각 절과 직접 대조한다.

- [ ] **Step 3: 집중 테스트로 문서의 실행 근거를 다시 확인한다**

실행: `sh stuck-resume/tests/resume.test.sh`

기대: 전부 통과하고 실패 0이다.

- [ ] **Step 4: 변경을 커밋한다**

```bash
git add README.md
git commit -m "docs(stuck-resume): explain centralized retry coordination"
```

---

### Task 4: 배포 버전과 전체 검증

**Files:**
- Modify: `stuck-resume/.claude-plugin/plugin.json:4`
- Modify: `.claude-plugin/marketplace.json:31`

**Interfaces:**
- Consumes: Task 1부터 Task 3까지의 기능과 문서 변경
- Produces: 두 매니페스트에 동일하게 기록된 `stuck-resume` 0.4.0 배포 계약

#### 테스트 전략

**위험과 불변조건:** 버전 고정 캐시에서 로드되는 플러그인의 두 버전이 다르면 설치본이 새 코드를 받지 못하거나 마켓플레이스 메타데이터와 패키지가 어긋난다. 집중 테스트만 통과하고 저장소 전체 게이트가 실패하면 다른 플러그인의 계약을 회귀시킨 상태다.

**핵심 시나리오:** 두 JSON의 `stuck-resume` 버전이 모두 0.4.0이고 `claude-statusline` 5.0.0과 마켓플레이스 자체 1.0.0은 바뀌지 않았는지 확인한다. 모든 셸 스위트와 Go 테스트가 실제 종료코드 0으로 끝나는지 확인한다.

**통제할 의존성:** 저장소 표준 전체 명령을 그대로 사용하고 Go 빌드는 저장소 규칙의 오프라인 계약을 유지한다. 실제 플러그인 설치와 외부 네트워크는 이 로컬 검증에 포함하지 않는다.

**실패 신호:** JSON 파싱 실패, 두 버전 불일치, 집중 스위트의 `fail>0`, 전체 명령의 비영 종료코드 가운데 하나라도 나오면 완료하지 않는다.

**유틸리티 판단:** 새 버전 검사 스크립트를 만들지 않는다. 두 파일의 정확한 JSON 값 비교와 기존 전체 게이트가 충분하다.

**검증 레이어:** 매니페스트 값 검사가 배포 메타데이터를, 집중 스위트가 stuck-resume 동작을, 저장소 전체 게이트가 두 플러그인의 회귀를 맡는다.

**완료 증거:** 집중 스위트의 최종 통과·실패 수와 전체 게이트 종료코드 0을 기록한다. `git diff --check`와 개인정보 검사를 통과하고 작업 범위의 파일만 커밋돼 있어야 한다.

- [ ] **Step 1: 두 버전을 0.4.0으로 맞춘다**

`stuck-resume/.claude-plugin/plugin.json`의 4번째 줄과 `.claude-plugin/marketplace.json`의 `stuck-resume` 항목 31번째 줄을 다음 값으로 바꾼다.

```json
"version": "0.4.0"
```

마켓플레이스 자체 버전 1.0.0과 `claude-statusline` 버전 5.0.0은 바꾸지 않는다.

- [ ] **Step 2: 버전 일치를 확인한다**

실행:

```sh
plugin_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' stuck-resume/.claude-plugin/plugin.json | sed -n '1p')
market_version=$(sed -n '28,34{s/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;}' .claude-plugin/marketplace.json)
[ "$plugin_version" = 0.4.0 ]
[ "$market_version" = "$plugin_version" ]
```

기대: 출력 없이 종료코드 0이다.

- [ ] **Step 3: 집중 테스트를 실행한다**

실행: `sh stuck-resume/tests/resume.test.sh`

기대: 마지막 합계가 `fail=0`이고 종료코드가 0이다. 최종 보고를 위해 통과 수와 실패 수를 기록한다.

- [ ] **Step 4: 저장소 전체 검증을 실행한다**

실행:

```sh
sh -c 'rc=0; for t in */tests/*.test.sh; do sh "$t" || rc=1; done; (cd claude-statusline && go test ./...) || rc=1; exit "$rc"'
```

기대: 모든 셸 스위트와 Go 테스트가 실행되고 최종 종료코드가 0이다. 시작하지 못한 스위트가 있으면 실패 개수와 관계없이 완료하지 않는다.

- [ ] **Step 5: 변경 범위와 개인정보를 확인한다**

실행:

```sh
git diff --check
git status --short
git diff --name-status HEAD
```

기대: 설계가 승인한 `resume.sh`, `hooks.json`, `resume.test.sh`, README와 두 매니페스트만 구현 변경으로 나타난다. diff에 로컬 절대경로, 실재 이메일, Claude 세션 URL, 금지된 공동 작성자와 세션 메타데이터가 없어야 한다.

- [ ] **Step 6: 버전을 커밋한다**

```bash
git add stuck-resume/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(stuck-resume): bump version to 0.4.0"
```

- [ ] **Step 7: 구현 전체를 정본 설계에 대조한다**

[2026-08-20-stuck-resume-central-retry-design.md](../specs/2026-08-20-stuck-resume-central-retry-design.md)의 목표, 비목표, 훅 구성, 전역 상태, 동시성 제어, 최초 탐침, 지수 백오프, 정상 완료, 결과 없는 시도, 오류별 종료 시각, 실패 처리, 호출 횟수, 상태 전환과 테스트 전략을 구현과 직접 대조한다. 계획의 체크 여부만으로 통과를 판정하지 않는다.

Expand 단계의 버전 전용 상태가 기존 카운터 경로와 충돌하지 않는지 확인한다. Migrate와 Contract는 설계 문서의 시작 조건이 충족되기 전에는 구현하지 않는다.
