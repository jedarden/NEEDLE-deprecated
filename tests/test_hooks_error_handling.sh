#!/usr/bin/env bash
# Integration tests for hook error handling specification
#
# Tests cover:
#   - on_failure hook behavior and exit code semantics
#   - on_quarantine hook behavior and exit code semantics
#   - fail_action policy (warn | abort | ignore)
#   - Timeout handling across hook points
#   - Error propagation to bead lifecycle
#   - All 11 hook points: exit code contract verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Set up test environment
export NEEDLE_HOME="${TMPDIR:-/tmp}/needle-hooks-error-test-$$"
export NEEDLE_CONFIG_FILE="$NEEDLE_HOME/config.yaml"
export NEEDLE_LOG_INITIALIZED=false
mkdir -p "$NEEDLE_HOME/hooks"

# Source required modules
source "$NEEDLE_ROOT/src/lib/constants.sh"
source "$NEEDLE_ROOT/src/lib/output.sh"
source "$NEEDLE_ROOT/src/lib/paths.sh"
source "$NEEDLE_ROOT/src/lib/json.sh"
source "$NEEDLE_ROOT/src/lib/config.sh"
source "$NEEDLE_ROOT/src/lib/utils.sh"
source "$NEEDLE_ROOT/src/telemetry/events.sh"
source "$NEEDLE_ROOT/src/hooks/runner.sh"

export NEEDLE_VERBOSE="${NEEDLE_VERBOSE:-false}"
export NEEDLE_QUIET="${NEEDLE_QUIET:-true}"
_needle_output_init

TESTS_PASSED=0
TESTS_FAILED=0

_test_start() { echo ""; echo "TEST: $1"; }
_test_pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ PASS: $1"; }
_test_fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ FAIL: $1"; [[ -n "${2:-}" ]] && echo "    Details: $2"; }

make_hook() {
    local name="$1"
    local body="$2"
    local path="$NEEDLE_HOME/hooks/$name"
    printf '#!/bin/bash\n%s\n' "$body" > "$path"
    chmod +x "$path"
    echo "$path"
}

write_cfg() {
    local hook_type="$1"
    local hook_path="$2"
    local timeout="${3:-5s}"
    local fail_action="${4:-warn}"
    cat > "$NEEDLE_CONFIG_FILE" << CONFIGEOF
hooks:
  timeout: $timeout
  fail_action: $fail_action
  $hook_type: $hook_path
CONFIGEOF
    clear_config_cache
}

echo "=== Hook Error Handling Integration Tests ==="

# ============================================================================
# on_failure exit code semantics
# ============================================================================

_test_start "on_failure: exit 0 returns success (retry allowed)"
HOOK=$(make_hook "on-fail-0.sh" "exit 0")
write_cfg "on_failure" "$HOOK"
result=0
_needle_hook_on_failure "bead-fail-0" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure exit 0 → runner returns 0 (retry path)"
else
    _test_fail "on_failure exit 0 should return 0" "got $result"
fi

_test_start "on_failure: exit 1 (warning) returns success (retry allowed)"
HOOK=$(make_hook "on-fail-1.sh" "exit 1")
write_cfg "on_failure" "$HOOK"
result=0
_needle_hook_on_failure "bead-fail-1" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure exit 1 → runner returns 0 (retry path)"
else
    _test_fail "on_failure exit 1 should return 0 (warning, not abort)" "got $result"
fi

_test_start "on_failure: exit 2 (abort) returns failure (forces quarantine)"
HOOK=$(make_hook "on-fail-2.sh" "exit 2")
write_cfg "on_failure" "$HOOK"
result=0
_needle_hook_on_failure "bead-fail-2" 2>/dev/null || result=$?
if [[ "$result" -ne 0 ]]; then
    _test_pass "on_failure exit 2 → runner returns non-zero (quarantine path)"
else
    _test_fail "on_failure exit 2 (abort) should return non-zero to force quarantine"
fi

_test_start "on_failure: exit 3 (skip) returns success (retry allowed)"
HOOK=$(make_hook "on-fail-3.sh" "exit 3")
write_cfg "on_failure" "$HOOK"
result=0
_needle_hook_on_failure "bead-fail-3" 2>/dev/null || result=$?
# exit 3 maps to runner return 2 (skip); caller treats non-abort as retry
if [[ "$result" -ne 1 ]]; then
    _test_pass "on_failure exit 3 → not an abort (skip treated as success for retry)"
else
    _test_fail "on_failure exit 3 should not produce abort return" "got $result"
fi

# ============================================================================
# on_quarantine exit code semantics
# ============================================================================

_test_start "on_quarantine: exit 0 returns success (quarantine proceeds)"
HOOK=$(make_hook "on-quar-0.sh" "exit 0")
write_cfg "on_quarantine" "$HOOK"
result=0
_needle_hook_on_quarantine "bead-quar-0" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_quarantine exit 0 → runner returns 0"
else
    _test_fail "on_quarantine exit 0 should return 0" "got $result"
fi

_test_start "on_quarantine: exit 1 (warning) returns success"
HOOK=$(make_hook "on-quar-1.sh" "exit 1")
write_cfg "on_quarantine" "$HOOK"
result=0
_needle_hook_on_quarantine "bead-quar-1" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_quarantine exit 1 → runner returns 0 (warning only)"
else
    _test_fail "on_quarantine exit 1 should return 0" "got $result"
fi

_test_start "on_quarantine: exit 2 (abort) still returns failure (but quarantine already done)"
HOOK=$(make_hook "on-quar-2.sh" "exit 2")
write_cfg "on_quarantine" "$HOOK"
result=0
_needle_hook_on_quarantine "bead-quar-2" 2>/dev/null || result=$?
# exit 2 propagates as abort from runner — caller is expected to ignore since quarantine is terminal
if [[ "$result" -ne 0 ]]; then
    _test_pass "on_quarantine exit 2 → runner returns non-zero (abort propagated, caller ignores for quarantine)"
else
    _test_fail "on_quarantine exit 2 should propagate abort from runner"
fi

_test_start "on_quarantine: exit 3 (skip) returns skip code"
HOOK=$(make_hook "on-quar-3.sh" "exit 3")
write_cfg "on_quarantine" "$HOOK"
result=0
_needle_hook_on_quarantine "bead-quar-3" 2>/dev/null || result=$?
if [[ "$result" -eq 2 ]]; then
    _test_pass "on_quarantine exit 3 → runner returns 2 (skip)"
else
    _test_fail "on_quarantine exit 3 should return 2 (skip code)" "got $result"
fi

# ============================================================================
# fail_action policy: warn (default)
# ============================================================================

_test_start "fail_action=warn: on_failure unexpected exit (e.g. 5) returns success"
HOOK=$(make_hook "on-fail-warn.sh" "exit 5")
write_cfg "on_failure" "$HOOK" "5s" "warn"
result=0
_needle_hook_on_failure "bead-warn" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "fail_action=warn: unexpected exit → returns 0 (log and continue)"
else
    _test_fail "fail_action=warn: unexpected exit should return 0" "got $result"
fi

_test_start "fail_action=warn: on_quarantine unexpected exit returns success"
HOOK=$(make_hook "on-quar-warn.sh" "exit 7")
write_cfg "on_quarantine" "$HOOK" "5s" "warn"
result=0
_needle_hook_on_quarantine "bead-quar-warn" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "fail_action=warn: on_quarantine unexpected exit → returns 0"
else
    _test_fail "fail_action=warn: on_quarantine unexpected exit should return 0" "got $result"
fi

# ============================================================================
# fail_action policy: abort
# ============================================================================

_test_start "fail_action=abort: on_failure unexpected exit returns failure"
HOOK=$(make_hook "on-fail-abort.sh" "exit 5")
write_cfg "on_failure" "$HOOK" "5s" "abort"
result=0
_needle_hook_on_failure "bead-abort" 2>/dev/null || result=$?
if [[ "$result" -ne 0 ]]; then
    _test_pass "fail_action=abort: unexpected exit → returns non-zero (propagates failure)"
else
    _test_fail "fail_action=abort: unexpected exit should return non-zero" "got $result"
fi

_test_start "fail_action=abort: on_quarantine unexpected exit returns failure"
HOOK=$(make_hook "on-quar-abort.sh" "exit 5")
write_cfg "on_quarantine" "$HOOK" "5s" "abort"
result=0
_needle_hook_on_quarantine "bead-quar-abort" 2>/dev/null || result=$?
if [[ "$result" -ne 0 ]]; then
    _test_pass "fail_action=abort: on_quarantine unexpected exit → non-zero"
else
    _test_fail "fail_action=abort: on_quarantine unexpected exit should be non-zero" "got $result"
fi

# ============================================================================
# fail_action policy: ignore
# ============================================================================

_test_start "fail_action=ignore: on_failure unexpected exit returns success"
HOOK=$(make_hook "on-fail-ignore.sh" "exit 5")
write_cfg "on_failure" "$HOOK" "5s" "ignore"
result=0
_needle_hook_on_failure "bead-ignore" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "fail_action=ignore: unexpected exit → returns 0 (silently ignored)"
else
    _test_fail "fail_action=ignore: unexpected exit should return 0" "got $result"
fi

# ============================================================================
# Timeout behavior
# ============================================================================

_test_start "on_failure timeout + fail_action=warn: returns success (retry path)"
HOOK=$(make_hook "on-fail-slow.sh" "sleep 10; exit 0")
write_cfg "on_failure" "$HOOK" "1s" "warn"
result=0
_needle_hook_on_failure "bead-timeout-warn" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure timeout + fail_action=warn → returns 0 (retry allowed)"
else
    _test_fail "on_failure timeout + fail_action=warn should return 0" "got $result"
fi

_test_start "on_failure timeout + fail_action=abort: returns failure (quarantine path)"
HOOK=$(make_hook "on-fail-slow-abort.sh" "sleep 10; exit 0")
write_cfg "on_failure" "$HOOK" "1s" "abort"
result=0
_needle_hook_on_failure "bead-timeout-abort" 2>/dev/null || result=$?
if [[ "$result" -ne 0 ]]; then
    _test_pass "on_failure timeout + fail_action=abort → non-zero (quarantine path)"
else
    _test_fail "on_failure timeout + fail_action=abort should return non-zero" "got $result"
fi

_test_start "on_quarantine timeout + fail_action=warn: returns success"
HOOK=$(make_hook "on-quar-slow.sh" "sleep 10; exit 0")
write_cfg "on_quarantine" "$HOOK" "1s" "warn"
result=0
_needle_hook_on_quarantine "bead-quar-timeout-warn" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_quarantine timeout + fail_action=warn → returns 0"
else
    _test_fail "on_quarantine timeout + fail_action=warn should return 0" "got $result"
fi

_test_start "on_quarantine timeout + fail_action=abort: returns failure"
HOOK=$(make_hook "on-quar-slow-abort.sh" "sleep 10; exit 0")
write_cfg "on_quarantine" "$HOOK" "1s" "abort"
result=0
_needle_hook_on_quarantine "bead-quar-timeout-abort" 2>/dev/null || result=$?
if [[ "$result" -ne 0 ]]; then
    _test_pass "on_quarantine timeout + fail_action=abort → non-zero"
else
    _test_fail "on_quarantine timeout + fail_action=abort should return non-zero" "got $result"
fi

# ============================================================================
# Exit code contract: all 11 hook points
# ============================================================================

_test_start "Exit code contract: all hook points accept exit 0"
ALL_HOOKS=(pre_claim post_claim pre_execute post_execute pre_complete post_complete
           on_failure on_quarantine pre_commit post_task error_recovery)
all_ok=true
for hook_type in "${ALL_HOOKS[@]}"; do
    HOOK=$(make_hook "contract-0-${hook_type//_/-}.sh" "exit 0")
    write_cfg "$hook_type" "$HOOK"
    result=0
    _needle_run_hook "$hook_type" "contract-test" 2>/dev/null || result=$?
    if [[ "$result" -ne 0 ]]; then
        _test_fail "exit 0 should return 0 for $hook_type" "got $result"
        all_ok=false
    fi
done
[[ "$all_ok" == "true" ]] && _test_pass "All 11 hook points return 0 for exit 0"

_test_start "Exit code contract: all hook points accept exit 1 as non-fatal"
all_ok=true
for hook_type in "${ALL_HOOKS[@]}"; do
    HOOK=$(make_hook "contract-1-${hook_type//_/-}.sh" "exit 1")
    write_cfg "$hook_type" "$HOOK"
    result=0
    _needle_run_hook "$hook_type" "contract-test" 2>/dev/null || result=$?
    if [[ "$result" -ne 0 ]]; then
        _test_fail "exit 1 should return 0 (warning) for $hook_type" "got $result"
        all_ok=false
    fi
done
[[ "$all_ok" == "true" ]] && _test_pass "All 11 hook points treat exit 1 as warning (return 0)"

_test_start "Exit code contract: all hook points propagate exit 2 as abort"
all_ok=true
for hook_type in "${ALL_HOOKS[@]}"; do
    HOOK=$(make_hook "contract-2-${hook_type//_/-}.sh" "exit 2")
    write_cfg "$hook_type" "$HOOK"
    result=0
    _needle_run_hook "$hook_type" "contract-test" 2>/dev/null || result=$?
    if [[ "$result" -eq 0 ]]; then
        _test_fail "exit 2 should return non-zero (abort) for $hook_type" "got 0"
        all_ok=false
    fi
done
[[ "$all_ok" == "true" ]] && _test_pass "All 11 hook points propagate exit 2 as abort (non-zero)"

_test_start "Exit code contract: all hook points return 2 for exit 3 (skip)"
all_ok=true
for hook_type in "${ALL_HOOKS[@]}"; do
    HOOK=$(make_hook "contract-3-${hook_type//_/-}.sh" "exit 3")
    write_cfg "$hook_type" "$HOOK"
    result=0
    _needle_run_hook "$hook_type" "contract-test" 2>/dev/null || result=$?
    if [[ "$result" -ne 2 ]]; then
        _test_fail "exit 3 should return 2 (skip) for $hook_type" "got $result"
        all_ok=false
    fi
done
[[ "$all_ok" == "true" ]] && _test_pass "All 11 hook points return 2 for exit 3 (skip)"

# ============================================================================
# Environment variables propagated to on_failure and on_quarantine
# ============================================================================

_test_start "on_failure: NEEDLE_BEAD_ID is set in hook environment"
HOOK=$(make_hook "on-fail-env.sh" '[[ "$NEEDLE_BEAD_ID" == "bead-env-test" ]] || exit 99')
write_cfg "on_failure" "$HOOK"
result=0
_needle_hook_on_failure "bead-env-test" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure: NEEDLE_BEAD_ID correctly set in hook env"
else
    _test_fail "on_failure: NEEDLE_BEAD_ID not set correctly" "hook exited $result"
fi

_test_start "on_quarantine: NEEDLE_HOOK is set to 'on_quarantine'"
HOOK=$(make_hook "on-quar-env.sh" '[[ "$NEEDLE_HOOK" == "on_quarantine" ]] || exit 99')
write_cfg "on_quarantine" "$HOOK"
result=0
_needle_hook_on_quarantine "bead-env-quar" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_quarantine: NEEDLE_HOOK env var set to 'on_quarantine'"
else
    _test_fail "on_quarantine: NEEDLE_HOOK not set to 'on_quarantine'" "hook exited $result"
fi

_test_start "on_failure: NEEDLE_HOOK is set to 'on_failure'"
HOOK=$(make_hook "on-fail-hook-env.sh" '[[ "$NEEDLE_HOOK" == "on_failure" ]] || exit 99')
write_cfg "on_failure" "$HOOK"
result=0
_needle_hook_on_failure "bead-hook-env" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure: NEEDLE_HOOK env var set to 'on_failure'"
else
    _test_fail "on_failure: NEEDLE_HOOK not set to 'on_failure'" "hook exited $result"
fi

# ============================================================================
# Lock release guarantee: on_failure always releases locks
# ============================================================================

_test_start "on_failure always releases locks even when hook fails"
# Create a hook that exits 2 (abort) — locks should still be released
HOOK=$(make_hook "on-fail-lock-abort.sh" "exit 2")
write_cfg "on_failure" "$HOOK"
# The _needle_hook_on_failure function must call _needle_release_bead_locks_on_close
# We verify the function itself calls _needle_release_bead_locks_on_close
if declare -f _needle_hook_on_failure | grep -q "_needle_release_bead_locks_on_close"; then
    _test_pass "on_failure function calls _needle_release_bead_locks_on_close (lock release guaranteed)"
else
    _test_fail "on_failure must call _needle_release_bead_locks_on_close"
fi

_test_start "post_complete always releases locks"
if declare -f _needle_hook_post_complete | grep -q "_needle_release_bead_locks_on_close"; then
    _test_pass "post_complete function calls _needle_release_bead_locks_on_close"
else
    _test_fail "post_complete must call _needle_release_bead_locks_on_close"
fi

# ============================================================================
# Hook not configured: non-configured hook points return success
# ============================================================================

_test_start "on_failure: returns success when no hook configured"
cat > "$NEEDLE_CONFIG_FILE" << CONFIGEOF
hooks:
  timeout: 5s
  fail_action: warn
CONFIGEOF
clear_config_cache
result=0
_needle_hook_on_failure "bead-no-hook" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure with no hook configured returns 0 (no-op)"
else
    _test_fail "on_failure with no hook should return 0" "got $result"
fi

_test_start "on_quarantine: returns success when no hook configured"
result=0
_needle_hook_on_quarantine "bead-no-hook" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_quarantine with no hook configured returns 0 (no-op)"
else
    _test_fail "on_quarantine with no hook should return 0" "got $result"
fi

# ============================================================================
# Hook file missing: returns success (graceful degradation)
# ============================================================================

_test_start "on_failure: returns success when hook file not found"
write_cfg "on_failure" "/nonexistent/on-failure.sh"
result=0
_needle_hook_on_failure "bead-missing-hook" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_failure with missing hook file returns 0 (graceful degradation)"
else
    _test_fail "on_failure with missing file should return 0" "got $result"
fi

_test_start "on_quarantine: returns success when hook file not found"
write_cfg "on_quarantine" "/nonexistent/on-quarantine.sh"
result=0
_needle_hook_on_quarantine "bead-missing-quar" 2>/dev/null || result=$?
if [[ "$result" -eq 0 ]]; then
    _test_pass "on_quarantine with missing hook file returns 0 (graceful degradation)"
else
    _test_fail "on_quarantine with missing file should return 0" "got $result"
fi

# ============================================================================
# Cleanup
# ============================================================================
rm -rf "$NEEDLE_HOME"

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed!"
    exit 1
fi
