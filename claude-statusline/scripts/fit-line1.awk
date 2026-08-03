# 첫 행의 경로와 브랜치를 표시 폭 예산에 맞춰 줄인다.
# stdin 두 줄(경로, 브랜치) -> stdout 두 줄. LC_ALL=C 로 호출해 바이트 단위로 다룬다.
#
# 수정 시 검토 관점: 폭 계산은 UTF-8 의 바이트 순서가 코드포인트 순서를 보존한다는 성질에
# 기댄다. 경계 시퀀스를 옥탈 리터럴로 비교하므로 awk 구현의 유니코드 지원에 의존하지 않는다.
# 이 성질을 깨는 방식(코드포인트 산술, length() 의 문자 수 가정)으로 바꾸지 않는다.
# 전체 예산은 호출자가 `-v budget=...` 으로 넘긴다. 첫 행의 시각·공백·브랜치 아이콘처럼
# 이 파일이 렌더하지 않는 고정 폭을 여기서 다시 계산하면 조립부와 조용히 어긋난다.

function is_wide(sq) {
  if (length(sq) == 4) return 1          # 4바이트 시퀀스는 이모지 평면으로 보고 두 칸
  if (length(sq) != 3) return 0          # 1~2바이트는 모두 한 칸
  if (sq >= "\341\204\200" && sq <= "\341\205\237") return 1   # U+1100..U+115F 한글 자모
  if (sq >= "\342\272\200" && sq <= "\352\223\217") return 1   # U+2E80..U+A4CF CJK
  if (sq >= "\352\260\200" && sq <= "\355\236\243") return 1   # U+AC00..U+D7A3 한글 음절
  if (sq >= "\357\244\200" && sq <= "\357\253\277") return 1   # U+F900..U+FAFF CJK 호환
  if (sq >= "\357\270\260" && sq <= "\357\271\257") return 1   # U+FE30..U+FE6F 세로형
  if (sq >= "\357\274\200" && sq <= "\357\275\240") return 1   # U+FF00..U+FF60 전각
  if (sq >= "\357\277\240" && sq <= "\357\277\246") return 1   # U+FFE0..U+FFE6 전각 기호
  return 0
}

function seqlen(c) {
  if (c < "\200") return 1
  if (c < "\340") return 2
  if (c < "\360") return 3
  return 4
}

# 표시 폭. ANSI 이스케이프(ESC [ ... m)는 0으로 센다.
function vwidth(s,   i, n, c, sq, L, tot) {
  n = length(s); i = 1; tot = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\033") {
      i++
      while (i <= n) { c = substr(s, i, 1); i++; if (c == "m") break }
      continue
    }
    L = seqlen(c); sq = substr(s, i, L)
    tot += is_wide(sq) ? 2 : 1
    i += L
  }
  return tot
}

# 표시 폭 limit 까지만 남긴다. 두 칸 문자가 한 칸 자리에 걸리면 넣지 않는다.
function cut(s, limit,   i, n, c, sq, L, wd, tot, out) {
  n = length(s); i = 1; tot = 0; out = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\033") {
      sq = c; i++
      while (i <= n) { c = substr(s, i, 1); sq = sq c; i++; if (c == "m") break }
      out = out sq
      continue
    }
    L = seqlen(c); sq = substr(s, i, L); wd = is_wide(sq) ? 2 : 1
    if (tot + wd > limit) break
    tot += wd; out = out sq; i += L
  }
  return out
}

# 넘칠 때만 자르고 줄임표를 붙인다. 줄임표 한 칸을 미리 빼서 결과가 limit 를 넘지 않게 한다.
# 색이 섞인 입력은 잘린 자리에서 색이 열린 채 끝날 수 있으므로 리셋으로 닫는다.
function fit(s, limit) {
  if (vwidth(s) <= limit) return s
  return cut(s, limit - 1) "…" (index(s, "\033") ? "\033[0m" : "")
}

BEGIN {
  if (budget == "") exit 2
  getline path_seg
  getline branch_seg
  pw = vwidth(path_seg)
  bw = vwidth(branch_seg)
  if (pw + bw <= budget) {
    plim = pw; blim = bw
  } else {
    half = int(budget / 2)
    if (bw <= half)      { plim = budget - bw; blim = bw }
    else if (pw <= half) { plim = pw;          blim = budget - pw }
    else                 { plim = half;        blim = budget - half }
  }
  print fit(path_seg, plim)
  print fit(branch_seg, blim)
}
