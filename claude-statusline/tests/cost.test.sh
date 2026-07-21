#!/bin/sh
set -eu
SRC=$(cd "$(dirname "$0")/.." && pwd)
AGG="$SRC/scripts/aggregate-cost.awk"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/prices.tsv" <<'TSV'
claude-opus-4-8	0.000005	0.000025	0.00000625	0.0000005
claude-sonnet-5	0.000002	0.00001	0.0000025	0.0000002
claude-haiku-4-5	0.000001	0.000005	0.00000125	0.0000001
TSV

cat > "$WORK/in.jsonl" <<'JSON'
{"timestamp":"2026-07-21T01:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-21T01:00:00.500Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-20T10:00:00.000Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-01T10:00:00.000Z","requestId":"r3","message":{"id":"m3","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-06-30T10:00:00.000Z","requestId":"r4","message":{"id":"m4","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSON

out=$(awk -v DAY=2026-07-20T15:00:00Z -v WEEK=2026-07-18T15:00:00Z -v MONTH=2026-06-30T15:00:00Z \
  -v PRICES="$WORK/prices.tsv" -f "$AGG" < "$WORK/in.jsonl")
echo "$out"
# 기대: dailyOpus=5(중복 1회) weekly=15(opus5+sonnet10) monthly=16(+haiku1, 접두사매칭) m4(6월)제외
echo "$out" | grep -q '^dailyOpus=5' && echo "$out" | grep -q '^weekly=15' \
  && echo "$out" | grep -q '^monthly=16' && echo "$out" | grep -q '^available=true' \
  && echo "cost.test PASS" || { echo "cost.test FAIL"; exit 1; }
