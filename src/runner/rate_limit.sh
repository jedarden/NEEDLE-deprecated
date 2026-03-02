#!/usr/bin/env bash
# NEEDLE Rate Limiting Per Provider
# Implements requests-per-minute rate limiting with sliding window
#
# This module provides functions to track and enforce API rate limits
# per provider. It uses a sliding window approach to count requests
# in the last 60 seconds.
#
# State files are stored in: $NEEDLE_HOME/state/rate_limits/{provider}.json

# Rate limits directory
NEEDLE_RATE_LIMITS_DIR="${NEEDLE_HOME}/${NEEDLE_STATE_DIR}/rate_limits"

# -----------------------------------------------------------------------------
# Rate Limit Retrieval Functions
# -----------------------------------------------------------------------------

# Get the requests_per_minute limit for a provider
# Arguments:
#   $1 - Provider name (e.g., "anthropic", "openai")
# Returns: Integer limit (default: 60)
# Usage: _needle_get_rate_limit "anthropic"
_needle_get_rate_limit() {
    local provider="$1"
    local limit

    if [[ -z "$provider" ]]; then
        echo "60"
        return 0
    fi

    # Try provider-specific rate limit from config
    limit=$(get_config_int "limits.providers.$provider.requests_per_minute" "")

    if [[ -n "$limit" ]] && [[ "$limit" -gt 0 ]]; then
        echo "$limit"
        return 0
    fi

    # Fall back to default
    echo "60"
}

# Get the current request count for a provider in the sliding window
# Arguments:
#   $1 - Provider name
# Returns: Integer count of requests in last 60 seconds
# Usage: _needle_get_request_count "anthropic"
_needle_get_request_count() {
    local provider="$1"

    if [[ -z "$provider" ]]; then
        echo "0"
        return 0
    fi

    local state_file="$NEEDLE_RATE_LIMITS_DIR/${provider}.json"

    if [[ ! -f "$state_file" ]]; then
        echo "0"
        return 0
    fi

    local now epoch_ts
    now=$(date +%s)
    local cutoff=$((now - 60))

    # Count requests within the sliding window
    # Timestamps are stored as ISO 8601, convert to epoch for comparison
    local count
    count=$(jq --argjson cutoff "$cutoff" \
        '[.requests[] | select((.ts | fromdateiso8601) > $cutoff)] | length' \
        "$state_file" 2>/dev/null || echo "0")

    echo "${count:-0}"
}

# Get remaining requests for a provider
# Arguments:
#   $1 - Provider name
# Returns: Integer count of remaining requests
# Usage: _needle_get_remaining_requests "anthropic"
_needle_get_remaining_requests() {
    local provider="$1"

    local limit current
    limit=$(_needle_get_rate_limit "$provider")
    current=$(_needle_get_request_count "$provider")

    local remaining=$((limit - current))
    [[ $remaining -lt 0 ]] && remaining=0

    echo "$remaining"
}

# Get time until the oldest request expires (for retry-after)
# Arguments:
#   $1 - Provider name
# Returns: Seconds until oldest request exits the window (0 if under limit)
# Usage: _needle_get_retry_after "anthropic"
_needle_get_retry_after() {
    local provider="$1"

    local limit current
    limit=$(_needle_get_rate_limit "$provider")
    current=$(_needle_get_request_count "$provider")

    # If under limit, no wait needed
    if [[ $current -lt $limit ]]; then
        echo "0"
        return 0
    fi

    local state_file="$NEEDLE_RATE_LIMITS_DIR/${provider}.json"

    if [[ ! -f "$state_file" ]]; then
        echo "0"
        return 0
    fi

    local now
    now=$(date +%s)

    # Get the oldest request timestamp in the window
    local oldest_ts
    oldest_ts=$(jq -r --argjson now "$now" \
        '[.requests[] | select((.ts | fromdateiso8601) > ($now - 60))] | sort_by(.ts) | .[0].ts' \
        "$state_file" 2>/dev/null)

    if [[ -z "$oldest_ts" ]] || [[ "$oldest_ts" == "null" ]]; then
        echo "0"
        return 0
    fi

    # Calculate when oldest request exits the window (60 seconds after it was made)
    local oldest_epoch retry_at wait_seconds
    oldest_epoch=$(date -d "$oldest_ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$oldest_ts" +%s 2>/dev/null || echo "0")
    retry_at=$((oldest_epoch + 60))
    wait_seconds=$((retry_at - now))

    [[ $wait_seconds -lt 0 ]] && wait_seconds=0

    echo "$wait_seconds"
}

# -----------------------------------------------------------------------------
# Rate Limit State Management
# -----------------------------------------------------------------------------

# Initialize the rate limits directory
# Usage: _needle_rate_limits_init
_needle_rate_limits_init() {
    if [[ ! -d "$NEEDLE_RATE_LIMITS_DIR" ]]; then
        mkdir -p "$NEEDLE_RATE_LIMITS_DIR" || {
            _needle_error "Failed to create rate limits directory: $NEEDLE_RATE_LIMITS_DIR"
            return 1
        }
        _needle_debug "Created rate limits directory: $NEEDLE_RATE_LIMITS_DIR"
    fi
    return 0
}

# Check if rate limit would be exceeded for a provider
# Arguments:
#   $1 - Provider name
#   $2 - Number of additional requests (default: 1)
# Returns: 0 if within limit, 1 if would exceed
# Sets: NEEDLE_RATE_LIMIT_MESSAGE with details
# Usage: _needle_check_rate_limit "anthropic"
_needle_check_rate_limit() {
    local provider="$1"
    local additional="${2:-1}"

    if [[ -z "$provider" ]]; then
        return 0
    fi

    local limit current projected
    limit=$(_needle_get_rate_limit "$provider")
    current=$(_needle_get_request_count "$provider")
    projected=$((current + additional))

    if [[ $projected -gt $limit ]]; then
        local retry_after
        retry_after=$(_needle_get_retry_after "$provider")
        NEEDLE_RATE_LIMIT_EXCEEDED=true
        NEEDLE_RATE_LIMIT_MESSAGE="Rate limit exceeded for '$provider'"
        NEEDLE_RATE_LIMIT_DETAILS="Current: $current, Limit: $limit, Requested: +$additional"
        NEEDLE_RATE_LIMIT_RETRY_AFTER=$retry_after
        return 1
    fi

    NEEDLE_RATE_LIMIT_EXCEEDED=false
    NEEDLE_RATE_LIMIT_MESSAGE=""
    NEEDLE_RATE_LIMIT_DETAILS="Rate limit: $current/$limit ($provider)"
    NEEDLE_RATE_LIMIT_RETRY_AFTER=0
    return 0
}

# Record a request for rate limiting
# Arguments:
#   $1 - Provider name
# Returns: 0 on success, 1 on failure
# Usage: _needle_record_request "anthropic"
_needle_record_request() {
    local provider="$1"

    if [[ -z "$provider" ]]; then
        return 1
    fi

    _needle_rate_limits_init || return 1

    local state_file="$NEEDLE_RATE_LIMITS_DIR/${provider}.json"
    local lock_file="${state_file}.lock"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Use flock for atomic update
    (
        flock -x 200

        local now cutoff
        now=$(date +%s)
        cutoff=$((now - 60))

        if [[ -f "$state_file" ]]; then
            # Read existing, filter old entries, add new one
            local updated_json
            updated_json=$(jq --arg ts "$ts" --argjson cutoff "$cutoff" \
                '.provider = "'"$provider"'" |
                 .requests = [.requests[] | select((.ts | fromdateiso8601) > $cutoff)] + [{"ts": $ts}]' \
                "$state_file" 2>/dev/null)

            if [[ -n "$updated_json" ]]; then
                echo "$updated_json" > "$state_file"
            else
                # Fallback: create fresh if jq fails
                echo "{\"provider\": \"$provider\", \"requests\": [{\"ts\": \"$ts\"}]}" > "$state_file"
            fi
        else
            # Create new state file
            echo "{\"provider\": \"$provider\", \"requests\": [{\"ts\": \"$ts\"}]}" > "$state_file"
        fi

        _needle_debug "Recorded request for $provider at $ts"

    ) 200>"$lock_file"

    return $?
}

# Clean up old requests from rate limit state files
# This is called automatically but can also be invoked manually
# Arguments:
#   $1 - Provider name (optional, cleans all if not specified)
# Usage: _needle_cleanup_rate_limits "anthropic"
_needle_cleanup_rate_limits() {
    local provider="${1:-}"

    if [[ ! -d "$NEEDLE_RATE_LIMITS_DIR" ]]; then
        return 0
    fi

    local now cutoff
    now=$(date +%s)
    cutoff=$((now - 60))

    if [[ -n "$provider" ]]; then
        # Clean specific provider
        local state_file="$NEEDLE_RATE_LIMITS_DIR/${provider}.json"
        if [[ -f "$state_file" ]]; then
            local lock_file="${state_file}.lock"
            (
                flock -x 200
                jq --argjson cutoff "$cutoff" \
                    '.requests = [.requests[] | select((.ts | fromdateiso8601) > $cutoff)]' \
                    "$state_file" > "${state_file}.tmp" 2>/dev/null && \
                mv "${state_file}.tmp" "$state_file"
            ) 200>"$lock_file"
        fi
    else
        # Clean all providers
        for state_file in "$NEEDLE_RATE_LIMITS_DIR"/*.json; do
            [[ -f "$state_file" ]] || continue
            local lock_file="${state_file}.lock"
            (
                flock -x 200
                jq --argjson cutoff "$cutoff" \
                    '.requests = [.requests[] | select((.ts | fromdateiso8601) > $cutoff)]' \
                    "$state_file" > "${state_file}.tmp" 2>/dev/null && \
                mv "${state_file}.tmp" "$state_file"
            ) 200>"$lock_file"
        done
    fi
}

# Clear all rate limit state (use for testing or reset)
# Arguments:
#   $1 - Provider name (optional, clears all if not specified)
# Usage: _needle_clear_rate_limits "anthropic"
_needle_clear_rate_limits() {
    local provider="${1:-}"

    if [[ -n "$provider" ]]; then
        local state_file="$NEEDLE_RATE_LIMITS_DIR/${provider}.json"
        rm -f "$state_file" "${state_file}.lock"
        _needle_debug "Cleared rate limits for $provider"
    else
        rm -rf "$NEEDLE_RATE_LIMITS_DIR"
        _needle_debug "Cleared all rate limits"
    fi
}

# -----------------------------------------------------------------------------
# Convenience Wrapper Functions
# -----------------------------------------------------------------------------

# Check rate limit and wait if necessary (with retry)
# Arguments:
#   $1 - Provider name
#   $2 - Max wait seconds (default: 60)
# Returns: 0 if can proceed, 1 if timeout exceeded
# Usage: _needle_wait_for_rate_limit "anthropic" 30
_needle_wait_for_rate_limit() {
    local provider="$1"
    local max_wait="${2:-60}"
    local waited=0

    while ! _needle_check_rate_limit "$provider"; do
        if [[ $waited -ge $max_wait ]]; then
            _needle_warn "Rate limit wait timeout exceeded for $provider"
            return 1
        fi

        local retry_after="${NEEDLE_RATE_LIMIT_RETRY_AFTER:-5}"
        [[ $retry_after -gt 10 ]] && retry_after=10  # Cap sleep time

        _needle_debug "Rate limit hit for $provider, waiting ${retry_after}s..."
        sleep "$retry_after"
        waited=$((waited + retry_after))
    done

    return 0
}

# Enforce rate limit (check, wait, record)
# This is the main entry point for rate limiting
# Arguments:
#   $1 - Provider name
#   $2 - Max wait seconds (default: 60)
# Returns: 0 on success, 1 on failure
# Usage: _needle_enforce_rate_limit "anthropic"
_needle_enforce_rate_limit() {
    local provider="$1"
    local max_wait="${2:-60}"

    # Wait for rate limit if needed
    if ! _needle_wait_for_rate_limit "$provider" "$max_wait"; then
        _needle_error "$NEEDLE_RATE_LIMIT_MESSAGE"
        _needle_info "$NEEDLE_RATE_LIMIT_DETAILS"
        return 1
    fi

    # Record the request
    _needle_record_request "$provider"
    return $?
}

# Get rate limit status as JSON
# Arguments:
#   $1 - Provider name
# Returns: JSON object with rate limit info
# Usage: _needle_get_rate_limit_status "anthropic"
_needle_get_rate_limit_status() {
    local provider="$1"

    if [[ -z "$provider" ]]; then
        echo '{"error": "provider required"}'
        return 1
    fi

    local limit current remaining retry_after
    limit=$(_needle_get_rate_limit "$provider")
    current=$(_needle_get_request_count "$provider")
    remaining=$(_needle_get_remaining_requests "$provider")
    retry_after=$(_needle_get_retry_after "$provider")

    cat <<EOF
{
  "provider": "$provider",
  "limit": $limit,
  "current": $current,
  "remaining": $remaining,
  "retry_after": $retry_after,
  "window_seconds": 60
}
EOF
}

# Display rate limit status in human-readable format
# Arguments:
#   $1 - Provider name
# Usage: _needle_show_rate_limit_status "anthropic"
_needle_show_rate_limit_status() {
    local provider="$1"

    if [[ -z "$provider" ]]; then
        _needle_error "Provider name required"
        return 1
    fi

    local limit current remaining pct status
    limit=$(_needle_get_rate_limit "$provider")
    current=$(_needle_get_request_count "$provider")
    remaining=$(_needle_get_remaining_requests "$provider")

    if [[ $limit -gt 0 ]]; then
        pct=$((current * 100 / limit))
    else
        pct=0
    fi

    status="OK"
    [[ $pct -ge 80 ]] && status="WARNING"
    [[ $pct -ge 100 ]] && status="LIMIT"

    _needle_section "Rate Limit Status: $provider"
    _needle_table_row "Current" "$current / $limit requests/min ($pct%)"
    _needle_table_row "Remaining" "$remaining"
    _needle_table_row "Status" "$status"

    if [[ $pct -ge 100 ]]; then
        local retry_after
        retry_after=$(_needle_get_retry_after "$provider")
        _needle_table_row "Retry After" "${retry_after}s"
    fi
}
