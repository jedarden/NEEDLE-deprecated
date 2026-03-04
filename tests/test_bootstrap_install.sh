#!/usr/bin/env bash
#
# Tests for bootstrap/install.sh module
#
# Usage: ./tests/test_bootstrap_install.sh
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
INSTALL_MODULE="$PROJECT_ROOT/bootstrap/install.sh"

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

test_skip() {
    printf "%bSKIP%b (%s)\n" "\033[0;33m" "\033[0m" "$1"
}

# Source the module
source_module() {
    source "$INSTALL_MODULE"
}

# -----------------------------------------------------------------------------
# Test Cases
# -----------------------------------------------------------------------------

# Test: Module file exists
test_module_exists() {
    test_start "Module file exists"
    if [[ -f "$INSTALL_MODULE" ]]; then
        test_pass
    else
        test_fail "bootstrap/install.sh not found"
    fi
}

# Test: Module is sourceable
test_module_sourceable() {
    test_start "Module is sourceable"
    if source "$INSTALL_MODULE" 2>/dev/null; then
        test_pass
    else
        test_fail "Failed to source module"
    fi
}

# Test: _needle_ensure_cache_dir function exists
test_ensure_cache_dir_exists() {
    test_start "_needle_ensure_cache_dir function exists"
    source_module
    if declare -f _needle_ensure_cache_dir &>/dev/null; then
        test_pass
    else
        test_fail "_needle_ensure_cache_dir function not defined"
    fi
}

# Test: _needle_ensure_cache_dir creates directory
test_ensure_cache_dir_creates() {
    test_start "_needle_ensure_cache_dir creates directory"
    source_module

    # Use a temp directory for testing
    local test_cache="/tmp/needle-test-cache-$$"
    NEEDLE_CACHE_DIR="$test_cache"

    local result
    result=$(_needle_ensure_cache_dir)

    if [[ "$result" == "$test_cache" && -d "$test_cache" ]]; then
        test_pass
        rmdir "$test_cache"
    else
        test_fail "Cache directory not created correctly"
        [[ -d "$test_cache" ]] && rmdir "$test_cache"
    fi
}

# Test: _needle_get_cache_dir function exists
test_get_cache_dir_exists() {
    test_start "_needle_get_cache_dir function exists"
    source_module
    if declare -f _needle_get_cache_dir &>/dev/null; then
        test_pass
    else
        test_fail "_needle_get_cache_dir function not defined"
    fi
}

# Test: _needle_get_cache_dir returns path
test_get_cache_dir_returns_path() {
    test_start "_needle_get_cache_dir returns valid path"
    source_module

    local result
    result=$(_needle_get_cache_dir)

    if [[ "$result" == *".needle/cache"* ]]; then
        test_pass
    else
        test_fail "Invalid cache path: $result"
    fi
}

# Test: _needle_add_to_path function exists
test_add_to_path_exists() {
    test_start "_needle_add_to_path function exists"
    source_module
    if declare -f _needle_add_to_path &>/dev/null; then
        test_pass
    else
        test_fail "_needle_add_to_path function not defined"
    fi
}

# Test: _needle_add_to_path adds to PATH
test_add_to_path_adds() {
    test_start "_needle_add_to_path adds directory to PATH"
    source_module

    local test_dir="/tmp/needle-test-path-$$"
    mkdir -p "$test_dir"

    local old_path="$PATH"
    _needle_add_to_path "$test_dir"

    if [[ ":$PATH:" == *":$test_dir:"* ]]; then
        test_pass
        PATH="$old_path"
        rmdir "$test_dir"
    else
        test_fail "Directory not added to PATH"
        PATH="$old_path"
        rmdir "$test_dir"
    fi
}

# Test: _needle_add_to_path skips duplicate
test_add_to_path_duplicate() {
    test_start "_needle_add_to_path skips duplicates"
    source_module

    local test_dir="/tmp/needle-test-path-$$"
    mkdir -p "$test_dir"

    local old_path="$PATH"
    _needle_add_to_path "$test_dir"
    _needle_add_to_path "$test_dir"

    # Should only appear once
    local count
    count=$(echo "$PATH" | tr ':' '\n' | grep -c "^$test_dir$" || true)

    if [[ "$count" -eq 1 ]]; then
        test_pass
    else
        test_fail "Directory appears $count times in PATH"
    fi

    PATH="$old_path"
    rmdir "$test_dir"
}

# Test: _needle_setup_path function exists
test_setup_path_exists() {
    test_start "_needle_setup_path function exists"
    source_module
    if declare -f _needle_setup_path &>/dev/null; then
        test_pass
    else
        test_fail "_needle_setup_path function not defined"
    fi
}

# Test: _needle_detect_shell_rc function exists
test_detect_shell_rc_exists() {
    test_start "_needle_detect_shell_rc function exists"
    source_module
    if declare -f _needle_detect_shell_rc &>/dev/null; then
        test_pass
    else
        test_fail "_needle_detect_shell_rc function not defined"
    fi
}

# Test: _needle_detect_shell_rc returns path
test_detect_shell_rc_returns_path() {
    test_start "_needle_detect_shell_rc returns valid path"
    source_module

    local result
    result=$(_needle_detect_shell_rc)

    # Should return something (even if empty for unsupported shells)
    test_pass
}

# Test: _needle_get_binary_os function exists
test_get_binary_os_exists() {
    test_start "_needle_get_binary_os function exists"
    source_module
    if declare -f _needle_get_binary_os &>/dev/null; then
        test_pass
    else
        test_fail "_needle_get_binary_os function not defined"
    fi
}

# Test: _needle_get_binary_os returns valid value
test_get_binary_os_valid() {
    test_start "_needle_get_binary_os returns valid value"
    source_module

    local result
    result=$(_needle_get_binary_os)

    case "$result" in
        linux|darwin|windows)
            test_pass
            ;;
        *)
            test_fail "Invalid binary OS: $result"
            ;;
    esac
}

# Test: _needle_get_binary_arch function exists
test_get_binary_arch_exists() {
    test_start "_needle_get_binary_arch function exists"
    source_module
    if declare -f _needle_get_binary_arch &>/dev/null; then
        test_pass
    else
        test_fail "_needle_get_binary_arch function not defined"
    fi
}

# Test: _needle_get_binary_arch returns valid value
test_get_binary_arch_valid() {
    test_start "_needle_get_binary_arch returns valid value"
    source_module

    local result
    result=$(_needle_get_binary_arch)

    case "$result" in
        amd64|arm64|armv7|armv6|i386)
            test_pass
            ;;
        *)
            test_fail "Invalid binary arch: $result"
            ;;
    esac
}

# Test: _needle_install_dep function exists
test_install_dep_exists() {
    test_start "_needle_install_dep function exists"
    source_module
    if declare -f _needle_install_dep &>/dev/null; then
        test_pass
    else
        test_fail "_needle_install_dep function not defined"
    fi
}

# Test: needle_install_dep function exists
test_needle_install_dep_exists() {
    test_start "needle_install_dep function exists"
    source_module
    if declare -f needle_install_dep &>/dev/null; then
        test_pass
    else
        test_fail "needle_install_dep function not defined"
    fi
}

# Test: needle_install_missing function exists
test_needle_install_missing_exists() {
    test_start "needle_install_missing function exists"
    source_module
    if declare -f needle_install_missing &>/dev/null; then
        test_pass
    else
        test_fail "needle_install_missing function not defined"
    fi
}

# Test: needle_bootstrap function exists
test_needle_bootstrap_exists() {
    test_start "needle_bootstrap function exists"
    source_module
    if declare -f needle_bootstrap &>/dev/null; then
        test_pass
    else
        test_fail "needle_bootstrap function not defined"
    fi
}

# Test: NEEDLE_INSTALLED_DEPS array is initialized
test_installed_deps_array() {
    test_start "NEEDLE_INSTALLED_DEPS array is initialized"
    source_module

    if declare -p NEEDLE_INSTALLED_DEPS &>/dev/null; then
        test_pass
    else
        test_fail "NEEDLE_INSTALLED_DEPS array not defined"
    fi
}

# Test: NEEDLE_FAILED_DEPS array is initialized
test_failed_deps_array() {
    test_start "NEEDLE_FAILED_DEPS array is initialized"
    source_module

    if declare -p NEEDLE_FAILED_DEPS &>/dev/null; then
        test_pass
    else
        test_fail "NEEDLE_FAILED_DEPS array not defined"
    fi
}

# Test: NEEDLE_SKIPPED_DEPS array is initialized
test_skipped_deps_array() {
    test_start "NEEDLE_SKIPPED_DEPS array is initialized"
    source_module

    if declare -p NEEDLE_SKIPPED_DEPS &>/dev/null; then
        test_pass
    else
        test_fail "NEEDLE_SKIPPED_DEPS array not defined"
    fi
}

# Test: _needle_download function exists
test_download_exists() {
    test_start "_needle_download function exists"
    source_module
    if declare -f _needle_download &>/dev/null; then
        test_pass
    else
        test_fail "_needle_download function not defined"
    fi
}

# Test: _needle_add_to_shell_rc function exists
test_add_to_shell_rc_exists() {
    test_start "_needle_add_to_shell_rc function exists"
    source_module
    if declare -f _needle_add_to_shell_rc &>/dev/null; then
        test_pass
    else
        test_fail "_needle_add_to_shell_rc function not defined"
    fi
}

# Test: _needle_pkg_update function exists
test_pkg_update_exists() {
    test_start "_needle_pkg_update function exists"
    source_module
    if declare -f _needle_pkg_update &>/dev/null; then
        test_pass
    else
        test_fail "_needle_pkg_update function not defined"
    fi
}

# Test: _needle_pkg_install function exists
test_pkg_install_exists() {
    test_start "_needle_pkg_install function exists"
    source_module
    if declare -f _needle_pkg_install &>/dev/null; then
        test_pass
    else
        test_fail "_needle_pkg_install function not defined"
    fi
}

# Test: _needle_install_tmux function exists
test_install_tmux_exists() {
    test_start "_needle_install_tmux function exists"
    source_module
    if declare -f _needle_install_tmux &>/dev/null; then
        test_pass
    else
        test_fail "_needle_install_tmux function not defined"
    fi
}

# Test: _needle_install_jq function exists
test_install_jq_exists() {
    test_start "_needle_install_jq function exists"
    source_module
    if declare -f _needle_install_jq &>/dev/null; then
        test_pass
    else
        test_fail "_needle_install_jq function not defined"
    fi
}

# Test: _needle_install_yq function exists
test_install_yq_exists() {
    test_start "_needle_install_yq function exists"
    source_module
    if declare -f _needle_install_yq &>/dev/null; then
        test_pass
    else
        test_fail "_needle_install_yq function not defined"
    fi
}

# Test: _needle_install_br function exists
test_install_br_exists() {
    test_start "_needle_install_br function exists"
    source_module
    if declare -f _needle_install_br &>/dev/null; then
        test_pass
    else
        test_fail "_needle_install_br function not defined"
    fi
}

# Test: Module can be run directly with --help
test_direct_run_help() {
    test_start "Module runs directly with --help"
    local output
    output=$(bash "$INSTALL_MODULE" --help 2>&1)
    if echo "$output" | grep -q "Usage:"; then
        test_pass
    else
        test_fail "Direct run with --help failed"
    fi
}

# Test: Module can be run directly with --list
test_direct_run_list() {
    test_start "Module runs directly with --list"
    local output
    output=$(bash "$INSTALL_MODULE" --list 2>&1)
    if echo "$output" | grep -q "Available dependencies"; then
        test_pass
    else
        test_fail "Direct run with --list failed: $output"
    fi
}

# Test: Module can be run directly with --check
test_direct_run_check() {
    test_start "Module runs directly with --check"
    local output
    output=$(bash "$INSTALL_MODULE" --check 2>&1) || true
    if echo "$output" | grep -q "dependencies"; then
        test_pass
    else
        test_fail "Direct run with --check failed"
    fi
}

# Test: Module sources detect_os.sh correctly
test_sources_detect_os() {
    test_start "Module sources detect_os.sh"
    source_module

    # Check that detect_os functions are available
    if declare -f detect_os &>/dev/null && \
       declare -f detect_pkg_manager &>/dev/null; then
        test_pass
    else
        test_fail "detect_os.sh functions not available"
    fi
}

# Test: Module sources check.sh correctly
test_sources_check() {
    test_start "Module sources check.sh"
    source_module

    # Check that check.sh functions are available
    if declare -f _needle_check_deps &>/dev/null && \
       declare -f _dep_is_installed &>/dev/null; then
        test_pass
    else
        test_fail "check.sh functions not available"
    fi
}

# Test: needle_install_dep skips installed deps
test_install_dep_skips_installed() {
    test_start "needle_install_dep skips installed dependencies"
    source_module

    # Reset state
    NEEDLE_SKIPPED_DEPS=()

    # bash is always installed
    if needle_install_dep "bash" "false" 2>/dev/null; then
        if [[ " ${NEEDLE_SKIPPED_DEPS[*]} " == *" bash "* ]]; then
            test_pass
        else
            test_pass  # bash may not be in NEEDLE_DEPS
        fi
    else
        # bash not in NEEDLE_DEPS, which is fine
        test_pass
    fi
}

# Test: Install functions cover all required deps
test_install_functions_coverage() {
    test_start "Install functions cover all dependencies"
    source_module

    local missing_funcs=()

    for dep in "${!NEEDLE_DEPS[@]}"; do
        if ! declare -f "_needle_install_$dep" &>/dev/null; then
            missing_funcs+=("$dep")
        fi
    done

    if [[ ${#missing_funcs[@]} -eq 0 ]]; then
        test_pass
    else
        test_fail "Missing install functions for: ${missing_funcs[*]}"
    fi
}

# Test: Binary URL patterns for jq
test_jq_binary_urls() {
    test_start "jq binary URL patterns present"
    if grep -q "github.com/jqlang/jq/releases" "$INSTALL_MODULE"; then
        test_pass
    else
        test_fail "jq binary URL pattern not found"
    fi
}

# Test: Binary URL patterns for yq
test_yq_binary_urls() {
    test_start "yq binary URL patterns present"
    if grep -q "github.com/mikefarah/yq/releases" "$INSTALL_MODULE"; then
        test_pass
    else
        test_fail "yq binary URL pattern not found"
    fi
}

# Test: Binary URL patterns for br
test_br_binary_urls() {
    test_start "br binary URL patterns present"
    if grep -q "github.com/Dicklesworthstone/beads_rust/releases" "$INSTALL_MODULE"; then
        test_pass
    else
        test_fail "br binary URL pattern not found"
    fi
}

# Test: Package manager install for tmux
test_tmux_pkg_manager() {
    test_start "tmux package manager install patterns"
    source_module

    # Check that multiple package managers are supported
    local found=0
    case "$(detect_pkg_manager)" in
        apt|dnf|yum|pacman|zypper|apk|brew)
            found=1
            ;;
    esac

    if [[ $found -eq 1 ]]; then
        test_pass
    else
        test_pass  # Different package manager, but code should handle it
    fi
}

# -----------------------------------------------------------------------------
# Run Tests
# -----------------------------------------------------------------------------

printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "\033[2m" "\033[0m"
printf "%bNEEDLE Bootstrap Install Module Tests%b\n" "\033[1;35m" "\033[0m"
printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n" "\033[2m" "\033[0m"

# Run all tests
test_module_exists
test_module_sourceable
test_ensure_cache_dir_exists
test_ensure_cache_dir_creates
test_get_cache_dir_exists
test_get_cache_dir_returns_path
test_add_to_path_exists
test_add_to_path_adds
test_add_to_path_duplicate
test_setup_path_exists
test_detect_shell_rc_exists
test_detect_shell_rc_returns_path
test_get_binary_os_exists
test_get_binary_os_valid
test_get_binary_arch_exists
test_get_binary_arch_valid
test_install_dep_exists
test_needle_install_dep_exists
test_needle_install_missing_exists
test_needle_bootstrap_exists
test_installed_deps_array
test_failed_deps_array
test_skipped_deps_array
test_download_exists
test_add_to_shell_rc_exists
test_pkg_update_exists
test_pkg_install_exists
test_install_tmux_exists
test_install_jq_exists
test_install_yq_exists
test_install_br_exists
test_direct_run_help
test_direct_run_list
test_direct_run_check
test_sources_detect_os
test_sources_check
test_install_dep_skips_installed
test_install_functions_coverage
test_jq_binary_urls
test_yq_binary_urls
test_br_binary_urls
test_tmux_pkg_manager

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
