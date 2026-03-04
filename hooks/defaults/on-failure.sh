#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: on-failure
# ============================================================================
#
# PURPOSE:
#   Runs when a bead execution FAILS. Use this hook to alert on failures,
#   capture diagnostic information, or trigger escalation procedures.
#
# WHEN CALLED:
#   After execution has failed (non-zero exit code or error).
#   The bead may be marked for retry or quarantine depending on error type.
#
# EXIT CODES:
#   0 - Success: Continue with failure handling (bead will be retried/quarantined)
#   1 - Warning: Log warning but continue
#   2 - Abort: Immediately quarantine the bead (skip retry attempts)
#   3 - Skip: Skip remaining on-failure hooks
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("on_failure")
# NEEDLE_BEAD_ID       - ID of the failed bead
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0-4)
# NEEDLE_BEAD_TYPE     - Type of bead
# NEEDLE_BEAD_LABELS   - Comma-separated labels
# NEEDLE_WORKSPACE     - Path to workspace
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_EXIT_CODE     - Exit code from execution (non-zero)
# NEEDLE_DURATION_MS   - Duration before failure
# NEEDLE_OUTPUT_FILE   - Path to output file with error details
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Send alert to on-call team (PagerDuty, Opsgenie)
# 2. Post failure notification to Slack/Discord
# 3. Collect diagnostic information (logs, stack traces)
# 4. Create incident ticket automatically
# 5. Check for specific error patterns and handle accordingly
# 6. Determine if failure should be retried or quarantined
#
# ============================================================================

set -euo pipefail

# ============================================================================
# ALERTING EXAMPLES (Uncomment to enable)
# ============================================================================

echo "on-failure hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Title: ${NEEDLE_BEAD_TITLE:-}"
echo "  Exit code: ${NEEDLE_EXIT_CODE:-unknown}"
echo "  Worker: ${NEEDLE_WORKER:-unknown}"
echo "  Duration before failure: ${NEEDLE_DURATION_MS:-unknown}ms"

# Collect error context
error_context=""
if [[ -n "${NEEDLE_OUTPUT_FILE:-}" ]] && [[ -f "${NEEDLE_OUTPUT_FILE:-}" ]]; then
    error_context=$(tail -100 "${NEEDLE_OUTPUT_FILE:-}" 2>/dev/null || echo "Could not read output file")
fi

# ----------------------------------------------------------------------------
# Example 1: Slack alert
# ----------------------------------------------------------------------------
# Uncomment and configure to enable Slack failure alerts:
#
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
#
# # Determine severity emoji based on priority
# case "${NEEDLE_BEAD_PRIORITY:-3}" in
#     0) emoji=":rotating_light:" ;;  # Critical
#     1) emoji=":warning:" ;;         # High
#     2) emoji=":exclamation:" ;;     # Normal
#     *) emoji=":information_source:" ;; # Low
# esac
#
# # Truncate error context if too long
# truncated_context="${error_context:0:500}"
# [[ ${#error_context} -gt 500 ]] && truncated_context="${truncated_context}..."
#
# payload=$(cat <<EOF
# {
#   "text": "Bead Execution Failed",
#   "blocks": [
#     {
#       "type": "header",
#       "text": {
#         "type": "plain_text",
#         "text": "${emoji} Bead Failed"
#       }
#     },
#     {
#       "type": "section",
#       "text": {
#         "type": "mrkdwn",
#         "text": "*${NEEDLE_BEAD_TITLE:-Bead}*\n:x: Exit code: ${NEEDLE_EXIT_CODE:-1}\n:bust_in_silhouette: Worker: ${NEEDLE_WORKER:-unknown}"
#       }
#     },
#     {
#       "type": "section",
#       "text": {
#         "type": "mrkdwn",
#         "text": "*Error Context:*\n\`\`\`${truncated_context}\`\`\`"
#       }
#     },
#     {
#       "type": "context",
#       "elements": [
#         {"type": "mrkdwn", "text": "ID: ${NEEDLE_BEAD_ID:-} | ${NEEDLE_BEAD_LABELS:-}"}
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
# Example 2: PagerDuty alert for critical failures
# ----------------------------------------------------------------------------
# Uncomment to trigger PagerDuty incident:
#
# PAGERDUTY_ROUTING_KEY="your-routing-key"
#
# # Only alert for critical or high priority failures
# if [[ "${NEEDLE_BEAD_PRIORITY:-3}" -le 1 ]]; then
#     echo "Triggering PagerDuty alert for critical failure..."
#
#     curl -s -X POST \
#         -H "Content-Type: application/json" \
#         -d "{
#             \"routing_key\": \"$PAGERDUTY_ROUTING_KEY\",
#             \"event_action\": \"trigger\",
#             \"dedup_key\": \"needle-failure-${NEEDLE_BEAD_ID:-}\",
#             \"payload\": {
#                 \"summary\": \"Bead failed: ${NEEDLE_BEAD_TITLE:-}\",
#                 \"severity\": \"$( [[ \"${NEEDLE_BEAD_PRIORITY:-3}\" -eq 0 ]] && echo 'critical' || echo 'error' )\",
#                 \"source\": \"needle-worker\",
#                 \"custom_details\": {
#                     \"bead_id\": \"${NEEDLE_BEAD_ID:-}\",
#                     \"exit_code\": ${NEEDLE_EXIT_CODE:-1},
#                     \"worker\": \"${NEEDLE_WORKER:-unknown}\",
#                     \"workspace\": \"${NEEDLE_WORKSPACE:-}\"
#                 }
#             }
#         }" \
#         "https://events.pagerduty.com/v2/enqueue" > /dev/null 2>&1 || true
# fi

# ----------------------------------------------------------------------------
# Example 3: Create GitHub issue for the failure
# ----------------------------------------------------------------------------
# Uncomment to create a tracking issue:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if command -v gh > /dev/null 2>&1 && git rev-parse --git-dir > /dev/null 2>&1; then
#     repo=$(git remote get-url origin | sed 's/.*github.com[/:]//' | sed 's/.git$//')
#
#     echo "Creating GitHub issue for failure..."
#
#     gh issue create \
#         --repo "$repo" \
#         --title "Bug: Bead execution failed - ${NEEDLE_BEAD_ID:-}" \
#         --body "## Failure Details
#
# **Bead ID:** ${NEEDLE_BEAD_ID:-}
# **Title:** ${NEEDLE_BEAD_TITLE:-}
# **Exit Code:** ${NEEDLE_EXIT_CODE:-1}
# **Worker:** ${NEEDLE_WORKER:-unknown}
# **Timestamp:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# ## Error Context
#
# \`\`\`
# ${error_context:0:2000}
# \`\`\`
#
# ## Labels
#
# ${NEEDLE_BEAD_LABELS:-none}
# " \
#         --label "bug,automated" \
#         2>/dev/null || echo "Note: Could not create GitHub issue"
# fi

# ----------------------------------------------------------------------------
# Example 4: Check for specific error patterns
# ----------------------------------------------------------------------------
# Uncomment to handle specific error types:
#
# # Check for common error patterns
# if echo "$error_context" | grep -qi "out of memory"; then
#     echo "Detected OOM error - may need resource increase"
#     # Could trigger auto-scaling or alert ops team
# fi
#
# if echo "$error_context" | grep -qi "timeout\|timed out"; then
#     echo "Detected timeout error - may need longer timeout"
#     # Could adjust timeout settings automatically
# fi
#
# if echo "$error_context" | grep -qi "permission denied\|access denied"; then
#     echo "Detected permission error - may need RBAC fix"
#     # Exit 2 to immediately quarantine - permission errors won't fix themselves
#     exit 2
# fi
#
# if echo "$error_context" | grep -qi "rate limit\|too many requests"; then
#     echo "Detected rate limiting - temporary issue"
#     # Allow retry - this is a transient error
# fi

# ----------------------------------------------------------------------------
# Example 5: Collect diagnostic information
# ----------------------------------------------------------------------------
# Uncomment to gather diagnostics:
#
# DIAG_DIR="/tmp/needle-diagnostics/${NEEDLE_BEAD_ID:-$$}"
# mkdir -p "$DIAG_DIR"
#
# echo "Collecting diagnostics to $DIAG_DIR..."
#
# # System state
# {
#     echo "=== System State ==="
#     echo "Date: $(date)"
#     echo "Uptime: $(uptime)"
#     echo "Memory:"
#     free -m 2>/dev/null || vm_stat 2>/dev/null || echo "Memory info unavailable"
#     echo "Disk:"
#     df -h 2>/dev/null || echo "Disk info unavailable"
# } > "$DIAG_DIR/system.txt"
#
# # Process list
# ps aux > "$DIAG_DIR/processes.txt" 2>/dev/null || true
#
# # Network connectivity
# {
#     echo "=== Network Test ==="
#     ping -c 3 google.com 2>&1 || echo "Ping failed"
# } > "$DIAG_DIR/network.txt"
#
# # Copy execution output
# if [[ -n "${NEEDLE_OUTPUT_FILE:-}" ]] && [[ -f "${NEEDLE_OUTPUT_FILE:-}" ]]; then
#     cp "${NEEDLE_OUTPUT_FILE:-}" "$DIAG_DIR/output.log"
# fi
#
# # Create archive
# tar -czf "/tmp/needle-diagnostics/${NEEDLE_BEAD_ID:-$$}.tar.gz" -C "$DIAG_DIR" .
# echo "Diagnostics archived to: /tmp/needle-diagnostics/${NEEDLE_BEAD_ID:-$$}.tar.gz"

# ----------------------------------------------------------------------------
# Example 6: Conditional retry vs quarantine decision
# ----------------------------------------------------------------------------
# Uncomment to control retry behavior:
#
# # List of error patterns that should NOT be retried
# PERMANENT_ERRORS=(
#     "permission denied"
#     "access denied"
#     "not found"
#     "invalid.*argument"
#     "syntax error"
#     "configuration error"
# )
#
# for pattern in "${PERMANENT_ERRORS[@]}"; do
#     if echo "$error_context" | grep -qi "$pattern"; then
#         echo "Detected permanent error pattern: $pattern"
#         echo "Quarantining bead instead of retrying"
#         exit 2  # Abort - go directly to quarantine
#     fi
# done
#
# # For transient errors, allow retry
# echo "Allowing retry for transient error"

# ============================================================================
# Default: Continue with standard failure handling
# ============================================================================
echo "Failure handling complete for bead: ${NEEDLE_BEAD_ID:-unknown}"
exit 0
