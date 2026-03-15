#!/usr/bin/env bash
# Tests for the FABRIC dashboard server
# Verifies HTTP endpoints: /ingest, /stream, /api/summary, /health

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDLE_ROOT="$(dirname "$SCRIPT_DIR")"
SERVER_SCRIPT="$NEEDLE_ROOT/src/dashboard/server.py"

TEST_PORT=17842
SERVER_PID=""

pass=0
fail=0

_pass() { echo "PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "FAIL: $1"; fail=$((fail + 1)); }

_start_server() {
    python3 "$SERVER_SCRIPT" --port "$TEST_PORT" 2>/dev/null &
    SERVER_PID=$!
    # Wait for server to be ready (up to 4 seconds)
    local retries=20
    while [[ $retries -gt 0 ]]; do
        if curl -sf --max-time 1 "http://localhost:$TEST_PORT/health" &>/dev/null; then
            return 0
        fi
        sleep 0.2
        retries=$((retries - 1))
    done
    echo "ERROR: Server did not start in time" >&2
    return 1
}

_stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

trap '_stop_server' EXIT

echo "=== FABRIC Dashboard Server Tests ==="
echo ""

# Verify Python and server script are present
if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not available"
    exit 0
fi

if [[ ! -f "$SERVER_SCRIPT" ]]; then
    echo "FAIL: Server script not found: $SERVER_SCRIPT"
    exit 1
fi

# Start server
echo "Starting test server on port $TEST_PORT..."
if ! _start_server; then
    echo "FAIL: Could not start server"
    exit 1
fi
echo "Server started (PID: $SERVER_PID)"
echo ""

# Test 1: /health endpoint
echo "Test 1: GET /health"
health=$(curl -sf --max-time 5 "http://localhost:$TEST_PORT/health" 2>/dev/null || echo "")
if echo "$health" | grep -q '"status"'; then
    _pass "Health endpoint returns status"
else
    _fail "Health endpoint did not return status (got: $health)"
fi
echo ""

# Test 2: GET / returns dashboard HTML
echo "Test 2: GET / returns dashboard HTML"
html=$(curl -sf --max-time 5 "http://localhost:$TEST_PORT/" 2>/dev/null || echo "")
if echo "$html" | grep -q "FABRIC Dashboard"; then
    _pass "Root endpoint serves dashboard HTML"
else
    _fail "Root endpoint did not return dashboard HTML"
fi
echo ""

# Test 3: GET /api/summary returns JSON
echo "Test 3: GET /api/summary returns JSON"
summary=$(curl -sf --max-time 5 "http://localhost:$TEST_PORT/api/summary" 2>/dev/null || echo "")
if echo "$summary" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'events_total' in d" 2>/dev/null; then
    _pass "Summary endpoint returns valid JSON with expected keys"
else
    _fail "Summary endpoint failed (got: $summary)"
fi
echo ""

# Test 4: POST /ingest accepts an event
echo "Test 4: POST /ingest accepts event"
ingest_result=$(curl -sf --max-time 5 -X POST "http://localhost:$TEST_PORT/ingest" \
    -H "Content-Type: application/json" \
    -d '{"type":"bead.claimed","ts":"2026-03-15T12:00:00.000Z","event":"bead.claimed","session":"test-session","worker":"test-worker","data":{"bead_id":"nd-test"}}' \
    2>/dev/null || echo "")
if echo "$ingest_result" | grep -q '"ok"'; then
    _pass "Ingest endpoint accepts event"
else
    _fail "Ingest endpoint rejected event (got: $ingest_result)"
fi
echo ""

# Test 5: POST /ingest invalid JSON returns 400
echo "Test 5: POST /ingest rejects invalid JSON"
bad_result=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -X POST "http://localhost:$TEST_PORT/ingest" \
    -H "Content-Type: application/json" \
    -d 'not-json' 2>/dev/null || echo "000")
if [[ "$bad_result" == "400" ]]; then
    _pass "Ingest endpoint returns 400 for invalid JSON"
else
    _fail "Ingest endpoint should return 400 for invalid JSON (got: $bad_result)"
fi
echo ""

# Test 6: Event appears in /api/summary after ingest
echo "Test 6: Ingested event appears in summary"
curl -sf --max-time 5 -X POST "http://localhost:$TEST_PORT/ingest" \
    -H "Content-Type: application/json" \
    -d '{"type":"result","ts":"2026-03-15T12:00:01.000Z","worker":"test-worker","data":{"usage":{"input_tokens":100,"output_tokens":50},"cost":0.005}}' \
    &>/dev/null || true
summary2=$(curl -sf --max-time 5 "http://localhost:$TEST_PORT/api/summary" 2>/dev/null || echo "")
if echo "$summary2" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['events_total'] >= 2" 2>/dev/null; then
    _pass "Summary reflects ingested events"
else
    _fail "Summary did not reflect ingested events (got: $summary2)"
fi
echo ""

# Test 7: GET /api/events returns event list
echo "Test 7: GET /api/events returns events"
events_result=$(curl -sf --max-time 5 "http://localhost:$TEST_PORT/api/events" 2>/dev/null || echo "")
if echo "$events_result" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'events' in d and isinstance(d['events'], list)" 2>/dev/null; then
    _pass "Events endpoint returns list"
else
    _fail "Events endpoint failed (got: $events_result)"
fi
echo ""

# Test 8: Unknown route returns 404
echo "Test 8: Unknown route returns 404"
not_found=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://localhost:$TEST_PORT/nonexistent" 2>/dev/null || echo "000")
if [[ "$not_found" == "404" ]]; then
    _pass "Unknown route returns 404"
else
    _fail "Unknown route should return 404 (got: $not_found)"
fi
echo ""

# Test 9: SSE /stream endpoint sends initial connection event
# -N disables curl's output buffering so we get data as it arrives
echo "Test 9: GET /stream sends SSE data"
sse_output=$(timeout 2 curl -sfN --max-time 3 "http://localhost:$TEST_PORT/stream" 2>/dev/null || true)
if echo "$sse_output" | grep -q "^data:"; then
    _pass "SSE stream sends data: lines"
else
    _fail "SSE stream did not send expected data (got: ${sse_output:0:100})"
fi
echo ""

# Summary
echo "=== Results: $pass passed, $fail failed ==="
if [[ $fail -gt 0 ]]; then
    exit 1
fi
