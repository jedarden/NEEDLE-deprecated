# Worker Starvation Alert Analysis: nd-270

**Date:** 2026-03-04
**Alert Bead:** nd-270
**Worker:** claude-code-glm-5-bravo
**Status:** FALSE POSITIVE - CLOSED

## Summary

Worker `claude-code-glm-5-bravo` triggered a starvation alert claiming "no work available", but investigation revealed the worker was already assigned to an open bead.

## Root Cause

The starvation detection logic did not check for **already-assigned beads** before triggering the alert. The worker has:

- **Assigned bead:** nd-bqi (Create default hook templates) - status OPEN
- **Assignee:** claude-code-glm-5-bravo

## Investigation Findings

### 1. Assigned Work Exists
```
nd-bqi [P2] - Create default hook templates (hooks/defaults/)
Assignee: claude-code-glm-5-bravo
Status: OPEN
```

### 2. No NEW Claimable Beads
All unassigned beads have open dependencies:

| Bead | Dependencies | Status |
|------|--------------|--------|
| nd-14y | nd-vt9, nd-2kh | Blocked |
| nd-20k | nd-39i | Blocked |
| nd-38g | nd-n0y, nd-39i | Blocked |
| nd-n0y | nd-39i | Blocked |
| nd-2q6 | nd-bqi | Blocked |
| nd-gn2 | nd-qpj-1 | Blocked |
| nd-1fr | nd-qpj-1 | Blocked |
| nd-21h | nd-qpj-1 | Blocked |

### 3. Dependency Chain
The blocking beads (nd-vt9, nd-2kh, nd-39i, nd-bqi, nd-qpj-1) are all assigned to either "coder" or other workers and still open.

## Resolution

Closed nd-270 as false positive. Worker should continue working on assigned bead nd-bqi.

## Recommended Fix

The starvation detection (Priority 6 in worker loop) should check for:

1. **Assigned beads first** - If worker has assigned but incomplete beads, that's work
2. **Claimable beads second** - Only alert if no assigned AND no claimable beads

### Suggested Code Change (src/strands/knot.sh)

```bash
# Before alerting, check for assigned work
assigned_beads=$(br list --assignee "$WORKER_NAME" --status open --json 2>/dev/null | jq 'length')
if [[ "$assigned_beads" -gt 0 ]]; then
    _needle_debug "Worker has $assigned_beads assigned bead(s) - not starving"
    return 0
fi

# Then check for claimable beads
claimable=$(_needle_get_claimable_beads --workspace "$WORKSPACE" | jq 'length')
if [[ "$claimable" -gt 0 ]]; then
    _needle_debug "Found $claimable claimable beads - not starving"
    return 0
fi

# Only alert if truly no work
_create_starvation_alert
```

## Related

- `docs/worker-starvation-false-positive.md` - Previous false positive analysis
- `src/bead/select.sh` - Claimable bead detection
- `nd-bqi` - Assigned bead for this worker

## Skills

- `worker-starvation-false-positive` - Pattern for handling this scenario
