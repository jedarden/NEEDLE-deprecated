#!/usr/bin/env bash
# NEEDLE CLI Version Subcommand
# Display version information for needle and all dependencies

_needle_version_help() {
    _needle_print "Show NEEDLE version information

Displays the installed NEEDLE version along with dependency
and agent status.

USAGE:
    needle version [OPTIONS]

OPTIONS:
    -j, --json       Output in JSON format
    -s, --short      Output short version string only
    -h, --help       Show this help message

EXAMPLES:
    # Show full version info
    needle version

    # Show just version number
    needle version --short

    # Output as JSON for scripting
    needle version --json
"
}

# Check a dependency and return version string
# Usage: _needle_check_dep_version <command> [version_flag]
_needle_check_dep_version() {
    local cmd="$1"
    local version_flag="${2:---version}"

    if ! command -v "$cmd" &>/dev/null; then
        echo "-"
        return 1
    fi

    local version
    version=$("$cmd" $version_flag 2>&1 | head -1) || {
        echo "unknown"
        return 0
    }

    # Clean up version string
    version=$(echo "$version" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    echo "${version:-unknown}"
    return 0
}

# Get the number of log sessions (distinct log file prefixes)
_needle_count_log_sessions() {
    local log_dir="$NEEDLE_HOME/$NEEDLE_LOG_DIR"

    if [[ ! -d "$log_dir" ]]; then
        echo "0"
        return 0
    fi

    # Count unique session prefixes (date-based or numbered sessions)
    local count
    count=$(find "$log_dir" -type f -name "*.log" 2>/dev/null | wc -l)
    echo "$count"
}

# Output version as human-readable text
_needle_version_text() {
    local repo_url="https://github.com/anthropics/needle"

    _needle_print ""
    _needle_print_color "$NEEDLE_COLOR_BOLD$NEEDLE_COLOR_MAGENTA" "NEEDLE v$NEEDLE_VERSION"
    _needle_print_color "$NEEDLE_COLOR_DIM" "  $repo_url"
    _needle_print ""

    # Dependencies section
    _needle_section "Dependencies:"

    # tmux
    local tmux_ver
    tmux_ver=$(_needle_check_dep_version "tmux")
    if [[ "$tmux_ver" != "-" ]]; then
        printf "  %-12s %-8s %s\n" "tmux" "$tmux_ver" "${NEEDLE_COLOR_GREEN}✓ installed${NEEDLE_COLOR_RESET}"
    else
        printf "  %-12s %-8s %s\n" "tmux" "-" "${NEEDLE_COLOR_RED}✗ not found${NEEDLE_COLOR_RESET}"
    fi

    # jq
    local jq_ver
    jq_ver=$(_needle_check_dep_version "jq")
    if [[ "$jq_ver" != "-" ]]; then
        printf "  %-12s %-8s %s\n" "jq" "$jq_ver" "${NEEDLE_COLOR_GREEN}✓ installed${NEEDLE_COLOR_RESET}"
    else
        printf "  %-12s %-8s %s\n" "jq" "-" "${NEEDLE_COLOR_RED}✗ not found${NEEDLE_COLOR_RESET}"
    fi

    # yq
    local yq_ver
    yq_ver=$(_needle_check_dep_version "yq")
    if [[ "$yq_ver" != "-" ]]; then
        printf "  %-12s %-8s %s\n" "yq" "$yq_ver" "${NEEDLE_COLOR_GREEN}✓ installed${NEEDLE_COLOR_RESET}"
    else
        printf "  %-12s %-8s %s\n" "yq" "-" "${NEEDLE_COLOR_RED}✗ not found${NEEDLE_COLOR_RESET}"
    fi

    # br (bead runner)
    local br_ver
    br_ver=$(_needle_check_dep_version "br")
    if [[ "$br_ver" != "-" ]]; then
        printf "  %-12s %-8s %s\n" "br" "$br_ver" "${NEEDLE_COLOR_GREEN}✓ installed${NEEDLE_COLOR_RESET}"
    else
        printf "  %-12s %-8s %s\n" "br" "-" "${NEEDLE_COLOR_RED}✗ not found${NEEDLE_COLOR_RESET}"
    fi

    _needle_print ""

    # Agents section
    _needle_section "Agents:"

    local agent_order=("claude" "opencode" "codex" "aider")

    for agent in "${agent_order[@]}"; do
        local cmd="${NEEDLE_AGENT_CMDS[$agent]:-$agent}"
        local name="${NEEDLE_AGENT_NAMES[$agent]:-$agent}"
        local display_name="${agent}"

        if command -v "$cmd" &>/dev/null; then
            local version
            version=$(_needle_agent_version "$agent" 2>/dev/null)

            # Check auth status
            local auth
            auth=$(_needle_agent_auth_status "$agent" 2>/dev/null)

            if [[ "$auth" == "authenticated" ]]; then
                printf "  %-12s %-8s %s\n" "$display_name" "${version:-unknown}" "${NEEDLE_COLOR_GREEN}✓ available (logged in)${NEEDLE_COLOR_RESET}"
            else
                printf "  %-12s %-8s %s\n" "$display_name" "${version:-unknown}" "${NEEDLE_COLOR_YELLOW}✓ available${NEEDLE_COLOR_RESET}"
            fi
        else
            printf "  %-12s %-8s %s\n" "$display_name" "-" "${NEEDLE_COLOR_RED}✗ not found${NEEDLE_COLOR_RESET}"
        fi
    done

    _needle_print ""

    # Paths section
    _needle_section "Paths:"

    # Config path
    local config_status="not found"
    if [[ -f "$NEEDLE_CONFIG_FILE" ]]; then
        config_status="exists"
    fi
    printf "  %-12s %s (%s)\n" "Config:" "$NEEDLE_CONFIG_FILE" "$config_status"

    # Logs path
    local log_sessions
    log_sessions=$(_needle_count_log_sessions)
    printf "  %-12s %s (%s sessions)\n" "Logs:" "$NEEDLE_HOME/$NEEDLE_LOG_DIR" "$log_sessions"

    _needle_print ""
}

# Output version as JSON
_needle_version_json() {
    local repo_url="https://github.com/anthropics/needle"

    # Start JSON object
    echo "{"

    # Needle version info
    echo "  \"needle\": {"
    echo "    \"version\": \"$NEEDLE_VERSION\","
    echo "    \"major\": $NEEDLE_VERSION_MAJOR,"
    echo "    \"minor\": $NEEDLE_VERSION_MINOR,"
    echo "    \"patch\": $NEEDLE_VERSION_PATCH,"
    echo "    \"repo\": \"$repo_url\""
    echo "  },"

    # Dependencies
    echo "  \"dependencies\": {"

    # tmux
    local tmux_ver
    tmux_ver=$(_needle_check_dep_version "tmux")
    local tmux_installed="true"
    [[ "$tmux_ver" == "-" ]] && tmux_installed="false"
    echo "    \"tmux\": {\"version\": $(_needle_json_value "$tmux_ver"), \"status\": \"$([ "$tmux_installed" == "true" ] && echo "installed" || echo "not found")\"},"

    # jq
    local jq_ver
    jq_ver=$(_needle_check_dep_version "jq")
    local jq_installed="true"
    [[ "$jq_ver" == "-" ]] && jq_installed="false"
    echo "    \"jq\": {\"version\": $(_needle_json_value "$jq_ver"), \"status\": \"$([ "$jq_installed" == "true" ] && echo "installed" || echo "not found")\"},"

    # yq
    local yq_ver
    yq_ver=$(_needle_check_dep_version "yq")
    local yq_installed="true"
    [[ "$yq_ver" == "-" ]] && yq_installed="false"
    echo "    \"yq\": {\"version\": $(_needle_json_value "$yq_ver"), \"status\": \"$([ "$yq_installed" == "true" ] && echo "installed" || echo "not found")\"},"

    # br
    local br_ver
    br_ver=$(_needle_check_dep_version "br")
    local br_installed="true"
    [[ "$br_ver" == "-" ]] && br_installed="false"
    echo "    \"br\": {\"version\": $(_needle_json_value "$br_ver"), \"status\": \"$([ "$br_installed" == "true" ] && echo "installed" || echo "not found")\"}"

    echo "  },"

    # Agents
    echo "  \"agents\": {"

    local agent_order=("claude" "opencode" "codex" "aider")
    local last_agent="${agent_order[-1]}"

    for agent in "${agent_order[@]}"; do
        local cmd="${NEEDLE_AGENT_CMDS[$agent]:-$agent}"
        local version="null"
        local status="not found"
        local auth_status="null"

        if command -v "$cmd" &>/dev/null; then
            version=$(_needle_json_escape "$(_needle_agent_version "$agent" 2>/dev/null)")
            version="\"$version\""
            status="available"
            auth_status=$(_needle_agent_auth_status "$agent" 2>/dev/null)
            auth_status="\"$auth_status\""
        fi

        local comma=","
        [[ "$agent" == "$last_agent" ]] && comma=""

        echo "    \"$agent\": {\"version\": $version, \"status\": \"$status\", \"auth_status\": $auth_status}$comma"
    done

    echo "  },"

    # Paths
    local config_exists="false"
    [[ -f "$NEEDLE_CONFIG_FILE" ]] && config_exists="true"

    local log_sessions
    log_sessions=$(_needle_count_log_sessions)

    echo "  \"paths\": {"
    echo "    \"config\": \"$(_needle_json_escape "$NEEDLE_CONFIG_FILE")\","
    echo "    \"config_exists\": $config_exists,"
    echo "    \"logs\": \"$(_needle_json_escape "$NEEDLE_HOME/$NEEDLE_LOG_DIR")\","
    echo "    \"log_sessions\": $log_sessions"
    echo "  }"

    # End JSON object
    echo "}"
}

# Helper: return properly formatted JSON value
_needle_json_value() {
    local value="$1"
    if [[ -z "$value" ]] || [[ "$value" == "-" ]] || [[ "$value" == "null" ]]; then
        echo "null"
    else
        echo "\"$(_needle_json_escape "$value")\""
    fi
}

_needle_version() {
    local json_output=false
    local short=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--json)
                json_output=true
                shift
                ;;
            -s|--short)
                short=true
                shift
                ;;
            -h|--help)
                _needle_version_help
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                _needle_version_help
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    if [[ "$short" == "true" ]]; then
        echo "$NEEDLE_VERSION"
        exit $NEEDLE_EXIT_SUCCESS
    fi

    if [[ "$json_output" == "true" ]]; then
        _needle_version_json
    else
        _needle_version_text
    fi

    exit $NEEDLE_EXIT_SUCCESS
}
