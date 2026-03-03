#!/usr/bin/env bash
# NEEDLE CLI Run Subcommand
# Execute a needle workflow or script
#
# This module implements CLI parsing and validation for the 'needle run' command.
# It parses command-line arguments, validates them, applies config defaults,
# and exports validated options for the worker execution phase.

# -----------------------------------------------------------------------------
# Run Command Help
# -----------------------------------------------------------------------------

_needle_run_help() {
    _needle_print "Start a worker to process beads from the queue

Starts a NEEDLE worker that processes beads (tasks) from the queue.
The worker will claim beads, execute them with the configured agent,
and mark them as complete.

USAGE:
    needle run [OPTIONS]

OPTIONS:
    -w, --workspace <PATH>   Workspace directory containing .beads/
                             [default: current directory]
    -a, --agent <NAME>       Agent to use (e.g., claude-anthropic-sonnet)
                             [default: from config or auto-detected]
    -c, --count <N>          Number of workers to start
                             [default: 1]
    --budget <USD>           Budget override for this run
                             [default: from config]
    --no-hooks               Skip hook execution for this run
    -d, --dry-run            Show what would be done without executing
    -f, --force              Skip concurrency limit checks
    --status                 Show concurrency status for agent
    -v, --verbose            Show detailed output
    -h, --help               Show this help message

EXAMPLES:
    # Start a single worker with default options
    needle run

    # Start a worker with explicit workspace and agent
    needle run --workspace=/path/to/project --agent=claude-anthropic-sonnet

    # Start multiple workers
    needle run -w /path/to/project -c 4

    # Run with budget override
    needle run --budget 10.00

    # Skip hooks for this run
    needle run --no-hooks

    # Preview what would be done
    needle run --dry-run

    # Check concurrency status before starting
    needle run --agent=claude-anthropic-sonnet --status

VALIDATION:
    The following validations are performed before starting:

    1. Workspace must exist and contain a .beads/ directory
    2. Agent must be installed and configured (or available in config)
    3. Count must be a positive integer (1 or greater)
    4. Budget must be a positive number (if specified)

CONFIGURATION DEFAULTS:
    Options not specified on the command line are loaded from:

    1. Workspace config (.needle.yaml in workspace root)
    2. Global config (~/.needle/config.yaml)
    3. Built-in defaults

CONCURRENCY LIMITS:
    NEEDLE enforces three levels of concurrency limits:

    1. Global limit     - Maximum total workers across all providers
    2. Provider limit   - Maximum workers per provider (e.g., anthropic)
    3. Model limit      - Maximum workers per agent (e.g., claude-anthropic-sonnet)

    Use --force to bypass these checks (not recommended for normal use).
"
}

# -----------------------------------------------------------------------------
# Validation Functions
# -----------------------------------------------------------------------------

# Validate workspace path exists and has .beads/ directory
# Usage: _needle_validate_workspace <path>
# Returns: 0 if valid, 1 if invalid
# Sets: NEEDLE_VALIDATED_WORKSPACE to absolute path
_needle_validate_workspace() {
    local workspace="$1"

    # If not specified, use current directory
    if [[ -z "$workspace" ]]; then
        workspace="$(pwd)"
    fi

    # Resolve to absolute path
    local abs_path
    abs_path="$(cd "$workspace" 2>/dev/null && pwd)" || {
        _needle_error "Workspace not found: $workspace"
        return 1
    }

    # Check if directory exists
    if [[ ! -d "$abs_path" ]]; then
        _needle_error "Workspace is not a directory: $abs_path"
        return 1
    fi

    # Check for .beads/ directory
    if [[ ! -d "$abs_path/.beads" ]]; then
        _needle_error "Workspace missing .beads/ directory: $abs_path"
        _needle_info "Run 'needle init' in the workspace to initialize it"
        return 1
    fi

    # Valid - store and export
    NEEDLE_VALIDATED_WORKSPACE="$abs_path"
    export NEEDLE_VALIDATED_WORKSPACE
    return 0
}

# Validate agent exists and is configured
# Usage: _needle_validate_agent <agent_name>
# Returns: 0 if valid, 1 if invalid
# Sets: NEEDLE_VALIDATED_AGENT to agent name
_needle_validate_agent() {
    local agent="$1"

    # If not specified, try to get default
    if [[ -z "$agent" ]]; then
        agent="$(_needle_get_default_agent 2>/dev/null)"
        if [[ -z "$agent" ]]; then
            _needle_error "No agent specified and no default agent found"
            _needle_info "Specify an agent with --agent or run 'needle agents scan' to detect available agents"
            return 1
        fi
        _needle_verbose "Using default agent: $agent"
    fi

    # Check if agent config exists
    if ! _needle_find_agent_config "$agent" &>/dev/null; then
        _needle_error "Agent not found: $agent"
        _needle_info "Run 'needle agents list' to see available agents"
        return 1
    fi

    # Validate agent configuration
    if ! _needle_load_agent "$agent" &>/dev/null; then
        _needle_error "Failed to load agent configuration: $agent"
        return 1
    fi

    # Valid - store and export
    NEEDLE_VALIDATED_AGENT="$agent"
    export NEEDLE_VALIDATED_AGENT
    return 0
}

# Validate worker count is positive integer
# Usage: _needle_validate_count <count>
# Returns: 0 if valid, 1 if invalid
# Sets: NEEDLE_VALIDATED_COUNT to count
_needle_validate_count() {
    local count="$1"

    # If not specified, use default
    if [[ -z "$count" ]]; then
        count="1"
    fi

    # Must be a positive integer
    if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
        _needle_error "Invalid worker count: $count (must be a positive integer)"
        return 1
    fi

    # Valid - store and export
    NEEDLE_VALIDATED_COUNT="$count"
    export NEEDLE_VALIDATED_COUNT
    return 0
}

# Validate budget is positive number
# Usage: _needle_validate_budget <budget>
# Returns: 0 if valid, 1 if invalid
# Sets: NEEDLE_VALIDATED_BUDGET to budget (or empty if not specified)
_needle_validate_budget() {
    local budget="$1"

    # Budget is optional
    if [[ -z "$budget" ]]; then
        NEEDLE_VALIDATED_BUDGET=""
        export NEEDLE_VALIDATED_BUDGET
        return 0
    fi

    # Must be a positive number (integer or decimal)
    # First check format, then check it's greater than 0
    if [[ ! "$budget" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        _needle_error "Invalid budget: $budget (must be a positive number)"
        return 1
    fi

    # Check that it's greater than 0
    # Handle both integer and decimal comparison
    local is_zero=false
    if [[ "$budget" == "0" ]] || [[ "$budget" == "0.0" ]] || [[ "$budget" =~ ^0\.0+$ ]]; then
        is_zero=true
    fi

    if [[ "$is_zero" == "true" ]]; then
        _needle_error "Invalid budget: $budget (must be greater than 0)"
        return 1
    fi

    # Valid - store and export
    NEEDLE_VALIDATED_BUDGET="$budget"
    export NEEDLE_VALIDATED_BUDGET
    return 0
}

# -----------------------------------------------------------------------------
# Config Defaults Application
# -----------------------------------------------------------------------------

# Apply configuration defaults for missing options
# Uses workspace config if available, falls back to global config
# Usage: _needle_apply_config_defaults
# Sets: NEEDLE_DEFAULT_AGENT, NEEDLE_DEFAULT_BUDGET
_needle_apply_config_defaults() {
    local workspace="${NEEDLE_VALIDATED_WORKSPACE:-$(pwd)}"

    # Get default agent from workspace config or global config
    if [[ -z "${NEEDLE_VALIDATED_AGENT:-}" ]]; then
        local config_agent
        config_agent=$(get_workspace_setting "$workspace" "runner.default_agent" "" 2>/dev/null)
        if [[ -n "$config_agent" ]]; then
            NEEDLE_DEFAULT_AGENT="$config_agent"
            export NEEDLE_DEFAULT_AGENT
            _needle_verbose "Config default agent: $config_agent"
        fi
    fi

    # Get default budget from config
    if [[ -z "${NEEDLE_VALIDATED_BUDGET:-}" ]]; then
        local config_budget
        config_budget=$(get_workspace_setting "$workspace" "effort.budget.daily_limit_usd" "" 2>/dev/null)
        if [[ -n "$config_budget" ]] && [[ "$config_budget" != "null" ]]; then
            NEEDLE_DEFAULT_BUDGET="$config_budget"
            export NEEDLE_DEFAULT_BUDGET
            _needle_verbose "Config default budget: \$$config_budget"
        fi
    fi

    # Get default worker count from config
    if [[ -z "${NEEDLE_VALIDATED_COUNT:-}" ]] || [[ "${NEEDLE_VALIDATED_COUNT:-}" == "1" ]]; then
        local config_count
        config_count=$(get_workspace_setting "$workspace" "runner.default_workers" "" 2>/dev/null)
        if [[ -n "$config_count" ]] && [[ "$config_count" != "null" ]]; then
            NEEDLE_DEFAULT_COUNT="$config_count"
            export NEEDLE_DEFAULT_COUNT
            _needle_verbose "Config default worker count: $config_count"
        fi
    fi
}

# -----------------------------------------------------------------------------
# CLI Parsing
# -----------------------------------------------------------------------------

# Parse and validate all run options
# Usage: _needle_run_parse_args "$@"
# Returns: 0 if valid, exits with error code if invalid
# Exports all NEEDLE_VALIDATED_* variables
_needle_run_parse_args() {
    local workspace=""
    local agent=""
    local count=""
    local budget=""
    local no_hooks=false
    local dry_run=false
    local force=false
    local show_status=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--workspace)
                if [[ -z "${2:-}" ]]; then
                    _needle_error "Option $1 requires an argument"
                    exit $NEEDLE_EXIT_USAGE
                fi
                workspace="$2"
                shift 2
                ;;
            --workspace=*)
                workspace="${1#*=}"
                shift
                ;;
            -a|--agent)
                if [[ -z "${2:-}" ]]; then
                    _needle_error "Option $1 requires an argument"
                    exit $NEEDLE_EXIT_USAGE
                fi
                agent="$2"
                shift 2
                ;;
            --agent=*)
                agent="${1#*=}"
                shift
                ;;
            -c|--count)
                if [[ -z "${2:-}" ]]; then
                    _needle_error "Option $1 requires an argument"
                    exit $NEEDLE_EXIT_USAGE
                fi
                count="$2"
                shift 2
                ;;
            --count=*)
                count="${1#*=}"
                shift
                ;;
            --budget)
                if [[ -z "${2:-}" ]]; then
                    _needle_error "Option $1 requires an argument"
                    exit $NEEDLE_EXIT_USAGE
                fi
                budget="$2"
                shift 2
                ;;
            --budget=*)
                budget="${1#*=}"
                shift
                ;;
            --no-hooks)
                no_hooks=true
                shift
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -f|--force)
                force=true
                shift
                ;;
            --status)
                show_status=true
                shift
                ;;
            -v|--verbose)
                NEEDLE_VERBOSE=true
                shift
                ;;
            -h|--help)
                _needle_run_help
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            -*)
                _needle_error "Unknown option: $1"
                _needle_run_help
                exit $NEEDLE_EXIT_USAGE
                ;;
            *)
                # Positional argument - treat as workspace if not set
                if [[ -z "$workspace" ]]; then
                    workspace="$1"
                else
                    _needle_error "Unexpected argument: $1"
                    exit $NEEDLE_EXIT_USAGE
                fi
                shift
                ;;
        esac
    done

    # Store raw parsed values for status display
    NEEDLE_RAW_WORKSPACE="$workspace"
    NEEDLE_RAW_AGENT="$agent"
    NEEDLE_RAW_COUNT="$count"
    NEEDLE_RAW_BUDGET="$budget"
    NEEDLE_RAW_NO_HOOKS="$no_hooks"
    NEEDLE_RAW_DRY_RUN="$dry_run"
    NEEDLE_RAW_FORCE="$force"
    NEEDLE_RAW_STATUS="$show_status"

    # Export flags
    NEEDLE_VALIDATED_NO_HOOKS="$no_hooks"
    NEEDLE_VALIDATED_DRY_RUN="$dry_run"
    NEEDLE_VALIDATED_FORCE="$force"
    NEEDLE_VALIDATED_STATUS="$show_status"
    export NEEDLE_VALIDATED_NO_HOOKS NEEDLE_VALIDATED_DRY_RUN NEEDLE_VALIDATED_FORCE NEEDLE_VALIDATED_STATUS

    # Validate workspace
    if ! _needle_validate_workspace "$workspace"; then
        exit $NEEDLE_EXIT_USAGE
    fi

    # Apply config defaults before agent validation (agent might be in config)
    _needle_apply_config_defaults

    # Use config default agent if not specified
    if [[ -z "$agent" ]] && [[ -n "${NEEDLE_DEFAULT_AGENT:-}" ]]; then
        agent="$NEEDLE_DEFAULT_AGENT"
    fi

    # Use config default count if not specified
    if [[ -z "$count" ]] && [[ -n "${NEEDLE_DEFAULT_COUNT:-}" ]]; then
        count="$NEEDLE_DEFAULT_COUNT"
    fi

    # Validate agent (unless showing status)
    if [[ "$show_status" != "true" ]]; then
        if ! _needle_validate_agent "$agent"; then
            exit $NEEDLE_EXIT_USAGE
        fi
    fi

    # Validate count
    if ! _needle_validate_count "$count"; then
        exit $NEEDLE_EXIT_USAGE
    fi

    # Validate budget
    if ! _needle_validate_budget "$budget"; then
        exit $NEEDLE_EXIT_USAGE
    fi

    return 0
}

# Export validated options as JSON for consumption by other tools
# Usage: _needle_export_validated_json
_needle_export_validated_json() {
    cat << EOF
{
    "workspace": "$(_needle_json_escape "${NEEDLE_VALIDATED_WORKSPACE:-}")",
    "agent": "$(_needle_json_escape "${NEEDLE_VALIDATED_AGENT:-}")",
    "count": ${NEEDLE_VALIDATED_COUNT:-1},
    "budget": "$(_needle_json_escape "${NEEDLE_VALIDATED_BUDGET:-}")",
    "no_hooks": ${NEEDLE_VALIDATED_NO_HOOKS:-false},
    "dry_run": ${NEEDLE_VALIDATED_DRY_RUN:-false},
    "force": ${NEEDLE_VALIDATED_FORCE:-false}
}
EOF
}

_needle_run() {
    # Parse and validate all arguments
    _needle_run_parse_args "$@"

    # Extract validated values (already exported)
    local workspace="$NEEDLE_VALIDATED_WORKSPACE"
    local agent="${NEEDLE_VALIDATED_AGENT:-}"
    local count="$NEEDLE_VALIDATED_COUNT"
    local budget="${NEEDLE_VALIDATED_BUDGET:-}"
    local no_hooks="$NEEDLE_VALIDATED_NO_HOOKS"
    local dry_run="$NEEDLE_VALIDATED_DRY_RUN"
    local force="$NEEDLE_VALIDATED_FORCE"
    local show_status="$NEEDLE_VALIDATED_STATUS"

    # Handle --status flag
    if [[ "$show_status" == "true" ]]; then
        local status_agent="${agent:-$(_needle_get_default_agent 2>/dev/null)}"
        if [[ -z "$status_agent" ]]; then
            _needle_error "Agent required for status check. Use: needle run --agent=<name> --status"
            exit $NEEDLE_EXIT_USAGE
        fi

        # Load agent to get provider
        local provider=""
        if _needle_load_agent "$status_agent" &>/dev/null; then
            provider="${NEEDLE_AGENT[provider]:-}"
        fi

        _needle_show_concurrency_status "$status_agent" "$provider"
        exit $NEEDLE_EXIT_SUCCESS
    fi

    # At this point, agent should be validated and loaded
    local provider="${NEEDLE_AGENT[provider]:-}"

    # Check concurrency limits (unless --force or --dry-run)
    if [[ "$force" != "true" ]] && [[ "$dry_run" != "true" ]]; then
        _needle_verbose "Checking concurrency limits..."

        if ! _needle_check_concurrency "$agent" "$provider" "$count"; then
            _needle_error "$NEEDLE_LIMIT_CHECK_MESSAGE"
            _needle_info "$NEEDLE_LIMIT_CHECK_DETAILS"
            _needle_print ""
            _needle_info "Use --force to bypass this check (not recommended)"
            _needle_info "Use --status to see current limit usage"
            exit $NEEDLE_EXIT_USAGE
        fi

        _needle_success "Concurrency check passed"
        _needle_verbose "$NEEDLE_LIMIT_CHECK_DETAILS"
    fi

    # Display run configuration
    _needle_header "Running: $agent"

    if [[ "$dry_run" == "true" ]]; then
        _needle_info "Dry run mode - no changes will be made"
    fi

    _needle_verbose "Workspace: $workspace"
    _needle_verbose "Agent: $agent"
    _needle_verbose "Workers: $count"
    [[ -n "$budget" ]] && _needle_verbose "Budget: \$$budget"
    [[ "$no_hooks" == "true" ]] && _needle_verbose "Hooks: disabled"
    _needle_verbose "Force: $force"

    # Start watchdog monitor (ensures it's running)
    # The watchdog monitors worker heartbeats and recovers stuck workers
    if [[ "$dry_run" != "true" ]]; then
        # Source watchdog monitor module
        if [[ -f "${NEEDLE_LIB_DIR:-}/watchdog/monitor.sh" ]]; then
            source "${NEEDLE_LIB_DIR:-}/watchdog/monitor.sh"
            _needle_ensure_watchdog
        else
            _needle_warn "Watchdog module not found, skipping watchdog startup"
        fi
    fi

    # TODO: Implement actual workflow execution (Phase 2: nd-qzu-2)
    _needle_warn "Workflow execution not yet implemented"
    _needle_info "This is a stub for the 'run' subcommand - CLI parsing is complete"

    # Show what would be done in dry-run mode
    if [[ "$dry_run" == "true" ]]; then
        _needle_print ""
        _needle_section "Dry Run Summary"
        _needle_table_row "Workspace" "$workspace"
        _needle_table_row "Agent" "$agent"
        [[ -n "$provider" ]] && _needle_table_row "Provider" "$provider"
        _needle_table_row "Workers to start" "$count"
        [[ -n "$budget" ]] && _needle_table_row "Budget" "\$$budget"
        [[ "$no_hooks" == "true" ]] && _needle_table_row "Hooks" "disabled"

        if [[ -n "$agent" ]] && [[ -n "$provider" ]]; then
            _needle_print ""
            local status_json
            status_json=$(_needle_get_concurrency_status "$agent" "$provider")
            local global_current global_limit
            global_current=$(echo "$status_json" | jq -r '.global.current')
            global_limit=$(echo "$status_json" | jq -r '.global.limit')
            _needle_table_row "Current global workers" "$global_current / $global_limit"
        fi

        _needle_print ""
        _needle_section "Validated Options (JSON)"
        _needle_export_validated_json
    fi

    exit $NEEDLE_EXIT_SUCCESS
}
