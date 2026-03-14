#!/usr/bin/env bash
# NEEDLE Optimistic Locking Module
# Implements optimistic locking with 3-way merge for concurrent file edits
#
# Design:
# Instead of blocking on conflict, allow concurrent edits and attempt 3-way merge
# at completion. If merge fails, restore, add dependency, and re-queue the bead.
#
# Workflow:
#   1. prepare_optimistic_edits() - snapshot files before agent execution
#   2. Agent edits files
#   3. reconcile_optimistic_edits() - merge if concurrent modifications detected
#
# Configuration:
#   file_locks.strategy: optimistic|pessimistic (default: pessimistic)
#   file_locks.merge.enabled: true|false (default: true when strategy=optimistic)
#   file_locks.merge.tool: git-merge-file|diff3|custom (default: git-merge-file)
#   file_locks.merge.on_conflict: block|keep_ours|keep_theirs (default: block)
#
# Snapshot Directory:
#   /dev/shm/needle-snapshots/{bead-id}/
#     - {file-hash}.base  - Original file content before edit
#     - files             - List of tracked files (one per line)
#
# Exit Codes (reconcile_optimistic_edits):
#   0 - No conflicts or all conflicts auto-merged
#   1 - Conflicts detected and blocked (bead re-queued)

# ============================================================================
# Snapshot Directory Configuration
# ============================================================================

NEEDLE_SNAPSHOT_DIR="${NEEDLE_SNAPSHOT_DIR:-/dev/shm/needle-snapshots}"

# ============================================================================
# Logging Stubs (if parent modules not loaded)
# ============================================================================

if ! declare -f log_warn &>/dev/null; then
    log_warn()  { echo "[WARN] $*"  >&2; }
fi
if ! declare -f log_error &>/dev/null; then
    log_error() { echo "[ERROR] $*" >&2; }
fi
if ! declare -f log_info &>/dev/null; then
    log_info()  { echo "[INFO] $*"  >&2; }
fi
if ! declare -f log_debug &>/dev/null; then
    log_debug() { [[ "${NEEDLE_VERBOSE:-}" == "true" ]] && echo "[DEBUG] $*" >&2; }
fi

# ============================================================================
# Internal Helpers
# ============================================================================

# Get MD5 hash of a file path (first 8 characters)
# Usage: _needle_optimistic_path_hash <file_path>
_needle_optimistic_path_hash() {
    echo "$1" | md5sum | cut -d' ' -f1 | cut -c1-8
}

# Get snapshot directory for a bead
# Usage: _needle_optimistic_snapshot_dir <bead_id>
_needle_optimistic_snapshot_dir() {
    echo "${NEEDLE_SNAPSHOT_DIR}/$1"
}

# Check if optimistic locking is enabled
# Usage: _needle_optimistic_is_enabled
# Returns: 0 if enabled, 1 if disabled
_needle_optimistic_is_enabled() {
    local strategy
    if declare -f get_config &>/dev/null; then
        strategy=$(get_config "file_locks.strategy" "pessimistic")
    else
        strategy="${NEEDLE_FILE_LOCK_STRATEGY:-pessimistic}"
    fi

    [[ "$strategy" == "optimistic" ]]
}

# Check if merge is enabled for optimistic locking
# Usage: _needle_optimistic_merge_enabled
# Returns: 0 if enabled, 1 if disabled
_needle_optimistic_merge_enabled() {
    local enabled
    if declare -f get_config &>/dev/null; then
        enabled=$(get_config "file_locks.merge.enabled" "true")
    else
        enabled="${NEEDLE_MERGE_ENABLED:-true}"
    fi

    [[ "$enabled" == "true" ]]
}

# Get merge tool configuration
# Usage: _needle_optimistic_get_merge_tool
# Returns: git-merge-file, diff3, or custom
_needle_optimistic_get_merge_tool() {
    if declare -f get_config &>/dev/null; then
        get_config "file_locks.merge.tool" "git-merge-file"
    else
        echo "${NEEDLE_MERGE_TOOL:-git-merge-file}"
    fi
}

# Get conflict resolution strategy
# Usage: _needle_optimistic_get_on_conflict
# Returns: block, keep_ours, or keep_theirs
_needle_optimistic_get_on_conflict() {
    if declare -f get_config &>/dev/null; then
        get_config "file_locks.merge.on_conflict" "block"
    else
        echo "${NEEDLE_MERGE_ON_CONFLICT:-block}"
    fi
}

# Emit an event (stub if telemetry not available)
# Usage: _needle_optimistic_emit_event <event_type> <data_json>
_needle_optimistic_emit_event() {
    local event_type="$1"
    local data_json="$2"

    if declare -f _needle_telemetry_emit &>/dev/null; then
        _needle_telemetry_emit "$event_type" "info" "data=$data_json"
    else
        log_debug "Event: $event_type - $data_json"
    fi
}

# ============================================================================
# Snapshot Functions
# ============================================================================

# Prepare optimistic edit by snapshotting a file
# Creates a copy of the file's current state for later merge comparison
#
# Usage: prepare_optimistic_edit <file_path> <bead_id>
# Arguments:
#   file_path - Absolute path to the file to snapshot
#   bead_id   - The bead ID that will edit this file
# Returns: 0 on success, 1 on failure
prepare_optimistic_edit() {
    local file_path="$1"
    local bead_id="$2"

    if [[ -z "$file_path" ]] || [[ -z "$bead_id" ]]; then
        log_error "prepare_optimistic_edit: file_path and bead_id are required"
        return 1
    fi

    # Create snapshot directory
    local snapshot_dir
    snapshot_dir=$(_needle_optimistic_snapshot_dir "$bead_id")
    mkdir -p "$snapshot_dir" 2>/dev/null || {
        log_error "Failed to create snapshot directory: $snapshot_dir"
        return 1
    }

    # Generate hash for file path
    local path_hash
    path_hash=$(_needle_optimistic_path_hash "$file_path")

    # Snapshot file if it exists
    local base_file="${snapshot_dir}/${path_hash}.base"
    if [[ -f "$file_path" ]]; then
        cp "$file_path" "$base_file" 2>/dev/null || {
            log_error "Failed to snapshot file: $file_path"
            return 1
        }
    else
        # File doesn't exist yet - create empty base
        touch "$base_file" 2>/dev/null || {
            log_error "Failed to create empty base: $base_file"
            return 1
        }
    fi

    # Record file in tracking list
    echo "$file_path" >> "${snapshot_dir}/files"

    log_debug "Snapshot created for $file_path (bead: $bead_id)"
    return 0
}

# Prepare optimistic edits for multiple files
# Usage: prepare_optimistic_edits <bead_id> <file_paths...>
# Arguments:
#   bead_id     - The bead ID
#   file_paths  - Space-separated list of file paths
prepare_optimistic_edits() {
    local bead_id="$1"
    shift

    for file_path in "$@"; do
        prepare_optimistic_edit "$file_path" "$bead_id" || return 1
    done
}

# Clean up snapshots for a bead
# Usage: cleanup_optimistic_snapshots <bead_id>
cleanup_optimistic_snapshots() {
    local bead_id="$1"
    local snapshot_dir
    snapshot_dir=$(_needle_optimistic_snapshot_dir "$bead_id")

    if [[ -d "$snapshot_dir" ]]; then
        rm -rf "$snapshot_dir" 2>/dev/null || {
            log_warn "Failed to clean up snapshots: $snapshot_dir"
            return 1
        }
    fi

    return 0
}

# ============================================================================
# Merge Functions
# ============================================================================

# Perform 3-way merge using git merge-file
# Usage: _needle_merge_git_merge_file <current> <base> <theirs> <result>
# Returns: 0 on clean merge, 1 on conflict
_needle_merge_git_merge_file() {
    local current="$1"
    local base="$2"
    local theirs="$3"
    local result="$4"

    # git merge-file modifies current in place, so we need to work on a copy
    local work_copy
    work_copy=$(mktemp "${TMPDIR:-/tmp}/needle-merge-XXXXXXXX")
    cp "$current" "$work_copy"

    # Run git merge-file
    # Returns 0 on clean merge, non-zero on conflicts
    if git merge-file "$work_copy" "$base" "$theirs" 2>/dev/null; then
        mv "$work_copy" "$result"
        return 0
    else
        rm -f "$work_copy"
        return 1
    fi
}

# Perform 3-way merge using diff3
# Usage: _needle_merge_diff3 <current> <base> <theirs> <result>
# Returns: 0 on clean merge, 1 on conflict
_needle_merge_diff3() {
    local current="$1"
    local base="$2"
    local theirs="$3"
    local result="$4"

    # diff3 -m performs merge and outputs to stdout
    # Returns 0 on success, 1 on conflicts, 2 on error
    if diff3 -m "$current" "$base" "$theirs" > "$result" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Perform 3-way merge using configured tool
# Usage: _needle_perform_merge <current> <base> <theirs> <result>
# Returns: 0 on clean merge, 1 on conflict
_needle_perform_merge() {
    local current="$1"
    local base="$2"
    local theirs="$3"
    local result="$4"

    local merge_tool
    merge_tool=$(_needle_optimistic_get_merge_tool)

    case "$merge_tool" in
        git-merge-file)
            _needle_merge_git_merge_file "$current" "$base" "$theirs" "$result"
            ;;
        diff3)
            _needle_merge_diff3 "$current" "$base" "$theirs" "$result"
            ;;
        custom)
            # For custom tool, look for a custom merge script
            local custom_script="${NEEDLE_HOME:-$HOME/.needle}/hooks/custom-merge.sh"
            if [[ -x "$custom_script" ]]; then
                "$custom_script" "$current" "$base" "$theirs" "$result"
            else
                log_warn "Custom merge tool specified but script not found: $custom_script"
                log_warn "Falling back to git-merge-file"
                _needle_merge_git_merge_file "$current" "$base" "$theirs" "$result"
            fi
            ;;
        *)
            log_warn "Unknown merge tool: $merge_tool, using git-merge-file"
            _needle_merge_git_merge_file "$current" "$base" "$theirs" "$result"
            ;;
    esac
}

# Handle merge conflict based on configured strategy
# Usage: _needle_handle_conflict <file_path> <current> <base> <theirs> <workspace>
# Returns: 0 to continue, 1 to block and re-queue
_needle_handle_conflict() {
    local file_path="$1"
    local current="$2"
    local base="$3"
    local theirs="$4"
    local workspace="$5"

    local on_conflict
    on_conflict=$(_needle_optimistic_get_on_conflict)

    case "$on_conflict" in
        keep_ours)
            # Keep our version (current)
            log_info "Conflict in $file_path: keeping our version (on_conflict=keep_ours)"
            _needle_optimistic_emit_event "file.merge.conflict.resolved" \
                "{\"strategy\":\"keep_ours\",\"path\":\"$file_path\"}"
            return 0
            ;;
        keep_theirs)
            # Use their version (from HEAD)
            cp "$theirs" "$current"
            log_info "Conflict in $file_path: keeping their version (on_conflict=keep_theirs)"
            _needle_optimistic_emit_event "file.merge.conflict.resolved" \
                "{\"strategy\":\"keep_theirs\",\"path\":\"$file_path\"}"
            return 0
            ;;
        block|*)
            # Default: block and re-queue
            log_error "Conflict in $file_path: blocking (on_conflict=block)"
            _needle_optimistic_emit_event "file.merge.conflict" \
                "{\"strategy\":\"block\",\"path\":\"$file_path\"}"
            return 1
            ;;
    esac
}

# ============================================================================
# Main Reconciliation Function
# ============================================================================

# Reconcile optimistic edits after agent execution
# For each tracked file, check if concurrent modification occurred and attempt merge
#
# Usage: reconcile_optimistic_edits <bead_id> [workspace]
# Arguments:
#   bead_id   - The bead ID
#   workspace - The workspace path (defaults to NEEDLE_WORKSPACE or pwd)
#
# Returns:
#   0 - No conflicts or all conflicts resolved
#   1 - Conflicts detected and blocked (bead should be re-queued)
#
# Side effects:
#   - On clean merge: Updates file with merged content
#   - On conflict with block: Restores file, adds dependency, requires re-queue
#   - Cleans up snapshot directory on completion
reconcile_optimistic_edits() {
    local bead_id="$1"
    local workspace="${2:-${NEEDLE_WORKSPACE:-$(pwd)}}"

    if [[ -z "$bead_id" ]]; then
        log_error "reconcile_optimistic_edits: bead_id is required"
        return 0
    fi

    local snapshot_dir
    snapshot_dir=$(_needle_optimistic_snapshot_dir "$bead_id")

    # No snapshots exist for this bead
    if [[ ! -d "$snapshot_dir" ]]; then
        log_debug "No snapshots found for bead: $bead_id"
        return 0
    fi

    local files_list="${snapshot_dir}/files"
    if [[ ! -f "$files_list" ]]; then
        log_debug "No tracked files for bead: $bead_id"
        cleanup_optimistic_snapshots "$bead_id"
        return 0
    fi

    log_info "Reconciling optimistic edits for bead: $bead_id"

    local conflicts=0
    local merges=0
    local checked=0

    while IFS= read -r file_path; do
        [[ -z "$file_path" ]] && continue

        local path_hash
        path_hash=$(_needle_optimistic_path_hash "$file_path")
        local base_file="${snapshot_dir}/${path_hash}.base"

        # Skip if base snapshot is missing
        if [[ ! -f "$base_file" ]]; then
            log_warn "Missing base snapshot for: $file_path"
            continue
        fi

        ((checked++)) || true

        # Get relative path for git operations
        local rel_path="${file_path#$workspace/}"

        # Get current HEAD version (what others may have committed)
        local head_content
        if [[ -f "$file_path" ]] && git -C "$workspace" rev-parse --git-dir &>/dev/null; then
            head_content=$(git -C "$workspace" show "HEAD:$rel_path" 2>/dev/null || echo "")
        else
            head_content=""
        fi

        # Read our base snapshot
        local base_content
        base_content=$(cat "$base_file" 2>/dev/null || echo "")

        # Check if file was modified by another bead since we started
        if [[ "$head_content" == "$base_content" ]]; then
            # No concurrent modification - our edits are safe
            log_debug "No concurrent modification for: $file_path"
            continue
        fi

        # Concurrent modification detected!
        log_info "Concurrent modification detected for: $file_path"

        # Check if merge is enabled
        if ! _needle_optimistic_merge_enabled; then
            log_warn "Merge disabled, treating as conflict"
            _needle_optimistic_emit_event "file.merge.skipped" \
                "{\"path\":\"$file_path\",\"reason\":\"merge_disabled\"}"

            # Restore to HEAD and count as conflict
            if [[ -n "$head_content" ]]; then
                echo "$head_content" > "$file_path"
            else
                git -C "$workspace" checkout HEAD -- "$rel_path" 2>/dev/null || true
            fi

            ((conflicts++)) || true
            continue
        fi

        # Prepare files for 3-way merge
        local current_file="$file_path"
        local theirs_file
        theirs_file=$(mktemp "${TMPDIR:-/tmp}/needle-theirs-XXXXXXXX")
        local result_file
        result_file=$(mktemp "${TMPDIR:-/tmp}/needle-result-XXXXXXXX")

        # Write HEAD content to "theirs" file
        echo "$head_content" > "$theirs_file"

        # Copy current state to result (merge will update it)
        cp "$current_file" "$result_file"

        # Attempt merge
        if _needle_perform_merge "$current_file" "$base_file" "$theirs_file" "$result_file"; then
            # Clean merge!
            mv "$result_file" "$current_file"
            log_info "Auto-merged concurrent edits to: $file_path"
            _needle_optimistic_emit_event "file.merge.success" \
                "{\"bead\":\"$bead_id\",\"path\":\"$file_path\"}"
            ((merges++)) || true
        else
            # Merge conflict
            rm -f "$result_file"

            if ! _needle_handle_conflict "$file_path" "$current_file" "$base_file" "$theirs_file" "$workspace"; then
                # Restore to HEAD
                git -C "$workspace" checkout HEAD -- "$rel_path" 2>/dev/null || true
                ((conflicts++)) || true
            fi
        fi

        # Clean up temp files
        rm -f "$theirs_file" "$result_file"

    done < "$files_list"

    # Clean up snapshots
    cleanup_optimistic_snapshots "$bead_id"

    # Summary
    log_info "Reconciliation complete: checked=$checked merges=$merges conflicts=$conflicts"

    # Handle conflicts
    if (( conflicts > 0 )); then
        log_error "Optimistic lock conflicts detected: $conflicts file(s)"

        # Re-queue the bead so it runs after blockers complete
        if command -v br &>/dev/null; then
            br update "$bead_id" --status open 2>/dev/null || true
        fi

        return 1
    fi

    return 0
}

# ============================================================================
# Utility Functions
# ============================================================================

# List all snapshots for a bead
# Usage: list_optimistic_snapshots <bead_id>
# Returns: List of tracked file paths
list_optimistic_snapshots() {
    local bead_id="$1"
    local snapshot_dir
    snapshot_dir=$(_needle_optimistic_snapshot_dir "$bead_id")
    local files_list="${snapshot_dir}/files"

    if [[ -f "$files_list" ]]; then
        cat "$files_list"
    fi
}

# Check if a bead has snapshots
# Usage: has_optimistic_snapshots <bead_id>
# Returns: 0 if snapshots exist, 1 if not
has_optimistic_snapshots() {
    local bead_id="$1"
    local snapshot_dir
    snapshot_dir=$(_needle_optimistic_snapshot_dir "$bead_id")
    [[ -d "$snapshot_dir" ]] && [[ -f "${snapshot_dir}/files" ]]
}

# Get the base snapshot content for a file
# Usage: get_optimistic_base <bead_id> <file_path>
# Returns: File content (or empty if not found)
get_optimistic_base() {
    local bead_id="$1"
    local file_path="$2"
    local snapshot_dir
    snapshot_dir=$(_needle_optimistic_snapshot_dir "$bead_id")
    local path_hash
    path_hash=$(_needle_optimistic_path_hash "$file_path")
    local base_file="${snapshot_dir}/${path_hash}.base"

    if [[ -f "$base_file" ]]; then
        cat "$base_file"
    fi
}
