#!/usr/bin/env bash
# NEEDLE CLI Analyze Subcommand
# Analyze codebase patterns and file contention

_needle_analyze_help() {
    _needle_print "Analyze codebase patterns and file contention

USAGE:
    needle analyze <SUBCOMMAND> [OPTIONS]

SUBCOMMANDS:
    hot-files    Identify frequently contested files and optionally create refactoring beads

OPTIONS:
    -h, --help   Show this help message

EXAMPLES:
    needle analyze hot-files
    needle analyze hot-files --top=5
    needle analyze hot-files --create-beads
    needle analyze hot-files --period=7d --create-beads
"
}

_needle_analyze() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        hot-files|hot_files)
            _needle_analyze_hot_files "$@"
            ;;
        -h|--help|help|"")
            _needle_analyze_help
            exit $NEEDLE_EXIT_SUCCESS
            ;;
        *)
            _needle_error "Unknown subcommand: $subcommand"
            _needle_analyze_help
            exit $NEEDLE_EXIT_USAGE
            ;;
    esac
}

# ----------------------------------------------------------------------------
# needle analyze hot-files [--create-beads]
# ----------------------------------------------------------------------------

_needle_analyze_hot_files() {
    local top=10
    local period="7d"
    local create_beads=false
    local json_output=false
    local workspace=""
    local min_conflicts=3

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
            --create-beads)
                create_beads=true
                shift
                ;;
            --min-conflicts=*)
                min_conflicts="${1#*=}"
                shift
                ;;
            --min-conflicts)
                min_conflicts="$2"
                shift 2
                ;;
            --workspace=*)
                workspace="${1#*=}"
                shift
                ;;
            --workspace|-w)
                workspace="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                _needle_print "Identify frequently contested files

USAGE:
    needle analyze hot-files [OPTIONS]

OPTIONS:
    --top=N                  Show top N files (default: 10)
    --period=<duration>      Analysis period (default: 7d)
    --create-beads           Auto-generate refactoring beads for hot files
    --min-conflicts=N        Minimum conflicts to qualify (default: 3, for --create-beads)
    --workspace=<path>       Workspace context for bead creation
    -j, --json               Output JSON
    -h, --help               Show this help
"
                exit $NEEDLE_EXIT_SUCCESS
                ;;
            *)
                _needle_error "Unknown option: $1"
                exit $NEEDLE_EXIT_USAGE
                ;;
        esac
    done

    workspace="${workspace:-$(pwd)}"

    source "$NEEDLE_ROOT_DIR/src/lock/metrics.sh"

    local metrics
    metrics=$(_needle_metrics_aggregate "$period")

    local hot_files
    hot_files=$(echo "$metrics" | jq --argjson top "$top" '.hot_files[0:$top]')

    local count
    count=$(echo "$hot_files" | jq 'length')

    if [[ "$json_output" == "true" ]] && [[ "$create_beads" != "true" ]]; then
        echo "$hot_files"
        return
    fi

    if [[ "$count" -eq 0 ]]; then
        _needle_info "No hot files detected in the last ${period}"
        exit $NEEDLE_EXIT_SUCCESS
    fi

    _needle_header "Hot Files Analysis (${period})"
    _needle_print ""

    local max_conflicts
    max_conflicts=$(echo "$hot_files" | jq '.[0].conflicts // 1')
    if (( max_conflicts < 1 )); then max_conflicts=1; fi

    echo "$hot_files" | jq -r '.[] | "\(.conflicts)\t\(.path)"' | \
    while IFS=$'\t' read -r conflicts path; do
        local bar_len=$(( conflicts * 20 / max_conflicts ))
        if (( bar_len < 1 )); then bar_len=1; fi
        local bar="" i=0
        while (( i < bar_len )); do bar+="█"; ((i++)); done
        printf "  %3dx  %-20s  %s\n" "$conflicts" "$bar" "$path"
    done
    _needle_print ""

    if [[ "$create_beads" == "true" ]]; then
        if ! _needle_command_exists br; then
            _needle_warn "br command not found, cannot create beads"
            exit $NEEDLE_EXIT_DEPENDENCY
        fi

        _needle_info "Creating refactoring beads for hot files (min conflicts: ${min_conflicts})..."
        _needle_print ""

        local created=0 skipped=0

        while IFS=$'\t' read -r conflicts path; do
            if (( conflicts < min_conflicts )); then
                skipped=$(( skipped + 1 ))
                continue
            fi

            local filename
            filename=$(basename "$path")
            local title="Refactor: reduce contention in ${filename}"

            local description
            description="## Hot File: \`${filename}\`

File \`${path}\` has been contested **${conflicts} times** in the last ${period}.

This file is a hot spot for concurrent access conflicts between workers.

## Why This Matters

High contention means multiple workers are frequently trying to edit the same file simultaneously, leading to:
- Worker blocking (one must wait for the other to finish)
- Potential merge conflicts if checkout system is bypassed
- Reduced parallelism and throughput

## Suggested Refactoring Approaches

1. **Split into smaller modules** — Break the file into focused submodules so workers edit different files
2. **Extract shared utilities** — Move shared code to a lib/ file that rarely changes
3. **Add a facade layer** — Create an interface that delegates to specialized implementations
4. **Reduce scope** — Narrow what each bead needs to change in this file

## Metrics

- Contention count: ${conflicts} (period: ${period})
- Workspace: ${workspace}

---
*Auto-generated by: \`needle analyze hot-files --create-beads\`*

## Required for
/home/coder/NEEDLE bead nd-2a0i (needle metrics: File collision analytics)"

            local bead_id
            bead_id=$(br create \
                --title "$title" \
                --description "$description" \
                --add-label refactor \
                --add-label hot-file \
                2>/dev/null | grep -oP 'Created issue \K[a-z0-9-]+' || true)

            if [[ -n "$bead_id" ]]; then
                _needle_success "Created bead $bead_id: $title"
                created=$(( created + 1 ))
            else
                _needle_warn "Failed to create bead for: $path"
            fi
        done < <(echo "$hot_files" | jq -r '.[] | "\(.conflicts)\t\(.path)"')

        _needle_print ""
        if (( created > 0 )); then
            _needle_success "Created $created refactoring bead(s)"
        else
            _needle_info "No beads created (all files below min-conflicts threshold of ${min_conflicts})"
        fi
        if (( skipped > 0 )); then
            _needle_info "Skipped $skipped files below threshold"
        fi
    fi

    exit $NEEDLE_EXIT_SUCCESS
}
