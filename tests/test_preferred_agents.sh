#!/usr/bin/env bash
# Tests for preferred_agents workspace config feature
#
# Covers:
#   - get_preferred_agents returns list from workspace config
#   - get_preferred_agents returns default when no config
#   - get_preferred_agents returns default when key missing
#   - has_preferred_agents returns correct status
#   - get_first_available_preferred_agent returns first available
#   - get_first_available_preferred_agent falls back to default
#   - validate_preferred_agents accepts valid arrays
#   - validate_preferred_agents rejects invalid formats

# Don't use set -e - arithmetic can return 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Set up isolated test environment
NEEDLE_HOME="$(mktemp -d)"
TEST_WORKSPACE="$(mktemp -d)"
NEEDLE_CONFIG_NAME="config.yaml"
NEEDLE_CONFIG_FILE="$NEEDLE_HOME/$NEEDLE_CONFIG_NAME"

export NEEDLE_HOME NEEDLE_CONFIG_NAME NEEDLE_CONFIG_FILE
export NEEDLE_QUIET=true

# Source dependencies
source "$PROJECT_ROOT/src/lib/constants.sh"
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/utils.sh"
source "$PROJECT_ROOT/src/lib/config.sh"
source "$PROJECT_ROOT/src/lib/config_schema.sh"

# Cleanup on exit
cleanup() {
    rm -rf "$NEEDLE_HOME"
    rm -rf "$TEST_WORKSPACE"
}
trap cleanup EXIT

# ============================================================================
# Test framework
# ============================================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

_t() {
    local name="$1"
    ((TESTS_RUN++))
    echo -n "TEST: $name ... "
}

_pass() {
    echo "PASS"
    ((TESTS_PASSED++))
}

_fail() {
    echo "FAIL"
    [[ -n "$1" ]] && echo "  => $1"
    ((TESTS_FAILED++))
}

# Write a workspace config file
_write_ws_config() {
    cat > "$TEST_WORKSPACE/.needle.yaml"
}

# ============================================================================
# Tests: get_preferred_agents
# ============================================================================

echo ""
echo "========================================"
echo "get_preferred_agents tests"
echo "========================================"

# No workspace config file - returns default
rm -f "$TEST_WORKSPACE/.needle.yaml"
_t "get_preferred_agents with no config returns default"
result=$(get_preferred_agents "$TEST_WORKSPACE" "default-agent")
if [[ "$result" == "default-agent" ]]; then
    _pass
else
    _fail "Expected 'default-agent', got '$result'"
fi

# Empty workspace - returns default
_t "get_preferred_agents with empty workspace returns default"
result=$(get_preferred_agents "" "default-agent")
if [[ "$result" == "default-agent" ]]; then
    _pass
else
    _fail "Expected 'default-agent', got '$result'"
fi

# Config without preferred_agents - returns default
_write_ws_config <<'EOF'
strands:
  pluck: true
  explore: auto
EOF
_t "get_preferred_agents with no preferred_agents key returns default"
result=$(get_preferred_agents "$TEST_WORKSPACE" "default-agent")
if [[ "$result" == "default-agent" ]]; then
    _pass
else
    _fail "Expected 'default-agent', got '$result'"
fi

# Config with preferred_agents array
_write_ws_config <<'EOF'
preferred_agents:
  - claude-anthropic-sonnet
  - opencode-alibaba-qwen
strands:
  pluck: true
EOF
_t "get_preferred_agents returns list from config"
result=$(get_preferred_agents "$TEST_WORKSPACE" "")
if echo "$result" | grep -q "claude-anthropic-sonnet" && echo "$result" | grep -q "opencode-alibaba-qwen"; then
    _pass
else
    _fail "Expected agent list, got '$result'"
fi

# Config with single preferred_agents item
_write_ws_config <<'EOF'
preferred_agents:
  - single-agent
EOF
_t "get_preferred_agents returns single agent"
result=$(get_preferred_agents "$TEST_WORKSPACE" "")
if [[ "$result" == "single-agent" ]]; then
    _pass
else
    _fail "Expected 'single-agent', got '$result'"
fi

# ============================================================================
# Tests: has_preferred_agents
# ============================================================================

echo ""
echo "========================================"
echo "has_preferred_agents tests"
echo "========================================"

# No config
rm -f "$TEST_WORKSPACE/.needle.yaml"
_t "has_preferred_agents returns 1 when no config"
if ! has_preferred_agents "$TEST_WORKSPACE"; then
    _pass
else
    _fail "Expected false when no config"
fi

# Config without preferred_agents
_write_ws_config <<'EOF'
strands:
  pluck: true
EOF
_t "has_preferred_agents returns 1 when key missing"
if ! has_preferred_agents "$TEST_WORKSPACE"; then
    _pass
else
    _fail "Expected false when key missing"
fi

# Config with preferred_agents
_write_ws_config <<'EOF'
preferred_agents:
  - some-agent
EOF
_t "has_preferred_agents returns 0 when configured"
if has_preferred_agents "$TEST_WORKSPACE"; then
    _pass
else
    _fail "Expected true when configured"
fi

# Empty workspace
_t "has_preferred_agents returns 1 for empty workspace"
if ! has_preferred_agents ""; then
    _pass
else
    _fail "Expected false for empty workspace"
fi

# ============================================================================
# Tests: get_first_available_preferred_agent
# ============================================================================

echo ""
echo "========================================"
echo "get_first_available_preferred_agent tests"
echo "========================================"

# No config - returns default
rm -f "$TEST_WORKSPACE/.needle.yaml"
_t "get_first_available_preferred_agent returns default when no config"
result=$(get_first_available_preferred_agent "$TEST_WORKSPACE" "default-agent")
if [[ "$result" == "default-agent" ]]; then
    _pass
else
    _fail "Expected 'default-agent', got '$result'"
fi

# Config with preferred_agents but agent loader not available
_write_ws_config <<'EOF'
preferred_agents:
  - first-agent
  - second-agent
EOF
_t "get_first_available_preferred_agent returns first agent when loader unavailable"
result=$(get_first_available_preferred_agent "$TEST_WORKSPACE" "default-agent")
# Without _needle_is_agent_configured, it returns first agent
if [[ "$result" == "first-agent" ]]; then
    _pass
else
    _fail "Expected 'first-agent', got '$result'"
fi

# Config without preferred_agents - returns default
_write_ws_config <<'EOF'
strands:
  pluck: true
EOF
_t "get_first_available_preferred_agent returns default when key missing"
result=$(get_first_available_preferred_agent "$TEST_WORKSPACE" "default-agent")
if [[ "$result" == "default-agent" ]]; then
    _pass
else
    _fail "Expected 'default-agent', got '$result'"
fi

# ============================================================================
# Tests: validate_preferred_agents
# ============================================================================

echo ""
echo "========================================"
echo "validate_preferred_agents tests"
echo "========================================"

# Valid array
_write_ws_config <<'EOF'
preferred_agents:
  - claude-anthropic-sonnet
  - opencode-alibaba-qwen
EOF
_t "validate_preferred_agents accepts valid array"
if validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected valid for array of strings"
fi

# Valid single item array
_write_ws_config <<'EOF'
preferred_agents:
  - single-agent
EOF
_t "validate_preferred_agents accepts single item array"
if validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected valid for single item array"
fi

# Valid with hyphens and underscores
_write_ws_config <<'EOF'
preferred_agents:
  - agent-with-hyphens
  - agent_with_underscores
  - Agent-With-Mixed_Case
EOF
_t "validate_preferred_agents accepts hyphens and underscores"
if validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected valid for agent names with hyphens/underscores"
fi

# Missing config - passes (nothing to validate)
rm -f "$TEST_WORKSPACE/.needle.yaml"
_t "validate_preferred_agents passes when no config"
if validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected pass when no config file"
fi

# No preferred_agents key - passes
_write_ws_config <<'EOF'
strands:
  pluck: true
EOF
_t "validate_preferred_agents passes when key missing"
if validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected pass when preferred_agents not present"
fi

# Invalid: string instead of array (if yq/python can detect)
_write_ws_config <<'EOF'
preferred_agents: single-string-value
EOF
_t "validate_preferred_agents rejects string value"
if ! validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected rejection for string instead of array"
fi

# Invalid: object instead of array
_write_ws_config <<'EOF'
preferred_agents:
  agent1: value1
EOF
_t "validate_preferred_agents rejects object value"
if ! validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected rejection for object instead of array"
fi

# Invalid: special characters in agent name
_write_ws_config <<'EOF'
preferred_agents:
  - agent@invalid
EOF
_t "validate_preferred_agents rejects special characters"
if ! validate_preferred_agents "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected rejection for special characters in agent name"
fi

# ============================================================================
# Tests: validate_workspace_config
# ============================================================================

echo ""
echo "========================================"
echo "validate_workspace_config tests"
echo "========================================"

# Valid workspace config
_write_ws_config <<'EOF'
strands:
  pluck: true
  explore: auto
preferred_agents:
  - claude-anthropic-sonnet
  - opencode-alibaba-qwen
runner:
  polling_interval: 5s
EOF
_t "validate_workspace_config accepts valid config"
if validate_workspace_config "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected valid for complete workspace config"
fi

# Invalid strand value
_write_ws_config <<'EOF'
strands:
  pluck: invalid_value
EOF
_t "validate_workspace_config rejects invalid strand value"
if ! validate_workspace_config "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected rejection for invalid strand value"
fi

# Invalid YAML syntax
_write_ws_config <<'EOF'
strands:
  pluck: true
  broken: [unclosed
EOF
_t "validate_workspace_config rejects invalid YAML"
if ! validate_workspace_config "$TEST_WORKSPACE/.needle.yaml" 2>/dev/null; then
    _pass
else
    _fail "Expected rejection for invalid YAML syntax"
fi

# ============================================================================
# Tests: Integration with workspace config
# ============================================================================

echo ""
echo "========================================"
echo "Workspace config integration tests"
echo "========================================"

# Test that load_workspace_config merges preferred_agents
_write_ws_config <<'EOF'
preferred_agents:
  - workspace-agent-1
  - workspace-agent-2
strands:
  pluck: false
EOF

# Create a minimal global config
cat > "$NEEDLE_CONFIG_FILE" <<'EOF'
billing:
  model: pay_per_token
strands:
  pluck: true
EOF

_t "load_workspace_config includes preferred_agents"
ws_config=$(load_workspace_config "$TEST_WORKSPACE")
if echo "$ws_config" | grep -q "workspace-agent"; then
    _pass
else
    _fail "Expected preferred_agents in merged config"
fi

_t "workspace config overrides global strand settings"
result=$(get_workspace_config "$TEST_WORKSPACE" "strands.pluck" "not-set")
if [[ "$result" == "false" ]]; then
    _pass
else
    _fail "Expected 'false', got '$result'"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "========================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
