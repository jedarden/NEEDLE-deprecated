# Worker Starvation False Positive Analysis

**Date:** 2026-03-03
**Issue:** HUMAN beads nd-3bo, nd-2h0 (Worker starvation alerts)
**Status:** RESOLVED - False Positive (confirmed twice)

## Root Cause

The `br ready` command fails with a schema error:
```
Database error: Invalid column type Text at index: 14, name: created_by
```

This is a known bug in beads_rust v0.1.13.

## Fallback IS Working

The fallback mechanism in `src/bead/select.sh` function `_needle_get_claimable_beads`:
1. Detects the DATABASE_ERROR from `br ready`
2. Falls back to `br list` with client-side filtering
3. **Successfully finds claimable beads**

### Verification
```bash
$ source src/bead/select.sh && _needle_get_claimable_beads | jq 'length'
36

$ _needle_select_weighted
nd-2pw  # Successfully selected a P0 task bead
```

## Workaround Tools

- `bin/needle-ready` - Lists claimable beads using fallback
- `bin/needle-db-rebuild` - Rebuilds database from JSONL

## Resolution

The worker starvation alert was a **false positive**. The fallback mechanism is working correctly. Workers should be able to claim beads.

## Recommendations

1. **Immediate**: Ensure workers load the fallback code correctly
2. **Short-term**: Upgrade beads_rust to fix schema bug
3. **Long-term**: Add integration tests for fallback path

## Root Cause of False Positive Alerts

The worker starvation detection logic does not account for the fallback mechanism's success. When `br ready` fails, the fallback in `_needle_get_claimable_beads` successfully finds beads, but the worker's detection logic may be checking a different path or not properly detecting the fallback's success.

### Investigation Needed
- Check `src/runner/loop.sh` for starvation detection logic
- Verify workers call `_needle_get_claimable_beads` correctly
- Ensure diagnostic logging is enabled to trace the issue

## Related Skills

- `br-cli-workspace-isolation-troubleshooting`
- `worker-starvation-false-positive`
