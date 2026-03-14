#!/usr/bin/env bash
# NEEDLE File Checkout System
# Manages file collision avoidance using /dev/shm locks
#
# Design Principles:
# 1. No blocking - Workers never wait for file locks; conflicts become dependencies
# 2. Self-healing - Closing a bead releases all its file claims automatically
# 3. Cross-workspace - All NEEDLE workers share the same lock namespace
# 4. Volatile - Locks live in /dev/shm (RAM), no stale locks after reboot
#
# Lock Structure:
#   /dev/shm/needle/{bead-id}-{path-uuid}
#   Where path-uuid is the first 8 characters of MD5 hash of the absolute file path
#
# Lock file contents (JSON):
#   {
#     "bead": "nd-2ov",
#     "worker": "claude-code-glm-5-alpha",
#     "path": "/home/coder/NEEDLE/src/cli/run.sh",
#     "type": "write",
#     "ts": 1709337600,
#     "workspace": "/home/coder/NEEDLE"
#   }

# ============================================================================
# Lock Directory Configuration
# ============================================================================

NEEDLE_LOCK_DIR="${NEEDLE_LOCK_DIR:-/dev/shm/needle}"

# ============================================================================
# Dependency Checks (Fallbacks if parent modules not loaded)
# ============================================================================

# Ensure logging functions are available
if ! declare -f _needle_info &>/dev/null; then
    _needle_info() { echo "[INFO] $*" >&2; }
    _needle_warn() { echo "[WARN] $*" >&2; }
    _needle_error() { echo "[ERROR] $*" >&2; }
    _needle_debug() { [[ "${NEEDLE_VERBOSE:-}" == "true" ]] && echo "[DEBUG] $*" >&2; }
fi

# Ensure jq check function is available
if ! declare -f _needle_command_exists &>/dev/null; then
    _needle_command_exists() { command -v "$1" &>/dev/null; }
fi

# Ensure JSON escape function is available
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

# Ensure telemetry emit function is available
if ! declare -f _needle_telemetry_emit &>/dev/null; then
    _needle_telemetry_emit() {
        local event_type="$1"
        shift
        # Silently ignore if telemetry not available
        return 0
    }
fi

# Stub for metrics recording (real impl loaded from src/lock/metrics.sh)
if ! declare -f _needle_metrics_record_event &>/dev/null; then
    _needle_metrics_record_event() { return 0; }
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Generate path UUID from file path (first 8 chars of MD5)
# Usage: _needle_lock_path_uuid <filepath>
# Returns: 8-character hex string
_needle_lock_path_uuid() {
    local filepath="$1"

    if [[ -z "$filepath" ]]; then
        echo "00000000"
        return 1
    fi

    # Use md5sum to generate hash, take first 8 characters
    echo -n "$filepath" | md5sum | cut -c1-8
}

# Get the lock file path for a specific bead and file
# Usage: _needle_lock_file_path <bead_id> <filepath>
# Returns: Full path to lock file
_needle_lock_file_path() {
    local bead_id="$1"
    local filepath="$2"
    local path_uuid

    path_uuid=$(_needle_lock_path_uuid "$filepath")
    echo "${NEEDLE_LOCK_DIR}/${bead_id}-${path_uuid}"
}

# Ensure lock directory exists
# Usage: _needle_lock_ensure_dir
_needle_lock_ensure_dir() {
    if [[ ! -d "$NEEDLE_LOCK_DIR" ]]; then
        mkdir -p "$NEEDLE_LOCK_DIR" 2>/dev/null || {
            _needle_error "Failed to create lock directory: $NEEDLE_LOCK_DIR"
            return 1
        }
        _needle_debug "Created lock directory: $NEEDLE_LOCK_DIR"
    fi
}

# Write lock info JSON to lock file
# Usage: _needle_lock_write_info <lock_file> <bead_id> <worker_id> <filepath> <workspace>
_needle_lock_write_info() {
    local lock_file="$1"
    local bead_id="$2"
    local worker_id="$3"
    local filepath="$4"
    local workspace="$5"
    local ts
    ts=$(date +%s)

    if _needle_command_exists jq; then
        # Use jq for proper JSON generation
        jq -n \
            --arg bead "$bead_id" \
            --arg worker "$worker_id" \
            --arg path "$filepath" \
            --arg type "write" \
            --argjson ts "$ts" \
            --arg workspace "$workspace" \
            '{bead: $bead, worker: $worker, path: $path, type: $type, ts: $ts, workspace: $workspace}' \
            > "$lock_file"
    else
        # Fallback: manual JSON construction
        cat > "$lock_file" << EOF
{"bead":"$(_needle_json_escape "$bead_id")","worker":"$(_needle_json_escape "$worker_id")","path":"$(_needle_json_escape "$filepath")","type":"write","ts":$ts,"workspace":"$(_needle_json_escape "$workspace")"}
EOF
    fi
}

# Read lock info from lock file
# Usage: _needle_lock_read_info <lock_file>
# Returns: JSON object with lock info
_needle_lock_read_info() {
    local lock_file="$1"

    if [[ ! -f "$lock_file" ]]; then
        echo "{}"
        return 1
    fi

    cat "$lock_file" 2>/dev/null || echo "{}"
}

# Extract bead ID from lock filename
# Usage: _needle_lock_extract_bead_id <lock_file>
# Returns: Bead ID from filename
_needle_lock_extract_bead_id() {
    local lock_file="$1"
    local filename
    filename=$(basename "$lock_file")

    # Extract bead ID (everything before the last hyphen and path-uuid)
    # Format: {bead-id}-{path-uuid}
    echo "$filename" | rev | cut -d'-' -f2- | rev
}

# Extract worker ID from a lock file's JSON contents
# Usage: _needle_lock_extract_worker_id <lock_file>
# Returns: worker name string, or "unknown"
_needle_lock_extract_worker_id() {
    local lock_file="$1"
    local lock_info
    lock_info=$(_needle_lock_read_info "$lock_file")

    if _needle_command_exists jq; then
        echo "$lock_info" | jq -r '.worker // "unknown"'
    else
        echo "$lock_info" | grep -o '"worker":"[^"]*"' | cut -d'"' -f4 || echo "unknown"
    fi
}

# Check whether a worker's tmux session is still alive
# Usage: _needle_lock_worker_alive <worker_id>
# Returns: 0 if alive, 1 if dead/unverifiable via tmux
#
# Workers are identified by their tmux session name (e.g. needle-claude-zai-glm-5-alpha).
# If tmux is unavailable the check is skipped and the lock is treated as valid.
_needle_lock_worker_alive() {
    local worker_id="$1"

    if [[ -z "$worker_id" || "$worker_id" == "unknown" ]]; then
        _needle_debug "worker_alive: no worker ID, assuming alive"
        return 0
    fi

    if ! _needle_command_exists tmux; then
        _needle_debug "worker_alive: tmux not available, assuming $worker_id alive"
        return 0
    fi

    if tmux has-session -t "$worker_id" 2>/dev/null; then
        _needle_debug "worker_alive: session '$worker_id' is alive"
        return 0
    else
        _needle_debug "worker_alive: session '$worker_id' not found — worker is dead"
        return 1
    fi
}

# ============================================================================
# Core Lock API Functions
# ============================================================================

# Attempt to checkout a file for writing
# Usage: checkout_file <filepath> [bead_id] [worker_id]
# Environment: Uses NEEDLE_BEAD_ID and NEEDLE_WORKER if args not provided
# Returns:
#   0 = Lock acquired successfully
#   1 = File locked by another bead (prints blocking bead info to stdout)
# Example:
#   if ! checkout_file "/path/to/file.sh" "nd-2ov" "claude-code-glm-5"; then
#       echo "Blocked by: $(cat)"
#       exit 1
#   fi
checkout_file() {
    local filepath="$1"
    local bead_id="${2:-${NEEDLE_BEAD_ID:-}}"
    local worker_id="${3:-${NEEDLE_WORKER:-${NEEDLE_SESSION:-unknown}}}"
    local workspace="${NEEDLE_WORKSPACE:-$(pwd)}"

    # Validate inputs
    if [[ -z "$filepath" ]]; then
        _needle_error "checkout_file: filepath is required"
        return 1
    fi

    if [[ -z "$bead_id" ]]; then
        _needle_error "checkout_file: bead_id is required (set NEEDLE_BEAD_ID or pass as argument)"
        return 1
    fi

    # Ensure lock directory exists
    _needle_lock_ensure_dir || return 1

    local path_uuid lock_file
    path_uuid=$(_needle_lock_path_uuid "$filepath")
    lock_file=$(_needle_lock_file_path "$bead_id" "$filepath")

    _needle_debug "Checking out file: $filepath (uuid: $path_uuid)"

    # Record checkout attempt metric
    _needle_metrics_record_event "checkout.attempt" "$bead_id" "$filepath"

    # Check if file is already locked by another bead
    # Look for any lock files with this path UUID
    local existing_locks
    existing_locks=$(ls "${NEEDLE_LOCK_DIR}"/*-"${path_uuid}" 2>/dev/null || true)

    if [[ -n "$existing_locks" ]]; then
        # Found existing locks - check if any are from a different bead
        for existing_lock in $existing_locks; do
            local existing_bead
            existing_bead=$(_needle_lock_extract_bead_id "$existing_lock")

            if [[ "$existing_bead" != "$bead_id" ]]; then
                # File is locked by another bead — check if that worker is still alive
                local lock_info existing_worker
                lock_info=$(_needle_lock_read_info "$existing_lock")
                existing_worker=$(_needle_lock_extract_worker_id "$existing_lock")

                if ! _needle_lock_worker_alive "$existing_worker"; then
                    # Holding worker's tmux session is gone — auto-release orphaned lock
                    _needle_warn "Auto-releasing orphaned lock: $filepath (held by dead worker $existing_worker / bead $existing_bead)"
                    rm -f "$existing_lock" 2>/dev/null || true

                    _needle_telemetry_emit "file.orphan_release" "warn" \
                        "bead=$bead_id" \
                        "path=$filepath" \
                        "orphaned_bead=$existing_bead" \
                        "dead_worker=$existing_worker"

                    _needle_metrics_record_event "checkout.orphan_released" "$bead_id" "$filepath" \
                        "orphaned_bead=$existing_bead"

                    # Continue the loop — lock is gone, we can proceed to acquire
                    continue
                fi

                _needle_warn "File conflict: $filepath is locked by bead $existing_bead (worker: $existing_worker)"

                # Emit conflict telemetry event
                _needle_telemetry_emit "file.conflict" "warn" \
                    "bead=$bead_id" \
                    "path=$filepath" \
                    "blocked_by=$existing_bead"

                # Record blocked checkout metric (conflict prevented)
                _needle_metrics_record_event "checkout.blocked" "$bead_id" "$filepath" \
                    "blocked_by=$existing_bead"
                _needle_metrics_record_event "conflict.prevented" "$bead_id" "$filepath" \
                    "blocked_by=$existing_bead"

                # Return blocking bead info to stderr (stdout is captured as bead_id upstream)
                echo "$lock_info" >&2
                return 1
            fi
        done
    fi

    # Create the lock file atomically using mkdir if possible, otherwise touch
    # Using set -C (noclobber) for atomic file creation
    if (set -o noclobber; echo "" > "$lock_file" 2>/dev/null); then
        # Successfully created lock file, now write info
        _needle_lock_write_info "$lock_file" "$bead_id" "$worker_id" "$filepath" "$workspace"

        _needle_debug "Lock acquired: $lock_file"

        # Emit checkout telemetry event
        _needle_telemetry_emit "file.checkout" "info" \
            "bead=$bead_id" \
            "path=$filepath" \
            "status=acquired"

        # Record acquired checkout metric
        _needle_metrics_record_event "checkout.acquired" "$bead_id" "$filepath"

        return 0
    else
        # Race condition - another process created the lock
        _needle_warn "Race condition acquiring lock for: $filepath"

        # Re-check who holds the lock
        local existing_bead
        existing_bead=$(_needle_lock_extract_bead_id "$lock_file")

        if [[ "$existing_bead" != "$bead_id" ]]; then
            local lock_info race_worker
            lock_info=$(_needle_lock_read_info "$lock_file")
            race_worker=$(_needle_lock_extract_worker_id "$lock_file")

            if ! _needle_lock_worker_alive "$race_worker"; then
                # Holding worker is dead — steal the lock
                _needle_warn "Race: stealing orphaned lock from dead worker $race_worker / bead $existing_bead for $filepath"
                _needle_lock_write_info "$lock_file" "$bead_id" "$worker_id" "$filepath" "$workspace"

                _needle_telemetry_emit "file.orphan_release" "warn" \
                    "bead=$bead_id" \
                    "path=$filepath" \
                    "orphaned_bead=$existing_bead" \
                    "dead_worker=$race_worker"

                _needle_metrics_record_event "checkout.orphan_released" "$bead_id" "$filepath" \
                    "orphaned_bead=$existing_bead"

                return 0
            fi

            _needle_telemetry_emit "file.conflict" "warn" \
                "bead=$bead_id" \
                "path=$filepath" \
                "blocked_by=$existing_bead"

            # Record blocked checkout metric
            _needle_metrics_record_event "checkout.blocked" "$bead_id" "$filepath" \
                "blocked_by=$existing_bead"
            _needle_metrics_record_event "conflict.prevented" "$bead_id" "$filepath" \
                "blocked_by=$existing_bead"

            echo "$lock_info" >&2
            return 1
        fi

        # We already have the lock, just update it
        _needle_lock_write_info "$lock_file" "$bead_id" "$worker_id" "$filepath" "$workspace"
        _needle_debug "Lock refreshed: $lock_file"
        # Record acquired checkout metric (re-checkout by same bead)
        _needle_metrics_record_event "checkout.acquired" "$bead_id" "$filepath"
        return 0
    fi
}

# Release a specific file lock
# Usage: release_file <filepath> [bead_id]
# Environment: Uses NEEDLE_BEAD_ID if arg not provided
# Returns:
#   0 = Lock released or didn't exist
#   1 = Error releasing lock
# Example:
#   release_file "/path/to/file.sh"
release_file() {
    local filepath="$1"
    local bead_id="${2:-${NEEDLE_BEAD_ID:-}}"
    local lock_file
    local held_for_ms=0

    if [[ -z "$filepath" ]]; then
        _needle_error "release_file: filepath is required"
        return 1
    fi

    if [[ -z "$bead_id" ]]; then
        _needle_error "release_file: bead_id is required (set NEEDLE_BEAD_ID or pass as argument)"
        return 1
    fi

    lock_file=$(_needle_lock_file_path "$bead_id" "$filepath")

    if [[ ! -f "$lock_file" ]]; then
        _needle_debug "No lock to release: $filepath"
        return 0
    fi

    # Calculate how long we held the lock
    local lock_info ts now
    lock_info=$(_needle_lock_read_info "$lock_file")
    if _needle_command_exists jq; then
        ts=$(echo "$lock_info" | jq -r '.ts // 0')
    else
        ts=$(echo "$lock_info" | grep -o '"ts":[0-9]*' | cut -d: -f2 || echo 0)
    fi
    now=$(date +%s)
    held_for_ms=$(( (now - ts) * 1000 ))

    # Remove the lock file
    if rm -f "$lock_file" 2>/dev/null; then
        _needle_debug "Lock released: $lock_file (held for ${held_for_ms}ms)"

        # Emit release telemetry event
        _needle_telemetry_emit "file.release" "info" \
            "bead=$bead_id" \
            "path=$filepath" \
            "held_for_ms=$held_for_ms"

        return 0
    else
        _needle_error "Failed to release lock: $lock_file"
        return 1
    fi
}

# Release ALL locks held by a bead
# Called automatically on bead completion or failure
# Usage: release_bead_locks <bead_id>
# Returns: 0 always (best-effort cleanup)
# Example:
#   release_bead_locks "nd-2ov"
release_bead_locks() {
    local bead_id="${1:-${NEEDLE_BEAD_ID:-}}"
    local released_count=0
    local failed_count=0

    if [[ -z "$bead_id" ]]; then
        _needle_debug "release_bead_locks: no bead_id provided, skipping"
        return 0
    fi

    _needle_debug "Releasing all locks for bead: $bead_id"

    # Find all lock files for this bead
    local lock_pattern="${NEEDLE_LOCK_DIR}/${bead_id}-*"
    local lock_files
    lock_files=$(ls $lock_pattern 2>/dev/null || true)

    if [[ -z "$lock_files" ]]; then
        _needle_debug "No locks found for bead: $bead_id"
        return 0
    fi

    for lock_file in $lock_files; do
        [[ -f "$lock_file" ]] || continue

        # Read lock info for telemetry
        local lock_info filepath ts now held_for_ms
        lock_info=$(_needle_lock_read_info "$lock_file")

        if _needle_command_exists jq; then
            filepath=$(echo "$lock_info" | jq -r '.path // "unknown"')
            ts=$(echo "$lock_info" | jq -r '.ts // 0')
        else
            filepath=$(echo "$lock_info" | grep -o '"path":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
            ts=$(echo "$lock_info" | grep -o '"ts":[0-9]*' | cut -d: -f2 || echo 0)
        fi

        now=$(date +%s)
        held_for_ms=$(( (now - ts) * 1000 ))

        # Remove the lock file
        if rm -f "$lock_file" 2>/dev/null; then
            released_count=$((released_count + 1))

            # Emit release telemetry event
            _needle_telemetry_emit "file.release" "info" \
                "bead=$bead_id" \
                "path=$filepath" \
                "held_for_ms=$held_for_ms"
        else
            failed_count=$((failed_count + 1))
            _needle_warn "Failed to release lock: $lock_file"
        fi
    done

    _needle_info "Released $released_count locks for bead $bead_id (failed: $failed_count)"

    return 0
}

# Check if a file is locked (read-only query)
# Usage: check_file <filepath>
# Returns:
#   0 = File is locked (prints lock info JSON to stdout)
#   1 = File is not locked
# Example:
#   if check_file "/path/to/file.sh"; then
#       echo "File is locked by: $(cat | jq -r '.bead')"
#   fi
check_file() {
    local filepath="$1"
    local path_uuid
    local lock_files

    if [[ -z "$filepath" ]]; then
        _needle_error "check_file: filepath is required"
        return 1
    fi

    path_uuid=$(_needle_lock_path_uuid "$filepath")
    lock_files=$(ls "${NEEDLE_LOCK_DIR}"/*-"${path_uuid}" 2>/dev/null || true)

    if [[ -z "$lock_files" ]]; then
        _needle_debug "File not locked: $filepath"
        return 1
    fi

    # Return info about the first lock found
    local lock_file
    lock_file=$(echo "$lock_files" | head -1)
    local lock_info
    lock_info=$(_needle_lock_read_info "$lock_file")

    echo "$lock_info"
    return 0
}

# List all current locks (for debugging)
# Usage: list_locks [bead_id]
# Arguments:
#   bead_id - Optional, filter to specific bead
# Returns: JSON array of lock info objects
# Example:
#   list_locks
#   list_locks "nd-2ov"
list_locks() {
    local filter_bead_id="${1:-}"
    local lock_pattern="${NEEDLE_LOCK_DIR}/*"
    local locks=()

    if [[ -n "$filter_bead_id" ]]; then
        lock_pattern="${NEEDLE_LOCK_DIR}/${filter_bead_id}-*"
    fi

    local lock_files
    lock_files=$(ls $lock_pattern 2>/dev/null || true)

    if [[ -z "$lock_files" ]]; then
        echo "[]"
        return 0
    fi

    if _needle_command_exists jq; then
        # Build JSON array using jq
        local json_array="[]"
        for lock_file in $lock_files; do
            [[ -f "$lock_file" ]] || continue
            local lock_info
            lock_info=$(_needle_lock_read_info "$lock_file")
            json_array=$(echo "$json_array" | jq --argjson info "$lock_info" '. + [$info]')
        done
        echo "$json_array"
    else
        # Fallback: build JSON array manually
        local first=true
        echo -n "["
        for lock_file in $lock_files; do
            [[ -f "$lock_file" ]] || continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo -n ","
            fi
            _needle_lock_read_info "$lock_file"
        done
        echo "]"
    fi
}

# ============================================================================
# Stale Lock Detection
# ============================================================================

# Check and handle stale locks
# A lock is considered stale if it's older than the configured timeout
# Usage: check_stale_locks [action]
# Arguments:
#   action - warn (default), release, or ignore
# Config:
#   file_locks.timeout - Lock age timeout (default: 30m = 1800s)
#   file_locks.stale_action - Action for stale locks (default: warn)
# Returns: Number of stale locks found
check_stale_locks() {
    local action="${1:-}"
    local now ts timeout_s stale_count=0

    # Get timeout from config (default 30 minutes)
    if declare -f get_config &>/dev/null; then
        local timeout_config
        timeout_config=$(get_config "file_locks.timeout" "30m")
        # Parse timeout (supports: 30m, 1h, 3600s, or just seconds)
        case "$timeout_config" in
            *m) timeout_s=$(( ${timeout_config%m} * 60 )) ;;
            *h) timeout_s=$(( ${timeout_config%h} * 3600 )) ;;
            *s) timeout_s=${timeout_config%s} ;;
            *) timeout_s=$timeout_config ;;
        esac
    else
        timeout_s=1800  # 30 minutes default
    fi

    # Get action from config if not provided
    if [[ -z "$action" ]]; then
        if declare -f get_config &>/dev/null; then
            action=$(get_config "file_locks.stale_action" "warn")
        else
            action="warn"
        fi
    fi

    now=$(date +%s)

    _needle_debug "Checking for stale locks (timeout: ${timeout_s}s, action: $action)"

    # Iterate through all locks
    local lock_pattern="${NEEDLE_LOCK_DIR}/*"
    local lock_files
    lock_files=$(ls $lock_pattern 2>/dev/null || true)

    for lock_file in $lock_files; do
        [[ -f "$lock_file" ]] || continue

        local lock_info bead filepath age_s
        lock_info=$(_needle_lock_read_info "$lock_file")

        if _needle_command_exists jq; then
            ts=$(echo "$lock_info" | jq -r '.ts // 0')
            bead=$(echo "$lock_info" | jq -r '.bead // "unknown"')
            filepath=$(echo "$lock_info" | jq -r '.path // "unknown"')
        else
            ts=$(echo "$lock_info" | grep -o '"ts":[0-9]*' | cut -d: -f2 || echo 0)
            bead=$(echo "$lock_info" | grep -o '"bead":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
            filepath=$(echo "$lock_info" | grep -o '"path":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        fi

        age_s=$(( now - ts ))

        if (( age_s > timeout_s )); then
            stale_count=$((stale_count + 1))

            _needle_warn "Stale lock detected: $filepath (held by $bead for ${age_s}s)"

            # Emit stale lock telemetry
            _needle_telemetry_emit "file.stale" "warn" \
                "bead=$bead" \
                "path=$filepath" \
                "age_s=$age_s" \
                "action=$action"

            case "$action" in
                release)
                    if rm -f "$lock_file" 2>/dev/null; then
                        _needle_info "Released stale lock: $lock_file"
                    else
                        _needle_error "Failed to release stale lock: $lock_file"
                    fi
                    ;;
                warn)
                    # Already warned above
                    ;;
                ignore)
                    _needle_debug "Ignoring stale lock (action=ignore)"
                    ;;
                *)
                    _needle_warn "Unknown stale action: $action"
                    ;;
            esac
        fi
    done

    if (( stale_count > 0 )); then
        _needle_info "Found $stale_count stale lock(s)"
    fi

    return $stale_count
}

# ============================================================================
# Bead Reap Check (for cleanup_stale_locks)
# ============================================================================

# Check if a bead is still active (open or in_progress)
# Usage: _needle_lock_bead_active <bead_id>
# Returns: 0 if active, 1 if closed/deleted
_needle_lock_bead_active() {
    local bead_id="$1"

    # Check if br command exists
    if ! _needle_command_exists br; then
        _needle_debug "br command not found, assuming bead is active"
        return 0
    fi

    # Query bead status
    local bead_json
    bead_json=$(br show "$bead_id" --json 2>/dev/null || echo "[]")

    if _needle_command_exists jq; then
        # Check if status is open or in_progress
        local status
        status=$(echo "$bead_json" | jq -r '.[0].status // "unknown"')

        case "$status" in
            open|in_progress)
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    else
        # Fallback: simple grep
        if echo "$bead_json" | grep -q '"status"[[:space:]]*:[[:space:]]*"[^"]*closed[^"]*"'; then
            return 1
        fi
        return 0
    fi
}

# Cleanup locks for beads that are no longer active
# Usage: cleanup_reaped_locks
# Returns: Number of locks cleaned up
cleanup_reaped_locks() {
    local cleaned_count=0
    local lock_pattern="${NEEDLE_LOCK_DIR}/*"
    local lock_files

    lock_files=$(ls $lock_pattern 2>/dev/null || true)

    if [[ -z "$lock_files" ]]; then
        _needle_debug "No locks to check for reaped beads"
        return 0
    fi

    _needle_debug "Checking for locks belonging to reaped beads or dead workers..."

    # Track which beads/workers we've already checked
    declare -A checked_beads
    declare -A checked_workers

    for lock_file in $lock_files; do
        [[ -f "$lock_file" ]] || continue

        local bead_id worker_id
        bead_id=$(_needle_lock_extract_bead_id "$lock_file")
        worker_id=$(_needle_lock_extract_worker_id "$lock_file")

        # Check worker liveness first (fast tmux check, no br call needed)
        if [[ -z "${checked_workers[$worker_id]:-}" ]]; then
            checked_workers[$worker_id]=1
            if ! _needle_lock_worker_alive "$worker_id"; then
                _needle_info "Worker '$worker_id' is dead — releasing all its locks"
                # Release every lock file owned by this worker directly
                local w_pattern="${NEEDLE_LOCK_DIR}/*"
                local w_files
                w_files=$(ls $w_pattern 2>/dev/null || true)
                for w_lock in $w_files; do
                    [[ -f "$w_lock" ]] || continue
                    local w_owner
                    w_owner=$(_needle_lock_extract_worker_id "$w_lock")
                    if [[ "$w_owner" == "$worker_id" ]]; then
                        rm -f "$w_lock" 2>/dev/null || true
                        cleaned_count=$((cleaned_count + 1))
                        _needle_telemetry_emit "file.orphan_release" "warn" \
                            "worker=$worker_id" \
                            "lock=$w_lock"
                    fi
                done
                # Mark bead as already handled to skip br query below
                checked_beads[$bead_id]=1
                continue
            fi
        fi

        # Skip if we already checked this bead
        if [[ -n "${checked_beads[$bead_id]:-}" ]]; then
            continue
        fi

        # Worker is alive — check if the bead itself is still active
        if ! _needle_lock_bead_active "$bead_id"; then
            _needle_info "Bead $bead_id is no longer active, releasing its locks"

            # Release all locks for this bead
            release_bead_locks "$bead_id"
            cleaned_count=$((cleaned_count + 1))
        fi

        # Mark as checked
        checked_beads[$bead_id]=1
    done

    if (( cleaned_count > 0 )); then
        _needle_info "Cleaned up locks for $cleaned_count reaped bead(s)"
    fi

    return $cleaned_count
}

# ============================================================================
# CLI Integration Functions
# ============================================================================

# CLI: checkout command
# Usage: _needle_cli_checkout <filepath>
_needle_cli_checkout() {
    local filepath="$1"

    if [[ -z "$filepath" ]]; then
        _needle_error "Usage: needle checkout <filepath>"
        return 1
    fi

    # Resolve to absolute path
    if [[ "$filepath" != /* ]]; then
        filepath="$(pwd)/$filepath"
    fi

    local bead_id="${NEEDLE_BEAD_ID:-cli-$$}"
    local worker_id="${NEEDLE_WORKER:-cli}"

    if checkout_file "$filepath" "$bead_id" "$worker_id"; then
        _needle_success "Checked out: $filepath"
        return 0
    else
        local blocking_info
        blocking_info=$(cat)
        local blocking_bead
        if _needle_command_exists jq; then
            blocking_bead=$(echo "$blocking_info" | jq -r '.bead // "unknown"')
        else
            blocking_bead="unknown"
        fi
        _needle_error "File locked by: $blocking_bead"
        return 1
    fi
}

# CLI: release command
# Usage: _needle_cli_release <filepath>
_needle_cli_release() {
    local filepath="$1"

    if [[ -z "$filepath" ]]; then
        _needle_error "Usage: needle release <filepath>"
        return 1
    fi

    # Resolve to absolute path
    if [[ "$filepath" != /* ]]; then
        filepath="$(pwd)/$filepath"
    fi

    local bead_id="${NEEDLE_BEAD_ID:-cli-$$}"

    if release_file "$filepath" "$bead_id"; then
        _needle_success "Released: $filepath"
        return 0
    else
        return 1
    fi
}

# CLI: status command (for file locks)
# Usage: _needle_cli_lock_status [filepath]
_needle_cli_lock_status() {
    local filepath="$1"

    if [[ -n "$filepath" ]]; then
        # Resolve to absolute path
        if [[ "$filepath" != /* ]]; then
            filepath="$(pwd)/$filepath"
        fi

        if check_file "$filepath"; then
            local lock_info
            lock_info=$(cat)
            local bead worker ts age
            if _needle_command_exists jq; then
                bead=$(echo "$lock_info" | jq -r '.bead')
                worker=$(echo "$lock_info" | jq -r '.worker')
                ts=$(echo "$lock_info" | jq -r '.ts')
                age=$(($(date +%s) - ts))
                _needle_info "File locked by: $bead (worker: $worker, age: ${age}s)"
            else
                echo "$lock_info"
            fi
            return 0
        else
            _needle_info "File not locked: $filepath"
            return 1
        fi
    else
        # List all locks
        local locks
        locks=$(list_locks)
        local count
        if _needle_command_exists jq; then
            count=$(echo "$locks" | jq 'length')
        else
            count=$(echo "$locks" | grep -c '{' || echo 0)
        fi

        if (( count == 0 )); then
            _needle_info "No active file locks"
        else
            _needle_header "Active File Locks ($count)"
            if _needle_command_exists jq; then
                echo "$locks" | jq -r '.[] | "  \(.bead): \(.path) (worker: \(.worker))"'
            else
                echo "$locks"
            fi
        fi
        return 0
    fi
}

# ============================================================================
# Priority-Based Lock Queuing
# ============================================================================
# When a high-priority bead needs a file locked by a lower-priority bead,
# the request is queued and the holder is signaled to expedite.
#
# Queue Structure (stored in lock file):
# {
#   "path": "/src/cli/run.sh",
#   "holder": {"bead": "nd-low", "priority": 2, "worker": "alpha"},
#   "queue": [
#     {"bead": "nd-high", "priority": 0, "worker": "bravo", "ts": 1709337700}
#   ]
# }
#
# Priority levels: P0=critical, P1=high, P2=normal, P3=low
# Lower number = higher priority

# Queue directory for priority bump signals
NEEDLE_QUEUE_DIR="${NEEDLE_QUEUE_DIR:-${NEEDLE_LOCK_DIR}/queue}"

# Ensure queue directory exists
_needle_queue_ensure_dir() {
    if [[ ! -d "$NEEDLE_QUEUE_DIR" ]]; then
        mkdir -p "$NEEDLE_QUEUE_DIR" 2>/dev/null || {
            _needle_error "Failed to create queue directory: $NEEDLE_QUEUE_DIR"
            return 1
        }
    fi
}

# Get the queue file path for a specific bead
# This is where other workers can send priority bump signals to this bead
# Usage: _needle_queue_file_path <bead_id>
# Returns: Full path to queue file
_needle_queue_file_path() {
    local bead_id="$1"
    echo "${NEEDLE_QUEUE_DIR}/${bead_id}.queue"
}

# Write a lock with queue support (holder + queue structure)
# Usage: _needle_lock_write_with_queue <lock_file> <bead_id> <worker_id> <filepath> <workspace> [priority]
_needle_lock_write_with_queue() {
    local lock_file="$1"
    local bead_id="$2"
    local worker_id="$3"
    local filepath="$4"
    local workspace="$5"
    local priority="${6:-2}"  # Default to P2 (normal)
    local ts
    ts=$(date +%s)

    if _needle_command_exists jq; then
        # Use jq for proper JSON generation with queue structure
        jq -n \
            --arg bead "$bead_id" \
            --arg worker "$worker_id" \
            --arg path "$filepath" \
            --arg type "write" \
            --argjson ts "$ts" \
            --arg workspace "$workspace" \
            --argjson priority "$priority" \
            '{
                path: $path,
                holder: {bead: $bead, priority: $priority, worker: $worker},
                queue: []
            }' > "$lock_file"
    else
        # Fallback: manual JSON construction
        cat > "$lock_file" << EOF
{"path":"$(_needle_json_escape "$filepath")","holder":{"bead":"$(_needle_json_escape "$bead_id")","priority":$priority,"worker":"$(_needle_json_escape "$worker_id")"},"queue":[]}
EOF
    fi
}

# Add a request to the lock queue
# Usage: _needle_lock_add_to_queue <filepath> <bead_id> <worker_id> <priority>
# Returns: 0 if added successfully, 1 on error
_needle_lock_add_to_queue() {
    local filepath="$1"
    local bead_id="$2"
    local worker_id="$3"
    local priority="$4"
    local path_uuid lock_file

    path_uuid=$(_needle_lock_path_uuid "$filepath")

    # Find the lock file (owned by another bead)
    local existing_locks
    existing_locks=$(ls "${NEEDLE_LOCK_DIR}"/*-"${path_uuid}" 2>/dev/null || true)

    if [[ -z "$existing_locks" ]]; then
        _needle_error "No lock found for queue addition: $filepath"
        return 1
    fi

    # Get the first lock file (there should only be one holder)
    local lock_file
    lock_file=$(echo "$existing_locks" | head -1)

    local lock_info ts
    lock_info=$(_needle_lock_read_info "$lock_file")
    ts=$(date +%s)

    if _needle_command_exists jq; then
        # Add request to queue using jq
        local new_request
        new_request=$(jq -n \
            --arg bead "$bead_id" \
            --arg worker "$worker_id" \
            --argjson priority "$priority" \
            --argjson ts "$ts" \
            '{bead: $bead, priority: $priority, worker: $worker, ts: $ts}')

        # Update the lock file with new queue entry
        local updated_lock
        updated_lock=$(echo "$lock_info" | jq --argjson req "$new_request" '.queue += [$req]')
        echo "$updated_lock" > "$lock_file"
    else
        # Fallback: append to queue array manually (less robust)
        _needle_warn "jq required for priority queue operations"
        return 1
    fi

    _needle_debug "Added $bead_id (P$priority) to queue for $filepath"
    return 0
}

# Get the current holder priority from a lock
# Usage: _needle_lock_get_holder_priority <lock_info_json>
# Returns: Priority number (0-3), defaults to 2 if not found
_needle_lock_get_holder_priority() {
    local lock_info="$1"

    if _needle_command_exists jq; then
        local priority
        priority=$(echo "$lock_info" | jq -r '.holder.priority // 2')
        echo "$priority"
    else
        # Fallback: grep for priority
        echo "$lock_info" | grep -o '"priority":[0-9]*' | cut -d: -f2 || echo "2"
    fi
}

# Request a lock with priority-based queuing
# When a high-priority bead needs a file locked by a lower-priority bead:
# 1. If file is free, acquire lock immediately
# 2. If held by lower priority, add to queue and signal holder
# 3. If held by same/higher priority, just add dependency
#
# Usage: request_lock_with_priority <filepath> <bead_id> <priority> [worker_id]
# Arguments:
#   filepath  - Absolute path to file
#   bead_id   - Bead ID requesting the lock
#   priority  - Priority level (0=critical, 1=high, 2=normal, 3=low)
#   worker_id - Optional worker ID (defaults to NEEDLE_WORKER)
# Returns:
#   0 = Lock acquired immediately
#   1 = Queued behind another bead (dependency added)
#   2 = Added to queue with priority bump signal sent
# Example:
#   request_lock_with_priority "/src/cli/run.sh" "nd-high" 0 "worker-alpha"
request_lock_with_priority() {
    local filepath="$1"
    local bead_id="$2"
    local priority="$3"
    local worker_id="${4:-${NEEDLE_WORKER:-${NEEDLE_SESSION:-unknown}}}"
    local workspace="${NEEDLE_WORKSPACE:-$(pwd)}"

    # Validate inputs
    if [[ -z "$filepath" ]]; then
        _needle_error "request_lock_with_priority: filepath is required"
        return 1
    fi

    if [[ -z "$bead_id" ]]; then
        _needle_error "request_lock_with_priority: bead_id is required"
        return 1
    fi

    # Validate priority (0-3, default to 2)
    if ! [[ "$priority" =~ ^[0-3]$ ]]; then
        _needle_warn "Invalid priority '$priority', defaulting to 2 (normal)"
        priority=2
    fi

    # Ensure directories exist
    _needle_lock_ensure_dir || return 1

    local path_uuid
    path_uuid=$(_needle_lock_path_uuid "$filepath")

    _needle_debug "Priority lock request: $bead_id (P$priority) wants $filepath"

    # Record checkout attempt metric
    _needle_metrics_record_event "checkout.attempt" "$bead_id" "$filepath" "priority=$priority"

    # Check if file is already locked
    local existing_locks
    existing_locks=$(ls "${NEEDLE_LOCK_DIR}"/*-"${path_uuid}" 2>/dev/null || true)

    if [[ -z "$existing_locks" ]]; then
        # File is free - acquire lock immediately
        local lock_file
        lock_file=$(_needle_lock_file_path "$bead_id" "$filepath")

        if (set -o noclobber; echo "" > "$lock_file" 2>/dev/null); then
            _needle_lock_write_with_queue "$lock_file" "$bead_id" "$worker_id" "$filepath" "$workspace" "$priority"

            _needle_debug "Priority lock acquired: $lock_file (P$priority)"

            _needle_telemetry_emit "file.checkout" "info" \
                "bead=$bead_id" \
                "path=$filepath" \
                "priority=$priority" \
                "status=acquired"

            _needle_metrics_record_event "checkout.acquired" "$bead_id" "$filepath" "priority=$priority"

            return 0
        else
            # Race condition - retry
            _needle_warn "Race condition acquiring priority lock for: $filepath"
            return 1
        fi
    fi

    # File is locked - check holder's priority
    local lock_file lock_info holder_bead holder_priority holder_worker
    lock_file=$(echo "$existing_locks" | head -1)
    lock_info=$(_needle_lock_read_info "$lock_file")
    holder_bead=$(_needle_lock_extract_bead_id "$lock_file")
    holder_priority=$(_needle_lock_get_holder_priority "$lock_info")
    holder_worker=$(_needle_lock_extract_worker_id "$lock_file")

    # Check if holder worker is still alive
    if ! _needle_lock_worker_alive "$holder_worker"; then
        # Holder is dead - steal the lock
        _needle_warn "Stealing orphaned lock from dead worker $holder_worker / bead $holder_bead for $filepath"
        rm -f "$lock_file" 2>/dev/null || true

        _needle_telemetry_emit "file.orphan_release" "warn" \
            "bead=$bead_id" \
            "path=$filepath" \
            "orphaned_bead=$holder_bead" \
            "dead_worker=$holder_worker"

        _needle_metrics_record_event "checkout.orphan_released" "$bead_id" "$filepath" \
            "orphaned_bead=$holder_bead"

        # Retry the acquisition
        lock_file=$(_needle_lock_file_path "$bead_id" "$filepath")
        _needle_lock_write_with_queue "$lock_file" "$bead_id" "$worker_id" "$filepath" "$workspace" "$priority"
        return 0
    fi

    # Same bead already has lock - refresh it
    if [[ "$holder_bead" == "$bead_id" ]]; then
        _needle_lock_write_with_queue "$lock_file" "$bead_id" "$worker_id" "$filepath" "$workspace" "$priority"
        _needle_debug "Priority lock refreshed: $lock_file (P$priority)"
        _needle_metrics_record_event "checkout.acquired" "$bead_id" "$filepath" "priority=$priority"
        return 0
    fi

    # File locked by another bead - check priority
    _needle_warn "File conflict: $filepath is locked by bead $holder_bead (P$holder_priority, worker: $holder_worker)"

    if [[ "$priority" -lt "$holder_priority" ]]; then
        # We're higher priority - add to queue and signal holder
        _needle_lock_add_to_queue "$filepath" "$bead_id" "$worker_id" "$priority"

        # Emit priority bump telemetry event
        _needle_telemetry_emit "lock.priority_bump" "warn" \
            "path=$filepath" \
            "waiting_bead=$bead_id" \
            "waiting_priority=$priority" \
            "holder_bead=$holder_bead" \
            "holder_priority=$holder_priority"

        _needle_metrics_record_event "lock.priority_bump" "$bead_id" "$filepath" \
            "waiting_priority=$priority" \
            "holder_bead=$holder_bead" \
            "holder_priority=$holder_priority"

        # Signal the holder to expedite or yield
        _needle_signal_worker "$holder_bead" "$holder_worker" "PRIORITY_BUMP" "$filepath" "$bead_id" "$priority"

        _needle_info "Priority bump sent to $holder_bead (P$holder_priority -> P$priority waiting) for $filepath"

        return 2  # Queued with priority bump
    fi

    # We're same or lower priority - standard conflict handling
    _needle_telemetry_emit "file.conflict" "warn" \
        "bead=$bead_id" \
        "path=$filepath" \
        "blocked_by=$holder_bead" \
        "holder_priority=$holder_priority" \
        "requester_priority=$priority"

    _needle_metrics_record_event "checkout.blocked" "$bead_id" "$filepath" \
        "blocked_by=$holder_bead" \
        "priority=$priority"

    # Return blocking info to stderr
    echo "$lock_info" >&2
    return 1
}

# Signal a worker about a priority bump
# Creates a signal file in the queue directory that the worker can poll
#
# Usage: _needle_signal_worker <holder_bead> <holder_worker> <signal_type> <filepath> <waiting_bead> <waiting_priority>
# Arguments:
#   holder_bead      - Bead ID of the lock holder
#   holder_worker    - Worker ID of the lock holder
#   signal_type      - Type of signal (e.g., "PRIORITY_BUMP")
#   filepath         - File that has the priority bump
#   waiting_bead     - Bead ID that is waiting
#   waiting_priority - Priority of waiting bead
# Returns: 0 on success, 1 on failure
_needle_signal_worker() {
    local holder_bead="$1"
    local holder_worker="$2"
    local signal_type="$3"
    local filepath="$4"
    local waiting_bead="$5"
    local waiting_priority="$6"

    _needle_queue_ensure_dir || return 1

    local queue_file ts signal_file
    queue_file=$(_needle_queue_file_path "$holder_bead")
    ts=$(date +%s)

    # Create signal entry
    if _needle_command_exists jq; then
        local signal_json
        signal_json=$(jq -n \
            --arg type "$signal_type" \
            --arg path "$filepath" \
            --arg waiting_bead "$waiting_bead" \
            --argjson waiting_priority "$waiting_priority" \
            --argjson ts "$ts" \
            '{
                type: $type,
                path: $path,
                waiting_bead: $waiting_bead,
                waiting_priority: $waiting_priority,
                ts: $ts
            }')

        # Append to queue file (newline-delimited JSON)
        echo "$signal_json" >> "$queue_file"

        _needle_debug "Signal sent to $holder_bead: $signal_type for $filepath"
    else
        # Fallback: write simple format
        echo "${signal_type}|${filepath}|${waiting_bead}|${waiting_priority}|${ts}" >> "$queue_file"
    fi

    return 0
}

# Check for priority bump signals for the current bead
# Used by worker loop to detect when higher-priority beads are waiting
#
# Usage: _needle_check_priority_bumps [bead_id]
# Arguments:
#   bead_id - Optional bead ID (defaults to NEEDLE_BEAD_ID)
# Returns:
#   0 = No signals pending
#   1+ = Number of priority bump signals found
# Output: JSON array of pending signals to stdout
_needle_check_priority_bumps() {
    local bead_id="${1:-${NEEDLE_BEAD_ID:-}}"
    local queue_file signals

    if [[ -z "$bead_id" ]]; then
        echo "[]"
        return 0
    fi

    queue_file=$(_needle_queue_file_path "$bead_id")

    if [[ ! -f "$queue_file" ]]; then
        echo "[]"
        return 0
    fi

    # Read and clear the queue file atomically
    local tmp_file
    tmp_file=$(mktemp)
    mv "$queue_file" "$tmp_file" 2>/dev/null || {
        echo "[]"
        return 0
    }

    # Filter to priority bump signals
    if _needle_command_exists jq; then
        # Parse JSONL and filter
        signals=$(jq -s 'map(select(.type == "PRIORITY_BUMP"))' "$tmp_file" 2>/dev/null || echo "[]")
        local count
        count=$(echo "$signals" | jq 'length')

        echo "$signals"
        rm -f "$tmp_file"
        return "$count"
    else
        # Fallback: parse simple format
        signals="[]"
        local count=0
        while IFS='|' read -r sig_type sig_path sig_bead sig_prio sig_ts; do
            if [[ "$sig_type" == "PRIORITY_BUMP" ]]; then
                count=$((count + 1))
            fi
        done < "$tmp_file"
        rm -f "$tmp_file"
        echo "$signals"
        return "$count"
    fi
}

# Handle a priority bump signal in the worker loop
# Called when a worker discovers a higher-priority bead is waiting
#
# Usage: handle_priority_bump <signal_json>
# Arguments:
#   signal_json - JSON object describing the bump signal
# Output: Logs warning and recommendations
# Returns: 0 always (informational)
#
# Options for worker:
#   1. Complete current work faster (reduce exploration depth)
#   2. Checkpoint and yield (if supported)
#   3. Continue but emit ETA for waiting bead
handle_priority_bump() {
    local signal_json="$1"
    local waiting_bead waiting_priority filepath

    if _needle_command_exists jq; then
        waiting_bead=$(echo "$signal_json" | jq -r '.waiting_bead // "unknown"')
        waiting_priority=$(echo "$signal_json" | jq -r '.waiting_priority // 2')
        filepath=$(echo "$signal_json" | jq -r '.path // "unknown"')
    else
        _needle_warn "Priority bump received - jq required for details"
        return 0
    fi

    local priority_name
    case "$waiting_priority" in
        0) priority_name="CRITICAL" ;;
        1) priority_name="HIGH" ;;
        2) priority_name="NORMAL" ;;
        3) priority_name="LOW" ;;
        *) priority_name="UNKNOWN" ;;
    esac

    _needle_warn "=========================================="
    _needle_warn "PRIORITY BUMP RECEIVED"
    _needle_warn "=========================================="
    _needle_warn "Higher priority bead waiting: $waiting_bead (P$waiting_priority - $priority_name)"
    _needle_warn "Affected file: $filepath"
    _needle_warn ""
    _needle_warn "Options:"
    _needle_warn "  1. Expedite: Complete current work faster"
    _needle_warn "  2. Yield: Checkpoint progress and release lock"
    _needle_warn "  3. Continue: Work normally, bead will wait"
    _needle_warn "=========================================="

    # Emit telemetry about the bump being received
    _needle_telemetry_emit "lock.priority_bump_received" "warn" \
        "waiting_bead=$waiting_bead" \
        "waiting_priority=$waiting_priority" \
        "path=$filepath"

    return 0
}

# Release lock and notify next in queue (if any)
# Called when a bead releases a lock that has a queue
#
# Usage: _needle_release_lock_with_handoff <filepath> <bead_id>
# Returns: 0 on success
_needle_release_lock_with_handoff() {
    local filepath="$1"
    local bead_id="${2:-${NEEDLE_BEAD_ID:-}}"
    local path_uuid lock_file lock_info

    if [[ -z "$filepath" ]] || [[ -z "$bead_id" ]]; then
        return 1
    fi

    path_uuid=$(_needle_lock_path_uuid "$filepath")
    lock_file=$(_needle_lock_file_path "$bead_id" "$filepath")

    if [[ ! -f "$lock_file" ]]; then
        return 0
    fi

    lock_info=$(_needle_lock_read_info "$lock_file")

    # Check if there's a queue
    local queue_length=0
    if _needle_command_exists jq; then
        queue_length=$(echo "$lock_info" | jq '.queue | length')
    fi

    # Remove the lock
    rm -f "$lock_file" 2>/dev/null

    _needle_telemetry_emit "file.release" "info" \
        "bead=$bead_id" \
        "path=$filepath" \
        "queue_depth=$queue_length"

    # If there was a queue, the next in line can now acquire
    # They will discover the lock is free on their next attempt
    if [[ "$queue_length" -gt 0 ]]; then
        _needle_info "Lock released with $queue_length waiting - next in queue can acquire"

        # Signal the first in queue that lock is available
        if _needle_command_exists jq; then
            local next_bead next_worker
            next_bead=$(echo "$lock_info" | jq -r '.queue[0].bead')
            next_worker=$(echo "$lock_info" | jq -r '.queue[0].worker')

            if [[ -n "$next_bead" ]] && [[ "$next_bead" != "null" ]]; then
                _needle_signal_worker "$next_bead" "$next_worker" "LOCK_AVAILABLE" "$filepath" "$bead_id" "0"
            fi
        fi
    fi

    return 0
}

# ============================================================================
# Hook Integration
# ============================================================================

# Function to be called from post_complete and on_failure hooks
# Automatically releases all locks for the current bead
# Usage: _needle_hook_release_locks
_needle_hook_release_locks() {
    local bead_id="${NEEDLE_BEAD_ID:-}"

    if [[ -z "$bead_id" ]]; then
        _needle_debug "No bead_id set, skipping lock release"
        return 0
    fi

    _needle_info "Releasing all file locks for bead: $bead_id"
    release_bead_locks "$bead_id"
}
