#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: pre-claim
# ============================================================================
#
# PURPOSE:
#   Runs BEFORE a worker claims a bead. Use this hook to filter which beads
#   a worker should accept based on custom criteria.
#
# WHEN CALLED:
#   Just before the worker registers ownership of a bead. The bead is still
#   unclaimed at this point.
#
# EXIT CODES:
#   0 - Success: Proceed with claiming this bead
#   1 - Warning: Log warning but proceed (same as success for pre-claim)
#   2 - Abort: Do NOT claim this bead, skip to next available bead
#   3 - Skip: Skip remaining pre-claim hooks but still claim the bead
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("pre_claim")
# NEEDLE_BEAD_ID       - ID of the bead being considered for claim
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0=critical, 1=high, 2=normal, 3=low, 4=backlog)
# NEEDLE_BEAD_TYPE     - Type of bead (task, bug, feature, etc.)
# NEEDLE_BEAD_LABELS   - Comma-separated list of labels
# NEEDLE_WORKSPACE     - Path to the workspace directory
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Current process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_AGENT         - Agent name (if set)
# NEEDLE_STRAND        - Strand ID (if set)
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Only claim beads with specific labels:
#    - Filter by technology stack (rust, python, kubernetes)
#    - Filter by complexity level
#    - Filter by team ownership
#
# 2. Avoid claiming beads during maintenance windows
#
# 3. Claim only beads within worker's expertise domain
#
# 4. Implement capacity-based claim limiting
#
# ============================================================================

set -euo pipefail

# ============================================================================
# EXAMPLE FILTERING LOGIC (Uncomment to enable)
# ============================================================================

echo "pre-claim hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Title: ${NEEDLE_BEAD_TITLE:-}"
echo "  Priority: ${NEEDLE_BEAD_PRIORITY:-}"
echo "  Labels: ${NEEDLE_BEAD_LABELS:-}"

# ----------------------------------------------------------------------------
# Example 1: Filter by label - Only accept beads with specific labels
# ----------------------------------------------------------------------------
# Uncomment to enable label-based filtering:
#
# ALLOWED_LABELS="rust,backend,api"
# if [[ -n "${NEEDLE_BEAD_LABELS:-}" ]]; then
#     matched=false
#     for label in ${NEEDLE_BEAD_LABELS//,/ }; do
#         if [[ ",$ALLOWED_LABELS," == *",$label,"* ]]; then
#             matched=true
#             break
#         fi
#     done
#     if [[ "$matched" == "false" ]]; then
#         echo "Skipping bead - no matching labels (allowed: $ALLOWED_LABELS)"
#         exit 2  # Abort claim
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 2: Filter by priority - Only claim high-priority beads
# ----------------------------------------------------------------------------
# Uncomment to enable priority-based filtering:
#
# if [[ "${NEEDLE_BEAD_PRIORITY:-3}" -gt 1 ]]; then
#     echo "Skipping bead - priority too low (current: ${NEEDLE_BEAD_PRIORITY:-3})"
#     exit 2  # Abort claim
# fi

# ----------------------------------------------------------------------------
# Example 3: Time-based filtering - Don't claim during maintenance windows
# ----------------------------------------------------------------------------
# Uncomment to enable time-based filtering:
#
# current_hour=$(date +%H)
# # Skip claiming between 2-4 AM (maintenance window)
# if [[ "$current_hour" -ge 2 && "$current_hour" -lt 4 ]]; then
#     echo "Skipping claim - maintenance window (2-4 AM)"
#     exit 2  # Abort claim
# fi

# ----------------------------------------------------------------------------
# Example 4: Capacity check - Limit concurrent claims
# ----------------------------------------------------------------------------
# Uncomment to enable capacity-based filtering:
#
# MAX_CONCURRENT=3
# current_count=$(find /tmp/needle-claims -name "*.lock" 2>/dev/null | wc -l)
# if [[ "$current_count" -ge "$MAX_CONCURRENT" ]]; then
#     echo "Skipping claim - at capacity ($current_count/$MAX_CONCURRENT)"
#     exit 2  # Abort claim
# fi

# ----------------------------------------------------------------------------
# Example 5: Workspace availability check
# ----------------------------------------------------------------------------
# Uncomment to enable workspace check:
#
# if [[ ! -d "${NEEDLE_WORKSPACE:-}" ]]; then
#     echo "Error: Workspace does not exist: ${NEEDLE_WORKSPACE:-}"
#     exit 2  # Abort claim
# fi

# ============================================================================
# Default: Allow claim to proceed
# ============================================================================
echo "Claim approved for bead: ${NEEDLE_BEAD_ID:-unknown}"
exit 0
