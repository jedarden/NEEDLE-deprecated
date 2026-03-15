#!/usr/bin/env bash
# Tests for NEEDLE bead verification module (src/bead/verify.sh)
#
# Tests the post-execution verification functionality:
# - Extraction of verification_cmd from metadata and labels
# - Verification execution with retry logic
# - Failure context formatting for re-dispatch
# - Flaky detection and labeling

# Test setup - create temp directory
TEST_DIR=$(mktemp -d)
TEST_NEEDLE_HOME="$TEST_DIR/.needle"
TEST_LOG_FILE="$TEST_DIR/events.jsonl"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false
export NEEDLE_LOG_FILE="$TEST_LOG_FILE"
export NEEDLE_LOG_INITIALIZED=true
export NEEDLE_VERIFY_RETRY_DELAY=0  # No delay in tests

# Set worker identity for telemetry
export NEEDLE_SESSION="test-session-verify"
export NEEDLE_RUNNER="test"
export NEEDLE_PROVIDER="test"
export NEEDLE_MODEL="test"
export NEEDLE_IDENTIFIER="test"

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lib/diagnostic.sh"
source "$PROJECT_DIR/src/telemetry/writer.sh"
source "$PROJECT_DIR/src/telemetry/events.sh"

# Create test workspace
TEST_WORKSPACE="$TEST_DIR/workspace"
mkdir -p "$TEST_WORKSPACE/.beads"

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
    ((TESTS_RUN++))
    echo -n "Testing: $name... "
}

test_pass() {
    echo "PASS"
    ((TESTS_PASSED++))
}

test_fail() {
    local reason="${1:-}"
    echo "FAIL"
    [[ -n "$reason" ]] && echo "  Reason: $reason"
    ((TESTS_FAILED++))
}

# Source verify module
source "$PROJECT_DIR/src/bead/verify.sh"

# ============================================================================
# Tests: _needle_get_verification_cmd (via cache mechanism)
# ============================================================================

test_case "get_verification_cmd extracts from cache (metadata)"
# Set up cache to simulate metadata extraction
export NEEDLE_CLAIMED_BEAD_ID="nd-test1"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="pytest tests/"

result=$(_needle_get_verification_cmd "nd-test1" "$TEST_WORKSPACE")
exit_code=$?

if [[ $exit_code -eq 0 ]] && [[ "$result" == "pytest tests/" ]]; then
    test_pass
else
    test_fail "Expected 'pytest tests/', got '$result' (exit: $exit_code)"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "get_verification_cmd returns 1 for uncached bead_id without br"
# Clear cache
unset NEEDLE_CLAIMED_BEAD_ID
unset NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

# Without a working br and no cache, should return 1
result=$(_needle_get_verification_cmd "nd-uncached" "$TEST_WORKSPACE" 2>/dev/null)
exit_code=$?

if [[ $exit_code -eq 1 ]]; then
    test_pass
else
    test_fail "Expected exit 1 for uncached/unknown bead, got exit $exit_code"
fi

test_case "get_verification_cmd returns 1 for empty bead_id"
result=$(_needle_get_verification_cmd "" "$TEST_WORKSPACE")
exit_code=$?

if [[ $exit_code -eq 1 ]]; then
    test_pass
else
    test_fail "Expected exit 1 for empty bead_id, got exit $exit_code"
fi

test_case "get_verification_cmd empty cache value returns 1"
export NEEDLE_CLAIMED_BEAD_ID="nd-test2"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD=""  # Explicitly empty

result=$(_needle_get_verification_cmd "nd-test2" "$TEST_WORKSPACE")
exit_code=$?

if [[ $exit_code -eq 1 ]]; then
    test_pass
else
    test_fail "Expected exit 1 for empty cached value, got exit $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

# ============================================================================
# Tests: _needle_run_verification
# ============================================================================

test_case "run_verification returns 2 when no verification_cmd (empty cache)"
export NEEDLE_CLAIMED_BEAD_ID="nd-test5"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD=""

result=$(_needle_run_verification "nd-test5" "$TEST_WORKSPACE")
exit_code=$?

if [[ $exit_code -eq 2 ]]; then
    skipped=$(echo "$result" | jq -r '.skipped')
    if [[ "$skipped" == "true" ]]; then
        test_pass
    else
        test_fail "Expected skipped=true, got $(echo "$result" | jq -c .)"
    fi
else
    test_fail "Expected exit 2 (no cmd), got exit $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "run_verification passes when command succeeds"
export NEEDLE_CLAIMED_BEAD_ID="nd-test6"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="true"

result=$(_needle_run_verification "nd-test6" "$TEST_WORKSPACE" --max-retries 1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    passed=$(echo "$result" | jq -r '.passed')
    attempts=$(echo "$result" | jq -r '.attempts')
    if [[ "$passed" == "true" ]] && [[ "$attempts" -eq 1 ]]; then
        test_pass
    else
        test_fail "Expected passed=true, attempts=1, got passed=$passed, attempts=$attempts"
    fi
else
    test_fail "Expected exit 0 (pass), got exit $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "run_verification fails when command fails all retries"
export NEEDLE_CLAIMED_BEAD_ID="nd-test7"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="exit 1"

result=$(_needle_run_verification "nd-test7" "$TEST_WORKSPACE" --max-retries 2)
exit_code=$?

if [[ $exit_code -eq 1 ]]; then
    passed=$(echo "$result" | jq -r '.passed')
    attempts=$(echo "$result" | jq -r '.attempts')
    # max-retries 2 means 2 attempts, but the implementation tracks the last attempt number
    if [[ "$passed" == "false" ]] && [[ "$attempts" -ge 2 ]]; then
        test_pass
    else
        test_fail "Expected passed=false, attempts>=2, got passed=$passed, attempts=$attempts"
    fi
else
    test_fail "Expected exit 1 (fail), got exit $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "run_verification detects flaky when passes after retry"
# Create a command that fails first, then succeeds
flaky_cmd="$TEST_DIR/flaky_cmd.sh"
count_file="$TEST_DIR/flaky_count"
echo 0 > "$count_file"
cat > "$flaky_cmd" << 'CMDEOF'
#!/bin/bash
count_file="$1"
count=$(cat "$count_file")
echo $((count + 1)) > "$count_file"
if [[ $count -lt 1 ]]; then
    exit 1
fi
exit 0
CMDEOF
chmod +x "$flaky_cmd"

export NEEDLE_CLAIMED_BEAD_ID="nd-test8"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="$flaky_cmd $count_file"

echo 0 > "$count_file"
result=$(_needle_run_verification "nd-test8" "$TEST_WORKSPACE" --max-retries 3)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    flaky=$(echo "$result" | jq -r '.flaky')
    attempts=$(echo "$result" | jq -r '.attempts')
    if [[ "$flaky" == "true" ]] && [[ "$attempts" -gt 1 ]]; then
        test_pass
    else
        test_fail "Expected flaky=true with attempts>1, got flaky=$flaky, attempts=$attempts"
    fi
else
    test_fail "Expected exit 0 (pass after retry), got exit $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "run_verification not flaky when passes on first try"
export NEEDLE_CLAIMED_BEAD_ID="nd-test9"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="true"

result=$(_needle_run_verification "nd-test9" "$TEST_WORKSPACE" --max-retries 3)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    flaky=$(echo "$result" | jq -r '.flaky')
    if [[ "$flaky" == "false" ]]; then
        test_pass
    else
        test_fail "Expected flaky=false on first try success"
    fi
else
    test_fail "Expected exit 0, got exit $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

# ============================================================================
# Tests: _needle_format_verification_failure_context
# ============================================================================

test_case "format_failure_context generates proper markdown"
result_json='{"passed":false,"attempts":3,"command":"pytest tests/","output":"FAILED test_foo.py","exit_code":1,"flaky":false}'

context=$(_needle_format_verification_failure_context "$result_json")

if echo "$context" | grep -q "Verification Failed" && \
   echo "$context" | grep -q "pytest tests/" && \
   echo "$context" | grep -q "3 attempt" && \
   echo "$context" | grep -q "FAILED test_foo.py"; then
    test_pass
else
    test_fail "Context missing expected elements"
fi

test_case "format_failure_context includes flaky warning when flaky=true"
result_json='{"passed":false,"attempts":3,"command":"npm test","output":"timeout","exit_code":1,"flaky":true}'

context=$(_needle_format_verification_failure_context "$result_json")

if echo "$context" | grep -qi "flaky"; then
    test_pass
else
    test_fail "Expected flaky warning in context"
fi

test_case "format_failure_context handles empty input"
context=$(_needle_format_verification_failure_context "")

if echo "$context" | grep -q "No details available"; then
    test_pass
else
    test_fail "Expected 'No details available' for empty input"
fi

test_case "format_failure_context handles null output"
result_json='{"passed":false,"attempts":1,"command":"make test","output":null,"exit_code":1,"flaky":false}'

context=$(_needle_format_verification_failure_context "$result_json")

if echo "$context" | grep -q "make test"; then
    test_pass
else
    test_fail "Expected command in context"
fi

# ============================================================================
# Tests: _needle_verify_bead (main entry point)
# ============================================================================

test_case "verify_bead returns 2 when no verification_cmd"
export NEEDLE_CLAIMED_BEAD_ID="nd-test9"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD=""

result=$(_needle_verify_bead "nd-test9" "$TEST_WORKSPACE")
exit_code=$?

if [[ $exit_code -eq 2 ]]; then
    skipped=$(echo "$result" | jq -r '.skipped')
    if [[ "$skipped" == "true" ]]; then
        test_pass
    else
        test_fail "Expected skipped=true"
    fi
else
    test_fail "Expected exit 2, got $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "verify_bead passes when verification succeeds"
export NEEDLE_CLAIMED_BEAD_ID="nd-test10"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="true"

result=$(_needle_verify_bead "nd-test10" "$TEST_WORKSPACE")
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    passed=$(echo "$result" | jq -r '.passed')
    if [[ "$passed" == "true" ]]; then
        test_pass
    else
        test_fail "Expected passed=true"
    fi
else
    test_fail "Expected exit 0, got $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

test_case "verify_bead fails when verification fails"
export NEEDLE_CLAIMED_BEAD_ID="nd-test11"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="exit 1"

result=$(_needle_verify_bead "nd-test11" "$TEST_WORKSPACE" --max-retries 1)
exit_code=$?

if [[ $exit_code -eq 1 ]]; then
    passed=$(echo "$result" | jq -r '.passed')
    if [[ "$passed" == "false" ]]; then
        test_pass
    else
        test_fail "Expected passed=false"
    fi
else
    test_fail "Expected exit 1, got $exit_code"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

# ============================================================================
# Tests: _needle_label_verification_flaky
# ============================================================================

test_case "label_verification_flaky returns 1 for empty bead_id"
result=$(_needle_label_verification_flaky "" "$TEST_WORKSPACE" 2>/dev/null)
exit_code=$?

if [[ $exit_code -eq 1 ]]; then
    test_pass
else
    test_fail "Expected exit 1 for empty bead_id, got $exit_code"
fi

# Note: Full label test requires working br, which we skip here

# ============================================================================
# Tests: CLI interface
# ============================================================================

test_case "CLI --help shows usage"
result=$(NEEDLE_SRC="$PROJECT_DIR/src" bash "$PROJECT_DIR/src/bead/verify.sh" --help 2>&1)

if echo "$result" | grep -q "get-cmd" && echo "$result" | grep -q "run" && echo "$result" | grep -q "verify"; then
    test_pass
else
    test_fail "Expected help output with commands"
fi

test_case "CLI unknown command returns error"
result=$(NEEDLE_SRC="$PROJECT_DIR/src" bash "$PROJECT_DIR/src/bead/verify.sh" unknown-command 2>&1)
exit_code=$?

if [[ $exit_code -ne 0 ]] && echo "$result" | grep -qi "unknown"; then
    test_pass
else
    test_fail "Expected error for unknown command, got exit $exit_code"
fi

test_case "CLI format-failure works"
result_json='{"passed":false,"attempts":1,"command":"test","output":"err","exit_code":1,"flaky":false}'
result=$(NEEDLE_SRC="$PROJECT_DIR/src" bash "$PROJECT_DIR/src/bead/verify.sh" format-failure "$result_json" 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "Verification Failed"; then
    test_pass
else
    test_fail "Expected format-failure to work, got exit $exit_code"
fi

# ============================================================================
# Tests: Result JSON structure
# ============================================================================

test_case "run_verification result JSON has all required fields"
export NEEDLE_CLAIMED_BEAD_ID="nd-json-test"
export NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD="echo test"

result=$(_needle_run_verification "nd-json-test" "$TEST_WORKSPACE" --max-retries 1)

# Check all required fields exist
passed=$(echo "$result" | jq -r '.passed' 2>/dev/null)
attempts=$(echo "$result" | jq -r '.attempts' 2>/dev/null)
command=$(echo "$result" | jq -r '.command' 2>/dev/null)
output=$(echo "$result" | jq -r '.output' 2>/dev/null)
exit_code=$(echo "$result" | jq -r '.exit_code' 2>/dev/null)
flaky=$(echo "$result" | jq -r '.flaky' 2>/dev/null)
skipped=$(echo "$result" | jq -r '.skipped' 2>/dev/null)

if [[ -n "$passed" ]] && [[ -n "$attempts" ]] && [[ -n "$command" ]] && \
   [[ -n "$output" ]] && [[ -n "$exit_code" ]] && [[ -n "$flaky" ]] && [[ -n "$skipped" ]]; then
    test_pass
else
    test_fail "Missing required fields in result JSON"
fi
unset NEEDLE_CLAIMED_BEAD_ID NEEDLE_CLAIMED_BEAD_VERIFICATION_CMD

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================"
echo "Test Summary: verify.sh"
echo "========================================"
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED test(s) failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
