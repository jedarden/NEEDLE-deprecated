#!/usr/bin/env bash
# Tests for NEEDLE prompt builder module (src/bead/prompt.sh)

# Test setup - create temp directory
TEST_DIR=$(mktemp -d)
TEST_WORKSPACE="$TEST_DIR/workspace"
mkdir -p "$TEST_WORKSPACE"

# Source the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Set up test environment
export NEEDLE_HOME="$TEST_DIR/.needle"
export NEEDLE_STATE_DIR="state"
export NEEDLE_QUIET=true
export NEEDLE_VERBOSE=false
export NEEDLE_PROMPT_MAX_FILE_LINES=50

# Source required modules
source "$PROJECT_DIR/src/lib/constants.sh"
source "$PROJECT_DIR/src/lib/output.sh"
source "$PROJECT_DIR/src/lib/utils.sh"
source "$PROJECT_DIR/src/bead/prompt.sh"

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

# Mock br show command for testing
mock_br_show() {
    local data="$1"
    # Create a mock br script
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/br" << EOF
#!/bin/bash
case "\$1 \$2 \$3" in
    "show "*" --json")
        echo '$data'
        ;;
    *)
        echo "[]" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$TEST_DIR/bin/br"
    export PATH="$TEST_DIR/bin:$PATH"
}

# Remove mock
unmock_br() {
    export PATH="${PATH//$TEST_DIR\/bin:/}"
}

# Create test files in workspace
create_test_files() {
    mkdir -p "$TEST_WORKSPACE/src/lib"

    # Create a sample bash file
    cat > "$TEST_WORKSPACE/src/lib/utils.sh" << 'EOF'
#!/usr/bin/env bash
# Utility functions

hello() {
    echo "Hello, World!"
}

goodbye() {
    echo "Goodbye!"
}
EOF

    # Create a sample Python file
    cat > "$TEST_WORKSPACE/src/lib/helpers.py" << 'EOF'
#!/usr/bin/env python3
"""Helper functions for the application."""

def greet(name):
    """Greet someone by name."""
    return f"Hello, {name}!"

def farewell(name):
    """Say goodbye to someone."""
    return f"Goodbye, {name}!"
EOF

    # Create a sample JSON file
    cat > "$TEST_WORKSPACE/config.json" << 'EOF'
{
    "name": "test-project",
    "version": "1.0.0",
    "settings": {
        "debug": true
    }
}
EOF
}

echo "=== NEEDLE Prompt Builder Tests ==="
echo ""

# Run file creation for all tests
create_test_files

# Test 1: Language detection
test_case "Detects bash language from .sh extension"
lang=$(_needle_get_file_lang "script.sh")
if [[ "$lang" == "bash" ]]; then
    test_pass
else
    test_fail "Expected 'bash', got '$lang'"
fi

test_case "Detects python language from .py extension"
lang=$(_needle_get_file_lang "module.py")
if [[ "$lang" == "python" ]]; then
    test_pass
else
    test_fail "Expected 'python', got '$lang'"
fi

test_case "Detects javascript language from .js extension"
lang=$(_needle_get_file_lang "app.js")
if [[ "$lang" == "javascript" ]]; then
    test_pass
else
    test_fail "Expected 'javascript', got '$lang'"
fi

test_case "Detects yaml language from .yaml extension"
lang=$(_needle_get_file_lang "config.yaml")
if [[ "$lang" == "yaml" ]]; then
    test_pass
else
    test_fail "Expected 'yaml', got '$lang'"
fi

test_case "Returns extension for unknown file types"
lang=$(_needle_get_file_lang "file.xyz")
if [[ "$lang" == "xyz" ]]; then
    test_pass
else
    test_fail "Expected 'xyz', got '$lang'"
fi

# Test 2: File context extraction
test_case "Extracts mentioned files from description"
description="Read the file src/lib/utils.sh and update it."
context=$(_needle_extract_file_context "$description" "$TEST_WORKSPACE")

if [[ "$context" == *"utils.sh"* ]] && [[ "$context" == *"hello()"* ]]; then
    test_pass
else
    test_fail "Expected file context with utils.sh content"
fi

test_case "Returns empty for no mentioned files"
description="This task has no file references."
context=$(_needle_extract_file_context "$description" "$TEST_WORKSPACE")

if [[ -z "$context" ]]; then
    test_pass
else
    test_fail "Expected empty context, got: $context"
fi

test_case "Extracts multiple files from description"
description="Update src/lib/utils.sh and src/lib/helpers.py files."
context=$(_needle_extract_file_context "$description" "$TEST_WORKSPACE")

if [[ "$context" == *"utils.sh"* ]] && [[ "$context" == *"helpers.py"* ]]; then
    test_pass
else
    test_fail "Expected context with both files"
fi

test_case "Skips non-existent files"
description="Read the file nonexistent.py and update it."
context=$(_needle_extract_file_context "$description" "$TEST_WORKSPACE")

if [[ -z "$context" ]]; then
    test_pass
else
    test_fail "Expected empty context for non-existent file"
fi

# Test 3: Shell escaping
test_case "Escapes single quotes in prompt"
original="It's a test"
escaped=$(_needle_escape_prompt "$original")

# Verify the escaped string can be safely embedded
eval "result='$escaped'"
if [[ "$result" == "$original" ]]; then
    test_pass
else
    test_fail "Escaping broke the string: got '$result'"
fi

test_case "Escapes multiple single quotes"
original="It's a 'test' with quotes"
escaped=$(_needle_escape_prompt "$original")

eval "result='$escaped'"
if [[ "$result" == "$original" ]]; then
    test_pass
else
    test_fail "Escaping broke the string: got '$result'"
fi

test_case "Handles newlines in prompt"
original=$'Line 1\nLine 2\nLine 3'
escaped=$(_needle_escape_prompt "$original")

eval "result='$escaped'"
if [[ "$result" == "$original" ]]; then
    test_pass
else
    test_fail "Escaping broke newlines"
fi

# Test 4: JSON escaping
test_case "Escapes prompt for JSON"
original='Test with "quotes" and \backslashes\'
escaped=$(_needle_escape_json "$original")

if [[ "$escaped" == *'"Test with '* ]] && [[ "$escaped" == *'\\'* ]]; then
    test_pass
else
    test_fail "JSON escaping failed: $escaped"
fi

# Test 5: Prompt validation
test_case "Validates correct prompt structure"
prompt="# Task: Test
## Bead ID
nd-test
## Description
A test task
## Workspace
/test"

if _needle_validate_prompt "$prompt" &>/dev/null; then
    test_pass
else
    test_fail "Valid prompt rejected"
fi

test_case "Rejects empty prompt"
if ! _needle_validate_prompt "" &>/dev/null; then
    test_pass
else
    test_fail "Empty prompt should be rejected"
fi

test_case "Rejects prompt without Bead ID"
prompt="# Task: Test
## Description
A test task"

if ! _needle_validate_prompt "$prompt" &>/dev/null; then
    test_pass
else
    test_fail "Prompt without Bead ID should be rejected"
fi

test_case "Rejects prompt without Description"
prompt="# Task: Test
## Bead ID
nd-test"

if ! _needle_validate_prompt "$prompt" &>/dev/null; then
    test_pass
else
    test_fail "Prompt without Description should be rejected"
fi

# Test 6: Full prompt building
test_case "Builds prompt from bead JSON"
mock_br_show '[{
    "id": "nd-test1",
    "title": "Test Task",
    "description": "A test task description",
    "labels": ["test", "unit"],
    "status": "open",
    "priority": 1
}]'

prompt=$(_needle_build_prompt "nd-test1" "$TEST_WORKSPACE" 2>/dev/null)

if [[ "$prompt" == *"Test Task"* ]] && \
   [[ "$prompt" == *"nd-test1"* ]] && \
   [[ "$prompt" == *"A test task description"* ]] && \
   [[ "$prompt" == *"test, unit"* ]] && \
   [[ "$prompt" == *"P1 (high)"* ]]; then
    test_pass
else
    test_fail "Prompt missing expected content"
fi

test_case "Handles missing labels"
mock_br_show '[{
    "id": "nd-test2",
    "title": "Task Without Labels",
    "description": "No labels here",
    "status": "open",
    "priority": 2
}]'

prompt=$(_needle_build_prompt "nd-test2" "$TEST_WORKSPACE" 2>/dev/null)

if [[ "$prompt" == *"Task Without Labels"* ]] && [[ "$prompt" == *"nd-test2"* ]]; then
    test_pass
else
    test_fail "Failed to build prompt without labels"
fi

test_case "Handles empty description"
mock_br_show '[{
    "id": "nd-test3",
    "title": "Task Without Description",
    "description": "",
    "status": "open",
    "priority": 2
}]'

prompt=$(_needle_build_prompt "nd-test3" "$TEST_WORKSPACE" 2>/dev/null)

if [[ "$prompt" == *"Task Without Description"* ]]; then
    test_pass
else
    test_fail "Failed to build prompt with empty description"
fi

test_case "Includes mentioned files in prompt"
mock_br_show '[{
    "id": "nd-test4",
    "title": "Task With Files",
    "description": "Update the file src/lib/utils.sh",
    "status": "open",
    "priority": 2
}]'

prompt=$(_needle_build_prompt "nd-test4" "$TEST_WORKSPACE" 2>/dev/null)

if [[ "$prompt" == *"Mentioned Files"* ]] && [[ "$prompt" == *"utils.sh"* ]]; then
    test_pass
else
    test_fail "Prompt missing file context"
fi

# Test 7: Error handling
test_case "Returns error for missing bead ID"
if ! _needle_build_prompt "" "$TEST_WORKSPACE" &>/dev/null; then
    test_pass
else
    test_fail "Should fail with missing bead ID"
fi

test_case "Returns error for missing workspace"
if ! _needle_build_prompt "nd-test" "" &>/dev/null; then
    test_pass
else
    test_fail "Should fail with missing workspace"
fi

test_case "Returns error for non-existent workspace"
if ! _needle_build_prompt "nd-test" "/nonexistent/path" &>/dev/null; then
    test_pass
else
    test_fail "Should fail with non-existent workspace"
fi

test_case "Returns error for non-existent bead"
mock_br_show '[]'

if ! _needle_build_prompt "nd-nonexistent" "$TEST_WORKSPACE" &>/dev/null; then
    test_pass
else
    test_fail "Should fail for non-existent bead"
fi

# Test 8: Minimal prompt
test_case "Builds minimal prompt"
mock_br_show '[{
    "id": "nd-minimal",
    "title": "Minimal Task",
    "description": "A minimal task description that might be quite long but should be truncated in the minimal view"
}]'

prompt=$(_needle_build_minimal_prompt "nd-minimal" "$TEST_WORKSPACE" 2>/dev/null)

if [[ "$prompt" == *"Minimal Task"* ]] && [[ "$prompt" == *"nd-minimal"* ]]; then
    test_pass
else
    test_fail "Minimal prompt missing expected content"
fi

# Cleanup
unmock_br

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
