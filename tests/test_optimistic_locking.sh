#!/usr/bin/env bash
# Test suite for NEEDLE optimistic locking with 3-way merge
#
# Tests:
#   - Snapshot creation and retrieval
#   - Clean merge scenario
#   - Conflict detection and handling
#   - Merge tool selection (git-merge-file, diff3, custom)
#   - Conflict resolution strategies (block, keep_ours, keep_theirs)
#   - Snapshot cleanup
#   - Integration with detect_file_conflicts

set -euo pipefail

# ============================================================================
# Test Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDLE_SRC="${NEEDLE_SRC:-$SCRIPT_DIR/../src}"
NEEDLE_HOME="${NEEDLE_HOME:-$HOME/.needle}"

# Source the optimistic locking module
source "$NEEDLE_SRC/lock/optimistic.sh"

# Test directory (use a temp directory that we clean up)
TEST_DIR=""
SNAPSHOT_DIR=""

setup() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/needle-optimistic-test-XXXXXXXX")
    SNAPSHOT_DIR="${TEST_DIR}/snapshots"
    mkdir -p "$SNAPSHOT_DIR"

    # Override snapshot directory for tests
    NEEDLE_SNAPSHOT_DIR="$SNAPSHOT_DIR"

    echo "=== Optimistic Locking Tests ===" >&2
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# ============================================================================
# Test: Path Hash Generation
# ============================================================================
test_path_hash() {
    echo "Testing path hash generation..."

    local hash1 hash2 hash3

    # Same path should produce same hash
    hash1=$(_needle_optimistic_path_hash "/path/to/file.txt")
    hash2=$(_needle_optimistic_path_hash "/path/to/file.txt")

    if [[ "$hash1" != "$hash2" ]]; then
        echo "FAIL: Same path produced different hashes"
        return 1
    fi

    # Hash should be 8 characters
    if [[ ${#hash1} -ne 8 ]]; then
        echo "FAIL: Hash length is not 8 characters: ${#hash1}"
        return 1
    fi

    # Different paths should produce different hashes
    hash3=$(_needle_optimistic_path_hash "/different/path.txt")

    if [[ "$hash1" == "$hash3" ]]; then
        echo "FAIL: Different paths produced same hash"
        return 1
    fi

    echo "PASS: Path hash generation"
    return 0
}

# ============================================================================
# Test: Snapshot Creation
# ============================================================================
test_snapshot_creation() {
    echo "Testing snapshot creation..."

    local test_file="${TEST_DIR}/test-file.txt"
    local bead_id="nd-test"
    local content="Original content for testing"

    # Create test file
    echo "$content" > "$test_file"

    # Create snapshot
    if ! prepare_optimistic_edit "$test_file" "$bead_id"; then
        echo "FAIL: prepare_optimistic_edit failed"
        return 1
    fi

    # Verify snapshot directory was created
    local snapshot_dir="${SNAPSHOT_DIR}/${bead_id}"
    if [[ ! -d "$snapshot_dir" ]]; then
        echo "FAIL: Snapshot directory not created"
        return 1
    fi

    # Verify files list was created
    if [[ ! -f "${snapshot_dir}/files" ]]; then
        echo "FAIL: Files list not created"
        return 1
    fi

    # Verify file is in the list
    if ! grep -q "^${test_file}$" "${snapshot_dir}/files"; then
        echo "FAIL: File not recorded in files list"
        return 1
    fi

    # Verify base snapshot was created
    local path_hash
    path_hash=$(_needle_optimistic_path_hash "$test_file")
    local base_file="${snapshot_dir}/${path_hash}.base"

    if [[ ! -f "$base_file" ]]; then
        echo "FAIL: Base snapshot not created"
        return 1
    fi

    # Verify content matches
    if [[ "$(cat "$base_file")" != "$content" ]]; then
        echo "FAIL: Base snapshot content mismatch"
        return 1
    fi

    echo "PASS: Snapshot creation"
    return 0
}

# ============================================================================
# Test: Snapshot for Non-Existent File
# ============================================================================
test_snapshot_nonexistent_file() {
    echo "Testing snapshot for non-existent file..."

    local test_file="${TEST_DIR}/nonexistent-file.txt"
    local bead_id="nd-test2"

    # File should not exist
    rm -f "$test_file" 2>/dev/null || true

    # Create snapshot for non-existent file
    if ! prepare_optimistic_edit "$test_file" "$bead_id"; then
        echo "FAIL: prepare_optimistic_edit failed for non-existent file"
        return 1
    fi

    # Verify empty base was created
    local path_hash
    path_hash=$(_needle_optimistic_path_hash "$test_file")
    local base_file="${SNAPSHOT_DIR}/${bead_id}/${path_hash}.base"

    if [[ ! -f "$base_file" ]]; then
        echo "FAIL: Base snapshot not created for non-existent file"
        return 1
    fi

    # Should be empty
    if [[ -s "$base_file" ]]; then
        echo "FAIL: Base snapshot should be empty for non-existent file"
        return 1
    fi

    echo "PASS: Snapshot for non-existent file"
    return 0
}

# ============================================================================
# Test: Snapshot Cleanup
# ============================================================================
test_snapshot_cleanup() {
    echo "Testing snapshot cleanup..."

    local test_file="${TEST_DIR}/cleanup-test.txt"
    local bead_id="nd-cleanup"

    # Create test file and snapshot
    echo "Test content" > "$test_file"
    prepare_optimistic_edit "$test_file" "$bead_id" || true

    # Verify snapshot exists
    local snapshot_dir="${SNAPSHOT_DIR}/${bead_id}"
    if [[ ! -d "$snapshot_dir" ]]; then
        echo "FAIL: Snapshot directory not created"
        return 1
    fi

    # Clean up
    if ! cleanup_optimistic_snapshots "$bead_id"; then
        echo "FAIL: cleanup_optimistic_snapshots failed"
        return 1
    fi

    # Verify directory was removed
    if [[ -d "$snapshot_dir" ]]; then
        echo "FAIL: Snapshot directory not cleaned up"
        return 1
    fi

    echo "PASS: Snapshot cleanup"
    return 0
}

# ============================================================================
# Test: List Snapshots
# ============================================================================
test_list_snapshots() {
    echo "Testing list snapshots..."

    local bead_id="nd-list"
    local file1="${TEST_DIR}/file1.txt"
    local file2="${TEST_DIR}/file2.txt"

    # Create files
    echo "Content 1" > "$file1"
    echo "Content 2" > "$file2"

    # Create snapshots
    prepare_optimistic_edit "$file1" "$bead_id" || true
    prepare_optimistic_edit "$file2" "$bead_id" || true

    # List snapshots
    local snapshots
    snapshots=$(list_optimistic_snapshots "$bead_id")

    # Verify both files are listed
    if ! echo "$snapshots" | grep -q "^${file1}$"; then
        echo "FAIL: file1 not in snapshot list"
        return 1
    fi

    if ! echo "$snapshots" | grep -q "^${file2}$"; then
        echo "FAIL: file2 not in snapshot list"
        return 1
    fi

    echo "PASS: List snapshots"
    return 0
}

# ============================================================================
# Test: Has Snapshots Check
# ============================================================================
test_has_snapshots() {
    echo "Testing has snapshots check..."

    local bead_id="nd-has"
    local test_file="${TEST_DIR}/has-test.txt"

    # Should not have snapshots initially
    if has_optimistic_snapshots "$bead_id"; then
        echo "FAIL: has_optimistic_snapshots should return false initially"
        return 1
    fi

    # Create snapshot
    echo "Content" > "$test_file"
    prepare_optimistic_edit "$test_file" "$bead_id" || true

    # Should have snapshots now
    if ! has_optimistic_snapshots "$bead_id"; then
        echo "FAIL: has_optimistic_snapshots should return true after creating snapshot"
        return 1
    fi

    echo "PASS: Has snapshots check"
    return 0
}

# ============================================================================
# Test: Get Optimistic Base
# ============================================================================
test_get_optimistic_base() {
    echo "Testing get optimistic base..."

    local bead_id="nd-base"
    local test_file="${TEST_DIR}/base-test.txt"
    local content="This is the base content"

    # Create file and snapshot
    echo "$content" > "$test_file"
    prepare_optimistic_edit "$test_file" "$bead_id" || true

    # Get base content
    local retrieved
    retrieved=$(get_optimistic_base "$bead_id" "$test_file")

    if [[ "$retrieved" != "$content" ]]; then
        echo "FAIL: Retrieved base content mismatch"
        echo "Expected: $content"
        echo "Got: $retrieved"
        return 1
    fi

    echo "PASS: Get optimistic base"
    return 0
}

# ============================================================================
# Test: Clean Merge Scenario (No Concurrent Modification)
# ============================================================================
test_reconcile_no_concurrent_modification() {
    echo "Testing reconcile with no concurrent modification..."

    local bead_id="nd-reconcile1"
    local test_file="${TEST_DIR}/reconcile-test.txt"
    local original="Original content"
    local modified="Modified by current bead"

    # Create file with original content
    echo "$original" > "$test_file"

    # Create snapshot
    prepare_optimistic_edit "$test_file" "$bead_id" || true

    # Modify the file (simulating agent edit)
    echo "$modified" > "$test_file"

    # Mock NEEDLE_WORKSPACE for git operations
    export NEEDLE_WORKSPACE="$TEST_DIR"

    # Initialize a git repo for the test
    cd "$TEST_DIR"
    git init -q 2>/dev/null || true
    git config user.email "test@test.com" 2>/dev/null || true
    git config user.name "Test" 2>/dev/null || true
    git add -A 2>/dev/null || true
    git commit -m "Initial" -q 2>/dev/null || true

    # Reconcile (should succeed since no concurrent modification)
    if ! reconcile_optimistic_edits "$bead_id" "$TEST_DIR"; then
        echo "FAIL: reconcile_optimistic_edits failed with no concurrent modification"
        return 1
    fi

    # File should still have our modification
    if [[ "$(cat "$test_file")" != "$modified" ]]; then
        echo "FAIL: File content changed during reconcile"
        return 1
    fi

    # Snapshots should be cleaned up
    if has_optimistic_snapshots "$bead_id"; then
        echo "FAIL: Snapshots not cleaned up after reconcile"
        return 1
    fi

    echo "PASS: Reconcile with no concurrent modification"
    return 0
}

# ============================================================================
# Test: Merge Tool Selection
# ============================================================================
test_merge_tool_selection() {
    echo "Testing merge tool selection..."

    # Default should be git-merge-file
    local tool
    tool=$(_needle_optimistic_get_merge_tool)

    if [[ "$tool" != "git-merge-file" ]]; then
        echo "FAIL: Default merge tool should be git-merge-file, got: $tool"
        return 1
    fi

    # Test environment variable override
    export NEEDLE_MERGE_TOOL="diff3"
    tool=$(_needle_optimistic_get_merge_tool)

    if [[ "$tool" != "diff3" ]]; then
        echo "FAIL: Environment override should work, got: $tool"
        return 1
    fi

    unset NEEDLE_MERGE_TOOL

    echo "PASS: Merge tool selection"
    return 0
}

# ============================================================================
# Test: Conflict Resolution Strategy
# ============================================================================
test_conflict_resolution_strategy() {
    echo "Testing conflict resolution strategy..."

    # Default should be block
    local strategy
    strategy=$(_needle_optimistic_get_on_conflict)

    if [[ "$strategy" != "block" ]]; then
        echo "FAIL: Default conflict strategy should be block, got: $strategy"
        return 1
    fi

    # Test environment variable override
    export NEEDLE_MERGE_ON_CONFLICT="keep_ours"
    strategy=$(_needle_optimistic_get_on_conflict)

    if [[ "$strategy" != "keep_ours" ]]; then
        echo "FAIL: Environment override should work, got: $strategy"
        return 1
    fi

    unset NEEDLE_MERGE_ON_CONFLICT

    echo "PASS: Conflict resolution strategy"
    return 0
}

# ============================================================================
# Test: Enabled Checks
# ============================================================================
test_enabled_checks() {
    echo "Testing enabled checks..."

    # Default should be pessimistic (not optimistic)
    if _needle_optimistic_is_enabled; then
        echo "FAIL: Optimistic should be disabled by default"
        return 1
    fi

    # Enable via environment variable
    export NEEDLE_FILE_LOCK_STRATEGY="optimistic"

    if ! _needle_optimistic_is_enabled; then
        echo "FAIL: Optimistic should be enabled when strategy is optimistic"
        return 1
    fi

    unset NEEDLE_FILE_LOCK_STRATEGY

    echo "PASS: Enabled checks"
    return 0
}

# ============================================================================
# Test: Multiple Files Reconciliation
# ============================================================================
test_multiple_files_reconciliation() {
    echo "Testing multiple files reconciliation..."

    local bead_id="nd-multi"
    local file1="${TEST_DIR}/multi1.txt"
    local file2="${TEST_DIR}/multi2.txt"

    # Initialize git repo first
    cd "$TEST_DIR"
    git init -q 2>/dev/null || true
    git config user.email "test@test.com" 2>/dev/null || true
    git config user.name "Test" 2>/dev/null || true

    # Create files
    echo "Content 1" > "$file1"
    echo "Content 2" > "$file2"

    # Commit initial state
    git add -A 2>/dev/null || true
    git commit -m "Initial" -q 2>/dev/null || true

    # Create snapshots for both
    prepare_optimistic_edit "$file1" "$bead_id" || true
    prepare_optimistic_edit "$file2" "$bead_id" || true

    # Modify both (simulating agent edit)
    echo "Modified 1" > "$file1"
    echo "Modified 2" > "$file2"

    # Verify both are tracked
    local count
    count=$(list_optimistic_snapshots "$bead_id" | wc -l)

    if [[ $count -ne 2 ]]; then
        echo "FAIL: Expected 2 tracked files, got $count"
        return 1
    fi

    # Reconcile - should succeed since we're the only modifier
    export NEEDLE_WORKSPACE="$TEST_DIR"
    if ! reconcile_optimistic_edits "$bead_id" "$TEST_DIR"; then
        echo "FAIL: Reconciliation failed (no concurrent modification expected)"
        return 1
    fi

    # Verify both files kept modifications
    if [[ "$(cat "$file1")" != "Modified 1" ]]; then
        echo "FAIL: file1 content incorrect"
        return 1
    fi

    if [[ "$(cat "$file2")" != "Modified 2" ]]; then
        echo "FAIL: file2 content incorrect"
        return 1
    fi

    echo "PASS: Multiple files reconciliation"
    return 0
}

# ============================================================================
# Run All Tests
# ============================================================================
run_tests() {
    local failed=0
    local passed=0

    setup

    # List of all test functions
    local tests=(
        "test_path_hash"
        "test_snapshot_creation"
        "test_snapshot_nonexistent_file"
        "test_snapshot_cleanup"
        "test_list_snapshots"
        "test_has_snapshots"
        "test_get_optimistic_base"
        "test_reconcile_no_concurrent_modification"
        "test_merge_tool_selection"
        "test_conflict_resolution_strategy"
        "test_enabled_checks"
        "test_multiple_files_reconciliation"
    )

    # Run each test
    for test_func in "${tests[@]}"; do
        echo ""
        echo "Running: $test_func"

        # Run test in subshell to isolate state
        if ( $test_func ); then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "===================================="
    echo "Tests passed: $passed"
    echo "Tests failed: $failed"
    echo "===================================="

    teardown

    if [[ $failed -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Run tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
    exit $?
fi
