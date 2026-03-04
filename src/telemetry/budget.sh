#!/usr/bin/env bash
# NEEDLE Budget Enforcement Module
# Enforce daily and per-bead budget limits with warnings
#
# This module handles:
# - Loading budget configuration (daily_limit_usd, warning_threshold, per_bead_limit_usd)
# - Checking daily spend against limits before each bead
# - Emitting budget.warning at configurable threshold (default 80%)
# - Emitting budget.exceeded and stopping worker at 100%
# - Per-bead limit check (abort if single bead exceeds limit)

# Source dependencies if not already loaded
if [[ -z "${_NEEDLE_OUTPUT_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/output.sh"
fi

# Source billing models module for enforcement strategy
if [[ -z "${_NEEDLE_BILLING_MODELS_LOADED:-}" ]]; then
    local billing_path
    billing_path="$(dirname "${BASH_SOURCE[0]}")/../lib/billing_models.sh"
    if [[ -f "$billing_path" ]]; then
        source "$billing_path"
    fi
fi

# Module version
_NEEDLE_BUDGET_VERSION="1.0.0"

# Budget state tracking
NEEDLE_BUDGET_WARNING_EMITTED="${NEEDLE_BUDGET_WARNING_EMITTED:-false}"

# -----------------------------------------------------------------------------
# Budget Configuration Loading
# -----------------------------------------------------------------------------

# Get budget configuration value
# Usage: _needle_budget_config <key> [default]
# Key format: daily_limit_usd, warning_threshold, per_bead_limit_usd
_needle_budget_config() {
    local key="$1"
    local default="${2:-}"

    # Source config module if not loaded
    if ! declare -f get_config &>/dev/null; then
        local config_path
        config_path="$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
        if [[ -f "$config_path" ]]; then
            source "$config_path"
        fi
    fi

    # Try to get from config
    if declare -f get_config &>/dev/null; then
        local value
        value=$(get_config "effort.budget.$key" "$default")
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    # Return default
    echo "$default"
}

# Get daily budget limit in USD
# Usage: get_daily_limit
# Returns: Daily limit (default: 50.0)
get_daily_limit() {
    _needle_budget_config "daily_limit_usd" "50.0"
}

# Get warning threshold (as ratio 0.0-1.0)
# Usage: get_warning_threshold
# Returns: Warning threshold (default: 0.8)
get_warning_threshold() {
    _needle_budget_config "warning_threshold" "0.8"
}

# Get per-bead limit in USD
# Usage: get_per_bead_limit
# Returns: Per-bead limit (default: 10.0)
get_per_bead_limit() {
    _needle_budget_config "per_bead_limit_usd" "10.0"
}

# Get timezone for daily reset
# Usage: get_budget_timezone
# Returns: Timezone (default: UTC)
get_budget_timezone() {
    _needle_budget_config "timezone" "UTC"
}

# -----------------------------------------------------------------------------
# Daily Spend Retrieval
# -----------------------------------------------------------------------------

# Get current daily spend
# Usage: get_daily_spend
# Returns: Total spend for today in USD
get_daily_spend() {
    # Source effort module if not loaded
    if ! declare -f _needle_get_total_spend &>/dev/null; then
        local effort_path
        effort_path="$(dirname "${BASH_SOURCE[0]}")/effort.sh"
        if [[ -f "$effort_path" ]]; then
            source "$effort_path"
        fi
    fi

    # Get today's total spend
    if declare -f _needle_get_total_spend &>/dev/null; then
        _needle_get_total_spend
    else
        echo "0"
    fi
}

# Get current budget utilization ratio
# Usage: get_budget_ratio
# Returns: Ratio of daily_spend / daily_limit (0.0 - 1.0+)
get_budget_ratio() {
    local daily_spend daily_limit

    daily_spend=$(get_daily_spend)
    daily_limit=$(get_daily_limit)

    # Handle zero/empty values
    if [[ -z "$daily_spend" || "$daily_spend" == "null" ]]; then
        daily_spend=0
    fi
    if [[ -z "$daily_limit" || "$daily_limit" == "null" || "$daily_limit" == "0" ]]; then
        echo "0"
        return 0
    fi

    # Calculate ratio
    if command -v bc &>/dev/null; then
        echo "scale=4; $daily_spend / $daily_limit" | bc 2>/dev/null || echo "0"
    elif command -v awk &>/dev/null; then
        awk "BEGIN {printf \"%.4f\", $daily_spend / $daily_limit}" 2>/dev/null || echo "0"
    else
        # Fallback: basic integer comparison
        echo "0"
    fi
}

# -----------------------------------------------------------------------------
# Budget Event Emission
# -----------------------------------------------------------------------------

# Emit budget.warning event
# Usage: _needle_event_budget_warning <daily_spend> <daily_limit> <threshold>
_needle_event_budget_warning() {
    local daily_spend="$1"
    local daily_limit="$2"
    local threshold="$3"

    # Source events module if not loaded
    if ! declare -f _needle_telemetry_emit &>/dev/null; then
        local events_path
        events_path="$(dirname "${BASH_SOURCE[0]}")/events.sh"
        if [[ -f "$events_path" ]]; then
            source "$events_path"
        fi
    fi

    # Emit the event
    if declare -f _needle_telemetry_emit &>/dev/null; then
        _needle_telemetry_emit "budget.warning" "warn" \
            "daily_spend_usd=$daily_spend" \
            "daily_limit_usd=$daily_limit" \
            "threshold=$threshold"
    fi
}

# Emit budget.exceeded event
# Usage: _needle_event_budget_exceeded <daily_spend> <daily_limit>
_needle_event_budget_exceeded() {
    local daily_spend="$1"
    local daily_limit="$2"

    # Source events module if not loaded
    if ! declare -f _needle_telemetry_emit &>/dev/null; then
        local events_path
        events_path="$(dirname "${BASH_SOURCE[0]}")/events.sh"
        if [[ -f "$events_path" ]]; then
            source "$events_path"
        fi
    fi

    # Emit the event
    if declare -f _needle_telemetry_emit &>/dev/null; then
        _needle_telemetry_emit "budget.exceeded" "error" \
            "daily_spend_usd=$daily_spend" \
            "daily_limit_usd=$daily_limit"
    fi
}

# Emit budget.per_bead_exceeded event
# Usage: _needle_event_budget_per_bead_exceeded <bead_cost> <bead_limit> <bead_id>
_needle_event_budget_per_bead_exceeded() {
    local bead_cost="$1"
    local bead_limit="$2"
    local bead_id="$3"

    # Source events module if not loaded
    if ! declare -f _needle_telemetry_emit &>/dev/null; then
        local events_path
        events_path="$(dirname "${BASH_SOURCE[0]}")/events.sh"
        if [[ -f "$events_path" ]]; then
            source "$events_path"
        fi
    fi

    # Emit the event
    if declare -f _needle_telemetry_emit &>/dev/null; then
        _needle_telemetry_emit "budget.per_bead_exceeded" "error" \
            "bead_cost_usd=$bead_cost" \
            "bead_limit_usd=$bead_limit" \
            "bead_id=$bead_id"
    fi
}

# -----------------------------------------------------------------------------
# Budget Check Functions
# -----------------------------------------------------------------------------

# Compare two floating point numbers
# Returns: 0 if $1 >= $2, 1 otherwise
_needle_float_compare_gte() {
    local a="$1"
    local b="$2"

    if command -v bc &>/dev/null; then
        local result
        result=$(echo "$a >= $b" | bc -l 2>/dev/null)
        [[ "$result" == "1" ]]
    elif command -v awk &>/dev/null; then
        awk "BEGIN {exit !($a >= $b)}"
    else
        # Fallback: integer comparison (less precise)
        local a_int b_int
        a_int=$(echo "$a" | sed 's/\..*//')
        b_int=$(echo "$b" | sed 's/\..*//')
        [[ ${a_int:-0} -ge ${b_int:-0} ]]
    fi
}

# Main budget check function
# Usage: check_budget
# Returns:
#   0 - Budget OK, continue working
#   1 - Warning threshold reached (continue but emit warning)
#   2 - Budget exceeded, stop worker
#
# Example:
#   case $(check_budget) in
#       0) echo "OK" ;;
#       1) echo "Warning" ;;
#       2) echo "Stop"; exit 2 ;;
#   esac
check_budget() {
    local daily_spend daily_limit warn_threshold ratio

    daily_spend=$(get_daily_spend)
    daily_limit=$(get_daily_limit)
    warn_threshold=$(get_warning_threshold)

    # Handle empty/null values
    if [[ -z "$daily_spend" || "$daily_spend" == "null" ]]; then
        daily_spend=0
    fi
    if [[ -z "$daily_limit" || "$daily_limit" == "null" ]]; then
        daily_limit=50
    fi
    if [[ -z "$warn_threshold" || "$warn_threshold" == "null" ]]; then
        warn_threshold=0.8
    fi

    # Calculate ratio
    ratio=$(get_budget_ratio)

    _needle_debug "Budget check: spend=\$$daily_spend, limit=\$$daily_limit, ratio=$ratio, threshold=$warn_threshold"

    # Check if budget exceeded using billing model enforcement strategy
    # If billing models module is loaded, use it to determine if we should stop
    if declare -f _needle_billing_should_stop_for_budget &>/dev/null; then
        if _needle_billing_should_stop_for_budget "$daily_spend" "$daily_limit"; then
            _needle_error "Budget exceeded: \$$daily_spend / \$$daily_limit"
            _needle_event_budget_exceeded "$daily_spend" "$daily_limit"
            return 2
        fi
    else
        # Fallback: strict enforcement (100%)
        if _needle_float_compare_gte "$ratio" "1"; then
            _needle_error "Budget exceeded: \$$daily_spend / \$$daily_limit (100%)"
            _needle_event_budget_exceeded "$daily_spend" "$daily_limit"
            return 2
        fi
    fi

    # Check if warning threshold reached
    if _needle_float_compare_gte "$ratio" "$warn_threshold"; then
        # Only emit warning once per session
        if [[ "$NEEDLE_BUDGET_WARNING_EMITTED" != "true" ]]; then
            local percentage
            percentage=$(awk "BEGIN {printf \"%.0f\", $warn_threshold * 100}")
            _needle_warn "Budget warning: \$$daily_spend / \$$daily_limit ($percentage% of limit)"
            _needle_event_budget_warning "$daily_spend" "$daily_limit" "$warn_threshold"
            NEEDLE_BUDGET_WARNING_EMITTED="true"
        fi
        return 1
    fi

    return 0
}

# Check if budget is OK (convenience wrapper)
# Usage: budget_ok
# Returns: 0 if OK, 1 if warning, 2 if exceeded
budget_ok() {
    check_budget
}

# Check if budget is exceeded
# Usage: budget_exceeded
# Returns: 0 if exceeded, 1 otherwise
budget_exceeded() {
    check_budget
    [[ $? -eq 2 ]]
}

# Check per-bead cost against limit
# Usage: check_bead_cost <cost> [bead_id]
# Returns:
#   0 - Cost within limit
#   2 - Cost exceeds per-bead limit
check_bead_cost() {
    local cost="${1:-0}"
    local bead_id="${2:-unknown}"
    local per_bead_limit

    per_bead_limit=$(get_per_bead_limit)

    # Handle empty/null values
    if [[ -z "$cost" || "$cost" == "null" ]]; then
        cost=0
    fi
    if [[ -z "$per_bead_limit" || "$per_bead_limit" == "null" ]]; then
        per_bead_limit=10
    fi

    _needle_debug "Per-bead check: cost=\$$cost, limit=\$$per_bead_limit"

    if _needle_float_compare_gte "$cost" "$per_bead_limit"; then
        _needle_error "Per-bead budget exceeded: \$$cost > \$$per_bead_limit for bead $bead_id"
        _needle_event_budget_per_bead_exceeded "$cost" "$per_bead_limit" "$bead_id"
        return 2
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Budget Summary and Display
# -----------------------------------------------------------------------------

# Get budget status as JSON
# Usage: get_budget_status
# Returns: JSON object with budget status
get_budget_status() {
    local daily_spend daily_limit warn_threshold per_bead_limit ratio percentage

    daily_spend=$(get_daily_spend)
    daily_limit=$(get_daily_limit)
    warn_threshold=$(get_warning_threshold)
    per_bead_limit=$(get_per_bead_limit)
    ratio=$(get_budget_ratio)

    # Calculate percentage
    if command -v awk &>/dev/null; then
        percentage=$(awk "BEGIN {printf \"%.1f\", $ratio * 100}" 2>/dev/null)
    else
        percentage="0.0"
    fi

    # Build JSON
    if command -v jq &>/dev/null; then
        jq -nc \
            --argjson daily_spend "$daily_spend" \
            --argjson daily_limit "$daily_limit" \
            --argjson warning_threshold "$warn_threshold" \
            --argjson per_bead_limit "$per_bead_limit" \
            --arg ratio "$ratio" \
            --arg percentage "$percentage" \
            '{
                daily_spend_usd: $daily_spend,
                daily_limit_usd: $daily_limit,
                warning_threshold: $warning_threshold,
                per_bead_limit_usd: $per_bead_limit,
                ratio: ($ratio | tonumber),
                percentage: ($percentage | tonumber),
                status: (if $daily_spend >= $daily_limit then "exceeded" elif $daily_spend >= ($daily_limit * $warning_threshold) then "warning" else "ok" end)
            }'
    else
        # Fallback: manual JSON
        local status="ok"
        if _needle_float_compare_gte "$daily_spend" "$daily_limit"; then
            status="exceeded"
        elif _needle_float_compare_gte "$ratio" "$warn_threshold"; then
            status="warning"
        fi

        printf '{"daily_spend_usd":%s,"daily_limit_usd":%s,"warning_threshold":%s,"per_bead_limit_usd":%s,"ratio":%s,"percentage":%s,"status":"%s"}' \
            "$daily_spend" "$daily_limit" "$warn_threshold" "$per_bead_limit" "$ratio" "$percentage" "$status"
    fi
}

# Display budget status
# Usage: show_budget_status
show_budget_status() {
    local daily_spend daily_limit warn_threshold per_bead_limit ratio

    daily_spend=$(get_daily_spend)
    daily_limit=$(get_daily_limit)
    warn_threshold=$(get_warning_threshold)
    per_bead_limit=$(get_per_bead_limit)
    ratio=$(get_budget_ratio)

    local percentage
    if command -v awk &>/dev/null; then
        percentage=$(awk "BEGIN {printf \"%.0f\", $ratio * 100}")
    else
        percentage="0"
    fi

    _needle_header "Budget Status"

    # Determine status color
    local status status_color
    if _needle_float_compare_gte "$ratio" "1"; then
        status="EXCEEDED"
        status_color="$NEEDLE_COLOR_RED"
    elif _needle_float_compare_gte "$ratio" "$warn_threshold"; then
        status="WARNING"
        status_color="$NEEDLE_COLOR_YELLOW"
    else
        status="OK"
        status_color="$NEEDLE_COLOR_GREEN"
    fi

    _needle_table_row "Daily Spend" "\$$daily_spend"
    _needle_table_row "Daily Limit" "\$$daily_limit"
    _needle_table_row "Usage" "$percentage%"
    _needle_table_row "Warning Threshold" "$(awk "BEGIN {printf \"%.0f\", $warn_threshold * 100}")%"
    _needle_table_row "Per-Bead Limit" "\$$per_bead_limit"

    _needle_section "Status"
    _needle_print_color "$status_color" "  $status"
}

# Reset warning state (call at start of new session)
# Usage: reset_budget_warning
reset_budget_warning() {
    NEEDLE_BUDGET_WARNING_EMITTED="false"
}

# -----------------------------------------------------------------------------
# Direct Execution Support (for testing)
# -----------------------------------------------------------------------------

# Allow running this module directly for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source dependencies for standalone testing
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/output.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/constants.sh"

    case "${1:-}" in
        check)
            check_budget
            case $? in
                0) echo "OK" ;;
                1) echo "WARNING" ;;
                2) echo "EXCEEDED" ;;
            esac
            ;;
        status)
            get_budget_status
            ;;
        show)
            show_budget_status
            ;;
        spend)
            get_daily_spend
            ;;
        limit)
            get_daily_limit
            ;;
        ratio)
            get_budget_ratio
            ;;
        check-bead)
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 check-bead <cost> [bead_id]"
                exit 1
            fi
            check_bead_cost "$2" "${3:-unknown}"
            case $? in
                0) echo "OK" ;;
                2) echo "EXCEEDED" ;;
            esac
            ;;
        reset)
            reset_budget_warning
            echo "Warning state reset"
            ;;
        -h|--help)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  check              Check budget status (OK/WARNING/EXCEEDED)"
            echo "  status             Get budget status as JSON"
            echo "  show               Display budget status"
            echo "  spend              Get daily spend"
            echo "  limit              Get daily limit"
            echo "  ratio              Get budget ratio"
            echo "  check-bead <cost>  Check per-bead cost"
            echo "  reset              Reset warning state"
            ;;
        *)
            echo "Unknown command: ${1:-}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
fi
