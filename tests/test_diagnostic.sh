#!/usr/bin/env bash
# Tests for NEEDLE diagnostic logging module (src/lib/diagnostic.sh)

set -euo pipefail

# Test setup - create temp directory
TEST_DIR=$(mktemp -d)
TEST_NEEDLE_HOME="$TEST_DIR/.needle"
TEST_DIAG_FILE="$TEST_DIR/diagnostic.jsonl"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment BEFORE sourcing modules
export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false
export NEEDLE_DIAGNOSTIC_ENABLED=true
export NEEDLE_DIAGNOSTIC_FILE="$TEST_DIAG_FILE"

# Set worker identity for telemetry
export NEEDLE_SESSION="test-diagnostic-session"
export NEEDLE_RUNNER="test"
export NEEDLE_PROVIDER="test"
export NEEDLE_MODEL="test"
export NEEDLE_IDENTIFIER="test"

# Source required modules
source "$PROJECT_DIR/src/lib/output.sh"

# Re-export after sourcing to ensure test values are used
export NEEDLE_DIAGNOSTIC_ENABLED=true
export NEEDLE_DIAGNOSTIC_FILE="$TEST_DIAG_FILE"
export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"

source "$PROJECT_DIR/src/lib/diagnostic.sh"

# Re-export again after sourcing diagnostic.sh
export NEEDLE_DIAGNOSTIC_ENABLED=true
export NEEDLE_DIAGNOSTIC_FILE="$TEST_DIAG_FILE"

# Cleanup function
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper
test_case() {
    local name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing: $name... "
}

test_pass() {
    echo "PASS"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local reason="${1:-}"
    echo "FAIL"
    [[ -n "$reason" ]] && echo "  Reason: $reason"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "=== NEEDLE Diagnostic Logging Tests ==="
echo ""

# ============================================================================
# Test Diagnostic Initialization
# ============================================================================

test_case "Diagnostic init creates directory"
if _needle_diagnostic_init && [[ -d "$NEEDLE_DIAGNOSTIC_DIR" ]]; then
    test_pass
else
    test_fail "Directory not created"
fi

test_case "Diagnostic init creates file"
if [[ -f "$TEST_DIAG_FILE" ]]; then
    test_pass
else
    test_fail "File not created"
fi

test_case "Diagnostic init with custom file"
CUSTOM_FILE="$TEST_DIR/custom.jsonl"
NEEDLE_DIAGNOSTIC_FILE="$CUSTOM_FILE"
_needle_diagnostic_init
if [[ -f "$CUSTOM_FILE" ]]; then
    test_pass
else
    test_fail "Custom file not created"
fi
NEEDLE_DIAGNOSTIC_FILE="$TEST_DIAG_FILE"

# ============================================================================
# Test Core Diagnostic Functions
# ============================================================================

test_case "_needle_diagnostic logs to file when enabled"
> "$TEST_DIAG_FILE"  # Clear file
_needle_diagnostic "test_category" "Test message" "key1=value1"
if [[ -s "$TEST_DIAG_FILE" ]] && grep -q "test_category" "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Log entry not written"
fi

test_case "_needle_diagnostic includes all context"
> "$TEST_DIAG_FILE"
_needle_diagnostic "ctx_test" "Context test" "foo=bar" "baz=qux"
if grep -q '"foo":"bar"' "$TEST_DIAG_FILE" && grep -q '"baz":"qux"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Context not included in log"
fi

test_case "_needle_diagnostic includes session"
> "$TEST_DIAG_FILE"
_needle_diagnostic "session_test" "Session test"
if grep -q "test-diagnostic-session" "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Session not included"
fi

test_case "_needle_diagnostic produces valid JSON"
> "$TEST_DIAG_FILE"
_needle_diagnostic "json_test" "JSON test" "key=value"
if jq -e '.' "$TEST_DIAG_FILE" > /dev/null 2>&1; then
    test_pass
else
    test_fail "Invalid JSON output"
fi

# ============================================================================
# Test Category-Specific Helpers
# ============================================================================

test_case "_needle_diag_engine logs with engine category"
> "$TEST_DIAG_FILE"
_needle_diag_engine "Engine test" "detail=info"
if grep -q '"category":"engine"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Engine category not set"
fi

test_case "_needle_diag_strand logs with strand category"
> "$TEST_DIAG_FILE"
_needle_diag_strand "pluck" "Strand test"
if grep -q '"category":"strand:pluck"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Strand category not set"
fi

test_case "_needle_diag_claim logs with claim category"
> "$TEST_DIAG_FILE"
_needle_diag_claim "Claim test"
if grep -q '"category":"claim"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Claim category not set"
fi

test_case "_needle_diag_select logs with select category"
> "$TEST_DIAG_FILE"
_needle_diag_select "Select test"
if grep -q '"category":"select"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Select category not set"
fi

test_case "_needle_diag_config logs with config category"
> "$TEST_DIAG_FILE"
_needle_diag_config "Config test"
if grep -q '"category":"config"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Config category not set"
fi

test_case "_needle_diag_workspace logs with workspace category"
> "$TEST_DIAG_FILE"
_needle_diag_workspace "Workspace test"
if grep -q '"category":"workspace"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Workspace category not set"
fi

# ============================================================================
# Test Starvation Detection Helpers
# ============================================================================

test_case "_needle_diag_starvation logs starvation warning"
> "$TEST_DIAG_FILE"
_needle_diag_starvation "test_reason" "detail=value"
if grep -q '"category":"starvation"' "$TEST_DIAG_FILE" && grep -q "test_reason" "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Starvation not logged correctly"
fi

test_case "_needle_diag_no_work logs no work found"
> "$TEST_DIAG_FILE"
_needle_diag_no_work "7" "strand=pluck"
if grep -q '"category":"no_work"' "$TEST_DIAG_FILE" && grep -q '"strands_checked":"7"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "No work not logged correctly"
fi

test_case "_needle_diag_br_call logs br CLI call"
> "$TEST_DIAG_FILE"
_needle_diag_br_call "br ready" "0" "success output"
if grep -q '"category":"br_call"' "$TEST_DIAG_FILE" && grep -q '"command":"br ready"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "BR call not logged correctly"
fi

# ============================================================================
# Test State Dump Functions
# ============================================================================

test_case "_needle_diagnostic_dump_state produces valid JSON"
state=$(_needle_diagnostic_dump_state)
if echo "$state" | jq -e '.' > /dev/null 2>&1; then
    test_pass
else
    test_fail "State dump is not valid JSON"
fi

test_case "_needle_diagnostic_dump_state includes session"
state=$(_needle_diagnostic_dump_state)
if echo "$state" | jq -e '.session == "test-diagnostic-session"' > /dev/null 2>&1; then
    test_pass
else
    test_fail "Session not in state dump"
fi

test_case "_needle_diagnostic_snapshot logs snapshot"
> "$TEST_DIAG_FILE"
_needle_diagnostic_snapshot "test_event" "extra=data"
if grep -q '"category":"snapshot"' "$TEST_DIAG_FILE" && grep -q "test_event" "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Snapshot not logged correctly"
fi

# ============================================================================
# Test Statistics Functions
# ============================================================================

test_case "_needle_diagnostic_stats returns valid JSON"
> "$TEST_DIAG_FILE"
for i in {1..5}; do
    _needle_diagnostic "test" "message $i"
done
stats=$(_needle_diagnostic_stats)
if echo "$stats" | jq -e '.entries == 5' > /dev/null 2>&1; then
    test_pass
else
    test_fail "Stats incorrect: $stats"
fi

test_case "_needle_diagnostic_clear clears log"
> "$TEST_DIAG_FILE"
_needle_diagnostic "test" "message"
_needle_diagnostic_clear
if [[ ! -s "$TEST_DIAG_FILE" ]]; then
    test_pass
else
    test_fail "Log not cleared"
fi

# ============================================================================
# Test Disabled Diagnostic
# ============================================================================

test_case "Diagnostic disabled - no logging"
NEEDLE_DIAGNOSTIC_ENABLED=false
> "$TEST_DIAG_FILE"
_needle_diagnostic "test" "should not log"
if [[ ! -s "$TEST_DIAG_FILE" ]]; then
    test_pass
else
    test_fail "Logged when disabled"
fi
NEEDLE_DIAGNOSTIC_ENABLED=true

# ============================================================================
# Test Verbose Mode
# ============================================================================

test_case "Verbose mode logs to stderr"
NEEDLE_VERBOSE=true
output=$(_needle_diagnostic "test" "verbose message" "key=value" 2>&1)
if [[ "$output" == *"[DIAG:test]"* ]]; then
    test_pass
else
    test_fail "Verbose output missing: $output"
fi
NEEDLE_VERBOSE=false

# ============================================================================
# Test Edge Cases
# ============================================================================

test_case "Handles empty message"
> "$TEST_DIAG_FILE"
_needle_diagnostic "test" "" "key=value"
if [[ -s "$TEST_DIAG_FILE" ]]; then
    test_pass
else
    test_fail "Failed with empty message"
fi

test_case "Handles special characters in values"
> "$TEST_DIAG_FILE"
_needle_diagnostic "test" "Special chars" "key=hello\"world"
if [[ -s "$TEST_DIAG_FILE" ]] && jq -e '.' "$TEST_DIAG_FILE" > /dev/null 2>&1; then
    test_pass
else
    test_fail "Failed with special characters"
fi

test_case "Handles long messages"
> "$TEST_DIAG_FILE"
long_msg=$(printf 'A%.0s' {1..500})
_needle_diagnostic "test" "$long_msg"
if [[ -s "$TEST_DIAG_FILE" ]]; then
    test_pass
else
    test_fail "Failed with long message"
fi

test_case "Handles many key-value pairs"
> "$TEST_DIAG_FILE"
_needle_diagnostic "test" "Many pairs" \
    "key1=val1" "key2=val2" "key3=val3" "key4=val4" "key5=val5"
if grep -q '"key1":"val1"' "$TEST_DIAG_FILE" && grep -q '"key5":"val5"' "$TEST_DIAG_FILE"; then
    test_pass
else
    test_fail "Failed with many pairs"
fi

# ============================================================================
# Test Performance
# ============================================================================

test_case "100 diagnostic logs complete in <5 seconds"
> "$TEST_DIAG_FILE"
start_s=$(date +%s)
for i in {1..100}; do
    _needle_diagnostic "perf" "Message $i" "iteration=$i"
done
end_s=$(date +%s)
elapsed=$((end_s - start_s))

if [[ $elapsed -lt 5 ]]; then
    test_pass "(${elapsed}s for 100 logs)"
else
    test_fail "100 logs took ${elapsed}s (expected <5s)"
fi

# ============================================================================
# Print Summary
# ============================================================================

echo ""
echo "=== Test Summary ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo "All tests passed!"
    exit 0
else
    echo ""
    echo "Some tests failed!"
    exit 1
fi
