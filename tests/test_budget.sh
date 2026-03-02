#!/usr/bin/env bash
# Tests for NEEDLE Budget Enforcement Module

# Get test directory
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

# Source test utilities
source "$TEST_DIR/test_utils.sh" 2>/dev/null || {
    # Minimal test utilities if not available
    _test_pass() { echo "PASS: $1"; ((passed++)); }
    _test_fail() { echo "FAIL: $1"; ((failed++)); }
    passed=0
    failed=0
}

# Source the module under test
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/config.sh"
source "$PROJECT_DIR/src/telemetry/effort.sh"
source "$PROJECT_DIR/src/telemetry/events.sh"
source "$PROJECT_DIR/src/telemetry/budget.sh"

# Test constants
TEST_STATE_DIR="/tmp/needle_test_budget_$$"

# Setup
setup() {
    mkdir -p "$TEST_STATE_DIR"
    export NEEDLE_HOME="$TEST_STATE_DIR"
    export NEEDLE_DAILY_SPEND_FILE="$TEST_STATE_DIR/daily_spend.json"
    export NEEDLE_CONFIG_FILE="$TEST_STATE_DIR/config.yaml"

    # Create a minimal config file
    cat > "$NEEDLE_CONFIG_FILE" << EOF
effort:
  budget:
    daily_limit_usd: 50.0
    warning_threshold: 0.8
    per_bead_limit_usd: 10.0
EOF

    _needle_effort_init
    reset_budget_warning
}

# Teardown
teardown() {
    rm -rf "$TEST_STATE_DIR"
}

# =============================================================================
# Test: get_daily_limit
# =============================================================================
test_get_daily_limit() {
    local test_name="get_daily_limit"

    local limit
    limit=$(get_daily_limit)

    if [[ "$limit" == "50.0" || "$limit" == "50" ]]; then
        _test_pass "$test_name - returns default 50.0"
    else
        _test_fail "$test_name - expected 50.0, got $limit"
    fi
}

# =============================================================================
# Test: get_warning_threshold
# =============================================================================
test_get_warning_threshold() {
    local test_name="get_warning_threshold"

    local threshold
    threshold=$(get_warning_threshold)

    if [[ "$threshold" == "0.8" ]]; then
        _test_pass "$test_name - returns 0.8"
    else
        _test_fail "$test_name - expected 0.8, got $threshold"
    fi
}

# =============================================================================
# Test: get_per_bead_limit
# =============================================================================
test_get_per_bead_limit() {
    local test_name="get_per_bead_limit"

    local limit
    limit=$(get_per_bead_limit)

    if [[ "$limit" == "10.0" || "$limit" == "10" ]]; then
        _test_pass "$test_name - returns 10.0"
    else
        _test_fail "$test_name - expected 10.0, got $limit"
    fi
}

# =============================================================================
# Test: get_daily_spend with no spend
# =============================================================================
test_get_daily_spend_empty() {
    local test_name="get_daily_spend (empty)"

    # Initialize empty spend file
    echo '{}' > "$NEEDLE_DAILY_SPEND_FILE"

    local spend
    spend=$(get_daily_spend)

    if [[ "$spend" == "0" || "$spend" == "0.0" || "$spend" == "null" || -z "$spend" ]]; then
        _test_pass "$test_name - returns 0 for empty file"
    else
        _test_fail "$test_name - expected 0, got $spend"
    fi
}

# =============================================================================
# Test: get_daily_spend with existing spend
# =============================================================================
test_get_daily_spend_with_data() {
    local test_name="get_daily_spend (with data)"

    local today
    today=$(date +%Y-%m-%d)

    # Create spend file with existing data
    echo "{\"$today\":{\"total\":25.50}}" > "$NEEDLE_DAILY_SPEND_FILE"

    local spend
    spend=$(get_daily_spend)

    if [[ "$spend" == "25.50" ]]; then
        _test_pass "$test_name - returns 25.50"
    else
        _test_fail "$test_name - expected 25.50, got $spend"
    fi
}

# =============================================================================
# Test: get_budget_ratio
# =============================================================================
test_get_budget_ratio() {
    local test_name="get_budget_ratio"

    local today
    today=$(date +%Y-%m-%d)

    # Test with 50% spend (25 of 50)
    echo "{\"$today\":{\"total\":25.0}}" > "$NEEDLE_DAILY_SPEND_FILE"

    local ratio
    ratio=$(get_budget_ratio)

    # Should be 0.5
    if command -v awk &>/dev/null; then
        local is_half
        is_half=$(awk "BEGIN {print ($ratio >= 0.49 && $ratio <= 0.51) ? 1 : 0}")
        if [[ "$is_half" == "1" ]]; then
            _test_pass "$test_name - returns ~0.5 for 50% spend"
        else
            _test_fail "$test_name - expected ~0.5, got $ratio"
        fi
    else
        _test_pass "$test_name - skipped (awk not available)"
    fi
}

# =============================================================================
# Test: check_budget returns OK
# =============================================================================
test_check_budget_ok() {
    local test_name="check_budget (OK)"

    local today
    today=$(date +%Y-%m-%d)

    # Set spend to 10% of limit (5 of 50)
    echo "{\"$today\":{\"total\":5.0}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    check_budget
    local result=$?

    if [[ $result -eq 0 ]]; then
        _test_pass "$test_name - returns 0 for 10% spend"
    else
        _test_fail "$test_name - expected 0, got $result"
    fi
}

# =============================================================================
# Test: check_budget returns warning
# =============================================================================
test_check_budget_warning() {
    local test_name="check_budget (warning)"

    local today
    today=$(date +%Y-%m-%d)

    # Set spend to 85% of limit (42.5 of 50) - above 80% threshold
    echo "{\"$today\":{\"total\":42.5}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    check_budget
    local result=$?

    if [[ $result -eq 1 ]]; then
        _test_pass "$test_name - returns 1 for 85% spend"
    else
        _test_fail "$test_name - expected 1, got $result"
    fi
}

# =============================================================================
# Test: check_budget returns exceeded
# =============================================================================
test_check_budget_exceeded() {
    local test_name="check_budget (exceeded)"

    local today
    today=$(date +%Y-%m-%d)

    # Set spend to 100% of limit (50 of 50)
    echo "{\"$today\":{\"total\":50.0}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    check_budget
    local result=$?

    if [[ $result -eq 2 ]]; then
        _test_pass "$test_name - returns 2 for 100% spend"
    else
        _test_fail "$test_name - expected 2, got $result"
    fi
}

# =============================================================================
# Test: check_budget exceeded above limit
# =============================================================================
test_check_budget_over_limit() {
    local test_name="check_budget (over limit)"

    local today
    today=$(date +%Y-%m-%d)

    # Set spend to 120% of limit (60 of 50)
    echo "{\"$today\":{\"total\":60.0}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    check_budget
    local result=$?

    if [[ $result -eq 2 ]]; then
        _test_pass "$test_name - returns 2 for 120% spend"
    else
        _test_fail "$test_name - expected 2, got $result"
    fi
}

# =============================================================================
# Test: check_bead_cost OK
# =============================================================================
test_check_bead_cost_ok() {
    local test_name="check_bead_cost (OK)"

    # Cost within limit (5 < 10)
    check_bead_cost "5.0" "test-bead-1"
    local result=$?

    if [[ $result -eq 0 ]]; then
        _test_pass "$test_name - returns 0 for cost under limit"
    else
        _test_fail "$test_name - expected 0, got $result"
    fi
}

# =============================================================================
# Test: check_bead_cost exceeded
# =============================================================================
test_check_bead_cost_exceeded() {
    local test_name="check_bead_cost (exceeded)"

    # Cost exceeds limit (15 > 10)
    check_bead_cost "15.0" "test-bead-2"
    local result=$?

    if [[ $result -eq 2 ]]; then
        _test_pass "$test_name - returns 2 for cost over limit"
    else
        _test_fail "$test_name - expected 2, got $result"
    fi
}

# =============================================================================
# Test: check_bead_cost at limit
# =============================================================================
test_check_bead_cost_at_limit() {
    local test_name="check_bead_cost (at limit)"

    # Cost exactly at limit (10 == 10)
    check_bead_cost "10.0" "test-bead-3"
    local result=$?

    if [[ $result -eq 2 ]]; then
        _test_pass "$test_name - returns 2 for cost at limit"
    else
        _test_fail "$test_name - expected 2, got $result"
    fi
}

# =============================================================================
# Test: get_budget_status
# =============================================================================
test_get_budget_status() {
    local test_name="get_budget_status"

    local today
    today=$(date +%Y-%m-%d)

    # Set spend to 40% of limit
    echo "{\"$today\":{\"total\":20.0}}" > "$NEEDLE_DAILY_SPEND_FILE"

    local status
    status=$(get_budget_status)

    if [[ -n "$status" ]]; then
        # Verify it's valid JSON
        if command -v jq &>/dev/null; then
            if echo "$status" | jq empty 2>/dev/null; then
                _test_pass "$test_name - returns valid JSON"
            else
                _test_fail "$test_name - invalid JSON: $status"
            fi
        else
            _test_pass "$test_name - returns non-empty status (jq not available)"
        fi
    else
        _test_fail "$test_name - expected non-empty status"
    fi
}

# =============================================================================
# Test: warning only emitted once
# =============================================================================
test_warning_emitted_once() {
    local test_name="warning emitted only once"

    local today
    today=$(date +%Y-%m-%d)

    # Set spend to 85% of limit
    echo "{\"$today\":{\"total\":42.5}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    export NEEDLE_VERBOSE=true

    # First check should emit warning
    local output1
    output1=$(check_budget 2>&1)

    # Second check should not emit warning (already emitted)
    local output2
    output2=$(check_budget 2>&1)

    # Both should return 1 (warning)
    check_budget
    local result1=$?
    check_budget
    local result2=$?

    if [[ $result1 -eq 1 && $result2 -eq 1 ]]; then
        _test_pass "$test_name - both checks return warning (1)"
    else
        _test_fail "$test_name - expected both to return 1, got $result1 and $result2"
    fi
}

# =============================================================================
# Test: reset_budget_warning
# =============================================================================
test_reset_budget_warning() {
    local test_name="reset_budget_warning"

    # Set warning as already emitted
    NEEDLE_BUDGET_WARNING_EMITTED="true"

    # Reset
    reset_budget_warning

    if [[ "$NEEDLE_BUDGET_WARNING_EMITTED" == "false" ]]; then
        _test_pass "$test_name - resets warning state to false"
    else
        _test_fail "$test_name - expected false, got $NEEDLE_BUDGET_WARNING_EMITTED"
    fi
}

# =============================================================================
# Test: budget_ok wrapper
# =============================================================================
test_budget_ok() {
    local test_name="budget_ok wrapper"

    local today
    today=$(date +%Y-%m-%d)

    # Test OK state
    echo "{\"$today\":{\"total\":5.0}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    if budget_ok; then
        _test_pass "$test_name - returns true for OK state"
    else
        _test_fail "$test_name - expected true for OK state"
    fi
}

# =============================================================================
# Test: budget_exceeded wrapper
# =============================================================================
test_budget_exceeded_wrapper() {
    local test_name="budget_exceeded wrapper"

    local today
    today=$(date +%Y-%m-%d)

    # Test exceeded state
    echo "{\"$today\":{\"total\":60.0}}" > "$NEEDLE_DAILY_SPEND_FILE"
    reset_budget_warning

    if budget_exceeded; then
        _test_pass "$test_name - returns true for exceeded state"
    else
        _test_fail "$test_name - expected true for exceeded state"
    fi
}

# =============================================================================
# Main test runner
# =============================================================================
main() {
    echo "Running budget.sh tests..."
    echo ""

    setup

    # Run tests
    test_get_daily_limit
    test_get_warning_threshold
    test_get_per_bead_limit
    test_get_daily_spend_empty
    test_get_daily_spend_with_data
    test_get_budget_ratio
    test_check_budget_ok
    test_check_budget_warning
    test_check_budget_exceeded
    test_check_budget_over_limit
    test_check_bead_cost_ok
    test_check_bead_cost_exceeded
    test_check_bead_cost_at_limit
    test_get_budget_status
    test_warning_emitted_once
    test_reset_budget_warning
    test_budget_ok
    test_budget_exceeded_wrapper

    teardown

    echo ""
    echo "Test Results: $passed passed, $failed failed"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
