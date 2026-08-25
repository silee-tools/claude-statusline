# 경로 추적 JSON 스캐너. stdin 의 한 JSON 값을 읽어 문자열/숫자/불리언/null 리프마다
# `점경로<TAB>스칼라` 를 출력한다. 경로는 점으로 이어붙이므로 중첩 키가 서로 섞이지 않는다
# (최상위 version 과 model.version 이 구분된다).
# 수정 시 검토 관점: 이 점 조인 경로는 키에 점이 들어가면 스택이 어긋난다. 여기 대상인
# statusline·settings 의 키에는 점이 없어 안전하다. 점이 흔한 데이터(LiteLLM 등)에는 쓰지 않는다.
BEGIN { RS = "\x01" }   # stdin 전체를 한 레코드로 읽는다
{
  s = $0; n = length(s); i = 1; path = ""; key = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"") {
      str = ""; i++
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { esc = substr(s, i + 1, 1)
          if (esc == "n") str = str "\n"
          else if (esc == "t") str = str "\t"
          else if (esc == "u") { str = str substr(s, i, 6); i += 4 }
          else str = str esc
          i += 2; continue }
        if (c == "\"") break
        str = str c; i++
      }
      i++
      j = i; while (j <= n && substr(s, j, 1) ~ /[ \t\n\r]/) j++
      if (substr(s, j, 1) == ":") { key = str; i = j + 1 }
      else { print path "." key "\t" str; key = "" }
      continue
    }
    if (c == "{") { path = path "." key; key = ""; i++; continue }
    if (c == "}") { sub(/\.[^.]*$/, "", path); i++; continue }
    if (c ~ /[-0-9]/) {
      num = ""
      while (i <= n && substr(s, i, 1) ~ /[-0-9.eE+]/) { num = num substr(s, i, 1); i++ }
      print path "." key "\t" num; key = ""
      continue
    }
    if (c == "t" || c == "f" || c == "n") {
      while (i <= n && substr(s, i, 1) ~ /[a-z]/) i++
      print path "." key "\t" c; key = ""
      continue
    }
    i++
  }
}
