#!/bin/sh
# Persistence restart test for quine-roc.
# Ingests data, stops the container, restarts, and verifies data survived.
#
# Usage: ./tests/e2e/restart-test.sh
# Requires: docker compose, curl
set -e

BASE="http://localhost:8080/api/v1"
COMPOSE="docker compose"
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

wait_healthy() {
    echo "Waiting for quine-roc to be healthy..."
    for i in $(seq 1 30); do
        STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/health" 2>/dev/null || echo "000")
        [ "$STATUS" = "200" ] && return 0
        sleep 1
    done
    echo "FAIL: quine-roc did not become healthy in 30s"
    return 1
}

cleanup() {
    echo "Cleaning up..."
    $COMPOSE down -v 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Phase 1: Start, ingest data, verify ==="

$COMPOSE up -d quine-roc
wait_healthy

# Ingest test data
STATUS=$(curl -so /dev/null -w '%{http_code}' -X POST "$BASE/ingest" \
  -H "Content-Type: application/json" \
  -d '{"name":"restart-test","type":"file","path":"/test-data/test-events.jsonl"}')
assert_status "ingest starts" "201" "$STATUS"

# Wait for ingest completion
for i in $(seq 1 30); do
    INGEST_STATUS=$(curl -s "$BASE/ingest/restart-test" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    [ "$INGEST_STATUS" = "complete" ] && break
    sleep 0.5
done
assert_status "ingest completes" "complete" "$INGEST_STATUS"

# Verify node exists before restart
NODE_STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/nodes/alice")
assert_status "node alice exists before restart" "200" "$NODE_STATUS"

# Capture pre-restart properties for comparison
curl -s "$BASE/nodes/alice" > /tmp/pre-restart.json

echo ""
echo "=== Phase 2: Stop and restart ==="

$COMPOSE stop quine-roc
echo "Container stopped. Restarting..."
$COMPOSE start quine-roc
wait_healthy

echo ""
echo "=== Phase 3: Verify data survived restart ==="

# Query the same node — should still exist with properties
NODE_STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/nodes/alice")
assert_status "node alice exists after restart" "200" "$NODE_STATUS"

# Verify properties are present
curl -s "$BASE/nodes/alice" > /tmp/post-restart.json
HAS_PROPS=$(grep -c '"properties"' /tmp/post-restart.json || true)
assert_status "node alice has properties after restart" "true" "$([ "$HAS_PROPS" -gt 0 ] && echo true || echo false)"

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed out of 5"
[ "$FAIL" -eq 0 ] || exit 1
