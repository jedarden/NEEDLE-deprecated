#!/usr/bin/env bash
#
# NEEDLE Capacity Governor
# Monitors Claude Code subscription usage and adjusts sonnet worker count
# to pace consumption toward the weekly reset without getting blocked.
#
# Usage:
#   ./scripts/capacity-governor.sh              # Run once (check + adjust)
#   ./scripts/capacity-governor.sh --loop       # Run continuously (every 15 min)
#   ./scripts/capacity-governor.sh --dry-run    # Show what would change
#   ./scripts/capacity-governor.sh --status     # Just show current state
#
# The governor uses a linear pacing model:
#   target_rate = remaining_pct / hours_until_reset
#   If current burn rate > target_rate → scale down sonnet workers
#   If current burn rate < target_rate → scale up sonnet workers (up to limit)
#
# 2x off-peak promotion (Mar 13-27, 2026):
#   Off-peak (outside 8AM-2PM ET): usage counts at 0.5x
#   Peak (8AM-2PM ET): usage counts at 1x
#   The governor factors this into remaining effective capacity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOVERNOR_STATE="/home/coding/.needle/state/capacity-governor.json"
STATUS_SCRIPT="/home/coding/.claude/skills/claude-status/scripts/claude-status.sh"
LOOP_INTERVAL=900  # 15 minutes
DRY_RUN=false
LOOP=false
STATUS_ONLY=false

# Sonnet worker limits
SONNET_MIN=1       # Always keep at least 1 sonnet worker
SONNET_MAX=5       # Config limit
SONNET_AGENT="claude-anthropic-sonnet"

# 2x promotion window (ET)
PROMO_START="2026-03-13"
PROMO_END="2026-03-27"
PEAK_START_HOUR=8   # 8 AM ET
PEAK_END_HOUR=14    # 2 PM ET

# ─────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────

log() { printf '[capacity-governor] %s\n' "$*" >&2; }
warn() { printf '[capacity-governor] ⚠ %s\n' "$*" >&2; }
err() { printf '[capacity-governor] ✗ %s\n' "$*" >&2; }

now_epoch() { date +%s; }

# Current hour in ET (handles EDT/EST automatically)
et_hour() {
    TZ="America/New_York" date +%H | sed 's/^0//'
}

et_date() {
    TZ="America/New_York" date +%Y-%m-%d
}

is_promo_active() {
    local today
    today=$(et_date)
    [[ "$today" > "$PROMO_START" || "$today" == "$PROMO_START" ]] && \
    [[ "$today" < "$PROMO_END" || "$today" == "$PROMO_END" ]]
}

is_peak_hour() {
    local hour
    hour=$(et_hour)
    [[ $hour -ge $PEAK_START_HOUR && $hour -lt $PEAK_END_HOUR ]]
}

# Effective usage multiplier: during promo off-peak, 1 unit of work costs 0.5 quota
usage_multiplier() {
    if is_promo_active && ! is_peak_hour; then
        echo "0.5"
    else
        echo "1.0"
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Usage Fetching
# ─────────────────────────────────────────────────────────────────────

fetch_usage() {
    if [[ ! -x "$STATUS_SCRIPT" ]]; then
        err "claude-status.sh not found at $STATUS_SCRIPT"
        return 1
    fi

    local output
    output=$(bash "$STATUS_SCRIPT" 2>/dev/null) || {
        err "Failed to fetch usage"
        return 1
    }

    # Parse sonnet weekly percentage
    local sonnet_pct all_pct
    sonnet_pct=$(echo "$output" | grep -A1 "Sonnet only" | grep -oP '\d+(?=% used)' | head -1)
    all_pct=$(echo "$output" | grep -A1 "all models" | grep -oP '\d+(?=% used)' | head -1)

    # Parse reset time for sonnet
    local reset_line reset_date
    reset_line=$(echo "$output" | grep -A2 "Sonnet only" | grep "Resets" | head -1)
    reset_date=$(echo "$reset_line" | grep -oP 'Mar \d+' | head -1)

    if [[ -z "$sonnet_pct" ]]; then
        err "Could not parse sonnet usage percentage"
        return 1
    fi

    echo "${sonnet_pct}|${all_pct:-0}|${reset_date:-unknown}"
}

# ─────────────────────────────────────────────────────────────────────
# Worker Management
# ─────────────────────────────────────────────────────────────────────

count_sonnet_workers() {
    local count
    count=$(needle list 2>/dev/null | grep -c "$SONNET_AGENT" || true)
    echo "${count:-0}"
}

# Get workspaces that sonnet workers are assigned to
get_sonnet_workspaces() {
    needle list 2>/dev/null | grep "$SONNET_AGENT" | awk '{print $NF}'
}

# Scale sonnet workers to target count
scale_sonnet() {
    local target=$1
    local current
    current=$(count_sonnet_workers)

    if [[ $target -eq $current ]]; then
        log "Sonnet workers at target: $current"
        return 0
    fi

    if [[ $target -gt $current ]]; then
        local to_add=$((target - current))
        log "Scaling UP sonnet: $current → $target (+$to_add)"
        if $DRY_RUN; then
            log "[DRY RUN] Would launch $to_add sonnet workers"
            return 0
        fi
        # Launch into kalshi-trading (largest backlog) by default
        for i in $(seq 1 "$to_add"); do
            needle run --workspace=/home/coding/kalshi-trading \
                --agent="$SONNET_AGENT" --force 2>&1 | tail -1
        done
    else
        local to_remove=$((current - target))
        log "Scaling DOWN sonnet: $current → $target (-$to_remove)"
        if $DRY_RUN; then
            log "[DRY RUN] Would stop $to_remove sonnet workers"
            return 0
        fi
        # Stop the most recently launched sonnet workers
        local sessions
        sessions=$(tmux list-sessions 2>/dev/null | grep "needle-claude-anthropic-sonnet" | \
            sort -t: -k1 -r | head -"$to_remove" | awk -F: '{print $1}')
        for session in $sessions; do
            log "Stopping $session"
            tmux kill-session -t "$session" 2>/dev/null || true
        done
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Pacing Algorithm
# ─────────────────────────────────────────────────────────────────────

compute_target_workers() {
    local sonnet_pct=$1

    local remaining=$((100 - sonnet_pct))
    local multiplier
    multiplier=$(usage_multiplier)

    # Parse reset date to compute hours remaining
    # Reset is weekly — estimate hours until next reset
    local now_ts reset_ts hours_remaining
    now_ts=$(now_epoch)

    # Get the reset time from the status output (stored in state)
    # Fall back to ~48 hours if unknown
    hours_remaining=48
    if [[ -f "$GOVERNOR_STATE" ]]; then
        local stored_reset
        stored_reset=$(jq -r '.reset_date // ""' "$GOVERNOR_STATE" 2>/dev/null)
        if [[ -n "$stored_reset" && "$stored_reset" != "unknown" ]]; then
            # Parse "Mar 20" style date
            local reset_ts_parsed
            reset_ts_parsed=$(date -d "$stored_reset 2026 00:00:00 America/New_York" +%s 2>/dev/null || echo "")
            if [[ -n "$reset_ts_parsed" ]]; then
                hours_remaining=$(( (reset_ts_parsed - now_ts) / 3600 ))
                [[ $hours_remaining -lt 1 ]] && hours_remaining=1
            fi
        fi
    fi

    # Compute effective remaining capacity factoring in 2x promotion
    # Off-peak hours remaining get 2x effective capacity
    local peak_hours_remaining=0
    local offpeak_hours_remaining=0
    local h
    for h in $(seq 0 $((hours_remaining - 1))); do
        local future_hour
        future_hour=$(TZ="America/New_York" date -d "+${h} hours" +%H 2>/dev/null | sed 's/^0//')
        local future_date
        future_date=$(TZ="America/New_York" date -d "+${h} hours" +%Y-%m-%d 2>/dev/null)
        if [[ ! "$future_date" < "$PROMO_START" && ! "$future_date" > "$PROMO_END" ]] && \
           [[ $future_hour -ge $PEAK_START_HOUR && $future_hour -lt $PEAK_END_HOUR ]]; then
            peak_hours_remaining=$((peak_hours_remaining + 1))
        else
            offpeak_hours_remaining=$((offpeak_hours_remaining + 1))
        fi
    done

    # Effective hours = peak_hours * 1.0 + offpeak_hours * 2.0 (2x promo)
    # This represents how much "work-equivalent" time we have
    local effective_hours
    effective_hours=$((peak_hours_remaining + offpeak_hours_remaining * 2))
    [[ $effective_hours -lt 1 ]] && effective_hours=1

    # Target: pace remaining capacity evenly across effective hours
    # With 5 workers at full tilt, we consume roughly 4-6% per hour
    # With 1 worker, roughly 1% per hour
    # Target consumption rate: remaining% / hours_remaining
    local target_rate_per_hour
    target_rate_per_hour=$(awk "BEGIN {printf \"%.2f\", $remaining / $hours_remaining}")

    # Current consumption rate per sonnet worker: ~1.2% per hour (empirical)
    local rate_per_worker="1.2"

    # Target workers = target_rate / rate_per_worker
    local target_workers
    target_workers=$(awk "BEGIN {printf \"%d\", $target_rate_per_hour / $rate_per_worker}")

    # Clamp to bounds
    [[ $target_workers -lt $SONNET_MIN ]] && target_workers=$SONNET_MIN
    [[ $target_workers -gt $SONNET_MAX ]] && target_workers=$SONNET_MAX

    # Emit decision context
    log "Usage: ${sonnet_pct}% used, ${remaining}% remaining"
    log "Time: ${hours_remaining}h until reset (${peak_hours_remaining}h peak + ${offpeak_hours_remaining}h off-peak)"
    log "Effective hours: ${effective_hours}h (with 2x promo)"
    log "Target rate: ${target_rate_per_hour}%/h → ${target_workers} workers (rate/worker: ${rate_per_worker}%/h)"
    log "Multiplier: $(usage_multiplier) ($(is_peak_hour && echo 'PEAK' || echo 'off-peak'))"

    echo "$target_workers"
}

# ─────────────────────────────────────────────────────────────────────
# State Persistence
# ─────────────────────────────────────────────────────────────────────

save_state() {
    local sonnet_pct=$1 all_pct=$2 reset_date=$3 target=$4 current=$5
    mkdir -p "$(dirname "$GOVERNOR_STATE")"
    cat > "$GOVERNOR_STATE" <<STATEEOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "sonnet_pct": $sonnet_pct,
    "all_models_pct": $all_pct,
    "reset_date": "$reset_date",
    "target_workers": $target,
    "current_workers": $current,
    "multiplier": "$(usage_multiplier)",
    "is_peak": $(is_peak_hour && echo true || echo false)
}
STATEEOF
}

# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --loop) LOOP=true; shift ;;
            --status) STATUS_ONLY=true; shift ;;
            --interval) LOOP_INTERVAL="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $0 [--loop] [--dry-run] [--status] [--interval SECONDS]"
                exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done
}

run_once() {
    log "Fetching Claude Code usage..."
    local usage_data
    usage_data=$(fetch_usage) || return 1

    local sonnet_pct all_pct reset_date
    IFS='|' read -r sonnet_pct all_pct reset_date <<< "$usage_data"

    local current_workers
    current_workers=$(count_sonnet_workers)

    if $STATUS_ONLY; then
        echo "=== Capacity Governor Status ==="
        echo "Sonnet weekly:    ${sonnet_pct}% used (${reset_date} reset)"
        echo "All models:       ${all_pct}% used"
        echo "Sonnet workers:   ${current_workers}"
        echo "Peak hour:        $(is_peak_hour && echo 'YES (1x)' || echo 'NO (2x promo)')"
        echo "Promo active:     $(is_promo_active && echo 'YES' || echo 'NO')"
        echo "================================="
        return 0
    fi

    local target
    target=$(compute_target_workers "$sonnet_pct")

    save_state "$sonnet_pct" "$all_pct" "$reset_date" "$target" "$current_workers"

    scale_sonnet "$target"
}

main() {
    parse_args "$@"

    if $LOOP; then
        log "Starting capacity governor loop (interval: ${LOOP_INTERVAL}s)"
        while true; do
            run_once || warn "Governor cycle failed, will retry"
            log "Next check in ${LOOP_INTERVAL}s"
            sleep "$LOOP_INTERVAL"
        done
    else
        run_once
    fi
}

main "$@"
