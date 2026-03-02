# Hook System Runner: Implementation Approaches Comparison

## Executive Summary

This document compares different approaches for implementing the NEEDLE hook system runner (`hooks/runner.sh`). The hook system enables users to customize NEEDLE behavior by running user-defined scripts at lifecycle events without modifying core code.

**Status**: The current implementation (Approach 1) is fully implemented and all 13 tests pass.

---

## Requirements

From bead nd-2w0, the hook system must:

1. Load hook paths from configuration
2. Set all NEEDLE_* environment variables for hooks
3. Respect timeout settings
4. Handle exit codes: 0=success, 1=warning, 2=abort, 3=skip
5. Support fail_action config (warn/abort/ignore)
6. Emit hook.started and hook.completed telemetry events
7. Handle missing/non-executable hooks gracefully

---

## Approach Comparison

### Approach 1: Synchronous Bash Functions (IMPLEMENTED)

**Status**: ✅ Implemented in `src/hooks/runner.sh`

**Description**:
Hook runner implemented as a set of bash functions that execute hooks synchronously within the main process context. Uses `timeout` command for execution time limits.

**Implementation Details**:
```bash
_needle_run_hook() {
    local hook_name="$1"
    local bead_id="${2:-}"

    # Get hook path from config
    local hook_path=$(get_config "hooks.$hook_name" "")

    # No hook configured - return success
    [[ -z "$hook_path" ]] && return 0

    # Expand ~ and check file exists
    hook_path="${hook_path/#\~/$HOME}"
    [[ ! -f "$hook_path" ]] && return 0

    # Execute with timeout
    timeout "$timeout_seconds" "$hook_path" 2>&1

    # Handle exit codes
    case "$exit_code" in
        0) return 0 ;;  # Success
        1) return 0 ;;  # Warning
        2) return 1 ;;  # Abort
        3) return 2 ;;  # Skip
        124) # Timeout - check fail_action
    esac
}
```

**Pros**:
- ✅ Simple implementation - no external dependencies
- ✅ Direct access to NEEDLE environment variables
- ✅ Easy to debug - hooks run in predictable sequence
- ✅ Low overhead - no process spawning complexity
- ✅ Telemetry events naturally integrated
- ✅ Fail-fast behavior is natural (abort stops execution)

**Cons**:
- ❌ Hooks block main thread during execution
- ❌ Long-running hooks delay other operations
- ❌ No parallel hook execution possible
- ❌ Hook crash could affect main process state

**Test Coverage**: 13 tests, all passing

---

### Approach 2: Asynchronous Hook Execution

**Description**:
Run hooks in background subprocesses using `&` and track completion asynchronously.

**Implementation Sketch**:
```bash
_needle_run_hook_async() {
    local hook_name="$1"
    local bead_id="${2:-}"
    local callback="${3:-}"

    # Spawn hook in background
    (
        _needle_set_hook_env "$bead_id"
        timeout "$timeout_seconds" "$hook_path"
    ) &

    local hook_pid=$!
    echo "$hook_pid:$hook_name:$SECONDS" >> "$NEEDLE_STATE_DIR/hooks.pending"

    # Optional: wait with callback
    if [[ -n "$callback" ]]; then
        wait "$hook_pid" && $callback 0 || $callback $?
    fi
}

_needle_check_pending_hooks() {
    while IFS=: read -r pid name start; do
        if ! kill -0 "$pid" 2>/dev/null; then
            # Hook completed, handle result
            wait "$pid"
            local exit_code=$?
            _needle_handle_hook_result "$name" "$exit_code"
        fi
    done < "$NEEDLE_STATE_DIR/hooks.pending"
}
```

**Pros**:
- ✅ Non-blocking - main loop continues immediately
- ✅ Better for long-running hooks (notifications, API calls)
- ✅ Multiple hooks can run concurrently
- ✅ Hook crashes isolated from main process

**Cons**:
- ❌ Complex state management for pending hooks
- ❌ Abort behavior difficult to implement (hook already spawned)
- ❌ Race conditions between hooks and main loop
- ❌ Requires polling or signal handling for completion
- ❌ More difficult to debug

**Complexity**: Medium-High

---

### Approach 3: Hook Queue with Dedicated Worker

**Description**:
Hooks are queued to a FIFO and processed by a dedicated background worker process.

**Implementation Sketch**:
```bash
# Main process queues hooks
_needle_queue_hook() {
    local hook_name="$1"
    local bead_id="$2"

    echo "{\"hook\":\"$hook_name\",\"bead_id\":\"$bead_id\",\"env\":$(env | jq -R . | jq -s .)}" \
        >> "$NEEDLE_STATE_DIR/hook-queue.fifo"
}

# Dedicated worker process
_needle_hook_worker() {
    while IFS= read -r hook_request; do
        local hook_name=$(echo "$hook_request" | jq -r '.hook')
        local bead_id=$(echo "$hook_request" | jq -r '.bead_id')

        # Execute hook
        _needle_run_hook "$hook_name" "$bead_id"
    done < "$NEEDLE_STATE_DIR/hook-queue.fifo"
}
```

**Pros**:
- ✅ Complete isolation - hooks in separate process
- ✅ Sequential hook execution guaranteed
- ✅ Main loop never blocked
- ✅ Worker can be restarted if crashed

**Cons**:
- ❌ Complex inter-process communication
- ❌ Environment variable passing is tricky
- ❌ Abort cannot stop already-queued hooks
- ❌ Additional process to manage
- ❌ FIFO management overhead

**Complexity**: High

---

### Approach 4: Event-Driven Hook System

**Description**:
Hooks are triggered by events emitted to an event bus. Hooks subscribe to event types.

**Implementation Sketch**:
```bash
# Hook configuration includes event subscriptions
hooks:
  subscriptions:
    - event: "bead.claimed"
      action: "pre_claim"
    - event: "bead.completed"
      action: "post_complete"

# Event emitter triggers hooks
_needle_emit_event() {
    local event_type="$1"
    shift

    # Record event for telemetry
    _needle_telemetry_emit "$event_type" "$@"

    # Trigger subscribed hooks
    for sub in "${NEEDLE_HOOK_SUBSCRIPTIONS[@]}"; do
        if [[ "$(echo "$sub" | jq -r '.event')" == "$event_type" ]]; then
            local action=$(echo "$sub" | jq -r '.action')
            _needle_run_hook "$action" "$@"
        fi
    done
}
```

**Pros**:
- ✅ Flexible event subscription model
- ✅ Hooks can subscribe to any event type
- ✅ Naturally integrates with telemetry system
- ✅ Easy to add new hook points without code changes

**Cons**:
- ❌ More complex configuration
- ❌ Event ordering can be confusing
- ❌ Performance overhead for event dispatch
- ❌ Overkill for current requirements

**Complexity**: Medium

---

### Approach 5: External Hook Runner Service

**Description**:
Hooks are executed by a completely separate service (could be HTTP-based).

**Implementation Sketch**:
```bash
# HTTP-based hook execution
_needle_run_hook_http() {
    local hook_name="$1"
    local bead_id="$2"

    local payload=$(jq -n \
        --arg hook "$hook_name" \
        --arg bead_id "$bead_id" \
        --argjson env "$(env | jq -R . | jq -s .)" \
        '{hook: $hook, bead_id: $bead_id, env: $env}')

    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://localhost:9876/hooks/execute"
}
```

**Pros**:
- ✅ Complete isolation from NEEDLE process
- ✅ Can be written in any language
- ✅ Scalable to multiple workers
- ✅ External service can have its own auth/logging

**Cons**:
- ❌ Requires external service to be running
- ❌ Network overhead for every hook
- ❌ Service availability becomes critical
- ❌ Debugging requires checking multiple systems
- ❌ Much higher operational complexity

**Complexity**: Very High

---

## Decision Matrix

| Criterion | Approach 1 | Approach 2 | Approach 3 | Approach 4 | Approach 5 |
|-----------|-----------|-----------|-----------|-----------|-----------|
| Simplicity | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐ |
| Debuggability | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐⭐ |
| Performance | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐ |
| Abort Support | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐ |
| Test Coverage | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐⭐ |
| Isolation | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## Recommendation

**Approach 1 (Synchronous Bash Functions)** is recommended and has been implemented because:

1. **Simplicity**: The implementation is straightforward and easy to maintain
2. **Debuggability**: Hooks run in sequence with predictable behavior
3. **Abort Support**: Critical feature for quality gates works naturally
4. **Test Coverage**: Comprehensive test suite (13 tests) validates all edge cases
5. **Integration**: Works seamlessly with existing telemetry and config systems

**When to Consider Alternatives**:

- **Approach 2** if long-running hooks become a bottleneck
- **Approach 4** if many new event types are needed
- **Approach 5** for enterprise deployments requiring isolation

---

## Future Considerations

### Potential Enhancements (Backward Compatible)

1. **Hook Caching**: Cache compiled hook scripts for interpreted languages
2. **Hook Chaining**: Allow hooks to call other hooks
3. **Conditional Hooks**: Run hooks only when conditions are met
4. **Hook Versioning**: Support multiple hook versions

### Breaking Changes (Major Version)

1. **Async by Default**: Make hooks async with sync option
2. **Event Subscription**: Full event-driven model
3. **Hook Sandbox**: Isolate hooks in containers/namespaces

---

## Appendix: Current Implementation

### File Locations
- Implementation: `src/hooks/runner.sh` (577 lines)
- Tests: `tests/test_hooks_runner.sh` (247 lines)
- Config: `src/lib/config.sh` (hooks section)
- Telemetry: `src/telemetry/events.sh` (hook events)

### Hook Types Supported
- `pre_claim` - Before claiming a bead
- `post_claim` - After claiming a bead
- `pre_execute` - Before executing a bead
- `post_execute` - After executing a bead
- `pre_complete` - Before completing a bead
- `post_complete` - After completing a bead
- `on_failure` - When a bead fails
- `on_quarantine` - When a bead is quarantined

### Exit Codes
- 0: Success (continue normally)
- 1: Warning (log warning but continue)
- 2: Abort (stop current operation)
- 3: Skip (skip remaining hooks)
- 124: Timeout (exceeded timeout limit)

### Environment Variables
- `NEEDLE_HOOK` - Name of the hook being executed
- `NEEDLE_BEAD_ID` - Current bead ID
- `NEEDLE_BEAD_TITLE` - Current bead title
- `NEEDLE_BEAD_PRIORITY` - Bead priority level
- `NEEDLE_BEAD_TYPE` - Bead type
- `NEEDLE_BEAD_LABELS` - Comma-separated labels
- `NEEDLE_WORKSPACE` - Current workspace path
- `NEEDLE_SESSION` - Worker session ID
- `NEEDLE_PID` - Process ID

---

*Document generated for bead nd-257 (Alternative: Research and document options)*
*Date: 2026-03-02*
