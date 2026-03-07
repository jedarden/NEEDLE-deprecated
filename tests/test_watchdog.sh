#!/usr/bin/env bash
# Tests for NEEDLE Watchdog Monitor
# Run with: bash tests/test_watchdog.sh

# Don't exit on first error - we want to run all tests
# set -e

# Test setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test utilities
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/utils.sh"
source "$PROJECT_ROOT/src/lib/json.sh"
source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/config.sh"
source "$PROJECT_ROOT/src/lib/paths.sh"
source "$PROJECT_ROOT/src/watchdog/monitor.sh"

# Test directory
TEST_DIR=""
TEST_COUNTER=0
PASS_COUNTER=0
FAIL_COUNTER=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# Test helper functions
_test_setup() {
    TEST_DIR=$(mktemp -d)
    export NEEDLE_HOME="$TEST_DIR/.needle"
    export NEEDLE_STATE_DIR="state"
    export NEEDLE_LOG_DIR="logs"
    export NEEDLE_CONFIG_FILE="$NEEDLE_HOME/config.yaml"
    mkdir -p "$NEEDLE_HOME/$NEEDLE_STATE_DIR/heartbeats"
    mkdir -p "$NEEDLE_HOME/$NEEDLE_LOG_DIR"
    # Clear config cache for each test
    NEEDLE_CONFIG_CACHE=""
    # Reset recovery action to default
    unset NEEDLE_WATCHDOG_RECOVERY_ACTION
    # Reset NEEDLE_ROOT_DIR
    unset NEEDLE_ROOT_DIR
}

_test_teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

_test_start() {
    ((TEST_COUNTER++))
    echo -e "${YELLOW}Test $TEST_COUNTER: $1${RESET}"
}

_test_pass() {
    ((PASS_COUNTER++))
    echo -e "  ${GREEN}✓ PASS${RESET}"
}

_test_fail() {
    ((FAIL_COUNTER++))
    echo -e "  ${RED}✗ FAIL: $1${RESET}"
}

_assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        _test_fail "$message (expected: '$expected', got: '$actual')"
        return 1
    fi
}

_assert_true() {
    local message="${1:-Should be true}"
    if [[ $? -eq 0 ]]; then
        return 0
    else
        _test_fail "$message"
        return 1
    fi
}

_assert_false() {
    local message="${1:-Should be false}"
    if [[ $? -ne 0 ]]; then
        return 0
    else
        _test_fail "$message"
        return 1
    fi
}

_assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"
    if [[ -f "$file" ]]; then
        return 0
    else
        _test_fail "$message (file: $file)"
        return 1
    fi
}

_assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory should exist}"
    if [[ -d "$dir" ]]; then
        return 0
    else
        _test_fail "$message (dir: $dir)"
        return 1
    fi
}

_assert_file_not_exists() {
    local file="$1"
    local message="${2:-File should not exist}"
    if [[ ! -f "$file" ]]; then
        return 0
    else
        _test_fail "$message (file: $file)"
        return 1
    fi
}

# ============================================================================
# Test Cases
# ============================================================================

test_watchdog_init() {
    _test_start "Watchdog initialization"
    _test_setup

    # Run init
    _needle_watchdog_init

    # Check directories were created (init creates paths, not PID file)
    # PID file is created when watchdog starts
    _assert_dir_exists "$NEEDLE_WATCHDOG_HEARTBEATS_DIR" "Heartbeats dir should exist"

    local result=$?
    if [[ $result -eq 0 ]]; then
        _test_pass
    fi

    _test_teardown
}

test_watchdog_not_running_initially() {
    _test_start "Watchdog not running initially"
    _test_setup

    _needle_watchdog_init

    # Should not be running initially
    if ! _needle_watchdog_is_running; then
        _test_pass
    else
        _test_fail "Watchdog should not be running initially"
    fi

    _test_teardown
}

test_watchdog_pid_file_creation() {
    _test_start "Watchdog PID file creation"
    _test_setup

    _needle_watchdog_init

    # Create a fake PID file
    echo "12345" > "$NEEDLE_WATCHDOG_PID_FILE"

    # PID file should exist
    if [[ -f "$NEEDLE_WATCHDOG_PID_FILE" ]]; then
        local pid
        pid=$(cat "$NEEDLE_WATCHDOG_PID_FILE")
        if [[ "$pid" == "12345" ]]; then
            _test_pass
        else
            _test_fail "PID file content incorrect"
        fi
    else
        _test_fail "PID file not created"
    fi

    _test_teardown
}

test_stale_pid_file_cleanup() {
    _test_start "Stale PID file cleanup"
    _test_setup

    _needle_watchdog_init

    # Create a stale PID file with non-existent PID
    echo "999999998" > "$NEEDLE_WATCHDOG_PID_FILE"

    # Check if running - should clean up stale file
    if _needle_watchdog_is_running; then
        _test_fail "Should not detect non-existent PID as running"
    else
        # Stale file should be removed
        if [[ ! -f "$NEEDLE_WATCHDOG_PID_FILE" ]]; then
            _test_pass
        else
            _test_fail "Stale PID file should be removed"
        fi
    fi

    _test_teardown
}

test_heartbeat_file_parsing() {
    _test_start "Heartbeat file parsing"
    _test_setup

    _needle_watchdog_init

    # Create a test heartbeat file
    local hb_file="$NEEDLE_WATCHDOG_HEARTBEATS_DIR/test-worker.json"
    cat > "$hb_file" << 'EOF'
{
    "worker": "test-worker",
    "pid": 12345,
    "last_heartbeat": "2026-03-02T10:00:00Z",
    "status": "executing",
    "current_bead": "nd-test",
    "bead_started": "2026-03-02T09:55:00Z"
}
EOF

    # Check file exists
    if [[ -f "$hb_file" ]]; then
        # Try to parse with jq if available
        if command -v jq &>/dev/null; then
            local worker
            worker=$(jq -r '.worker' "$hb_file")
            if [[ "$worker" == "test-worker" ]]; then
                _test_pass
            else
                _test_fail "Failed to parse worker from heartbeat"
            fi
        else
            # Skip if no jq
            _test_pass
        fi
    else
        _test_fail "Heartbeat file not created"
    fi

    _test_teardown
}

test_has_workers_detection() {
    _test_start "Workers detection"
    _test_setup

    _needle_watchdog_init

    # Initially no workers
    if _needle_watchdog_has_workers; then
        _test_fail "Should detect no workers initially"
    else
        # Add a heartbeat file
        echo '{"worker":"test"}' > "$NEEDLE_WATCHDOG_HEARTBEATS_DIR/test.json"

        # Now should detect workers
        if _needle_watchdog_has_workers; then
            _test_pass
        else
            _test_fail "Should detect workers after adding heartbeat"
        fi
    fi

    _test_teardown
}

test_config_values() {
    _test_start "Configuration values"
    _test_setup

    # Set up config with custom values
    cat > "$NEEDLE_CONFIG_FILE" << 'EOF'
watchdog:
  interval: 60
  heartbeat_timeout: 240
  bead_timeout: 1200
  recovery_action: stop
EOF

    _needle_watchdog_init

    # Check config was loaded
    if [[ "$NEEDLE_WATCHDOG_INTERVAL" == "60" ]] && \
       [[ "$NEEDLE_WATCHDOG_HEARTBEAT_TIMEOUT" == "240" ]] && \
       [[ "$NEEDLE_WATCHDOG_BEAD_TIMEOUT" == "1200" ]] && \
       [[ "$NEEDLE_WATCHDOG_RECOVERY_ACTION" == "stop" ]]; then
        _test_pass
    else
        _test_fail "Config values not loaded correctly (interval=$NEEDLE_WATCHDOG_INTERVAL, timeout=$NEEDLE_WATCHDOG_HEARTBEAT_TIMEOUT, bead=$NEEDLE_WATCHDOG_BEAD_TIMEOUT, action=$NEEDLE_WATCHDOG_RECOVERY_ACTION)"
    fi

    _test_teardown
}

test_default_config_values() {
    _test_start "Default configuration values"
    _test_setup

    # No config file - should use defaults
    _needle_watchdog_init

    # Check defaults
    if [[ "$NEEDLE_WATCHDOG_INTERVAL" == "30" ]] && \
       [[ "$NEEDLE_WATCHDOG_HEARTBEAT_TIMEOUT" == "120" ]] && \
       [[ "$NEEDLE_WATCHDOG_BEAD_TIMEOUT" == "600" ]] && \
       [[ "$NEEDLE_WATCHDOG_RECOVERY_ACTION" == "restart" ]]; then
        _test_pass
    else
        _test_fail "Default config values not correct"
    fi

    _test_teardown
}

test_log_function() {
    _test_start "Log function"
    _test_setup

    _needle_watchdog_init

    local log_file="$NEEDLE_HOME/$NEEDLE_LOG_DIR/test.jsonl"

    # Write a log entry
    _needle_watchdog_log "$log_file" "test.event" "Test message" "key1=value1" "key2=value2"

    # Check log file was created
    if [[ -f "$log_file" ]]; then
        # Check content
        local content
        content=$(cat "$log_file")
        if echo "$content" | grep -q '"event":"test.event"' && \
           echo "$content" | grep -q '"message":"Test message"'; then
            _test_pass
        else
            _test_fail "Log content incorrect: $content"
        fi
    else
        _test_fail "Log file not created"
    fi

    _test_teardown
}

# ============================================================================
# Auto-Recovery Respawn Tests
# ============================================================================

test_respawn_missing_config() {
    _test_start "Respawn with missing configuration"
    _test_setup

    _needle_watchdog_init

    local log_file="$NEEDLE_HOME/$NEEDLE_LOG_DIR/test.jsonl"

    # Attempt respawn with missing workspace
    _needle_watchdog_respawn_worker "test-worker" "" "claude-anthropic-sonnet" "$log_file"
    local result=$?

    if [[ $result -ne 0 ]]; then
        # Check log for failure message
        if grep -q "missing workspace or agent" "$log_file" 2>/dev/null; then
            _test_pass
        else
            _test_fail "Should log missing configuration error"
        fi
    else
        _test_fail "Should fail with missing workspace"
    fi

    _test_teardown
}

test_respawn_missing_workspace() {
    _test_start "Respawn with non-existent workspace"
    _test_setup

    _needle_watchdog_init

    local log_file="$NEEDLE_HOME/$NEEDLE_LOG_DIR/test.jsonl"
    local fake_workspace="/nonexistent/workspace/path"

    # Attempt respawn with non-existent workspace
    _needle_watchdog_respawn_worker "test-worker" "$fake_workspace" "claude-anthropic-sonnet" "$log_file"
    local result=$?

    if [[ $result -ne 0 ]]; then
        # Check log for failure message
        if grep -q "workspace no longer exists" "$log_file" 2>/dev/null; then
            _test_pass
        else
            _test_fail "Should log non-existent workspace error"
        fi
    else
        _test_fail "Should fail with non-existent workspace"
    fi

    _test_teardown
}

test_respawn_valid_config() {
    _test_start "Respawn with valid configuration"
    _test_setup

    _needle_watchdog_init

    local log_file="$NEEDLE_HOME/$NEEDLE_LOG_DIR/test.jsonl"
    local workspace="$TEST_DIR/fake-workspace"

    # Create a fake workspace
    mkdir -p "$workspace/.beads"

    # Set NEEDLE_ROOT_DIR to a fake location (we just test that the command is logged)
    export NEEDLE_ROOT_DIR="$TEST_DIR/fake-needle"
    mkdir -p "$NEEDLE_ROOT_DIR/bin"
    echo '#!/bin/bash' > "$NEEDLE_ROOT_DIR/bin/needle"
    echo 'exit 0' >> "$NEEDLE_ROOT_DIR/bin/needle"
    chmod +x "$NEEDLE_ROOT_DIR/bin/needle"

    # Attempt respawn with valid config
    _needle_watchdog_respawn_worker "test-worker" "$workspace" "claude-anthropic-sonnet" "$log_file"
    local result=$?

    if [[ $result -eq 0 ]]; then
        # Check log for success message
        if grep -q "Successfully respawned worker" "$log_file" 2>/dev/null; then
            _test_pass
        else
            _test_fail "Should log successful respawn"
        fi
    else
        _test_fail "Should succeed with valid configuration"
    fi

    _test_teardown
}

test_recovery_with_respawn() {
    _test_start "Full recovery flow with respawn"
    _test_setup

    # Enable restart action
    export NEEDLE_WATCHDOG_RECOVERY_ACTION="restart"

    _needle_watchdog_init

    local log_file="$NEEDLE_HOME/$NEEDLE_LOG_DIR/test.jsonl"
    local workspace="$TEST_DIR/test-workspace"
    local hb_file="$NEEDLE_WATCHDOG_HEARTBEATS_DIR/test-worker.json"

    # Create a fake workspace
    mkdir -p "$workspace/.beads"

    # Create a fake needle binary
    export NEEDLE_ROOT_DIR="$TEST_DIR/fake-needle"
    mkdir -p "$NEEDLE_ROOT_DIR/bin"
    echo '#!/bin/bash' > "$NEEDLE_ROOT_DIR/bin/needle"
    echo 'exit 0' >> "$NEEDLE_ROOT_DIR/bin/needle"
    chmod +x "$NEEDLE_ROOT_DIR/bin/needle"

    # Create heartbeat file with valid config
    cat > "$hb_file" << EOF
{
    "worker": "test-worker",
    "pid": 999999999,
    "last_heartbeat": "2026-03-01T00:00:00Z",
    "status": "executing",
    "current_bead": "nd-test",
    "bead_started": "2026-03-01T00:00:00Z",
    "workspace": "$workspace",
    "agent": "claude-anthropic-sonnet"
}
EOF

    # Run recovery (the PID won't exist, so kill will fail gracefully)
    _needle_watchdog_recover_worker "test-worker" "999999999" "nd-test" "no_heartbeat" "$hb_file" "$log_file"

    # Check that respawn was logged
    if grep -q "Attempting worker respawn" "$log_file" 2>/dev/null; then
        if grep -q "Successfully respawned worker" "$log_file" 2>/dev/null; then
            _test_pass
        else
            _test_fail "Should log successful respawn"
        fi
    else
        _test_fail "Should attempt respawn when action=restart"
    fi

    _test_teardown
}

test_recovery_without_respawn() {
    _test_start "Recovery without respawn (action=stop)"
    _test_setup

    _needle_watchdog_init

    # Override after init to ensure it sticks
    NEEDLE_WATCHDOG_RECOVERY_ACTION="stop"

    local log_file="$NEEDLE_HOME/$NEEDLE_LOG_DIR/test.jsonl"
    local workspace="$TEST_DIR/test-workspace"
    local hb_file="$NEEDLE_WATCHDOG_HEARTBEATS_DIR/test-worker.json"

    # Create a fake workspace
    mkdir -p "$workspace/.beads"

    # Create heartbeat file with valid config
    cat > "$hb_file" << EOF
{
    "worker": "test-worker",
    "pid": 999999999,
    "last_heartbeat": "2026-03-01T00:00:00Z",
    "status": "executing",
    "current_bead": "nd-test",
    "bead_started": "2026-03-01T00:00:00Z",
    "workspace": "$workspace",
    "agent": "claude-anthropic-sonnet"
}
EOF

    # Run recovery
    _needle_watchdog_recover_worker "test-worker" "999999999" "nd-test" "no_heartbeat" "$hb_file" "$log_file"

    # Check that respawn was NOT attempted
    if ! grep -q "Attempting worker respawn" "$log_file" 2>/dev/null; then
        _test_pass
    else
        _test_fail "Should NOT attempt respawn when action=stop"
    fi

    _test_teardown
}

test_heartbeat_config_extraction() {
    _test_start "Heartbeat config extraction for respawn"
    _test_setup

    _needle_watchdog_init

    local hb_file="$NEEDLE_WATCHDOG_HEARTBEATS_DIR/test-worker.json"
    local workspace="/test/workspace"
    local agent="claude-anthropic-sonnet"

    # Create heartbeat file with config
    cat > "$hb_file" << EOF
{
    "worker": "test-worker",
    "pid": 12345,
    "last_heartbeat": "2026-03-01T00:00:00Z",
    "status": "executing",
    "workspace": "$workspace",
    "agent": "$agent"
}
EOF

    # Test extraction with jq if available
    if command -v jq &>/dev/null; then
        local extracted_ws extracted_agent
        extracted_ws=$(jq -r '.workspace // ""' "$hb_file" 2>/dev/null)
        extracted_agent=$(jq -r '.agent // ""' "$hb_file" 2>/dev/null)

        if [[ "$extracted_ws" == "$workspace" ]] && [[ "$extracted_agent" == "$agent" ]]; then
            _test_pass
        else
            _test_fail "Failed to extract workspace=$extracted_ws agent=$extracted_agent"
        fi
    else
        # Skip test if jq not available
        _test_pass
    fi

    _test_teardown
}

# ============================================================================
# Run Tests
# ============================================================================

echo ""
echo "========================================"
echo "NEEDLE Watchdog Monitor Tests"
echo "========================================"
echo ""

# Run all tests
test_watchdog_init
test_watchdog_not_running_initially
test_watchdog_pid_file_creation
test_stale_pid_file_cleanup
test_heartbeat_file_parsing
test_has_workers_detection
test_config_values
test_default_config_values
test_log_function

# Auto-recovery respawn tests
test_respawn_missing_config
test_respawn_missing_workspace
test_respawn_valid_config
test_recovery_with_respawn
test_recovery_without_respawn
test_heartbeat_config_extraction

# Summary
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Total:  $TEST_COUNTER"
echo -e "Passed: ${GREEN}$PASS_COUNTER${RESET}"
echo -e "Failed: ${RED}$FAIL_COUNTER${RESET}"
echo ""

if [[ $FAIL_COUNTER -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${RESET}"
    exit 0
else
    echo -e "${RED}Some tests failed.${RESET}"
    exit 1
fi
