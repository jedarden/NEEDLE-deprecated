#!/usr/bin/env bash
# Tests for NEEDLE worker state registry (src/runner/state.sh)

# Test setup - create temp directory
TEST_DIR=$(mktemp -d)
TEST_NEEDLE_HOME="$TEST_DIR/.needle"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"
export NEEDLE_WORKERS_FILE="$TEST_NEEDLE_HOME/state/workers.json"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=true

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/paths.sh"
source "$PROJECT_DIR/src/runner/state.sh"

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

# ============ Tests ============

# Test: Initial state - no workers file
test_case "Workers file does not exist initially"
if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
    test_pass
else
    test_fail "Workers file should not exist"
fi

# Test: Init creates workers file
test_case "_needle_workers_init creates workers file"
_needle_workers_init
if [[ -f "$NEEDLE_WORKERS_FILE" ]] && jq empty "$NEEDLE_WORKERS_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Workers file not created or invalid JSON"
fi

# Test: Init creates empty workers array
test_case "Initial workers array is empty"
rm -f "$NEEDLE_WORKERS_FILE"
_needle_workers_init
count=$(jq '.workers | length' "$NEEDLE_WORKERS_FILE")
if [[ "$count" == "0" ]]; then
    test_pass
else
    test_fail "Expected 0 workers, got $count"
fi

# Test: Register a worker
test_case "_needle_register_worker adds worker to registry"
_needle_register_worker \
    "test-session-1" \
    "claude" \
    "anthropic" \
    "sonnet" \
    "alpha" \
    "$$" \
    "/home/coder/test"

if _needle_is_worker_registered "test-session-1"; then
    test_pass
else
    test_fail "Worker not registered"
fi

# Test: Worker has correct fields
test_case "Registered worker has all required fields"
worker=$(_needle_get_worker "test-session-1")
has_session=$(echo "$worker" | jq 'has("session")')
has_runner=$(echo "$worker" | jq 'has("runner")')
has_provider=$(echo "$worker" | jq 'has("provider")')
has_model=$(echo "$worker" | jq 'has("model")')
has_identifier=$(echo "$worker" | jq 'has("identifier")')
has_pid=$(echo "$worker" | jq 'has("pid")')
has_workspace=$(echo "$worker" | jq 'has("workspace")')
has_started=$(echo "$worker" | jq 'has("started")')

if [[ "$has_session" == "true" && "$has_runner" == "true" && \
      "$has_provider" == "true" && "$has_model" == "true" && \
      "$has_identifier" == "true" && "$has_pid" == "true" && \
      "$has_workspace" == "true" && "$has_started" == "true" ]]; then
    test_pass
else
    test_fail "Missing required fields"
fi

# Test: Worker values are correct
test_case "Worker values are stored correctly"
session=$(echo "$worker" | jq -r '.session')
runner=$(echo "$worker" | jq -r '.runner')
provider=$(echo "$worker" | jq -r '.provider')
model=$(echo "$worker" | jq -r '.model')

if [[ "$session" == "test-session-1" && \
      "$runner" == "claude" && \
      "$provider" == "anthropic" && \
      "$model" == "sonnet" ]]; then
    test_pass
else
    test_fail "Values don't match: session=$session, runner=$runner, provider=$provider, model=$model"
fi

# Test: Count all workers
test_case "_needle_count_all_workers returns correct count"
count=$(_needle_count_all_workers)
if [[ "$count" == "1" ]]; then
    test_pass
else
    test_fail "Expected 1 worker, got $count"
fi

# Test: Register second worker
test_case "Register second worker"
_needle_register_worker \
    "test-session-2" \
    "claude" \
    "anthropic" \
    "haiku" \
    "bravo" \
    "$$" \
    "/home/coder/test"

count=$(_needle_count_all_workers)
if [[ "$count" == "2" ]]; then
    test_pass
else
    test_fail "Expected 2 workers, got $count"
fi

# Test: Count by agent
test_case "_needle_count_by_agent counts correctly"
count=$(_needle_count_by_agent "claude-anthropic-sonnet")
if [[ "$count" == "1" ]]; then
    test_pass
else
    test_fail "Expected 1 claude-anthropic-sonnet worker, got $count"
fi

# Test: Count by provider
test_case "_needle_count_by_provider counts correctly"
count=$(_needle_count_by_provider "anthropic")
if [[ "$count" == "2" ]]; then
    test_pass
else
    test_fail "Expected 2 anthropic workers, got $count"
fi

# Test: Unregister worker
test_case "_needle_unregister_worker removes worker"
_needle_unregister_worker "test-session-2"
if ! _needle_is_worker_registered "test-session-2"; then
    count=$(_needle_count_all_workers)
    if [[ "$count" == "1" ]]; then
        test_pass
    else
        test_fail "Worker unregistered but count is $count, expected 1"
    fi
else
    test_fail "Worker still registered"
fi

# Test: Unregister non-existent worker is safe
test_case "Unregister non-existent worker is safe"
_needle_unregister_worker "non-existent-session"
count=$(_needle_count_all_workers)
if [[ "$count" == "1" ]]; then
    test_pass
else
    test_fail "Count changed unexpectedly to $count"
fi

# Test: Get workers with filter
test_case "_needle_get_workers with --runner filter"
# Add more workers
_needle_register_worker "test-session-3" "openai" "openai" "gpt-4" "charlie" "$$" "/home/coder/test"
_needle_register_worker "test-session-4" "claude" "anthropic" "sonnet" "delta" "$$" "/home/coder/test"

claude_workers=$(_needle_get_workers --runner "claude")
claude_count=$(echo "$claude_workers" | jq 'length')
if [[ "$claude_count" == "2" ]]; then
    test_pass
else
    test_fail "Expected 2 claude workers, got $claude_count"
fi

# Test: Get workers with multiple filters
test_case "_needle_get_workers with multiple filters"
sonnet_workers=$(_needle_get_workers --runner "claude" --provider "anthropic" --model "sonnet")
sonnet_count=$(echo "$sonnet_workers" | jq 'length')
if [[ "$sonnet_count" == "2" ]]; then
    test_pass
else
    test_fail "Expected 2 claude-anthropic-sonnet workers, got $sonnet_count"
fi

# Test: Prevent duplicate registration
test_case "Duplicate registration is prevented"
original_count=$(_needle_count_all_workers)
_needle_register_worker \
    "test-session-1" \
    "claude" \
    "anthropic" \
    "sonnet" \
    "alpha" \
    "$$" \
    "/home/coder/test"

new_count=$(_needle_count_all_workers)
if [[ "$original_count" == "$new_count" ]]; then
    test_pass
else
    test_fail "Duplicate was added, count changed from $original_count to $new_count"
fi

# Test: List all workers
test_case "_needle_list_workers returns valid JSON"
list=$(_needle_list_workers)
workers_count=$(echo "$list" | jq '.workers | length')
if [[ "$workers_count" -ge 1 ]]; then
    test_pass
else
    test_fail "Expected at least 1 worker, got $workers_count"
fi

# Test: Clear all workers
test_case "_needle_clear_all_workers removes all workers"
_needle_clear_all_workers
count=$(_needle_count_all_workers)
if [[ "$count" == "0" ]]; then
    test_pass
else
    test_fail "Expected 0 workers after clear, got $count"
fi

# Test: Register with missing arguments fails
test_case "Register with missing arguments fails"
if ! _needle_register_worker "" "claude" "anthropic" "sonnet" "alpha" "$$" "/home/coder/test" 2>/dev/null; then
    test_pass
else
    test_fail "Should fail with empty session"
fi

# Test: Worker timestamp is ISO8601
test_case "Worker timestamp is ISO8601 format"
_needle_register_worker "timestamp-test" "claude" "anthropic" "sonnet" "echo" "$$" "/home/coder/test"
worker=$(_needle_get_worker "timestamp-test")
started=$(echo "$worker" | jq -r '.started')
iso_pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
if [[ "$started" =~ $iso_pattern ]]; then
    test_pass
else
    test_fail "Timestamp not ISO8601: $started"
fi

# Test: PID is numeric
test_case "Worker PID is numeric"
pid=$(echo "$worker" | jq -r '.pid')
if [[ "$pid" =~ ^[0-9]+$ ]]; then
    test_pass
else
    test_fail "PID is not numeric: $pid"
fi

# Test: Stale worker cleanup
test_case "_needle_cleanup_stale_workers removes dead PIDs"
# Register a worker with a definitely dead PID
_dead_pid=99999999
_needle_register_worker \
    "dead-pid-worker" \
    "claude" \
    "anthropic" \
    "sonnet" \
    "foxtrot" \
    "$_dead_pid" \
    "/home/coder/test"

# Verify it was registered
if _needle_is_worker_registered "dead-pid-worker"; then
    # Run cleanup
    _needle_cleanup_stale_workers

    # Check if dead worker was removed
    if ! _needle_is_worker_registered "dead-pid-worker"; then
        test_pass
    else
        test_fail "Dead PID worker was not cleaned up"
    fi
else
    test_fail "Worker with dead PID was not registered"
fi

# Test: Concurrent access safety (basic)
test_case "Concurrent registration is safe"
# Clear and register multiple workers quickly
_needle_clear_all_workers

for i in {1..5}; do
    _needle_register_worker \
        "concurrent-test-$i" \
        "claude" \
        "anthropic" \
        "sonnet" \
        "worker-$i" \
        "$$" \
        "/home/coder/test" &
done
wait

count=$(_needle_count_all_workers)
if [[ "$count" == "5" ]]; then
    test_pass
else
    test_fail "Expected 5 workers, got $count (concurrent registration issue)"
fi

# Test: Get worker returns empty object for non-existent
test_case "_needle_get_worker returns empty object for non-existent"
worker=$(_needle_get_worker "non-existent-session")
if [[ "$worker" == "{}" ]] || [[ -z "$worker" ]]; then
    test_pass
else
    test_fail "Expected empty object, got: $worker"
fi

# ============ Summary ============
echo ""
echo "================================"
echo "Test Summary"
echo "================================"
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi

exit 0
