#!/usr/bin/env bash
# NEEDLE Claim Locking Module
# Per-workspace /dev/shm file locks to prevent thundering herd on bead claims
#
# Design:
# - Uses mkdir-based atomic locking (mkdir is atomic on all POSIX systems)
# - Per-workspace lock: /dev/shm/needle-claim/{workspace-hash}
# - Lock hold time: <50ms (one br list + one br update)
# - Stale lock timeout: 30s (handles crashed workers)
# - Jittered exponential backoff for contention
#
# What to lock:
# - Claim sequence (br list + br update --status in_progress)
# - br close (prevents double-close race)
#
# What NOT to lock:
# - br list (reads safe under WAL)
# - br show (read-only)
# - Operations on different workspaces (independent locks per workspace hash)

# ============================================================================
# Lock Directory Configuration
# ============================================================================

NEEDLE_CLAIM_LOCK_DIR="${NEEDLE_CLAIM_LOCK_DIR:-/dev/shm/needle-claim}"
NEEDLE_CLAIM_LOCK_TIMEOUT="${NEEDLE_CLAIM_LOCK_TIMEOUT:-30}"  # seconds
NEEDLE_CLAIM_LOCK_MAX_RETRIES="${NEEDLE_CLAIM_LOCK_MAX_RETRIES:-10}"
NEEDLE_CLAIM_LOCK_BASE_DELAY_MS="${NEEDLE_CLAIM_LOCK_BASE_DELAY_MS:-10}"  # 10ms base

# ============================================================================
# Dependency Checks (Fallbacks if parent modules not loaded)
# ============================================================================

if ! declare -f _needle_debug &>/dev/null; then
    _needle_debug() { [[ "${NEEDLE_VERBOSE:-}" == "true" ]] && echo "[DEBUG] $*" >&2; }
fi
if ! declare -f _needle_warn &>/dev/null; then
    _needle_warn() { echo "[WARN] $*" >&2; }
fi
if ! declare -f _needle_error &>/dev/null; then
    _needle_error() { echo "[ERROR] $*" >&2; }
fi
if ! declare -f _needle_telemetry_emit &>/dev/null; then
    _needle_telemetry_emit() { return 0; }
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Generate a short hash of a workspace path for lock naming
# Usage: _needle_claim_lock_hash <workspace_path>
# Returns: 12-character hex string
_needle_claim_lock_hash() {
    local workspace="$1"

    if [[ -z "$workspace" ]]; then
        echo "default"
        return 0
    fi

    # Resolve to absolute path and hash
    local abs_path
    abs_path=$(cd "$workspace" 2>/dev/null && pwd || echo "$workspace")

    # Use md5sum, take first 12 characters
    echo -n "$abs_path" | md5sum | cut -c1-12
}

# Get the lock directory path for a workspace
# Usage: _needle_claim_lock_dir <workspace>
# Returns: Full path to lock directory
_needle_claim_lock_dir() {
    local workspace="$1"
    local hash
    hash=$(_needle_claim_lock_hash "$workspace")
    echo "${NEEDLE_CLAIM_LOCK_DIR}/${hash}"
}

# Ensure the claim lock base directory exists
# Usage: _needle_claim_lock_ensure_base_dir
_needle_claim_lock_ensure_base_dir() {
    if [[ ! -d "$NEEDLE_CLAIM_LOCK_DIR" ]]; then
        mkdir -p "$NEEDLE_CLAIM_LOCK_DIR" 2>/dev/null || {
            _needle_error "Failed to create claim lock directory: $NEEDLE_CLAIM_LOCK_DIR"
            return 1
        }
    fi
}

# Sleep for a given number of milliseconds (using fractional seconds)
# Usage: _needle_sleep_ms <milliseconds>
_needle_sleep_ms() {
    local ms="${1:-10}"
    sleep "${ms}e-3"
}

# Calculate jittered exponential backoff delay in milliseconds
# Usage: _needle_claim_backoff_delay <attempt> [base_ms]
# Returns: delay in milliseconds
_needle_claim_backoff_delay() {
    local attempt="${1:-1}"
    local base_ms="${2:-$NEEDLE_CLAIM_LOCK_BASE_DELAY_MS}"

    # Exponential backoff: base * 2^attempt, capped at 500ms
    local max_ms=500
    local delay=$((base_ms * (2 ** (attempt - 1))))

    # Cap at max
    if [[ $delay -gt $max_ms ]]; then
        delay=$max_ms
    fi

    # Add jitter: random value between 0 and 50% of delay
    local jitter_max=$((delay / 2))
    if [[ $jitter_max -gt 0 ]]; then
        local jitter=$((RANDOM % jitter_max))
        delay=$((delay + jitter))
    fi

    echo "$delay"
}

# ============================================================================
# Core Lock Functions
# ============================================================================

# Check if a lock is stale (older than timeout)
# Usage: _needle_claim_lock_is_stale <lock_dir>
# Returns: 0 if stale, 1 if fresh or doesn't exist
_needle_claim_lock_is_stale() {
    local lock_dir="$1"

    if [[ ! -d "$lock_dir" ]]; then
        return 1  # Doesn't exist, not stale
    fi

    local now ts age
    now=$(date +%s)

    # Read timestamp from lock file
    local ts_file="${lock_dir}/timestamp"
    if [[ -f "$ts_file" ]]; then
        ts=$(cat "$ts_file" 2>/dev/null || echo "0")
        age=$((now - ts))

        if [[ $age -gt $NEEDLE_CLAIM_LOCK_TIMEOUT ]]; then
            return 0  # Stale
        fi
    else
        # No timestamp file - check directory mtime
        # This handles locks created by crashed processes
        local mtime
        mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || echo "0")
        age=$((now - mtime))

        if [[ $age -gt $NEEDLE_CLAIM_LOCK_TIMEOUT ]]; then
            return 0  # Stale
        fi
    fi

    return 1  # Fresh
}

# Acquire the claim lock for a workspace
# Uses mkdir for atomicity, with jittered exponential backoff
#
# Usage: _needle_acquire_claim_lock <workspace> [max_retries]
# Arguments:
#   workspace   - The workspace path to lock
#   max_retries - Maximum retries (default: NEEDLE_CLAIM_LOCK_MAX_RETRIES)
# Returns:
#   0 - Lock acquired successfully
#   1 - Failed to acquire lock after retries
# Environment:
#   Sets NEEDLE_CLAIM_LOCK_ACQUIRED=1 on success
#
# Example:
#   if _needle_acquire_claim_lock "/home/coder/NEEDLE"; then
#       # Do claim work
#       _needle_release_claim_lock "/home/coder/NEEDLE"
#   fi
_needle_acquire_claim_lock() {
    local workspace="$1"
    local max_retries="${2:-$NEEDLE_CLAIM_LOCK_MAX_RETRIES}"
    local lock_dir
    lock_dir=$(_needle_claim_lock_dir "$workspace")

    # Ensure base directory exists
    _needle_claim_lock_ensure_base_dir || return 1

    local attempt=1
    local acquired=false

    # Track for cleanup
    export NEEDLE_CLAIM_LOCK_ACQUIRED=0
    export NEEDLE_CLAIM_LOCK_DIR_HELD=""

    while [[ $attempt -le $max_retries ]]; do
        # Check for stale lock and clean it up
        if _needle_claim_lock_is_stale "$lock_dir"; then
            _needle_warn "Removing stale claim lock for workspace (older than ${NEEDLE_CLAIM_LOCK_TIMEOUT}s)"
            rm -rf "$lock_dir" 2>/dev/null || true

            _needle_telemetry_emit "claim.lock.stale_removed" "warn" \
                "workspace=$workspace"
        fi

        # Attempt atomic mkdir (returns 0 on success, non-zero if exists)
        if mkdir "$lock_dir" 2>/dev/null; then
            # Success! Write timestamp and metadata
            local ts
            ts=$(date +%s)
            echo "$ts" > "${lock_dir}/timestamp"
            echo "${NEEDLE_SESSION:-unknown}" > "${lock_dir}/worker"
            echo "$$" > "${lock_dir}/pid"

            export NEEDLE_CLAIM_LOCK_ACQUIRED=1
            export NEEDLE_CLAIM_LOCK_DIR_HELD="$lock_dir"

            _needle_debug "Acquired claim lock for workspace: $lock_dir (attempt $attempt)"

            _needle_telemetry_emit "claim.lock.acquired" "info" \
                "workspace=$workspace" \
                "attempt=$attempt"

            return 0
        fi

        # Lock is held by another worker - backoff and retry
        local delay_ms
        delay_ms=$(_needle_claim_backoff_delay "$attempt")

        _needle_debug "Claim lock contention, waiting ${delay_ms}ms (attempt $attempt/$max_retries)"

        _needle_sleep_ms "$delay_ms"
        attempt=$((attempt + 1))
    done

    # Failed to acquire lock after all retries
    _needle_warn "Failed to acquire claim lock after $max_retries attempts: $lock_dir"

    _needle_telemetry_emit "claim.lock.failed" "warn" \
        "workspace=$workspace" \
        "attempts=$max_retries"

    return 1
}

# Release the claim lock for a workspace
# Usage: _needle_release_claim_lock <workspace>
# Returns: 0 always (best-effort cleanup)
_needle_release_claim_lock() {
    local workspace="$1"
    local lock_dir
    lock_dir=$(_needle_claim_lock_dir "$workspace")

    if [[ -z "$lock_dir" ]] || [[ ! -d "$lock_dir" ]]; then
        return 0
    fi

    # Verify we're releasing our own lock (optional safety check)
    local lock_pid
    lock_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")

    if [[ -n "$lock_pid" ]] && [[ "$lock_pid" != "$$" ]]; then
        # Different PID holds the lock - be careful
        # This can happen after fork, so we still release
        _needle_debug "Releasing claim lock held by different PID: $lock_pid (current: $$)"
    fi

    # Calculate hold time for telemetry
    local hold_ms=0
    local ts_file="${lock_dir}/timestamp"
    if [[ -f "$ts_file" ]]; then
        local ts now
        ts=$(cat "$ts_file" 2>/dev/null || echo "0")
        now=$(date +%s)
        hold_ms=$(( (now - ts) * 1000 ))
    fi

    # Remove the lock directory
    rm -rf "$lock_dir" 2>/dev/null || true

    export NEEDLE_CLAIM_LOCK_ACQUIRED=0
    export NEEDLE_CLAIM_LOCK_DIR_HELD=""

    _needle_debug "Released claim lock for workspace: $lock_dir (held for ${hold_ms}ms)"

    if [[ $hold_ms -gt 0 ]]; then
        _needle_telemetry_emit "claim.lock.released" "info" \
            "workspace=$workspace" \
            "hold_ms=$hold_ms"
    fi

    return 0
}

# Release any held claim lock (convenience function)
# Usage: _needle_release_held_claim_lock
# Returns: 0 always
_needle_release_held_claim_lock() {
    if [[ "$NEEDLE_CLAIM_LOCK_ACQUIRED" == "1" ]] && [[ -n "$NEEDLE_CLAIM_LOCK_DIR_HELD" ]]; then
        rm -rf "$NEEDLE_CLAIM_LOCK_DIR_HELD" 2>/dev/null || true
        export NEEDLE_CLAIM_LOCK_ACQUIRED=0
        export NEEDLE_CLAIM_LOCK_DIR_HELD=""
        _needle_debug "Released held claim lock: $NEEDLE_CLAIM_LOCK_DIR_HELD"
    fi
    return 0
}

# ============================================================================
# Lock Wrapper for Critical Sections
# ============================================================================

# Execute a command while holding the claim lock
# Usage: _needle_with_claim_lock <workspace> -- <command...>
# Returns: Exit code of the command
#
# Example:
#   _needle_with_claim_lock "/home/coder/NEEDLE" -- br update "$bead_id" --claim
_needle_with_claim_lock() {
    local workspace=""
    local cmd=()
    local found_separator=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            found_separator=true
            shift
            cmd=("$@")
            break
        elif [[ -z "$workspace" ]]; then
            workspace="$1"
        else
            cmd+=("$1")
        fi
        shift
    done

    if [[ -z "$workspace" ]] || [[ ${#cmd[@]} -eq 0 ]]; then
        _needle_error "_needle_with_claim_lock: workspace and command required"
        return 1
    fi

    # Acquire lock
    if ! _needle_acquire_claim_lock "$workspace"; then
        return 1
    fi

    # Execute command
    "${cmd[@]}"
    local exit_code=$?

    # Release lock
    _needle_release_claim_lock "$workspace"

    return $exit_code
}

# ============================================================================
# Cleanup Functions
# ============================================================================

# Clean up stale locks across all workspaces
# Usage: _needle_cleanup_stale_claim_locks
# Returns: Number of locks cleaned
_needle_cleanup_stale_claim_locks() {
    local cleaned=0

    if [[ ! -d "$NEEDLE_CLAIM_LOCK_DIR" ]]; then
        return 0
    fi

    local lock_dirs
    lock_dirs=$(ls -d "${NEEDLE_CLAIM_LOCK_DIR}"/* 2>/dev/null || true)

    for lock_dir in $lock_dirs; do
        [[ -d "$lock_dir" ]] || continue

        if _needle_claim_lock_is_stale "$lock_dir"; then
            _needle_debug "Cleaning up stale claim lock: $lock_dir"
            rm -rf "$lock_dir" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        _needle_debug "Cleaned up $cleaned stale claim lock(s)"
    fi

    return $cleaned
}

# ============================================================================
# Direct Execution Support (for testing)
# ============================================================================

_NEEDLE_LOCKS_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        acquire)
            shift
            if _needle_acquire_claim_lock "$@"; then
                echo "Lock acquired: $NEEDLE_CLAIM_LOCK_DIR_HELD"
                # Hold lock for testing
                read -t 5 -p "Press Enter to release (auto-release in 5s)..." 2>/dev/null || true
                _needle_release_claim_lock "$@"
                echo "Lock released"
                exit 0
            else
                echo "Failed to acquire lock"
                exit 1
            fi
            ;;
        release)
            shift
            _needle_release_claim_lock "$@"
            echo "Lock released"
            ;;
        cleanup)
            _needle_cleanup_stale_claim_locks
            ;;
        hash)
            shift
            _needle_claim_lock_hash "$@"
            ;;
        -h|--help)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  acquire <workspace>   Acquire claim lock for workspace"
            echo "  release <workspace>   Release claim lock for workspace"
            echo "  cleanup               Clean up all stale claim locks"
            echo "  hash <workspace>      Show hash for workspace"
            echo ""
            echo "Environment:"
            echo "  NEEDLE_CLAIM_LOCK_TIMEOUT      Lock timeout in seconds (default: 30)"
            echo "  NEEDLE_CLAIM_LOCK_MAX_RETRIES  Max acquire retries (default: 10)"
            ;;
        *)
            echo "Unknown command: ${1:-}"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
fi
