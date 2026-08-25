# JSONL(Claude Code 세션 로그)의 토큰 사용량에 단가표를 곱해 일·주·월 비용을 집계한다.
# 사용: awk -v DAY=<UTC ISO> -v WEEK=<UTC ISO> -v MONTH=<UTC ISO> -v PRICES=<prices.tsv> -f 이파일 < JSONL
# 출력(key=value): available, dailyOpus, dailySonnet, dailyHaiku, weekly, monthly
# 수정 시 검토 관점:
# - `/"usage"/` 사전 필터로 usage 를 담은 라인만 처리한다. content/text 필드를 포함한
#   대용량 라인 전체를 매 줄 스캔하면 안 된다 — 실측 654개 파일 384MB 12만 줄에서
#   char-by-char 누적 방식은 120초를 넘겼고, match()/substr() 기반 추출은 약 11초에 끝난다.
#   필드 추출을 다시 손볼 때도 문자 단위 루프로 문자열을 누적하는 방식(str = str c)으로
#   되돌리면 같은 성능 회귀가 재발한다.
# - message.id 추출은 반드시 `msg_` 접두사에 anchor 한다(`field("\"id\":\"msg_[^\"]*\"")`).
#   assistant 라인에는 흔히 tool_use 블록의 `toolu_` id 가 message.id 보다 먼저 나타나므로,
#   anchor 없이 첫 `"id"` 매치를 쓰면 잘못된 id 를 집어 dedup 키가 깨진다. Claude 메시지 id 는
#   항상 `msg_` 로 시작하는 성질에 기대는 anchor 다.
# - dedup 키는 `message.id:requestId` 이고 최초 등장만 채택한다(스트리밍 재전송 중복 제거).
# - 단가표 매칭은 완전 일치 우선, 없으면 최장 접두사 일치(`claude-haiku-4-5-20251001` ->
#   `claude-haiku-4-5`)다. 매칭 실패 모델은 집계에서 제외한다.
# - 비용은 input/output/cache_creation/cache_read 네 토큰 필드에 각 단가를 곱한 합이다.
#   cache_creation_input_tokens 는 5분(1.25배) 단가 하나로만 계산한다 — 1시간/5분 캐시를
#   나눠 계산하는 모델은 세션 로그 집계 오라클 대비 비용을 과다 산정하는 것으로 실측
#   확인됐으므로 분리 로직을 추가하지 않는다.
# - 버킷 분류는 UTC ISO 문자열 사전 비교에 의존한다(POSIX awk 에 mktime 이 없다). 경계와
#   timestamp 양쪽 모두 초 단위(YYYY-MM-DDTHH:MM:SS, 19자)로 정규화한 뒤 비교해야
#   밀리초·`Z` 표기 차이에 흔들리지 않는다.
BEGIN {
  while ((getline line < PRICES) > 0) {
    nf = split(line, a, "\t")
    if (nf >= 5) { pin[a[1]] = a[2]; pout[a[1]] = a[3]; pcw[a[1]] = a[4]; pcr[a[1]] = a[5] }
  }
  DAY = substr(DAY, 1, 19); WEEK = substr(WEEK, 1, 19); MONTH = substr(MONTH, 1, 19)
}
# 정규식 re 에 매치된 첫 `"key":value` 조각에서 값만 뽑는다(콜론 앞 잘라내고 따옴표 제거).
function field(re,   s) {
  if (match($0, re)) { s = substr($0, RSTART, RLENGTH); sub(/^[^:]*:/, "", s); gsub(/"/, "", s); return s }
  return ""
}
/"usage"/ {
  ts = field("\"timestamp\":\"[^\"]*\"")
  id = field("\"id\":\"msg_[^\"]*\"")
  rq = field("\"requestId\":\"[^\"]*\"")
  if (id == "" || ts == "") next
  dk = id ":" rq
  if (seen[dk]) next
  seen[dk] = 1
  model = field("\"model\":\"[^\"]*\"")
  pk = ""
  if (model in pin) pk = model
  else { best = ""; for (k in pin) if (index(model, k) == 1 && length(k) > length(best)) best = k; pk = best }
  if (pk == "") next
  it = field("\"input_tokens\":[0-9]+") + 0
  ot = field("\"output_tokens\":[0-9]+") + 0
  cc = field("\"cache_creation_input_tokens\":[0-9]+") + 0
  cr = field("\"cache_read_input_tokens\":[0-9]+") + 0
  cost = it * pin[pk] + ot * pout[pk] + cc * pcw[pk] + cr * pcr[pk]
  tsec = substr(ts, 1, 19)
  if (tsec >= MONTH) monthly += cost
  if (tsec >= WEEK) weekly += cost
  if (tsec >= DAY) {
    if (pk == "claude-opus-4-8") d_opus += cost
    else if (pk == "claude-sonnet-5") d_sonnet += cost
    else if (pk == "claude-haiku-4-5") d_haiku += cost
    else d_opus += cost   # 미분류 모델은 opus 슬롯에 합산(표시 폭 보존)
  }
}
END {
  printf "available=true\n"
  printf "dailyOpus=%.2f\n", d_opus
  printf "dailySonnet=%.2f\n", d_sonnet
  printf "dailyHaiku=%.2f\n", d_haiku
  printf "weekly=%.0f\n", weekly
  printf "monthly=%.0f\n", monthly
}
