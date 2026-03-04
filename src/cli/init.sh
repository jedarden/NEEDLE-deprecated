#!/usr/bin/env bash
# NEEDLE CLI Init Subcommand
# Initialize NEEDLE configuration and directory structure

_needle_init_help() {
    _needle_print "Initialize NEEDLE with interactive onboarding

This command guides you through first-time setup:
  1. Installing dependencies (tmux, jq, yq, br)
  2. Detecting available coding CLI agents
  3. Configuring your first workspace
  4. Creating default configuration

USAGE:
    needle init [OPTIONS]

OPTIONS:
    -f, --force              Overwrite existing configuration
    -d, --defaults           Use all default values (non-interactive)
    -w, --workspace <PATH>   Set workspace path (default: current directory)
    -e, --editor <EDITOR>    Set default editor
    -t, --timezone <TZ>      Set timezone (default: UTC)
    -h, --help               Show this help message

EXAMPLES:
    # Interactive setup
    needle init

    # Non-interactive with all defaults
    needle init --defaults

    # Re-run setup, overwriting existing config
    needle init --force

    # Set editor, timezone, and workspace
    needle init --editor vim --timezone America/New_York --workspace ~/myproject
"
}

_needle_init() {
    local force=false
    local use_defaults=false
    local workspace=""
    local editor="${EDITOR:-vim}"
    local timezone="UTC"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                force=true
                shift
                ;;
            -d|--defaults)
                use_defaults=true
                shift
                ;;
            -w|--workspace)
                workspace="$2"
                shift 2
                ;;
            -e|--editor)
                editor="$2"
                shift 2
                ;;
            -t|--timezone)
                timezone="$2"
                shift 2
                ;;
            -h|--help)
                _needle_init_help
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                _needle_init_help
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    # Show welcome banner
    _needle_welcome_init

    # Check if already initialized
    if _needle_is_initialized && [[ "$force" != "true" ]]; then
        _needle_warn "NEEDLE is already initialized at $NEEDLE_HOME"
        _needle_info "Use --force to reinitialize"
        exit $NEEDLE_EXIT_SUCCESS
    fi

    _needle_header "Initializing NEEDLE"

    # -------------------------------------------------------------------------
    # Step 1: Create directory structure
    # -------------------------------------------------------------------------
    _needle_section "Directory Setup"

    # Create NEEDLE home directory
    if [[ ! -d "$NEEDLE_HOME" ]]; then
        _needle_verbose "Creating NEEDLE home: $NEEDLE_HOME"
        mkdir -p "$NEEDLE_HOME"
    fi

    # Create subdirectories using onboarding module (creates hooks dir too)
    _needle_create_config_dirs "$NEEDLE_HOME"

    # -------------------------------------------------------------------------
    # Step 2: Workspace setup
    # -------------------------------------------------------------------------
    _needle_section "Workspace Setup"

    local workspace_path="${workspace:-$(pwd)}"

    if [[ "$use_defaults" == "true" ]]; then
        # Non-interactive: use provided or current directory
        workspace_path=$(cd "$workspace_path" 2>/dev/null && pwd)

        # Validate workspace
        if ! _needle_is_valid_workspace "$workspace_path"; then
            _needle_warn "No .beads directory in workspace: $workspace_path"
            _needle_info "Initialize with: cd $workspace_path && br init"
            _needle_info "Continuing with NEEDLE configuration..."
        fi
    else
        # Interactive: prompt for workspace
        if ! _needle_workspace_setup --offer-init --default "$workspace_path"; then
            _needle_warn "Workspace setup incomplete, continuing with configuration"
        fi

        # Get the validated workspace (may have been set by workspace_setup)
        workspace_path="${NEEDLE_WORKSPACE:-$workspace_path}"
    fi

    # Store workspace for config generation
    export NEEDLE_CONFIG_WORKSPACE="$workspace_path"

    # -------------------------------------------------------------------------
    # Step 3: Create configuration with interactive prompts
    # -------------------------------------------------------------------------
    local config_args=()

    if [[ "$force" == "true" ]]; then
        config_args+=("--force")
    fi

    if [[ "$use_defaults" == "true" ]]; then
        config_args+=("--defaults")
    fi

    if ! _needle_onboarding_create_config "${config_args[@]}"; then
        _needle_error "Failed to create configuration"
        exit $NEEDLE_EXIT_CONFIG
    fi

    # Update config with editor and timezone
    # Note: NEEDLE_CONFIG_FILE is already the full path (set in constants.sh)
    local config_file="$NEEDLE_CONFIG_FILE"
    if [[ -f "$config_file" ]]; then
        _needle_config_set "editor" "\"$editor\""
        _needle_config_set "timezone" "\"$timezone\""

        # Add workspace to config if we have one
        if [[ -n "$NEEDLE_CONFIG_WORKSPACE" ]]; then
            # Check if workspaces section exists, if not create it
            if ! grep -q "^workspaces:" "$config_file" 2>/dev/null; then
                echo "" >> "$config_file"
                echo "workspaces:" >> "$config_file"
            fi
            # Add the workspace path
            echo "  - \"$NEEDLE_CONFIG_WORKSPACE\"" >> "$config_file"
        fi

        _needle_success "Updated configuration settings"
    fi

    # -------------------------------------------------------------------------
    # Step 4: Create README
    # -------------------------------------------------------------------------
    local readme="$NEEDLE_HOME/README.md"
    if [[ ! -f "$readme" ]] || [[ "$force" == "true" ]]; then
        cat > "$readme" << EOF
# NEEDLE Configuration

This directory contains your NEEDLE configuration and state.

## Structure

- \`config.yaml\` - Main configuration file
- \`state/\` - Runtime state files
- \`cache/\` - Cached data
- \`logs/\` - Log files
- \`hooks/\` - Hook scripts

## Configuration

Edit \`config.yaml\` to customize NEEDLE behavior.

## More Information

Run \`needle help\` for available commands.
EOF
        _needle_success "Created README"
    fi

    # -------------------------------------------------------------------------
    # Step 5: Show completion message
    # -------------------------------------------------------------------------
    _needle_print ""

    # Check workspace status
    if [[ -n "$NEEDLE_CONFIG_WORKSPACE" ]] && ! _needle_is_valid_workspace "$NEEDLE_CONFIG_WORKSPACE"; then
        _needle_warn "Your workspace does not have a .beads directory"
        _needle_print ""
        _needle_info "To initialize bead tracking in your workspace, run:"
        _needle_print "    cd \"$NEEDLE_CONFIG_WORKSPACE\" && br init"
        _needle_print ""
    fi

    # Show completion message with quick start guide
    _needle_welcome_complete
}
