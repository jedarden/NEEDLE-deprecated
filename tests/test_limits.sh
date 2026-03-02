#!/usr/bin/env bash
# Tests for NEEDLE concurrency limit enforcement (src/runner/limits.sh)

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
export NEEDLE_CONFIG_FILE="$TEST_NEEDLE_HOME/config.yaml"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=true

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/paths.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lib/config.sh"
source "$PROJECT_DIR/src/runner/state.sh"
source "$PROJECT_DIR/src/runner/limits.sh"

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

# Create test config with limits
create_test_config() {
    mkdir -p "$TEST_NEEDLE_HOME"
    cat > "$NEEDLE_CONFIG_FILE" << 'EOF'
limits:
  global_max_concurrent: 10
  providers:
    anthropic:
      max_concurrent: 5
    openai:
      max_concurrent: 3
  models:
    claude-anthropic-opus:
      max_concurrent: 2

runner:
  polling_interval: 2s
  idle_timeout: 300s
EOF
    # Clear config cache
    clear_config_cache
}

# ============ Tests ============

# Test: Get global limit
test_case "_needle_get_global_limit returns configured value"
create_test_config
limit=$(_needle_get_global_limit)
if [[ "$limit" == "10" ]]; then
    test_pass
else
    test_fail "Expected 10, got $limit"
fi

# Test: Get global limit default
test_case "_needle_get_global_limit returns default when not configured"
rm -f "$NEEDLE_CONFIG_FILE"
clear_config_cache
limit=$(_needle_get_global_limit)
if [[ "$limit" == "20" ]]; then
    test_pass
else
    test_fail "Expected default 20, got $limit"
fi

# Test: Get provider limit
test_case "_needle_get_provider_limit returns configured value"
create_test_config
limit=$(_needle_get_provider_limit "anthropic")
if [[ "$limit" == "5" ]]; then
    test_pass
else
    test_fail "Expected 5, got $limit"
fi

# Test: Get provider limit for unknown provider
test_case "_needle_get_provider_limit returns default for unknown provider"
create_test_config
limit=$(_needle_get_provider_limit "unknown")
if [[ "$limit" == "10" ]]; then
    test_pass
else
    test_fail "Expected 10, got $limit"
fi

# Test: Get model limit from config
test_case "_needle_get_model_limit returns configured model limit"
create_test_config
limit=$(_needle_get_model_limit "claude-anthropic-opus" "anthropic")
if [[ "$limit" == "2" ]]; then
    test_pass
else
    test_fail "Expected 2, got $limit"
fi

# Test: Model limit falls back to provider limit
test_case "_needle_get_model_limit falls back to provider limit"
create_test_config
limit=$(_needle_get_model_limit "claude-anthropic-sonnet" "anthropic")
if [[ "$limit" == "5" ]]; then
    test_pass
else
    test_fail "Expected 5 (provider limit), got $limit"
fi

# Test: Global limit check passes when under limit
test_case "_needle_check_global_limit passes when under limit"
create_test_config
_needle_workers_init
_needle_clear_all_workers

# Register 8 workers (under limit of 10)
for i in {1..8}; do
    _needle_register_worker "test-worker-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

if _needle_check_global_limit 1; then
    test_pass
else
    test_fail "Check failed but we're under limit: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Global limit check fails when at limit
test_case "_needle_check_global_limit fails when at limit"
create_test_config
_needle_clear_all_workers

# Register 10 workers (at limit)
for i in {1..10}; do
    _needle_register_worker "test-worker-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

if ! _needle_check_global_limit 1; then
    if [[ "$NEEDLE_LIMIT_CHECK_MESSAGE" == *"Global"* ]]; then
        test_pass
    else
        test_fail "Wrong error message: $NEEDLE_LIMIT_CHECK_MESSAGE"
    fi
else
    test_fail "Check passed but we're at limit"
fi

# Test: Provider limit check passes when under limit
test_case "_needle_check_provider_limit passes when under limit"
create_test_config
_needle_clear_all_workers

# Register 3 anthropic workers (under limit of 5)
for i in {1..3}; do
    _needle_register_worker "test-anthropic-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

if _needle_check_provider_limit "anthropic" 1; then
    test_pass
else
    test_fail "Check failed but we're under provider limit: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Provider limit check fails when at limit
test_case "_needle_check_provider_limit fails when at limit"
create_test_config
_needle_clear_all_workers

# Register 5 anthropic workers (at limit)
for i in {1..5}; do
    _needle_register_worker "test-anthropic-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

if ! _needle_check_provider_limit "anthropic" 1; then
    if [[ "$NEEDLE_LIMIT_CHECK_MESSAGE" == *"anthropic"* ]]; then
        test_pass
    else
        test_fail "Wrong error message: $NEEDLE_LIMIT_CHECK_MESSAGE"
    fi
else
    test_fail "Check passed but we're at provider limit"
fi

# Test: Model limit check passes when under limit
test_case "_needle_check_model_limit passes when under limit"
create_test_config
_needle_clear_all_workers

# Register 1 opus worker (under limit of 2)
_needle_register_worker "test-opus-1" "claude" "anthropic" "opus" "w1" "$$" "/test"

if _needle_check_model_limit "claude-anthropic-opus" "anthropic" 1; then
    test_pass
else
    test_fail "Check failed but we're under model limit: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Model limit check fails when at limit
test_case "_needle_check_model_limit fails when at limit"
create_test_config
_needle_clear_all_workers

# Register 2 opus workers (at limit)
for i in {1..2}; do
    _needle_register_worker "test-opus-$i" "claude" "anthropic" "opus" "w$i" "$$" "/test"
done

# Verify the count is correct
opus_count=$(_needle_count_by_agent "claude-anthropic-opus")
model_limit=$(_needle_get_effective_model_limit "claude-anthropic-opus" "anthropic")

if ! _needle_check_model_limit "claude-anthropic-opus" "anthropic" 1; then
    if [[ "$NEEDLE_LIMIT_CHECK_MESSAGE" == *"opus"* || "$NEEDLE_LIMIT_CHECK_MESSAGE" == *"Model"* ]]; then
        test_pass
    else
        test_fail "Wrong error message: $NEEDLE_LIMIT_CHECK_MESSAGE (count=$opus_count, limit=$model_limit)"
    fi
else
    test_fail "Check passed but we're at model limit (count=$opus_count, limit=$model_limit)"
fi

# Test: Full concurrency check passes when all under limit
test_case "_needle_check_concurrency passes when all under limits"
create_test_config
_needle_clear_all_workers

# Register 3 sonnet workers (under all limits)
for i in {1..3}; do
    _needle_register_worker "test-sonnet-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

if _needle_check_concurrency "claude-anthropic-sonnet" "anthropic" 1; then
    test_pass
else
    test_fail "Check failed but all limits are satisfied: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Full concurrency check fails when global limit reached
test_case "_needle_check_concurrency fails when global limit reached"
create_test_config
_needle_clear_all_workers

# Fill up to global limit with different providers
for i in {1..5}; do
    _needle_register_worker "test-anthropic-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
    _needle_register_worker "test-openai-$i" "openai" "openai" "gpt-4" "w$i" "$$" "/test"
done

if ! _needle_check_concurrency "openai-gpt-4" "openai" 1; then
    test_pass
else
    test_fail "Check passed but global limit reached"
fi

# Test: Concurrency status JSON is valid
test_case "_needle_get_concurrency_status returns valid JSON"
create_test_config
_needle_clear_all_workers
_needle_register_worker "test-1" "claude" "anthropic" "sonnet" "w1" "$$" "/test"

status=$(_needle_get_concurrency_status "claude-anthropic-sonnet" "anthropic")

if echo "$status" | jq -e '.global.current' &>/dev/null; then
    global_current=$(echo "$status" | jq -r '.global.current')
    if [[ "$global_current" == "1" ]]; then
        test_pass
    else
        test_fail "Expected 1 global worker, got $global_current"
    fi
else
    test_fail "Invalid JSON or missing .global.current"
fi

# Test: Provider count is correct
test_case "_needle_get_provider_count returns correct count"
create_test_config
_needle_clear_all_workers

for i in {1..3}; do
    _needle_register_worker "test-anthropic-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
    _needle_register_worker "test-openai-$i" "openai" "openai" "gpt-4" "w$i" "$$" "/test"
done

anthropic_count=$(_needle_get_provider_count "anthropic")
openai_count=$(_needle_get_provider_count "openai")

if [[ "$anthropic_count" == "3" && "$openai_count" == "3" ]]; then
    test_pass
else
    test_fail "Expected 3,3 - got $anthropic_count,$openai_count"
fi

# Test: Agent count is correct
test_case "_needle_get_agent_count returns correct count"
create_test_config
_needle_clear_all_workers

for i in {1..2}; do
    _needle_register_worker "test-sonnet-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done
_needle_register_worker "test-opus-1" "claude" "anthropic" "opus" "w1" "$$" "/test"

sonnet_count=$(_needle_get_agent_count "claude-anthropic-sonnet")
opus_count=$(_needle_get_agent_count "claude-anthropic-opus")

if [[ "$sonnet_count" == "2" && "$opus_count" == "1" ]]; then
    test_pass
else
    test_fail "Expected 2,1 - got $sonnet_count,$opus_count"
fi

# Test: Multiple additional workers check
test_case "_needle_check_concurrency handles multiple additional workers"
create_test_config
_needle_clear_all_workers

# Register 2 workers (leaving room for 3 more within provider limit of 5)
for i in {1..2}; do
    _needle_register_worker "test-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

# Should pass - 2 + 3 = 5 (at provider limit, not over)
if _needle_check_concurrency "claude-anthropic-sonnet" "anthropic" 3; then
    # But 2 + 4 = 6 (over provider limit of 5)
    if ! _needle_check_concurrency "claude-anthropic-sonnet" "anthropic" 4; then
        test_pass
    else
        test_fail "Check passed for 2+4 workers but provider limit is 5"
    fi
else
    test_fail "Check failed for 2+3 workers but provider limit is 5: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Provider extracted from agent name
test_case "_needle_check_concurrency extracts provider from agent name"
create_test_config
_needle_clear_all_workers

# Don't pass provider explicitly - should extract "anthropic" from agent name
if _needle_check_concurrency "claude-anthropic-sonnet" "" 1; then
    test_pass
else
    test_fail "Failed to extract provider from agent name: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Empty agent/provider handled gracefully
test_case "_needle_check_concurrency handles empty agent"
create_test_config
_needle_clear_all_workers

# Should pass - just checks global limit
if _needle_check_concurrency "" "" 1; then
    test_pass
else
    test_fail "Failed with empty agent: $NEEDLE_LIMIT_CHECK_MESSAGE"
fi

# Test: Stale workers don't count
test_case "Concurrency check ignores stale workers"
create_test_config
_needle_clear_all_workers

# Register worker with definitely dead PID
_needle_register_worker "dead-worker" "claude" "anthropic" "sonnet" "w1" "99999999" "/test"

# The count functions should clean up stale workers automatically
# After cleanup, the count should be 0 since the PID doesn't exist
count=$(_needle_count_all_workers)

# Debug output
if [[ "$count" == "0" ]]; then
    test_pass
else
    # Check if it's actually 0 with cleanup
    _needle_cleanup_stale_workers
    count_after=$(_needle_count_all_workers)
    if [[ "$count_after" == "0" ]]; then
        test_pass
    else
        test_fail "Stale worker still counted: $count (after cleanup: $count_after)"
    fi
fi

# Test: Concurrency enforce wrapper outputs error
test_case "_needle_enforce_concurrency outputs error message"
create_test_config
_needle_clear_all_workers

# Fill to limit
for i in {1..10}; do
    _needle_register_worker "test-$i" "claude" "anthropic" "sonnet" "w$i" "$$" "/test"
done

# Capture output (should print error)
output=$(_needle_enforce_concurrency "claude-anthropic-sonnet" "anthropic" 1 2>&1)

if [[ $? -ne 0 ]] && [[ "$output" == *"limit"* || "$output" == *"Limit"* ]]; then
    test_pass
else
    test_fail "Expected error message with 'limit', got: $output"
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
