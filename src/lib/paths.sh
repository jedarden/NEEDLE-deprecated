#!/usr/bin/env bash
# NEEDLE CLI Path Utilities
# Directory creation and PATH management

# Ensure NEEDLE directory structure exists
_needle_ensure_dirs() {
    mkdir -p "$NEEDLE_HOME"
    mkdir -p "$NEEDLE_HOME/$NEEDLE_STATE_DIR"
    mkdir -p "$NEEDLE_HOME/$NEEDLE_CACHE_DIR"
    mkdir -p "$NEEDLE_HOME/$NEEDLE_LOG_DIR"
}

# Add directory to PATH (if not already present)
# Usage: _needle_add_to_path <directory> [position]
# Position can be: "front", "back", or "after:<dir>"
# Default is "front"
_needle_add_to_path() {
    local dir="$1"
    local position="${2:-front}"

    # Validate directory exists
    if [[ ! -d "$dir" ]]; then
        _needle_warn "Directory does not exist, skipping PATH add: $dir"
        return 1
    fi

    # Check if already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        return 0
    fi

    case "$position" in
        front)
            export PATH="$dir:$PATH"
            ;;
        back|end)
            export PATH="$PATH:$dir"
            ;;
        after:*)
            local after_dir="${position#after:}"
            if [[ ":$PATH:" == *":$after_dir:"* ]]; then
                # Insert after the specified directory
                export PATH="${PATH//$after_dir:/$after_dir:$dir:}"
            else
                # Fallback to front if target not found
                export PATH="$dir:$PATH"
            fi
            ;;
        *)
            _needle_warn "Unknown position '$position', defaulting to front"
            export PATH="$dir:$PATH"
            ;;
    esac

    return 0
}

# Remove directory from PATH
# Usage: _needle_remove_from_path <directory>
_needle_remove_from_path() {
    local dir="$1"

    # Remove from PATH using parameter expansion
    export PATH="${PATH//$dir:/}"
    export PATH="${PATH/:$dir/}"
}

# Check if directory is in PATH
# Usage: _needle_in_path <directory>
_needle_in_path() {
    local dir="$1"
    [[ ":$PATH:" == *":$dir:"* ]]
}

# Get NEEDLE home directory (with optional subdirectory)
# Usage: _needle_home_path [subdirectory]
_needle_home_path() {
    local subdir="${1:-}"
    if [[ -n "$subdir" ]]; then
        echo "$NEEDLE_HOME/$subdir"
    else
        echo "$NEEDLE_HOME"
    fi
}

# Get full path to a state file
# Usage: _needle_state_path <filename>
_needle_state_path() {
    echo "$NEEDLE_HOME/$NEEDLE_STATE_DIR/$1"
}

# Get full path to a cache file
# Usage: _needle_cache_path <filename>
_needle_cache_path() {
    echo "$NEEDLE_HOME/$NEEDLE_CACHE_DIR/$1"
}

# Get full path to a log file
# Usage: _needle_log_path <filename>
_needle_log_path() {
    echo "$NEEDLE_HOME/$NEEDLE_LOG_DIR/$1"
}

# Clean old cache files (older than N days)
# Usage: _needle_clean_cache [days]
_needle_clean_cache() {
    local days="${1:-7}"
    local cache_dir="$NEEDLE_HOME/$NEEDLE_CACHE_DIR"

    if [[ -d "$cache_dir" ]]; then
        find "$cache_dir" -type f -mtime +$days -delete 2>/dev/null || true
    fi
}

# Clean old log files (older than N days)
# Usage: _needle_clean_logs [days]
_needle_clean_logs() {
    local days="${1:-30}"
    local log_dir="$NEEDLE_HOME/$NEEDLE_LOG_DIR"

    if [[ -d "$log_dir" ]]; then
        find "$log_dir" -type f -mtime +$days -delete 2>/dev/null || true
    fi
}
