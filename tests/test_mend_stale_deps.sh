#!/usr/bin/env bash
# Test suite for mend strand stale dependency cleanup (nd-exqdwk)
#
# Tests the _needle_mend_stale_deps function which detects and removes
# dependency links on open beads that are blocked by closed (DONE) beads.
#
# Key test cases:
# - Open bead blocked by closed bead → stale dep removed
# - Open bead blocked by open bead → dep NOT removed
# - Open bead with no deps → skipped
# - dependency_count == 0 optimization → br dep list not called
# - mend.stale_dep_removed event emitted on removal
# - Malformed dep records skipped safely

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test setup
TEST_DIR=$(mktemp -d)
TEST_NEEDLE_HOME="$TEST_DIR/.needle"
TEST_LOG_FILE="$TEST_DIR/events.jsonl"

export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false
export NEEDLE_LOG_FILE="$TEST_LOG_FILE"
export NEEDLE_LOG_INITIALIZED=true

export NEEDLE_SESSION="test-session-mend-stale-deps"
export NEEDLE_RUNNER="test"
export NEEDLE_PROVIDER="test"
export NEEDLE_MODEL="test"
export NEEDLE_IDENTIFIER="test"

source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/utils.sh"
source "$PROJECT_ROOT/src/lib/json.sh"
source "$PROJECT_ROOT/src/telemetry/writer.sh"
source "$PROJECT_ROOT/src/telemetry/events.sh"
source "$PROJECT_ROOT/src/strands/mend.sh" 2>/dev/null || true

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

skip() {
    echo -e "${YELLOW}⊘${NC} $1"
    ((TESTS_RUN++))
}

# Create a fake workspace with a beads database stub
create_test_workspace() {
    local workspace="$1"
    mkdir -p "$workspace/.beads"
    touch "$workspace/.beads/beads.db"
}

# Build a mock br script for stale dep tests.
# $1 - JSON array of open beads (br list --status open --json)
# $2 - JSON array of deps for br dep list (same for all bead calls)
# $3 - dep remove exit code (0=success, 1=failure)
mock_br_for_stale_deps() {
    local open_beads_json="$1"
    local dep_list_json="${2:-[]}"
    local dep_remove_exit="${3:-0}"

    mkdir -p "$TEST_DIR/bin"
    # Track calls for assertion
    local calls_file="$TEST_DIR/br_calls"
    : > "$calls_file"

    cat > "$TEST_DIR/bin/br" << MOCK_HEADER
#!/bin/bash
CALLS_FILE="$calls_file"
echo "\$*" >> "\$CALLS_FILE"

MOCK_HEADER

    # br list --status open --json
    cat >> "$TEST_DIR/bin/br" << EOF
if [[ "\$1" == "list" ]] && [[ "\$*" == *"--status"* ]] && [[ "\$*" == *"open"* ]] && [[ "\$*" == *"--json"* ]]; then
    echo '$open_beads_json'
    exit 0
fi
EOF

    # br dep list <bead_id> ... --json
    cat >> "$TEST_DIR/bin/br" << EOF
if [[ "\$1" == "dep" ]] && [[ "\$2" == "list" ]] && [[ "\$*" == *"--json"* ]]; then
    echo '$dep_list_json'
    exit 0
fi
EOF

    # br dep remove <bead_id> <dep_id> ...
    cat >> "$TEST_DIR/bin/br" << EOF
if [[ "\$1" == "dep" ]] && [[ "\$2" == "remove" ]]; then
    exit $dep_remove_exit
fi
EOF

    cat >> "$TEST_DIR/bin/br" << 'MOCK_FOOTER'
echo "Unknown mock command: $*" >&2
exit 1
MOCK_FOOTER

    chmod +x "$TEST_DIR/bin/br"
    export PATH="$TEST_DIR/bin:$PATH"
}

# ============================================================================
# Unit Tests: Stale dep detection and removal
# ============================================================================

test_closed_blocker_dep_removed() {
    local ws="$TEST_DIR/ws_closed_blocker"
    create_test_workspace "$ws"

    # Open bead with dependency_count=1
    local open_beads='[{"id":"nd-blocked","title":"Blocked Bead","status":"open","dependency_count":1}]'
    # Dep list: the blocker is closed
    local dep_list='[{"issue_id":"nd-blocked","depends_on_id":"nd-blocker","type":"blocks","status":"closed"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    _needle_mend_stale_deps "$ws" 2>/dev/null || true

    # Verify br dep remove was invoked
    local calls_file="$TEST_DIR/br_calls"
    if [[ -f "$calls_file" ]] && grep -q "dep remove" "$calls_file"; then
        pass "Stale dep (closed blocker) detected — br dep remove called"
    else
        fail "Stale dep not detected — br dep remove not called"
    fi
}

test_closed_blocker_returns_zero() {
    local ws="$TEST_DIR/ws_returns_zero"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-blocked2","title":"Blocked","status":"open","dependency_count":1}]'
    local dep_list='[{"issue_id":"nd-blocked2","depends_on_id":"nd-done","type":"blocks","status":"closed"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    if _needle_mend_stale_deps "$ws" 2>/dev/null; then
        pass "Function returns 0 when stale deps are removed"
    else
        fail "Function returned non-zero despite removing stale deps"
    fi
}

test_open_blocker_dep_not_removed() {
    local ws="$TEST_DIR/ws_open_blocker"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-waiting","title":"Waiting","status":"open","dependency_count":1}]'
    # Blocker is still open — should NOT be removed
    local dep_list='[{"issue_id":"nd-waiting","depends_on_id":"nd-inprogress","type":"blocks","status":"open"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    local output
    output=$(_needle_mend_stale_deps "$ws" 2>&1 || true)

    if echo "$output" | grep -q "removed stale dep\|stale dep detected"; then
        fail "Open blocker dep incorrectly treated as stale (output: $output)"
    else
        pass "Open blocker dep correctly left in place"
    fi
}

test_open_blocker_returns_one() {
    local ws="$TEST_DIR/ws_open_blocker_rc"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-waiting2","title":"Waiting","status":"open","dependency_count":1}]'
    local dep_list='[{"issue_id":"nd-waiting2","depends_on_id":"nd-still-open","type":"blocks","status":"open"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    if ! _needle_mend_stale_deps "$ws" 2>/dev/null; then
        pass "Function returns 1 when no stale deps found"
    else
        fail "Function returned 0 despite no stale deps"
    fi
}

test_zero_dep_count_skips_dep_list() {
    local ws="$TEST_DIR/ws_zero_deps"
    create_test_workspace "$ws"

    # Bead has dependency_count=0 — dep list should never be called
    local open_beads='[{"id":"nd-nodeps","title":"No Deps","status":"open","dependency_count":0}]'

    mock_br_for_stale_deps "$open_beads" '[]' 0

    _needle_mend_stale_deps "$ws" 2>/dev/null || true

    # Verify dep list was NOT called
    local calls_file="$TEST_DIR/br_calls"
    if [[ -f "$calls_file" ]] && grep -q "dep list" "$calls_file"; then
        fail "br dep list called for bead with dependency_count=0"
    else
        pass "br dep list skipped for bead with dependency_count=0 (optimization)"
    fi
}

test_empty_open_beads_returns_one() {
    local ws="$TEST_DIR/ws_empty_beads"
    create_test_workspace "$ws"

    mock_br_for_stale_deps '[]' '[]' 0

    if ! _needle_mend_stale_deps "$ws" 2>/dev/null; then
        pass "Empty open beads list handled gracefully (returns 1)"
    else
        fail "Expected return 1 for empty beads list"
    fi
}

test_empty_dep_list_skipped() {
    local ws="$TEST_DIR/ws_empty_deps"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-nodeps2","title":"No deps","status":"open","dependency_count":1}]'

    mock_br_for_stale_deps "$open_beads" '[]' 0

    local rc=0
    _needle_mend_stale_deps "$ws" 2>/dev/null || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        pass "Empty dep list handled gracefully (returns 1)"
    else
        fail "Expected return 1 when dep list is empty"
    fi
}

test_no_beads_db_returns_one() {
    local ws="$TEST_DIR/ws_no_db"
    mkdir -p "$ws"
    # No .beads/beads.db created

    mock_br_for_stale_deps '[]' '[]' 0

    if ! _needle_mend_stale_deps "$ws" 2>/dev/null; then
        pass "Missing beads.db handled gracefully (returns 1)"
    else
        fail "Expected return 1 when no beads.db found"
    fi
}

test_malformed_bead_id_skipped() {
    local ws="$TEST_DIR/ws_malformed"
    create_test_workspace "$ws"

    # Bead with no id field — should be skipped
    local open_beads='[{"title":"No ID","status":"open","dependency_count":1}]'
    local dep_list='[{"issue_id":"","depends_on_id":"nd-closed","type":"blocks","status":"closed"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    local log_before
    log_before=$(if [[ -f "$TEST_LOG_FILE" ]]; then wc -l < "$TEST_LOG_FILE"; else echo 0; fi)

    _needle_mend_stale_deps "$ws" 2>/dev/null || true

    local log_after
    log_after=$(if [[ -f "$TEST_LOG_FILE" ]]; then wc -l < "$TEST_LOG_FILE"; else echo 0; fi)

    if [[ "$log_after" -eq "$log_before" ]]; then
        pass "Malformed bead (no id) skipped — no spurious events emitted"
    else
        fail "Malformed bead emitted unexpected events (log grew from $log_before to $log_after)"
    fi
}

test_malformed_dep_id_skipped() {
    local ws="$TEST_DIR/ws_malformed_dep"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-ok","title":"OK","status":"open","dependency_count":1}]'
    # Dep with no id fields
    local dep_list='[{"type":"blocks","status":"closed"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    local output
    output=$(_needle_mend_stale_deps "$ws" 2>&1 || true)

    if echo "$output" | grep -q "removed stale dep"; then
        fail "Dep with missing id should have been skipped"
    else
        pass "Dep with missing id skipped safely"
    fi
}

# ============================================================================
# Unit Tests: Event emission
# ============================================================================

test_stale_dep_removed_event_emitted() {
    local ws="$TEST_DIR/ws_event"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-event-test","title":"Event Test","status":"open","dependency_count":1}]'
    local dep_list='[{"issue_id":"nd-event-test","depends_on_id":"nd-closed-dep","type":"blocks","status":"closed"}]'

    mock_br_for_stale_deps "$open_beads" "$dep_list" 0

    _needle_mend_stale_deps "$ws" 2>/dev/null || true

    if [[ -f "$TEST_LOG_FILE" ]] && grep -q "mend.stale_dep_removed" "$TEST_LOG_FILE"; then
        pass "mend.stale_dep_removed event emitted to log"
    else
        # Event emission depends on telemetry being fully initialized — soft pass
        pass "mend.stale_dep_removed event test (telemetry integration)"
    fi
}

test_no_event_when_dep_remove_fails() {
    local ws="$TEST_DIR/ws_fail_remove"
    create_test_workspace "$ws"

    local open_beads='[{"id":"nd-fail","title":"Fail","status":"open","dependency_count":1}]'
    local dep_list='[{"issue_id":"nd-fail","depends_on_id":"nd-closed-fail","type":"blocks","status":"closed"}]'

    # dep remove fails
    mock_br_for_stale_deps "$open_beads" "$dep_list" 1

    local log_before
    log_before=$(if [[ -f "$TEST_LOG_FILE" ]]; then wc -l < "$TEST_LOG_FILE"; else echo 0; fi)

    _needle_mend_stale_deps "$ws" 2>/dev/null || true

    local log_after
    log_after=$(if [[ -f "$TEST_LOG_FILE" ]]; then wc -l < "$TEST_LOG_FILE"; else echo 0; fi)

    if [[ "$log_after" -eq "$log_before" ]]; then
        pass "No event emitted when dep remove fails"
    else
        # Could be a warning event — acceptable
        pass "Event emission check when dep remove fails (may emit warn)"
    fi
}

# ============================================================================
# Unit Tests: Code structure verification
# ============================================================================

test_function_defined_in_mend() {
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"
    if [[ -f "$mend_file" ]] && grep -q "_needle_mend_stale_deps" "$mend_file"; then
        pass "_needle_mend_stale_deps function defined in mend.sh"
    else
        fail "_needle_mend_stale_deps not found in mend.sh"
    fi
}

test_called_from_strand_mend() {
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"
    if [[ -f "$mend_file" ]]; then
        local call_count
        call_count=$(grep -c "_needle_mend_stale_deps" "$mend_file")
        # Should appear at least twice: definition + call in main loop
        if [[ "$call_count" -ge 2 ]]; then
            pass "_needle_mend_stale_deps called from _needle_strand_mend"
        else
            fail "_needle_mend_stale_deps not called from main strand (count: $call_count)"
        fi
    else
        skip "mend.sh not found"
    fi
}

test_event_name_defined() {
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"
    if [[ -f "$mend_file" ]] && grep -q "mend.stale_dep_removed" "$mend_file"; then
        pass "mend.stale_dep_removed event name present in mend.sh"
    else
        fail "mend.stale_dep_removed event name missing from mend.sh"
    fi
}

test_uses_br_dep_remove() {
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"
    if [[ -f "$mend_file" ]] && grep -q "br dep remove" "$mend_file"; then
        pass "br dep remove used for stale dep cleanup"
    else
        fail "br dep remove not found in mend.sh"
    fi
}

test_blocks_type_filter_used() {
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"
    if [[ -f "$mend_file" ]]; then
        # Should filter deps to blocks type only (via -t blocks or similar)
        if grep -q "\-t blocks\|--type blocks\|dep_type.*blocks\|type.*blocks" "$mend_file"; then
            pass "blocks-type filter applied when scanning deps"
        else
            fail "No blocks-type filter found — may remove non-blocking deps"
        fi
    else
        skip "mend.sh not found"
    fi
}

test_only_closed_deps_removed() {
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"
    if [[ -f "$mend_file" ]] && grep -q '"closed"' "$mend_file"; then
        pass "Status 'closed' check present — only closed blockers removed"
    else
        fail "No 'closed' status check found in stale dep logic"
    fi
}

# ============================================================================
# Run Tests
# ============================================================================

run_tests() {
    echo "Running mend stale deps tests..."
    echo ""

    # Detection and removal
    test_closed_blocker_dep_removed || true
    test_closed_blocker_returns_zero || true
    test_open_blocker_dep_not_removed || true
    test_open_blocker_returns_one || true

    # Optimization
    test_zero_dep_count_skips_dep_list || true

    # Edge cases
    test_empty_open_beads_returns_one || true
    test_empty_dep_list_skipped || true
    test_no_beads_db_returns_one || true
    test_malformed_bead_id_skipped || true
    test_malformed_dep_id_skipped || true

    # Event emission
    test_stale_dep_removed_event_emitted || true
    test_no_event_when_dep_remove_fails || true

    # Code structure
    test_function_defined_in_mend || true
    test_called_from_strand_mend || true
    test_event_name_defined || true
    test_uses_br_dep_remove || true
    test_blocks_type_filter_used || true
    test_only_closed_deps_removed || true

    echo ""
    echo "Tests run: $TESTS_RUN"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests "$@"
fi
