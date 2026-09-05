# settings.json 의 최상위 "statusLine" 을 NEW 로 치환한다. 없으면 최상위 객체에 삽입한다.
# 문자열·브레이스·브래킷 인지 스캔이라 값 안의 { } 나 다른 키에 영향받지 않는다.
# -v NEW='{"type":"command","command":"..."}'
# 수정 시 검토 관점: 호출부는 이 출력을 tmp 에 쓰고 json.awk 로 재파싱해 목표 값을 확인한
# 뒤에만 원본과 교체한다. 이 변환이 어긋나도 재파싱 게이트가 파손된 파일의 반영을 막는다.
BEGIN {
  RS = "\x01"
  if (NEW == "") NEW = ENVIRON["STATUSLINE_NEW"]
}
function skipvalue(s, i, n,   c, depth, d, e) {
  c = substr(s, i, 1)
  if (c == "\"") { i++; while (i <= n) { d = substr(s, i, 1); i++
      if (d == "\\") { i++; continue } if (d == "\"") break }; return i }
  if (c == "{" || c == "[") { depth = 0
    while (i <= n) { d = substr(s, i, 1)
      if (d == "\"") { i++; while (i <= n) { e = substr(s, i, 1); i++
          if (e == "\\") { i++; continue } if (e == "\"") break }; continue }
      if (d == "{" || d == "[") depth++
      else if (d == "}" || d == "]") { depth--; if (depth == 0) return i + 1 }
      i++ }
    return i }
  while (i <= n && substr(s, i, 1) !~ /[,}\]\r\n \t]/) i++
  return i
}
{
  s = $0; n = length(s); i = 1; out = ""; depth = 0; replaced = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"") {
      tok = "\""; i++
      while (i <= n) { d = substr(s, i, 1); tok = tok d; i++
        if (d == "\\") { tok = tok substr(s, i, 1); i++; continue }
        if (d == "\"") break }
      if (depth == 1 && tok == "\"statusLine\"" && !replaced) {
        j = i; while (j <= n && substr(s, j, 1) ~ /[ \t\r\n]/) j++
        if (substr(s, j, 1) == ":") {
          out = out tok ": " NEW; i = j + 1
          while (i <= n && substr(s, i, 1) ~ /[ \t\r\n]/) i++
          i = skipvalue(s, i, n); replaced = 1; continue
        }
      }
      out = out tok; continue
    }
    if (c == "{") { depth++; out = out c; i++; continue }
    if (c == "}") { depth--; out = out c; i++; continue }
    if (c == "[") { depth++; out = out c; i++; continue }
    if (c == "]") { depth--; out = out c; i++; continue }
    out = out c; i++
  }
  if (!replaced) {
    p = index(out, "{"); head = substr(out, 1, p); tail = substr(out, p + 1)
    rest = tail; sub(/^[ \t\r\n]+/, "", rest)
    sep = (substr(rest, 1, 1) == "}") ? "" : ","
    out = head "\"statusLine\": " NEW sep tail
  }
  printf "%s", out
}
