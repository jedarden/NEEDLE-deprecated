#!/usr/bin/env bash
# NEEDLE Default Post-Complete Hook Template
#
# This script runs after a bead is marked complete. Use it for
# notifications, cleanup, metrics reporting, or any post-completion
# side effects.
#
# Exit Codes:
#   0   - Success (continue normally)
#   1   - Warning (log warning but continue)
#   2   - Abort (log error, but bead is already complete)
#   124 - Timeout (hook exceeded timeout limit)
#
# Environment Variables:
#   NEEDLE_HOOK           - Hook name ("post_complete")
#   NEEDLE_BEAD_ID        - Completed bead ID
#   NEEDLE_BEAD_TITLE     - Bead title
#   NEEDLE_BEAD_PRIORITY  - Bead priority (0=critical, 4=backlog)
#   NEEDLE_BEAD_TYPE      - Bead type
#   NEEDLE_BEAD_LABELS    - Comma-separated list of labels
#   NEEDLE_WORKER         - Worker/session ID
#   NEEDLE_WORKSPACE      - Current workspace path
#   NEEDLE_SESSION        - Worker session ID
#   NEEDLE_EXIT_CODE      - Agent exit code from execution
#   NEEDLE_DURATION_MS    - Total execution duration in milliseconds
#   NEEDLE_FILES_CHANGED  - Number of files changed
#   NEEDLE_LINES_ADDED    - Number of lines added
#   NEEDLE_LINES_REMOVED  - Number of lines removed
#
# Configuration (in ~/.needle/config.yaml or .needle.yaml):
#   hooks:
#     post_complete: ~/.needle/hooks/post-complete.sh
#
# To use this template:
#   cp src/hooks/defaults/post-complete.sh ~/.needle/hooks/post-complete.sh
#   chmod +x ~/.needle/hooks/post-complete.sh
#   # Edit to customize, then add to config

set -euo pipefail

# ============================================================================
# Example: Log completion summary
# ============================================================================
echo "Bead ${NEEDLE_BEAD_ID:-} completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -n "${NEEDLE_BEAD_TITLE:-}" ]]; then
    echo "  Title:    ${NEEDLE_BEAD_TITLE}"
fi
if [[ -n "${NEEDLE_DURATION_MS:-}" ]]; then
    echo "  Duration: ${NEEDLE_DURATION_MS}ms"
fi
if [[ -n "${NEEDLE_FILES_CHANGED:-}" ]] && [[ "${NEEDLE_FILES_CHANGED}" -gt 0 ]]; then
    echo "  Files:    ${NEEDLE_FILES_CHANGED} changed (+${NEEDLE_LINES_ADDED:-0}/-${NEEDLE_LINES_REMOVED:-0} lines)"
fi

# ============================================================================
# Example: Send Slack notification
# ============================================================================
# if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
#     curl -s -X POST "$SLACK_WEBHOOK" \
#         -H "Content-Type: application/json" \
#         -d "{
#           \"text\": \"Bead *${NEEDLE_BEAD_TITLE:-${NEEDLE_BEAD_ID:-}}* completed\",
#           \"blocks\": [{
#             \"type\": \"section\",
#             \"text\": {
#               \"type\": \"mrkdwn\",
#               \"text\": \"*Bead:* ${NEEDLE_BEAD_ID:-}\\n*Worker:* ${NEEDLE_WORKER:-}\\n*Duration:* ${NEEDLE_DURATION_MS:-}ms\"
#             }
#           }]
#         }" || true
# fi

# ============================================================================
# Example: Run a post-completion script in the workspace
# ============================================================================
# if [[ -n "${NEEDLE_WORKSPACE:-}" ]] && [[ -f "${NEEDLE_WORKSPACE}/.needle/on-complete.sh" ]]; then
#     bash "${NEEDLE_WORKSPACE}/.needle/on-complete.sh" || true
# fi

exit 0
