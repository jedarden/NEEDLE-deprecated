#!/usr/bin/env bash
# Test script for watchdog/heartbeat.sh module

# Don't use set -e because arithmetic ((++)) can return 1 and trigger exit

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source required libraries
source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/paths.sh"
source "$PROJECT_ROOT/src/lib/json.sh"
source "$PROJECT_ROOT/src/lib/utils.sh"

# Set up test environment
NEEDLE_HOME="$HOME/.needle-test-$$"
NEEDLE_SESSION="test-worker-$$"
NEEDLE_WORKSPACE="/tmp/test-workspace"
NEEDLE_AGENT="test-agent"
NEEDLE_VERBOSE=true

# Source the heartbeat module
source "$PROJECT_ROOT/src/watchdog/heartbeat.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
_test_start() {
    echo "TEST: $1"
}

_test_pass() {
    echo "  ✓ PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_test_fail() {
    echo "  ✗ FAIL: $1"
    [[ -n "$2" ]] && echo "    Details: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Cleanup function
cleanup() {
    rm -rf "$NEEDLE_HOME"
}
trap cleanup EXIT

# Run tests
echo "=========================================="
echo "Running heartbeat.sh tests"
echo "=========================================="

# Test 1: Heartbeat initialization
_test_start "Heartbeat initialization"
_needle_heartbeat_init
if [[ -f "$NEEDLE_HEARTBEAT_FILE" ]]; then
    _test_pass "Heartbeat file created"
else
    _test_fail "Heartbeat file not created" "$NEEDLE_HEARTBEAT_FILE"
fi

# Test 2: Valid JSON format
_test_start "Valid JSON format"
if jq empty "$NEEDLE_HEARTBEAT_FILE" 2>/dev/null; then
    _test_pass "Heartbeat file contains valid JSON"
else
    _test_fail "Heartbeat file contains invalid JSON"
fi

# Test 3: Required fields present
_test_start "Required fields present"
has_worker=$(jq 'has("worker")' "$NEEDLE_HEARTBEAT_FILE")
has_pid=$(jq 'has("pid")' "$NEEDLE_HEARTBEAT_FILE")
has_started=$(jq 'has("started")' "$NEEDLE_HEARTBEAT_FILE")
has_last_heartbeat=$(jq 'has("last_heartbeat")' "$NEEDLE_HEARTBEAT_FILE")
has_status=$(jq 'has("status")' "$NEEDLE_HEARTBEAT_FILE")
has_current_bead=$(jq 'has("current_bead")' "$NEEDLE_HEARTBEAT_FILE")
has_bead_started=$(jq 'has("bead_started")' "$NEEDLE_HEARTBEAT_FILE")
has_strand=$(jq 'has("strand")' "$NEEDLE_HEARTBEAT_FILE")
has_workspace=$(jq 'has("workspace")' "$NEEDLE_HEARTBEAT_FILE")
has_agent=$(jq 'has("agent")' "$NEEDLE_HEARTBEAT_FILE")

if [[ "$has_worker" == "true" && "$has_pid" == "true" && "$has_status" == "true" && "$has_last_heartbeat" == "true" ]]; then
    _test_pass "All required fields present"
else
    _test_fail "Missing required fields"
fi

# Test 4: Initial status is "starting"
_test_start "Initial status is 'starting'"
status=$(jq -r '.status' "$NEEDLE_HEARTBEAT_FILE")
if [[ "$status" == "starting" ]]; then
    _test_pass "Initial status correct"
else
    _test_fail "Initial status incorrect" "expected 'starting', got '$status'"
fi

# Test 5: Start bead updates status
_test_start "Start bead updates status to 'executing'"
_needle_heartbeat_start_bead "test-bead-123" "1"
status=$(jq -r '.status' "$NEEDLE_HEARTBEAT_FILE")
current_bead=$(jq -r '.current_bead' "$NEEDLE_HEARTBEAT_FILE")
strand=$(jq -r '.strand' "$NEEDLE_HEARTBEAT_FILE")

if [[ "$status" == "executing" && "$current_bead" == "test-bead-123" && "$strand" == "1" ]]; then
    _test_pass "Bead start updates correctly"
else
    _test_fail "Bead start failed" "status=$status, bead=$current_bead, strand=$strand"
fi

# Test 6: End bead returns to idle
_test_start "End bead returns to 'idle'"
_needle_heartbeat_end_bead
status=$(jq -r '.status' "$NEEDLE_HEARTBEAT_FILE")
current_bead=$(jq -r '.current_bead' "$NEEDLE_HEARTBEAT_FILE")

if [[ "$status" == "idle" && "$current_bead" == "null" ]]; then
    _test_pass "Bead end returns to idle"
else
    _test_fail "Bead end failed" "status=$status, current_bead=$current_bead"
fi

# Test 7: Draining status
_test_start "Draining status"
_needle_heartbeat_draining
status=$(jq -r '.status' "$NEEDLE_HEARTBEAT_FILE")
if [[ "$status" == "draining" ]]; then
    _test_pass "Draining status correct"
else
    _test_fail "Draining status incorrect" "expected 'draining', got '$status'"
fi

# Test 8: Cleanup removes file
_test_start "Cleanup removes heartbeat file"
_needle_heartbeat_cleanup
if [[ ! -f "$NEEDLE_HEARTBEAT_FILE" ]]; then
    _test_pass "Heartbeat file removed on cleanup"
else
    _test_fail "Heartbeat file not removed"
fi

# Test 9: Is initialized check
_test_start "Is initialized check works"
if ! _needle_heartbeat_is_initialized; then
    _test_pass "Is initialized returns false after cleanup"
else
    _test_fail "Is initialized should return false"
fi

# Test 10: Re-initialization
_test_start "Re-initialization works"
_needle_heartbeat_init
if _needle_heartbeat_is_initialized; then
    _test_pass "Re-initialization successful"
else
    _test_fail "Re-initialization failed"
fi

# Test 11: Keepalive preserves state
_test_start "Keepalive preserves state"
_needle_heartbeat_start_bead "keepalive-test" "5"
sleep 0.1
_needle_heartbeat_keepalive
status=$(jq -r '.status' "$NEEDLE_HEARTBEAT_FILE")
current_bead=$(jq -r '.current_bead' "$NEEDLE_HEARTBEAT_FILE")
strand=$(jq -r '.strand' "$NEEDLE_HEARTBEAT_FILE")

if [[ "$status" == "executing" && "$current_bead" == "keepalive-test" && "$strand" == "5" ]]; then
    _test_pass "Keepalive preserves state"
else
    _test_fail "Keepalive lost state" "status=$status, bead=$current_bead, strand=$strand"
fi

# Test 12: PID is numeric
_test_start "PID is numeric"
pid=$(jq -r '.pid' "$NEEDLE_HEARTBEAT_FILE")
if [[ "$pid" =~ ^[0-9]+$ ]]; then
    _test_pass "PID is numeric: $pid"
else
    _test_fail "PID is not numeric" "$pid"
fi

# Test 13: Timestamps are ISO8601 format
_test_start "Timestamps are ISO8601 format"
started=$(jq -r '.started' "$NEEDLE_HEARTBEAT_FILE")
last_heartbeat=$(jq -r '.last_heartbeat' "$NEEDLE_HEARTBEAT_FILE")

iso_pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
if [[ "$started" =~ $iso_pattern && "$last_heartbeat" =~ $iso_pattern ]]; then
    _test_pass "Timestamps are ISO8601 format"
else
    _test_fail "Invalid timestamp format" "started=$started, last=$last_heartbeat"
fi

# Final cleanup
_needle_heartbeat_cleanup

# Summary
echo ""
echo "=========================================="
echo "Test Results"
echo "=========================================="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
