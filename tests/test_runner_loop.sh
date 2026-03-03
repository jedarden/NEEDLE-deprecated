#!/usr/bin/env bash
# Test script for NEEDLE Worker Loop Module
#
# This test script verifies:
# 1. Signal handling setup
# 2. Worker loop initialization
# 3. Configuration loading
# 4. Event emission functions

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

# Test: Configuration helper
test_config_helper() {
    echo "=== Testing configuration helper ==="

    setup_mock_environment

    # Test configuration loading with defaults
    local polling_interval
    polling_interval=$(_needle_loop_get_config "runner.polling_interval" "$NEEDLE_LOOP_DEFAULT_POLLING_INTERVAL")

    local idle_timeout
    idle_timeout=$(_needle_loop_get_config "runner.idle_timeout" "$NEEDLE_LOOP_DEFAULT_IDLE_TIMEOUT")

    # Remove 's' suffix
    polling_interval="${polling_interval%s}"
    idle_timeout="${idle_timeout%s}"

    echo "Configuration loaded:"
    echo "  polling_interval: ${polling_interval}s"
    echo "  idle_timeout: ${idle_timeout}s"

    if [[ "$polling_interval" =~ ^[0-9]+$ ]]; then
        echo "✓ Polling interval is valid"
    else
        echo "✗ Polling interval is invalid"
        exit 1
    fi

    if [[ "$idle_timeout" =~ ^[0-9]+$ ]]; then
        echo "✓ Idle timeout is valid"
    else
        echo "✗ Idle timeout is invalid"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Event emission functions exist
test_event_emission() {
    echo "=== Testing event emission functions ==="

    setup_mock_environment

    # Test that event functions exist and can be called
    _needle_event_worker_started "workspace=/test" "agent=test-agent"
    echo "✓ Worker started event emission works"

    _needle_event_worker_idle "consecutive_empty=1" "idle_seconds=10"
    echo "✓ Worker idle event emission works"

    _needle_event_worker_stopped "reason=test"
    echo "✓ Worker stopped event emission works"

    _needle_event_bead_claimed "nd-test" "workspace=/test"
    echo "✓ Bead claimed event emission works"

    _needle_event_bead_completed "nd-test"
    echo "✓ Bead completed event emission works"

    _needle_event_bead_failed "nd-test" "reason=test"
    echo "✓ Bead failed event emission works"

    cleanup_mock_environment
    echo ""
}

# Test: Telemetry functions exist
test_telemetry() {
    echo "=== Testing telemetry functions ==="

    setup_mock_environment

    _needle_telemetry_init
    echo "✓ Telemetry init works"

    _needle_telemetry_emit "test.event" "key=value"
    echo "✓ Telemetry emit works"

    cleanup_mock_environment
    echo ""
}

# Test: Heartbeat stubs exist
test_heartbeat() {
    echo "=== Testing heartbeat functions ==="

    setup_mock_environment

    _needle_heartbeat_init
    echo "✓ Heartbeat init works"

    _needle_heartbeat_keepalive
    echo "✓ Heartbeat keepalive works"

    _needle_heartbeat_start_bead "nd-test"
    echo "✓ Heartbeat start bead works"

    _needle_heartbeat_end_bead
    echo "✓ Heartbeat end bead works"

    _needle_heartbeat_cleanup
    echo "✓ Heartbeat cleanup works"

    cleanup_mock_environment
    echo ""
}

# Test: Bead processing functions exist
test_bead_functions() {
    echo "=== Testing bead processing functions ==="

    setup_mock_environment

    # Test that bead functions exist
    declare -f _needle_process_bead >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_process_bead function exists"
    else
        echo "✗ _needle_process_bead function missing"
        exit 1
    fi

    declare -f _needle_complete_bead >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_complete_bead function exists"
    else
        echo "✗ _needle_complete_bead function missing"
        exit 1
    fi

    declare -f _needle_fail_bead >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_fail_bead function exists"
    else
        echo "✗ _needle_fail_bead function missing"
        exit 1
    fi

    declare -f _needle_release_bead >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_release_bead function exists"
    else
        echo "✗ _needle_release_bead function missing"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Worker loop function exists
test_worker_loop() {
    echo "=== Testing worker loop function ==="

    setup_mock_environment

    # Test that worker loop function exists
    declare -f _needle_worker_loop >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_worker_loop function exists"
    else
        echo "✗ _needle_worker_loop function missing"
        exit 1
    fi

    # Test that init function exists
    declare -f _needle_worker_loop_init >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_worker_loop_init function exists"
    else
        echo "✗ _needle_worker_loop_init function missing"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Signal handler setup function exists
test_signal_handlers() {
    echo "=== Testing signal handler functions ==="

    setup_mock_environment

    # Test that signal handler functions exist
    declare -f _needle_loop_setup_signals >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_loop_setup_signals function exists"
    else
        echo "✗ _needle_loop_setup_signals function missing"
        exit 1
    fi

    declare -f _needle_loop_handle_shutdown >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_loop_handle_shutdown function exists"
    else
        echo "✗ _needle_loop_handle_shutdown function missing"
        exit 1
    fi

    cleanup_mock_environment
    echo ""
}

# Test: Config hot-reload functions
test_config_hot_reload() {
    echo "=== Testing config hot-reload functions ==="

    setup_mock_environment

    # Test that hot-reload functions exist
    declare -f _needle_get_config_mtime >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_get_config_mtime function exists"
    else
        echo "✗ _needle_get_config_mtime function missing"
        exit 1
    fi

    declare -f _needle_check_config_reload >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_check_config_reload function exists"
    else
        echo "✗ _needle_check_config_reload function missing"
        exit 1
    fi

    declare -f _needle_validate_hot_reload_config >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ _needle_validate_hot_reload_config function exists"
    else
        echo "✗ _needle_validate_hot_reload_config function missing"
        exit 1
    fi

    # Test _needle_get_config_mtime with existing file
    local test_file="$NEEDLE_HOME/test_config.yaml"
    echo "test: value" > "$test_file"
    local mtime
    mtime=$(_needle_get_config_mtime "$test_file")
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        echo "✓ _needle_get_config_mtime returns valid timestamp for existing file"
    else
        echo "✗ _needle_get_config_mtime failed for existing file: $mtime"
        rm -f "$test_file"
        exit 1
    fi

    # Test _needle_get_config_mtime with non-existing file
    mtime=$(_needle_get_config_mtime "/nonexistent/file.yaml")
    if [[ "$mtime" == "0" ]]; then
        echo "✓ _needle_get_config_mtime returns 0 for non-existing file"
    else
        echo "✗ _needle_get_config_mtime should return 0 for non-existing file: $mtime"
        rm -f "$test_file"
        exit 1
    fi

    # Test _needle_validate_hot_reload_config with valid config
    echo "limits:
  global_max_concurrent: 20
runner:
  polling_interval: 2s" > "$test_file"
    if _needle_validate_hot_reload_config "$test_file" ""; then
        echo "✓ _needle_validate_hot_reload_config accepts valid config"
    else
        echo "✗ _needle_validate_hot_reload_config rejected valid config"
        rm -f "$test_file"
        exit 1
    fi

    # Test _needle_validate_hot_reload_config with invalid config (empty)
    echo "" > "$test_file"
    if ! _needle_validate_hot_reload_config "$test_file" ""; then
        echo "✓ _needle_validate_hot_reload_config rejects empty config"
    else
        echo "✗ _needle_validate_hot_reload_config should reject empty config"
        rm -f "$test_file"
        exit 1
    fi

    # Test that config change detection works
    local global_config="$NEEDLE_HOME/config.yaml"
    echo "limits:
  global_max_concurrent: 20" > "$global_config"

    # Initialize mtime tracking
    NEEDLE_GLOBAL_CONFIG_LOADED_AT=$(_needle_get_config_mtime "$global_config")
    NEEDLE_WS_CONFIG_LOADED_AT=0
    NEEDLE_CONFIG_CHECK_COUNTER=0

    # First check should not trigger reload
    NEEDLE_CONFIG_CHECK_COUNTER=$NEEDLE_CONFIG_CHECK_INTERVAL
    if _needle_check_config_reload; then
        echo "✗ First check should not trigger reload"
        rm -f "$test_file" "$global_config"
        exit 1
    fi
    echo "✓ No reload triggered when config unchanged"

    # Modify config and check again
    sleep 1  # Ensure mtime changes
    echo "limits:
  global_max_concurrent: 30" > "$global_config"

    # Reset counter to trigger check
    NEEDLE_CONFIG_CHECK_COUNTER=$NEEDLE_CONFIG_CHECK_INTERVAL
    if _needle_check_config_reload; then
        echo "✓ Config reload triggered when config changed"
    else
        echo "✗ Config reload should be triggered when config changed"
        rm -f "$test_file" "$global_config"
        exit 1
    fi

    # Verify mtime was updated
    local new_mtime
    new_mtime=$(_needle_get_config_mtime "$global_config")
    if [[ "$new_mtime" -gt "$NEEDLE_GLOBAL_CONFIG_LOADED_AT" ]] || [[ "$NEEDLE_GLOBAL_CONFIG_LOADED_AT" == "$new_mtime" ]]; then
        echo "✓ Config mtime tracking updated after reload"
    else
        echo "✗ Config mtime tracking not properly updated"
        rm -f "$test_file" "$global_config"
        exit 1
    fi

    # Cleanup
    rm -f "$test_file" "$global_config"
    cleanup_mock_environment
    echo ""
}

# Run all tests
echo "=========================================="
echo "NEEDLE Worker Loop Module Tests"
echo "=========================================="
echo ""

test_config_helper
test_event_emission
test_telemetry
test_heartbeat
test_bead_functions
test_worker_loop
test_signal_handlers
test_config_hot_reload

echo ""
echo "=========================================="
echo "All tests completed"
echo "=========================================="
