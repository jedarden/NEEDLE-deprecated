#!/usr/bin/env bash
# Tests for NEEDLE config creation module (src/onboarding/create_config.sh)

# Test setup
TEST_DIR=$(mktemp -d)
TEST_HOME="$TEST_DIR/.needle"
TEST_CONFIG="$TEST_HOME/config.yaml"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_HOME"
export HOME="$TEST_DIR"

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/lib/json.sh"
source "$PROJECT_DIR/src/onboarding/agents.sh"
source "$PROJECT_DIR/src/onboarding/create_config.sh"

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

# ============ Tests ============

# Test: _needle_create_config_dirs creates directory structure
test_case "_needle_create_config_dirs creates directory structure"
rm -rf "$TEST_HOME"
if _needle_create_config_dirs "$TEST_HOME" && [[ -d "$TEST_HOME" ]]; then
    if [[ -d "$TEST_HOME/state" ]] && [[ -d "$TEST_HOME/cache" ]] && [[ -d "$TEST_HOME/logs" ]]; then
        test_pass
    else
        test_fail "Missing subdirectories"
    fi
else
    test_fail "Directory creation failed"
fi

# Test: _needle_create_config_dirs is idempotent
test_case "_needle_create_config_dirs is idempotent"
if _needle_create_config_dirs "$TEST_HOME" && _needle_create_config_dirs "$TEST_HOME"; then
    test_pass
else
    test_fail "Failed on second run"
fi

# Test: _needle_generate_config_yaml produces valid YAML
test_case "_needle_generate_config_yaml produces valid YAML"
config=$(_needle_generate_config_yaml)
if [[ -n "$config" ]] && echo "$config" | grep -q "needle:" && echo "$config" | grep -q "workers:"; then
    test_pass
else
    test_fail "Generated config missing required sections"
fi

# Test: _needle_generate_config_yaml accepts custom values
test_case "_needle_generate_config_yaml accepts custom values"
config=$(_needle_generate_config_yaml --max-workers 10 --default-agent opencode --daily-limit 25.00)
if echo "$config" | grep -q "max_concurrent: 10" && echo "$config" | grep -q "default_agent: opencode" && echo "$config" | grep -q "daily_limit_usd: 25.00"; then
    test_pass
else
    test_fail "Custom values not applied"
fi

# Test: _needle_generate_config_yaml includes all required sections
test_case "_needle_generate_config_yaml includes all required sections"
config=$(_needle_generate_config_yaml)
required_sections=("needle:" "workers:" "telemetry:" "budget:" "limits:" "runner:" "strands:" "mend:" "hooks:" "mitosis:" "watchdog:")
missing=""
for section in "${required_sections[@]}"; do
    if ! echo "$config" | grep -q "$section"; then
        missing="$missing $section"
    fi
done
if [[ -z "$missing" ]]; then
    test_pass
else
    test_fail "Missing sections:$missing"
fi

# Test: _needle_create_default_config creates file with --defaults
test_case "_needle_create_default_config creates file with --defaults"
rm -rf "$TEST_HOME"
if _needle_create_default_config --defaults --path "$TEST_CONFIG" && [[ -f "$TEST_CONFIG" ]]; then
    test_pass
else
    test_fail "Config file not created"
fi

# Test: _needle_create_default_config creates directory structure
test_case "_needle_create_default_config creates directory structure"
if [[ -d "$TEST_HOME/state" ]] && [[ -d "$TEST_HOME/cache" ]] && [[ -d "$TEST_HOME/logs" ]]; then
    test_pass
else
    test_fail "Directory structure not created"
fi

# Test: _needle_validate_generated_config validates valid config
test_case "_needle_validate_generated_config validates valid config"
if _needle_validate_generated_config "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Valid config failed validation"
fi

# Test: _needle_validate_generated_config fails for non-existent file
test_case "_needle_validate_generated_config fails for non-existent file"
if ! _needle_validate_generated_config "/nonexistent/config.yaml" 2>/dev/null; then
    test_pass
else
    test_fail "Expected validation to fail"
fi

# Test: _needle_validate_generated_config fails for empty file
test_case "_needle_validate_generated_config fails for empty file"
empty_file="$TEST_DIR/empty.yaml"
touch "$empty_file"
if ! _needle_validate_generated_config "$empty_file" 2>/dev/null; then
    test_pass
else
    test_fail "Empty file should fail validation"
fi

# Test: _needle_validate_generated_config fails for missing section
test_case "_needle_validate_generated_config fails for missing section"
bad_config="$TEST_DIR/bad.yaml"
cat > "$bad_config" << 'EOF'
needle:
  version: 1
EOF
if ! _needle_validate_generated_config "$bad_config" 2>/dev/null; then
    test_pass
else
    test_fail "Missing sections should fail validation"
fi

# Test: _needle_create_default_config fails without --force if exists
test_case "_needle_create_default_config skips without --force if exists"
# Config already exists from previous test
output=$(_needle_create_default_config --defaults --path "$TEST_CONFIG" 2>&1)
result=$?
if [[ $result -eq 0 ]]; then
    test_pass
else
    test_fail "Should succeed (skip) when config exists"
fi

# Test: _needle_create_default_config overwrites with --force
test_case "_needle_create_default_config overwrites with --force"
original_mtime=$(stat -c %Y "$TEST_CONFIG" 2>/dev/null || stat -f %m "$TEST_CONFIG")
sleep 1
if _needle_create_default_config --defaults --force --path "$TEST_CONFIG"; then
    new_mtime=$(stat -c %Y "$TEST_CONFIG" 2>/dev/null || stat -f %m "$TEST_CONFIG")
    if [[ "$new_mtime" -gt "$original_mtime" ]]; then
        test_pass
    else
        test_fail "File was not overwritten"
    fi
else
    test_fail "Force overwrite failed"
fi

# Test: Config contains version number
test_case "Config contains version number"
if grep -q "version:" "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Missing version in config"
fi

# Test: Config contains max_concurrent setting
test_case "Config contains max_concurrent setting"
if grep -q "max_concurrent:" "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Missing max_concurrent in config"
fi

# Test: Config contains default_agent setting
test_case "Config contains default_agent setting"
if grep -q "default_agent:" "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Missing default_agent in config"
fi

# Test: Config contains telemetry settings
test_case "Config contains telemetry settings"
if grep -q "telemetry:" "$TEST_CONFIG" && grep -q "enabled:" "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Missing telemetry settings in config"
fi

# Test: Config contains budget settings
test_case "Config contains budget settings"
if grep -q "budget:" "$TEST_CONFIG" && grep -q "daily_limit_usd:" "$TEST_CONFIG" && grep -q "warn_threshold:" "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Missing budget settings in config"
fi

# Test: _needle_quick_create_config creates config
test_case "_needle_quick_create_config creates config"
quick_config="$TEST_DIR/quick/.needle/config.yaml"
if _needle_quick_create_config --path "$quick_config" && [[ -f "$quick_config" ]]; then
    test_pass
else
    test_fail "Quick config creation failed"
fi

# Test: _needle_onboarding_create_config succeeds with defaults
test_case "_needle_onboarding_create_config succeeds with defaults"
onboard_config="$TEST_DIR/onboard/.needle/config.yaml"
if _needle_onboarding_create_config --defaults --path "$onboard_config"; then
    test_pass
else
    test_fail "Onboarding config creation failed"
fi

# Test: Generated config is valid YAML (if yq available)
test_case "Generated config is valid YAML (if yq available)"
if command -v yq &>/dev/null; then
    if yq eval '.' "$TEST_CONFIG" &>/dev/null; then
        test_pass
    else
        test_fail "Invalid YAML syntax"
    fi
else
    echo "SKIP (yq not available)"
    ((TESTS_PASSED++))
fi

# Test: Config uses correct default values
test_case "Config uses correct default values"
rm -rf "$TEST_HOME"
_needle_create_default_config --defaults --path "$TEST_CONFIG"
if grep -q "max_concurrent: $NEEDLE_DEFAULT_MAX_CONCURRENT" "$TEST_CONFIG" && \
   grep -q "default_agent: $NEEDLE_DEFAULT_AGENT" "$TEST_CONFIG"; then
    test_pass
else
    test_fail "Default values not used"
fi

# Test: Hooks directory is created
test_case "Hooks directory is created"
if [[ -d "$TEST_HOME/hooks" ]]; then
    test_pass
else
    test_fail "Hooks directory not created"
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
