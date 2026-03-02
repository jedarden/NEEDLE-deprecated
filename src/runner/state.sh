#!/usr/bin/env bash
# NEEDLE Worker State Registry
# Track active workers for concurrency enforcement
#
# This module maintains a central registry of all running NEEDLE workers
# in ~/.needle/state/workers.json. It provides atomic operations using
# flock for concurrent access safety.

# Workers file path
NEEDLE_WORKERS_FILE="${NEEDLE_WORKERS_FILE:-$NEEDLE_HOME/$NEEDLE_STATE_DIR/workers.json}"
NEEDLE_WORKERS_LOCK="${NEEDLE_WORKERS_FILE}.lock"

# Initialize the workers registry file
# Creates an empty registry if it doesn't exist
# Usage: _needle_workers_init
_needle_workers_init() {
    local state_dir
    state_dir=$(dirname "$NEEDLE_WORKERS_FILE")

    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" || {
            _needle_error "Failed to create state directory: $state_dir"
            return 1
        }
    fi

    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo '{"workers":[]}' > "$NEEDLE_WORKERS_FILE" || {
            _needle_error "Failed to create workers registry: $NEEDLE_WORKERS_FILE"
            return 1
        }
        _needle_debug "Created workers registry: $NEEDLE_WORKERS_FILE"
    fi

    return 0
}

# Register a worker in the registry
# Usage: _needle_register_worker <session> <runner> <provider> <model> <identifier> <pid> <workspace>
# Example: _needle_register_worker "needle-claude-anthropic-sonnet-alpha" "claude" "anthropic" "sonnet" "alpha" $$ "/home/coder/project"
_needle_register_worker() {
    local session="$1"
    local runner="$2"
    local provider="$3"
    local model="$4"
    local identifier="$5"
    local pid="$6"
    local workspace="$7"

    # Validate required arguments
    if [[ -z "$session" ]] || [[ -z "$runner" ]] || [[ -z "$provider" ]] || \
       [[ -z "$model" ]] || [[ -z "$identifier" ]] || [[ -z "$pid" ]] || [[ -z "$workspace" ]]; then
        _needle_error "register_worker: missing required arguments"
        return 1
    fi

    # Ensure registry exists
    _needle_workers_init || return 1

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Use flock for atomic update
    (
        flock -x 200

        # Read current state
        local workers_json
        workers_json=$(cat "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo '{"workers":[]}')

        # Check if session already exists (prevent duplicates)
        local existing
        existing=$(echo "$workers_json" | jq -r --arg s "$session" '.workers[] | select(.session == $s) | .session' 2>/dev/null)
        if [[ -n "$existing" ]] && [[ "$existing" == "$session" ]]; then
            _needle_warn "Worker already registered: $session"
            flock -u 200
            return 0
        fi

        # Add new worker entry
        local new_entry
        new_entry=$(jq -n \
            --arg s "$session" \
            --arg r "$runner" \
            --arg p "$provider" \
            --arg m "$model" \
            --arg i "$identifier" \
            --argjson pid "$pid" \
            --arg w "$workspace" \
            --arg t "$timestamp" \
            '{
                session: $s,
                runner: $r,
                provider: $p,
                model: $m,
                identifier: $i,
                pid: $pid,
                workspace: $w,
                started: $t
            }')

        # Append to workers array
        workers_json=$(echo "$workers_json" | jq --argjson entry "$new_entry" '.workers += [$entry]')

        # Write back
        echo "$workers_json" > "$NEEDLE_WORKERS_FILE"

        _needle_debug "Registered worker: $session (PID: $pid)"

    ) 200>"$NEEDLE_WORKERS_LOCK"

    return $?
}

# Unregister a worker from the registry
# Usage: _needle_unregister_worker <session>
# Example: _needle_unregister_worker "needle-claude-anthropic-sonnet-alpha"
_needle_unregister_worker() {
    local session="$1"

    if [[ -z "$session" ]]; then
        _needle_error "unregister_worker: session is required"
        return 1
    fi

    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        _needle_debug "Workers registry does not exist, nothing to unregister"
        return 0
    fi

    # Use flock for atomic update
    (
        flock -x 200

        # Read current state
        local workers_json
        workers_json=$(cat "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo '{"workers":[]}')

        # Remove worker by session
        local original_count
        original_count=$(echo "$workers_json" | jq '.workers | length')
        workers_json=$(echo "$workers_json" | jq --arg s "$session" '.workers = [.workers[] | select(.session != $s)]')
        local new_count
        new_count=$(echo "$workers_json" | jq '.workers | length')

        # Write back
        echo "$workers_json" > "$NEEDLE_WORKERS_FILE"

        if [[ $original_count -gt $new_count ]]; then
            _needle_debug "Unregistered worker: $session"
        else
            _needle_debug "Worker not found in registry: $session"
        fi

    ) 200>"$NEEDLE_WORKERS_LOCK"

    return $?
}

# Count workers by agent (runner-provider-model combination)
# Usage: _needle_count_by_agent <agent>
# Example: _needle_count_by_agent "claude-anthropic-sonnet"
_needle_count_by_agent() {
    local agent="$1"

    if [[ -z "$agent" ]]; then
        echo "0"
        return 0
    fi

    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo "0"
        return 0
    fi

    # Parse agent into components
    local runner provider model
    IFS='-' read -r runner provider model <<< "$agent"

    # Count matching workers (with stale cleanup)
    _needle_cleanup_stale_workers

    local count
    count=$(jq -r \
        --arg r "$runner" \
        --arg p "$provider" \
        --arg m "$model" \
        '[.workers[] | select(.runner == $r and .provider == $p and .model == $m)] | length' \
        "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo "0")

    echo "$count"
}

# Count workers by provider
# Usage: _needle_count_by_provider <provider>
# Example: _needle_count_by_provider "anthropic"
_needle_count_by_provider() {
    local provider="$1"

    if [[ -z "$provider" ]]; then
        echo "0"
        return 0
    fi

    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo "0"
        return 0
    fi

    # Clean up stale workers first
    _needle_cleanup_stale_workers

    local count
    count=$(jq -r \
        --arg p "$provider" \
        '[.workers[] | select(.provider == $p)] | length' \
        "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo "0")

    echo "$count"
}

# Count total active workers
# Usage: _needle_count_all_workers
_needle_count_all_workers() {
    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo "0"
        return 0
    fi

    # Clean up stale workers first
    _needle_cleanup_stale_workers

    local count
    count=$(jq '.workers | length' "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo "0")

    echo "$count"
}

# Get workers matching criteria
# Usage: _needle_get_workers [--runner <runner>] [--provider <provider>] [--model <model>] [--identifier <id>] [--workspace <path>]
# Returns: JSON array of matching workers
_needle_get_workers() {
    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo "[]"
        return 0
    fi

    # Clean up stale workers first
    _needle_cleanup_stale_workers

    local filter=""
    local has_filter=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runner)
                filter="${filter}select(.runner == \"$2\") | "
                has_filter=true
                shift 2
                ;;
            --provider)
                filter="${filter}select(.provider == \"$2\") | "
                has_filter=true
                shift 2
                ;;
            --model)
                filter="${filter}select(.model == \"$2\") | "
                has_filter=true
                shift 2
                ;;
            --identifier)
                filter="${filter}select(.identifier == \"$2\") | "
                has_filter=true
                shift 2
                ;;
            --workspace)
                filter="${filter}select(.workspace == \"$2\") | "
                has_filter=true
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "$has_filter" == "true" ]]; then
        # Remove trailing " | " and build the full filter
        filter="${filter% | }"
        jq -r "[.workers[] | $filter]" "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo "[]"
    else
        jq '.workers' "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo "[]"
    fi
}

# Cleanup stale worker entries (PIDs that no longer exist)
# Usage: _needle_cleanup_stale_workers
_needle_cleanup_stale_workers() {
    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        return 0
    fi

    # Use flock for atomic update
    (
        flock -x 200

        # Read current state
        local workers_json
        workers_json=$(cat "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo '{"workers":[]}')

        local original_count
        original_count=$(echo "$workers_json" | jq '.workers | length')

        # If no workers, nothing to clean
        if [[ "$original_count" -eq 0 ]]; then
            return 0
        fi

        # Collect alive PIDs into a space-separated list
        local alive_pids=""
        local pids
        pids=$(echo "$workers_json" | jq -r '.workers[].pid' 2>/dev/null)

        for pid in $pids; do
            # Skip non-numeric PIDs
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                continue
            fi
            # Check if PID exists (kill -0 doesn't send signal, just checks)
            if kill -0 "$pid" 2>/dev/null; then
                alive_pids="$alive_pids $pid"
            fi
        done

        # Build a JSON array of alive PIDs for jq filtering (as numbers, not strings)
        local alive_pids_json
        if [[ -z "$(echo "$alive_pids" | tr -d ' ')" ]]; then
            alive_pids_json="[]"
        else
            # Convert space-separated list to JSON array of numbers
            alive_pids_json=$(echo "$alive_pids" | tr ' ' '\n' | grep -v '^$' | jq -R 'tonumber' | jq -s .)
        fi

        # Filter workers to only those with alive PIDs
        local cleaned_json
        cleaned_json=$(echo "$workers_json" | jq --argjson alive "$alive_pids_json" \
            '.workers = [.workers[] | select(.pid as $p | $alive | index($p))]')
        local new_count
        new_count=$(echo "$cleaned_json" | jq '.workers | length')

        # Write back if changed
        if [[ $original_count -ne $new_count ]]; then
            echo "$cleaned_json" > "$NEEDLE_WORKERS_FILE"
            _needle_debug "Cleaned up $((original_count - new_count)) stale worker(s)"
        fi

    ) 200>"$NEEDLE_WORKERS_LOCK"

    return $?
}

# Check if a specific session is registered
# Usage: _needle_is_worker_registered <session>
# Returns: 0 if registered, 1 if not
_needle_is_worker_registered() {
    local session="$1"

    if [[ -z "$session" ]] || [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        return 1
    fi

    local found
    found=$(jq -r --arg s "$session" '.workers[] | select(.session == $s) | .session' "$NEEDLE_WORKERS_FILE" 2>/dev/null)

    [[ -n "$found" ]] && [[ "$found" == "$session" ]]
}

# Get worker info by session
# Usage: _needle_get_worker <session>
# Returns: JSON object of worker or empty object if not found
_needle_get_worker() {
    local session="$1"

    if [[ -z "$session" ]] || [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo "{}"
        return 0
    fi

    jq -r --arg s "$session" '.workers[] | select(.session == $s)' "$NEEDLE_WORKERS_FILE" 2>/dev/null || echo "{}"
}

# Get all workers as JSON array
# Usage: _needle_list_workers
_needle_list_workers() {
    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        echo '{"workers":[]}'
        return 0
    fi

    # Clean up stale workers first
    _needle_cleanup_stale_workers

    cat "$NEEDLE_WORKERS_FILE"
}

# Clear all workers from registry (use with caution)
# Usage: _needle_clear_all_workers
_needle_clear_all_workers() {
    if [[ ! -f "$NEEDLE_WORKERS_FILE" ]]; then
        return 0
    fi

    # Use flock for atomic update
    (
        flock -x 200
        echo '{"workers":[]}' > "$NEEDLE_WORKERS_FILE"
        _needle_warn "Cleared all workers from registry"
    ) 200>"$NEEDLE_WORKERS_LOCK"

    return $?
}
