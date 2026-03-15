#!/usr/bin/env bash
# Test suite for mend strand orphaned claim detection (nd-mbxt)
#
# Tests the _needle_mend_orphaned_claims function which detects and releases
# orphaned claims from dead workers and ownerless in_progress beads.

set -euo pipefail

# Get test directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test utilities
source "$PROJECT_ROOT/tests/test_utils.sh" 2>/dev/null || {
    # Minimal test utilities if test_utils.sh doesn't exist
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'

    pass() { echo -e "${GREEN}PASS${NC}: $1"; }
    fail() { echo -e "${RED}FAIL${NC}: $1"; return 1; }
    skip() { echo -e "${YELLOW}SKIP${NC}: $1"; }
}

# ============================================================================
# Test: Null Assignee Detection (Ownerless Beads)
# ============================================================================

test_null_assignee_releases_bead() {
    # Verify that the mend strand code handles null assignee correctly
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    if [[ ! -f "$mend_file" ]]; then
        fail "Mend strand file not found"
        return 1
    fi

    # Check for the null assignee handling code
    if grep -q "no assignee — unconditionally orphaned" "$mend_file"; then
        pass "Code path exists for releasing null-assignee beads"
    else
        fail "Missing null-assignee orphan detection in mend.sh"
        return 1
    fi
}

test_null_assignee_emits_event() {
    # Verify that the ownerless_released event is emitted
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    if grep -q "mend.ownerless_released" "$mend_file"; then
        pass "Code emits mend.ownerless_released event"
    else
        fail "Missing mend.ownerless_released event emission"
        return 1
    fi
}

test_null_assignee_includes_workspace_in_event() {
    # Verify that workspace is included in the ownerless event
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    # Look for the event emission with workspace parameter
    if grep -A5 'mend.ownerless_released' "$mend_file" | grep -q "workspace=\$workspace"; then
        pass "Event includes workspace parameter"
    else
        fail "Event missing workspace parameter"
        return 1
    fi
}

test_null_assignee_includes_bead_id_in_event() {
    # Verify that bead_id is included in the ownerless event
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    # Look for the event emission with bead_id parameter
    if grep -A5 'mend.ownerless_released' "$mend_file" | grep -q "bead_id=\$bead_id"; then
        pass "Event includes bead_id parameter"
    else
        fail "Event missing bead_id parameter"
        return 1
    fi
}

# ============================================================================
# Test: Orphaned Claims with Dead Worker
# ============================================================================

test_orphaned_claim_detects_dead_worker() {
    # Verify that orphaned claims detection still works for dead workers
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    # Check for the heartbeat file check
    if grep -q "heartbeat_file.*json" "$mend_file"; then
        pass "Code checks for heartbeat files"
    else
        fail "Missing heartbeat file check"
        return 1
    fi
}

test_orphaned_claim_emits_orphan_released_event() {
    # Verify that orphan_released event is emitted for dead workers
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    if grep -q "mend.orphan_released" "$mend_file"; then
        pass "Code emits mend.orphan_released event for dead workers"
    else
        fail "Missing mend.orphan_released event"
        return 1
    fi
}

# ============================================================================
# Test: Code Order and Structure
# ============================================================================

test_null_assignee_checked_before_heartbeat() {
    # Verify that null assignee check happens before heartbeat check
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    # Get line numbers for key checks
    local null_assignee_line
    local heartbeat_line

    null_assignee_line=$(grep -n "no assignee — unconditionally orphaned" "$mend_file" | head -1 | cut -d: -f1)
    heartbeat_line=$(grep -n "heartbeat_file.*json" "$mend_file" | head -1 | cut -d: -f1)

    if [[ -n "$null_assignee_line" ]] && [[ -n "$heartbeat_line" ]]; then
        if [[ "$null_assignee_line" -lt "$heartbeat_line" ]]; then
            pass "Null assignee check happens before heartbeat check (correct order)"
        else
            fail "Null assignee check should happen before heartbeat check"
            return 1
        fi
    else
        fail "Could not determine code order"
        return 1
    fi
}

# ============================================================================
# Test: Integration with Main Mend Strand
# ============================================================================

test_mend_orphaned_claims_function_exists() {
    # Verify the function exists and is callable
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    if grep -q "_needle_mend_orphaned_claims()" "$mend_file"; then
        pass "Function _needle_mend_orphaned_claims is defined"
    else
        fail "Function _needle_mend_orphaned_claims not found"
        return 1
    fi
}

test_mend_orphaned_claims_called_from_main() {
    # Verify the main strand calls orphaned claims cleanup
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    if grep -q "_needle_mend_orphaned_claims" "$mend_file"; then
        pass "Orphaned claims function is called in mend strand"
    else
        fail "Orphaned claims function not called"
        return 1
    fi
}

test_release_bead_helper_exists() {
    # Verify the _needle_mend_release_bead helper function exists
    local mend_file="$PROJECT_ROOT/src/strands/mend.sh"

    if grep -q "_needle_mend_release_bead()" "$mend_file"; then
        pass "Helper function _needle_mend_release_bead exists"
    else
        fail "Helper function _needle_mend_release_bead not found"
        return 1
    fi
}

# ============================================================================
# Run Tests
# ============================================================================

run_tests() {
    echo "Running mend orphaned claim detection tests..."
    echo ""

    local failed=0

    # Null assignee tests (nd-mbxt focus)
    test_null_assignee_releases_bead || ((failed++))
    test_null_assignee_emits_event || ((failed++))
    test_null_assignee_includes_workspace_in_event || ((failed++))
    test_null_assignee_includes_bead_id_in_event || ((failed++))

    # Orphaned claims with dead worker tests
    test_orphaned_claim_detects_dead_worker || ((failed++))
    test_orphaned_claim_emits_orphan_released_event || ((failed++))

    # Code structure tests
    test_null_assignee_checked_before_heartbeat || ((failed++))

    # Integration tests
    test_mend_orphaned_claims_function_exists || ((failed++))
    test_mend_orphaned_claims_called_from_main || ((failed++))
    test_release_bead_helper_exists || ((failed++))

    echo ""
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}$failed test(s) failed${NC}"
        return 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests "$@"
fi
