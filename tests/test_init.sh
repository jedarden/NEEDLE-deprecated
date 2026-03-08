#!/usr/bin/env bash
# Tests for NEEDLE init command (src/cli/init.sh)

# Test setup
TEST_DIR=$(mktemp -d)
TEST_HOME="$TEST_DIR/.needle"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_HOME"
export HOME="$TEST_DIR"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/lib/config.sh"
source "$PROJECT_DIR/src/lib/paths.sh"
source "$PROJECT_DIR/src/lib/workspace.sh"
source "$PROJECT_DIR/src/lib/update_check.sh"
source "$PROJECT_DIR/src/runner/state.sh"
source "$PROJECT_DIR/src/runner/limits.sh"
source "$PROJECT_DIR/src/runner/tmux.sh"
source "$PROJECT_DIR/src/telemetry/events.sh"
source "$PROJECT_DIR/src/hooks/runner.sh"
source "$PROJECT_DIR/src/agent/loader.sh"
source "$PROJECT_DIR/src/agent/dispatch.sh"
source "$PROJECT_DIR/src/onboarding/welcome.sh"
source "$PROJECT_DIR/src/onboarding/agents.sh"
source "$PROJECT_DIR/src/onboarding/create_config.sh"
source "$PROJECT_DIR/src/onboarding/workspace_setup.sh"
source "$PROJECT_DIR/bootstrap/check.sh"
source "$PROJECT_DIR/bootstrap/install.sh"
source "$PROJECT_DIR/src/cli/init.sh"

# Cleanup function
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_case() {
    local name="$1"
    ((TESTS_RUN++)) || true
    echo -n "Testing: $name... "
    unset NEEDLE_WORKSPACE || true
    unset NEEDLE_CONFIG_WORKSPACE || true
}

test_pass() {
    echo "PASS"
    ((TESTS_PASSED++)) || true
}

test_fail() {
    local reason="${1:-}"
    echo "FAIL"
    [[ -n "$reason" ]] && echo "  Reason: $reason"
    ((TESTS_FAILED++)) || true
}

# ============ _needle_init_help Tests ============

test_case "_needle_init_help outputs usage information"
output=$(_needle_init_help 2>&1)
if echo "$output" | grep -q "needle init" && echo "$output" | grep -q "OPTIONS"; then
    test_pass
else
    test_fail "Missing usage/OPTIONS in help output"
fi

test_case "_needle_init_help mentions --non-interactive flag"
output=$(_needle_init_help 2>&1)
if echo "$output" | grep -q "\-\-non-interactive"; then
    test_pass
else
    test_fail "Missing --non-interactive flag in help"
fi

test_case "_needle_init_help mentions --agent flag"
output=$(_needle_init_help 2>&1)
if echo "$output" | grep -q "\-\-agent"; then
    test_pass
else
    test_fail "Missing --agent flag in help"
fi

test_case "_needle_init_help mentions --check flag"
output=$(_needle_init_help 2>&1)
if echo "$output" | grep -q "\-\-check"; then
    test_pass
else
    test_fail "Missing --check flag in help"
fi

test_case "_needle_init_help mentions --force flag"
output=$(_needle_init_help 2>&1)
if echo "$output" | grep -q "\-\-force"; then
    test_pass
else
    test_fail "Missing --force flag in help"
fi

test_case "_needle_init_help lists valid agents"
output=$(_needle_init_help 2>&1)
if echo "$output" | grep -q "claude" && echo "$output" | grep -q "opencode"; then
    test_pass
else
    test_fail "Missing valid agent names in help"
fi

# ============ _needle_init_check_deps Tests ============

test_case "_needle_init_check_deps function exists"
if declare -f _needle_init_check_deps &>/dev/null; then
    test_pass
else
    test_fail "Function not defined"
fi

test_case "_needle_init_check_deps outputs dependency status"
output=$(_needle_init_check_deps 2>&1)
if echo "$output" | grep -qE "(✓|✗|⚠)"; then
    test_pass
else
    test_fail "No status indicators in output"
fi

# ============ _needle_create_default_config --agent Tests ============

test_case "_needle_create_default_config accepts --agent flag"
rm -rf "$TEST_HOME"
if _needle_create_default_config --defaults --agent opencode --path "$TEST_HOME/config.yaml" 2>/dev/null; then
    if grep -q "default_agent: opencode" "$TEST_HOME/config.yaml"; then
        test_pass
    else
        test_fail "Agent 'opencode' not set in config"
    fi
else
    test_fail "Failed with --agent opencode"
fi

test_case "_needle_create_default_config --agent claude sets correct default"
rm -rf "$TEST_HOME"
if _needle_create_default_config --defaults --agent claude --path "$TEST_HOME/config.yaml" 2>/dev/null; then
    if grep -q "default_agent: claude" "$TEST_HOME/config.yaml"; then
        test_pass
    else
        test_fail "Agent 'claude' not set in config"
    fi
else
    test_fail "Failed with --agent claude"
fi

test_case "_needle_create_default_config --agent codex sets correct default"
rm -rf "$TEST_HOME"
if _needle_create_default_config --defaults --agent codex --path "$TEST_HOME/config.yaml" 2>/dev/null; then
    if grep -q "default_agent: codex" "$TEST_HOME/config.yaml"; then
        test_pass
    else
        test_fail "Agent 'codex' not set in config"
    fi
else
    test_fail "Failed with --agent codex"
fi

test_case "_needle_create_default_config --agent aider sets correct default"
rm -rf "$TEST_HOME"
if _needle_create_default_config --defaults --agent aider --path "$TEST_HOME/config.yaml" 2>/dev/null; then
    if grep -q "default_agent: aider" "$TEST_HOME/config.yaml"; then
        test_pass
    else
        test_fail "Agent 'aider' not set in config"
    fi
else
    test_fail "Failed with --agent aider"
fi

test_case "_needle_create_default_config without --agent uses default"
rm -rf "$TEST_HOME"
if _needle_create_default_config --defaults --path "$TEST_HOME/config.yaml" 2>/dev/null; then
    if grep -q "default_agent: $NEEDLE_DEFAULT_AGENT" "$TEST_HOME/config.yaml"; then
        test_pass
    else
        test_fail "Default agent not used when --agent not specified"
    fi
else
    test_fail "Config creation without --agent failed"
fi

# ============ _needle_onboarding_create_config --agent Tests ============

test_case "_needle_onboarding_create_config passes --agent to config"
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
if _needle_onboarding_create_config --defaults --agent opencode --path "$TEST_HOME/config.yaml" 2>/dev/null; then
    if grep -q "default_agent: opencode" "$TEST_HOME/config.yaml"; then
        test_pass
    else
        test_fail "Agent not set via onboarding wrapper"
    fi
else
    test_fail "Onboarding config with --agent failed"
fi

# ============ Non-interactive flag compatibility Tests ============

test_case "_needle_prompt_default_agent uses preset as default in interactive mode"
# With a preset agent value passed as default, the function should return it when no input given
default_agent=$( echo "" | _needle_prompt_default_agent "opencode" 2>/dev/null )
if [[ "$default_agent" == "opencode" ]]; then
    test_pass
else
    test_fail "Expected 'opencode', got '$default_agent'"
fi

test_case "_needle_prompt_max_workers returns default on empty input"
result=$( echo "" | _needle_prompt_max_workers 7 2>/dev/null )
if [[ "$result" == "7" ]]; then
    test_pass
else
    test_fail "Expected '7', got '$result'"
fi

test_case "_needle_prompt_max_workers returns default in non-interactive mode"
# In non-interactive mode (no TTY), prompt functions always use defaults
result=$( echo "10" | _needle_prompt_max_workers 5 2>/dev/null )
if [[ "$result" == "5" ]]; then
    test_pass
else
    test_fail "Expected default '5' in non-interactive mode, got '$result'"
fi

test_case "_needle_prompt_max_workers rejects non-numeric input and returns default"
result=$( echo "abc" | _needle_prompt_max_workers 5 2>/dev/null )
if [[ "$result" == "5" ]]; then
    test_pass
else
    test_fail "Expected default '5', got '$result'"
fi

test_case "_needle_prompt_max_workers rejects out-of-range input and returns default"
result=$( echo "0" | _needle_prompt_max_workers 5 2>/dev/null )
if [[ "$result" == "5" ]]; then
    test_pass
else
    test_fail "Expected default '5', got '$result'"
fi

test_case "_needle_prompt_daily_limit returns default on empty input"
result=$( echo "" | _needle_prompt_daily_limit 15.00 2>/dev/null )
if [[ "$result" == "15.00" ]]; then
    test_pass
else
    test_fail "Expected '15.00', got '$result'"
fi

test_case "_needle_prompt_daily_limit returns default in non-interactive mode"
# In non-interactive mode (no TTY), prompt functions always use defaults
result=$( echo "25.50" | _needle_prompt_daily_limit 10.00 2>/dev/null )
if [[ "$result" == "10.00" ]]; then
    test_pass
else
    test_fail "Expected default '10.00' in non-interactive mode, got '$result'"
fi

test_case "_needle_prompt_daily_limit rejects non-numeric input and returns default"
result=$( echo "not-a-number" | _needle_prompt_daily_limit 10.00 2>/dev/null )
if [[ "$result" == "10.00" ]]; then
    test_pass
else
    test_fail "Expected default '10.00', got '$result'"
fi

test_case "_needle_prompt_default_agent validates known agents"
result=$( echo "claude" | _needle_prompt_default_agent "claude" 2>/dev/null )
if [[ "$result" == "claude" ]]; then
    test_pass
else
    test_fail "Expected 'claude', got '$result'"
fi

test_case "_needle_prompt_default_agent rejects unknown agent and returns default"
result=$( echo "unknown-agent" | _needle_prompt_default_agent "claude" 2>/dev/null )
if [[ "$result" == "claude" ]]; then
    test_pass
else
    test_fail "Expected default 'claude', got '$result'"
fi

# ============ Config generation with agent Tests ============

test_case "_needle_generate_config_yaml with custom agent"
config=$(_needle_generate_config_yaml --default-agent aider)
if echo "$config" | grep -q "default_agent: aider"; then
    test_pass
else
    test_fail "Custom agent not in generated YAML"
fi

test_case "_needle_generate_config_yaml with custom max-workers"
config=$(_needle_generate_config_yaml --max-workers 8)
if echo "$config" | grep -q "max_concurrent: 8"; then
    test_pass
else
    test_fail "Custom max-workers not in generated YAML"
fi

test_case "_needle_generate_config_yaml with telemetry disabled"
config=$(_needle_generate_config_yaml --telemetry false)
if echo "$config" | grep -q "enabled: false"; then
    test_pass
else
    test_fail "Telemetry disabled not in generated YAML"
fi

test_case "_needle_generate_config_yaml with custom daily-limit"
config=$(_needle_generate_config_yaml --daily-limit 50.00)
if echo "$config" | grep -q "daily_limit_usd: 50.00"; then
    test_pass
else
    test_fail "Custom daily-limit not in generated YAML"
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
