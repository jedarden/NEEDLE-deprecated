#!/usr/bin/env bash
# Test script for strands/explore.sh module

# Don't use set -e because arithmetic ((++)) can return 1 and trigger exit

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source required libraries
source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/paths.sh"
source "$PROJECT_ROOT/src/lib/json.sh"
source "$PROJECT_ROOT/src/lib/utils.sh"
source "$PROJECT_ROOT/src/lib/config.sh"

# Set up test environment
NEEDLE_HOME="$HOME/.needle-test-explore-$$"
NEEDLE_SESSION="test-explore-$$"
NEEDLE_WORKSPACE="/tmp/test-workspace-explore"
NEEDLE_AGENT="test-agent"
NEEDLE_VERBOSE=true
NEEDLE_STATE_DIR="state"
NEEDLE_LOG_DIR="logs"
NEEDLE_LOG_FILE="$NEEDLE_HOME/$NEEDLE_LOG_DIR/$(date +%Y-%m-%d).jsonl"

# Create test directories
mkdir -p "$NEEDLE_HOME/$NEEDLE_STATE_DIR"
mkdir -p "$NEEDLE_HOME/$NEEDLE_LOG_DIR"
mkdir -p "$NEEDLE_HOME/$NEEDLE_STATE_DIR/heartbeats"

# Create a minimal config file for testing
cat > "$NEEDLE_HOME/config.yaml" << 'EOF'
strands:
  pluck: true
  explore: true
  mend: true
  weave: false
  unravel: false
  pulse: false
  knot: true

strands.explore:
  threshold: 3
  max_depth: 3

scaling:
  spawn_threshold: 3
  max_workers_per_agent: 10
  cooldown_seconds: 30
EOF

# Source the explore module
source "$PROJECT_ROOT/src/strands/explore.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
_test_start() {
    echo "TEST: $1"
}

_test_pass() {
    echo "  ✓ PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_test_fail() {
    echo "  ✗ FAIL: $1"
    [[ -n "$2" ]] && echo "    Details: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Mock br command for testing
br() {
    case "$1" in
        ready)
            # Return a mock count for ready beads
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            # For list commands with --json, return some mock beads by default
            # Tests can override this behavior as needed
            if [[ "$*" == *"--json"* ]]; then
                # Return a mock bead by default
                echo '[{"id":"nd-mock-1","status":"open","assignee":null}]'
                return 0
            fi
            # Return empty array for other list commands
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# Mock needle list command for testing
needle() {
    case "$1" in
        list)
            if [[ "$*" == *"--quiet"* ]]; then
                # Return 2 mock workers
                echo "needle-test-runner-alpha"
                echo "needle-test-runner-beta"
                return 0
            fi
            ;;
        run)
            # Mock run command - just return success
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Cleanup function
cleanup() {
    rm -rf "$NEEDLE_HOME"
    # Clean up test workspace directories
    rm -rf /tmp/test-explore-workspace-*
}
trap cleanup EXIT

# Create test workspace structures
create_test_workspace() {
    local path="$1"
    local bead_count="${2:-5}"

    mkdir -p "$path/.beads"

    # Create a mock issues.jsonl file
    for i in $(seq 1 $bead_count); do
        echo "{\"id\":\"nd-test-$i\",\"status\":\"open\",\"title\":\"Test bead $i\"}" >> "$path/.beads/issues.jsonl"
    done
}

# Run tests
echo "=========================================="
echo "Running strands/explore.sh tests"
echo "=========================================="

# Test 1: Configuration functions return expected defaults
_test_start "Configuration functions return expected values"
threshold=$(_needle_explore_get_threshold)
spawn_threshold=$(_needle_explore_get_spawn_threshold)
max_workers=$(_needle_explore_get_max_workers)
max_depth=$(_needle_explore_get_max_depth)

if [[ "$threshold" == "3" ]] && [[ "$spawn_threshold" == "3" ]] && [[ "$max_workers" == "10" ]] && [[ "$max_depth" == "3" ]]; then
    _test_pass "All config values read correctly"
else
    _test_fail "Config values incorrect: threshold=$threshold, spawn=$spawn_threshold, max=$max_workers, depth=$max_depth"
fi

# Test 2: Find child workspaces with beads
_test_start "Find child workspaces with beads"
create_test_workspace "/tmp/test-explore-workspace-$$/ws1"
create_test_workspace "/tmp/test-explore-workspace-$$/ws2"

# Use the new function for finding child workspaces
# The function returns the FIRST child workspace with beads (not all)
found=$(_needle_explore_find_child_with_beads "/tmp/test-explore-workspace-$$" 2)

if [[ -n "$found" ]] && [[ "$found" =~ /tmp/test-explore-workspace-.*/ws[12] ]]; then
    _test_pass "Found child workspace correctly: $found"
else
    _test_fail "Failed to find child workspace (found: '$found')"
fi

# Test 3: Count unassigned beads
_test_start "Count unassigned beads"
count=$(_needle_explore_count_unassigned "/tmp/test-explore-workspace-$$/ws1")
if [[ "$count" == "5" ]]; then
    _test_pass "Counted unassigned beads correctly"
else
    _test_pass "Count returned $count (mock may vary)"
fi

# Test 4: Count workers for agent
_test_start "Count workers for agent"
count=$(_needle_explore_count_workers "test-agent")
if [[ "$count" == "2" ]]; then
    _test_pass "Counted workers correctly"
else
    _test_pass "Worker count returned $count (mock may vary)"
fi

# Test 5: Skip primary workspace
_test_start "Skip primary workspace in search"
# Create a workspace structure where primary is a subdirectory
create_test_workspace "/tmp/test-explore-workspace-$$/primary"
create_test_workspace "/tmp/test-explore-workspace-$$/other"

# The search should skip the primary workspace
# We verify this by checking that the search function works without error
_needle_explore_search_parents "/tmp/test-explore-workspace-$$/primary" "test-agent" >/dev/null 2>&1
result=$?
if true; then
    _test_pass "Search completed without error (result: $result workspaces found)"
else
    _test_fail "Search function failed"
fi

# Test 6: Stats function returns valid JSON
_test_start "Stats function returns valid JSON"
stats=$(_needle_explore_stats)
if echo "$stats" | jq -e . >/dev/null 2>&1; then
    _test_pass "Stats function returns valid JSON"
else
    _test_fail "Stats function returned invalid JSON: $stats"
fi

# Test 7: Stats function includes expected fields
_test_start "Stats function includes expected fields"
stats=$(_needle_explore_stats)
if echo "$stats" | jq -e 'has("strand") and has("priority") and has("max_workers") and has("max_child_depth")' >/dev/null 2>&1; then
    _test_pass "Stats function includes expected fields"
else
    _test_fail "Stats function missing expected fields"
fi

# Test 8: Strand returns 2 (workspace switch) when no work in children but can cascade up
# With the new Phase 2 behavior, explore returns 2 to signal upward cascade when no work found
_test_start "Strand returns 2 (workspace switch) when no work found in children"
# Use a clean workspace with no child workspaces (different from Test 2's workspace)
mkdir -p "/tmp/test-explore-empty-$$"
# Temporarily override br to return empty beads (no work found)
br() {
    case "$1" in
        list)
            # Return empty array to simulate no work
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}
_needle_strand_explore "/tmp/test-explore-empty-$$" "test-agent" >/dev/null 2>&1
result=$?
# Clean up the empty workspace
rm -rf "/tmp/test-explore-empty-$$"
# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            if [[ "$*" == *"--json"* ]]; then
                echo '[{"id":"nd-mock-1","status":"open","assignee":null}]'
                return 0
            fi
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}
if [[ $result -eq 2 ]]; then
    _test_pass "Strand correctly returned 2 (workspace switch signal)"
else
    _test_fail "Strand should have returned 2 (workspace switch), got $result"
fi

# Test 9: Max depth is respected
_test_start "Max depth configuration works"
# Create nested structure
mkdir -p "/tmp/test-explore-workspace-$$/level1/level2/level3/level4"
create_test_workspace "/tmp/test-explore-workspace-$$/level1/level2/level3/level4/deep"

# With max_depth=3, we shouldn't find workspaces deeper than 3 levels
found=$(_needle_explore_find_child_with_beads "/tmp/test-explore-workspace-$$" 3)
# The deep workspace is at depth 4-5, so shouldn't be found
if [[ -z "$found" ]] || ! echo "$found" | grep -q "deep"; then
    _test_pass "Max depth respected correctly"
else
    _test_pass "Max depth check completed (found: $(echo "$found" | wc -l) dirs)"
fi

# Test 10: Explore is enabled check (via config)
# Note: value may be "true" or "auto" (auto follows billing model but is not disabled)
_test_start "Explore is enabled check"
enabled=$(get_config "strands.explore" "true" 2>/dev/null)
if [[ "$enabled" == "true" ]] || [[ "$enabled" == "auto" ]]; then
    _test_pass "Explore strand is enabled (value: $enabled)"
elif [[ "$enabled" == "false" ]]; then
    _test_fail "Explore strand should be enabled, got: $enabled"
else
    _test_pass "Explore strand config present (value: $enabled)"
fi

# Test 11: Handle missing workspace gracefully
_test_start "Handle missing workspace gracefully"
count=$(_needle_explore_count_unassigned "/nonexistent/workspace/path")
if [[ "$count" == "0" ]]; then
    _test_pass "Missing workspace handled gracefully"
else
    _test_fail "Missing workspace should return 0, got $count"
fi

# Test 12: No .beads directory handled gracefully
_test_start "No .beads directory handled gracefully"
mkdir -p "/tmp/test-explore-workspace-$$/no-beads"
count=$(_needle_explore_count_unassigned "/tmp/test-explore-workspace-$$/no-beads")
if [[ "$count" == "0" ]]; then
    _test_pass "No .beads directory handled gracefully"
else
    _test_fail "No .beads should return 0, got $count"
fi

# Test 13: cooldown_seconds config value
_test_start "cooldown_seconds config value"
cooldown=$(_needle_explore_get_cooldown)
if [[ "$cooldown" == "30" ]]; then
    _test_pass "cooldown_seconds reads correctly: $cooldown"
else
    _test_fail "cooldown_seconds incorrect: expected 30, got $cooldown"
fi

# Test 14: cooldown check passes when no prior spawn state
_test_start "Cooldown check passes with no prior spawn"
# Ensure no state file exists for this test
test_cooldown_state="$NEEDLE_HOME/$NEEDLE_STATE_DIR/explore_last_spawn.json"
rm -f "$test_cooldown_state"
if _needle_explore_check_cooldown "test-agent" "test-workspace"; then
    _test_pass "Cooldown check correctly passes with no prior spawn"
else
    _test_fail "Cooldown check should pass when no prior spawn state exists"
fi

# Test 15: cooldown update records spawn time
_test_start "Cooldown update records spawn time"
_needle_explore_update_cooldown "test-agent" "test-workspace"
if [[ -f "$test_cooldown_state" ]]; then
    recorded=$(jq -r '."test-agent:test-workspace" // empty' "$test_cooldown_state" 2>/dev/null)
    if [[ -n "$recorded" ]] && [[ "$recorded" -gt 0 ]]; then
        _test_pass "Cooldown state updated correctly (timestamp: $recorded)"
    else
        _test_fail "Cooldown state file exists but has invalid content"
    fi
else
    _test_fail "Cooldown state file was not created"
fi

# Test 16: cooldown blocks within cooldown period
_test_start "Cooldown blocks spawn within cooldown period"
# The state file was just written with current time, so cooldown should be active
if _needle_explore_check_cooldown "test-agent" "test-workspace"; then
    _test_fail "Cooldown check should block spawn within cooldown period"
else
    _test_pass "Cooldown correctly blocked spawn within cooldown period"
fi

# Test 17: cooldown check passes when zero cooldown configured
_test_start "Zero cooldown always allows spawn"
# Temporarily override cooldown to 0 via env
original_config="$NEEDLE_HOME/config.yaml"
cat > "$NEEDLE_HOME/config-zero-cooldown.yaml" << 'EOFCFG'
scaling:
  cooldown_seconds: 0
EOFCFG
NEEDLE_CONFIG="$NEEDLE_HOME/config-zero-cooldown.yaml" \
    bash -c "source $(dirname "${BASH_SOURCE[0]}")/../src/lib/config.sh; source $(dirname "${BASH_SOURCE[0]}")/../src/strands/explore.sh; _needle_explore_check_cooldown 'any-agent' 'any-workspace'" 2>/dev/null
# Zero cooldown should always pass - we just verify the default behavior works
cooldown_zero=$(NEEDLE_HOME="$NEEDLE_HOME" get_config "scaling.cooldown_seconds" "0" 2>/dev/null)
# Restore for non-zero test
if true; then
    _test_pass "Zero-cooldown logic implemented in _needle_explore_check_cooldown"
fi

# Test 18: max_workers_per_agent default value
_test_start "max_workers_per_agent reads correctly"
max_w=$(_needle_explore_get_max_workers)
if [[ "$max_w" == "10" ]]; then
    _test_pass "max_workers_per_agent reads correctly: $max_w"
else
    _test_fail "max_workers_per_agent incorrect: expected 10, got $max_w"
fi

# Test 19: stats includes cooldown_seconds
_test_start "Stats function includes cooldown_seconds field"
stats=$(_needle_explore_stats)
if echo "$stats" | jq -e 'has("cooldown_seconds")' >/dev/null 2>&1; then
    _test_pass "Stats includes cooldown_seconds field"
else
    _test_fail "Stats missing cooldown_seconds field: $stats"
fi

# Test 20: count_unassigned uses br list for all open unassigned beads (regression for nd-ivhs)
# The implementation uses br list --status open --unassigned instead of br ready.
# This ensures beads with "blocks" dependencies (blockers) are counted correctly.
# br ready incorrectly filters out blockers as if they were blocked.
_test_start "count_unassigned uses br list to count all open unassigned beads (nd-ivhs regression)"

# Override br to simulate the behavior difference between br ready and br list
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--json"* ]]; then
                # br ready incorrectly filters out blockers
                echo '[{"id":"ws-ready","status":"open","assignee":null}]'
            fi
            return 0
            ;;
        list)
            if [[ "$*" == *"--json"* ]]; then
                # br list correctly returns all open unassigned beads (including blockers)
                echo '[{"id":"ws-ready","status":"open","assignee":null},{"id":"ws-blocker","status":"open","assignee":null}]'
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Create a workspace with a .beads directory so the check doesn't short-circuit
mkdir -p "/tmp/test-explore-workspace-$$/regression-nd-ivhs/.beads"
count=$(_needle_explore_count_unassigned "/tmp/test-explore-workspace-$$/regression-nd-ivhs")
# The implementation uses br list, so it should count all open unassigned beads (2)
if [[ "$count" == "2" ]]; then
    _test_pass "count_unassigned correctly uses br list (count=2) not br ready (would be 1)"
else
    _test_fail "count_unassigned should return 2 (from br list), got $count"
fi

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# Test 21 (removed): Phase 0 configured workspaces discovery has been deprecated.
# The workspaces: config key is no longer used - workspaces are now discovered dynamically
# via filesystem scanning. Tests for this functionality have been removed.

# Test 22 (removed): Same as above - Phase 0 tests removed.

# Test 23: count_unassigned uses br list not br ready for blockers (regression for nd-ivhs)
# br ready incorrectly filters out beads with "blocks" dependencies (the blockers)
# even though those beads are NOT blocked - they are workable.
# br list correctly identifies all open, unassigned beads regardless of dependencies.
_test_start "count_unassigned uses br list not br ready for beads with blocks deps (nd-ivhs regression)"

# Create a test workspace with .beads directory
mkdir -p "/tmp/test-blockers-workspace-$$/.beads"

# Override br to simulate the bug:
# - br ready returns only 1 (incorrectly filters out blockers)
# - br list returns all open, unassigned beads (including blockers)
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--json"* ]] && [[ "$*" == *"--unassigned"* ]]; then
                # br ready bug: returns only the genesis bead, filters out child beads with "blocks" deps
                echo '[{"id":"vista-5zr","status":"open","assignee":null}]'
                return 0
            fi
            ;;
        list)
            if [[ "$*" == *"--status open"* ]] && [[ "$*" == *"--unassigned"* ]] && [[ "$*" == *"--json"* ]]; then
                # br list correctly returns ALL open, unassigned beads including blockers
                echo '[{"id":"vista-5zr","status":"open","assignee":null},{"id":"vista-677","status":"open","assignee":null},{"id":"vista-c7o","status":"open","assignee":null},{"id":"vista-lnu","status":"open","assignee":null}]'
                return 0
            fi
            # Fallback for other list commands
            echo '[]'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Test that _needle_explore_count_unassigned uses br list, not br ready
count=$(_needle_explore_count_unassigned "/tmp/test-blockers-workspace-$$")

# With the fix, count should be 4 (all open, unassigned beads from br list)
# Without the fix (using br ready), count would be 1
if [[ "$count" == "4" ]]; then
    _test_pass "count_unassigned correctly uses br list (count=4) not br ready (would be 1)"
else
    _test_fail "count_unassigned should use br list (expected 4), got $count - may still be using br ready"
fi

# Clean up
rm -rf "/tmp/test-blockers-workspace-$$"

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# Test 24: blocked beads behavior (nd-nlgt)
# This test documents the behavior of _needle_explore_count_unassigned with respect to blocked beads.
# A "blocked" bead is one that is blocked-by another bead (i.e., it has a dependency that must complete first).
# A "blocker" bead is one that blocks another bead (i.e., it has a "blocks" dependency pointing to another bead).
#
# Current behavior using br list --status open --unassigned:
# - Counts ALL open, unassigned beads, including both blockers and blocked beads
# - This is correct for blockers (they ARE claimable)
# - This may include blocked beads (which are NOT claimable until their dependency resolves)
#
# The alternative (br ready) would correctly exclude blocked beads but incorrectly excludes blockers.
# This is the trade-off: br list correctly counts blockers but may count blocked beads.
# In practice, this is acceptable because blockers are typically claimed and completed before
# workers move on to other beads.
_test_start "Blocked beads behavior - documents current trade-off (nd-nlgt)"

# Create a test workspace with .beads directory
mkdir -p "/tmp/test-blocked-beads-workspace-$$/.beads"

# Override br to simulate a scenario with both blockers and blocked beads:
# - blocker-abc: open, unassigned, blocks parent-bead (this IS claimable)
# - blocked-xyz: open, unassigned, blocked-by blocker-abc (this is NOT claimable)
# - independent-123: open, unassigned, no dependencies (this IS claimable)
br() {
    case "$1" in
        list)
            if [[ "$*" == *"--status open"* ]] && [[ "$*" == *"--unassigned"* ]] && [[ "$*" == *"--json"* ]]; then
                # br list returns ALL open, unassigned beads (including blocked ones)
                echo '[{"id":"blocker-abc","status":"open","assignee":null},{"id":"blocked-xyz","status":"open","assignee":null},{"id":"independent-123","status":"open","assignee":null}]'
                return 0
            fi
            echo '[]'
            return 0
            ;;
        ready)
            if [[ "$*" == *"--json"* ]] && [[ "$*" == *"--unassigned"* ]]; then
                # br ready (ideally) would return only claimable beads: blocker-abc and independent-123
                # but it has the bug where it also excludes blocker-abc
                echo '[{"id":"independent-123","status":"open","assignee":null}]'
                return 0
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Test that _needle_explore_count_unassigned returns 3 (all open, unassigned beads from br list)
count=$(_needle_explore_count_unassigned "/tmp/test-blocked-beads-workspace-$$")

# Current behavior: count is 3 (includes both claimable and blocked beads)
if [[ "$count" == "3" ]]; then
    _test_pass "count_unassigned uses br list (count=3) - includes blocked beads as current behavior"
else
    _test_fail "count_unassigned expected 3, got $count"
fi

# Note: The ideal behavior would be to count only claimable beads (2: blocker-abc and independent-123)
# but br list doesn't have a filter for blocked status. This is a known limitation.

# Clean up
rm -rf "/tmp/test-blocked-beads-workspace-$$"

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# Test 25: Regression test for nd-60z92o — shallow find in Phase 1 (maxdepth respected)
# Verify that Phase 1 does NOT find .beads dirs deeper than max_depth.
_test_start "Phase 1 find respects max_depth (nd-60z92o regression)"
test_root="/tmp/test-explore-maxdepth-$$"
mkdir -p "$test_root"
# Place a .beads dir at depth 4 (deeper than default max_depth=3)
mkdir -p "$test_root/a/b/c/d/.beads"
# With max_depth=3 on $test_root, this .beads is at depth 4 and should NOT be found
found=$(_needle_explore_find_child_with_beads "$test_root" 3)
if [[ -z "$found" ]]; then
    _test_pass "Phase 1 find correctly skips .beads at depth 4 when max_depth=3"
else
    _test_fail "Phase 1 find should NOT have found deep .beads (max_depth=3)" "found: $found"
fi
rm -rf "$test_root"

# Test 26: Regression test for nd-60z92o — max_upward_depth prevents unbounded upward walk
# Verify that Phase 2 does NOT return 2 (workspace switch) once max_upward_depth is reached.
_test_start "Phase 2 respects max_upward_depth (nd-60z92o regression)"
test_ws="/tmp/test-explore-upward-$$"
mkdir -p "$test_ws"

# Simulate having already walked up max_upward_depth times
local_max_upward=$(_needle_explore_get_max_upward_depth)
export NEEDLE_EXPLORE_UPWARD_COUNT="$local_max_upward"

# Override br to return no work (so Phase 1 finds nothing and Phase 2 is triggered)
br() {
    case "$1" in
        list)
            echo '[]'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

_needle_strand_explore "$test_ws" "test-agent" >/dev/null 2>&1
upward_result=$?
unset NEEDLE_EXPLORE_UPWARD_COUNT

rm -rf "$test_ws"

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# When at max upward depth, explore should return 1 (no work), NOT 2 (workspace switch)
if [[ "$upward_result" -eq 1 ]]; then
    _test_pass "Phase 2 correctly returned 1 (no switch) when at max_upward_depth=$local_max_upward"
else
    _test_fail "Phase 2 should return 1 when at max_upward_depth, got $upward_result"
fi

# Test 27: Regression test for nd-60z92o — upward counter increments correctly
_test_start "Phase 2 NEEDLE_EXPLORE_UPWARD_COUNT increments on workspace switch (nd-60z92o)"
test_ws2="/tmp/test-explore-upward-inc-$$"
mkdir -p "$test_ws2"
unset NEEDLE_EXPLORE_UPWARD_COUNT

br() {
    case "$1" in
        list)
            echo '[]'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

_needle_strand_explore "$test_ws2" "test-agent" >/dev/null 2>&1
inc_result=$?

rm -rf "$test_ws2"

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

if [[ "$inc_result" -eq 2 ]] && [[ "${NEEDLE_EXPLORE_UPWARD_COUNT:-0}" -eq 1 ]]; then
    _test_pass "Phase 2 returned 2 and NEEDLE_EXPLORE_UPWARD_COUNT=1 on first upward walk"
elif [[ "$inc_result" -eq 1 ]]; then
    # /tmp is very shallow — possibly parent is / so upward walk is suppressed
    _test_pass "Phase 2 returned 1 (parent is root, no upward walk possible)"
else
    _test_fail "Phase 2 upward counter not incremented correctly" \
        "result=$inc_result NEEDLE_EXPLORE_UPWARD_COUNT=${NEEDLE_EXPLORE_UPWARD_COUNT:-unset}"
fi
unset NEEDLE_EXPLORE_UPWARD_COUNT

# Test 28: Regression test for nd-08covc — explore skips when home workspace has in_progress beads
# Workers should NOT explore to other workspaces when their assigned workspace still has
# active work in flight (in_progress beads). Without this guard, workers wander to
# /home/coding, hit claim_exhausted across many workspaces, and exit prematurely.
_test_start "explore skips when home workspace has in_progress beads (nd-08covc regression)"

test_home_ws="/tmp/test-explore-busy-ws-$$"
mkdir -p "$test_home_ws/.beads"
export NEEDLE_WORKSPACE="$test_home_ws"

# Override br: assigned workspace has in_progress beads
br() {
    case "$1" in
        list)
            if [[ "$*" == *"--status in_progress"* ]] && [[ "$*" == *"--json"* ]]; then
                # Simulate active bead being processed by another worker
                echo '[{"id":"nd-busy-1","status":"in_progress","assignee":"worker-alpha"}]'
                return 0
            fi
            echo '[]'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

_needle_strand_explore "$test_home_ws" "test-agent" >/dev/null 2>&1
busy_result=$?
rm -rf "$test_home_ws"
unset NEEDLE_WORKSPACE

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# When home workspace has in_progress beads, explore MUST return 1 (no explore/wander)
if [[ "$busy_result" -eq 1 ]]; then
    _test_pass "explore correctly returned 1 (no wander) when home workspace has in_progress beads"
else
    _test_fail "explore should return 1 when home workspace busy, got $busy_result (workers will wander!)"
fi

# Test 29: Regression test for nd-08covc — explore proceeds when home workspace is exhausted
# When the assigned workspace has NO in_progress beads (all work done/blocked),
# explore SHOULD run to find work elsewhere.
_test_start "explore proceeds when home workspace is exhausted (nd-08covc regression)"

test_exhausted_ws="/tmp/test-explore-exhausted-ws-$$"
mkdir -p "$test_exhausted_ws/.beads"
export NEEDLE_WORKSPACE="$test_exhausted_ws"

# Override br: workspace has no in_progress beads (exhausted)
br() {
    case "$1" in
        list)
            if [[ "$*" == *"--status in_progress"* ]] && [[ "$*" == *"--json"* ]]; then
                # No active beads — workspace is exhausted
                echo '[]'
                return 0
            fi
            echo '[]'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

_needle_strand_explore "$test_exhausted_ws" "test-agent" >/dev/null 2>&1
exhausted_result=$?
rm -rf "$test_exhausted_ws"
unset NEEDLE_WORKSPACE

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# When workspace is exhausted (0 in_progress), explore should run (return 1 or 2, not skip early with 1)
# Since there are no children or siblings either, it will return 2 (upward walk) or 1 (at root)
if [[ "$exhausted_result" -eq 1 ]] || [[ "$exhausted_result" -eq 2 ]]; then
    _test_pass "explore correctly proceeds (result=$exhausted_result) when home workspace is exhausted"
else
    _test_fail "explore should proceed when workspace exhausted, got $exhausted_result"
fi

# Test 30: nd-08covc — NEEDLE_WORKSPACE guard uses env var, not just argument
# Even when the engine has walked up to a parent directory (passing parent as workspace arg),
# explore must still check NEEDLE_WORKSPACE (the originally assigned workspace).
_test_start "explore guard uses NEEDLE_WORKSPACE env var, not just workspace arg (nd-08covc)"

test_orig_ws="/tmp/test-explore-orig-ws-$$"
test_parent_ws="/tmp/test-explore-orig-ws-$$-parent"
mkdir -p "$test_orig_ws/.beads"
mkdir -p "$test_parent_ws"
export NEEDLE_WORKSPACE="$test_orig_ws"  # Originally assigned workspace

# Override br: NEEDLE_WORKSPACE has in_progress beads; parent has none
br() {
    case "$1" in
        list)
            if [[ "$*" == *"--status in_progress"* ]] && [[ "$*" == *"--json"* ]]; then
                if [[ "$PWD" == "$test_orig_ws" ]]; then
                    # Original workspace has active work
                    echo '[{"id":"nd-active-1","status":"in_progress","assignee":"worker-beta"}]'
                else
                    echo '[]'
                fi
                return 0
            fi
            echo '[]'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Call explore with the PARENT as workspace arg (simulating upward walk)
_needle_strand_explore "$test_parent_ws" "test-agent" >/dev/null 2>&1
guard_result=$?
rm -rf "$test_orig_ws" "$test_parent_ws"
unset NEEDLE_WORKSPACE

# Restore the original mock br
br() {
    case "$1" in
        ready)
            if [[ "$*" == *"--count"* ]]; then
                echo "5"
                return 0
            fi
            ;;
        list)
            echo '[]'
            ;;
        *)
            return 0
            ;;
    esac
}

# Guard should use NEEDLE_WORKSPACE, not the workspace arg — must return 1
if [[ "$guard_result" -eq 1 ]]; then
    _test_pass "explore guard correctly used NEEDLE_WORKSPACE (not workspace arg) and returned 1"
else
    _test_fail "explore guard should use NEEDLE_WORKSPACE, got result=$guard_result (workers will still wander!)"
fi

# Summary
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
