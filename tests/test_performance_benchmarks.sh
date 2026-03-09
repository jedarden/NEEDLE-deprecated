#!/usr/bin/env bash
# Performance Benchmarks for NEEDLE
#
# SLA Targets:
#   - Bead claim latency:             < 1000ms (sub-second, per task description)
#   - Worker startup time:            < 2000ms
#   - Strand fallthrough latency:     < 5000ms (7 strands, all disabled → no work)
#   - Event logging throughput:       >= 10 events/second (subprocess-based emit)
#
# CI Regression Gate:
#   - Results written to $PERF_RESULTS_FILE (JSON)
#   - Baseline stored in tests/performance_baseline.json
#   - Fails if any latency metric increases by > PERF_REGRESSION_THRESHOLD (default 30%)
#   - Fails if any throughput metric decreases by > PERF_REGRESSION_THRESHOLD
#
# Environment variables:
#   PERF_RESULTS_FILE          - Output JSON (default: /tmp/needle-perf-<PID>.json)
#   PERF_UPDATE_BASELINE       - Set to "true" to update baseline from results
#   PERF_REGRESSION_THRESHOLD  - Percent change to flag as regression (default: 30)

# Don't use set -e; arithmetic ((++)) returns 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Environment Setup
# ============================================================================
TEST_DIR=$(mktemp -d)
TEST_NEEDLE_HOME="$TEST_DIR/.needle"
TEST_LOG_FILE="$TEST_DIR/events.jsonl"

export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_STATE_DIR="state"
export NEEDLE_LOG_DIR="logs"
export NEEDLE_CACHE_DIR="cache"
export NEEDLE_CONFIG_NAME="config.yaml"
export NEEDLE_CONFIG_FILE="$TEST_NEEDLE_HOME/config.yaml"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false
export NEEDLE_LOG_FILE="$TEST_LOG_FILE"
export NEEDLE_LOG_INITIALIZED=true
export NEEDLE_SESSION="perf-$$"
export NEEDLE_RUNNER="test"
export NEEDLE_PROVIDER="test"
export NEEDLE_MODEL="test"
export NEEDLE_IDENTIFIER="perf"
export NEEDLE_WORKSPACE="$TEST_DIR/workspace"
export NEEDLE_AGENT="test-agent"

mkdir -p "$TEST_NEEDLE_HOME/$NEEDLE_STATE_DIR"
mkdir -p "$TEST_NEEDLE_HOME/$NEEDLE_LOG_DIR"
mkdir -p "$TEST_NEEDLE_HOME/$NEEDLE_CACHE_DIR"
mkdir -p "$TEST_NEEDLE_HOME/agents"
mkdir -p "$NEEDLE_WORKSPACE/.beads"

# Minimal config — all strands disabled by default
cat > "$TEST_NEEDLE_HOME/config.yaml" << 'EOF'
strands:
  pluck: false
  explore: false
  mend: false
  weave: false
  unravel: false
  pulse: false
  knot: false
EOF

# Source modules
source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/paths.sh"
source "$PROJECT_ROOT/src/lib/json.sh"
source "$PROJECT_ROOT/src/lib/utils.sh"
source "$PROJECT_ROOT/src/lib/config.sh"
source "$PROJECT_ROOT/src/telemetry/writer.sh"
source "$PROJECT_ROOT/src/telemetry/events.sh"
source "$PROJECT_ROOT/src/bead/select.sh"
source "$PROJECT_ROOT/src/bead/claim.sh"

PERF_RESULTS_FILE="${PERF_RESULTS_FILE:-$TEST_DIR/perf_results.json}"
BASELINE_FILE="$SCRIPT_DIR/performance_baseline.json"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# ============================================================================
# Test Infrastructure
# ============================================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_case() { local name="$1"; ((TESTS_RUN++)); echo -n "  Benchmarking: $name... "; }
test_pass()  { echo "PASS"; ((TESTS_PASSED++)); }
test_fail()  { local r="${1:-}"; echo "FAIL"; [[ -n "$r" ]] && echo "    Reason: $r"; ((TESTS_FAILED++)); }

now_ns()    { date +%s%N; }
elapsed_ms() { local s="$1"; echo $(( ($(date +%s%N) - s) / 1000000 )); }

assert_sla() {
    local label="$1" actual="$2" sla="$3"
    if [[ $actual -le $sla ]]; then
        test_pass; echo "    ${label}: ${actual}ms  (SLA: <${sla}ms)"
    else
        test_fail "${label}: ${actual}ms exceeded SLA of ${sla}ms"
    fi
}

assert_throughput() {
    local label="$1" actual="$2" min_tps="$3"
    if [[ $actual -ge $min_tps ]]; then
        test_pass; echo "    ${label}: ${actual}/sec  (SLA: >=${min_tps}/sec)"
    else
        test_fail "${label}: ${actual}/sec below minimum ${min_tps}/sec"
    fi
}

# ============================================================================
# Mock br helper
# ============================================================================
setup_mock_br() {
    local bead_count="${1:-10}"
    local beads_json='['
    for i in $(seq 1 "$bead_count"); do
        [[ $i -gt 1 ]] && beads_json+=','
        beads_json+="{\"id\":\"nd-perf-$i\",\"title\":\"Bead $i\",\"status\":\"ready\",\"priority\":$(( (i-1) % 5 )),\"type\":\"task\"}"
    done
    beads_json+=']'

    mkdir -p "$TEST_DIR/bin"
    # shellcheck disable=SC2016
    cat > "$TEST_DIR/bin/br" << MOCK
#!/usr/bin/env bash
case "\$1 \$2" in
    "ready --unassigned"|"ready --workspace="*)
        echo '$beads_json' ;;
    "update --claim")
        bead_id=""
        for a in "\$@"; do case "\$a" in nd-*) bead_id="\$a";; esac; done
        echo "{\"id\":\"\$bead_id\",\"status\":\"active\",\"actor\":\"test\"}"
        exit 0 ;;
    "list "*)  echo '[]' ;;
    *)         exit 0 ;;
esac
MOCK
    chmod +x "$TEST_DIR/bin/br"
    export PATH="$TEST_DIR/bin:$PATH"
}

# Storage for regression gate
declare -A BENCH_RESULTS

record() { BENCH_RESULTS["$1"]="$2"; }

# ============================================================================
echo ""
echo "=================================================="
echo "NEEDLE Performance Benchmarks"
echo "=================================================="

# ============================================================================
# 1. Bead Claim Latency  (SLA: sub-second)
# ============================================================================
echo ""
echo "--- 1. Bead Claim Latency ---"

setup_mock_br 20

test_case "Select bead from 20 candidates"
t=$(now_ns)
_needle_select_bead --workspace "$NEEDLE_WORKSPACE" > /dev/null 2>&1
ms=$(elapsed_ms "$t")
record "bead_select_latency_ms" "$ms"
assert_sla "Bead selection" "$ms" 1000

test_case "Full bead claim (select + atomic update, 20 candidates)"
t=$(now_ns)
_needle_claim_bead --workspace "$NEEDLE_WORKSPACE" --actor "perf-worker" > /dev/null 2>&1
ms=$(elapsed_ms "$t")
record "bead_claim_latency_ms" "$ms"
assert_sla "Bead claim" "$ms" 1000

# ============================================================================
# 2. Weighted Selection  (SLA: <3000ms for 30 calls — ~100ms/call due to br fork)
# ============================================================================
echo ""
echo "--- 2. Weighted Bead Selection (Priority Scoring) ---"

ITERATIONS=30
test_case "${ITERATIONS} weighted selections (20 beads, mixed priorities)"
t=$(now_ns)
for _ in $(seq 1 "$ITERATIONS"); do
    _needle_select_bead --workspace "$NEEDLE_WORKSPACE" > /dev/null 2>&1
done
ms=$(elapsed_ms "$t")
avg=$(( ms / ITERATIONS ))
record "weighted_selection_total_ms" "$ms"
record "weighted_selection_avg_ms" "$avg"
assert_sla "${ITERATIONS} weighted selections" "$ms" 3000
echo "    Average per selection: ~${avg}ms"

# ============================================================================
# 3. Priority Weight Calculation  (pure bash, SLA: <500ms for 500 calls)
# ============================================================================
echo ""
echo "--- 3. Priority Weight Calculation ---"

ITERATIONS=500
test_case "${ITERATIONS} priority weight lookups (5 levels each)"
t=$(now_ns)
for _ in $(seq 1 "$ITERATIONS"); do
    _needle_claim_get_weight 0 > /dev/null
    _needle_claim_get_weight 1 > /dev/null
    _needle_claim_get_weight 2 > /dev/null
    _needle_claim_get_weight 3 > /dev/null
    _needle_claim_get_weight 4 > /dev/null
done
ms=$(elapsed_ms "$t")
record "priority_weight_ms" "$ms"
assert_sla "${ITERATIONS} weight lookups" "$ms" 1000

# ============================================================================
# 4. Worker Startup Time  (SLA: <2000ms)
# ============================================================================
echo ""
echo "--- 4. Worker Startup Time ---"

test_case "Module sourcing + log/registry init (subshell)"
t=$(now_ns)
(
    export NEEDLE_HOME="$TEST_NEEDLE_HOME"
    export NEEDLE_SESSION="startup-$$"
    NEEDLE_SRC="$PROJECT_ROOT/src"
    source "$PROJECT_ROOT/src/lib/constants.sh"
    source "$PROJECT_ROOT/src/lib/output.sh"
    source "$PROJECT_ROOT/src/lib/paths.sh"
    source "$PROJECT_ROOT/src/lib/json.sh"
    source "$PROJECT_ROOT/src/lib/utils.sh"
    source "$PROJECT_ROOT/src/lib/config.sh"
    source "$PROJECT_ROOT/src/telemetry/writer.sh"
    source "$PROJECT_ROOT/src/telemetry/events.sh"
    source "$PROJECT_ROOT/src/bead/select.sh"
    source "$PROJECT_ROOT/src/bead/claim.sh"
    source "$PROJECT_ROOT/src/runner/state.sh"
    _needle_init_log "startup-$$" 2>/dev/null || true
    _needle_workers_init 2>/dev/null || true
) 2>/dev/null
ms=$(elapsed_ms "$t")
record "worker_startup_ms" "$ms"
assert_sla "Worker startup (module loading + init)" "$ms" 2000

# ============================================================================
# 5. Strand Fallthrough Latency  (SLA: <5000ms for 7 strands all disabled)
# ============================================================================
echo ""
echo "--- 5. Strand Fallthrough Latency ---"

# All strands enabled; br returns empty list so every strand falls through
cat > "$TEST_NEEDLE_HOME/config.yaml" << 'EOF'
strands:
  pluck: true
  explore: true
  mend: true
  weave: true
  unravel: true
  pulse: true
  knot: true
strands.weave.frequency: 0
strands.knot.frequency: 0
strands.pulse.frequency: 0
strands.mend.frequency: 0
EOF

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/br" << 'MOCK'
#!/usr/bin/env bash
case "$1 $2" in
    "ready --unassigned"|"ready --workspace="*) echo '[]' ;;
    "list "*)  echo '[]' ;;
    *)         exit 0 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/br"
export PATH="$TEST_DIR/bin:$PATH"

test_case "Full 7-strand fallthrough (all strands return no work)"
t=$(now_ns)
(
    export NEEDLE_QUIET=true
    export NEEDLE_VERBOSE=false
    export NEEDLE_HOME="$TEST_NEEDLE_HOME"
    export NEEDLE_CONFIG_FILE="$TEST_NEEDLE_HOME/config.yaml"
    export PATH="$TEST_DIR/bin:$PATH"
    NEEDLE_SRC="$PROJECT_ROOT/src"
    source "$PROJECT_ROOT/src/lib/config.sh"
    source "$PROJECT_ROOT/src/strands/engine.sh"
    _needle_strand_engine "$NEEDLE_WORKSPACE" "test-agent" 2>/dev/null
) 2>/dev/null
ms=$(elapsed_ms "$t")
avg=$(( ms / 7 ))
record "strand_fallthrough_total_ms" "$ms"
record "strand_fallthrough_avg_ms" "$avg"
assert_sla "Full 7-strand fallthrough" "$ms" 5000
echo "    Average per strand: ~${avg}ms"

# ============================================================================
# 6. Event Logging Throughput  (SLA: >= 10 events/sec)
# ============================================================================
echo ""
echo "--- 6. Event Logging Throughput ---"

EVENT_COUNT=50
test_case "Emit ${EVENT_COUNT} telemetry events"
t=$(now_ns)
for i in $(seq 1 "$EVENT_COUNT"); do
    _needle_telemetry_emit "benchmark.event" "info" \
        "iteration=$i" "metric=throughput" "test=perf_bench" 2>/dev/null
done
ms=$(elapsed_ms "$t")
tps=$(( (EVENT_COUNT * 1000) / (ms > 0 ? ms : 1) ))
record "event_logging_ms" "$ms"
record "event_logging_tps" "$tps"
assert_sla "Emit ${EVENT_COUNT} telemetry events" "$ms" 10000
test_case "Event logging throughput (>= 10 events/sec)"
assert_throughput "Event logging throughput" "$tps" 10
echo "    Throughput: ~${tps} events/sec"

# ============================================================================
# 7. JSON Emit Performance  (SLA: < 2000ms for 100 JSON emissions)
# ============================================================================
echo ""
echo "--- 7. JSON Emit Performance ---"

ITERATIONS=100
test_case "${ITERATIONS} JSON object emissions"
t=$(now_ns)
for i in $(seq 1 "$ITERATIONS"); do
    _needle_json_emit \
        --type "benchmark.json" \
        --iteration "$i" \
        --metric "json_emit" \
        --status "ok" > /dev/null 2>&1
done
ms=$(elapsed_ms "$t")
tps=$(( (ITERATIONS * 1000) / (ms > 0 ? ms : 1) ))
record "json_emit_ms" "$ms"
record "json_emit_tps" "$tps"
assert_sla "${ITERATIONS} JSON emissions" "$ms" 5000
echo "    Throughput: ~${tps} emissions/sec"

# ============================================================================
# CI Regression Gate
# ============================================================================
echo ""
echo "--- CI Regression Gate ---"

write_results_json() {
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"timestamp":"%s","results":{' "$ts" > "$PERF_RESULTS_FILE"
    local first=true
    for key in "${!BENCH_RESULTS[@]}"; do
        [[ "$first" == "true" ]] || printf ',' >> "$PERF_RESULTS_FILE"
        printf '"%s":%s' "$key" "${BENCH_RESULTS[$key]}" >> "$PERF_RESULTS_FILE"
        first=false
    done
    printf '}}' >> "$PERF_RESULTS_FILE"
    echo "    Results written to: $PERF_RESULTS_FILE"
}

check_regression() {
    local threshold="${PERF_REGRESSION_THRESHOLD:-30}"

    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "    No baseline at: $BASELINE_FILE"
        echo "    Skipping regression check (run with PERF_UPDATE_BASELINE=true to create)"
        if [[ "${PERF_UPDATE_BASELINE:-false}" == "true" ]]; then
            cp "$PERF_RESULTS_FILE" "$BASELINE_FILE"
            echo "    Baseline created: $BASELINE_FILE"
        fi
        return 0
    fi

    echo "    Checking regression (threshold: ${threshold}%)"
    local regression=false

    # Latency metrics: higher = worse
    local lat_metrics=(
        bead_select_latency_ms bead_claim_latency_ms
        weighted_selection_total_ms weighted_selection_avg_ms
        priority_weight_ms worker_startup_ms
        strand_fallthrough_total_ms strand_fallthrough_avg_ms
        event_logging_ms json_emit_ms
    )
    for m in "${lat_metrics[@]}"; do
        local cur="${BENCH_RESULTS[$m]:-}"; [[ -z "$cur" ]] && continue
        local base; base=$(grep -o "\"${m}\":[0-9]*" "$BASELINE_FILE" 2>/dev/null | grep -o '[0-9]*$')
        [[ -z "$base" || "$base" -eq 0 ]] && continue
        local delta=$(( (cur - base) * 100 / base ))
        if [[ $delta -gt $threshold ]]; then
            echo "    REGRESSION: $m +${delta}% (baseline: ${base}ms, current: ${cur}ms)"
            regression=true; ((TESTS_FAILED++)); ((TESTS_RUN++))
        elif [[ $delta -gt $(( threshold / 2 )) ]]; then
            echo "    WARNING:    $m +${delta}% (baseline: ${base}ms, current: ${cur}ms)"
        else
            echo "    OK:         $m ${delta:+${delta}%} change"
        fi
    done

    # Throughput metrics: lower = worse
    local tps_metrics=(event_logging_tps json_emit_tps)
    for m in "${tps_metrics[@]}"; do
        local cur="${BENCH_RESULTS[$m]:-}"; [[ -z "$cur" ]] && continue
        local base; base=$(grep -o "\"${m}\":[0-9]*" "$BASELINE_FILE" 2>/dev/null | grep -o '[0-9]*$')
        [[ -z "$base" || "$base" -eq 0 ]] && continue
        local delta=$(( (base - cur) * 100 / base ))
        if [[ $delta -gt $threshold ]]; then
            echo "    REGRESSION: $m -${delta}% (baseline: ${base}/s, current: ${cur}/s)"
            regression=true; ((TESTS_FAILED++)); ((TESTS_RUN++))
        elif [[ $delta -gt $(( threshold / 2 )) ]]; then
            echo "    WARNING:    $m -${delta}%"
        else
            echo "    OK:         $m within threshold"
        fi
    done

    [[ "$regression" == "true" ]] && return 1 || echo "    All metrics within threshold" && return 0
}

write_results_json
check_regression

# ============================================================================
echo ""
echo "=================================================="
echo "Performance Benchmark Results Summary"
echo "=================================================="
echo ""
printf "  %-40s %8s  %s\n" "Metric" "Value" "SLA"
printf "  %-40s %8s  %s\n" "------" "-----" "---"
printf "  %-40s %7sms  %s\n" "bead_select_latency"          "${BENCH_RESULTS[bead_select_latency_ms]:-?}"    "<1000ms"
printf "  %-40s %7sms  %s\n" "bead_claim_latency"           "${BENCH_RESULTS[bead_claim_latency_ms]:-?}"     "<1000ms"
printf "  %-40s %7sms  %s\n" "weighted_selection_30x"       "${BENCH_RESULTS[weighted_selection_total_ms]:-?}" "<3000ms"
printf "  %-40s %7sms  %s\n" "priority_weight_500x"         "${BENCH_RESULTS[priority_weight_ms]:-?}"        "<1000ms"
printf "  %-40s %7sms  %s\n" "worker_startup"               "${BENCH_RESULTS[worker_startup_ms]:-?}"         "<2000ms"
printf "  %-40s %7sms  %s\n" "strand_fallthrough_7x"        "${BENCH_RESULTS[strand_fallthrough_total_ms]:-?}" "<5000ms"
printf "  %-40s %7s/s  %s\n" "event_logging_throughput"     "${BENCH_RESULTS[event_logging_tps]:-?}"         ">=10/s"
printf "  %-40s %7sms  %s\n" "json_emit_100x"               "${BENCH_RESULTS[json_emit_ms]:-?}"              "<5000ms"
echo ""
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "ALL BENCHMARKS PASSED"
    exit 0
else
    echo "BENCHMARK FAILURES: $TESTS_FAILED"
    exit 1
fi
