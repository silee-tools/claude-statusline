# JSONL(Claude Code 세션 로그)의 토큰 사용량에 단가표를 곱해 일·주·월 비용을 집계한다.
# 사용: awk -v DAY=<UTC ISO> -v WEEK=<UTC ISO> -v MONTH=<UTC ISO> -v PRICES=<prices.tsv> -f 이파일 < JSONL
# 출력(key=value): available, dailyOpus, dailySonnet, dailyHaiku, weekly, monthly
# 수정 시 검토 관점: 버킷 분류는 UTC ISO 문자열 사전 비교에 의존한다(POSIX awk 에 mktime 이 없다).
# 경계와 timestamp 양쪽 모두 초 단위(YYYY-MM-DDTHH:MM:SS, 19자)로 정규화한 뒤 비교해야
# 밀리초·`Z` 표기 차이에 흔들리지 않는다.
BEGIN {
  while ((getline line < PRICES) > 0) {
    nf = split(line, a, "\t")
    if (nf >= 5) { pin[a[1]] = a[2]; pout[a[1]] = a[3]; pcw[a[1]] = a[4]; pcr[a[1]] = a[5] }
  }
  DAY = substr(DAY, 1, 19); WEEK = substr(WEEK, 1, 19); MONTH = substr(MONTH, 1, 19)
}
# 한 JSON 오브젝트 라인을 스캔해 필요한 리프만 V[] 에 담는다.
function scan(s,   n, i, c, path, key, str, j, num, d) {
  delete V; n = length(s); i = 1; path = ""; key = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"") {
      str = ""; i++
      while (i <= n) { c = substr(s, i, 1)
        if (c == "\\") { i += 2; str = str substr(s, i - 1, 1); continue }
        if (c == "\"") break; str = str c; i++ }
      i++; j = i; while (j <= n && substr(s, j, 1) ~ /[ \t\r\n]/) j++
      if (substr(s, j, 1) == ":") { key = str; i = j + 1 }
      else { V[path "." key] = str; key = "" }; continue
    }
    if (c == "{") { path = path "." key; key = ""; i++; continue }
    if (c == "}") { sub(/\.[^.]*$/, "", path); i++; continue }
    if (c ~ /[-0-9]/) { num = ""
      while (i <= n && substr(s, i, 1) ~ /[-0-9.eE+]/) { num = num substr(s, i, 1); i++ }
      V[path "." key] = num; key = ""; continue }
    if (c == "t" || c == "f" || c == "n") {
      while (i <= n && substr(s, i, 1) ~ /[a-z]/) i++; V[path "." key] = c; key = ""; continue }
    i++
  }
}
# 단가표에서 model 에 맞는 키를 고른다: 완전 일치 → 최장 접두사 일치.
function pricekey(model,   k, best) {
  if (model in pin) return model
  best = ""
  for (k in pin) if (index(model, k) == 1 && length(k) > length(best)) best = k
  return best
}
{
  scan($0)
  id = V["..message.id"]; rq = V["..requestId"]; ts = V["..timestamp"]; model = V["..message.model"]
  if (id == "" || ts == "") next
  dk = id ":" rq
  if (seen[dk]) next
  seen[dk] = 1
  pk = pricekey(model)
  if (pk == "") next
  it = V["..message.usage.input_tokens"] + 0
  ot = V["..message.usage.output_tokens"] + 0
  cc = V["..message.usage.cache_creation_input_tokens"] + 0
  cr = V["..message.usage.cache_read_input_tokens"] + 0
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
