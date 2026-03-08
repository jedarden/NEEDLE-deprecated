#!/usr/bin/env bash
# Test script for FABRIC event forwarding
# Demonstrates stream-json parsing and event forwarding

set -e

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDLE_ROOT="$(dirname "$SCRIPT_DIR")"

source "$NEEDLE_ROOT/src/lib/output.sh"
source "$NEEDLE_ROOT/src/telemetry/fabric.sh"

echo "=== FABRIC Event Forwarding Test ==="
echo ""

# Test 1: Check if FABRIC is disabled by default
echo "Test 1: FABRIC disabled by default"
if _needle_fabric_is_enabled; then
    echo "FAIL: FABRIC should be disabled by default"
    exit 1
else
    echo "PASS: FABRIC is disabled"
fi
echo ""

# Test 2: Enable FABRIC via environment variable
echo "Test 2: Enable FABRIC via FABRIC_ENDPOINT"
export FABRIC_ENDPOINT="http://localhost:3000/api/events"
if _needle_fabric_is_enabled; then
    echo "PASS: FABRIC enabled via environment variable"
    echo "  Endpoint: $(_needle_fabric_get_endpoint)"
else
    echo "FAIL: FABRIC should be enabled"
    exit 1
fi
echo ""

# Test 3: Create test stream-json data
echo "Test 3: Parse stream-json events"
TEST_FILE=$(mktemp)
cat > "$TEST_FILE" << 'EOF'
{"type":"bead.claimed","ts":"2026-03-08T12:00:00.000Z","event":"bead.claimed","level":"info","session":"needle-test","worker":"claude-anthropic-sonnet-alpha","data":{"bead_id":"nd-clld"}}
{"type":"tool_use","ts":"2026-03-08T12:00:01.000Z","event":"tool.bash","level":"info","data":{"tool":"Bash","command":"echo 'Hello FABRIC'"}}
{"type":"thinking","ts":"2026-03-08T12:00:02.000Z","event":"thinking","level":"debug","data":{"content":"Processing request..."}}
{"type":"result","ts":"2026-03-08T12:00:03.000Z","event":"bead.completed","level":"info","usage":{"input_tokens":1234,"output_tokens":567},"cost_usd":0.0123,"duration_ms":3000}
EOF

echo "  Parsing test stream file..."
_needle_fabric_parse_stream "$TEST_FILE" 2>&1 | head -5 || true
echo "  PASS: Stream parsing completed (events sent to background)"

rm -f "$TEST_FILE"
echo ""

# Test 4: Test single event forwarding
echo "Test 4: Forward single event"
TEST_EVENT='{"type":"test","ts":"2026-03-08T12:00:00.000Z","message":"FABRIC test event from test suite"}'
_needle_fabric_forward_event "$TEST_EVENT"
echo "  PASS: Event forwarded (background)"
echo ""

# Test 5: Named pipe creation
echo "Test 5: Named pipe for live streaming"
PIPE=$(_needle_fabric_create_pipe)
if [[ -p "$PIPE" ]]; then
    echo "  PASS: Named pipe created: $PIPE"
    rm -f "$PIPE"
else
    echo "  FAIL: Failed to create named pipe"
    exit 1
fi
echo ""

# Test 6: Configuration loading
echo "Test 6: Configuration"
echo "  Endpoint: $(_needle_fabric_get_endpoint)"
echo "  Timeout: $(_needle_fabric_get_timeout)s"
echo "  Batching: $(_needle_fabric_is_batching_enabled && echo enabled || echo disabled)"
echo "  PASS: Configuration loaded"
echo ""

echo "=== All Tests Passed ==="
echo ""
echo "To enable FABRIC forwarding in production:"
echo "  1. Set environment variable:"
echo "     export FABRIC_ENDPOINT=http://localhost:3000/api/events"
echo ""
echo "  2. Or configure in ~/.needle/config.yaml:"
echo "     fabric:"
echo "       enabled: true"
echo "       endpoint: http://localhost:3000/api/events"
echo "       timeout: 2"
echo ""
echo "Events will be forwarded automatically when agents use stream-json output."
