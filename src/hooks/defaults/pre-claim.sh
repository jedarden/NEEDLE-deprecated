#!/usr/bin/env bash
# NEEDLE Default Pre-Claim Hook Template
#
# This script runs before a worker claims a bead. Use it to implement
# custom filtering logic — for example, skip beads based on labels,
# priority, type, or any other criteria.
#
# Exit Codes:
#   0   - Allow claim (continue normally)
#   1   - Warning (log warning but continue)
#   2   - Abort (stop current operation)
#   3   - Skip (skip this bead, try the next one)
#   124 - Timeout (hook exceeded timeout limit)
#
# Environment Variables:
#   NEEDLE_HOOK           - Hook name ("pre_claim")
#   NEEDLE_BEAD_ID        - Bead ID being considered
#   NEEDLE_BEAD_TITLE     - Bead title
#   NEEDLE_BEAD_PRIORITY  - Bead priority (0=critical, 4=backlog)
#   NEEDLE_BEAD_TYPE      - Bead type (task, human, etc.)
#   NEEDLE_BEAD_LABELS    - Comma-separated list of labels
#   NEEDLE_WORKER         - Worker/session ID
#   NEEDLE_WORKSPACE      - Current workspace path
#   NEEDLE_SESSION        - Worker session ID
#
# Configuration (in ~/.needle/config.yaml or .needle.yaml):
#   hooks:
#     pre_claim: ~/.needle/hooks/pre-claim.sh
#
# To use this template:
#   cp src/hooks/defaults/pre-claim.sh ~/.needle/hooks/pre-claim.sh
#   chmod +x ~/.needle/hooks/pre-claim.sh
#   # Edit to customize, then add to config

set -euo pipefail

# ============================================================================
# Example: Skip beads tagged as needing human intervention
# ============================================================================
if echo "${NEEDLE_BEAD_LABELS:-}" | grep -q "needs-human"; then
    echo "Skipping bead ${NEEDLE_BEAD_ID:-}: tagged 'needs-human'"
    exit 3  # Skip to next bead
fi

# ============================================================================
# Example: Skip beads of type 'human'
# ============================================================================
# if [[ "${NEEDLE_BEAD_TYPE:-}" == "human" ]]; then
#     echo "Skipping human bead ${NEEDLE_BEAD_ID:-}"
#     exit 3
# fi

# ============================================================================
# Example: Only process high-priority beads (priority <= 1)
# ============================================================================
# if [[ "${NEEDLE_BEAD_PRIORITY:-3}" -gt 1 ]]; then
#     echo "Skipping low-priority bead ${NEEDLE_BEAD_ID:-} (priority=${NEEDLE_BEAD_PRIORITY:-})"
#     exit 3
# fi

# Allow the claim
exit 0
