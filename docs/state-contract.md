# Agent 상태 JSON 계약 v1

이 계약은 Claude와 Codex 세션 상태를 하나의 JSON 형식으로 표현한다. 모든 producer가 같은 필드명, 열거값과 시각 단위를 써야 메뉴바 앱과 Widget이 provider별 예외 없이 상태를 합칠 수 있다.

## 인코딩 규칙

- 문서는 UTF-8 JSON 객체다.
- 필드명과 열거값은 대소문자를 구분하며 아래 literal을 그대로 쓴다.
- 시각은 UTC 기준 Unix epoch seconds 정수다. ISO 8601 문자열이나 milliseconds를 쓰지 않는다.
- optional 값이 없으면 해당 필드를 생략한다. consumer는 생략과 JSON `null`을 모두 값 없음으로 처리한다.
- `schemaVersion`이 `1`이 아니거나 필수 필드가 없거나 열거값을 알 수 없으면 문서 전체를 거부한다.

## Session snapshot

최상위 객체는 한 provider의 한 세션을 한 관측 시점에 나타낸다.

| 필드 | JSON 타입 | 필수 | 의미 |
|---|---|---:|---|
| `schemaVersion` | integer | 예 | 반드시 `1`이다. |
| `provider` | string enum | 예 | 상태를 만든 provider다. |
| `sessionID` | string | 예 | provider 안에서 세션을 식별하는 값이다. |
| `workspace` | string | 예 | 세션이 연결된 workspace다. |
| `model` | string | 아니요 | provider가 보고한 model이다. |
| `activity` | string enum | 예 | producer가 관측한 현재 활동이다. |
| `usageWindows` | array | 예 | usage window 목록이며 없으면 빈 배열이다. |
| `resumeProgress` | object | 아니요 | stuck-resumer가 진행 중일 때의 정보다. |
| `observedAt` | integer | 예 | producer가 이 상태를 관측한 Unix epoch seconds다. |

`provider`는 다음 literal만 허용한다.

| literal | 의미 |
|---|---|
| `claude` | Claude 세션 |
| `codex` | Codex 세션 |

`activity`는 다음 literal만 허용한다.

| literal | 의미 |
|---|---|
| `inactive` | 활성 세션 정보가 없음 |
| `idle` | 세션이 유휴 상태임 |
| `working` | 응답이나 도구 실행을 처리 중임 |
| `waitingInput` | 사용자 입력을 기다림 |
| `waitingApproval` | 사용자 승인을 기다림 |
| `rateLimited` | usage limit으로 진행할 수 없음 |
| `resuming` | 중단된 turn을 재개하는 중임 |
| `failed` | 세션이나 재개가 실패함 |
| `stale` | 관측값이 freshness 기준을 넘김 |

## Usage window

`usageWindows`의 각 객체는 독립적인 한도 창을 나타낸다.

| 필드 | JSON 타입 | 필수 | 의미 |
|---|---|---:|---|
| `id` | string | 예 | 표시 문구가 바뀌어도 유지되는 provider 내부 식별자다. |
| `label` | string | 예 | 사용자에게 보여 줄 짧은 이름이다. |
| `usedPercent` | integer | 예 | 사용한 비율이며 `0...100` 범위다. 경곗값 `0`과 `100`을 허용한다. |
| `resetsAt` | integer | 예 | 한도가 초기화되는 Unix epoch seconds다. |
| `windowMinutes` | integer | 아니요 | provider가 알려 준 창 길이의 분 단위 값이다. |

`usedPercent`가 `0`보다 작거나 `100`보다 크면 snapshot 전체를 거부한다.

## Resume progress

`resumeProgress` 객체는 재개 시도가 존재할 때만 넣는다.

| 필드 | JSON 타입 | 필수 | 의미 |
|---|---|---:|---|
| `cause` | string enum | 예 | 재개가 필요한 원인이다. |
| `attempt` | integer | 예 | 현재 재개 시도 번호다. |
| `maximumAttempts` | integer | 아니요 | 원인별 최대 시도 횟수를 알 때의 값이다. |
| `nextAttemptAt` | integer | 예 | 다음 시도를 시작할 Unix epoch seconds다. |
| `deadlineAt` | integer | 예 | 현재 재개 작업의 종료 시한인 Unix epoch seconds다. |

`cause`는 다음 literal만 허용한다.

| literal | 의미 |
|---|---|
| `rateLimit` | usage limit 도달 |
| `authenticationFailed` | 인증 실패 또는 만료 |
| `serverError` | provider 서버 오류 |
| `overloaded` | provider 과부하 |
| `other` | 위 값으로 분류할 수 없는 원인 |

## 상태 우선순위

consumer가 같은 세션에 관한 여러 실시간 후보를 합치면 다음 우선순위를 적용한다.

1. `stale`
2. `failed`
3. `resuming`
4. `rateLimited`
5. `waitingApproval`
6. `waitingInput`
7. `working`
8. `idle`
9. `inactive`

후보가 없으면 `inactive`다.

staleness는 consumer가 전달한 `now`, snapshot의 `observedAt`과 0 이상인 `staleAfter` seconds로 판단한다. `now - observedAt`이 `staleAfter` 이상이면 다른 모든 후보보다 `stale`이 우선한다. 두 값이 같은 경계에서도 stale이다. `observedAt`이 `now`보다 미래면 시간 차이만으로 stale로 바꾸지 않는다.

## 예시

```json
{
  "schemaVersion": 1,
  "provider": "claude",
  "sessionID": "session-123",
  "workspace": "/tmp/example-project",
  "model": "example-model",
  "activity": "resuming",
  "usageWindows": [
    {
      "id": "five-hour",
      "label": "5 hour",
      "usedPercent": 100,
      "resetsAt": 1787230200,
      "windowMinutes": 300
    }
  ],
  "resumeProgress": {
    "cause": "rateLimit",
    "attempt": 2,
    "maximumAttempts": 5,
    "nextAttemptAt": 1787229900,
    "deadlineAt": 1787230200
  },
  "observedAt": 1787229600
}
```

## Privacy 경계

snapshot에는 상태를 합치고 표시하는 데 필요한 metadata만 넣는다. producer는 prompt, response, tool arguments와 그 내용을 복원할 수 있는 원문을 수집하거나 기록하지 않는다.
