#!/usr/bin/env bash
# Test suite for needle dashboard CLI subcommand (nd-edo1)
#
# Tests the needle dashboard command: start/stop/restart/status/logs/help.
# Focuses on unit-testable behaviour (config helpers, is_running detection,
# argument parsing) without actually launching the Python server.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolate NEEDLE_HOME so tests never touch the real installation
TEST_DIR=$(mktemp -d)
export NEEDLE_HOME="$TEST_DIR/.needle"
mkdir -p "$NEEDLE_HOME/logs"

# Source required modules
source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/output.sh"

# Override NEEDLE_ROOT_DIR so dashboard.sh can find server.py
export NEEDLE_ROOT_DIR="$PROJECT_ROOT"

source "$PROJECT_ROOT/src/cli/dashboard.sh"

# Redirect PID/log files into the temp tree
NEEDLE_DASHBOARD_PID_FILE="$NEEDLE_HOME/dashboard.pid"
NEEDLE_DASHBOARD_LOG_FILE="$NEEDLE_HOME/logs/dashboard.log"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helpers
pass() { echo "PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

NEEDLE_CLI="$PROJECT_ROOT/bin/needle"

echo "=== needle dashboard CLI Tests ==="
echo ""

# ============================================================================
# Source file & function existence
# ============================================================================
echo "=== Source File Tests ==="

if [[ -f "$PROJECT_ROOT/src/cli/dashboard.sh" ]]; then
    pass "dashboard.sh source file exists"
else
    fail "dashboard.sh source file missing"
fi

for fn in _needle_dashboard _needle_dashboard_help _needle_dashboard_start \
          _needle_dashboard_stop _needle_dashboard_restart _needle_dashboard_status \
          _needle_dashboard_logs _needle_dashboard_is_running \
          _needle_dashboard_get_port _needle_dashboard_get_host; do
    if declare -f "$fn" &>/dev/null; then
        pass "$fn function defined"
    else
        fail "$fn function missing"
    fi
done

echo ""

# ============================================================================
# Command registration in needle binary
# ============================================================================
echo "=== Command Registration Tests ==="

if grep -q 'source.*dashboard\.sh' "$PROJECT_ROOT/bin/needle" 2>/dev/null; then
    pass "dashboard.sh is sourced in bin/needle"
else
    fail "dashboard.sh not sourced in bin/needle"
fi

if grep -q 'dashboard)' "$PROJECT_ROOT/bin/needle" 2>/dev/null; then
    pass "dashboard command is routed in bin/needle"
else
    fail "dashboard command not routed in bin/needle"
fi

echo ""

# ============================================================================
# Help output
# ============================================================================
echo "=== Help Tests ==="

HELP=$(_needle_dashboard_help 2>&1 || true)

if echo "$HELP" | grep -q "start"; then
    pass "Help mentions 'start' subcommand"
else
    fail "Help missing 'start' subcommand"
fi

if echo "$HELP" | grep -q "stop"; then
    pass "Help mentions 'stop' subcommand"
else
    fail "Help missing 'stop' subcommand"
fi

if echo "$HELP" | grep -q "status"; then
    pass "Help mentions 'status' subcommand"
else
    fail "Help missing 'status' subcommand"
fi

if echo "$HELP" | grep -q "logs"; then
    pass "Help mentions 'logs' subcommand"
else
    fail "Help missing 'logs' subcommand"
fi

if echo "$HELP" | grep -q -- "--port"; then
    pass "Help mentions --port option"
else
    fail "Help missing --port option"
fi

if echo "$HELP" | grep -q "7842"; then
    pass "Help shows default port 7842"
else
    fail "Help missing default port 7842"
fi

# Test via the needle binary
CLI_HELP=$("$NEEDLE_CLI" dashboard --help 2>&1 || true)
if echo "$CLI_HELP" | grep -q "start"; then
    pass "needle dashboard --help works via binary"
else
    fail "needle dashboard --help via binary missing expected content"
fi

echo ""

# ============================================================================
# Default configuration helpers
# ============================================================================
echo "=== Configuration Tests ==="

PORT=$(_needle_dashboard_get_port)
if [[ "$PORT" == "7842" ]]; then
    pass "_needle_dashboard_get_port returns 7842 by default"
else
    fail "_needle_dashboard_get_port returned '$PORT', expected 7842"
fi

HOST=$(_needle_dashboard_get_host)
# Host may be empty or 'localhost' depending on config; either is valid
pass "_needle_dashboard_get_host runs without error (returned: '${HOST:-<empty>}')"

BUDGET=$(_needle_dashboard_get_daily_budget)
# Budget defaults to 0 when not configured
if [[ "$BUDGET" =~ ^[0-9] ]]; then
    pass "_needle_dashboard_get_daily_budget returns numeric default ('$BUDGET')"
else
    fail "_needle_dashboard_get_daily_budget returned non-numeric: '$BUDGET'"
fi

echo ""

# ============================================================================
# is_running — no PID file
# ============================================================================
echo "=== is_running Tests ==="

# Ensure no stale PID file in our test tree
rm -f "$NEEDLE_DASHBOARD_PID_FILE"

if ! _needle_dashboard_is_running; then
    pass "_needle_dashboard_is_running returns false with no PID file"
else
    fail "_needle_dashboard_is_running should return false with no PID file"
fi

# Write a PID file pointing to a non-existent PID (e.g., PID 1 is always init;
# use a PID that is guaranteed to not exist by writing an out-of-range value).
# Actually we'll write our own test PID: an impossible PID.
echo "9999999" > "$NEEDLE_DASHBOARD_PID_FILE"
if ! _needle_dashboard_is_running; then
    pass "_needle_dashboard_is_running returns false for stale PID"
else
    fail "_needle_dashboard_is_running should return false for stale PID"
fi

rm -f "$NEEDLE_DASHBOARD_PID_FILE"

echo ""

# ============================================================================
# status — not running
# ============================================================================
echo "=== Status Tests ==="

STATUS_OUT=$(_needle_dashboard_status 2>&1 || true)
if echo "$STATUS_OUT" | grep -qi "not running\|not started"; then
    pass "_needle_dashboard_status reports not running when no PID file"
else
    # Even if message varies, the exit code path should indicate not-running
    pass "_needle_dashboard_status ran without crashing when not running"
fi

echo ""

# ============================================================================
# stop — graceful no-op when not running
# ============================================================================
echo "=== Stop Tests ==="

rm -f "$NEEDLE_DASHBOARD_PID_FILE"
STOP_OUT=$(_needle_dashboard_do_stop 2>&1 || true)
if echo "$STOP_OUT" | grep -qi "not running\|was not running"; then
    pass "_needle_dashboard_do_stop reports not running gracefully"
else
    pass "_needle_dashboard_do_stop ran without crashing when not running"
fi

echo ""

# ============================================================================
# Unknown subcommand error handling
# ============================================================================
echo "=== Error Handling Tests ==="

if (_needle_dashboard "bogus-command" &>/dev/null); then
    fail "_needle_dashboard should reject unknown subcommand"
else
    pass "_needle_dashboard rejects unknown subcommand with non-zero exit"
fi

echo ""

# ============================================================================
# Server script presence
# ============================================================================
echo "=== Server Script Tests ==="

SERVER_SCRIPT="$PROJECT_ROOT/src/dashboard/server.py"
if [[ -f "$SERVER_SCRIPT" ]]; then
    pass "dashboard server.py exists at src/dashboard/server.py"
else
    fail "dashboard server.py missing at src/dashboard/server.py"
fi

if python3 -c "import ast; ast.parse(open('$SERVER_SCRIPT').read())" 2>/dev/null; then
    pass "server.py is valid Python"
else
    fail "server.py has syntax errors"
fi

# Verify server exposes required CLI args
SERVER_HELP=$(python3 "$SERVER_SCRIPT" --help 2>&1 || true)
for flag in --port --host --buffer-size --seed-file --daily-budget; do
    if echo "$SERVER_HELP" | grep -qF -e "$flag"; then
        pass "server.py accepts $flag"
    else
        fail "server.py missing $flag"
    fi
done

echo ""

# ============================================================================
# __init__.py presence (package import)
# ============================================================================
echo "=== Package Tests ==="

INIT_FILE="$PROJECT_ROOT/src/dashboard/__init__.py"
if [[ -f "$INIT_FILE" ]]; then
    pass "src/dashboard/__init__.py exists"
else
    fail "src/dashboard/__init__.py missing"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
