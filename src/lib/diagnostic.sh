#!/usr/bin/env bash
# NEEDLE Diagnostic Logging Module
# Provides detailed logging for debugging worker starvation false positives
#
# This module provides diagnostic logging functions that:
# - Always log to a dedicated diagnostic file (when enabled)
# - Include full context (session, workspace, timestamps)
# - Help identify why workers report "no work" when beads exist
#
# Usage:
#   source "$NEEDLE_SRC/lib/diagnostic.sh"
#   _needle_diagnostic_init
#   _needle_diag "claim" "Attempting to claim bead" "bead_id=$bead_id"
#
# Enable diagnostic logging:
#   export NEEDLE_DIAGNOSTIC_ENABLED=true
#   export NEEDLE_DIAGNOSTIC_FILE=/path/to/diagnostic.log

# ============================================================================
# Diagnostic Configuration
# ============================================================================

# Default diagnostic file location
NEEDLE_DIAGNOSTIC_DIR="${NEEDLE_HOME:-$HOME/.needle}/${NEEDLE_STATE_DIR:-state}/diagnostics"
NEEDLE_DIAGNOSTIC_ENABLED="${NEEDLE_DIAGNOSTIC_ENABLED:-false}"
NEEDLE_DIAGNOSTIC_FILE="${NEEDLE_DIAGNOSTIC_FILE:-}"

# Track if diagnostic module is loaded
_NEEDLE_DIAGNOSTIC_LOADED=true

# ============================================================================
# Diagnostic Initialization
# ============================================================================

# Initialize diagnostic logging
# Creates diagnostic directory and file if needed
# Usage: _needle_diagnostic_init
_needle_diagnostic_init() {
    if [[ "$NEEDLE_DIAGNOSTIC_ENABLED" != "true" ]]; then
        return 0
    fi

    # Create diagnostic directory
    if [[ ! -d "$NEEDLE_DIAGNOSTIC_DIR" ]]; then
        mkdir -p "$NEEDLE_DIAGNOSTIC_DIR" 2>/dev/null || {
            echo "WARN: Could not create diagnostic directory: $NEEDLE_DIAGNOSTIC_DIR" >&2
            return 1
        }
    fi

    # Set default diagnostic file if not specified
    if [[ -z "$NEEDLE_DIAGNOSTIC_FILE" ]]; then
        NEEDLE_DIAGNOSTIC_FILE="$NEEDLE_DIAGNOSTIC_DIR/diagnostic.jsonl"
    fi

    # Create or append to diagnostic file
    if [[ ! -f "$NEEDLE_DIAGNOSTIC_FILE" ]]; then
        touch "$NEEDLE_DIAGNOSTIC_FILE" 2>/dev/null || {
            echo "WARN: Could not create diagnostic file: $NEEDLE_DIAGNOSTIC_FILE" >&2
            return 1
        }
    fi

    return 0
}

# ============================================================================
# Core Diagnostic Functions
# ============================================================================

# Log a diagnostic message
# This is the primary diagnostic logging function that always logs when diagnostics are enabled
#
# Usage: _needle_diagnostic <category> <message> [key=value ...]
# Arguments:
#   category - The diagnostic category (e.g., "claim", "strand", "select", "engine")
#   message  - Human-readable message
#   key=value - Additional context pairs
#
# Example:
#   _needle_diagnostic "claim" "Claim attempt failed" "bead_id=$bead_id" "exit_code=$exit_code"
_needle_diagnostic() {
    local category="$1"
    local message="$2"
    shift 2

    # Always log to debug output if verbose mode is on
    if [[ "${NEEDLE_VERBOSE:-false}" == "true" ]]; then
        local context=""
        for arg in "$@"; do
            context="$context $arg"
        done
        echo "[DIAG:$category] $message $context" >&2
    fi

    # Log to diagnostic file if enabled
    if [[ "$NEEDLE_DIAGNOSTIC_ENABLED" == "true" ]]; then
        _needle_diagnostic_init

        if [[ -n "$NEEDLE_DIAGNOSTIC_FILE" ]] && [[ -f "$NEEDLE_DIAGNOSTIC_FILE" ]]; then
            _needle_write_diagnostic "$category" "$message" "$@"
        fi
    fi
}

# Write diagnostic entry to JSONL file
# Usage: _needle_write_diagnostic <category> <message> [key=value ...]
_needle_write_diagnostic() {
    local category="$1"
    local message="$2"
    shift 2

    # Build JSON object
    local ts session
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z)
    session="${NEEDLE_SESSION:-unknown}"

    # Build data object from key=value pairs
    local data_pairs=()
    for arg in "$@"; do
        if [[ "$arg" == *=* ]]; then
            data_pairs+=("$arg")
        fi
    done

    # Use jq if available for proper JSON escaping
    if command -v jq &>/dev/null; then
        local data="{}"
        for pair in "${data_pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            data=$(echo "$data" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
        done

        jq -nc \
            --arg ts "$ts" \
            --arg category "$category" \
            --arg session "$session" \
            --arg message "$message" \
            --argjson data "$data" \
            '{ts: $ts, category: $category, session: $session, message: $message, data: $data}' \
            >> "$NEEDLE_DIAGNOSTIC_FILE" 2>/dev/null
    else
        # Fallback: manual JSON building
        local data_str="{"
        local first=true
        for pair in "${data_pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            if [[ "$first" == "true" ]]; then
                first=false
            else
                data_str+=","
            fi
            # Basic escaping
            value="${value//\\/\\\\}"
            value="${value//\"/\\\"}"
            data_str+="\"$key\":\"$value\""
        done
        data_str+="}"

        echo "{\"ts\":\"$ts\",\"category\":\"$category\",\"session\":\"$session\",\"message\":\"$message\",\"data\":$data_str}" \
            >> "$NEEDLE_DIAGNOSTIC_FILE" 2>/dev/null
    fi
}

# ============================================================================
# Category-Specific Diagnostic Helpers
# ============================================================================

# Log strand engine diagnostic
# Usage: _needle_diag_engine <message> [key=value ...]
_needle_diag_engine() {
    _needle_diagnostic "engine" "$@"
}

# Log strand-specific diagnostic
# Usage: _needle_diag_strand <strand_name> <message> [key=value ...]
_needle_diag_strand() {
    local strand="$1"
    shift
    _needle_diagnostic "strand:$strand" "$@"
}

# Log claim process diagnostic
# Usage: _needle_diag_claim <message> [key=value ...]
_needle_diag_claim() {
    _needle_diagnostic "claim" "$@"
}

# Log select process diagnostic
# Usage: _needle_diag_select <message> [key=value ...]
_needle_diag_select() {
    _needle_diagnostic "select" "$@"
}

# Log configuration diagnostic
# Usage: _needle_diag_config <message> [key=value ...]
_needle_diag_config() {
    _needle_diagnostic "config" "$@"
}

# Log workspace diagnostic
# Usage: _needle_diag_workspace <message> [key=value ...]
_needle_diag_workspace() {
    _needle_diagnostic "workspace" "$@"
}

# ============================================================================
# Diagnostic State Dump Functions
# ============================================================================

# Dump current diagnostic state for debugging
# Usage: _needle_diagnostic_dump_state
# Returns: JSON object with current state
_needle_diagnostic_dump_state() {
    local now
    now=$(date +%s)

    # Gather state information
    local state="{}"

    if command -v jq &>/dev/null; then
        state=$(jq -nc \
            --arg session "${NEEDLE_SESSION:-unknown}" \
            --arg workspace "${NEEDLE_WORKSPACE:-unknown}" \
            --arg verbose "${NEEDLE_VERBOSE:-false}" \
            --arg diagnostic_enabled "${NEEDLE_DIAGNOSTIC_ENABLED:-false}" \
            --arg home "${NEEDLE_HOME:-}" \
            --argjson now "$now" \
            '{
                session: $session,
                workspace: $workspace,
                verbose: $verbose,
                diagnostic_enabled: $diagnostic_enabled,
                needle_home: $home,
                timestamp: $now
            }')
    fi

    echo "$state"
}

# Log a comprehensive state snapshot
# Usage: _needle_diagnostic_snapshot <event_type> [key=value ...]
_needle_diagnostic_snapshot() {
    local event_type="$1"
    shift

    local state
    state=$(_needle_diagnostic_dump_state)

    # Add extra context
    for arg in "$@"; do
        if [[ "$arg" == *=* ]]; then
            local key="${arg%%=*}"
            local value="${arg#*=}"
            state=$(echo "$state" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}' 2>/dev/null || echo "$state")
        fi
    done

    _needle_diagnostic "snapshot" "$event_type" "state=$(echo "$state" | jq -c . 2>/dev/null || echo "$state")"
}

# ============================================================================
# Worker Starvation Detection Helpers
# ============================================================================

# Log potential starvation condition
# Usage: _needle_diag_starvation <reason> [key=value ...]
_needle_diag_starvation() {
    local reason="$1"
    shift

    _needle_diagnostic "starvation" "Potential worker starvation detected: $reason" \
        "reason=$reason" \
        "session=${NEEDLE_SESSION:-unknown}" \
        "workspace=${NEEDLE_WORKSPACE:-unknown}" \
        "$@"
}

# Log when no work is found across all strands
# Usage: _needle_diag_no_work <total_strands_checked> [key=value ...]
_needle_diag_no_work() {
    local strands_checked="$1"
    shift

    _needle_diagnostic "no_work" "No work found across all strands" \
        "strands_checked=$strands_checked" \
        "session=${NEEDLE_SESSION:-unknown}" \
        "$@"
}

# Log br CLI call for debugging
# Usage: _needle_diag_br_call <command> <exit_code> <output_preview> [key=value ...]
_needle_diag_br_call() {
    local cmd="$1"
    local exit_code="$2"
    local output="${3:0:200}"  # Truncate to 200 chars
    shift 3

    _needle_diagnostic "br_call" "br CLI call completed" \
        "command=$cmd" \
        "exit_code=$exit_code" \
        "output_preview=$output" \
        "$@"
}

# ============================================================================
# Diagnostic Summary Functions
# ============================================================================

# Get diagnostic statistics
# Usage: _needle_diagnostic_stats
# Returns: JSON object with diagnostic stats
_needle_diagnostic_stats() {
    if [[ ! -f "$NEEDLE_DIAGNOSTIC_FILE" ]]; then
        echo '{"entries":0,"enabled":false}'
        return 0
    fi

    local count
    count=$(wc -l < "$NEEDLE_DIAGNOSTIC_FILE" 2>/dev/null || echo "0")

    echo "{\"entries\":$count,\"enabled\":$NEEDLE_DIAGNOSTIC_ENABLED,\"file\":\"$NEEDLE_DIAGNOSTIC_FILE\"}"
}

# Clear diagnostic log
# Usage: _needle_diagnostic_clear
_needle_diagnostic_clear() {
    if [[ -f "$NEEDLE_DIAGNOSTIC_FILE" ]]; then
        > "$NEEDLE_DIAGNOSTIC_FILE"
    fi
}

# ============================================================================
# Direct Execution Support (for testing)
# ============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        init)
            NEEDLE_DIAGNOSTIC_ENABLED=true
            _needle_diagnostic_init
            echo "Diagnostic initialized: $NEEDLE_DIAGNOSTIC_FILE"
            ;;
        log)
            shift
            NEEDLE_DIAGNOSTIC_ENABLED=true
            _needle_diagnostic_init
            _needle_diagnostic "$@"
            ;;
        stats)
            _needle_diagnostic_stats | jq .
            ;;
        clear)
            _needle_diagnostic_clear
            echo "Diagnostic log cleared"
            ;;
        dump)
            _needle_diagnostic_dump_state | jq .
            ;;
        -h|--help)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  init              Initialize diagnostic logging"
            echo "  log <cat> <msg>   Log a diagnostic message"
            echo "  stats             Show diagnostic statistics"
            echo "  clear             Clear diagnostic log"
            echo "  dump              Dump current state"
            echo ""
            echo "Environment Variables:"
            echo "  NEEDLE_DIAGNOSTIC_ENABLED  Enable diagnostic logging (true/false)"
            echo "  NEEDLE_DIAGNOSTIC_FILE     Custom diagnostic file path"
            ;;
        *)
            echo "Unknown command: $1" >&2
            exit 1
            ;;
    esac
fi
