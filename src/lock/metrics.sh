#!/usr/bin/env bash
# NEEDLE File Collision Metrics
# Records and aggregates file collision metrics for effectiveness analysis
#
# Events are stored as JSONL in ~/.needle/state/metrics/collision_events.jsonl
# Aggregated metrics are computed on demand.
#
# Event types:
#   file.checkout.attempt   - A worker attempted to checkout a file
#   file.checkout.acquired  - Checkout succeeded (lock acquired)
#   file.checkout.blocked   - Checkout blocked by another bead (conflict prevented)
#   file.conflict.missed    - Conflict got through (post_exec catch)
#   file.conflict.prevented - Conflict was blocked by enforcement strategy

# ============================================================================
# Configuration
# ============================================================================

NEEDLE_METRICS_DIR="${NEEDLE_HOME:-$HOME/.needle}/state/metrics"
NEEDLE_COLLISION_EVENTS="${NEEDLE_METRICS_DIR}/collision_events.jsonl"

# ============================================================================
# Dependency Checks (Fallbacks if parent modules not loaded)
# ============================================================================

if ! declare -f _needle_command_exists &>/dev/null; then
    _needle_command_exists() { command -v "$1" &>/dev/null; }
fi

if ! declare -f _needle_json_escape &>/dev/null; then
    _needle_json_escape() {
        local str="$1"
        str="${str//\\/\\\\}"
        str="${str//\"/\\\"}"
        str="${str//$'\n'/\\n}"
        str="${str//$'\r'/\\r}"
        str="${str//$'\t'/\\t}"
        printf '%s' "$str"
    }
fi

# ============================================================================
# Internal Utilities
# ============================================================================

# Ensure the metrics directory exists
_needle_metrics_ensure_dir() {
    mkdir -p "$NEEDLE_METRICS_DIR" 2>/dev/null || true
}

# Get current ISO8601 timestamp
_needle_metrics_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z
}

# Parse a period string to seconds
# Usage: _needle_metrics_period_to_seconds <period>
# Supports: 1h, 24h, 7d, 30d, 1w, 60m, 3600s
_needle_metrics_period_to_seconds() {
    local period="${1:-24h}"

    case "$period" in
        *h) echo $(( ${period%h} * 3600 )) ;;
        *d) echo $(( ${period%d} * 86400 )) ;;
        *w) echo $(( ${period%w} * 604800 )) ;;
        *m) echo $(( ${period%m} * 60 )) ;;
        *s) echo "${period%s}" ;;
        *)  echo $(( period * 3600 )) ;;  # treat as hours
    esac
}

# ============================================================================
# Event Recording
# ============================================================================

# Record a collision metric event to the events JSONL file
# Usage: _needle_metrics_record_event <event_type> <bead> <path> [key=value ...]
# Example: _needle_metrics_record_event checkout.attempt nd-2ov /src/run.sh strategy=prompt
_needle_metrics_record_event() {
    local event_type="$1"
    local bead="$2"
    local path="$3"
    shift 3

    _needle_metrics_ensure_dir

    local ts ts_unix
    ts=$(_needle_metrics_timestamp)
    ts_unix=$(date +%s)

    # Build data object from remaining key=value args
    local json
    if _needle_command_exists jq; then
        local data="{}"
        data=$(echo "$data" | jq --arg bead "$bead" --arg path "$path" '. + {bead: $bead, path: $path}')

        while [[ $# -gt 0 ]]; do
            if [[ "$1" == *=* ]]; then
                local key="${1%%=*}"
                local value="${1#*=}"
                data=$(echo "$data" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
            fi
            shift
        done

        json=$(jq -nc \
            --arg ts "$ts" \
            --argjson ts_unix "$ts_unix" \
            --arg event "file.$event_type" \
            --argjson data "$data" \
            '{ts: $ts, ts_unix: $ts_unix, event: $event, data: $data}')
    else
        local escaped_bead escaped_path
        escaped_bead=$(_needle_json_escape "$bead")
        escaped_path=$(_needle_json_escape "$path")
        json="{\"ts\":\"$ts\",\"ts_unix\":$ts_unix,\"event\":\"file.$event_type\",\"data\":{\"bead\":\"$escaped_bead\",\"path\":\"$escaped_path\"}}"
    fi

    echo "$json" >> "$NEEDLE_COLLISION_EVENTS"
}

# ============================================================================
# Convenience Recording Functions
# ============================================================================

# Record a checkout attempt
# Usage: _needle_metrics_checkout_attempt <bead> <path> [strategy=...]
_needle_metrics_checkout_attempt() {
    _needle_metrics_record_event "checkout.attempt" "$1" "$2" "${@:3}"
}

# Record a successful checkout
# Usage: _needle_metrics_checkout_acquired <bead> <path>
_needle_metrics_checkout_acquired() {
    _needle_metrics_record_event "checkout.acquired" "$1" "$2" "${@:3}"
}

# Record a blocked checkout (conflict prevented)
# Usage: _needle_metrics_checkout_blocked <bead> <path> blocked_by=<bead>
_needle_metrics_checkout_blocked() {
    _needle_metrics_record_event "checkout.blocked" "$1" "$2" "${@:3}"
}

# Record a missed conflict (got through, caught by post_exec)
# Usage: _needle_metrics_conflict_missed <bead> <path> [blocked_by=...]
_needle_metrics_conflict_missed() {
    _needle_metrics_record_event "conflict.missed" "$1" "$2" "${@:3}"
}

# Record a prevented conflict (blocked by enforcement)
# Usage: _needle_metrics_conflict_prevented <bead> <path> [blocked_by=...]
_needle_metrics_conflict_prevented() {
    _needle_metrics_record_event "conflict.prevented" "$1" "$2" "${@:3}"
}

# ============================================================================
# Metrics Aggregation
# ============================================================================

# Aggregate collision events for a given period
# Usage: _needle_metrics_aggregate [period]
# Returns: JSON metrics object with totals, hot_files, conflict_pairs
_needle_metrics_aggregate() {
    local period="${1:-24h}"

    if ! _needle_command_exists jq; then
        echo "{\"error\":\"jq required for metrics aggregation\"}"
        return 1
    fi

    # Return empty metrics if no events file
    if [[ ! -f "$NEEDLE_COLLISION_EVENTS" ]]; then
        jq -nc \
            --arg period "$period" \
            '{
                period: $period,
                totals: {
                    checkout_attempts: 0,
                    checkouts_acquired: 0,
                    checkouts_blocked: 0,
                    conflicts_missed: 0,
                    conflicts_prevented: 0
                },
                by_strategy: {},
                hot_files: [],
                conflict_pairs: []
            }'
        return 0
    fi

    local period_seconds
    period_seconds=$(_needle_metrics_period_to_seconds "$period")
    local now
    now=$(date +%s)
    local cutoff=$(( now - period_seconds ))

    # Process events with jq
    jq -sc \
        --arg period "$period" \
        --argjson cutoff "$cutoff" \
        '
        # Filter to events within the period using ts_unix (preferred) or ts ISO string
        map(select(
            (.ts_unix != null and .ts_unix > $cutoff) or
            (.ts_unix == null and .ts != null)
        )) |

        # Compute aggregated metrics
        {
            period: $period,
            totals: {
                checkout_attempts:   (map(select(.event == "file.checkout.attempt"))   | length),
                checkouts_acquired:  (map(select(.event == "file.checkout.acquired"))  | length),
                checkouts_blocked:   (map(select(.event == "file.checkout.blocked"))   | length),
                conflicts_missed:    (map(select(.event == "file.conflict.missed"))    | length),
                conflicts_prevented: (map(select(.event == "file.conflict.prevented")) | length)
            },
            hot_files: (
                map(select(
                    .event == "file.checkout.blocked" or
                    .event == "file.conflict.missed" or
                    .event == "file.conflict.prevented"
                )) |
                group_by(.data.path) |
                map({path: .[0].data.path, conflicts: length}) |
                sort_by(-.conflicts) |
                .[0:50]
            ),
            conflict_pairs: (
                map(select(.event == "file.checkout.blocked")) |
                group_by([.data.bead, (.data.blocked_by // "unknown"), .data.path] | tostring) |
                map({
                    bead_a: .[0].data.bead,
                    bead_b: (.[0].data.blocked_by // "unknown"),
                    file: .[0].data.path,
                    count: length
                }) |
                sort_by(-.count) |
                .[0:10]
            )
        }
        ' "$NEEDLE_COLLISION_EVENTS"
}

# ============================================================================
# Metrics Maintenance
# ============================================================================

# Prune old events beyond a retention period
# Usage: _needle_metrics_prune [retention_period]
# Default retention: 30d
_needle_metrics_prune() {
    local retention="${1:-30d}"

    if [[ ! -f "$NEEDLE_COLLISION_EVENTS" ]]; then
        return 0
    fi

    if ! _needle_command_exists jq; then
        return 0
    fi

    local retention_seconds
    retention_seconds=$(_needle_metrics_period_to_seconds "$retention")
    local now
    now=$(date +%s)
    local cutoff=$(( now - retention_seconds ))

    local tmp_file
    tmp_file=$(mktemp)

    jq -rc \
        --argjson cutoff "$cutoff" \
        'select(
            (.ts_unix != null and .ts_unix > $cutoff) or
            (.ts_unix == null and .ts != null)
        )' "$NEEDLE_COLLISION_EVENTS" > "$tmp_file" 2>/dev/null || true

    mv "$tmp_file" "$NEEDLE_COLLISION_EVENTS"
}

# Get count of recorded events
# Usage: _needle_metrics_event_count
_needle_metrics_event_count() {
    if [[ ! -f "$NEEDLE_COLLISION_EVENTS" ]]; then
        echo 0
        return
    fi
    wc -l < "$NEEDLE_COLLISION_EVENTS" | tr -d ' '
}

# Clear all metrics data
# Usage: _needle_metrics_clear
_needle_metrics_clear() {
    rm -f "$NEEDLE_COLLISION_EVENTS"
}
