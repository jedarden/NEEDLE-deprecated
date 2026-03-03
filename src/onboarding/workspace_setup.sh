#!/usr/bin/env bash
# NEEDLE CLI Workspace Setup Module
# Interactive workspace selection and validation for onboarding

# -----------------------------------------------------------------------------
# Workspace Validation Functions
# -----------------------------------------------------------------------------

# Check if a directory is a valid workspace (has .beads/ directory)
# Usage: _needle_is_valid_workspace <path>
# Returns: 0 if valid, 1 otherwise
_needle_is_valid_workspace() {
    local path="$1"

    if [[ ! -d "$path" ]]; then
        return 1
    fi

    [[ -d "$path/.beads" ]]
}

# Check if workspace has optional .needle.yaml config
# Usage: _needle_has_workspace_config <path>
# Returns: 0 if config exists, 1 otherwise
_needle_has_workspace_config() {
    local path="$1"
    [[ -f "$path/.needle.yaml" ]]
}

# Check if br CLI is available
# Usage: _needle_has_br_cli
# Returns: 0 if available, 1 otherwise
_needle_has_br_cli() {
    command -v br &>/dev/null
}

# Validate br CLI can access the workspace
# Usage: _needle_validate_br_access <workspace_path>
# Returns: 0 if accessible, 1 otherwise
_needle_validate_br_access() {
    local workspace="$1"

    if ! _needle_has_br_cli; then
        return 1
    fi

    # Try to run br list on the workspace
    # Use BR_IGNORE_SPACE to avoid prompts
    local result
    result=$(BR_IGNORE_SPACE=1 br list --workspace "$workspace" 2>&1)
    local exit_code=$?

    # Exit code 0 or having output means success
    [[ $exit_code -eq 0 ]] || [[ -n "$result" ]]
}

# Initialize .beads directory in a workspace
# Usage: _needle_init_beads_dir <workspace_path>
# Returns: 0 on success, 1 on failure
_needle_init_beads_dir() {
    local workspace="$1"
    local beads_dir="$workspace/.beads"

    if [[ -d "$beads_dir" ]]; then
        _needle_verbose ".beads directory already exists"
        return 0
    fi

    _needle_verbose "Creating .beads directory: $beads_dir"
    mkdir -p "$beads_dir"

    # Create initial issues.jsonl if it doesn't exist
    if [[ ! -f "$beads_dir/issues.jsonl" ]]; then
        touch "$beads_dir/issues.jsonl"
        _needle_verbose "Created empty issues.jsonl"
    fi

    # Create .br_history for br CLI
    if [[ ! -d "$beads_dir/.br_history" ]]; then
        mkdir -p "$beads_dir/.br_history"
        _needle_verbose "Created .br_history directory"
    fi

    if [[ -d "$beads_dir" ]]; then
        _needle_success "Initialized .beads directory"
        return 0
    else
        _needle_error "Failed to create .beads directory"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Workspace Prompting Functions
# -----------------------------------------------------------------------------

# Prompt user for workspace path
# Usage: _needle_prompt_workspace [default_path]
# Returns: Validated workspace path (echo)
# Exit code: 0 on success, 1 on cancel/failure
_needle_prompt_workspace() {
    local default_path="${1:-$(pwd)}"
    local workspace=""
    local attempts=0
    local max_attempts=3

    while [[ $attempts -lt $max_attempts ]]; do
        if _needle_is_interactive; then
            _needle_print ""
            _needle_print_color "$NEEDLE_COLOR_CYAN" "? Enter workspace path"
            _needle_print -n "  [$default_path]: "
            read -r workspace
        else
            # Non-interactive mode: use default
            workspace=""
        fi

        # Use default if empty
        if [[ -z "$workspace" ]]; then
            workspace="$default_path"
        fi

        # Expand ~ and environment variables
        workspace="${workspace//\~/$HOME}"
        workspace=$(eval echo "$workspace")

        # Resolve to absolute path
        if [[ ! -d "$workspace" ]]; then
            _needle_error "Directory does not exist: $workspace"
            ((attempts++))
            continue
        fi

        # Get absolute path
        workspace=$(cd "$workspace" 2>/dev/null && pwd)

        if [[ -z "$workspace" ]]; then
            _needle_error "Failed to resolve path"
            ((attempts++))
            continue
        fi

        # Valid path obtained
        echo "$workspace"
        return 0
    done

    _needle_error "Maximum attempts reached"
    return 1
}

# Validate workspace for NEEDLE use
# Usage: _needle_validate_workspace <workspace_path> [--offer-init]
# Returns: 0 if valid, 1 otherwise
_needle_validate_workspace() {
    local workspace="$1"
    local offer_init=false

    # Parse options
    if [[ "${2:-}" == "--offer-init" ]]; then
        offer_init=true
    fi

    # Check path exists
    if [[ ! -d "$workspace" ]]; then
        _needle_error "Workspace directory does not exist: $workspace"
        return 1
    fi

    # Check for .beads directory
    if ! _needle_is_valid_workspace "$workspace"; then
        if [[ "$offer_init" == "true" ]]; then
            _needle_warn "No .beads directory found in: $workspace"

            if _needle_confirm "Initialize .beads directory here?" "y"; then
                if _needle_init_beads_dir "$workspace"; then
                    _needle_success "Workspace initialized"
                else
                    _needle_error "Failed to initialize workspace"
                    return 1
                fi
            else
                _needle_info "Workspace initialization cancelled"
                return 1
            fi
        else
            _needle_error "No .beads directory in workspace: $workspace"
            _needle_info "Run with --offer-init to create one"
            return 1
        fi
    fi

    # Check br CLI access (non-blocking warning)
    if _needle_has_br_cli; then
        if ! _needle_validate_br_access "$workspace"; then
            _needle_warn "br CLI may have issues accessing this workspace"
            _needle_verbose "br access validation failed for $workspace"
        fi
    else
        _needle_warn "br CLI not found - some features may be limited"
    fi

    # Check for optional .needle.yaml
    if _needle_has_workspace_config "$workspace"; then
        _needle_verbose "Found workspace config: $workspace/.needle.yaml"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Main Setup Function
# -----------------------------------------------------------------------------

# Interactive workspace setup for onboarding
# Usage: _needle_workspace_setup [--offer-init] [--default <path>]
# Sets: NEEDLE_WORKSPACE environment variable
# Returns: 0 on success, 1 on failure
_needle_workspace_setup() {
    local offer_init=false
    local default_path="$(pwd)"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offer-init)
                offer_init=true
                shift
                ;;
            --default)
                default_path="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    _needle_section "Workspace Setup"
    _needle_info "Select a workspace directory for managing beads"

    # Prompt for workspace
    local workspace
    if ! workspace=$(_needle_prompt_workspace "$default_path"); then
        return 1
    fi

    # Validate workspace
    local validate_args=()
    if [[ "$offer_init" == "true" ]]; then
        validate_args+=("--offer-init")
    fi

    if ! _needle_validate_workspace "$workspace" "${validate_args[@]}"; then
        return 1
    fi

    # Set environment variable
    export NEEDLE_WORKSPACE="$workspace"

    _needle_print ""
    _needle_success "Workspace configured: $workspace"

    return 0
}

# Get current workspace (from env or detect)
# Usage: _needle_get_workspace
# Returns: Workspace path or empty string
_needle_get_workspace() {
    # Check environment variable first
    if [[ -n "${NEEDLE_WORKSPACE:-}" ]]; then
        echo "$NEEDLE_WORKSPACE"
        return 0
    fi

    # Try to find workspace from current directory
    local current_dir="$(pwd)"

    # Walk up looking for .beads
    while [[ -n "$current_dir" ]] && [[ "$current_dir" != "/" ]]; do
        if [[ -d "$current_dir/.beads" ]]; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done

    # No workspace found
    return 1
}

# Display workspace status
# Usage: _needle_workspace_status [workspace_path]
_needle_workspace_status() {
    local workspace="${1:-$(pwd)}"
    local has_beads=false
    local has_config=false
    local has_br=false

    # Check .beads
    if [[ -d "$workspace/.beads" ]]; then
        has_beads=true
        local bead_count=0
        if [[ -f "$workspace/.beads/issues.jsonl" ]]; then
            bead_count=$(wc -l < "$workspace/.beads/issues.jsonl" 2>/dev/null || echo 0)
        fi
    fi

    # Check .needle.yaml
    if [[ -f "$workspace/.needle.yaml" ]]; then
        has_config=true
    fi

    # Check br CLI
    has_br=$(_needle_has_br_cli && echo "true" || echo "false")

    _needle_header "Workspace Status"
    _needle_table_row "Path" "$workspace"
    _needle_table_row ".beads/" "$([[ "$has_beads" == "true" ]] && echo "present ($bead_count beads)" || echo "missing")"
    _needle_table_row ".needle.yaml" "$([[ "$has_config" == "true" ]] && echo "present" || echo "missing")"
    _needle_table_row "br CLI" "$([[ "$has_br" == "true" ]] && echo "available" || echo "not found")"
}

# -----------------------------------------------------------------------------
# Non-Interactive Mode Support
# -----------------------------------------------------------------------------

# Setup workspace without prompts (for scripting)
# Usage: _needle_workspace_setup_silent <workspace_path> [--create]
# Returns: 0 on success, 1 on failure
_needle_workspace_setup_silent() {
    local workspace=""
    local create=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --create)
                create=true
                shift
                ;;
            *)
                workspace="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$workspace" ]]; then
        _needle_error "Workspace path required"
        return 1
    fi

    # Expand path
    workspace="${workspace//\~/$HOME}"
    workspace=$(eval echo "$workspace")

    # Check directory exists
    if [[ ! -d "$workspace" ]]; then
        _needle_error "Directory does not exist: $workspace"
        return 1
    fi

    # Get absolute path
    workspace=$(cd "$workspace" 2>/dev/null && pwd)

    # Create .beads if needed
    if [[ "$create" == "true" ]] && [[ ! -d "$workspace/.beads" ]]; then
        if ! _needle_init_beads_dir "$workspace"; then
            return 1
        fi
    fi

    # Validate
    if ! _needle_is_valid_workspace "$workspace"; then
        _needle_error "Invalid workspace (no .beads directory): $workspace"
        return 1
    fi

    # Set environment
    export NEEDLE_WORKSPACE="$workspace"

    echo "$workspace"
    return 0
}
