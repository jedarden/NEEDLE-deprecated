#!/usr/bin/env bash
#
# NEEDLE Bundle Script
# Combines all source files into a single distributable script
#
# Usage: ./scripts/bundle.sh [--minify] [--output PATH]
#
# Options:
#   --minify    Strip comments and blank lines
#   --output    Output file path (default: dist/needle)
#   --help      Show this help message
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULT_OUTPUT="$PROJECT_ROOT/dist/needle"

# Parse command line arguments
MINIFY=false
OUTPUT="$DEFAULT_OUTPUT"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --minify|-m)
            MINIFY=true
            shift
            ;;
        --output|-o)
            OUTPUT="$2"
            shift 2
            ;;
        --help|-h)
            sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

# Strip comments and blank lines for minification
_strip_comments() {
    local in_heredoc=false
    local heredoc_delim=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Track heredoc state
        if [[ "$line" =~ ^[[:space:]]*cat[[:space:]]*\<\<\'?([^\']+)\'?$ ]] || \
           [[ "$line" =~ \<\<\'?([^\']+)\'?$ ]]; then
            in_heredoc=true
            heredoc_delim="${BASH_REMATCH[1]}"
            echo "$line"
            continue
        fi

        if $in_heredoc; then
            echo "$line"
            if [[ "$line" == "$heredoc_delim" ]]; then
                in_heredoc=false
                heredoc_delim=""
            fi
            continue
        fi

        # Skip blank lines
        [[ -z "${line// }" ]] && continue

        # Skip comment-only lines (but keep shebang)
        if [[ "$line" =~ ^#[[:space:]]*(.*)$ ]] && [[ ! "$line" =~ ^#!/ ]]; then
            # Keep special comment markers for sections
            [[ "$line" =~ ^#[[:space:]]*--- ]] && echo "$line"
            continue
        fi

        # Keep the line
        echo "$line"
    done
}

# Process a single source file
_process_file() {
    local file="$1"
    local basename
    basename=$(basename "$file")

    echo "# --- $basename ---"
    if $MINIFY; then
        _strip_comments < "$file"
    else
        cat "$file"
    fi
    echo
}

# -----------------------------------------------------------------------------
# Main Bundle Logic
# -----------------------------------------------------------------------------

_bundle() {
    local version
    version=$(cat "$PROJECT_ROOT/VERSION" 2>/dev/null || echo "0.0.0")

    # Create output directory
    mkdir -p "$(dirname "$OUTPUT")"

    # Start building the bundled script
    {
        # Shebang and header
        echo '#!/usr/bin/env bash'
        echo "# NEEDLE v$version - Navigates Every Enqueued Deliverable, Logs Effort"
        echo "# Bundled on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "NEEDLE_VERSION='$version'"
        echo "NEEDLE_BUNDLED=true"
        echo

        # Global state (from bin/needle)
        echo "# -----------------------------------------------------------------------------"
        echo "# Global State"
        echo "# -----------------------------------------------------------------------------"
        echo 'NEEDLE_VERBOSE="${NEEDLE_VERBOSE:-false}"'
        echo 'NEEDLE_QUIET="${NEEDLE_QUIET:-false}"'
        echo 'NEEDLE_USE_COLOR="${NEEDLE_USE_COLOR:-true}"'
        echo

        # Embed libraries first (order matters for dependencies)
        echo "# -----------------------------------------------------------------------------"
        echo "# Library Modules"
        echo "# -----------------------------------------------------------------------------"
        for lib in constants output paths json config utils; do
            file="$PROJECT_ROOT/src/lib/${lib}.sh"
            if [[ -f "$file" ]]; then
                _process_file "$file"
            fi
        done

        # Embed agent modules
        echo "# -----------------------------------------------------------------------------"
        echo "# Agent Modules"
        echo "# -----------------------------------------------------------------------------"
        for file in "$PROJECT_ROOT/src/agent"/*.sh; do
            [[ -f "$file" ]] || continue
            _process_file "$file"
        done

        # Embed onboarding modules
        echo "# -----------------------------------------------------------------------------"
        echo "# Onboarding Modules"
        echo "# -----------------------------------------------------------------------------"
        for file in "$PROJECT_ROOT/src/onboarding"/*.sh; do
            [[ -f "$file" ]] || continue
            _process_file "$file"
        done

        # Embed CLI subcommands
        echo "# -----------------------------------------------------------------------------"
        echo "# CLI Subcommands"
        echo "# -----------------------------------------------------------------------------"
        for cmd in init run list status config logs version upgrade agents help; do
            file="$PROJECT_ROOT/src/cli/${cmd}.sh"
            if [[ -f "$file" ]]; then
                _process_file "$file"
            fi
        done

        # Embed watchdog modules
        echo "# -----------------------------------------------------------------------------"
        echo "# Watchdog Modules"
        echo "# -----------------------------------------------------------------------------"
        for file in "$PROJECT_ROOT/src/watchdog"/*.sh; do
            [[ -f "$file" ]] || continue
            _process_file "$file"
        done

        # Embed agent configurations
        echo "# -----------------------------------------------------------------------------"
        echo "# Embedded Agent Configurations"
        echo "# -----------------------------------------------------------------------------"
        echo 'declare -A EMBEDDED_AGENTS=()'
        for yaml in "$PROJECT_ROOT/config/agents"/*.yaml; do
            [[ -f "$yaml" ]] || continue
            name=$(basename "$yaml" .yaml)
            echo "# Embedded: $name"
            echo "EMBEDDED_AGENTS['$name']='\$(cat <<'EMBEDDED_${name^^}_EOF'"
            cat "$yaml"
            echo "EMBEDDED_${name^^}_EOF"
            echo ")'"
        done
        echo

        # Add the main entry point (adapted from bin/needle)
        echo "# -----------------------------------------------------------------------------"
        echo "# Main Entry Point"
        echo "# -----------------------------------------------------------------------------"
        cat << 'MAIN_EOF'

# Auto-Initialization Check
_needle_maybe_init() {
    # Commands that don't require initialization
    case "${1:-}" in
        init|version|help|--help|-h|--version|-V|-x|upgrade|agents)
            return 0
            ;;
    esac

    # Check if initialized
    if ! _needle_is_initialized; then
        _needle_warn "NEEDLE is not initialized"
        _needle_info "Redirecting to 'needle init'..."
        _needle_print ""
        _needle_init
        exit $?
    fi
}

# Global Option Parsing
_needle_parse_global_options() {
    local args=()
    local skip_next=false
    local has_subcommand=false

    # Check if a subcommand is present
    for arg in "$@"; do
        case "$arg" in
            init|run|list|ls|status|config|logs|version|upgrade|help|completion|agents)
                has_subcommand=true
                break
                ;;
            -*)
                # Skip options
                ;;
            *)
                break
                ;;
        esac
    done

    while [[ $# -gt 0 ]]; do
        if [[ "$skip_next" == "true" ]]; then
            skip_next=false
            shift
            continue
        fi

        case "$1" in
            -v|--verbose)
                NEEDLE_VERBOSE=true
                shift
                ;;
            -q|--quiet)
                NEEDLE_QUIET=true
                shift
                ;;
            --no-color)
                NEEDLE_USE_COLOR=false
                shift
                ;;
            --color)
                NEEDLE_USE_COLOR=true
                shift
                ;;
            -h|--help)
                if $has_subcommand; then
                    args+=("$1")
                    shift
                else
                    _needle_help
                    exit $NEEDLE_EXIT_SUCCESS
                fi
                ;;
            -V|--version)
                if $has_subcommand; then
                    args+=("$1")
                    shift
                else
                    echo "needle version $NEEDLE_VERSION"
                    exit $NEEDLE_EXIT_SUCCESS
                fi
                ;;
            -x)
                set -x
                shift
                ;;
            --)
                shift
                args+=("$@")
                break
                ;;
            -*)
                if [[ ${#1} -gt 2 ]] && [[ "$1" =~ ^-[a-zA-Z]+$ ]]; then
                    _needle_error "Unknown option: $1"
                    _needle_help
                    exit $NEEDLE_EXIT_USAGE
                fi
                args+=("$1")
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    NEEDLE_REMAINING_ARGS=("${args[@]}")
}

# Subcommand Routing
_needle_route_command() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        init)
            _needle_init "$@"
            ;;
        run)
            _needle_run "$@"
            ;;
        list|ls)
            _needle_list "$@"
            ;;
        status)
            _needle_status "$@"
            ;;
        config)
            _needle_config "$@"
            ;;
        logs)
            _needle_logs "$@"
            ;;
        version|-V)
            _needle_version "$@"
            ;;
        upgrade)
            _needle_upgrade "$@"
            ;;
        agents)
            _needle_agents "$@"
            ;;
        help|--help|-h)
            _needle_help "$@"
            ;;
        completion)
            _needle_completion "$@"
            ;;
        *)
            _needle_error "Unknown command: $command"
            _needle_print ""
            _needle_help
            exit $NEEDLE_EXIT_USAGE
            ;;
    esac
}

# Shell Completion
_needle_completion() {
    local shell="${1:-bash}"

    case "$shell" in
        bash)
            cat << 'COMPLETION'
# NEEDLE bash completion
_needle_completion() {
    local cur prev words cword
    _init_completion || return

    local commands="init run list status config logs version upgrade agents help"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    fi
}

complete -F _needle_completion needle
COMPLETION
            ;;
        zsh)
            cat << 'COMPLETION'
# NEEDLE zsh completion
#compdef needle

_needle() {
    local commands=(
        'init:Initialize NEEDLE configuration'
        'run:Execute a workflow or script'
        'list:List running workers'
        'status:Show worker health and statistics'
        'config:View and modify configuration'
        'logs:View or tail worker logs'
        'version:Display version information'
        'upgrade:Upgrade NEEDLE to latest version'
        'agents:Detect and manage coding CLI agents'
        'help:Show help information'
    )

    _arguments -C \
        '1: :->command' \
        '*:: :->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
    esac
}

_needle
COMPLETION
            ;;
        *)
            _needle_error "Unsupported shell: $shell"
            _needle_info "Supported shells: bash, zsh"
            exit $NEEDLE_EXIT_USAGE
            ;;
    esac
}

# Main function
needle_main() {
    # Initialize output system
    _needle_output_init

    # Parse global options
    _needle_parse_global_options "$@"

    # Check for initialization (unless running init/version/help)
    _needle_maybe_init "${NEEDLE_REMAINING_ARGS[@]:-}"

    # Route to subcommand
    _needle_route_command "${NEEDLE_REMAINING_ARGS[@]:-}"
}

# Run main with all arguments
needle_main "$@"
MAIN_EOF

    } > "$OUTPUT"

    # Make executable
    chmod +x "$OUTPUT"

    # Report success
    local size
    size=$(wc -c < "$OUTPUT" | tr -d ' ')
    local lines
    lines=$(wc -l < "$OUTPUT" | tr -d ' ')

    echo "✓ Bundle created: $OUTPUT"
    echo "  Size: $size bytes"
    echo "  Lines: $lines"
    if $MINIFY; then
        echo "  Minified: yes"
    else
        echo "  Minified: no"
    fi
}

# Run the bundler
_bundle
