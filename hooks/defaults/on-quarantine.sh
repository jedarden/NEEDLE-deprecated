#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: on-quarantine
# ============================================================================
#
# PURPOSE:
#   Runs when a bead is moved to QUARANTINE state. Use this hook to
#   escalate issues, create human intervention tasks, or trigger alerts.
#
# WHEN CALLED:
#   After a bead has been quarantined due to repeated failures or
#   explicit quarantine action. The bead is now blocked from automatic
#   execution and requires human intervention.
#
# EXIT CODES:
#   0 - Success: Continue with quarantine handling
#   1 - Warning: Log warning but continue
#   2 - Abort: Ignored (bead is already quarantined)
#   3 - Skip: Skip remaining on-quarantine hooks
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("on_quarantine")
# NEEDLE_BEAD_ID       - ID of the quarantined bead
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0-4)
# NEEDLE_BEAD_TYPE     - Type of bead
# NEEDLE_BEAD_LABELS   - Comma-separated labels
# NEEDLE_WORKSPACE     - Path to workspace
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_EXIT_CODE     - Exit code that triggered quarantine
# NEEDLE_DURATION_MS   - Duration before failure
# NEEDLE_OUTPUT_FILE   - Path to output file with failure details
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Create a human intervention bead/task automatically
# 2. Send escalation notification to team leads
# 3. Post to incident channel for visibility
# 4. Create a Jira/GitHub issue for investigation
# 5. Update metrics on quarantine events
# 6. Check for similar quarantined beads (pattern detection)
#
# ============================================================================

set -euo pipefail

# ============================================================================
# ESCALATION EXAMPLES (Uncomment to enable)
# ============================================================================

echo "on-quarantine hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Title: ${NEEDLE_BEAD_TITLE:-}"
echo "  Exit code: ${NEEDLE_EXIT_CODE:-unknown}"
echo "  Worker: ${NEEDLE_WORKER:-unknown}"
echo "  Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Collect failure context
failure_context=""
if [[ -n "${NEEDLE_OUTPUT_FILE:-}" ]] && [[ -f "${NEEDLE_OUTPUT_FILE:-}" ]]; then
    failure_context=$(tail -200 "${NEEDLE_OUTPUT_FILE:-}" 2>/dev/null || echo "Could not read output file")
fi

# Determine urgency based on priority
urgency="normal"
case "${NEEDLE_BEAD_PRIORITY:-3}" in
    0) urgency="critical" ;;
    1) urgency="high" ;;
    2) urgency="normal" ;;
    *) urgency="low" ;;
esac

echo "  Urgency: $urgency"

# ----------------------------------------------------------------------------
# Example 1: Slack escalation notification
# ----------------------------------------------------------------------------
# Uncomment and configure to enable Slack escalation:
#
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
# # Use a different channel for quarantines (e.g., #incidents or #alerts)
#
# # Truncate context for Slack
# truncated_context="${failure_context:0:300}"
# [[ ${#failure_context} -gt 300 ]] && truncated_context="${truncated_context}..."
#
# payload=$(cat <<EOF
# {
#   "text": "Bead Quarantined - Human Intervention Required",
#   "blocks": [
#     {
#       "type": "header",
#       "text": {
#         "type": "plain_text",
#         "text": ":bangbang: Bead Quarantined"
#       }
#     },
#     {
#       "type": "section",
#       "text": {
#         "type": "mrkdwn",
#         "text": "*${NEEDLE_BEAD_TITLE:-Bead}*\n:warning: This bead has been quarantined after repeated failures.\n:person_standing: Human intervention required."
#       }
#     },
#     {
#       "type": "section",
#       "fields": [
#         {"type": "mrkdwn", "text": "*Urgency:*\n${urgency}"},
#         {"type": "mrkdwn", "text": "*Worker:*\n${NEEDLE_WORKER:-unknown}"},
#         {"type": "mrkdwn", "text": "*Exit Code:*\n${NEEDLE_EXIT_CODE:-1}"},
#         {"type": "mrkdwn", "text": "*ID:*\n${NEEDLE_BEAD_ID:-}"}
#       ]
#     },
#     {
#       "type": "section",
#       "text": {
#         "type": "mrkdwn",
#         "text": "*Last Error:*\n\`\`\`${truncated_context}\`\`\`"
#       }
#     },
#     {
#       "type": "actions",
#       "elements": [
#         {
#           "type": "button",
#           "text": {"type": "plain_text", "text": "View Bead"},
#           "url": "https://your-needle-dashboard.com/beads/${NEEDLE_BEAD_ID:-}"
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
# Example 2: Create human intervention bead
# ----------------------------------------------------------------------------
# Uncomment to automatically create a human bead:
#
# if command -v br > /dev/null 2>&1; then
#     echo "Creating human intervention bead..."
#
#     # Create a human-type bead for investigation
#     human_bead=$(br create \
#         --type human \
#         --priority "${NEEDLE_BEAD_PRIORITY:-3}" \
#         --title "HUMAN: Investigate quarantined bead ${NEEDLE_BEAD_ID:-}" \
#         --description "## Quarantined Bead Investigation
#
# A bead has been quarantined and requires human investigation.
#
# ### Original Bead
# - **ID:** ${NEEDLE_BEAD_ID:-}
# - **Title:** ${NEEDLE_BEAD_TITLE:-}
# - **Priority:** ${NEEDLE_BEAD_PRIORITY:-3}
# - **Labels:** ${NEEDLE_BEAD_LABELS:-}
#
# ### Failure Details
# - **Exit Code:** ${NEEDLE_EXIT_CODE:-1}
# - **Worker:** ${NEEDLE_WORKER:-unknown}
# - **Workspace:** ${NEEDLE_WORKSPACE:-}
#
# ### Error Context
# \`\`\`
# ${failure_context:0:1000}
# \`\`\`
#
# ### Actions Required
# 1. Review the error context above
# 2. Determine root cause
# 3. Fix the underlying issue
# 4. Close this bead and unquarantine the original bead
#
# ### Options for Resolution
# 1. **Fix the underlying issue** - Correct the code/configuration
# 2. **Update bead requirements** - If requirements were unclear
# 3. **Mark as wontfix** - If the task is no longer needed
# 4. **Escalate further** - If additional resources needed
# " \
#         2>/dev/null | grep -oP 'Created issue \K[a-z0-9-]+')
#
#     if [[ -n "$human_bead" ]]; then
#         echo "Created human intervention bead: $human_bead"
#         # Optionally add dependency
#         br dep add "$human_bead" --depends-on "${NEEDLE_BEAD_ID:-}" 2>/dev/null || true
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 3: Email escalation
# ----------------------------------------------------------------------------
# Uncomment to send email notification:
#
# if command -v mail > /dev/null 2>&1; then
#     recipients="team-lead@example.com,oncall@example.com"
#
#     subject="[NEEDLE] Quarantined Bead: ${NEEDLE_BEAD_TITLE:-}"
#
#     body="A bead has been quarantined and requires human intervention.
#
# Bead ID: ${NEEDLE_BEAD_ID:-}
# Title: ${NEEDLE_BEAD_TITLE:-}
# Priority: ${NEEDLE_BEAD_PRIORITY:-3} (${urgency})
# Exit Code: ${NEEDLE_EXIT_CODE:-1}
# Worker: ${NEEDLE_WORKER:-unknown}
# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Error Context:
# ${failure_context:0:1000}
#
# Please investigate and take appropriate action.
# "
#
#     echo "$body" | mail -s "$subject" "$recipients"
#     echo "Escalation email sent to: $recipients"
# fi

# ----------------------------------------------------------------------------
# Example 4: Create GitHub issue for tracking
# ----------------------------------------------------------------------------
# Uncomment to create a GitHub issue:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if command -v gh > /dev/null 2>&1 && git rev-parse --git-dir > /dev/null 2>&1; then
#     repo=$(git remote get-url origin | sed 's/.*github.com[/:]//' | sed 's/.git$//')
#
#     echo "Creating GitHub issue for quarantine..."
#
#     issue_url=$(gh issue create \
#         --repo "$repo" \
#         --title "[Quarantine] ${NEEDLE_BEAD_ID:-}: ${NEEDLE_BEAD_TITLE:-}" \
#         --body "## Quarantined Bead
#
# This issue was automatically created for a quarantined bead.
#
# ### Bead Details
# | Field | Value |
# |-------|-------|
# | ID | ${NEEDLE_BEAD_ID:-} |
# | Title | ${NEEDLE_BEAD_TITLE:-} |
# | Priority | ${NEEDLE_BEAD_PRIORITY:-3} |
# | Labels | ${NEEDLE_BEAD_LABELS:-} |
# | Exit Code | ${NEEDLE_EXIT_CODE:-1} |
# | Worker | ${NEEDLE_WORKER:-unknown} |
#
# ### Error Context
#
# \`\`\`
# ${failure_context:0:2000}
# \`\`\`
#
# ### Resolution Steps
# 1. [ ] Investigate root cause
# 2. [ ] Implement fix
# 3. [ ] Unquarantine bead for retry
#
# /cc @team-leads
# " \
#         --label "quarantine,needs-investigation" \
#         2>/dev/null)
#
#     if [[ -n "$issue_url" ]]; then
#         echo "Created tracking issue: $issue_url"
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 5: Update metrics/monitoring
# ----------------------------------------------------------------------------
# Uncomment to send metrics:
#
# if command -v curl > /dev/null 2>&1; then
#     METRICS_URL="https://metrics.example.com/api/v1/events"
#
#     curl -s -X POST \
#         -H "Content-Type: application/json" \
#         -d "{
#             \"event\": \"bead_quarantined\",
#             \"bead_id\": \"${NEEDLE_BEAD_ID:-}\",
#             \"title\": \"${NEEDLE_BEAD_TITLE:-}\",
#             \"priority\": ${NEEDLE_BEAD_PRIORITY:-3},
#             \"urgency\": \"${urgency}\",
#             \"exit_code\": ${NEEDLE_EXIT_CODE:-1},
#             \"worker\": \"${NEEDLE_WORKER:-unknown}\",
#             \"labels\": \"${NEEDLE_BEAD_LABELS:-}\",
#             \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
#         }" \
#         "$METRICS_URL" > /dev/null 2>&1 || true
# fi

# ----------------------------------------------------------------------------
# Example 6: Check for similar quarantined beads (pattern detection)
# ----------------------------------------------------------------------------
# Uncomment to detect patterns:
#
# if command -v br > /dev/null 2>&1; then
#     # Check for other quarantined beads with similar labels
#     similar_count=0
#
#     if [[ -n "${NEEDLE_BEAD_LABELS:-}" ]]; then
#         for label in ${NEEDLE_BEAD_LABELS//,/ }; do
#             count=$(br list --status quarantined --label "$label" 2>/dev/null | wc -l)
#             similar_count=$((similar_count + count))
#         done
#     fi
#
#     if [[ $similar_count -gt 3 ]]; then
#         echo "WARNING: Multiple similar beads quarantined ($similar_count total)"
#         echo "This may indicate a systemic issue with: ${NEEDLE_BEAD_LABELS:-}"
#
#         # Could trigger additional escalation here
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 7: Auto-unquarantine after cooldown (advanced)
# ----------------------------------------------------------------------------
# Uncomment for auto-retry after cooldown:
#
# COOLDOWN_MINUTES=30
# MAX_AUTO_RETRIES=3
#
# # Check if this bead has been auto-retried before
# RETRY_COUNT_FILE="/tmp/needle-retries/${NEEDLE_BEAD_ID:-}.count"
#
# if [[ -f "$RETRY_COUNT_FILE" ]]; then
#     retry_count=$(cat "$RETRY_COUNT_FILE")
# else
#     retry_count=0
# fi
#
# if [[ $retry_count -lt $MAX_AUTO_RETRIES ]]; then
#     echo "Scheduling auto-unquarantine in ${COOLDOWN_MINUTES} minutes (attempt $((retry_count + 1))/$MAX_AUTO_RETRIES)..."
#
#     # Schedule unquarantine (requires a scheduler like at or cron)
#     if command -v at > /dev/null 2>&1; then
#         echo "br unquarantine ${NEEDLE_BEAD_ID:-}" | at "now + $COOLDOWN_MINUTES minutes" 2>/dev/null || true
#         echo $((retry_count + 1)) > "$RETRY_COUNT_FILE"
#     fi
# else
#     echo "Max auto-retries ($MAX_AUTO_RETRIES) reached. Permanent quarantine."
# fi

# ============================================================================
# Default: Continue with standard quarantine handling
# ============================================================================
echo "Quarantine handling complete for bead: ${NEEDLE_BEAD_ID:-unknown}"
exit 0
