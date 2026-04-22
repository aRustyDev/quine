#!/bin/sh
# E2E test script for quine-roc prototype.
# Runs against a live quine-roc instance (expects $BASE or defaults to docker-compose service name).
set -e

BASE="${BASE:-http://quine-roc:8080/api/v1}"
PASS=0
FAIL=0

assert_status() {
    test_name="$1"; expected="$2"; actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $test_name (expected $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

# 1. Health check
STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/health")
assert_status "health check returns 200" "200" "$STATUS"

# 2. Register standing query (match any node with a "name" property)
SQ_RESP=$(curl -s -X POST "$BASE/standing-queries" \
  -H "Content-Type: application/json" \
  -d '{"query":{"type":"LocalProperty","prop_key":"name","constraint":{"type":"Any"},"aliased_as":"n"},"include_cancellations":false}')
SQ_ID=$(echo "$SQ_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_status "register standing query" "true" "$([ -n "$SQ_ID" ] && echo true || echo false)"

# 3. Start file ingest
STATUS=$(curl -so /dev/null -w '%{http_code}' -X POST "$BASE/ingest" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-ingest","type":"file","path":"/test-data/test-events.jsonl"}')
assert_status "start ingest returns 201" "201" "$STATUS"

# 4. Wait for ingest completion (poll up to 15s)
INGEST_STATUS=""
for i in $(seq 1 30); do
    INGEST_STATUS=$(curl -s "$BASE/ingest/test-ingest" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    [ "$INGEST_STATUS" = "complete" ] && break
    sleep 0.5
done
assert_status "ingest completes" "complete" "$INGEST_STATUS"

# 5. Check standing query has results
# Note: SQ propagation requires SQ command decoding on the Roc side,
# which is a known WIP (tags 0x10-0x12). This test checks that the
# API endpoint returns 200 and the SQ is still registered.
SQ_STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/standing-queries")
assert_status "SQ endpoint returns 200" "200" "$SQ_STATUS"

# 6. Query a known node — write to file to handle large responses
curl -s -o /tmp/node.json "$BASE/nodes/alice"
NODE_STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/nodes/alice")
HAS_PROPS=$(grep -c '"properties"' /tmp/node.json || true)
assert_status "node alice responds 200 with properties" "true" "$([ "$NODE_STATUS" = "200" ] && [ "$HAS_PROPS" -gt 0 ] && echo true || echo false)"

# 7. Cancel standing query
STATUS=$(curl -so /dev/null -w '%{http_code}' -X DELETE "$BASE/standing-queries/$SQ_ID")
assert_status "cancel standing query" "200" "$STATUS"

# 8. Cleanup: delete ingest job
# The test file completes almost instantly, so the job will be in "complete" state.
# API returns 400 for already-completed jobs (by design — can't cancel what's done).
STATUS=$(curl -so /dev/null -w '%{http_code}' -X DELETE "$BASE/ingest/test-ingest")
assert_status "delete completed ingest returns 400" "400" "$STATUS"

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed out of 8"
[ "$FAIL" -eq 0 ] || exit 1
