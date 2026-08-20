#!/bin/sh
set -eu
SRC=$(cd "$(dirname "$0")/.." && pwd)
AGG="$SRC/scripts/aggregate-cost.awk"
WORK=$(mktemp -d)
# bash 3.2 는 EXIT 트랩 진입에서 $? 를 0 으로 만든다. completed 플래그가 없으면 set -eu 중단이
# 종료코드 0 으로 보고된다. 정본은 AGENTS.md 의 Testing 절이다.
completed=0
trap 'rc=$?; rm -rf "$WORK"; [ "$completed" = 1 ] || rc=1; exit "$rc"' EXIT

cat > "$WORK/prices.tsv" <<'TSV'
claude-opus-4-8	0.000005	0.000025	0.00000625	0.0000005
claude-sonnet-5	0.000002	0.00001	0.0000025	0.0000002
claude-haiku-4-5	0.000001	0.000005	0.00000125	0.0000001
TSV

cat > "$WORK/in.jsonl" <<'JSON'
{"timestamp":"2026-07-21T01:00:00.000Z","requestId":"r1","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-21T01:00:00.500Z","requestId":"r1","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-20T10:00:00.000Z","requestId":"r2","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-01T10:00:00.000Z","requestId":"r3","message":{"id":"msg_3","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-06-30T10:00:00.000Z","requestId":"r4","message":{"id":"msg_4","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSON

out=$(awk -v DAY=2026-07-20T15:00:00Z -v WEEK=2026-07-18T15:00:00Z -v MONTH=2026-06-30T15:00:00Z \
  -v PRICES="$WORK/prices.tsv" -f "$AGG" < "$WORK/in.jsonl")
echo "$out"
# 기대: dailyOpus=5(중복 1회) weekly=15(opus5+sonnet10) monthly=16(+haiku1, 접두사매칭) m4(6월)제외
echo "$out" | grep -q '^dailyOpus=5' && echo "$out" | grep -q '^weekly=15' \
  && echo "$out" | grep -q '^monthly=16' && echo "$out" | grep -q '^available=true' \
  && echo "cost.test PASS" || { echo "cost.test FAIL"; exit 1; }

# 경계 초(=DAY) 안에서 밀리초/Z 표기 차이로 사전 비교가 흔들리지 않는지 검증한다.
# row A: 경계 초 0.5초 뒤(같은 초) -> daily 에 포함돼야 한다.
# row B: 경계 초 바로 앞날 23:59:59.5 -> daily 에서 제외돼야 한다.
cat > "$WORK/boundary.jsonl" <<'JSON'
{"timestamp":"2026-07-21T00:00:00.500Z","requestId":"r5","message":{"id":"msg_5","model":"claude-sonnet-5","usage":{"input_tokens":500000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"timestamp":"2026-07-20T23:59:59.500Z","requestId":"r6","message":{"id":"msg_6","model":"claude-sonnet-5","usage":{"input_tokens":500000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSON

out2=$(awk -v DAY=2026-07-21T00:00:00Z -v WEEK=2026-07-14T00:00:00Z -v MONTH=2026-06-01T00:00:00Z \
  -v PRICES="$WORK/prices.tsv" -f "$AGG" < "$WORK/boundary.jsonl")
echo "$out2"
# 기대: dailySonnet=1.00 (row A만 포함, row B는 daily 에서 제외)
completed=1
echo "$out2" | grep -q '^dailySonnet=1.00' \
  && echo "cost.test(boundary) PASS" || { echo "cost.test(boundary) FAIL"; exit 1; }
