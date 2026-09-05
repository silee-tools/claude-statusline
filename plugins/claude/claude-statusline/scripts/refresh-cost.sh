#!/bin/sh
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
CACHE="$CACHE_DIR/cost-cache.env"
PRICES="$CACHE_DIR/prices.tsv"
LOCK="$CACHE_DIR/cost-refresh.lock"
PROJECTS="$HOME/.claude/projects"
TTL=300           # 5분
LOCK_STALE=120    # 2분

mkdir -p "$CACHE_DIR"

now=$(date +%s)

# 1) TTL: 캐시가 신선하면 종료.
if [ -f "$CACHE" ]; then
  cached_at=$(awk -F= '$1=="cachedAt"{print $2; exit}' "$CACHE" 2>/dev/null || echo 0)
  case "$cached_at" in ''|*[!0-9]*) cached_at=0 ;; esac
  [ $((now - cached_at)) -lt "$TTL" ] && exit 0
fi

# 2) 락(mkdir 원자성). stale 하면 회수하고 한 번 재시도.
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_mtime=$(date -r "$LOCK" +%s 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  if [ $((now - lock_mtime)) -ge "$LOCK_STALE" ]; then
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0   # 다른 프로세스가 갱신 중
  fi
fi
trap 'rm -rf "$LOCK"' EXIT INT TERM

# 3) 락 획득 사이 갱신됐을 수 있으니 재확인.
if [ -f "$CACHE" ]; then
  cached_at=$(awk -F= '$1=="cachedAt"{print $2; exit}' "$CACHE" 2>/dev/null || echo 0)
  case "$cached_at" in ''|*[!0-9]*) cached_at=0 ;; esac
  [ $((now - cached_at)) -lt "$TTL" ] && exit 0
fi

# 4) 단가표 준비(하루 1회 fetch, 폴백 내장).
sh "$PLUGIN_ROOT/scripts/fetch-prices.sh" || true
[ -f "$PRICES" ] || exit 0

# 5) 로컬 일·주(일요일 시작)·월 경계를 UTC ISO 로 계산(BSD/GNU 이중 경로).
iso_utc() { # epoch -> UTC ISO
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}
day_epoch=$(date -v0H -v0M -v0S +%s 2>/dev/null || date -d "today 00:00:00" +%s)
dow=$(date +%w)   # 0=일
week_epoch=$(date -v-"${dow}"d -v0H -v0M -v0S +%s 2>/dev/null || date -d "today -${dow} days 00:00:00" +%s)
month_epoch=$(date -v1d -v0H -v0M -v0S +%s 2>/dev/null || date -d "$(date +%Y-%m-01) 00:00:00" +%s)
DAY=$(iso_utc "$day_epoch"); WEEK=$(iso_utc "$week_epoch"); MONTH=$(iso_utc "$month_epoch")

# 6) 월·주 집계 중 더 이른 경계 이후 갱신된 JSONL 만 대상으로 좁힌다.
ref="$CACHE_DIR/.month-ref"
ref_epoch=$month_epoch
[ "$week_epoch" -lt "$ref_epoch" ] && ref_epoch=$week_epoch
ref_touch=$(date -r "$ref_epoch" +%Y%m%d0000 2>/dev/null || date -d "@$ref_epoch" +%Y%m%d0000)
touch -t "$ref_touch" "$ref" 2>/dev/null || true

# 7) 집계 → cost-cache.env(원자 교체). cachedAt 을 덧붙인다.
tmp="$CACHE.tmp.$$"
if [ -d "$PROJECTS" ]; then
  find "$PROJECTS" -name '*.jsonl' -newer "$ref" -type f 2>/dev/null | tr '\n' '\0' | xargs -0 cat 2>/dev/null \
    | awk -v DAY="$DAY" -v WEEK="$WEEK" -v MONTH="$MONTH" -v PRICES="$PRICES" \
          -f "$PLUGIN_ROOT/scripts/aggregate-cost.awk" > "$tmp" 2>/dev/null || : > "$tmp"
else
  : > "$tmp"
fi
# 집계가 비면(available 줄 없음) 최소한 available=false 를 기록해 statusline 이 $-- 로 표시.
grep -q '^available=' "$tmp" || printf 'available=false\n' > "$tmp"
printf 'cachedAt=%s\n' "$now" >> "$tmp"
mv "$tmp" "$CACHE"
