#!/usr/bin/env bash
# Tests for NEEDLE rate limiting (src/runner/rate_limit.sh)

# Test setup - create temp directory
TEST_DIR=$(mktemp -d)
TEST_NEEDLE_HOME="$TEST_DIR/.needle"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"
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
source "$PROJECT_DIR/src/runner/rate_limit.sh"

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

# Create test config with rate limits
create_test_config() {
    mkdir -p "$TEST_NEEDLE_HOME"
    cat > "$NEEDLE_CONFIG_FILE" << 'EOF'
limits:
  global_max_concurrent: 10
  providers:
    anthropic:
      max_concurrent: 5
      requests_per_minute: 10
    openai:
      max_concurrent: 3
      requests_per_minute: 5
    unlimited:
      max_concurrent: 1
EOF
    # Clear config cache
    clear_config_cache
}

# ============ Tests ============

# Test: Get rate limit from config
test_case "_needle_get_rate_limit returns configured value"
create_test_config
limit=$(_needle_get_rate_limit "anthropic")
if [[ "$limit" == "10" ]]; then
    test_pass
else
    test_fail "Expected 10, got $limit"
fi

# Test: Get rate limit for provider without explicit limit
test_case "_needle_get_rate_limit returns default for unconfigured provider"
create_test_config
limit=$(_needle_get_rate_limit "unlimited")
if [[ "$limit" == "60" ]]; then
    test_pass
else
    test_fail "Expected default 60, got $limit"
fi

# Test: Get rate limit for unknown provider
test_case "_needle_get_rate_limit returns default for unknown provider"
create_test_config
limit=$(_needle_get_rate_limit "unknown-provider")
if [[ "$limit" == "60" ]]; then
    test_pass
else
    test_fail "Expected 60, got $limit"
fi

# Test: Get request count when no requests recorded
test_case "_needle_get_request_count returns 0 when no requests"
create_test_config
_needle_clear_rate_limits "anthropic"
count=$(_needle_get_request_count "anthropic")
if [[ "$count" == "0" ]]; then
    test_pass
else
    test_fail "Expected 0, got $count"
fi

# Test: Record a request
test_case "_needle_record_request creates state file"
create_test_config
_needle_clear_rate_limits "anthropic"
_needle_record_request "anthropic"

state_file="$NEEDLE_RATE_LIMITS_DIR/anthropic.json"
if [[ -f "$state_file" ]]; then
    count=$(jq '.requests | length' "$state_file")
    if [[ "$count" == "1" ]]; then
        test_pass
    else
        test_fail "Expected 1 request, got $count"
    fi
else
    test_fail "State file not created"
fi

# Test: Request count after recording
test_case "_needle_get_request_count returns correct count after recording"
create_test_config
_needle_clear_rate_limits "openai"

# Record 3 requests
for i in {1..3}; do
    _needle_record_request "openai"
done

count=$(_needle_get_request_count "openai")
if [[ "$count" == "3" ]]; then
    test_pass
else
    test_fail "Expected 3, got $count"
fi

# Test: Rate limit check passes when under limit
test_case "_needle_check_rate_limit passes when under limit"
create_test_config
_needle_clear_rate_limits "anthropic"

# Record 5 requests (under limit of 10)
for i in {1..5}; do
    _needle_record_request "anthropic"
done

if _needle_check_rate_limit "anthropic"; then
    test_pass
else
    test_fail "Check failed but under limit: $NEEDLE_RATE_LIMIT_MESSAGE"
fi

# Test: Rate limit check fails when at limit
test_case "_needle_check_rate_limit fails when at limit"
create_test_config
_needle_clear_rate_limits "openai"

# Record 5 requests (at limit of 5)
for i in {1..5}; do
    _needle_record_request "openai"
done

if ! _needle_check_rate_limit "openai"; then
    if [[ "$NEEDLE_RATE_LIMIT_MESSAGE" == *"openai"* ]]; then
        test_pass
    else
        test_fail "Wrong error message: $NEEDLE_RATE_LIMIT_MESSAGE"
    fi
else
    test_fail "Check passed but at limit"
fi

# Test: Remaining requests calculation
test_case "_needle_get_remaining_requests returns correct value"
create_test_config
_needle_clear_rate_limits "anthropic"

# Record 7 requests
for i in {1..7}; do
    _needle_record_request "anthropic"
done

remaining=$(_needle_get_remaining_requests "anthropic")
if [[ "$remaining" == "3" ]]; then
    test_pass
else
    test_fail "Expected 3 remaining, got $remaining"
fi

# Test: Remaining requests is 0 when at limit
test_case "_needle_get_remaining_requests returns 0 when at limit"
create_test_config
_needle_clear_rate_limits "openai"

# Record 5 requests (at limit)
for i in {1..5}; do
    _needle_record_request "openai"
done

remaining=$(_needle_get_remaining_requests "openai")
if [[ "$remaining" == "0" ]]; then
    test_pass
else
    test_fail "Expected 0 remaining, got $remaining"
fi

# Test: Rate limit status JSON is valid
test_case "_needle_get_rate_limit_status returns valid JSON"
create_test_config
_needle_clear_rate_limits "anthropic"
_needle_record_request "anthropic"

status=$(_needle_get_rate_limit_status "anthropic")

if echo "$status" | jq -e '.current' &>/dev/null; then
    current=$(echo "$status" | jq -r '.current')
    if [[ "$current" == "1" ]]; then
        test_pass
    else
        test_fail "Expected 1 current request, got $current"
    fi
else
    test_fail "Invalid JSON or missing .current"
fi

# Test: Multiple additional requests check
test_case "_needle_check_rate_limit handles multiple additional requests"
create_test_config
_needle_clear_rate_limits "anthropic"

# Record 7 requests (leaving room for 3 more within limit of 10)
for i in {1..7}; do
    _needle_record_request "anthropic"
done

# Should pass - 7 + 3 = 10 (at limit, not over)
if _needle_check_rate_limit "anthropic" 3; then
    # But 7 + 4 = 11 (over limit of 10)
    if ! _needle_check_rate_limit "anthropic" 4; then
        test_pass
    else
        test_fail "Check passed for 7+4 requests but limit is 10"
    fi
else
    test_fail "Check failed for 7+3 requests but limit is 10: $NEEDLE_RATE_LIMIT_MESSAGE"
fi

# Test: Clear rate limits
test_case "_needle_clear_rate_limits removes state file"
create_test_config
_needle_record_request "anthropic"
_needle_clear_rate_limits "anthropic"

state_file="$NEEDLE_RATE_LIMITS_DIR/anthropic.json"
if [[ ! -f "$state_file" ]]; then
    test_pass
else
    test_fail "State file still exists after clear"
fi

# Test: Sliding window - old requests expire
test_case "Old requests expire from sliding window"
create_test_config
_needle_clear_rate_limits "test-provider"

state_file="$NEEDLE_RATE_LIMITS_DIR/test-provider.json"
mkdir -p "$(dirname "$state_file")"

# Create state with an old request (65 seconds ago - outside window)
# and a recent request (5 seconds ago - inside window)
old_ts=$(date -u -d "65 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-65S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
recent_ts=$(date -u -d "5 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

cat > "$state_file" << EOF
{
  "provider": "test-provider",
  "requests": [
    {"ts": "$old_ts"},
    {"ts": "$recent_ts"}
  ]
}
EOF

# Count should only include recent request
count=$(_needle_get_request_count "test-provider")
if [[ "$count" == "1" ]]; then
    test_pass
else
    test_fail "Expected 1 (old request expired), got $count"
fi

# Test: Rate limit persists across state loads
test_case "Rate limit state persists"
create_test_config
_needle_clear_rate_limits "persistent-test"

# Record some requests
for i in {1..4}; do
    _needle_record_request "persistent-test"
done

# Clear any in-memory state by re-sourcing
count=$(_needle_get_request_count "persistent-test")
if [[ "$count" == "4" ]]; then
    test_pass
else
    test_fail "Expected 4 persisted requests, got $count"
fi

# Test: Empty provider handled gracefully
test_case "_needle_check_rate_limit handles empty provider"
create_test_config

# Should pass - no provider means no rate limit
if _needle_check_rate_limit ""; then
    test_pass
else
    test_fail "Failed with empty provider: $NEEDLE_RATE_LIMIT_MESSAGE"
fi

# Test: Retry after calculation when at limit
test_case "_needle_get_retry_after returns positive when at limit"
create_test_config
_needle_clear_rate_limits "openai"

# Fill to limit
for i in {1..5}; do
    _needle_record_request "openai"
done

retry_after=$(_needle_get_retry_after "openai")
if [[ "$retry_after" -gt 0 ]] && [[ "$retry_after" -le 60 ]]; then
    test_pass
else
    test_fail "Expected retry_after between 1-60, got $retry_after"
fi

# Test: Retry after is 0 when under limit
test_case "_needle_get_retry_after returns 0 when under limit"
create_test_config
_needle_clear_rate_limits "anthropic"

# Record just 1 request (under limit of 10)
_needle_record_request "anthropic"

retry_after=$(_needle_get_retry_after "anthropic")
if [[ "$retry_after" == "0" ]]; then
    test_pass
else
    test_fail "Expected 0, got $retry_after"
fi

# Test: Cleanup removes old requests
test_case "_needle_cleanup_rate_limits removes old requests"
create_test_config
_needle_clear_rate_limits "cleanup-test"

state_file="$NEEDLE_RATE_LIMITS_DIR/cleanup-test.json"
mkdir -p "$(dirname "$state_file")"

# Create state with old requests
old_ts=$(date -u -d "120 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-120S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$state_file" << EOF
{
  "provider": "cleanup-test",
  "requests": [
    {"ts": "$old_ts"},
    {"ts": "$old_ts"},
    {"ts": "$recent_ts"}
  ]
}
EOF

_needle_cleanup_rate_limits "cleanup-test"

remaining=$(jq '.requests | length' "$state_file")
if [[ "$remaining" == "1" ]]; then
    test_pass
else
    test_fail "Expected 1 request after cleanup, got $remaining"
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
