#!/usr/bin/env bash
# NEEDLE CLI Metrics Subcommand
# Analyze file collision effectiveness and checkout metrics

_needle_metrics_help() {
    _needle_print "Analyze file collision and checkout effectiveness

USAGE:
    needle metrics <SUBCOMMAND> [OPTIONS]

SUBCOMMANDS:
    collisions      Show collision summary for a time period
    hot-files       Identify frequently contested files
    strategies      Compare strategy effectiveness
    export          Export metrics data to file
    recommend       Get recommendations based on metrics

OPTIONS:
    -h, --help      Show this help message

EXAMPLES:
    needle metrics collisions --period=24h
    needle metrics hot-files --top=10
    needle metrics strategies --compare
    needle metrics export --format=csv --output=collisions.csv
    needle metrics recommend

STORAGE:
    Events:     ~/.needle/state/metrics/collision_events.jsonl
    Aggregated: ~/.needle/state/metrics/file_collisions.json
"
}

_needle_metrics() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        collisions)
            _needle_metrics_collisions "$@"
            ;;
        hot-files|hot_files)
            _needle_metrics_hot_files "$@"
            ;;
        strategies)
            _needle_metrics_strategies "$@"
            ;;
        export)
            _needle_metrics_export "$@"
            ;;
        recommend)
            _needle_metrics_recommend "$@"
            ;;
        -h|--help|help|"")
            _needle_metrics_help
            exit $NEEDLE_EXIT_SUCCESS
            ;;
        *)
            _needle_error "Unknown subcommand: $subcommand"
            _needle_metrics_help
            exit $NEEDLE_EXIT_USAGE
            ;;
    esac
}

# ----------------------------------------------------------------------------
# needle metrics collisions [--period=24h]
# ----------------------------------------------------------------------------

_needle_metrics_collisions() {
    local period="24h"
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period=*)
                period="${1#*=}"
                shift
                ;;
            --period)
                period="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                _needle_print "Show collision summary

USAGE:
    needle metrics collisions [OPTIONS]

OPTIONS:
    --period=<duration>  Time period (e.g., 1h, 24h, 7d, 30d). Default: 24h
    -j, --json           Output raw JSON
    -h, --help           Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    if [[ "$json_output" == "true" ]]; then
        echo "$metrics"
        return
    fi

    if ! _needle_command_exists jq; then
        _needle_error "jq is required for metrics display"
        exit $NEEDLE_EXIT_DEPENDENCY
    fi

    local attempts acquired blocked missed prevented
    attempts=$(echo "$metrics"  | jq -r '.totals.checkout_attempts   // 0')
    acquired=$(echo "$metrics"  | jq -r '.totals.checkouts_acquired  // 0')
    blocked=$(echo  "$metrics"  | jq -r '.totals.checkouts_blocked   // 0')
    missed=$(echo   "$metrics"  | jq -r '.totals.conflicts_missed    // 0')
    prevented=$(echo "$metrics" | jq -r '.totals.conflicts_prevented // 0')

    # Compute overall effectiveness: prevented / (prevented + missed) * 100
    local effectiveness="N/A"
    if (( prevented + missed > 0 )); then
        effectiveness=$(awk "BEGIN {printf \"%.1f\", $prevented * 100 / ($prevented + $missed)}")
        effectiveness="${effectiveness}%"
    fi

    _needle_header "File Collision Metrics (${period})"
    _needle_print ""
    printf "  %-28s %s\n" "Checkout attempts:"    "$attempts"
    printf "  %-28s %s\n" "Checkouts acquired:"   "$acquired"
    printf "  %-28s %s\n" "Checkouts blocked:"    "$blocked"
    printf "  %-28s %s\n" "Conflicts prevented:"  "$prevented"
    printf "  %-28s %s\n" "Conflicts missed:"     "$missed"
    printf "  %-28s %s\n" "Overall effectiveness:" "$effectiveness"
    _needle_print ""

    # Show conflict pairs if any
    local pairs_count
    pairs_count=$(echo "$metrics" | jq '.conflict_pairs | length')
    if (( pairs_count > 0 )); then
        _needle_print "  Top Conflict Pairs:"
        echo "$metrics" | jq -r '.conflict_pairs[] | "    \(.bead_a) <-> \(.bead_b): \(.file) (\(.count)x)"'
        _needle_print ""
    fi
}

# ----------------------------------------------------------------------------
# needle metrics hot-files [--top=10]
# ----------------------------------------------------------------------------

_needle_metrics_hot_files() {
    local top=10
    local period="24h"
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --top=*)
                top="${1#*=}"
                shift
                ;;
            --top)
                top="$2"
                shift 2
                ;;
            --period=*)
                period="${1#*=}"
                shift
                ;;
            --period)
                period="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                _needle_print "Identify frequently contested files

USAGE:
    needle metrics hot-files [OPTIONS]

OPTIONS:
    --top=N              Show top N files (default: 10)
    --period=<duration>  Time period (default: 24h)
    -j, --json           Output JSON
    -h, --help           Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    local hot_files
    hot_files=$(echo "$metrics" | jq --argjson top "$top" '.hot_files[0:$top]')

    if [[ "$json_output" == "true" ]]; then
        echo "$hot_files"
        return
    fi

    local count
    count=$(echo "$hot_files" | jq 'length')

    _needle_header "Hot Files - Top ${top} (${period})"
    _needle_print ""

    if [[ "$count" -eq 0 ]]; then
        _needle_info "No file conflicts recorded in this period"
        _needle_print ""
        return
    fi

    # Display with visual bar
    local max_conflicts
    max_conflicts=$(echo "$hot_files" | jq '.[0].conflicts // 1')
    if (( max_conflicts < 1 )); then max_conflicts=1; fi

    echo "$hot_files" | jq -r '.[] | "\(.conflicts)\t\(.path)"' | \
    while IFS=$'\t' read -r conflicts path; do
        local bar_len=$(( conflicts * 20 / max_conflicts ))
        if (( bar_len < 1 )); then bar_len=1; fi
        local bar=""
        local i=0
        while (( i < bar_len )); do
            bar+="█"
            ((i++))
        done
        printf "  %-20s  %-4s  %s\n" "$bar" "${conflicts}x" "$path"
    done
    _needle_print ""
}

# ----------------------------------------------------------------------------
# needle metrics strategies [--compare]
# ----------------------------------------------------------------------------

_needle_metrics_strategies() {
    local period="24h"
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --compare)
                # --compare is implied; included for CLI compatibility
                shift
                ;;
            --period=*)
                period="${1#*=}"
                shift
                ;;
            --period)
                period="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                _needle_print "Compare strategy effectiveness

USAGE:
    needle metrics strategies [OPTIONS]

OPTIONS:
    --compare            Compare strategies (default behavior)
    --period=<duration>  Time period (default: 24h)
    -j, --json           Output JSON
    -h, --help           Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    if [[ "$json_output" == "true" ]]; then
        echo "$metrics"
        return
    fi

    local attempts blocked missed prevented
    attempts=$(echo "$metrics"  | jq -r '.totals.checkout_attempts   // 0')
    blocked=$(echo  "$metrics"  | jq -r '.totals.checkouts_blocked   // 0')
    missed=$(echo   "$metrics"  | jq -r '.totals.conflicts_missed    // 0')
    prevented=$(echo "$metrics" | jq -r '.totals.conflicts_prevented // 0')

    _needle_header "Strategy Effectiveness (${period})"
    _needle_print ""

    if (( prevented + missed + blocked == 0 )); then
        _needle_info "No conflict data recorded in this period"
        _needle_print ""
        _needle_print "  The checkout system prevents conflicts by blocking concurrent"
        _needle_print "  access to the same files by different beads."
        _needle_print ""
        _needle_print "  Use checkout_file() in your workers to record events."
        _needle_print ""
        return
    fi

    # Prompt injection strategy (checkout blocking = prevention)
    local prompt_blocked prompt_missed prompt_effectiveness
    prompt_blocked=$blocked
    prompt_missed=$missed

    if (( prompt_blocked + prompt_missed > 0 )); then
        prompt_effectiveness=$(awk "BEGIN {printf \"%.1f\", $prompt_blocked * 100 / ($prompt_blocked + $prompt_missed)}")
    else
        prompt_effectiveness="N/A"
    fi

    # post_exec_rollback strategy (catches missed conflicts)
    local rollback_caught
    rollback_caught=$missed

    # Overall
    local overall_effectiveness
    if (( prevented + missed > 0 )); then
        overall_effectiveness=$(awk "BEGIN {printf \"%.1f\", $prevented * 100 / ($prevented + $missed)}")
    else
        overall_effectiveness="N/A"
    fi

    _needle_print "  Checkout blocking (prompt_injection):"
    printf  "    %-24s %s\n"  "Attempts blocked:"    "$prompt_blocked"
    printf  "    %-24s %s\n"  "Conflicts missed:"    "$prompt_missed"
    if [[ "$prompt_effectiveness" != "N/A" ]]; then
        # Visual bar for effectiveness
        local bar_len=$(awk "BEGIN {printf \"%d\", $prompt_effectiveness / 5}")
        local bar="" i=0
        while (( i < bar_len )); do bar+="█"; ((i++)); done
        local empty_len=$(( 20 - bar_len ))
        i=0
        while (( i < empty_len )); do bar+="░"; ((i++)); done
        printf  "    %-24s %s  %s%%\n" "Effectiveness:" "$bar" "$prompt_effectiveness"
    else
        printf  "    %-24s %s\n" "Effectiveness:" "N/A (no conflict data)"
    fi
    _needle_print ""

    _needle_print "  Post-exec rollback:"
    printf  "    %-24s %s\n" "Conflicts caught:" "$rollback_caught"
    _needle_print ""

    _needle_print "  Overall:"
    if [[ "$overall_effectiveness" != "N/A" ]]; then
        printf  "    %-24s %s%%\n" "Effectiveness:" "$overall_effectiveness"
    else
        printf  "    %-24s %s\n"  "Effectiveness:" "N/A"
    fi
    printf  "    %-24s %s\n" "Total attempts:" "$attempts"
    _needle_print ""
}

# ----------------------------------------------------------------------------
# needle metrics export [--format=csv] [--output=file]
# ----------------------------------------------------------------------------

_needle_metrics_export() {
    local format="json"
    local output=""
    local period="24h"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format=*)
                format="${1#*=}"
                shift
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --output=*)
                output="${1#*=}"
                shift
                ;;
            --output|-o)
                output="$2"
                shift 2
                ;;
            --period=*)
                period="${1#*=}"
                shift
                ;;
            --period)
                period="$2"
                shift 2
                ;;
            -h|--help)
                _needle_print "Export metrics data

USAGE:
    needle metrics export [OPTIONS]

OPTIONS:
    --format=<fmt>     Output format: json, csv (default: json)
    --output=<file>    Write to file instead of stdout
    --period=<dur>     Time period (default: 24h)
    -h, --help         Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    local result
    case "$format" in
        json)
            result="$metrics"
            ;;
        csv)
            # Export totals + hot files as CSV
            local totals_csv
            totals_csv=$(echo "$metrics" | jq -r '
                ["metric","value"],
                ["checkout_attempts",     .totals.checkout_attempts],
                ["checkouts_acquired",    .totals.checkouts_acquired],
                ["checkouts_blocked",     .totals.checkouts_blocked],
                ["conflicts_missed",      .totals.conflicts_missed],
                ["conflicts_prevented",   .totals.conflicts_prevented]
                | @csv
            ' 2>/dev/null || echo "metric,value")

            local hot_files_csv
            hot_files_csv=$(echo "$metrics" | jq -r '
                ["path","conflicts"],
                (.hot_files[] | [.path, .conflicts])
                | @csv
            ' 2>/dev/null || echo "path,conflicts")

            result="# Collision Metrics (${period})"$'\n'
            result+="$totals_csv"$'\n'$'\n'
            result+="# Hot Files"$'\n'
            result+="$hot_files_csv"
            ;;
        *)
            _needle_error "Unknown format: $format (supported: json, csv)"
            exit $NEEDLE_EXIT_USAGE
            ;;
    esac

    if [[ -n "$output" ]]; then
        echo "$result" > "$output"
        _needle_success "Exported ${period} metrics to: $output"
    else
        echo "$result"
    fi
}

# ----------------------------------------------------------------------------
# needle metrics recommend
# ----------------------------------------------------------------------------

_needle_metrics_recommend() {
    local period="24h"
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period=*)
                period="${1#*=}"
                shift
                ;;
            --period)
                period="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                _needle_print "Get recommendations based on collision metrics

USAGE:
    needle metrics recommend [OPTIONS]

OPTIONS:
    --period=<duration>  Analysis period (default: 24h)
    -j, --json           Output JSON
    -h, --help           Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    local attempts blocked missed prevented hot_count
    attempts=$(echo  "$metrics" | jq -r '.totals.checkout_attempts   // 0')
    blocked=$(echo   "$metrics" | jq -r '.totals.checkouts_blocked   // 0')
    missed=$(echo    "$metrics" | jq -r '.totals.conflicts_missed    // 0')
    prevented=$(echo "$metrics" | jq -r '.totals.conflicts_prevented // 0')
    hot_count=$(echo "$metrics" | jq '.hot_files | length')

    local recommendations=()

    if (( attempts == 0 )); then
        recommendations+=("No checkout activity recorded. Ensure workers are using checkout_file() before editing files.")
    else
        local block_rate=0
        if (( attempts > 0 )); then
            block_rate=$(( blocked * 100 / attempts ))
        fi

        if (( block_rate > 20 )); then
            local hot_file
            hot_file=$(echo "$metrics" | jq -r '.hot_files[0].path // "unknown"')
            recommendations+=("High contention rate (${block_rate}%). Consider refactoring hot files. Most contested: $hot_file")
        fi

        if (( missed > 0 )); then
            recommendations+=("${missed} conflict(s) were missed and required post-exec rollback. Ensure all workers call checkout_file() before editing shared files.")
        fi

        if (( hot_count > 5 )); then
            recommendations+=("${hot_count} hot files detected. Run 'needle analyze hot-files --create-beads' to auto-generate refactoring tasks.")
        fi

        if (( blocked + missed > 0 )); then
            local effectiveness
            effectiveness=$(awk "BEGIN {printf \"%.1f\", $prevented * 100 / ($prevented + $missed + 0.001)}")
            if (( $(awk "BEGIN {print ($effectiveness < 80)}") )); then
                recommendations+=("Effectiveness is ${effectiveness}% - below 80% threshold. Review checkout_file() usage in worker hooks.")
            fi
        fi

        if (( block_rate == 0 && missed == 0 && attempts > 0 )); then
            recommendations+=("Collision avoidance is working well. No conflicts detected in the last ${period}.")
        fi
    fi

    if [[ "$json_output" == "true" ]]; then
        printf '%s\n' "${recommendations[@]}" | jq -Rn '[inputs]' 2>/dev/null || printf '%s\n' "${recommendations[@]}"
        return
    fi

    _needle_header "Recommendations (${period})"
    _needle_print ""

    if [[ ${#recommendations[@]} -eq 0 ]]; then
        _needle_success "No recommendations at this time."
    else
        local i=1
        for rec in "${recommendations[@]}"; do
            _needle_print "  $i. $rec"
            ((i++))
        done
    fi
    _needle_print ""
}
