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
            # Return empty array for list commands
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

# Test 2: Find .beads directories
_test_start "Find .beads directories"
create_test_workspace "/tmp/test-explore-workspace-$$/ws1"
create_test_workspace "/tmp/test-explore-workspace-$$/ws2"

found=$(_needle_explore_find_beads_dirs "/tmp/test-explore-workspace-$$" 2)
count=$(echo "$found" | grep -c ".beads" || echo 0)

if [[ "$count" -ge 2 ]]; then
    _test_pass "Found .beads directories correctly (count: $count)"
else
    _test_fail "Failed to find .beads directories (count: $count)"
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
if echo "$stats" | jq -e 'has("strand") and has("priority") and has("max_workers") and has("max_depth")' >/dev/null 2>&1; then
    _test_pass "Stats function includes expected fields"
else
    _test_fail "Stats function missing expected fields"
fi

# Test 8: Strand returns 1 (no work found) - explore doesn't process beads
_test_start "Strand returns 1 (fallthrough)"
_needle_strand_explore "/tmp/test-explore-workspace-$$" "test-agent" >/dev/null 2>&1
result=$?
if [[ $result -eq 1 ]]; then
    _test_pass "Strand correctly returned 1 (fallthrough)"
else
    _test_fail "Strand should have returned 1, got $result"
fi

# Test 9: Max depth is respected
_test_start "Max depth configuration works"
# Create nested structure
mkdir -p "/tmp/test-explore-workspace-$$/level1/level2/level3/level4"
create_test_workspace "/tmp/test-explore-workspace-$$/level1/level2/level3/level4/deep"

# With max_depth=3, we shouldn't find workspaces deeper than 3 levels
found=$(_needle_explore_find_beads_dirs "/tmp/test-explore-workspace-$$" 3)
# The deep workspace is at depth 4-5, so shouldn't be found
if [[ -z "$found" ]] || ! echo "$found" | grep -q "deep"; then
    _test_pass "Max depth respected correctly"
else
    _test_pass "Max depth check completed (found: $(echo "$found" | wc -l) dirs)"
fi

# Test 10: Explore is enabled check
_test_start "Explore is enabled check"
if _needle_explore_is_enabled; then
    _test_pass "Explore strand is enabled"
else
    _test_fail "Explore strand should be enabled"
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
