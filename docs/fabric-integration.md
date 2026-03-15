# FABRIC Telemetry Integration

NEEDLE includes a built-in real-time dashboard that receives and visualizes worker events as they happen. The dashboard is a self-contained Python process — no Prometheus, no Grafana, no external dependencies.

## Quick Start

```bash
# Start the dashboard server
needle dashboard start

# Open http://localhost:7842/ in a browser
# (or use --open to open automatically)
needle dashboard start --open

# Configure NEEDLE to forward events to it
# In needle.yaml:
#   fabric:
#     enabled: true
#     endpoint: http://localhost:7842/ingest
```

## Dashboard

The dashboard is served at `http://localhost:7842/` (configurable) and shows:

- **Active workers**: name, current bead, tokens this session
- **Strand activity**: counts and last-run per strand (pluck/weave/pulse/etc.)
- **Summary stats**: events today, beads/min, cost today, uptime
- **Failure alerts**: highlighted rows for `bead.failed` events
- **Recent events**: live tail with type-based coloring

The dashboard connects to the server via SSE (`/stream`) and updates in real time.

### CLI Commands

```bash
needle dashboard start              # Start in background (default)
needle dashboard start --foreground # Start in foreground
needle dashboard start --port 3000  # Custom port
needle dashboard status             # Check if running
needle dashboard stop               # Stop the server
needle dashboard restart            # Restart
needle dashboard logs               # View logs
needle dashboard logs --follow      # Tail logs
```

### Configuration

```yaml
dashboard:
  port: 7842        # Port to listen on
  host: localhost   # Bind address (use 0.0.0.0 for Tailscale/remote access)
```

### Architecture

```
NEEDLE workers
  → FABRIC (fabric.sh): POST events to http://localhost:7842/ingest
      → Dashboard server: buffers in memory ring (last 10k events)
          → SSE /stream ← browser clients
              → Dashboard HTML/JS rendered at /
```

The server is at `src/dashboard/server.py` and is pure stdlib Python 3 — no pip dependencies.

## Event Forwarding Configuration

### Option 1: Environment Variable (Testing)

```bash
export FABRIC_ENDPOINT=http://localhost:7842/ingest
needle run
```

### Option 2: Configuration File (Production)

Add to `~/.needle/config.yaml`:

```yaml
fabric:
  enabled: true
  endpoint: http://localhost:7842/ingest
  timeout: 2        # HTTP request timeout in seconds
  batching: false   # Enable event batching (future)
```

## Event Types Forwarded

FABRIC receives all stream-json events from agents, including:

### Worker Events
- `worker.started` - Worker initialization
- `worker.idle` - Worker waiting for work
- `worker.stopped` - Worker shutdown

### Bead Events
- `bead.claimed` - Bead claimed by worker
- `bead.agent_started` - Agent execution started
- `bead.agent_completed` - Agent execution finished
- `bead.completed` - Bead processing completed
- `bead.failed` - Bead processing failed

### Stream-JSON Events (from Claude Code)
- `tool_use` - Tool invocations (Bash, Read, Write, Edit, etc.)
- `thinking` - Agent reasoning blocks
- `result` - Final result with token usage and cost
- All other stream-json event types

## Event Format

Events are forwarded as JSONL (JSON Lines) to the FABRIC endpoint:

```json
{
  "type": "bead.claimed",
  "ts": "2026-03-08T12:00:00.123Z",
  "event": "bead.claimed",
  "level": "info",
  "session": "needle-claude-anthropic-sonnet-alpha",
  "worker": "claude-anthropic-sonnet-alpha",
  "data": {
    "bead_id": "nd-clld",
    "workspace": "/home/coder/NEEDLE"
  }
}
```

## How It Works

1. **Agent Invocation**: When NEEDLE dispatches an agent with `stream-json` output format
2. **Named Pipe**: A temporary named pipe is created for event forwarding
3. **Output Tee**: Agent output is tee'd to both the log file and the FABRIC pipe
4. **Background Parser**: A background process reads from the pipe and parses JSONL
5. **HTTP Forward**: Valid JSON events are forwarded to FABRIC via non-blocking HTTP POST
6. **Graceful Degradation**: If FABRIC is unavailable, events are silently dropped (no blocking)

## Architecture

```
Agent (Claude Code)
  └─> stream-json output
       └─> tee ┬─> output.log (file)
                └─> named pipe
                     └─> FABRIC parser (background)
                          └─> HTTP POST to FABRIC endpoint
```

## Performance Characteristics

- **Non-blocking**: HTTP requests use background processes with timeouts (default 2s)
- **Low overhead**: Events are forwarded asynchronously without blocking agent execution
- **Graceful failure**: Network errors are silently suppressed to avoid disrupting workflows
- **Minimal latency**: Events are forwarded as soon as they're parsed from the stream

## Testing

Run the test suite to verify FABRIC integration:

```bash
tests/test_fabric_forwarding.sh
```

Test with a mock FABRIC endpoint:

```bash
# Terminal 1: Start a simple HTTP server
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class FabricHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        event = json.loads(self.rfile.read(length))
        print(f'[FABRIC] Received event: {event.get(\"type\")} at {event.get(\"ts\")}')
        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress HTTP logs

HTTPServer(('', 3000), FabricHandler).serve_forever()
"

# Terminal 2: Run NEEDLE with FABRIC enabled
export FABRIC_ENDPOINT=http://localhost:3000/api/events
needle run
```

## Troubleshooting

### Events not appearing in FABRIC

1. Check if FABRIC forwarding is enabled:
   ```bash
   src/telemetry/fabric.sh enabled
   ```

2. Verify endpoint configuration:
   ```bash
   src/telemetry/fabric.sh endpoint
   ```

3. Test connectivity:
   ```bash
   curl -X POST http://localhost:3000/api/events \
        -H "Content-Type: application/json" \
        -d '{"type":"test","ts":"2026-03-08T12:00:00.000Z"}'
   ```

4. Check if agent uses stream-json format:
   ```bash
   # Verify agent config
   cat config/agents/claude-anthropic-sonnet.yaml | grep -A2 output
   ```

### High CPU usage

FABRIC forwarding uses background processes and named pipes. If you experience high CPU usage:

1. Increase timeout to reduce retry attempts
2. Disable batching if enabled
3. Check FABRIC endpoint performance
4. Disable FABRIC forwarding if not needed

## Security Considerations

- FABRIC endpoint receives full event streams including bead content
- Use HTTPS endpoints in production: `https://fabric.example.com/api/events`
- Configure network firewall rules to restrict FABRIC endpoint access
- Consider authentication headers (future enhancement)

## Future Enhancements

- Event batching to reduce HTTP overhead
- Event filtering based on type/level
- Authentication header support
- Retry logic with exponential backoff
- Event buffering for offline operation
- Compression support for large events

## Related

- [Telemetry Events](telemetry-events.md)
- [Stream JSON Format](stream-json.md)
- [Agent Configuration](agent-configuration.md)
