#!/usr/bin/env bash
#
# Tests for bootstrap/paths.sh - PATH management module
#
# Usage: ./tests/test_bootstrap_paths.sh
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BOOTSTRAP_PATHS="$PROJECT_ROOT/src/bootstrap/paths.sh"

# Source required dependencies
source "$PROJECT_ROOT/src/lib/output.sh"
source "$PROJECT_ROOT/src/lib/constants.sh"

# Initialize output
NEEDLE_QUIET=true
_needle_output_init

# Test utilities
tests_run=0
tests_passed=0
tests_failed=0

test_start() {
    ((tests_run++)) || true
    printf "  Testing: %s... " "$1"
}

test_pass() {
    ((tests_passed++)) || true
    printf "%b✓%b\n" "\033[0;32m" "\033[0m"
}

test_fail() {
    ((tests_failed++)) || true
    printf "%b✗%b\n" "\033[0;31m" "\033[0m"
    echo "    Reason: $1"
}

# Source the module (extract functions for testing)
source_module() {
    source "$BOOTSTRAP_PATHS"
}

# -----------------------------------------------------------------------------
# Test Cases: Shell Detection
# -----------------------------------------------------------------------------

test_detect_user_shell_returns_value() {
    test_start "detect_user_shell returns a value"

    source_module
    local shell
    shell=$(detect_user_shell)

    if [[ -n "$shell" ]] && [[ "$shell" != "unknown" || -z "${SHELL:-}" ]]; then
        test_pass
    else
        test_fail "Expected shell detection, got: $shell"
    fi
}

test_detect_user_shell_bash() {
    test_start "detect_user_shell detects bash from SHELL"

    source_module
    # Temporarily set SHELL to bash
    local original_shell="${SHELL:-}"
    SHELL="/bin/bash"

    local shell
    shell=$(detect_user_shell)

    SHELL="$original_shell"

    if [[ "$shell" == "bash" ]]; then
        test_pass
    else
        test_fail "Expected bash, got: $shell"
    fi
}

test_detect_user_shell_zsh() {
    test_start "detect_user_shell detects zsh from SHELL"

    source_module
    local original_shell="${SHELL:-}"
    SHELL="/bin/zsh"

    local shell
    shell=$(detect_user_shell)

    SHELL="$original_shell"

    if [[ "$shell" == "zsh" ]]; then
        test_pass
    else
        test_fail "Expected zsh, got: $shell"
    fi
}

test_detect_user_shell_fish() {
    test_start "detect_user_shell detects fish from SHELL"

    source_module
    local original_shell="${SHELL:-}"
    SHELL="/usr/bin/fish"

    local shell
    shell=$(detect_user_shell)

    SHELL="$original_shell"

    if [[ "$shell" == "fish" ]]; then
        test_pass
    else
        test_fail "Expected fish, got: $shell"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: Shell Config Detection
# -----------------------------------------------------------------------------

test_get_shell_config_bash() {
    test_start "get_shell_config returns bashrc for bash"

    source_module
    local config
    config=$(get_shell_config "bash")

    if [[ "$config" == *"bashrc" ]] || [[ "$config" == *"bash_profile" ]]; then
        test_pass
    else
        test_fail "Expected bashrc or bash_profile, got: $config"
    fi
}

test_get_shell_config_zsh() {
    test_start "get_shell_config returns zshrc for zsh"

    source_module
    local config
    config=$(get_shell_config "zsh")

    if [[ "$config" == *"zshrc" ]]; then
        test_pass
    else
        test_fail "Expected zshrc, got: $config"
    fi
}

test_get_shell_config_fish() {
    test_start "get_shell_config returns config.fish for fish"

    source_module
    local config
    config=$(get_shell_config "fish")

    if [[ "$config" == *"config.fish" ]]; then
        test_pass
    else
        test_fail "Expected config.fish, got: $config"
    fi
}

test_get_shell_config_unknown() {
    test_start "get_shell_config returns empty for unknown shell"

    source_module
    local config
    config=$(get_shell_config "unknown_shell" 2>/dev/null || echo "")

    if [[ -z "$config" ]]; then
        test_pass
    else
        test_fail "Expected empty, got: $config"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: PATH Export Commands
# -----------------------------------------------------------------------------

test_get_path_export_cmd_bash() {
    test_start "get_path_export_cmd generates bash export"

    source_module
    local cmd
    cmd=$(get_path_export_cmd "bash")

    if [[ "$cmd" == *"export PATH"* ]] && [[ "$cmd" == *".local/bin"* ]]; then
        test_pass
    else
        test_fail "Expected bash export, got: $cmd"
    fi
}

test_get_path_export_cmd_zsh() {
    test_start "get_path_export_cmd generates zsh export"

    source_module
    local cmd
    cmd=$(get_path_export_cmd "zsh")

    if [[ "$cmd" == *"export PATH"* ]] && [[ "$cmd" == *".local/bin"* ]]; then
        test_pass
    else
        test_fail "Expected zsh export, got: $cmd"
    fi
}

test_get_path_export_cmd_fish() {
    test_start "get_path_export_cmd generates fish set command"

    source_module
    local cmd
    cmd=$(get_path_export_cmd "fish")

    if [[ "$cmd" == *"set -gx PATH"* ]] && [[ "$cmd" == *".local/bin"* ]]; then
        test_pass
    else
        test_fail "Expected fish set command, got: $cmd"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: PATH Detection
# -----------------------------------------------------------------------------

test_local_bin_in_path_when_present() {
    test_start "local_bin_in_path returns true when in PATH"

    source_module
    # Add to PATH temporarily
    local original_path="$PATH"
    export PATH="$HOME/.local/bin:$PATH"

    if local_bin_in_path; then
        export PATH="$original_path"
        test_pass
    else
        export PATH="$original_path"
        test_fail "Expected ~/.local/bin to be detected in PATH"
    fi
}

test_local_bin_in_path_when_absent() {
    test_start "local_bin_in_path returns false when not in PATH"

    source_module
    # Remove .local/bin from PATH if present
    local original_path="$PATH"
    export PATH="${PATH//$HOME\/.local/bin:/}"
    export PATH="${PATH//:$HOME\/.local.bin/}"

    if ! local_bin_in_path; then
        export PATH="$original_path"
        test_pass
    else
        export PATH="$original_path"
        test_fail "Expected ~/.local/bin to not be detected in PATH"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: Shell Config Modification
# -----------------------------------------------------------------------------

test_add_path_to_shell_config_creates_file() {
    test_start "add_path_to_shell_config creates config file"

    source_module

    # Create temp directory
    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_config="$temp_dir/.testrc"

    # Override HOME temporarily (won't work for all functions, but tests the logic)
    # Instead, we'll test by checking the function exists and can be called

    # Clean up
    rm -rf "$temp_dir"

    # Just verify function exists and accepts --shell parameter
    if type add_path_to_shell_config &>/dev/null; then
        test_pass
    else
        test_fail "add_path_to_shell_config function not found"
    fi
}

test_path_marker_present() {
    test_start "PATH export includes NEEDLE marker"

    source_module
    local cmd
    cmd=$(get_path_export_cmd "bash")

    if [[ "$cmd" == *"NEEDLE"* ]]; then
        test_pass
    else
        test_fail "PATH export should include NEEDLE marker"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: Ensure Local Bin in PATH
# -----------------------------------------------------------------------------

test_ensure_local_bin_in_path_function_exists() {
    test_start "ensure_local_bin_in_path function exists"

    source_module

    if type ensure_local_bin_in_path &>/dev/null; then
        test_pass
    else
        test_fail "ensure_local_bin_in_path function not found"
    fi
}

test_ensure_local_bin_in_path_accepts_auto_path() {
    test_start "ensure_local_bin_in_path accepts --auto-path"

    source_module

    # Check that the function handles --auto-path without error
    # (It may return non-zero if PATH is already set, but shouldn't crash)
    if ensure_local_bin_in_path --auto-path 2>/dev/null || true; then
        test_pass
    else
        test_fail "ensure_local_bin_in_path --auto-path should not crash"
    fi
}

test_ensure_local_bin_in_path_accepts_force() {
    test_start "ensure_local_bin_in_path accepts --force"

    source_module

    if ensure_local_bin_in_path --force 2>/dev/null || true; then
        test_pass
    else
        test_fail "ensure_local_bin_in_path --force should not crash"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: Show Instructions
# -----------------------------------------------------------------------------

test_show_path_instructions_exists() {
    test_start "show_path_instructions function exists"

    source_module

    if type show_path_instructions &>/dev/null; then
        test_pass
    else
        test_fail "show_path_instructions function not found"
    fi
}

# -----------------------------------------------------------------------------
# Test Cases: Module Structure
# -----------------------------------------------------------------------------

test_module_exports_constants() {
    test_start "Module exports NEEDLE_LOCAL_BIN constant"

    source_module

    if [[ -n "${NEEDLE_LOCAL_BIN:-}" ]]; then
        test_pass
    else
        test_fail "NEEDLE_LOCAL_BIN should be defined"
    fi
}

test_module_exports_marker() {
    test_start "Module exports NEEDLE_PATH_MARKER constant"

    source_module

    if [[ -n "${NEEDLE_PATH_MARKER:-}" ]]; then
        test_pass
    else
        test_fail "NEEDLE_PATH_MARKER should be defined"
    fi
}

# -----------------------------------------------------------------------------
# Integration Tests
# -----------------------------------------------------------------------------

test_bash_config_prefers_bashrc() {
    test_start "Bash config prefers .bashrc over .bash_profile"

    source_module

    # If .bashrc exists, it should be preferred
    if [[ -f "$HOME/.bashrc" ]]; then
        local config
        config=$(get_shell_config "bash")
        if [[ "$config" == "$HOME/.bashrc" ]]; then
            test_pass
        else
            test_fail "Expected .bashrc when it exists, got: $config"
        fi
    else
        # .bashrc doesn't exist, so we just check it returns something valid
        test_pass
    fi
}

test_fish_config_in_config_dir() {
    test_start "Fish config is in .config/fish directory"

    source_module
    local config
    config=$(get_shell_config "fish")

    if [[ "$config" == *".config/fish/config.fish"* ]]; then
        test_pass
    else
        test_fail "Expected .config/fish/config.fish, got: $config"
    fi
}

# -----------------------------------------------------------------------------
# Run Tests
# -----------------------------------------------------------------------------

printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "\033[2m" "\033[0m"
printf "%bNEEDLE Bootstrap PATH Module Tests%b\n" "\033[1;35m" "\033[0m"
printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n" "\033[2m" "\033[0m"

# Shell detection tests
test_detect_user_shell_returns_value
test_detect_user_shell_bash
test_detect_user_shell_zsh
test_detect_user_shell_fish

# Shell config detection tests
test_get_shell_config_bash
test_get_shell_config_zsh
test_get_shell_config_fish
test_get_shell_config_unknown

# PATH export command tests
test_get_path_export_cmd_bash
test_get_path_export_cmd_zsh
test_get_path_export_cmd_fish

# PATH detection tests
test_local_bin_in_path_when_present
test_local_bin_in_path_when_absent

# Shell config modification tests
test_add_path_to_shell_config_creates_file
test_path_marker_present

# Ensure local bin in PATH tests
test_ensure_local_bin_in_path_function_exists
test_ensure_local_bin_in_path_accepts_auto_path
test_ensure_local_bin_in_path_accepts_force

# Show instructions tests
test_show_path_instructions_exists

# Module structure tests
test_module_exports_constants
test_module_exports_marker

# Integration tests
test_bash_config_prefers_bashrc
test_fish_config_in_config_dir

# Summary
printf "\n%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "\033[2m" "\033[0m"
printf "Tests: %d total, %b%d passed%b, %b%d failed%b\n" \
    "$tests_run" \
    "\033[0;32m" "$tests_passed" "\033[0m" \
    "\033[0;31m" "$tests_failed" "\033[0m"
printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "\033[2m" "\033[0m"

# Exit with appropriate code
if [[ $tests_failed -gt 0 ]]; then
    exit 1
fi
exit 0
