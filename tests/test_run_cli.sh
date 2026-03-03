#!/usr/bin/env bash
# Tests for NEEDLE run CLI parsing and validation (src/cli/run.sh)

# Test setup
TEST_DIR=$(mktemp -d)
TEST_WORKSPACE="$TEST_DIR/workspace"
TEST_NEEDLE_HOME="$TEST_DIR/.needle"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_NEEDLE_HOME"
export NEEDLE_CONFIG_FILE="$NEEDLE_HOME/config.yaml"
export NEEDLE_CONFIG_NAME="config.yaml"

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/paths.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lib/config.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/workspace.sh"
source "$PROJECT_DIR/src/agent/loader.sh"
source "$PROJECT_DIR/src/onboarding/agents.sh"
source "$PROJECT_DIR/src/runner/limits.sh"
source "$PROJECT_DIR/src/cli/run.sh"

# Suppress output for tests
export NEEDLE_QUIET=true

# Cleanup function
cleanup() {
    rm -rf "$TEST_DIR"
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

# Create test workspace with .beads directory
setup_test_workspace() {
    mkdir -p "$TEST_WORKSPACE/.beads"
    mkdir -p "$TEST_NEEDLE_HOME"
    mkdir -p "$TEST_NEEDLE_HOME/agents"
}

# Create a test agent config
setup_test_agent() {
    local agent_name="${1:-test-agent}"
    cat > "$TEST_NEEDLE_HOME/agents/${agent_name}.yaml" << EOF
name: $agent_name
description: Test agent
version: "1.0"
runner: bash
provider: test
model: test-model
invoke: "echo test"
input:
  method: heredoc
output:
  format: text
  success_codes:
    - 0
limits:
  requests_per_minute: 60
  max_concurrent: 5
EOF
}

# ============ Tests ============

# ---- Workspace Validation Tests ----

test_case "_needle_validate_workspace: accepts valid workspace with .beads"
setup_test_workspace
unset NEEDLE_VALIDATED_WORKSPACE
if _needle_validate_workspace "$TEST_WORKSPACE" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_WORKSPACE" == "$TEST_WORKSPACE" ]]; then
        test_pass
    else
        test_fail "Expected $TEST_WORKSPACE, got $NEEDLE_VALIDATED_WORKSPACE"
    fi
else
    test_fail "Validation failed for valid workspace"
fi

test_case "_needle_validate_workspace: rejects workspace without .beads"
setup_test_workspace
rm -rf "$TEST_WORKSPACE/.beads"
unset NEEDLE_VALIDATED_WORKSPACE
if ! _needle_validate_workspace "$TEST_WORKSPACE" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject workspace without .beads directory"
fi

test_case "_needle_validate_workspace: rejects non-existent path"
unset NEEDLE_VALIDATED_WORKSPACE
if ! _needle_validate_workspace "/nonexistent/path" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject non-existent path"
fi

test_case "_needle_validate_workspace: uses current directory if not specified"
setup_test_workspace
cd "$TEST_WORKSPACE"
unset NEEDLE_VALIDATED_WORKSPACE
if _needle_validate_workspace "" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_WORKSPACE" == "$TEST_WORKSPACE" ]]; then
        test_pass
    else
        test_fail "Expected $TEST_WORKSPACE, got $NEEDLE_VALIDATED_WORKSPACE"
    fi
else
    test_fail "Should accept current directory if valid"
fi
cd - > /dev/null

# ---- Agent Validation Tests ----

test_case "_needle_validate_agent: accepts valid agent"
setup_test_workspace
setup_test_agent "test-agent"
unset NEEDLE_VALIDATED_AGENT
if _needle_validate_agent "test-agent" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_AGENT" == "test-agent" ]]; then
        test_pass
    else
        test_fail "Expected test-agent, got $NEEDLE_VALIDATED_AGENT"
    fi
else
    test_fail "Should accept valid agent"
fi

test_case "_needle_validate_agent: rejects non-existent agent"
unset NEEDLE_VALIDATED_AGENT
if ! _needle_validate_agent "nonexistent-agent" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject non-existent agent"
fi

# ---- Count Validation Tests ----

test_case "_needle_validate_count: accepts positive integer"
unset NEEDLE_VALIDATED_COUNT
if _needle_validate_count "5" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_COUNT" == "5" ]]; then
        test_pass
    else
        test_fail "Expected 5, got $NEEDLE_VALIDATED_COUNT"
    fi
else
    test_fail "Should accept positive integer"
fi

test_case "_needle_validate_count: uses default 1 when not specified"
unset NEEDLE_VALIDATED_COUNT
if _needle_validate_count "" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_COUNT" == "1" ]]; then
        test_pass
    else
        test_fail "Expected 1, got $NEEDLE_VALIDATED_COUNT"
    fi
else
    test_fail "Should use default when not specified"
fi

test_case "_needle_validate_count: rejects zero"
if ! _needle_validate_count "0" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject zero"
fi

test_case "_needle_validate_count: rejects negative number"
if ! _needle_validate_count "-5" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject negative number"
fi

test_case "_needle_validate_count: rejects non-numeric"
if ! _needle_validate_count "abc" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject non-numeric value"
fi

test_case "_needle_validate_count: rejects decimal"
if ! _needle_validate_count "2.5" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject decimal"
fi

# ---- Budget Validation Tests ----

test_case "_needle_validate_budget: accepts positive number"
unset NEEDLE_VALIDATED_BUDGET
if _needle_validate_budget "10.50" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_BUDGET" == "10.50" ]]; then
        test_pass
    else
        test_fail "Expected 10.50, got $NEEDLE_VALIDATED_BUDGET"
    fi
else
    test_fail "Should accept positive number"
fi

test_case "_needle_validate_budget: accepts integer budget"
unset NEEDLE_VALIDATED_BUDGET
if _needle_validate_budget "100" 2>/dev/null; then
    if [[ "$NEEDLE_VALIDATED_BUDGET" == "100" ]]; then
        test_pass
    else
        test_fail "Expected 100, got $NEEDLE_VALIDATED_BUDGET"
    fi
else
    test_fail "Should accept integer budget"
fi

test_case "_needle_validate_budget: accepts empty (optional)"
unset NEEDLE_VALIDATED_BUDGET
if _needle_validate_budget "" 2>/dev/null; then
    if [[ -z "$NEEDLE_VALIDATED_BUDGET" ]]; then
        test_pass
    else
        test_fail "Expected empty, got $NEEDLE_VALIDATED_BUDGET"
    fi
else
    test_fail "Should accept empty budget"
fi

test_case "_needle_validate_budget: rejects zero"
if ! _needle_validate_budget "0" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject zero"
fi

test_case "_needle_validate_budget: rejects negative"
if ! _needle_validate_budget "-10" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject negative"
fi

test_case "_needle_validate_budget: rejects non-numeric"
if ! _needle_validate_budget "abc" 2>/dev/null; then
    test_pass
else
    test_fail "Should reject non-numeric"
fi

# ---- CLI Parsing Tests ----

# Helper to run parse_args in subshell and capture exports
run_parse_args() {
    local result
    result=$(_needle_run_parse_args "$@" 2>&1 && echo "SUCCESS" || echo "FAILED")
    echo "$result"
}

test_case "_needle_run_parse_args: parses --workspace option"
setup_test_workspace
(
    _needle_run_parse_args --workspace "$TEST_WORKSPACE" 2>/dev/null
    if [[ "$NEEDLE_VALIDATED_WORKSPACE" == "$TEST_WORKSPACE" ]]; then
        echo "PASS"
    else
        echo "FAIL: Expected $TEST_WORKSPACE, got $NEEDLE_VALIDATED_WORKSPACE"
    fi
) >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    result=$( _needle_run_parse_args --workspace "$TEST_WORKSPACE" 2>/dev/null && echo "SUCCESS" || echo "FAILED" )
    # Re-run to capture the variable
    ( _needle_run_parse_args --workspace "$TEST_WORKSPACE" 2>/dev/null && echo "$NEEDLE_VALIDATED_WORKSPACE" )
fi

# Use simpler approach - run validation directly
test_case "_needle_run_parse_args: parses --workspace option"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed: $result"
fi

test_case "_needle_run_parse_args: parses -w short option"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses --agent option"
setup_test_workspace
setup_test_agent "my-agent"
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "my-agent" 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses -a short option"
setup_test_workspace
setup_test_agent "short-agent"
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "short-agent" 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses --count option"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" --count 3 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses -c short option"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" -c 5 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses --budget option"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" --budget "25.00" 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses --no-hooks flag"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" --no-hooks 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses --dry-run flag"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" --dry-run 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses --force flag"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" --force 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: parses multiple options together"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" -c 4 --budget "50.00" --no-hooks 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

test_case "_needle_run_parse_args: accepts positional workspace argument"
setup_test_workspace
setup_test_agent
result=$(_needle_run_parse_args "$TEST_WORKSPACE" -a "test-agent" 2>&1 && echo "OK" || echo "FAIL")
if [[ "$result" == *"OK"* ]]; then
    test_pass
else
    test_fail "Parse failed"
fi

# ---- Export Tests ----

test_case "_needle_export_validated_json outputs valid JSON"
# Test the function directly with pre-set variables
NEEDLE_VALIDATED_WORKSPACE="/test/path"
NEEDLE_VALIDATED_AGENT="test-agent"
NEEDLE_VALIDATED_COUNT=2
NEEDLE_VALIDATED_BUDGET="10.00"
NEEDLE_VALIDATED_NO_HOOKS=false
NEEDLE_VALIDATED_DRY_RUN=false
NEEDLE_VALIDATED_FORCE=false
export NEEDLE_VALIDATED_WORKSPACE NEEDLE_VALIDATED_AGENT NEEDLE_VALIDATED_COUNT
export NEEDLE_VALIDATED_BUDGET NEEDLE_VALIDATED_NO_HOOKS NEEDLE_VALIDATED_DRY_RUN NEEDLE_VALIDATED_FORCE

json=$(_needle_export_validated_json)
if echo "$json" | jq -e . >/dev/null 2>&1; then
    test_pass
else
    test_fail "Invalid JSON output: $json"
fi

test_case "_needle_export_validated_json contains expected fields"
json=$(_needle_export_validated_json)
if echo "$json" | jq -e '.workspace' >/dev/null 2>&1 && \
   echo "$json" | jq -e '.agent' >/dev/null 2>&1 && \
   echo "$json" | jq -e '.count' >/dev/null 2>&1 && \
   echo "$json" | jq -e '.budget' >/dev/null 2>&1; then
    test_pass
else
    test_fail "Missing expected fields in JSON: $json"
fi

# ---- Help Tests ----

test_case "_needle_run_help runs without error"
if _needle_run_help >/dev/null 2>&1; then
    test_pass
else
    test_fail "Help function failed"
fi

test_case "_needle_run_help contains expected options"
help_output=$(_needle_run_help 2>&1)
if [[ "$help_output" == *"--workspace"* ]] && \
   [[ "$help_output" == *"--agent"* ]] && \
   [[ "$help_output" == *"--count"* ]] && \
   [[ "$help_output" == *"--budget"* ]] && \
   [[ "$help_output" == *"--no-hooks"* ]]; then
    test_pass
else
    test_fail "Help missing expected options"
fi

# ---- Validation Error Cases ----

test_case "_needle_run_parse_args: rejects invalid count"
setup_test_workspace
setup_test_agent
(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" -c "invalid" 2>/dev/null) >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    test_pass
else
    test_fail "Should reject invalid count"
fi

test_case "_needle_run_parse_args: rejects invalid budget"
setup_test_workspace
setup_test_agent
(_needle_run_parse_args -w "$TEST_WORKSPACE" -a "test-agent" --budget "invalid" 2>/dev/null) >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    test_pass
else
    test_fail "Should reject invalid budget"
fi

test_case "_needle_run_parse_args: rejects unknown option"
setup_test_workspace
(_needle_run_parse_args -w "$TEST_WORKSPACE" --unknown-option 2>/dev/null) >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    test_pass
else
    test_fail "Should reject unknown option"
fi

# ============ Summary ============
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
