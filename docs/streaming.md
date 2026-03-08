# Streaming Architecture

NEEDLE uses streaming output from AI agents to enable terminal visibility, real-time heartbeats, and telemetry forwarding.

## Why Streaming Matters

### 1. Terminal Visibility

By default, agent output is captured to log files for telemetry extraction. With streaming enabled, output is displayed in real-time using `tee`, so you can watch agent execution as it happens:

```
Agent thinking...
Using Bash tool: git status
Files modified: src/app.ts
Creating commit...
```

This is essential for debugging, monitoring, and understanding agent behavior.

### 2. Heartbeat Keepalive

Long-running agent tasks can trigger watchdog timeouts. Streaming enables background heartbeat processes that keep the worker alive:

```
┌─────────────────────────────────────────────────────────────┐
│ Agent (5+ minutes)     │ Heartbeat (every 30s)              │
│  ├─ Thinking...        │  ├─ ping                           │
│  ├─ Tool call          │  ├─ ping                           │
│  ├─ Processing...      │  ├─ ping                           │
│  └─ Done               │  └─ stopped                        │
└─────────────────────────────────────────────────────────────┘
```

Without heartbeats, the watchdog might kill a perfectly healthy worker.

### 3. Real-time Telemetry

Streaming enables event forwarding to FABRIC dashboards and external monitoring systems. See [FABRIC Integration](fabric-integration.md) for details.

## How It Works

### Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    NEEDLE Dispatch                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Agent CLI (e.g., claude)                                   │
│    │                                                        │
│    ├─> --output-format stream-json                          │
│    │                                                        │
│    └─> stdout/stderr (JSONL stream)                         │
│          │                                                  │
│          ├─> tee ─────────────┬─> output.log (file)         │
│          │                    │                             │
│          │ (if FABRIC)        └─> named pipe                │
│          │                         │                        │
│          │                         └─> FABRIC parser        │
│          │                              │                   │
│          │                              └─> HTTP POST       │
│          │                                                  │
│          └─> terminal (visible to user)                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

1. **Agent CLI**: Uses `--output-format stream-json` flag
2. **Tee Pipeline**: Output goes to both file and terminal
3. **FABRIC Pipe**: Named pipe for background event parsing (optional)
4. **Heartbeat Process**: Background process sending keepalives

## Stream-JSON Event Types

Claude Code with `--output-format stream-json` emits these event types:

### System Events

| Type | Description |
|------|-------------|
| `system` | System initialization message |
| `result` | Final result with usage stats |

### Content Events

| Type | Description |
|------|-------------|
| `thinking` | Agent reasoning/planning |
| `text` | Text response content |
| `tool_use` | Tool invocation |
| `tool_result` | Tool execution result |

### Result Event (Most Important)

The `result` event contains aggregated statistics:

```json
{
  "type": "result",
  "usage": {
    "input_tokens": 15234,
    "output_tokens": 2847
  },
  "cost_usd": 0.0892,
  "duration_ms": 45230
}
```

NEEDLE extracts these for cost tracking and telemetry.

## Agent Configuration

### Enabling Streaming

In agent config (`config/agents/claude-anthropic-sonnet.yaml`):

```yaml
# CLI invocation with streaming
invoke: |
  cd ${WORKSPACE} && \
  claude --print \
         --dangerously-skip-permissions \
         --output-format stream-json \
         --verbose \
  <<'NEEDLE_PROMPT'
  ${PROMPT}
  NEEDLE_PROMPT

# Output parsing configuration
output:
  format: stream-json          # Enable stream-json parsing
  streaming_enabled: true      # Enable terminal output via tee
  success_codes: [0]
  retry_codes: [1]
  fail_codes: [2, 137]
```

### Key Options

| Option | Description |
|--------|-------------|
| `--output-format stream-json` | CLI flag for JSONL output |
| `output.format: stream-json` | Config: parse as stream-json |
| `output.streaming_enabled: true` | Config: enable tee output |

## Token Extraction

NEEDLE extracts tokens from the stream-json `result` event:

```bash
# From src/telemetry/tokens.sh
_needle_extract_tokens_streaming "/path/to/output.log"
# Returns: input_tokens|output_tokens|cost_usd|duration_ms
# Example: 15234|2847|0.0892|45230
```

This is used for:
- Cost tracking and budget enforcement
- Usage analytics and telemetry
- Performance metrics

## Heartbeat Integration

When dispatching an agent with streaming output:

1. **Start Heartbeat**: `_needle_start_heartbeat_background` spawns background process
2. **During Execution**: Heartbeat pings every 30 seconds
3. **On Completion**: `_needle_stop_heartbeat_background` cleans up

```bash
# In src/agent/dispatch.sh
_needle_start_heartbeat_background "$bead_id"
# ... agent runs ...
_needle_stop_heartbeat_background
```

## Troubleshooting

### Terminal Output Not Visible

**Symptom**: Agent runs but no output appears in terminal.

**Solutions**:
1. Check agent config has `output.streaming_enabled: true`
2. Verify invoke template uses `--output-format stream-json`
3. Check tee pipeline in dispatch.sh

### Watchdog Timeout During Long Tasks

**Symptom**: Worker killed after 5 minutes despite active agent.

**Solutions**:
1. Ensure streaming is enabled (enables heartbeat)
2. Increase `NEEDLE_HEARTBEAT_INTERVAL` (default: 30s)
3. Check heartbeat process is starting (`_needle_start_heartbeat_background`)

### Token Extraction Failures

**Symptom**: Cost/tokens show 0 despite successful run.

**Solutions**:
1. Verify output format is `stream-json` (not `text` or `json`)
2. Check output file contains `result` event
3. Test extraction manually:
   ```bash
   src/telemetry/tokens.sh streaming /path/to/output.log
   ```

### Missing Result Event

**Symptom**: Output has tool_use/thinking events but no result.

**Solutions**:
1. Agent may have crashed before completion
2. Check for timeout (exit code 124)
3. Check output file for truncation

## Related Documentation

- [FABRIC Integration](fabric-integration.md) - Real-time event forwarding
- [Agent Configuration](agent-configuration.md) - Agent YAML format
- [Telemetry Events](telemetry-events.md) - Event types and format
