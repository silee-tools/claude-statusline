#!/bin/sh
set -eu

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
PRICES="$CACHE_DIR/prices.tsv"
URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MODELS="claude-fable-5 claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5"

mkdir -p "$CACHE_DIR"

# 내장 폴백 테이블(구현 시점 LiteLLM 스냅샷; Anthropic 공식 단가와 일치).
# 갱신 방법: 위 URL 의 각 모델 *_cost_per_token / *_token_cost 필드를 확인해 이 값을 맞춘다.
write_embedded() {
  cat > "$1" <<'TSV'
claude-fable-5	0.00001	0.00005	0.0000125	0.000001
claude-opus-4-8	0.000005	0.000025	0.00000625	0.0000005
claude-sonnet-5	0.000002	0.00001	0.0000025	0.0000002
claude-haiku-4-5	0.000001	0.000005	0.00000125	0.0000001
TSV
}

# 1일보다 신선하면 아무 것도 하지 않는다.
if [ -f "$PRICES" ] && [ -z "$(find "$PRICES" -mtime +0 2>/dev/null)" ]; then
  exit 0
fi

# 캐시가 아예 없으면 우선 내장 테이블로 최소 보장.
[ -f "$PRICES" ] || write_embedded "$PRICES"

command -v curl >/dev/null 2>&1 || exit 0

raw="$CACHE_DIR/litellm.json.tmp.$$"
if ! curl -fsSL --max-time 60 "$URL" -o "$raw" 2>/dev/null; then
  rm -f "$raw"; exit 0   # fetch 실패 → 기존(또는 방금 쓴 내장) 캐시 유지
fi

# 대상 모델별로 객체 블록을 브레이스·문자열 인지로 잘라 4개 단가 필드를 뽑는다.
# json.awk 를 쓰지 않는 이유: LiteLLM 키에 점(gpt-3.5-turbo 등)이 흔해 점 조인 경로가 깨진다.
tmp="$CACHE_DIR/prices.tsv.tmp.$$"
: > "$tmp"
ok=1
for m in $MODELS; do
  row=$(awk -v m="\"$m\":" '
    BEGIN { RS = "\x01" }
    {
      s = $0; k = index(s, m); if (!k) { print "MISSING"; next }
      i = k + length(m); while (i <= length(s) && substr(s, i, 1) ~ /[ \t\r\n]/) i++
      if (substr(s, i, 1) != "{") { print "MISSING"; next }
      depth = 0
      ipt = ""; opt = ""; cw = ""; cr = ""
      # 현재 모델 객체 안에서만(depth 1) 필드를 잡는다. 문자열은 통째로 건너뛴다.
      while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "\"") {
          tok = ""; i++
          while (i <= length(s)) { d = substr(s, i, 1); i++
            if (d == "\\") { i++; continue } if (d == "\"") break; tok = tok d }
          # 값 키인지 확인(뒤에 : 와 숫자)
          j = i; while (j <= length(s) && substr(s, j, 1) ~ /[ \t\r\n]/) j++
          if (substr(s, j, 1) == ":" && depth == 1) {
            j++; while (j <= length(s) && substr(s, j, 1) ~ /[ \t\r\n]/) j++
            num = ""; while (j <= length(s) && substr(s, j, 1) ~ /[-0-9.eE+]/) { num = num substr(s, j, 1); j++ }
            if (num != "") {
              if (tok == "input_cost_per_token") ipt = num
              else if (tok == "output_cost_per_token") opt = num
              else if (tok == "cache_creation_input_token_cost") cw = num
              else if (tok == "cache_read_input_token_cost") cr = num
            }
          }
          continue
        }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") { depth--; if (depth == 0) break }
        i++
      }
      if (ipt == "" || opt == "") { print "MISSING"; next }
      if (cw == "") cw = ipt * 1.25
      if (cr == "") cr = ipt * 0.1
      printf "%s\t%s\t%s\t%s\t%s\n", "'"$m"'", ipt, opt, cw, cr
    }' "$raw")
  case "$row" in
    MISSING|"") ok=0 ;;
    *) printf '%s\n' "$row" >> "$tmp" ;;
  esac
done
rm -f "$raw"

# 4모델 모두 뽑혔을 때만 교체한다(부분 실패 시 기존 캐시 유지).
if [ "$ok" -eq 1 ] && [ "$(wc -l < "$tmp")" -eq 4 ]; then
  mv "$tmp" "$PRICES"
else
  rm -f "$tmp"
fi
