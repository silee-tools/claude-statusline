# 조사 보고서 — stuck-resume 이 한도로 멈춘 워커를 깨우지 못한 원인

작성: 2026-08-25 (Asia/Seoul). 조사 대상은 stuck-resume 0.4.0(설치 활성본, 저장소 판본과 diff 없음 확인).
결론을 먼저 쓴다: **매처 불일치가 아니다. 원인은 에피소드 데드라인 만료 뒤 롤오버가 막힌 영구 웨지이며,
`stuck-resume/scripts/resume.sh` 의 `handle_stop_failure` 롤오버 조건이 원인이다.** 수정·테스트·버전
bump 를 같은 커밋에 넣었다.

## 결론

`handle_stop_failure` 의 새 에피소드 롤오버 조건은 다음 세 가지를 모두 요구했다(수정 전 resume.sh:390).

1. `active_session = -` (활성 인계 없음)
2. 살아 있는 미복구 waiter 없음
3. `recovered_generation >= generation`

그런데 **데드라인 만료로 끝난 에피소드는 3번을 영영 만족하지 못한다.** `recovered_generation` 은 성공한
재개 턴의 `Stop` 에서만 올라가고(resume.sh:501), 실패로 끝난 에피소드는 그 기회를 놓친 채 세대 차이가
누적된다. 조사 시점 실측: `generation=73`, `recovered_generation=44`. 그 결과 모든 새 StopFailure 가
조건을 통과하지 못하고, 바로 아래의 데드라인 경과 조기 반환 분기(수정 전 resume.sh:415-419)로 빠져
아무 것도 하지 않고 종료코드 0 으로 끝났다. waiter 등록도, 재개도 일어나지 않는다.

이 분기는 상태를 건드리지 않는 유일한 `write_global`(resume.sh:416)이라 내용이 불변인데 mtime 만
갱신된다. 관측된 `global` mtime 2026-08-25 12:01 과 내용 불변(`last_attempt` 가 어제 19:40 그대로)이
정확히 이 분기의 서명이다.

## 타임라인 (모두 KST, epoch 는 `date -r` 로 재검증함)

| 시각 | 사건 | 근거 |
|---|---|---|
| 08-24 18:50:14 | episode 5 시작 (`first_seen`) | `~/.local/state/stuck-resume/v2/causes/5.rate_limit` |
| 08-24 19:40:55 | 마지막 탐침 (`last_attempt`, attempts=26) | `v2/global` |
| 08-24 20:40:00 | 데드라인 경과 (resetsAt+3600) | `v2/global deadline=1787571600` |
| 08-24 22:03 | 마지막 waiter 가 데드라인 확인에서 스스로 해제됨 | `waiters/` 디렉터리 mtime, resume.sh:569 부근의 포기 분기 |
| 08-25 11:59:24 | D1-7814 · D1-7662 가 세션 한도로 멈춤 | 각 transcript jsonl 4261행 · 3602행 |
| 08-25 12:01:37 | D1-7816 도 동일하게 멈춤 | transcript jsonl 3585행 |
| 08-25 12:01 | 웨지 분기가 `global` 을 무변경 덮어씀 (mtime 만 갱신) | `v2/global` mtime, 내용 불변 |
| 08-25 ~12:35 | 감독이 손으로 지시를 보내 D1-7814 재개 — 자동 재개 없음 | 사용자 보고 |

## 매처 불일치 가설은 기각했다

D1-7814 transcript(jsonl 4261행)의 synthetic 오류 메시지는 구조화 필드까지 갖고 있다:

```
"quotaLimits":{"status":"rejected","resetsAt":1787627400,...,"rateLimitType":"five_hour"},
"error":"rate_limit","isApiErrorMessage":true
```

메시지 본문은 세 워커 모두 동일하다: 「You've hit your session limit · resets 12:10pm (Asia/Seoul)」.
같은 형태의 실패가 어제 18:50 에 `causes/5.rate_limit` 파일을 만들었으므로, 클라이언트 v2.1.243 의
error 분류와 `hooks.json` 매처(`rate_limit|...`)는 어제까지 실제로 동작했다. 오늘도 동일 메시지이므로
매처가 원인일 근거가 없다.

## 가설별 판정

1. **매처 불일치 — 기각.** 위 섹션대로. 단, 개별 세션의 훅 실행 로그는 클라이언트가 남기지 않으므로
   「오늘 오전 세 번의 StopFailure 각각이 훅을 실행했다」는 직접 관측은 불가능하다. 간접 체인은
   ①동일 메시지가 어제 매처를 통과했음(cause 파일), ②global mtime 12:01 이 D1-7816 실패 시각과 일치,
   ③그 쓰기가 무변경 덮어쓰기라는 점에서 웨지 분기의 서명과 정확히 같다, 로 구성된다. 이를 넘어서
   특정하려면 Claude Code 자체의 hook 실행 디버그 로그가 필요하다(현시점 미확인 항목).
2. **episode 5 wedge — 확정.** 위 결론 섹션. 롤오버 조건(수정 전 :390)과 만료 조기 반환(수정 전
   :415-419)이 결합해, 데드라인이 지나고 세대 차이가 남으면 이후의 모든 실패를 영구히 무시한다.
3. **실행됐는데 등록 안 된 경우 — 이것이 실체.** 12:01 의 쓰기는 어떤 필드도 바꾸지 않았다. 웨지
   분기의 `write_global`(수정 전 :416)이 같은 내용을 다시 써서 mtime 만 바꿨고, 곧바로 반환했다.

참고 정리:

- 설치본의 `.in_use/`(mtime 오늘 11:28)는 resume.sh 가 참조하지 않는 경로다. Claude Code 플러그인
  로더의 흔적이며 본 사건과 무관하다.
- 최상위 `~/.local/state/stuck-resume/*.rate_limit` 파일들(08-20~21)은 v2 이전 구현 잔재다. 현행
  코드는 `$STATE_ROOT/v2` 만 읽고 쓰므로(resume.sh:5-6) 동작에 영향이 없으며, 정리만 하면 되는
  찌꺼기다.

## 세 워커 사례 판정

| 워커 | 멈춘 시각(KST) | stuck-resume 이 봤는가 | 어느 분기로 갔는가 |
|---|---|---|---|
| D1-7814 (`0bc5dbeb…`) | 11:59:24 | 봤다고 판정(간접 증거). transcript 4261행에 `"error":"rate_limit"` 있어 매처 통과 전제 | `handle_stop_failure` → 롤오버 조건 불충족 → 만료 조기 반환(수정 전 :415) → rc=0, waiter 미등록 |
| D1-7662 (`f0f92314…`) | 11:59:24 | 동일. 동일 메시지(3602행) | 동일 |
| D1-7816 (`e02fda7a…`) | 12:01:37 | 동일. global mtime 12:01 이 이 세션 실패 시각과 일치(마지막 덮어쓰기) | 동일 |

세 세션 모두 자동 재개가 일어나지 않았고, waiters 는 하나도 등록되지 않았다(waiters/ 비어 있음,
mtime 08-24 22:03).

## 수정 내용

`scripts/resume.sh` 의 롤오버 조건(resume.sh:390-392)에 만료 에피소드를 추가했다. 데드라인이 지난
에피소드이면서 활성 인계와 살아 있는 미복구 waiter 가 없으면, 세대 차이와 무관하게 새 에피소드를
연다(원인 파일 정리, delay/attempts 초기화 포함). 활성 인계 중이거나 live waiter 가 남아 있으면
종전대로 기각하므로 기존 계약(T16: 종료 시각 도달 시 미기상)은 그대로 유지된다.

웨지 상태 자체는 수정본이 다음 실패를 받는 순간 에피소드 6 을 열며 자가 치유되므로, 실제 상태 파일의
수동 정리는 필요 없다. 다만 설치 활성본은 0.4.0 이므로, 마켓플레이스에서 0.4.1 로 업데이트하기
전까지는 여전히 웨지 상태다.

## 검증 (Red → Green)

- RED: 사건을 그대로 재현하는 T34 추가 — `episode=5, generation=73, recovered_generation=44,
  deadline=1787571600` 시딩 뒤 오늘 시각의 rate_limit 실패 입력. 수정 전:
  `TOTAL pass=129 fail=6`(T34 전 항목 FAIL, rc=0, 상태 불변).
- GREEN: 수정 후 `sh stuck-resume/tests/resume.test.sh` → `TOTAL pass=135 fail=0`.
- 전체 게이트: `sh -c 'for t in */tests/*.test.sh; do sh "$t" || rc=1; done; (cd claude-statusline &&
  go test ./...) || rc=1'` → rc=0.

## 버전

- `stuck-resume/.claude-plugin/plugin.json`: 0.4.0 → 0.4.1
- `.claude-plugin/marketplace.json` stuck-resume 항목: 0.4.0 → 0.4.1

## 남은 미확인 사항

- 개별 StopFailure 이벤트의 훅 실행 여부는 Claude Code 측 실행 로그가 없어 직접 관측하지 못했다.
  간접 증거는 위 표의 수준을 넘지 않는다. 특정이 필요하면 `claude --debug` 로 한도 stop 을 재현해
  hook 실행 기록을 확인하는 것이 다음 수다.
- 어제 19:40 이후 22:03 사이의 세부 경과(attempts 26 회의 개별 결과)는 transcript 대조를 생략했다.
  웨지 메커니즘 판정에는 영향이 없다.
