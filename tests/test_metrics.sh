#!/usr/bin/env bash
# Tests for NEEDLE file collision metrics (src/lock/metrics.sh)

set -euo pipefail

# Test setup
TEST_DIR=$(mktemp -d)

# Source the module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_DIR/needle-home"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false

# Stub telemetry to avoid side effects
_needle_telemetry_emit() { return 0; }

# Source required modules
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lock/metrics.sh"

# Override paths to use test dir
NEEDLE_METRICS_DIR="$TEST_DIR/metrics"
NEEDLE_COLLISION_EVENTS="$NEEDLE_METRICS_DIR/collision_events.jsonl"

# Cleanup
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_case() {
    local name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing: $name... "
}

test_pass() {
    echo "PASS"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local reason="${1:-}"
    echo "FAIL"
    [[ -n "$reason" ]] && echo "  Reason: $reason"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Helper: reset metrics between tests
reset_metrics() {
    rm -rf "$NEEDLE_METRICS_DIR"
    mkdir -p "$NEEDLE_METRICS_DIR"
}

# ============================================================================
# Tests
# ============================================================================

echo "=== File Collision Metrics Tests ==="
echo ""

# Test 1: _needle_metrics_ensure_dir creates directory
test_case "_needle_metrics_ensure_dir creates directory"
reset_metrics
rm -rf "$NEEDLE_METRICS_DIR"
_needle_metrics_ensure_dir
if [[ -d "$NEEDLE_METRICS_DIR" ]]; then
    test_pass
else
    test_fail "Directory not created: $NEEDLE_METRICS_DIR"
fi

# Test 2: _needle_metrics_period_to_seconds handles hours
test_case "_needle_metrics_period_to_seconds converts 24h"
result=$(_needle_metrics_period_to_seconds "24h")
if [[ "$result" -eq 86400 ]]; then
    test_pass
else
    test_fail "Expected 86400, got $result"
fi

# Test 3: period to seconds handles days
test_case "_needle_metrics_period_to_seconds converts 7d"
result=$(_needle_metrics_period_to_seconds "7d")
if [[ "$result" -eq 604800 ]]; then
    test_pass
else
    test_fail "Expected 604800, got $result"
fi

# Test 4: period to seconds handles weeks
test_case "_needle_metrics_period_to_seconds converts 1w"
result=$(_needle_metrics_period_to_seconds "1w")
if [[ "$result" -eq 604800 ]]; then
    test_pass
else
    test_fail "Expected 604800, got $result"
fi

# Test 5: period to seconds handles minutes
test_case "_needle_metrics_period_to_seconds converts 60m"
result=$(_needle_metrics_period_to_seconds "60m")
if [[ "$result" -eq 3600 ]]; then
    test_pass
else
    test_fail "Expected 3600, got $result"
fi

# Test 6: _needle_metrics_record_event creates events file
test_case "_needle_metrics_record_event creates events file"
reset_metrics
_needle_metrics_record_event "checkout.attempt" "nd-test" "/tmp/test.sh" 2>/dev/null
if [[ -f "$NEEDLE_COLLISION_EVENTS" ]]; then
    test_pass
else
    test_fail "Events file not created: $NEEDLE_COLLISION_EVENTS"
fi

# Test 7: record_event writes valid JSON
test_case "_needle_metrics_record_event writes valid JSON"
reset_metrics
_needle_metrics_record_event "checkout.attempt" "nd-abc" "/tmp/foo.sh" 2>/dev/null
line=$(cat "$NEEDLE_COLLISION_EVENTS" | head -1)
event_type=$(echo "$line" | jq -r '.event' 2>/dev/null)
if [[ "$event_type" == "file.checkout.attempt" ]]; then
    test_pass
else
    test_fail "Expected event 'file.checkout.attempt', got '$event_type'"
fi

# Test 8: record_event includes bead and path
test_case "_needle_metrics_record_event includes bead and path in data"
reset_metrics
_needle_metrics_record_event "checkout.acquired" "nd-xyz" "/src/run.sh" 2>/dev/null
line=$(cat "$NEEDLE_COLLISION_EVENTS" | head -1)
bead=$(echo "$line" | jq -r '.data.bead' 2>/dev/null)
path=$(echo "$line" | jq -r '.data.path' 2>/dev/null)
if [[ "$bead" == "nd-xyz" ]] && [[ "$path" == "/src/run.sh" ]]; then
    test_pass
else
    test_fail "Expected bead='nd-xyz' path='/src/run.sh', got bead='$bead' path='$path'"
fi

# Test 9: record_event includes extra key=value pairs
test_case "_needle_metrics_record_event includes extra fields"
reset_metrics
_needle_metrics_record_event "checkout.blocked" "nd-1" "/tmp/b.sh" "blocked_by=nd-2" 2>/dev/null
line=$(cat "$NEEDLE_COLLISION_EVENTS" | head -1)
blocked_by=$(echo "$line" | jq -r '.data.blocked_by' 2>/dev/null)
if [[ "$blocked_by" == "nd-2" ]]; then
    test_pass
else
    test_fail "Expected blocked_by='nd-2', got '$blocked_by'"
fi

# Test 10: multiple events are appended
test_case "_needle_metrics_record_event appends multiple events"
reset_metrics
_needle_metrics_record_event "checkout.attempt"  "nd-a" "/tmp/x.sh" 2>/dev/null
_needle_metrics_record_event "checkout.acquired" "nd-a" "/tmp/x.sh" 2>/dev/null
_needle_metrics_record_event "checkout.blocked"  "nd-b" "/tmp/x.sh" "blocked_by=nd-a" 2>/dev/null
count=$(wc -l < "$NEEDLE_COLLISION_EVENTS")
if [[ "$count" -eq 3 ]]; then
    test_pass
else
    test_fail "Expected 3 lines, got $count"
fi

# Test 11: _needle_metrics_event_count returns correct count
test_case "_needle_metrics_event_count returns event count"
reset_metrics
_needle_metrics_record_event "checkout.attempt" "nd-a" "/tmp/a.sh" 2>/dev/null
_needle_metrics_record_event "checkout.attempt" "nd-b" "/tmp/b.sh" 2>/dev/null
count=$(_needle_metrics_event_count)
if [[ "$count" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected 2, got $count"
fi

# Test 12: _needle_metrics_event_count returns 0 with no file
test_case "_needle_metrics_event_count returns 0 when no events"
reset_metrics
count=$(_needle_metrics_event_count)
if [[ "$count" -eq 0 ]]; then
    test_pass
else
    test_fail "Expected 0, got $count"
fi

# Test 13: _needle_metrics_aggregate returns valid JSON with no events
test_case "_needle_metrics_aggregate returns valid JSON with no events"
reset_metrics
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
period=$(echo "$metrics" | jq -r '.period' 2>/dev/null)
if [[ "$period" == "24h" ]]; then
    test_pass
else
    test_fail "Expected period='24h', got '$period'"
fi

# Test 14: aggregate returns zero totals when no events
test_case "_needle_metrics_aggregate returns zero totals with no events"
reset_metrics
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
attempts=$(echo "$metrics" | jq -r '.totals.checkout_attempts' 2>/dev/null)
if [[ "$attempts" -eq 0 ]]; then
    test_pass
else
    test_fail "Expected 0 attempts, got $attempts"
fi

# Test 15: aggregate counts checkout_attempts correctly
test_case "_needle_metrics_aggregate counts checkout_attempts"
reset_metrics
_needle_metrics_record_event "checkout.attempt" "nd-a" "/tmp/a.sh" 2>/dev/null
_needle_metrics_record_event "checkout.attempt" "nd-b" "/tmp/b.sh" 2>/dev/null
_needle_metrics_record_event "checkout.attempt" "nd-c" "/tmp/c.sh" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
attempts=$(echo "$metrics" | jq -r '.totals.checkout_attempts' 2>/dev/null)
if [[ "$attempts" -eq 3 ]]; then
    test_pass
else
    test_fail "Expected 3 attempts, got $attempts"
fi

# Test 16: aggregate counts checkouts_blocked correctly
test_case "_needle_metrics_aggregate counts checkouts_blocked"
reset_metrics
_needle_metrics_record_event "checkout.blocked" "nd-a" "/tmp/a.sh" "blocked_by=nd-b" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-c" "/tmp/a.sh" "blocked_by=nd-b" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
blocked=$(echo "$metrics" | jq -r '.totals.checkouts_blocked' 2>/dev/null)
if [[ "$blocked" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected 2 blocked, got $blocked"
fi

# Test 17: aggregate builds hot_files list
test_case "_needle_metrics_aggregate builds hot_files list"
reset_metrics
_needle_metrics_record_event "checkout.blocked" "nd-a" "/src/cli/run.sh" "blocked_by=nd-b" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-c" "/src/cli/run.sh" "blocked_by=nd-b" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-d" "/src/cli/run.sh" "blocked_by=nd-b" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-e" "/src/lib/output.sh" "blocked_by=nd-b" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
hot_count=$(echo "$metrics" | jq '.hot_files | length' 2>/dev/null)
top_file=$(echo "$metrics" | jq -r '.hot_files[0].path' 2>/dev/null)
top_conflicts=$(echo "$metrics" | jq -r '.hot_files[0].conflicts' 2>/dev/null)
if [[ "$hot_count" -ge 1 ]] && [[ "$top_file" == "/src/cli/run.sh" ]] && [[ "$top_conflicts" -eq 3 ]]; then
    test_pass
else
    test_fail "Expected hot_file='/src/cli/run.sh' conflicts=3, got hot_count=$hot_count top_file='$top_file' top_conflicts=$top_conflicts"
fi

# Test 18: aggregate builds conflict_pairs
test_case "_needle_metrics_aggregate builds conflict_pairs"
reset_metrics
_needle_metrics_record_event "checkout.blocked" "nd-waiter" "/src/run.sh" "blocked_by=nd-owner" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-waiter" "/src/run.sh" "blocked_by=nd-owner" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
pairs_count=$(echo "$metrics" | jq '.conflict_pairs | length' 2>/dev/null)
bead_a=$(echo "$metrics" | jq -r '.conflict_pairs[0].bead_a' 2>/dev/null)
bead_b=$(echo "$metrics" | jq -r '.conflict_pairs[0].bead_b' 2>/dev/null)
if [[ "$pairs_count" -ge 1 ]] && [[ "$bead_a" == "nd-waiter" ]] && [[ "$bead_b" == "nd-owner" ]]; then
    test_pass
else
    test_fail "Expected pair bead_a=nd-waiter bead_b=nd-owner, got bead_a=$bead_a bead_b=$bead_b pairs_count=$pairs_count"
fi

# Test 19: convenience functions work correctly
test_case "_needle_metrics_checkout_attempt records attempt event"
reset_metrics
_needle_metrics_checkout_attempt "nd-test" "/tmp/file.sh" 2>/dev/null
event_type=$(jq -r '.event' "$NEEDLE_COLLISION_EVENTS" 2>/dev/null)
if [[ "$event_type" == "file.checkout.attempt" ]]; then
    test_pass
else
    test_fail "Expected 'file.checkout.attempt', got '$event_type'"
fi

# Test 20: _needle_metrics_checkout_blocked records correct event type
test_case "_needle_metrics_checkout_blocked records blocked event"
reset_metrics
_needle_metrics_checkout_blocked "nd-waiter" "/tmp/file.sh" "blocked_by=nd-owner" 2>/dev/null
event_type=$(jq -r '.event' "$NEEDLE_COLLISION_EVENTS" 2>/dev/null)
if [[ "$event_type" == "file.checkout.blocked" ]]; then
    test_pass
else
    test_fail "Expected 'file.checkout.blocked', got '$event_type'"
fi

# Test 21: _needle_metrics_clear removes events file
test_case "_needle_metrics_clear removes events file"
reset_metrics
_needle_metrics_record_event "checkout.attempt" "nd-a" "/tmp/x.sh" 2>/dev/null
_needle_metrics_clear
if [[ ! -f "$NEEDLE_COLLISION_EVENTS" ]]; then
    test_pass
else
    test_fail "Events file should be removed after clear"
fi

# Test 22: hot_files sorted by descending conflicts
test_case "_needle_metrics_aggregate hot_files sorted by conflicts desc"
reset_metrics
_needle_metrics_record_event "checkout.blocked" "nd-a" "/src/rarely.sh"  "blocked_by=nd-x" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-a" "/src/hotfile.sh" "blocked_by=nd-x" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-b" "/src/hotfile.sh" "blocked_by=nd-x" 2>/dev/null
_needle_metrics_record_event "checkout.blocked" "nd-c" "/src/hotfile.sh" "blocked_by=nd-x" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
top_file=$(echo "$metrics" | jq -r '.hot_files[0].path' 2>/dev/null)
if [[ "$top_file" == "/src/hotfile.sh" ]]; then
    test_pass
else
    test_fail "Expected '/src/hotfile.sh' as top hot file, got '$top_file'"
fi

# Test 23: conflict.prevented events are counted
test_case "_needle_metrics_aggregate counts conflicts_prevented"
reset_metrics
_needle_metrics_conflict_prevented "nd-a" "/tmp/x.sh" "blocked_by=nd-b" 2>/dev/null
_needle_metrics_conflict_prevented "nd-c" "/tmp/y.sh" "blocked_by=nd-b" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
prevented=$(echo "$metrics" | jq -r '.totals.conflicts_prevented' 2>/dev/null)
if [[ "$prevented" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected 2 conflicts_prevented, got $prevented"
fi

# Test 24: conflict.missed events are counted
test_case "_needle_metrics_aggregate counts conflicts_missed"
reset_metrics
_needle_metrics_conflict_missed "nd-a" "/tmp/x.sh" 2>/dev/null
metrics=$(_needle_metrics_aggregate "24h" 2>/dev/null)
missed=$(echo "$metrics" | jq -r '.totals.conflicts_missed' 2>/dev/null)
if [[ "$missed" -eq 1 ]]; then
    test_pass
else
    test_fail "Expected 1 conflicts_missed, got $missed"
fi

# Test 25: _needle_metrics_prune removes old events (basic sanity)
test_case "_needle_metrics_prune runs without error"
reset_metrics
_needle_metrics_record_event "checkout.attempt" "nd-a" "/tmp/a.sh" 2>/dev/null
_needle_metrics_prune "30d" 2>/dev/null && test_pass || test_fail "prune returned error"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=== Results ==="
echo "Passed: $TESTS_PASSED / $TESTS_RUN"
echo "Failed: $TESTS_FAILED / $TESTS_RUN"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
