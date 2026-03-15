#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: post-complete
# ============================================================================
#
# PURPOSE:
#   Runs AFTER a bead is marked as complete. Use this hook to send
#   notifications, update external systems, or trigger follow-up actions.
#
# WHEN CALLED:
#   After the bead has been successfully marked as complete.
#   The work is done and finalized.
#
# EXIT CODES:
#   0 - Success: Continue normally
#   1 - Warning: Log warning but continue (bead is already complete)
#   2 - Abort: Ignored (bead is already complete, but logs error)
#   3 - Skip: Skip remaining post-complete hooks
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("post_complete")
# NEEDLE_BEAD_ID       - ID of the completed bead
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0-4)
# NEEDLE_BEAD_TYPE     - Type of bead
# NEEDLE_BEAD_LABELS   - Comma-separated labels
# NEEDLE_WORKSPACE     - Path to workspace
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_EXIT_CODE     - Exit code from execution
# NEEDLE_DURATION_MS   - Duration of execution
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Send Slack/Discord notification about completion
# 2. Update external issue tracker (Jira, Linear, GitHub)
# 3. Trigger CI/CD pipelines
# 4. Update team dashboards
# 5. Send email notifications to stakeholders
# 6. Create follow-up tasks automatically
#
# ============================================================================

set -euo pipefail

# ============================================================================
# NOTIFICATION EXAMPLES (Uncomment to enable)
# ============================================================================

echo "post-complete hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Title: ${NEEDLE_BEAD_TITLE:-}"
echo "  Worker: ${NEEDLE_WORKER:-unknown}"
echo "  Duration: ${NEEDLE_DURATION_MS:-unknown}ms"

# Calculate human-readable duration
duration_seconds=$(( (${NEEDLE_DURATION_MS:-0}) / 1000 ))
if [[ $duration_seconds -ge 3600 ]]; then
    hours=$(( duration_seconds / 3600 ))
    minutes=$(( (duration_seconds % 3600) / 60 ))
    duration_str="${hours}h ${minutes}m"
elif [[ $duration_seconds -ge 60 ]]; then
    minutes=$(( duration_seconds / 60 ))
    seconds=$(( duration_seconds % 60 ))
    duration_str="${minutes}m ${seconds}s"
else
    duration_str="${duration_seconds}s"
fi

echo "  Time to complete: $duration_str"

# ============================================================================
# Bead Cost Attribution
# ============================================================================
# Annotate the bead with cost data from session logs.
# This joins effort.recorded events back to the bead record so cost is
# visible per-bead in `br show <id>`.
#
# The runner (loop.sh, pluck.sh) also does this annotation, but we do it
# here as well for redundancy and to support manual bead closures.
if [[ -n "${NEEDLE_BEAD_ID:-}" ]] && [[ -n "${NEEDLE_WORKSPACE:-}" ]]; then
    # Source the effort module if not already loaded
    if declare -F _needle_annotate_bead_with_effort >/dev/null 2>&1; then
        _needle_annotate_bead_with_effort "${NEEDLE_BEAD_ID}" "${NEEDLE_WORKSPACE}" 2>/dev/null || true
    else
        # Try to source and run directly
        effort_module="${NEEDLE_HOME:-$HOME/.needle}/src/telemetry/effort.sh"
        if [[ -f "$effort_module" ]]; then
            # Source and run annotation in subshell to avoid polluting environment
            (
                source "$effort_module" >/dev/null 2>&1
                if declare -F _needle_annotate_bead_with_effort >/dev/null 2>&1; then
                    _needle_annotate_bead_with_effort "${NEEDLE_BEAD_ID}" "${NEEDLE_WORKSPACE}" 2>/dev/null || true
                fi
            )
        fi
    fi
fi

# ----------------------------------------------------------------------------
# Example 1: Slack notification
# ----------------------------------------------------------------------------
# Uncomment and configure to enable Slack notifications:
#
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
#
# # Build status emoji based on priority
# case "${NEEDLE_BEAD_PRIORITY:-3}" in
#     0) emoji=":fire:" ;;     # Critical
#     1) emoji=":rocket:" ;;   # High
#     2) emoji=":white_check_mark:" ;; # Normal
#     *) emoji=":checkered_flag:" ;;   # Low/Backlog
# esac
#
# payload=$(cat <<EOF
# {
#   "text": "Bead Completed",
#   "blocks": [
#     {
#       "type": "header",
#       "text": {
#         "type": "plain_text",
#         "text": "${emoji} Bead Completed"
#       }
#     },
#     {
#       "type": "section",
#       "text": {
#         "type": "mrkdwn",
#         "text": "*${NEEDLE_BEAD_TITLE:-Bead}*\n:timer_clock: Completed in ${duration_str}\n:bust_in_silhouette: ${NEEDLE_WORKER:-unknown}"
#       }
#     },
#     {
#       "type": "context",
#       "elements": [
#         {
#           "type": "mrkdwn",
#           "text": "ID: ${NEEDLE_BEAD_ID:-} | Labels: ${NEEDLE_BEAD_LABELS:-none}"
#         }
#       ]
#     }
#   ]
# }
# EOF
# )
#
# curl -s -X POST -H 'Content-type: application/json' \
#     --data "$payload" \
#     "$SLACK_WEBHOOK_URL" > /dev/null

# ----------------------------------------------------------------------------
# Example 2: Discord notification
# ----------------------------------------------------------------------------
# Uncomment and configure to enable Discord notifications:
#
# DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR/WEBHOOK/URL"
#
# curl -s -X POST \
#     -H "Content-Type: application/json" \
#     -d "{
#         \"embeds\": [{
#             \"title\": \"Bead Completed\",
#             \"description\": \"**${NEEDLE_BEAD_TITLE:-}**\",
#             \"color\": 3066993,
#             \"fields\": [
#                 {\"name\": \"Worker\", \"value\": \"${NEEDLE_WORKER:-unknown}\", \"inline\": true},
#                 {\"name\": \"Duration\", \"value\": \"${duration_str}\", \"inline\": true},
#                 {\"name\": \"ID\", \"value\": \"${NEEDLE_BEAD_ID:-}\", \"inline\": false}
#             ],
#             \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
#         }]
#     }" \
#     "$DISCORD_WEBHOOK_URL" > /dev/null

# ----------------------------------------------------------------------------
# Example 3: Update GitHub issue
# ----------------------------------------------------------------------------
# Uncomment to close or update a linked GitHub issue:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if command -v gh > /dev/null 2>&1; then
#     # If the bead ID looks like a GitHub issue reference (owner/repo#123)
#     if [[ "${NEEDLE_BEAD_ID:-}" =~ ^([a-zA-Z0-9_-]+)/([a-zA-Z0-9_-]+)#([0-9]+)$ ]]; then
#         owner="${BASH_REMATCH[1]}"
#         repo="${BASH_REMATCH[2]}"
#         issue="${BASH_REMATCH[3]}"
#
#         echo "Closing GitHub issue ${owner}/${repo}#${issue}..."
#         gh issue close "${owner}/${repo}#${issue}" \
#             --comment "Completed by ${NEEDLE_WORKER:-worker} in ${duration_str}" \
#             2>/dev/null || echo "Note: Could not close GitHub issue"
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 4: Update external issue tracker (Jira example)
# ----------------------------------------------------------------------------
# Uncomment to update Jira:
#
# JIRA_URL="https://your-company.atlassian.net"
# JIRA_API_TOKEN="your-api-token"
#
# # If bead ID looks like a Jira ticket (PROJECT-123)
# if [[ "${NEEDLE_BEAD_ID:-}" =~ ^[A-Z]+-[0-9]+$ ]]; then
#     echo "Updating Jira ticket ${NEEDLE_BEAD_ID}..."
#
#     curl -s -X POST \
#         -H "Authorization: Bearer $JIRA_API_TOKEN" \
#         -H "Content-Type: application/json" \
#         -d "{
#             \"transition\": {\"id\": \"31\"},
#             \"fields\": {\"comment\": {
#                 \"add\": {\"body\": \"Completed by ${NEEDLE_WORKER:-worker} in ${duration_str}\"}
#             }}
#         }" \
#         "${JIRA_URL}/rest/api/3/issue/${NEEDLE_BEAD_ID}/transitions" \
#         > /dev/null 2>&1 || echo "Note: Could not update Jira"
# fi

# ----------------------------------------------------------------------------
# Example 5: Trigger CI/CD pipeline
# ----------------------------------------------------------------------------
# Uncomment to trigger a deployment pipeline:
#
# if command -v curl > /dev/null 2>&1; then
#     # Trigger GitHub Actions workflow
#     GITHUB_TOKEN="your-token"
#     REPO="owner/repo"
#
#     curl -s -X POST \
#         -H "Authorization: token $GITHUB_TOKEN" \
#         -H "Accept: application/vnd.github.v3+json" \
#         -d "{\"ref\": \"main\", \"inputs\": {\"bead_id\": \"${NEEDLE_BEAD_ID:-}\"}}" \
#         "https://api.github.com/repos/${REPO}/actions/workflows/deploy.yml/dispatches" \
#         > /dev/null 2>&1 || echo "Note: Could not trigger deployment"
# fi

# ----------------------------------------------------------------------------
# Example 6: Update metrics dashboard
# ----------------------------------------------------------------------------
# Uncomment to send metrics to a dashboard:
#
# if command -v curl > /dev/null 2>&1; then
#     METRICS_URL="https://metrics.example.com/api/v1/completions"
#
#     curl -s -X POST \
#         -H "Content-Type: application/json" \
#         -d "{
#             \"bead_id\": \"${NEEDLE_BEAD_ID:-}\",
#             \"title\": \"${NEEDLE_BEAD_TITLE:-}\",
#             \"worker\": \"${NEEDLE_WORKER:-unknown}\",
#             \"duration_ms\": ${NEEDLE_DURATION_MS:-0},
#             \"priority\": ${NEEDLE_BEAD_PRIORITY:-3},
#             \"labels\": \"${NEEDLE_BEAD_LABELS:-}\",
#             \"completed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
#         }" \
#         "$METRICS_URL" > /dev/null 2>&1 || true
# fi

# ============================================================================
# Default: Continue normally
# ============================================================================
echo "Post-completion processing done for bead: ${NEEDLE_BEAD_ID:-unknown}"
exit 0
