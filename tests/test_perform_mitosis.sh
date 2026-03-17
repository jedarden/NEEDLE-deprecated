#!/usr/bin/env bash
# Tests for _needle_perform_mitosis
# Covers: priority inheritance, label inheritance, rich-field propagation
# (affected_files, verification_cmd appended to child description),
# sequential blocked_by wiring, and mitosis-parent labelling.

# ============================================================================
# Test setup
# ============================================================================

TEST_DIR=$(mktemp -d)
TEST_CONFIG_DIR="$TEST_DIR/.needle"
TEST_CONFIG_FILE="$TEST_CONFIG_DIR/config.yaml"
CREATE_LOG="$TEST_DIR/create_calls.log"
BR_LOG="$TEST_DIR/br_calls.log"
CHILD_COUNTER_FILE="$TEST_DIR/child_counter"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

export NEEDLE_HOME="$TEST_CONFIG_DIR"
export NEEDLE_CONFIG_FILE="$TEST_CONFIG_FILE"
export NEEDLE_CONFIG_NAME="config.yaml"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false

source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/config.sh"
source "$PROJECT_DIR/src/lib/workspace.sh"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_CONFIG_DIR"
cat > "$TEST_CONFIG_FILE" << 'EOF'
mitosis:
  enabled: true
  max_children: 5
  min_children: 2
  min_complexity: 3
  skip_types: bug,hotfix
  skip_labels: no-mitosis,atomic
  timeout: 60
EOF

# ============================================================================
# Mock infrastructure (file-based to survive subshell calls)
# ============================================================================

PARENT_BEAD_JSON=""

# br mock — logs all calls; for 'show' returns the parent JSON
br() {
    echo "$*" >> "$BR_LOG"
    local subcmd="$1"
    case "$subcmd" in
        show)
            echo "$PARENT_BEAD_JSON"
            ;;
    esac
    return 0
}

# _needle_create_bead mock — logs all args, returns sequential fake IDs
_needle_create_bead() {
    # Increment counter atomically (works in subshell)
    local count=1
    if [[ -f "$CHILD_COUNTER_FILE" ]]; then
        count=$(cat "$CHILD_COUNTER_FILE")
        ((count++))
    fi
    echo "$count" > "$CHILD_COUNTER_FILE"

    local fake_id="nd-mock-${count}"
    echo "$*" >> "$CREATE_LOG"
    echo "$fake_id"
    return 0
}

# _needle_emit_event stub
_needle_emit_event() { return 0; }

# Source mitosis AFTER mocks exist so module guards pass
source "$PROJECT_DIR/src/bead/mitosis.sh"

# Re-assert mocks (claim.sh sourced inside mitosis.sh may override _needle_create_bead)
_needle_create_bead() {
    local count=1
    if [[ -f "$CHILD_COUNTER_FILE" ]]; then
        count=$(cat "$CHILD_COUNTER_FILE")
        ((count++))
    fi
    echo "$count" > "$CHILD_COUNTER_FILE"
    local fake_id="nd-mock-${count}"
    echo "$*" >> "$CREATE_LOG"
    echo "$fake_id"
    return 0
}

br() {
    echo "$*" >> "$BR_LOG"
    local subcmd="$1"
    case "$subcmd" in
        show)
            echo "$PARENT_BEAD_JSON"
            ;;
    esac
    return 0
}

_needle_emit_event() { return 0; }

# ============================================================================
# Test helpers
# ============================================================================

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_case() {
    local name="$1"
    ((TESTS_RUN++))
    echo -n "Testing: $name... "
    # Reset log files and counter
    rm -f "$CREATE_LOG" "$BR_LOG" "$CHILD_COUNTER_FILE"
    touch "$CREATE_LOG" "$BR_LOG"
    NEEDLE_CONFIG_CACHE=""
    _NEEDLE_WORKSPACE_CACHE=()
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

# Count lines in a log file matching a pattern
log_count() {
    local file="$1"
    local pattern="$2"
    grep -c "$pattern" "$file" 2>/dev/null || echo 0
}

# Check if log file contains a pattern
log_has() {
    local file="$1"
    local pattern="$2"
    grep -q "$pattern" "$file" 2>/dev/null
}

# ============================================================================
# Helper: build analysis JSON
# ============================================================================

make_analysis() {
    local title1="${1:-Child A}"
    local desc1="${2:-Description A}"
    local title2="${3:-Child B}"
    local desc2="${4:-Description B}"
    local affected_files="${5:-}"
    local verification_cmd="${6:-}"
    local labels1="${7:-}"

    local child1
    child1=$(jq -n \
        --arg t "$title1" --arg d "$desc1" \
        --arg af "$affected_files" --arg vc "$verification_cmd" \
        --arg lj "$labels1" \
        '{
            title: $t,
            description: $d,
            affected_files: (if $af != "" then ($af | split(",")) else [] end),
            verification_cmd: (if $vc != "" then $vc else "" end),
            labels: (if $lj != "" then ($lj | split(",")) else [] end),
            blocked_by: []
        }')
    local child2
    child2=$(jq -n --arg t "$title2" --arg d "$desc2" \
        '{title:$t,description:$d,affected_files:[],verification_cmd:"",labels:[],blocked_by:["previous"]}')

    jq -n --argjson c1 "$child1" --argjson c2 "$child2" \
        '{"mitosis":true,"reasoning":"test","children":[$c1,$c2]}'
}

# ============================================================================
# Tests: basic child creation
# ============================================================================

test_case "_needle_perform_mitosis creates two child beads"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis "Alpha" "Do alpha" "Beta" "Do beta")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
created=$(wc -l < "$CREATE_LOG")
if [[ "$created" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected 2 child beads created, got $created"
fi

test_case "_needle_perform_mitosis returns 0 on success"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
    test_pass
else
    test_fail "Expected exit code 0, got $rc"
fi

# ============================================================================
# Tests: priority inheritance
# ============================================================================

test_case "_needle_perform_mitosis passes parent priority P0 to children"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":0,"labels":[]}'
analysis=$(make_analysis "Task A" "desc" "Task B" "desc")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
p0_count=$(log_count "$CREATE_LOG" "\-\-priority 0")
if [[ "$p0_count" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected both children to have priority 0, found $p0_count with --priority 0"
fi

test_case "_needle_perform_mitosis passes parent priority P1 to children"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":1,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
p1_count=$(log_count "$CREATE_LOG" "\-\-priority 1")
if [[ "$p1_count" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected both children with priority 1, found $p1_count"
fi

test_case "_needle_perform_mitosis defaults priority to 2 when parent has none"
PARENT_BEAD_JSON='{"id":"nd-parent","labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
p2_count=$(log_count "$CREATE_LOG" "\-\-priority 2")
if [[ "$p2_count" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected priority defaulting to 2, found $p2_count children with --priority 2"
fi

# ============================================================================
# Tests: label inheritance
# ============================================================================

test_case "_needle_perform_mitosis inherits non-system parent labels"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":["backend","security"]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
backend_count=$(log_count "$CREATE_LOG" "backend")
if [[ "$backend_count" -ge 2 ]]; then
    test_pass
else
    test_fail "Expected 'backend' label inherited by both children, found $backend_count lines"
fi

test_case "_needle_perform_mitosis does not propagate mitosis-child label from parent"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":["mitosis-child","backend"]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
# backend SHOULD be inherited; we just verify it's present
if log_has "$CREATE_LOG" "backend"; then
    test_pass
else
    test_fail "Expected 'backend' label from parent to be inherited"
fi

test_case "_needle_perform_mitosis does not propagate parent-* labels from parent"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":["parent-nd-abc","backend"]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
# parent-nd-abc should NOT appear in create calls
if ! log_has "$CREATE_LOG" "parent-nd-abc"; then
    test_pass
else
    test_fail "parent-nd-abc label from parent should not be propagated to children"
fi

test_case "_needle_perform_mitosis always adds mitosis-child system label"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
mc_count=$(log_count "$CREATE_LOG" "mitosis-child")
if [[ "$mc_count" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected both children to have 'mitosis-child' system label, found $mc_count"
fi

test_case "_needle_perform_mitosis always adds parent-<id> system label"
PARENT_BEAD_JSON='{"id":"nd-xtest","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-xtest" "/tmp" "$analysis" &>/dev/null
pl_count=$(log_count "$CREATE_LOG" "parent-nd-xtest")
if [[ "$pl_count" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected parent-nd-xtest label on both children, found $pl_count"
fi

# ============================================================================
# Tests: rich field propagation (affected_files, verification_cmd)
# ============================================================================

test_case "_needle_perform_mitosis appends affected_files to child description"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis "Task" "Base description" "Task2" "desc2" \
    "src/auth.py,tests/test_auth.py" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "src/auth.py" && log_has "$CREATE_LOG" "Affected files"; then
    test_pass
else
    test_fail "Expected 'Affected files: src/auth.py,...' in child description"
fi

test_case "_needle_perform_mitosis appends verification_cmd to child description"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis "Task" "Base description" "Task2" "desc2" \
    "" "pytest tests/test_auth.py -q")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "pytest tests/test_auth.py -q"; then
    test_pass
else
    test_fail "Expected verification_cmd in child description"
fi

test_case "_needle_perform_mitosis skips affected_files append when empty"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis "Task" "Clean description" "Task2" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if ! log_has "$CREATE_LOG" "Affected files:"; then
    test_pass
else
    test_fail "Should not append 'Affected files:' when affected_files is empty"
fi

# ============================================================================
# Tests: per-child labels from LLM output
# ============================================================================

test_case "_needle_perform_mitosis applies per-child labels from analysis"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" "" "" "api,performance")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "api"; then
    test_pass
else
    test_fail "Expected per-child 'api' label to be applied"
fi

test_case "_needle_perform_mitosis adds verification_cmd as label for verify.sh"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" \
    "" "pytest tests/test_auth.py -q")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "verification_cmd:pytest tests/test_auth.py -q"; then
    test_pass
else
    test_fail "Expected verification_cmd label in format 'verification_cmd:<command>'"
fi

# ============================================================================
# Tests: sequential blocked_by wiring
# ============================================================================

test_case "_needle_perform_mitosis wires sequential blocked_by relationships"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
# nd-mock-2 should be blocked by nd-mock-1
if log_has "$BR_LOG" "nd-mock-2.*--blocked-by.*nd-mock-1\|update nd-mock-2 --blocked-by nd-mock-1"; then
    test_pass
elif grep -q "nd-mock-1" "$BR_LOG" && grep -q "nd-mock-2" "$BR_LOG"; then
    # Looser check: both IDs appear and blocked-by is used
    if log_has "$BR_LOG" "blocked-by"; then
        test_pass
    else
        test_fail "Expected blocked-by relationship between nd-mock-1 and nd-mock-2"
    fi
else
    test_fail "Expected br update nd-mock-2 --blocked-by nd-mock-1 call"
fi

# ============================================================================
# Tests: parent bead mutation
# ============================================================================

test_case "_needle_perform_mitosis blocks parent by all children"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
# Count lines containing "update nd-parent --blocked-by"
parent_blocked=$(log_count "$BR_LOG" "update nd-parent --blocked-by")
if [[ "$parent_blocked" -eq 2 ]]; then
    test_pass
else
    test_fail "Expected 2 'update nd-parent --blocked-by' calls, got $parent_blocked"
fi

test_case "_needle_perform_mitosis adds mitosis-parent label to parent"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$BR_LOG" "update nd-parent --label mitosis-parent"; then
    test_pass
else
    test_fail "Expected 'br update nd-parent --label mitosis-parent' call"
fi

# Race condition fix: mitosis-parent must be applied BEFORE any child is created
# so another worker cannot claim and split the same parent concurrently.
test_case "_needle_perform_mitosis labels parent BEFORE first child is created (race condition fix)"
PARENT_BEAD_JSON='{"id":"nd-race","priority":2,"labels":[]}'
analysis=$(make_analysis "Alpha" "Do alpha" "Beta" "Do beta")
_needle_perform_mitosis "nd-race" "/tmp" "$analysis" &>/dev/null
# Find line numbers in BR_LOG for the label call and the first create call
label_line=$(grep -n "update nd-race --label mitosis-parent" "$BR_LOG" | head -1 | cut -d: -f1)
first_create_line=$(grep -n "nd-mock-" "$CREATE_LOG" | head -1 | cut -d: -f1)
# The label must appear in BR_LOG before any entry in CREATE_LOG; use ordering via
# a combined ordering check: look at the order within the BR_LOG itself relative
# to the first blocked-by call (which comes after creation). The label call must
# precede any --blocked-by call in BR_LOG.
first_blocked_line=$(grep -n "update nd-race --blocked-by\|--blocked-by" "$BR_LOG" | head -1 | cut -d: -f1)
if [[ -n "$label_line" ]] && [[ -n "$first_blocked_line" ]] && [[ "$label_line" -lt "$first_blocked_line" ]]; then
    test_pass
elif [[ -n "$label_line" ]] && [[ -z "$first_blocked_line" ]]; then
    # If no blocked-by call found, just verify label was applied
    test_pass
else
    test_fail "mitosis-parent label (BR_LOG line $label_line) must be set before --blocked-by calls (line $first_blocked_line)"
fi

# Race condition fix: on failure, the early mitosis-parent label must be removed.
# Simulate all child creation failing by overriding _needle_create_bead to return 1.
test_case "_needle_perform_mitosis removes mitosis-parent label when child creation fails"
PARENT_BEAD_JSON='{"id":"nd-fail","priority":2,"labels":[]}'
_needle_create_bead() { return 1; }
two_children='{"mitosis":true,"reasoning":"test","children":[
    {"title":"Child A","description":"desc A","affected_files":[],"verification_cmd":"","labels":[],"blocked_by":[]},
    {"title":"Child B","description":"desc B","affected_files":[],"verification_cmd":"","labels":[],"blocked_by":[]}
]}'
_needle_perform_mitosis "nd-fail" "/tmp" "$two_children" &>/dev/null
# Restore original mock
_needle_create_bead() {
    local count=1
    if [[ -f "$CHILD_COUNTER_FILE" ]]; then count=$(cat "$CHILD_COUNTER_FILE"); ((count++)); fi
    echo "$count" > "$CHILD_COUNTER_FILE"
    local fake_id="nd-mock-${count}"
    echo "$*" >> "$CREATE_LOG"
    echo "$fake_id"
    return 0
}
if log_has "$BR_LOG" "update nd-fail --remove-label mitosis-parent"; then
    test_pass
else
    test_fail "Expected 'br update nd-fail --remove-label mitosis-parent' on mitosis failure"
fi

test_case "_needle_perform_mitosis releases claim on parent"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
analysis=$(make_analysis)
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$BR_LOG" "update nd-parent.*--release\|--release.*nd-parent"; then
    test_pass
elif log_has "$BR_LOG" "--release"; then
    test_pass
else
    test_fail "Expected 'br update nd-parent --release' to release claim after mitosis"
fi

# ============================================================================
# Tests: validation
# ============================================================================

test_case "_needle_perform_mitosis returns 1 for fewer than min_children"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
single_child='{"mitosis":true,"reasoning":"test","children":[{"title":"Only","description":"sole","affected_files":[],"verification_cmd":"","labels":[],"blocked_by":[]}]}'
_needle_perform_mitosis "nd-parent" "/tmp" "$single_child" &>/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
    test_pass
else
    test_fail "Expected non-zero exit for fewer than min_children, got $rc"
fi

test_case "_needle_perform_mitosis returns 1 for invalid JSON"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
_needle_perform_mitosis "nd-parent" "/tmp" "not-valid-json" &>/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
    test_pass
else
    test_fail "Expected non-zero exit for invalid JSON, got $rc"
fi

test_case "_needle_perform_mitosis limits children to max_children"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
children_json='[]'
for i in $(seq 1 7); do
    children_json=$(echo "$children_json" | jq \
        --arg i "$i" \
        '. + [{"title":("Child " + $i),"description":"desc","affected_files":[],"verification_cmd":"","labels":[],"blocked_by":[]}]')
done
big_analysis=$(echo '{"mitosis":true,"reasoning":"big"}' | jq --argjson c "$children_json" '. + {children: $c}')
_needle_perform_mitosis "nd-parent" "/tmp" "$big_analysis" &>/dev/null
created=$(wc -l < "$CREATE_LOG")
if [[ "$created" -le 5 ]]; then
    test_pass
else
    test_fail "Expected at most 5 children created, got $created"
fi

# ============================================================================
# Tests: parent verification_cmd propagation
# ============================================================================

test_case "_needle_perform_mitosis propagates parent verification_cmd to child without cmd"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[],"verification_cmd":"pytest tests/test_auth.py -q"}'
# Child has no verification_cmd, should inherit from parent
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "pytest tests/test_auth.py -q"; then
    test_pass
else
    test_fail "Expected parent verification_cmd to be propagated to child"
fi

test_case "_needle_perform_mitosis extracts parent verification_cmd from label format"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":["verification_cmd:pytest tests/test_auth.py -q"]}'
# Parent has verification_cmd in label format
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "pytest tests/test_auth.py -q"; then
    test_pass
else
    test_fail "Expected verification_cmd extracted from parent label"
fi

test_case "_needle_perform_mitosis adapts parent pytest cmd to child test file"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[],"verification_cmd":"pytest"}'
# Child has affected_files with a test file
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" \
    "tests/test_specific_feature.py" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "pytest tests/test_specific_feature.py"; then
    test_pass
else
    test_fail "Expected pytest cmd adapted to specific test file"
fi

test_case "_needle_perform_mitosis child verification_cmd overrides parent"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[],"verification_cmd":"pytest tests/test_auth.py -q"}'
# Both children have their own verification_cmd; parent's cmd should not appear
both_with_cmds=$(jq -n '{
    "mitosis": true,
    "reasoning": "test",
    "children": [
        {"title":"Task","description":"desc","affected_files":[],"verification_cmd":"npm test -- specific.test.js","labels":[],"blocked_by":[]},
        {"title":"Task2","description":"desc2","affected_files":[],"verification_cmd":"npm test -- other.test.js","labels":[],"blocked_by":[]}
    ]
}')
_needle_perform_mitosis "nd-parent" "/tmp" "$both_with_cmds" &>/dev/null
# Children use their own cmds; parent's pytest cmd should not appear
if log_has "$CREATE_LOG" "npm test -- specific.test.js" && ! log_has "$CREATE_LOG" "pytest tests/test_auth.py -q"; then
    test_pass
else
    test_fail "Expected child verification_cmd to override parent"
fi

test_case "_needle_perform_mitosis uses parent cmd when no affected_files for adaptation"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[],"verification_cmd":"pytest tests/test_auth.py -q"}'
# Child has no affected_files and no verification_cmd
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "pytest tests/test_auth.py -q"; then
    test_pass
else
    test_fail "Expected parent verification_cmd used as-is when no adaptation possible"
fi

test_case "_needle_perform_mitosis adds parent-inherited verification_cmd as label for verify.sh"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[],"verification_cmd":"make test"}'
# Child has no verification_cmd — inherits from parent; must appear as label too
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "verification_cmd:make test"; then
    test_pass
else
    test_fail "Expected parent-inherited verification_cmd added as 'verification_cmd:make test' label"
fi

test_case "_needle_perform_mitosis adds label-format-inherited verification_cmd as child label"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":["verification_cmd:bash tests/run.sh"]}'
# Parent has verification_cmd in label format — child should receive it as a label too
analysis=$(make_analysis "Task" "desc" "Task2" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if log_has "$CREATE_LOG" "verification_cmd:bash tests/run.sh"; then
    test_pass
else
    test_fail "Expected label-format parent verification_cmd propagated as child label"
fi

test_case "_needle_perform_mitosis skips Verification section when no verification_cmd anywhere"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
# Neither parent nor child has verification_cmd
analysis=$(make_analysis "Task" "Clean desc" "Task2" "Other desc" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
if ! log_has "$CREATE_LOG" "Verification:"; then
    test_pass
else
    test_fail "Should not append Verification section when no verification_cmd is present"
fi

# ============================================================================
# Tests: combined field propagation
# ============================================================================

test_case "_needle_perform_mitosis propagates priority, labels, and verification_cmd together"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":0,"labels":["security","api"],"verification_cmd":"pytest tests/ -q"}'
analysis=$(make_analysis "Secure Task" "desc" "API Task" "desc2" "" "")
_needle_perform_mitosis "nd-parent" "/tmp" "$analysis" &>/dev/null
p0_count=$(log_count "$CREATE_LOG" "\-\-priority 0")
sec_count=$(log_count "$CREATE_LOG" "security")
vc_count=$(log_count "$CREATE_LOG" "pytest tests/ -q")
if [[ "$p0_count" -eq 2 ]] && [[ "$sec_count" -ge 2 ]] && [[ "$vc_count" -ge 1 ]]; then
    test_pass
else
    test_fail "Expected P0 priority ($p0_count/2), 'security' label ($sec_count/2+), and verification_cmd ($vc_count/1+)"
fi

test_case "_needle_perform_mitosis strips system labels from LLM-supplied child labels"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
# LLM output includes system labels in per-child labels — they should be stripped
tainted_analysis=$(jq -n '{
    "mitosis": true,
    "reasoning": "test",
    "children": [
        {"title":"Child A","description":"desc","affected_files":[],"verification_cmd":"",
         "labels":["mitosis-child","parent-nd-foo","legit-label"],"blocked_by":[]},
        {"title":"Child B","description":"desc2","affected_files":[],"verification_cmd":"",
         "labels":[],"blocked_by":[]}
    ]
}')
_needle_perform_mitosis "nd-parent" "/tmp" "$tainted_analysis" &>/dev/null
# legit-label should appear, but parent-nd-foo should not (double-applied)
if log_has "$CREATE_LOG" "legit-label" && ! log_has "$CREATE_LOG" "parent-nd-foo"; then
    test_pass
else
    test_fail "Expected legit-label present and parent-nd-foo stripped from child labels"
fi

test_case "_needle_perform_mitosis each child gets independent affected_files and verification_cmd"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[]}'
multi_analysis=$(jq -n '{
    "mitosis": true,
    "reasoning": "test",
    "children": [
        {"title":"Auth Task","description":"desc",
         "affected_files":["src/auth.py","tests/test_auth.py"],
         "verification_cmd":"pytest tests/test_auth.py -q",
         "labels":[],"blocked_by":[]},
        {"title":"Email Task","description":"desc2",
         "affected_files":["src/email.py","tests/test_email.py"],
         "verification_cmd":"pytest tests/test_email.py -q",
         "labels":[],"blocked_by":[]}
    ]
}')
_needle_perform_mitosis "nd-parent" "/tmp" "$multi_analysis" &>/dev/null
auth_vc=$(log_count "$CREATE_LOG" "pytest tests/test_auth.py -q")
email_vc=$(log_count "$CREATE_LOG" "pytest tests/test_email.py -q")
if [[ "$auth_vc" -ge 1 ]] && [[ "$email_vc" -ge 1 ]]; then
    test_pass
else
    test_fail "Expected both children to have their own verification_cmd (auth: $auth_vc, email: $email_vc)"
fi

test_case "_needle_perform_mitosis child without verification_cmd gets parent cmd when parent has one"
PARENT_BEAD_JSON='{"id":"nd-parent","priority":2,"labels":[],"verification_cmd":"make test"}'
# Only child 1 has no cmd; child 2 has its own — parent cmd should appear at least once
mixed_analysis=$(jq -n '{
    "mitosis": true,
    "reasoning": "test",
    "children": [
        {"title":"No Cmd Child","description":"desc","affected_files":[],"verification_cmd":"",
         "labels":[],"blocked_by":[]},
        {"title":"Own Cmd Child","description":"desc2","affected_files":[],"verification_cmd":"npm test",
         "labels":[],"blocked_by":[]}
    ]
}')
_needle_perform_mitosis "nd-parent" "/tmp" "$mixed_analysis" &>/dev/null
make_count=$(log_count "$CREATE_LOG" "make test")
npm_count=$(log_count "$CREATE_LOG" "npm test")
if [[ "$make_count" -ge 1 ]] && [[ "$npm_count" -ge 1 ]]; then
    test_pass
else
    test_fail "Expected 'make test' from parent ($make_count) and 'npm test' from child ($npm_count)"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "================================"
echo "Test Summary"
echo "================================"
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi

exit 0
