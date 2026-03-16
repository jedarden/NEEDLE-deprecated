#!/usr/bin/env bash
# NEEDLE CLI Workspace Configuration Loader
# Load, merge, and cache workspace-level configuration with global config

# Workspace config cache (associative array for multiple workspaces)
declare -A _NEEDLE_WORKSPACE_CACHE

# Find workspace root directory (where .needle.yaml might be)
# Looks for .needle.yaml starting from given directory and walking up to /
# Usage: _needle_find_workspace_root [start_dir]
# Returns: path to workspace root or empty string
_needle_find_workspace_root() {
    local start_dir="${1:-$(pwd)}"
    local current_dir

    # Resolve to absolute path
    current_dir="$(cd "$start_dir" 2>/dev/null && pwd)" || return 1

    # Walk up directory tree looking for .needle.yaml
    while [[ -n "$current_dir" ]] && [[ "$current_dir" != "/" ]]; do
        if [[ -f "$current_dir/.needle.yaml" ]]; then
            echo "$current_dir"
            return 0
        fi

        # Move to parent directory
        current_dir="$(dirname "$current_dir")"
    done

    # No workspace config found
    return 1
}

# Check if yq is available
_needle_workspace_has_yq() {
    command -v yq &>/dev/null
}

# Merge two YAML configs using Python
# Usage: _needle_merge_yaml_python <base_file> <override_file>
# Returns: merged YAML content
_needle_merge_yaml_python() {
    local base_file="$1"
    local override_file="$2"

    python3 -c "
import yaml
import sys

def deep_merge(base, override):
    '''Deep merge two dictionaries, with override taking precedence'''
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override

    result = base.copy()
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result

try:
    with open('$base_file', 'r') as f:
        base = yaml.safe_load(f) or {}

    with open('$override_file', 'r') as f:
        override = yaml.safe_load(f) or {}

    merged = deep_merge(base, override)
    yaml.dump(merged, sys.stdout, default_flow_style=False, sort_keys=False)
except Exception as e:
    print(f'Error merging configs: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# Parse YAML using Python
# Usage: _needle_parse_workspace_yaml_python <content> <path>
_needle_parse_workspace_yaml_python() {
    local content="$1"
    local path="$2"

    echo "$content" | python3 -c "
import yaml
import sys
import json

def get_value(data, path):
    '''Get value from nested dict using dot-notation path'''
    if not path or path == '.':
        return data

    # Convert yq-style path to keys
    keys = path.lstrip('.').split('.')
    current = data

    for key in keys:
        if current is None:
            return None
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            return None

    return current

try:
    data = yaml.safe_load(sys.stdin)
    if data is None:
        print('null')
        sys.exit(0)

    value = get_value(data, '$path')

    if value is None:
        print('null')
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    elif isinstance(value, bool):
        print('true' if value else 'false')
    else:
        print(value)
except Exception as e:
    print('null', file=sys.stdout)
    sys.exit(1)
" 2>/dev/null
}

# Load and merge workspace configuration with global config
# Workspace config overrides global settings
# Usage: load_workspace_config [workspace_path]
# Returns: merged configuration in YAML format
load_workspace_config() {
    local workspace="${1:-$(pwd)}"
    local ws_config
    local global_config="${NEEDLE_HOME:-$HOME/.needle}/config.yaml"
    local cache_key
    local merged_config

    # Resolve workspace to absolute path
    workspace="$(cd "$workspace" 2>/dev/null && pwd)" || {
        _needle_error "Invalid workspace path: $1"
        return 1
    }

    # Create cache key from workspace path
    cache_key="$workspace"

    # Check cache first
    if [[ -n "${_NEEDLE_WORKSPACE_CACHE[$cache_key]:-}" ]]; then
        echo "${_NEEDLE_WORKSPACE_CACHE[$cache_key]}"
        return 0
    fi

    # Find workspace config (look for .needle.yaml in workspace root)
    ws_config="$workspace/.needle.yaml"

    # If no workspace config, try to find it by walking up
    if [[ ! -f "$ws_config" ]]; then
        local found_root
        found_root=$(_needle_find_workspace_root "$workspace" 2>/dev/null)
        if [[ -n "$found_root" ]]; then
            ws_config="$found_root/.needle.yaml"
        fi
    fi

    # Check if global config exists
    if [[ ! -f "$global_config" ]]; then
        # No global config
        if [[ -f "$ws_config" ]]; then
            # Use workspace config only
            merged_config=$(cat "$ws_config")
        else
            # No config at all, return defaults
            merged_config="$_NEEDLE_CONFIG_DEFAULTS"
        fi
    else
        # Global config exists
        if [[ ! -f "$ws_config" ]]; then
            # No workspace config, use global
            merged_config=$(cat "$global_config")
        else
            # Both configs exist - merge them
            # Use Python for merging (more reliable than yq)
            merged_config=$(_needle_merge_yaml_python "$global_config" "$ws_config" 2>/dev/null)
            if [[ $? -ne 0 ]] || [[ -z "$merged_config" ]]; then
                _needle_warn "Workspace config merge failed, using workspace config"
                merged_config=$(cat "$ws_config")
            fi
        fi
    fi

    # Cache the result
    _NEEDLE_WORKSPACE_CACHE[$cache_key]="$merged_config"

    echo "$merged_config"
}

# Get a specific setting from workspace configuration
# Falls back to default value if key not found
# Usage: get_workspace_setting <workspace> <key> [default]
# Example: get_workspace_setting "/home/user/project" "limits.max_concurrent" "10"
get_workspace_setting() {
    local workspace="$1"
    local key="$2"
    local default="${3:-}"
    local config
    local value

    # Load merged config
    config=$(load_workspace_config "$workspace") || {
        echo "$default"
        return 0
    }

    # Extract value using Python YAML parser
    if command -v python3 &>/dev/null; then
        value=$(_needle_parse_workspace_yaml_python "$config" "$key" 2>/dev/null)
    elif _needle_workspace_has_yq; then
        value=$(echo "$config" | yq ".$key" 2>/dev/null)
    elif command -v jq &>/dev/null; then
        # Try to parse as JSON
        value=$(echo "$config" | jq -r ".$key" 2>/dev/null)
    else
        # Basic fallback extraction
        value=$(_needle_config_extract_value "$config" "$key")
    fi

    # Handle null/empty values - return default
    if [[ "$value" == "null" ]] || [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Get workspace setting as integer
# Usage: get_workspace_setting_int <workspace> <key> [default]
get_workspace_setting_int() {
    local value
    value=$(get_workspace_setting "$1" "$2" "$3")
    # Extract numeric part only
    echo "${value//[^0-9-]/}"
}

# Get workspace setting as boolean
# Usage: get_workspace_setting_bool <workspace> <key> [default]
get_workspace_setting_bool() {
    local value
    value=$(get_workspace_setting "$1" "$2" "$3")
    case "$value" in
        true|True|TRUE|yes|Yes|YES|1) echo "true" ;;
        false|False|FALSE|no|No|NO|0) echo "false" ;;
        *) echo "${3:-false}" ;;
    esac
}

# Basic value extraction fallback (without Python/yq/jq)
# Usage: _needle_config_extract_value <config_content> <key>
# Key format: dot.notation like "limits.max_concurrent"
_needle_config_extract_value() {
    local config="$1"
    local key="$2"
    local key_parts
    local current_value="$config"
    local part

    # Split key by dots
    IFS='.' read -ra key_parts <<< "$key"

    # Navigate through nested structure (simplified YAML)
    for part in "${key_parts[@]}"; do
        # Try to find the key in current content
        # Look for patterns like "key: value"
        local pattern="^[[:space:]]*${part}[[:space:]]*:[[:space:]]*"
        local match

        match=$(echo "$current_value" | grep -E "$pattern" | head -1)

        if [[ -n "$match" ]]; then
            # Extract value after colon
            current_value="${match#*:}"
            # Trim whitespace
            current_value="${current_value#"${current_value%%[![:space:]]*}"}"
            current_value="${current_value%"${current_value##*[![:space:]]}"}"
            # Remove trailing comma
            current_value="${current_value%,}"
            # Remove quotes if present
            current_value="${current_value#\"}"
            current_value="${current_value%\"}"
        else
            echo "null"
            return 1
        fi
    done

    echo "$current_value"
}

# Check if workspace has a local configuration file
# Usage: has_workspace_config [workspace_path]
# Returns: 0 if workspace config exists, 1 otherwise
has_workspace_config() {
    local workspace="${1:-$(pwd)}"
    local ws_config

    # Resolve to absolute path
    workspace="$(cd "$workspace" 2>/dev/null && pwd)" || return 1

    # Check for .needle.yaml directly
    ws_config="$workspace/.needle.yaml"
    if [[ -f "$ws_config" ]]; then
        return 0
    fi

    # Try walking up to find it
    local found_root
    found_root=$(_needle_find_workspace_root "$workspace" 2>/dev/null)
    [[ -n "$found_root" ]]
}

# Get the path to the workspace config file
# Usage: get_workspace_config_path [workspace_path]
# Returns: path to .needle.yaml or empty string
get_workspace_config_path() {
    local workspace="${1:-$(pwd)}"
    local ws_config

    # Resolve to absolute path
    workspace="$(cd "$workspace" 2>/dev/null && pwd)" || return 1

    # Check for .needle.yaml directly
    ws_config="$workspace/.needle.yaml"
    if [[ -f "$ws_config" ]]; then
        echo "$ws_config"
        return 0
    fi

    # Try walking up to find it
    local found_root
    found_root=$(_needle_find_workspace_root "$workspace" 2>/dev/null)
    if [[ -n "$found_root" ]]; then
        echo "$found_root/.needle.yaml"
        return 0
    fi

    return 1
}

# Clear workspace config cache for a specific workspace or all
# Usage: clear_workspace_cache [workspace_path]
clear_workspace_cache() {
    local workspace="${1:-}"

    if [[ -n "$workspace" ]]; then
        local cache_key
        workspace="$(cd "$workspace" 2>/dev/null && pwd)" || return 1
        cache_key="$workspace"
        unset "_NEEDLE_WORKSPACE_CACHE[$cache_key]"
    else
        # Clear all cached workspace configs
        _NEEDLE_WORKSPACE_CACHE=()
    fi
}

# Reload workspace configuration (clear cache and reload)
# Usage: reload_workspace_config [workspace_path]
reload_workspace_config() {
    local workspace="${1:-$(pwd)}"
    clear_workspace_cache "$workspace"
    load_workspace_config "$workspace"
}

# List all cached workspaces
# Usage: list_cached_workspaces
list_cached_workspaces() {
    local workspace
    for workspace in "${!_NEEDLE_WORKSPACE_CACHE[@]}"; do
        echo "$workspace"
    done
}

# ============================================================================
# Workspace Discovery (for auto-selection when --workspace is omitted)
# ============================================================================

# Discovery scan cache: timestamp of last scan + cached result
_NEEDLE_DISCOVERY_CACHE_TIMESTAMP=0
_NEEDLE_DISCOVERY_CACHE_RESULT=""

# Discover all workspaces with .beads directories
# Scans from root for directories containing .beads/, no maxdepth by default
# (can be constrained via discovery.max_depth config or NEEDLE_DISCOVER_MAX_DEPTH env)
# Usage: _needle_discover_all_workspaces [search_root]
# Returns: List of workspace paths (one per line)
_needle_discover_all_workspaces() {
    local search_root="${1:-$HOME}"

    # Check config for optional max depth override (default: unlimited)
    local max_depth
    max_depth=$(get_config "discovery.max_depth" "${NEEDLE_DISCOVER_MAX_DEPTH:-}")
    local find_args=(-name ".beads" -type d
        -not -path "*/node_modules/*"
        -not -path "*/.git/*"
        -not -path "*/vendor/*"
        -not -path "*/.cache/*"
        -not -path "*/.local/*"
        -not -path "*/.npm/*"
        -not -path "*/.cargo/*"
        -not -path "*/.nvm/*"
        -not -path "*/.rustup/*"
    )

    if [[ -n "$max_depth" ]] && [[ "$max_depth" =~ ^[0-9]+$ ]]; then
        find_args=(-maxdepth "$max_depth" "${find_args[@]}")
    fi

    find "$search_root" "${find_args[@]}" 2>/dev/null | while IFS= read -r beads_dir; do
        [[ -z "$beads_dir" ]] && continue
        dirname "$beads_dir"
    done
}

# Count open beads in a workspace
# Usage: _needle_workspace_bead_count <workspace_path>
# Returns: Number of open beads (0 if none or invalid)
_needle_workspace_bead_count() {
    local workspace="$1"

    if [[ ! -d "$workspace/.beads" ]]; then
        echo "0"
        return 0
    fi

    local count
    count=$(cd "$workspace" && br list --status open --json 2>/dev/null | jq 'length' 2>/dev/null)

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
        return 0
    fi

    # Fallback: JSONL-only mode (corrupted SQLite)
    count=$(cd "$workspace" && br list --status open --no-db --json 2>/dev/null | jq 'length' 2>/dev/null)

    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 0
    fi

    echo "$count"
}

# Get the most recently created open bead's timestamp in a workspace
# Usage: _needle_workspace_freshest_time <workspace_path>
# Returns: Unix timestamp of most recently created open bead (0 if none)
_needle_workspace_freshest_time() {
    local workspace="$1"

    if [[ ! -d "$workspace/.beads" ]]; then
        echo "0"
        return 0
    fi

    # Get the most recently created open bead's created_at timestamp
    local freshest
    freshest=$(cd "$workspace" && br list --status open --json --limit 1 --sort created_at --reverse 2>/dev/null | \
        jq -r '.[0].created_at // empty' 2>/dev/null)

    if [[ -z "$freshest" ]]; then
        # Fallback: JSONL-only mode
        freshest=$(cd "$workspace" && br list --status open --no-db --json --limit 1 --sort created_at --reverse 2>/dev/null | \
            jq -r '.[0].created_at // empty' 2>/dev/null)
    fi

    if [[ -z "$freshest" ]]; then
        echo "0"
        return 0
    fi

    # Convert ISO timestamp to unix epoch
    date -d "$freshest" +%s 2>/dev/null || echo "0"
}

# Check if any active NEEDLE worker is assigned to a workspace
# A heartbeat is "active" if its last_heartbeat is within the timeout window
# Usage: _needle_workspace_has_active_worker <workspace_path>
# Returns: 0 if an active worker is assigned, 1 otherwise
_needle_workspace_has_active_worker() {
    local workspace="$1"
    local heartbeat_dir="${NEEDLE_HOME:-$HOME/.needle}/state/heartbeats"

    if [[ ! -d "$heartbeat_dir" ]]; then
        return 1
    fi

    # Get heartbeat timeout from config (default: 120s)
    local timeout
    timeout=$(get_config_int "watchdog.heartbeat_timeout" "120")
    local cutoff
    cutoff=$(date -d "$((${timeout%%[!0-9]*})) seconds ago" -u +%s 2>/dev/null)
    [[ -z "$cutoff" ]] && cutoff=0

    local hb_file
    for hb_file in "$heartbeat_dir"/*.json; do
        [[ -f "$hb_file" ]] || continue

        # Extract workspace and last_heartbeat from heartbeat JSON
        local hb_workspace hb_last
        hb_workspace=$(jq -r '.workspace // empty' "$hb_file" 2>/dev/null)
        hb_last=$(jq -r '.last_heartbeat // empty' "$hb_file" 2>/dev/null)

        [[ -z "$hb_workspace" ]] && continue
        [[ -z "$hb_last" ]] && continue

        # Resolve both paths for comparison
        # Normalize workspace path (heartbeat may store trailing slash or not)
        local norm_ws norm_hb
        norm_ws=$(cd "$workspace" 2>/dev/null && pwd)
        norm_hb=$(cd "$hb_workspace" 2>/dev/null && pwd)
        [[ -z "$norm_ws" ]] && continue
        [[ "$norm_ws" != "$norm_hb" ]] && continue

        # Check if heartbeat is fresh
        local hb_epoch
        hb_epoch=$(date -d "$hb_last" +%s 2>/dev/null)
        [[ -z "$hb_epoch" ]] && continue
        [[ "$hb_epoch" -ge "$cutoff" ]] && return 0
    done

    return 1
}

# Discover the best workspace to run in when --workspace is omitted.
#
# Selection logic:
#   1. Scan for .beads/ directories under root (default $HOME or discovery.root config)
#   2. For each workspace, get freshest open bead timestamp and open bead count
#   3. Check heartbeats to see if any active worker is already assigned
#   4. Return workspace with freshest unserviced bead (no active worker)
#   5. If all workspaces have active workers, return the one with most open beads (work-stealing)
#   6. If no workspaces have open beads, return empty (caller handles error)
#
# Results are cached for 60s to avoid repeated filesystem scans.
#
# Usage: _needle_discover_workspace [--root <path>] [--all]
# Returns: workspace path on stdout (one per line if --all), exit 0 on success, exit 1 if none found
_needle_discover_workspace() {
    local root=""
    local show_all=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)
                root="${2:?--root requires a path}"
                shift 2
                ;;
            --all)
                show_all=true
                shift
                ;;
            *)
                _needle_warn "Unknown argument to _needle_discover_workspace: $1"
                shift
                ;;
        esac
    done

    # Resolve search root: explicit arg > config > $HOME
    if [[ -z "$root" ]]; then
        root=$(get_config "discovery.root" "$HOME")
    fi
    root="$(cd "$root" 2>/dev/null && pwd)" || {
        _needle_error "Discovery root not found: $root"
        return 1
    }

    # Check cache (60s TTL)
    local now
    now=$(date +%s)
    local cache_ttl=60
    if [[ $((now - _NEEDLE_DISCOVERY_CACHE_TIMESTAMP)) -lt "$cache_ttl" ]] && \
       [[ -n "$_NEEDLE_DISCOVERY_CACHE_RESULT" ]]; then
        if $show_all; then
            echo "$_NEEDLE_DISCOVERY_CACHE_RESULT"
            return 0
        else
            echo "$_NEEDLE_DISCOVERY_CACHE_RESULT" | head -1
            [[ -n "$(echo "$_NEEDLE_DISCOVERY_CACHE_RESULT" | head -1)" ]]
            return $?
        fi
    fi

    # Phase 1: Gather workspace metadata
    # Format: "timestamp|count|has_worker|workspace"
    local candidates=()
    while IFS= read -r workspace; do
        [[ -z "$workspace" ]] && continue

        local count freshness has_worker
        count=$(_needle_workspace_bead_count "$workspace")

        # Skip workspaces with no open beads
        [[ "$count" -eq 0 ]] && continue

        freshness=$(_needle_workspace_freshest_time "$workspace")

        if _needle_workspace_has_active_worker "$workspace"; then
            has_worker=1
        else
            has_worker=0
        fi

        candidates+=("$freshness|$count|$has_worker|$workspace")
    done < <(_needle_discover_all_workspaces "$root")

    # No workspaces with open beads
    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    fi

    # Phase 2: Rank workspaces
    # Priority 1: unserviced workspaces (has_worker=0), sorted by freshest bead desc
    # Priority 2: all-serviced workspaces, sorted by open bead count desc (work-stealing)
    local unserviced=()
    local serviced=()
    local entry
    for entry in "${candidates[@]}"; do
        local has_worker="${entry#*|}"; has_worker="${has_worker%%|*}"
        if [[ "$has_worker" -eq 0 ]]; then
            unserviced+=("$entry")
        else
            serviced+=("$entry")
        fi
    done

    local ranked=()
    if [[ ${#unserviced[@]} -gt 0 ]]; then
        # Sort unserviced by freshness desc (field 0), then by count desc (field 1)
        while IFS= read -r line; do
            [[ -n "$line" ]] && ranked+=("$line")
        done < <(printf '%s\n' "${unserviced[@]}" | sort -t'|' -k1 -nr -k2 -nr)
    else
        # All workspaces have active workers — work-stealing: sort by count desc
        while IFS= read -r line; do
            [[ -n "$line" ]] && ranked+=("$line")
        done < <(printf '%s\n' "${serviced[@]}" | sort -t'|' -k2 -nr)
    fi

    # Extract workspace paths from ranked entries
    local result=()
    for entry in "${ranked[@]}"; do
        result+=("${entry##*|}")
    done

    # Cache the result
    _NEEDLE_DISCOVERY_CACHE_TIMESTAMP="$now"
    _NEEDLE_DISCOVERY_CACHE_RESULT=$(printf '%s\n' "${result[@]}")

    # Output
    if $show_all; then
        printf '%s\n' "${result[@]}"
        return 0
    else
        echo "${result[0]}"
        return 0
    fi
}

# Discover top-N workspaces with the most open beads for round-robin distribution.
# Usage: _needle_discover_top_workspaces <count> [search_root]
# Returns: List of workspace paths (one per line), sorted by bead count desc
_needle_discover_top_workspaces() {
    local count="${1:-3}"
    local search_root="${2:-$HOME}"

    # Build list of workspace:count pairs, sort by count desc, take top N
    local workspaces=()
    while IFS= read -r workspace; do
        [[ -z "$workspace" ]] && continue

        local ws_count
        ws_count=$(_needle_workspace_bead_count "$workspace")

        [[ "$ws_count" -eq 0 ]] && continue

        workspaces+=("$ws_count:$workspace")
    done < <(_needle_discover_all_workspaces "$search_root")

    # Sort by count (descending) and extract workspace paths
    if [[ ${#workspaces[@]} -gt 0 ]]; then
        printf '%s\n' "${workspaces[@]}" | \
            sort -t: -k1 -nr | \
            head -n "$count" | \
            cut -d: -f2-
    fi
}
