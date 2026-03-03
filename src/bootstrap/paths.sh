#!/usr/bin/env bash
# NEEDLE CLI Bootstrap PATH Management
# Detect and manage ~/.local/bin in PATH for NEEDLE binary access

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

NEEDLE_LOCAL_BIN="${NEEDLE_LOCAL_BIN:-$HOME/.local/bin}"
NEEDLE_PATH_MARKER="# Added by NEEDLE"

# -----------------------------------------------------------------------------
# Shell Detection Functions
# -----------------------------------------------------------------------------

# Detect the user's default shell
# Returns: "bash", "zsh", "fish", or "unknown"
# Usage: shell=$(detect_user_shell)
detect_user_shell() {
    local shell_name

    # First check $SHELL environment variable
    if [[ -n "${SHELL:-}" ]]; then
        shell_name=$(basename "$SHELL")
        case "$shell_name" in
            bash)      echo "bash";  return 0 ;;
            zsh)       echo "zsh";   return 0 ;;
            fish)      echo "fish";  return 0 ;;
        esac
    fi

    # Fallback: check if bash is available
    if command -v bash &>/dev/null; then
        echo "bash"
        return 0
    fi

    # Fallback: check for zsh
    if command -v zsh &>/dev/null; then
        echo "zsh"
        return 0
    fi

    echo "unknown"
    return 1
}

# Get the shell config file path for a given shell
# Usage: config_file=$(get_shell_config "bash")
get_shell_config() {
    local shell="${1:-$(detect_user_shell)}"

    case "$shell" in
        bash)
            # Check for ~/.bashrc first, then ~/.bash_profile
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        zsh)
            # Zsh uses ~/.zshrc
            echo "$HOME/.zshrc"
            ;;
        fish)
            # Fish uses ~/.config/fish/config.fish
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get the PATH export command for a given shell
# Usage: export_cmd=$(get_path_export_cmd "bash")
get_path_export_cmd() {
    local shell="${1:-$(detect_user_shell)}"
    local bin_dir="$NEEDLE_LOCAL_BIN"

    case "$shell" in
        bash|zsh)
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\"  $NEEDLE_PATH_MARKER"
            ;;
        fish)
            echo "set -gx PATH \$HOME/.local/bin \$PATH  $NEEDLE_PATH_MARKER"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# PATH Detection Functions
# -----------------------------------------------------------------------------

# Check if ~/.local/bin is in PATH
# Returns: 0 if in PATH, 1 if not
# Usage: if local_bin_in_path; then ...
local_bin_in_path() {
    [[ ":$PATH:" == *":$NEEDLE_LOCAL_BIN:"* ]]
}

# Check if ~/.local/bin is already configured in shell config
# Usage: if path_in_shell_config; then ...
path_in_shell_config() {
    local shell="${1:-$(detect_user_shell)}"
    local config_file
    config_file=$(get_shell_config "$shell")

    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        return 1
    fi

    # Check for our marker or the PATH export
    if grep -q "$NEEDLE_PATH_MARKER" "$config_file" 2>/dev/null; then
        return 0
    fi

    # Also check for generic .local/bin in PATH
    if grep -q '\.local/bin' "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# PATH Management Functions
# -----------------------------------------------------------------------------

# Add PATH export to shell config file
# Usage: add_path_to_shell_config [--shell <shell>]
add_path_to_shell_config() {
    local shell=""
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --shell)
                shell="$2"
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Detect shell if not specified
    if [[ -z "$shell" ]]; then
        shell=$(detect_user_shell)
    fi

    local config_file
    config_file=$(get_shell_config "$shell")

    if [[ -z "$config_file" ]]; then
        _needle_error "Could not determine shell config file for: $shell"
        return 1
    fi

    # Check if already present (unless forced)
    if [[ "$force" != "true" ]] && path_in_shell_config "$shell"; then
        _needle_info "PATH already configured in $config_file"
        return 0
    fi

    # Ensure config directory exists (especially for fish)
    local config_dir
    config_dir=$(dirname "$config_file")
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" || {
            _needle_error "Failed to create directory: $config_dir"
            return 1
        }
    fi

    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        touch "$config_file" || {
            _needle_error "Failed to create config file: $config_file"
            return 1
        }
    fi

    # Get the export command
    local export_cmd
    export_cmd=$(get_path_export_cmd "$shell")

    if [[ -z "$export_cmd" ]]; then
        _needle_error "Could not generate PATH export for shell: $shell"
        return 1
    fi

    # Add newline if file doesn't end with one
    if [[ -s "$config_file" ]] && [[ $(tail -c 1 "$config_file" | wc -l) -eq 0 ]]; then
        echo "" >> "$config_file"
    fi

    # Add the PATH export
    echo "$export_cmd" >> "$config_file" || {
        _needle_error "Failed to write to config file: $config_file"
        return 1
    }

    _needle_success "Added ~/.local/bin to PATH in $config_file"
    return 0
}

# Interactive prompt to add PATH to shell config
# Usage: prompt_add_path
prompt_add_path() {
    local shell="${1:-$(detect_user_shell)}"
    local config_file
    config_file=$(get_shell_config "$shell")

    if [[ -z "$config_file" ]]; then
        _needle_error "Could not determine shell config file"
        return 1
    fi

    _needle_print ""
    _needle_warn "~/.local/bin is not in your PATH"
    _needle_info "NEEDLE installs to ~/.local/bin and needs it in your PATH"
    _needle_print ""
    _needle_print "  Detected shell: $shell"
    _needle_print "  Config file: $config_file"
    _needle_print ""

    if _needle_confirm "Add ~/.local/bin to your PATH?" "y"; then
        add_path_to_shell_config --shell "$shell"
        local result=$?

        if [[ $result -eq 0 ]]; then
            _needle_print ""
            _needle_info "To use NEEDLE immediately, run:"
            _needle_print "    source $config_file"
            _needle_print ""
            _needle_info "Or start a new shell session"
        fi
        return $result
    else
        _needle_info "Skipped PATH configuration"
        _needle_info "You can add it manually by adding this line to $config_file:"
        local export_cmd
        export_cmd=$(get_path_export_cmd "$shell")
        _needle_print "    $export_cmd"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Bootstrap Entry Point
# -----------------------------------------------------------------------------

# Ensure ~/.local/bin is accessible
# This is the main entry point for PATH management during bootstrap
# Usage: ensure_local_bin_in_path [--auto-path] [--force]
ensure_local_bin_in_path() {
    local auto_path=false
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-path)
                auto_path=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Check if already in PATH
    if local_bin_in_path; then
        _needle_debug "~/.local/bin is already in PATH"
        return 0
    fi

    # Check if already configured in shell config
    if [[ "$force" != "true" ]] && path_in_shell_config; then
        _needle_info "~/.local/bin is configured in shell config"
        _needle_info "Start a new shell session or run: source $(get_shell_config)"
        return 0
    fi

    # Add to PATH based on mode
    if [[ "$auto_path" == "true" ]]; then
        # Non-interactive mode: automatically add to config
        _needle_info "Automatically adding ~/.local/bin to PATH..."
        add_path_to_shell_config --force
        return $?
    else
        # Interactive mode: prompt user
        prompt_add_path
        return $?
    fi
}

# Get instructions for manually adding PATH
# Usage: show_path_instructions
show_path_instructions() {
    local shell="${1:-$(detect_user_shell)}"
    local config_file
    config_file=$(get_shell_config "$shell")
    local export_cmd
    export_cmd=$(get_path_export_cmd "$shell")

    _needle_print ""
    _needle_section "Manual PATH Configuration"
    _needle_print ""
    _needle_print "  1. Add this line to $config_file:"
    _needle_print ""
    _needle_print "     $export_cmd"
    _needle_print ""
    _needle_print "  2. Reload your shell config:"
    _needle_print ""
    _needle_print "     source $config_file"
    _needle_print ""
    _needle_print "  3. Or start a new shell session"
    _needle_print ""
}
