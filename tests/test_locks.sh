#!/usr/bin/env bash
# Tests for NEEDLE claim lock module (src/lib/locks.sh)
# Regression test for nd-q3cstb: Thundering herd fix

# Test setup - create temp directory
TEST_DIR=$(mktemp -d)

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false

# Source required modules
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/locks.sh"

# Cleanup function
cleanup() {
    rm -rf "$TEST_DIR"
    # Clean up any stale locks
    rm -rf /dev/shm/needle-claim/* 2>/dev/null || true
}
trap cleanup EXIT

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper
test_case() {
    local name="$1"
    ((TESTS_RUN++))
    echo -n "Testing: $name... "
}

test_pass() {
    echo "PASS"
    ((TESTS_PASSED++))
}

test_fail() {
    local reason="${1:-}"
    echo "FAIL"
    [[ -n "$reason" ]] && echo "  Reason: $reason"
    ((TESTS_FAILED++))
}

echo "=== NEEDLE Claim Lock Tests (nd-q3cstb) ==="
echo ""

# ============================================================================
# Test Lock Hash Function
# ============================================================================

test_case "Lock hash generates consistent output for same workspace"
hash1=$(_needle_claim_lock_hash "/home/coder/NEEDLE")
hash2=$(_needle_claim_lock_hash "/home/coder/NEEDLE")
if [[ "$hash1" == "$hash2" ]] && [[ ${#hash1} -eq 12 ]]; then
    test_pass
else
    test_fail "Expected identical 12-char hashes, got '$hash1' vs '$hash2'"
fi

test_case "Lock hash generates different output for different workspaces"
hash1=$(_needle_claim_lock_hash "/home/coder/NEEDLE")
hash2=$(_needle_claim_lock_hash "/home/coder/OTHER")
if [[ "$hash1" != "$hash2" ]]; then
    test_pass
else
    test_fail "Expected different hashes for different workspaces"
fi

test_case "Lock hash handles empty workspace"
hash=$(_needle_claim_lock_hash "")
if [[ "$hash" == "default" ]]; then
    test_pass
else
    test_fail "Expected 'default' for empty workspace, got '$hash'"
fi

# ============================================================================
# Test Lock Directory Path
# ============================================================================

test_case "Lock directory path is correct"
lock_dir=$(_needle_claim_lock_dir "/home/coder/NEEDLE")
expected_prefix="/dev/shm/needle-claim/"
if [[ "$lock_dir" == ${expected_prefix}* ]]; then
    test_pass
else
    test_fail "Expected path starting with $expected_prefix, got '$lock_dir'"
fi

# ============================================================================
# Test Lock Acquisition and Release
# ============================================================================

test_case "Acquire and release lock successfully"
if _needle_acquire_claim_lock "$TEST_DIR"; then
    if [[ "$NEEDLE_CLAIM_LOCK_ACQUIRED" == "1" ]] && [[ -n "$NEEDLE_CLAIM_LOCK_DIR_HELD" ]]; then
        _needle_release_claim_lock "$TEST_DIR"
        if [[ "$NEEDLE_CLAIM_LOCK_ACQUIRED" != "1" ]]; then
            test_pass
        else
            test_fail "Lock flag not cleared after release"
        fi
    else
        test_fail "Lock not properly acquired (flag not set)"
    fi
else
    test_fail "Failed to acquire lock"
fi

test_case "Lock directory exists while held"
if _needle_acquire_claim_lock "$TEST_DIR"; then
    lock_dir=$(_needle_claim_lock_dir "$TEST_DIR")
    if [[ -d "$lock_dir" ]]; then
        _needle_release_claim_lock "$TEST_DIR"
        test_pass
    else
        _needle_release_claim_lock "$TEST_DIR"
        test_fail "Lock directory does not exist while held"
    fi
else
    test_fail "Failed to acquire lock"
fi

test_case "Lock directory is removed after release"
lock_dir=$(_needle_claim_lock_dir "$TEST_DIR")
if _needle_acquire_claim_lock "$TEST_DIR"; then
    _needle_release_claim_lock "$TEST_DIR"
    if [[ ! -d "$lock_dir" ]]; then
        test_pass
    else
        test_fail "Lock directory still exists after release"
    fi
else
    test_fail "Failed to acquire lock"
fi

test_case "Lock timestamp file is created"
if _needle_acquire_claim_lock "$TEST_DIR"; then
    lock_dir=$(_needle_claim_lock_dir "$TEST_DIR")
    if [[ -f "${lock_dir}/timestamp" ]] && [[ -f "${lock_dir}/pid" ]]; then
        _needle_release_claim_lock "$TEST_DIR"
        test_pass
    else
        _needle_release_claim_lock "$TEST_DIR"
        test_fail "Timestamp or PID file not created"
    fi
else
    test_fail "Failed to acquire lock"
fi

# ============================================================================
# Test Lock Contention
# ============================================================================

test_case "Second acquire fails while lock is held"
if _needle_acquire_claim_lock "$TEST_DIR"; then
    # Try to acquire again (should fail after retries)
    NEEDLE_CLAIM_LOCK_MAX_RETRIES=2
    if ! _needle_acquire_claim_lock "$TEST_DIR" 2>/dev/null; then
        _needle_release_claim_lock "$TEST_DIR"
        test_pass
    else
        _needle_release_claim_lock "$TEST_DIR"
        test_fail "Second acquire should have failed"
    fi
else
    test_fail "Initial acquire failed"
fi

test_case "Lock can be re-acquired after release"
if _needle_acquire_claim_lock "$TEST_DIR"; then
    _needle_release_claim_lock "$TEST_DIR"
    if _needle_acquire_claim_lock "$TEST_DIR"; then
        _needle_release_claim_lock "$TEST_DIR"
        test_pass
    else
        test_fail "Could not re-acquire after release"
    fi
else
    test_fail "Initial acquire failed"
fi

# ============================================================================
# Test Stale Lock Detection
# ============================================================================

test_case "Stale lock is detected correctly"
lock_dir=$(_needle_claim_lock_dir "$TEST_DIR")
mkdir -p "$lock_dir"

# Create an old timestamp (35 seconds ago)
old_ts=$(($(date +%s) - 35))
echo "$old_ts" > "${lock_dir}/timestamp"

if _needle_claim_lock_is_stale "$lock_dir"; then
    rm -rf "$lock_dir"
    test_pass
else
    rm -rf "$lock_dir"
    test_fail "Old lock should be detected as stale"
fi

test_case "Fresh lock is not detected as stale"
lock_dir=$(_needle_claim_lock_dir "$TEST_DIR")
mkdir -p "$lock_dir"

# Create a fresh timestamp
echo "$(date +%s)" > "${lock_dir}/timestamp"

if ! _needle_claim_lock_is_stale "$lock_dir"; then
    rm -rf "$lock_dir"
    test_pass
else
    rm -rf "$lock_dir"
    test_fail "Fresh lock should not be detected as stale"
fi

test_case "Stale lock is auto-cleaned on acquire"
lock_dir=$(_needle_claim_lock_dir "$TEST_DIR")
mkdir -p "$lock_dir"

# Create an old timestamp
old_ts=$(($(date +%s) - 35))
echo "$old_ts" > "${lock_dir}/timestamp"

# Acquire should succeed by cleaning up the stale lock
if _needle_acquire_claim_lock "$TEST_DIR"; then
    _needle_release_claim_lock "$TEST_DIR"
    test_pass
else
    test_fail "Acquire should succeed with stale lock cleanup"
fi

# ============================================================================
# Test Different Workspaces Don't Block Each Other
# ============================================================================

test_case "Different workspaces have independent locks"
ws1="${TEST_DIR}/workspace1"
ws2="${TEST_DIR}/workspace2"
mkdir -p "$ws1" "$ws2"

if _needle_acquire_claim_lock "$ws1"; then
    if _needle_acquire_claim_lock "$ws2"; then
        _needle_release_claim_lock "$ws2"
        _needle_release_claim_lock "$ws1"
        test_pass
    else
        _needle_release_claim_lock "$ws1"
        test_fail "Should be able to acquire lock on different workspace"
    fi
else
    test_fail "Failed to acquire first lock"
fi

# ============================================================================
# Test Lock Performance
# ============================================================================

test_case "Lock acquisition completes in <50ms"
start_ns=$(date +%s%N)
if _needle_acquire_claim_lock "$TEST_DIR"; then
    end_ns=$(date +%s%N)
    _needle_release_claim_lock "$TEST_DIR"
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    if [[ $elapsed_ms -lt 50 ]]; then
        test_pass "(${elapsed_ms}ms)"
    else
        test_fail "Lock acquisition took ${elapsed_ms}ms (expected <50ms)"
    fi
else
    test_fail "Failed to acquire lock"
fi

test_case "Lock release completes in <10ms"
if _needle_acquire_claim_lock "$TEST_DIR"; then
    start_ns=$(date +%s%N)
    _needle_release_claim_lock "$TEST_DIR"
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    if [[ $elapsed_ms -lt 10 ]]; then
        test_pass "(${elapsed_ms}ms)"
    else
        test_fail "Lock release took ${elapsed_ms}ms (expected <10ms)"
    fi
else
    test_fail "Failed to acquire lock"
fi

# ============================================================================
# Test Concurrent Workers (Thundering Herd Scenario)
# ============================================================================

echo ""
echo "--- Thundering Herd Tests (nd-q3cstb) ---"

test_case "Multiple concurrent workers get serialized by lock"
# Create a shared result file
RESULT_FILE="$TEST_DIR/concurrent_results"
echo "" > "$RESULT_FILE"

# Function that tries to claim and records timing
run_claim_simulation() {
    local worker_id="$1"
    local workspace="$2"
    local result_file="$3"

    # Try to acquire the lock
    if _needle_acquire_claim_lock "$workspace" 2>/dev/null; then
        # Record that this worker got the lock
        local ts
        ts=$(date +%s%N)
        echo "${worker_id}:${ts}" >> "$result_file"
        # Simulate claim work (10ms)
        sleep 0.01
        _needle_release_claim_lock "$workspace"
        return 0
    else
        return 1
    fi
}
export -f run_claim_simulation _needle_acquire_claim_lock _needle_release_claim_lock
export _needle_claim_lock_hash _needle_claim_lock_dir _needle_claim_lock_ensure_dir
export _needle_claim_lock_is_stale _needle_claim_backoff_delay _needle_sleep_ms
export NEEDLE_CLAIM_LOCK_DIR NEEDLE_CLAIM_LOCK_TIMEOUT NEEDLE_CLAIM_LOCK_MAX_RETRIES NEEDLE_CLAIM_LOCK_BASE_DELAY_MS

# Spawn 5 workers targeting the same workspace
for i in {1..5}; do
    NEEDLE_CLAIM_LOCK_MAX_RETRIES=3 run_claim_simulation "worker-$i" "$TEST_DIR" "$RESULT_FILE" &
done

# Wait for all workers
wait

# Count how many workers succeeded
success_count=$(wc -l < "$RESULT_FILE" | tr -d ' ')

if [[ "$success_count" -ge 3 ]]; then
    # At least 3 of 5 workers should have succeeded (with retries)
    test_pass "($success_count/5 workers succeeded with serialization)"
else
    test_fail "Only $success_count/5 workers succeeded (expected >=3)"
fi

test_case "No two workers claim simultaneously (serialized by lock)"
# Check the timestamps in the result file - they should be at least 10ms apart
# because each worker holds the lock for 10ms
RESULT_FILE2="$TEST_DIR/serialized_results"
echo "" > "$RESULT_FILE2"

# Run 3 workers with longer hold time
run_serialized_test() {
    local worker_id="$1"
    local workspace="$2"
    local result_file="$3"

    NEEDLE_CLAIM_LOCK_MAX_RETRIES=10
    if _needle_acquire_claim_lock "$workspace" 2>/dev/null; then
        ts=$(date +%s%N)
        echo "${worker_id}:${ts}" >> "$result_file"
        sleep 0.02  # Hold for 20ms
        _needle_release_claim_lock "$workspace"
        return 0
    else
        return 1
    fi
}
export -f run_serialized_test

# Clear previous locks
rm -rf /dev/shm/needle-claim/* 2>/dev/null || true

for i in {1..3}; do
    run_serialized_test "worker-$i" "$TEST_DIR" "$RESULT_FILE2" &
done
wait

# Parse timestamps and verify they're at least 15ms apart
all_serialized=true
prev_ts=0
while IFS=: read -r worker ts; do
    if [[ -n "$ts" ]] && [[ $prev_ts -gt 0 ]]; then
        diff_ns=$((ts - prev_ns))
        diff_ms=$((diff_ns / 1000000))
        if [[ $diff_ms -lt 15 ]]; then
            all_serialized=false
            break
        fi
    fi
    prev_ts=$ts
    prev_ns=${ts%%:*}
done < "$RESULT_FILE2"

if $all_serialized; then
    test_pass "(workers were properly serialized)"
else
    test_fail "Workers claimed too close together (not properly serialized)"
fi

# ============================================================================
# Test Cleanup Function
# ============================================================================

test_case "Cleanup removes stale locks"
# Create some stale locks
lock_dir1="${NEEDLE_CLAIM_LOCK_DIR}/stale1"
lock_dir2="${NEEDLE_CLAIM_LOCK_DIR}/stale2"
mkdir -p "$lock_dir1" "$lock_dir2"

# Make them stale
old_ts=$(($(date +%s) - 35))
echo "$old_ts" > "${lock_dir1}/timestamp"
echo "$old_ts" > "${lock_dir2}/timestamp"

cleaned=$(_needle_cleanup_stale_claim_locks)
cleaned=${cleaned:-0}

if [[ ! -d "$lock_dir1" ]] && [[ ! -d "$lock_dir2" ]]; then
    test_pass "(cleaned $cleaned stale locks)"
else
    test_fail "Stale locks not cleaned up"
fi

# ============================================================================
# Test Backoff Calculation
# ============================================================================

test_case "Backoff delay increases with attempts"
delay1=$(_needle_claim_backoff_delay 1)
delay2=$(_needle_claim_backoff_delay 2)
delay3=$(_needle_claim_backoff_delay 3)

if [[ $delay2 -gt $delay1 ]] && [[ $delay3 -gt $delay2 ]]; then
    test_pass "(delays: ${delay1}ms, ${delay2}ms, ${delay3}ms)"
else
    test_fail "Backoff should increase: got ${delay1}ms, ${delay2}ms, ${delay3}ms"
fi

test_case "Backoff delay is capped at 500ms"
delay10=$(_needle_claim_backoff_delay 10)
delay20=$(_needle_claim_backoff_delay 20)

if [[ $delay10 -le 750 ]] && [[ $delay20 -le 750 ]]; then
    # Allow for jitter (500ms + 50% jitter = 750ms max)
    test_pass "(delay capped with jitter: ${delay10}ms, ${delay20}ms)"
else
    test_fail "Backoff should be capped: got ${delay10}ms, ${delay20}ms"
fi

# ============================================================================
# Test Lock Wrapper Function
# ============================================================================

test_case "_needle_with_claim_lock executes command with lock"
result=$(_needle_with_claim_lock "$TEST_DIR" -- echo "hello")
if [[ "$result" == "hello" ]]; then
    test_pass
else
    test_fail "Expected 'hello', got '$result'"
fi

test_case "_needle_with_claim_lock releases lock after command"
# First execution should release the lock
_needle_with_claim_lock "$TEST_DIR" -- echo "first" >/dev/null

# Second execution should succeed (lock was released)
if _needle_with_claim_lock "$TEST_DIR" -- echo "second" >/dev/null; then
    test_pass
else
    test_fail "Second execution failed (lock may not have been released)"
fi

# Print summary
echo ""
echo "=== Test Summary ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo "All tests passed!"
    exit 0
else
    echo ""
    echo "Some tests failed!"
    exit 1
fi
