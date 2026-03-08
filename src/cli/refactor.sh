#!/usr/bin/env bash
# NEEDLE CLI Refactor Subcommand
# Suggest refactoring opportunities based on file contention metrics

_needle_refactor_help() {
    _needle_print "Suggest refactoring opportunities based on file contention metrics

USAGE:
    needle refactor <SUBCOMMAND> [OPTIONS]

SUBCOMMANDS:
    suggest    Analyze a file and suggest refactoring approaches

OPTIONS:
    -h, --help   Show this help message

EXAMPLES:
    needle refactor suggest src/cli/run.sh
    needle refactor suggest src/cli/run.sh --period=7d
    needle refactor suggest src/lib/output.sh -j
"
}

_needle_refactor() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        suggest)
            _needle_refactor_suggest "$@"
            ;;
        -h|--help|help|"")
            _needle_refactor_help
            exit $NEEDLE_EXIT_SUCCESS
            ;;
        *)
            _needle_error "Unknown subcommand: $subcommand"
            _needle_refactor_help
            exit $NEEDLE_EXIT_USAGE
            ;;
    esac
}

# ----------------------------------------------------------------------------
# needle refactor suggest <file> [--period=7d]
# ----------------------------------------------------------------------------

_needle_refactor_suggest() {
    local filepath=""
    local period="7d"
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period=*)
                period="${1#*=}"
                shift
                ;;
            --period)
                period="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                _needle_print "Analyze a file and suggest refactoring approaches

USAGE:
    needle refactor suggest <file> [OPTIONS]

OPTIONS:
    --period=<duration>  Lookback period for contention data (default: 7d)
    -j, --json           Output JSON
    -h, --help           Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            -*)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
            *)
                if [[ -z "$filepath" ]]; then
                    filepath="$1"
                else
                    _needle_error "Unexpected argument: $1"
                    exit $NEEDLE_EXIT_USAGE
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$filepath" ]]; then
        _needle_error "Usage: needle refactor suggest <file>"
        exit $NEEDLE_EXIT_USAGE
    fi

    # Resolve to absolute path
    if [[ "$filepath" != /* ]]; then
        filepath="$(pwd)/$filepath"
    fi

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    # Find contention data for this specific file
    local conflicts=0
    if _needle_command_exists jq; then
        conflicts=$(echo "$metrics" | jq --arg path "$filepath" \
            '(.hot_files[] | select(.path == $path) | .conflicts) // 0' 2>/dev/null || echo 0)
    fi

    local filename extension
    filename=$(basename "$filepath")
    extension="${filename##*.}"

    # Build suggestions based on file type and contention data
    local suggestions=()

    # Contention-based suggestion
    if (( conflicts > 0 )); then
        suggestions+=("This file has $conflicts recorded conflicts in the last $period — it is a hot spot")
    else
        suggestions+=("No recorded conflicts for this file in the last $period")
    fi

    # File-type specific suggestions
    case "$extension" in
        sh|bash)
            suggestions+=("Split into smaller modules — group related functions into dedicated files")
            suggestions+=("Extract utility functions to a shared lib/ module that rarely changes")
            suggestions+=("Create a dispatcher/facade script that delegates to specialized submodules")
            suggestions+=("Use source directives to compose from smaller, focused scripts")
            ;;
        py)
            suggestions+=("Split into a package directory with __init__.py")
            suggestions+=("Extract classes and functions to separate modules by responsibility")
            suggestions+=("Use dependency injection to reduce tight coupling between components")
            suggestions+=("Apply the single-responsibility principle — one class/module per concern")
            ;;
        js|ts)
            suggestions+=("Split into smaller ES modules with clear export boundaries")
            suggestions+=("Extract utility functions to a utils/ directory")
            suggestions+=("Consider lazy loading to reduce import dependencies")
            suggestions+=("Apply barrel exports (index.ts) to create stable public APIs")
            ;;
        jsx|tsx)
            suggestions+=("Break large components into smaller, focused sub-components")
            suggestions+=("Extract custom hooks to separate files")
            suggestions+=("Move business logic out of components into services/hooks")
            ;;
        json|yaml|yml)
            suggestions+=("Split configuration into domain-specific files (e.g., auth.yaml, db.yaml)")
            suggestions+=("Use includes or references to compose from smaller config files")
            suggestions+=("Consider environment-specific overrides rather than monolithic config")
            ;;
        go)
            suggestions+=("Split into multiple .go files within the same package by responsibility")
            suggestions+=("Extract to a sub-package if the functionality is independently useful")
            suggestions+=("Use interfaces to decouple callers from implementation details")
            ;;
        rs)
            suggestions+=("Split into submodules using mod declarations")
            suggestions+=("Extract traits and implementations to separate files")
            suggestions+=("Use the newtype pattern to reduce shared mutable state")
            ;;
        *)
            suggestions+=("Break into smaller, more focused files by responsibility")
            suggestions+=("Identify independent concerns that can be separated into their own files")
            suggestions+=("Apply the single-responsibility principle")
            ;;
    esac

    # High-contention specific advice
    if (( conflicts > 10 )); then
        suggestions+=("CRITICAL: Very high contention (${conflicts}x) — prioritize this refactoring to unblock workers")
    elif (( conflicts > 5 )); then
        suggestions+=("High contention (${conflicts}x) — refactoring this file will significantly reduce worker conflicts")
    fi

    # Check file size if it exists
    if [[ -f "$filepath" ]]; then
        local line_count
        line_count=$(wc -l < "$filepath" 2>/dev/null || echo 0)
        if (( line_count > 500 )); then
            suggestions+=("Large file ($line_count lines) — size alone is a good reason to split into modules")
        fi
    fi

    if [[ "$json_output" == "true" ]]; then
        printf '%s\n' "${suggestions[@]}" | jq -Rn \
            --arg path "$filepath" \
            --arg filename "$filename" \
            --argjson conflicts "$conflicts" \
            --arg period "$period" \
            '{
                file: $path,
                filename: $filename,
                conflicts: $conflicts,
                period: $period,
                suggestions: [inputs]
            }' 2>/dev/null
        return
    fi

    _needle_header "Refactoring Suggestions: $filename"
    _needle_print ""
    _needle_print "  File:   $filepath"
    _needle_print "  Period: ${period}"
    printf  "  %-7s %d conflicts\n" "Contention:" "$conflicts"
    _needle_print ""
    _needle_print "  Suggestions:"
    local i=1
    for suggestion in "${suggestions[@]}"; do
        _needle_print "    $i. $suggestion"
        ((i++))
    done
    _needle_print ""
}
