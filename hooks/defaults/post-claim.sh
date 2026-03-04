#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: post-claim
# ============================================================================
#
# PURPOSE:
#   Runs AFTER a worker successfully claims a bead. Use this hook to send
#   notifications, set up tracking, or prepare resources for execution.
#
# WHEN CALLED:
#   Immediately after the worker has registered ownership of the bead.
#   The bead is now in "claimed" state.
#
# EXIT CODES:
#   0 - Success: Continue normally (claim is already done)
#   1 - Warning: Log warning but continue
#   2 - Abort: Release the claim and mark bead as available again
#   3 - Skip: Skip remaining post-claim hooks
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("post_claim")
# NEEDLE_BEAD_ID       - ID of the claimed bead
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0-4)
# NEEDLE_BEAD_TYPE     - Type of bead
# NEEDLE_BEAD_LABELS   - Comma-separated labels
# NEEDLE_WORKSPACE     - Path to workspace
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_AGENT         - Agent name
# NEEDLE_STRAND        - Strand ID
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Send notification to Slack/Discord/Teams about claimed work
# 2. Log claim to external tracking system (Jira, Linear, etc.)
# 3. Prepare development environment for the bead
# 4. Create a scratch file for notes and research
# 5. Update metrics/monitoring about claim activity
#
# ============================================================================

set -euo pipefail

# ============================================================================
# NOTIFICATION EXAMPLES (Uncomment to enable)
# ============================================================================

echo "post-claim hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Worker: ${NEEDLE_WORKER:-unknown}"
echo "  Session: ${NEEDLE_SESSION:-unknown}"
echo "  Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ----------------------------------------------------------------------------
# Example 1: Slack notification
# ----------------------------------------------------------------------------
# Uncomment and configure to enable Slack notifications:
#
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
#
# payload=$(cat <<EOF
# {
#   "text": "Bead Claimed",
#   "blocks": [
#     {
#       "type": "section",
#       "text": {
#         "type": "mrkdwn",
#         "text": "*${NEEDLE_BEAD_TITLE:-Bead}*\nClaimed by ${NEEDLE_WORKER:-worker}\nPriority: ${NEEDLE_BEAD_PRIORITY:-3} | ID: ${NEEDLE_BEAD_ID:-}"
#       }
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
# Example 2: Discord notification via webhook
# ----------------------------------------------------------------------------
# Uncomment and configure to enable Discord notifications:
#
# DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR/WEBHOOK/URL"
#
# curl -s -X POST \
#     -H "Content-Type: application/json" \
#     -d "{\"content\": \"**Bead Claimed**: ${NEEDLE_BEAD_TITLE:-} (ID: ${NEEDLE_BEAD_ID:-})\\nWorker: ${NEEDLE_WORKER:-}\"}" \
#     "$DISCORD_WEBHOOK_URL" > /dev/null

# ----------------------------------------------------------------------------
# Example 3: Create workspace notes file
# ----------------------------------------------------------------------------
# Uncomment to create a notes file for the bead:
#
# NOTES_FILE="${NEEDLE_WORKSPACE}/.needle/notes/${NEEDLE_BEAD_ID}.md"
# mkdir -p "$(dirname "$NOTES_FILE")"
#
# cat > "$NOTES_FILE" << EOF
# # Notes for ${NEEDLE_BEAD_ID}
#
# **Title:** ${NEEDLE_BEAD_TITLE:-}
# **Claimed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
# **Worker:** ${NEEDLE_WORKER:-}
#
# ## Progress
# - [ ] Started work
#
# ## Notes
#
# ## Blockers
#
# EOF
#
# echo "Created notes file: $NOTES_FILE"

# ----------------------------------------------------------------------------
# Example 4: Log to external tracking system
# ----------------------------------------------------------------------------
# Uncomment to log to an external API:
#
# TRACKING_API_URL="https://api.example.com/tracker/events"
# API_KEY="your-api-key"
#
# curl -s -X POST \
#     -H "Authorization: Bearer $API_KEY" \
#     -H "Content-Type: application/json" \
#     -d "{
#         \"event\": \"bead_claimed\",
#         \"bead_id\": \"${NEEDLE_BEAD_ID:-}\",
#         \"title\": \"${NEEDLE_BEAD_TITLE:-}\",
#         \"worker\": \"${NEEDLE_WORKER:-}\",
#         \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
#     }" \
#     "$TRACKING_API_URL" > /dev/null

# ----------------------------------------------------------------------------
# Example 5: Prepare development environment
# ----------------------------------------------------------------------------
# Uncomment to set up environment before execution:
#
# # Switch to workspace directory
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || true
#
# # Pull latest changes if in a git repo
# if git rev-parse --git-dir > /dev/null 2>&1; then
#     echo "Pulling latest changes..."
#     git pull --rebase 2>/dev/null || echo "Git pull failed, continuing anyway"
# fi
#
# # Install dependencies if package files exist
# if [[ -f "package.json" && ! -d "node_modules" ]]; then
#     echo "Installing npm dependencies..."
#     npm install --silent 2>/dev/null || echo "npm install failed, continuing anyway"
# fi

# ============================================================================
# Default: Continue normally
# ============================================================================
exit 0
