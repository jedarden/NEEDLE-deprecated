#!/usr/bin/env bash
# Test script for NEEDLE Worker Loop Cleanup and Recovery Module
#
# This test script verifies:
# 1. Exit code handling
# 2. Backoff logic
# 3. Crash loop detection
# 4. Cleanup functions

set -o pipefail

# Test directory
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$TEST_DIR/../src/runner"

# Source the loop module (which includes stubs for dependencies)
source "$SCRIPT_DIR/loop.sh"

# Test helper: Setup mock environment
setup_mock_environment() {
    export NEEDLE_SESSION="test-session-$$"
    export NEEDLE_RUNNER="test"
    export NEEDLE_PROVIDER="test"
    export NEEDLE_MODEL="test"
    export NEEDLE_IDENTIFIER="test"
    export NEEDLE_WORKSPACE="/tmp/test-workspace-$$"
    export NEEDLE_AGENT="test-agent"
    export NEEDLE_HOME="/tmp/test-needle-home-$$"
    export NEEDLE_STATE_DIR="$NEEDLE_HOME/state"
    export NEEDLE_VERBOSE=true

    # Create test directories
    mkdir -p "$NEEDLE_HOME/$NEEDLE_STATE_DIR"
    mkdir -p "$NEEDLE_HOME/$NEEDLE_STATE_DIR/heartbeats"
    mkdir -p "$NEEDLE_WORKSPACE"

    # Reset backoff state
    NEEDLE_FAILURE_COUNT=0
    NEEDLE_BACKOFF_SECONDS=0
    NEEDLE_LAST_FAILURE_TIME=""
}

# Test helper: Cleanup mock environment
cleanup_mock_environment() {
    if [[ -n "${NEEDLE_HOME:-}" ]]; then
        rm -rf "$NEEDLE_HOME" 2>/dev/null || true
    fi
    if [[ -n "${NEEDLE_WORKSPACE:-}" ]]; then
        rm -rf "$NEEDLE_WORKSPACE" 2>/dev/null || true
    fi
}

# Test: Backoff reset function
test_reset_backoff() {
    echo "=== Testing backoff reset ==="

    setup_mock_environment

    # Set some failure state
    NEEDLE_FAILURE_COUNT=5
    NEEDLE_BACKOFF_SECONDS=120
    NEEDLE_LAST_FAILURE_TIME="2026-01-01T00:00:00Z"

    # Reset
    _needle_reset_backoff

    if [[ $NEEDLE_FAILURE_COUNT -eq 0 ]]; then
        echo "✓ Failure count reset to 0"
    else
        echo "✗ Failure count not reset: $NEEDLE_FAILURE_COUNT"
        exit 1
    fi

    if [[ $NEEDLE_BACKOFF_SECONDS -eq 0 ]]; then
        echo "✓ Backoff seconds reset to 0"
    else
        echo "✗ Backoff seconds not reset: $NEEDLE_BACKOFF_SECONDS"
        exit 1
    fi

    if [[ -z "$NEEDLE_LAST_FAILURE_TIME" ]]; then
        echo "✓ Last failure time cleared"
    else
        echo "✗ Last failure time not cleared: $NEEDLE_LAST_FAILURE_TIME"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Backoff increment function
test_increment_backoff() {
    echo "=== Testing backoff increment ==="

    setup_mock_environment

    # First few failures should not trigger backoff
    _needle_increment_backoff
    if [[ $NEEDLE_FAILURE_COUNT -eq 1 ]] && [[ $NEEDLE_BACKOFF_SECONDS -eq 0 ]]; then
        echo "✓ Failure 1: No backoff yet (count=$NEEDLE_FAILURE_COUNT, backoff=$NEEDLE_BACKOFF_SECONDS)"
    else
        echo "✗ Failure 1: Unexpected state (count=$NEEDLE_FAILURE_COUNT, backoff=$NEEDLE_BACKOFF_SECONDS)"
        exit 1
    fi

    _needle_increment_backoff
    if [[ $NEEDLE_FAILURE_COUNT -eq 2 ]] && [[ $NEEDLE_BACKOFF_SECONDS -eq 0 ]]; then
        echo "✓ Failure 2: No backoff yet (count=$NEEDLE_FAILURE_COUNT, backoff=$NEEDLE_BACKOFF_SECONDS)"
    else
        echo "✗ Failure 2: Unexpected state (count=$NEEDLE_FAILURE_COUNT, backoff=$NEEDLE_BACKOFF_SECONDS)"
        exit 1
    fi

    # Third failure should trigger backoff (threshold is 3)
    _needle_increment_backoff
    if [[ $NEEDLE_FAILURE_COUNT -eq 3 ]] && [[ $NEEDLE_BACKOFF_SECONDS -gt 0 ]]; then
        echo "✓ Failure 3: Backoff triggered (count=$NEEDLE_FAILURE_COUNT, backoff=$NEEDLE_BACKOFF_SECONDS)"
    else
        echo "✗ Failure 3: Backoff not triggered (count=$NEEDLE_FAILURE_COUNT, backoff=$NEEDLE_BACKOFF_SECONDS)"
        exit 1
    fi

    # Check exponential growth
    local first_backoff=$NEEDLE_BACKOFF_SECONDS

    _needle_increment_backoff
    if [[ $NEEDLE_BACKOFF_SECONDS -gt $first_backoff ]]; then
        echo "✓ Failure 4: Backoff increased (from $first_backoff to $NEEDLE_BACKOFF_SECONDS)"
    else
        echo "✗ Failure 4: Backoff did not increase (from $first_backoff to $NEEDLE_BACKOFF_SECONDS)"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Alert threshold detection
test_alert_threshold() {
    echo "=== Testing alert threshold detection ==="

    setup_mock_environment

    # Below threshold
    NEEDLE_FAILURE_COUNT=2
    if ! _needle_should_alert_human; then
        echo "✓ No alert at 2 failures (below threshold)"
    else
        echo "✗ Alert triggered at 2 failures (should be below threshold)"
        exit 1
    fi

    # At threshold
    NEEDLE_FAILURE_COUNT=5
    if _needle_should_alert_human; then
        echo "✓ Alert triggered at 5 failures (at threshold)"
    else
        echo "✗ No alert at 5 failures (should be at threshold)"
        exit 1
    fi

    # Above threshold
    NEEDLE_FAILURE_COUNT=7
    if _needle_should_alert_human; then
        echo "✓ Alert triggered at 7 failures (above threshold)"
    else
        echo "✗ No alert at 7 failures (should be above threshold)"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Exit threshold detection
test_exit_threshold() {
    echo "=== Testing exit threshold detection ==="

    setup_mock_environment

    # Below threshold
    NEEDLE_FAILURE_COUNT=5
    if ! _needle_should_exit_worker; then
        echo "✓ No exit at 5 failures (below max)"
    else
        echo "✗ Exit triggered at 5 failures (should be below max)"
        exit 1
    fi

    # At max
    NEEDLE_FAILURE_COUNT=7
    if _needle_should_exit_worker; then
        echo "✓ Exit triggered at 7 failures (at max)"
    else
        echo "✗ No exit at 7 failures (should be at max)"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Exit code handler function exists
test_exit_code_handler() {
    echo "=== Testing exit code handler function ==="

    setup_mock_environment

    # Test that function exists
    declare -f _needle_handle_exit_code >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_handle_exit_code function exists"
    else
        echo "✗ _needle_handle_exit_code function missing"
        exit 1
    fi

    # Mock br command for testing
    br() {
        case "$1" in
            update)
                # Simulate successful update
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f br

    # Test handling exit code 0 (success)
    NEEDLE_FAILURE_COUNT=3  # Start with some failures
    _needle_handle_exit_code "test-bead-0" 0 "$NEEDLE_WORKSPACE" "test-agent"
    local result=$?
    if [[ $result -eq 0 ]] && [[ $NEEDLE_FAILURE_COUNT -eq 0 ]]; then
        echo "✓ Exit code 0: Success - backoff reset"
    else
        echo "✗ Exit code 0: Unexpected result=$result, failure_count=$NEEDLE_FAILURE_COUNT"
        exit 1
    fi

    # Test handling exit code 1 (failure)
    NEEDLE_FAILURE_COUNT=0
    _needle_handle_exit_code "test-bead-1" 1 "$NEEDLE_WORKSPACE" "test-agent"
    result=$?
    if [[ $result -eq 0 ]] && [[ $NEEDLE_FAILURE_COUNT -eq 1 ]]; then
        echo "✓ Exit code 1: Failure - bead released, backoff incremented"
    else
        echo "✗ Exit code 1: Unexpected result=$result, failure_count=$NEEDLE_FAILURE_COUNT"
        exit 1
    fi

    # Test handling exit code 124 (timeout)
    NEEDLE_FAILURE_COUNT=0
    NEEDLE_BACKOFF_SECONDS=0
    _needle_handle_exit_code "test-bead-124" 124 "$NEEDLE_WORKSPACE" "test-agent"
    result=$?
    if [[ $result -eq 0 ]]; then
        echo "✓ Exit code 124: Timeout - bead released with timeout label"
    else
        echo "✗ Exit code 124: Unexpected result=$result"
        exit 1
    fi

    # Test handling unknown exit code
    NEEDLE_FAILURE_COUNT=0
    NEEDLE_BACKOFF_SECONDS=0
    _needle_handle_exit_code "test-bead-99" 99 "$NEEDLE_WORKSPACE" "test-agent"
    result=$?
    if [[ $result -eq 0 ]] && [[ $NEEDLE_FAILURE_COUNT -eq 1 ]]; then
        echo "✓ Exit code 99: Unknown error - bead released, backoff incremented"
    else
        echo "✗ Exit code 99: Unexpected result=$result, failure_count=$NEEDLE_FAILURE_COUNT"
        exit 1
    fi

    # Test handling exit code 137 (SIGKILL/OOM - agent crash)
    # Regression test for nd-r8ie: exit code 137 should quarantine, not release
    NEEDLE_FAILURE_COUNT=5  # Start with high failure count to verify reset
    NEEDLE_BACKOFF_SECONDS=10
    local pre_quarantine_count=0
    if declare -f _needle_quarantine_bead &>/dev/null; then
        # Track if quarantine was called (mock will set a flag)
        export NEEDLE_TEST_QUARANTINE_CALLED=""
        _needle_handle_exit_code "test-bead-137" 137 "$NEEDLE_WORKSPACE" "test-agent"
        result=$?
        if [[ $result -eq 0 ]] && [[ $NEEDLE_FAILURE_COUNT -eq 0 ]]; then
            echo "✓ Exit code 137: Agent crash - bead quarantined, failure count reset"
        elif [[ $NEEDLE_FAILURE_COUNT -ne 0 ]]; then
            echo "✗ Exit code 137: Failure count should be reset to 0, got $NEEDLE_FAILURE_COUNT"
            exit 1
        else
            echo "✗ Exit code 137: Unexpected result=$result"
            exit 1
        fi
    else
        echo "⊘ Exit code 137: _needle_quarantine_bead not available (skipped)"
    fi

    # Unset mock
    unset -f br

    cleanup_mock_environment
    echo ""
}

# Test: Cleanup execution function
test_cleanup_execution() {
    echo "=== Testing cleanup execution function ==="

    setup_mock_environment

    # Set some execution state
    export NEEDLE_EXIT_CODE=1
    export NEEDLE_DURATION_MS=5000
    export NEEDLE_OUTPUT_FILE="/tmp/test-output.log"
    export NEEDLE_CURRENT_BEAD="test-bead"

    # Create a temp output file
    touch "$NEEDLE_OUTPUT_FILE"

    # Run cleanup
    _needle_cleanup_execution "test-bead"

    # Verify environment variables are unset
    if [[ -z "${NEEDLE_EXIT_CODE:-}" ]]; then
        echo "✓ NEEDLE_EXIT_CODE cleared"
    else
        echo "✗ NEEDLE_EXIT_CODE not cleared: $NEEDLE_EXIT_CODE"
        exit 1
    fi

    if [[ -z "${NEEDLE_DURATION_MS:-}" ]]; then
        echo "✓ NEEDLE_DURATION_MS cleared"
    else
        echo "✗ NEEDLE_DURATION_MS not cleared: $NEEDLE_DURATION_MS"
        exit 1
    fi

    if [[ -z "${NEEDLE_OUTPUT_FILE:-}" ]]; then
        echo "✓ NEEDLE_OUTPUT_FILE cleared"
    else
        echo "✗ NEEDLE_OUTPUT_FILE not cleared: $NEEDLE_OUTPUT_FILE"
        exit 1
    fi

    if [[ -z "${NEEDLE_CURRENT_BEAD:-}" ]]; then
        echo "✓ NEEDLE_CURRENT_BEAD cleared"
    else
        echo "✗ NEEDLE_CURRENT_BEAD not cleared: $NEEDLE_CURRENT_BEAD"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Worker cleanup function exists
test_worker_cleanup() {
    echo "=== Testing worker cleanup function ==="

    setup_mock_environment

    # Test that function exists
    declare -f _needle_worker_cleanup >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_worker_cleanup function exists"
    else
        echo "✗ _needle_worker_cleanup function missing"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Crash loop alert function exists
test_crash_loop_alert() {
    echo "=== Testing crash loop alert function ==="

    setup_mock_environment

    # Test that function exists
    declare -f _needle_alert_crash_loop >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_alert_crash_loop function exists"
    else
        echo "✗ _needle_alert_crash_loop function missing"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Backoff configuration constants
test_backoff_config() {
    echo "=== Testing backoff configuration constants ==="

    setup_mock_environment

    # Check that configuration constants exist
    if [[ -n "${NEEDLE_BACKOFF_BASE_SECONDS:-}" ]]; then
        echo "✓ NEEDLE_BACKOFF_BASE_SECONDS defined: $NEEDLE_BACKOFF_BASE_SECONDS"
    else
        echo "✗ NEEDLE_BACKOFF_BASE_SECONDS not defined"
        exit 1
    fi

    if [[ -n "${NEEDLE_BACKOFF_MAX_SECONDS:-}" ]]; then
        echo "✓ NEEDLE_BACKOFF_MAX_SECONDS defined: $NEEDLE_BACKOFF_MAX_SECONDS"
    else
        echo "✗ NEEDLE_BACKOFF_MAX_SECONDS not defined"
        exit 1
    fi

    if [[ -n "${NEEDLE_BACKOFF_THRESHOLD:-}" ]]; then
        echo "✓ NEEDLE_BACKOFF_THRESHOLD defined: $NEEDLE_BACKOFF_THRESHOLD"
    else
        echo "✗ NEEDLE_BACKOFF_THRESHOLD not defined"
        exit 1
    fi

    if [[ -n "${NEEDLE_ALERT_THRESHOLD:-}" ]]; then
        echo "✓ NEEDLE_ALERT_THRESHOLD defined: $NEEDLE_ALERT_THRESHOLD"
    else
        echo "✗ NEEDLE_ALERT_THRESHOLD not defined"
        exit 1
    fi

    if [[ -n "${NEEDLE_MAX_FAILURES:-}" ]]; then
        echo "✓ NEEDLE_MAX_FAILURES defined: $NEEDLE_MAX_FAILURES"
    else
        echo "✗ NEEDLE_MAX_FAILURES not defined"
        exit 1
    fi

    # Verify expected values
    if [[ $NEEDLE_BACKOFF_BASE_SECONDS -eq 30 ]]; then
        echo "✓ NEEDLE_BACKOFF_BASE_SECONDS is 30"
    else
        echo "✗ NEEDLE_BACKOFF_BASE_SECONDS unexpected: $NEEDLE_BACKOFF_BASE_SECONDS"
        exit 1
    fi

    if [[ $NEEDLE_BACKOFF_MAX_SECONDS -eq 120 ]]; then
        echo "✓ NEEDLE_BACKOFF_MAX_SECONDS is 120"
    else
        echo "✗ NEEDLE_BACKOFF_MAX_SECONDS unexpected: $NEEDLE_BACKOFF_MAX_SECONDS"
        exit 1
    fi

    if [[ $NEEDLE_BACKOFF_THRESHOLD -eq 3 ]]; then
        echo "✓ NEEDLE_BACKOFF_THRESHOLD is 3"
    else
        echo "✗ NEEDLE_BACKOFF_THRESHOLD unexpected: $NEEDLE_BACKOFF_THRESHOLD"
        exit 1
    fi

    if [[ $NEEDLE_ALERT_THRESHOLD -eq 5 ]]; then
        echo "✓ NEEDLE_ALERT_THRESHOLD is 5"
    else
        echo "✗ NEEDLE_ALERT_THRESHOLD unexpected: $NEEDLE_ALERT_THRESHOLD"
        exit 1
    fi

    if [[ $NEEDLE_MAX_FAILURES -eq 7 ]]; then
        echo "✓ NEEDLE_MAX_FAILURES is 7"
    else
        echo "✗ NEEDLE_MAX_FAILURES unexpected: $NEEDLE_MAX_FAILURES"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Exit code 137 uses _needle_error_handle (auto-bead trigger)
# Regression test for nd-6ys3: the 137 handler must use _needle_error_handle
# so that _needle_error_auto_bead is called per errors.sh escalation policy.
# Previously, _needle_event_error_agent_crash was used, which only emits a
# telemetry event and does NOT trigger auto-bead creation.
test_exit_137_uses_error_handle() {
    echo "=== Testing exit code 137 uses _needle_error_handle (nd-6ys3 regression) ==="

    setup_mock_environment

    # Verify _needle_error_handle is available in the loop context
    # (errors.sh must be sourced by loop.sh for auto-bead to work)
    if declare -f _needle_error_handle &>/dev/null; then
        echo "✓ _needle_error_handle is available in loop context (errors.sh sourced)"
    else
        echo "✗ _needle_error_handle not available - errors.sh not sourced in loop.sh"
        exit 1
    fi

    # Track whether _needle_error_handle is called for exit code 137
    local error_handle_called=false
    _needle_error_handle() {
        if [[ "$1" == "error.agent_crash" ]] && [[ "$2" == "137" ]]; then
            error_handle_called=true
        fi
        printf 'quarantine'
    }
    export -f _needle_error_handle

    # Mock br and quarantine function
    br() { return 0; }
    export -f br
    _needle_quarantine_bead() { return 0; }
    export -f _needle_quarantine_bead

    NEEDLE_FAILURE_COUNT=3
    _needle_handle_exit_code "test-bead-137" 137 "$NEEDLE_WORKSPACE" "test-agent"

    if [[ "$error_handle_called" == "true" ]]; then
        echo "✓ Exit code 137: _needle_error_handle called (auto-bead creation enabled)"
    else
        echo "✗ Exit code 137: _needle_error_handle NOT called - auto-bead will not be created"
        exit 1
    fi

    # Verify failure count is reset (regression from nd-r8ie)
    if [[ $NEEDLE_FAILURE_COUNT -eq 0 ]]; then
        echo "✓ Exit code 137: Failure count reset to 0"
    else
        echo "✗ Exit code 137: Failure count not reset, got $NEEDLE_FAILURE_COUNT"
        exit 1
    fi

    # Unset mocks
    unset -f _needle_error_handle br _needle_quarantine_bead

    cleanup_mock_environment
    echo ""
}

# Run all tests
echo "=========================================="
echo "NEEDLE Worker Loop Cleanup/Recovery Tests"
echo "=========================================="
echo ""

test_reset_backoff
test_increment_backoff
test_alert_threshold
test_exit_threshold
test_exit_code_handler
test_cleanup_execution
test_worker_cleanup
test_crash_loop_alert
test_backoff_config
test_exit_137_uses_error_handle

echo ""
echo "=========================================="
echo "All tests completed"
echo "=========================================="
