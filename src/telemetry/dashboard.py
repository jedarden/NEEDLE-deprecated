#!/usr/bin/env python3
"""
FABRIC Dashboard Server
Standalone SSE server and live UI for NEEDLE telemetry events

Receives events from NEEDLE workers via FABRIC forwarder and displays
them in a real-time web dashboard.

Architecture:
    NEEDLE workers → FABRIC forwarder → POST /ingest → ring buffer
                                            ↓
                                    SSE /stream ← browser clients
                                            ↑
                                    HTML/JS served at /

Usage:
    python3 -m needle.telemetry.dashboard [--port PORT] [--host HOST]
"""

import argparse
import asyncio
import json
import os
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http.server import HTTPServer, SimpleHTTPRequestHandler
from typing import Any, Deque, Dict, List, Optional, Set
from urllib.parse import parse_qs, urlparse
import socket
import threading
import socketserver
import traceback

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DEFAULT_PORT = 7842
DEFAULT_HOST = "localhost"
RING_BUFFER_SIZE = 10000
SSE_RETRY_DELAY = 3000  # milliseconds

# -----------------------------------------------------------------------------
# Data Models
# ----------------------------------------------------------------@

@dataclass
class WorkerState:
    """Track active worker state"""
    session: str
    worker: str
    started: str
    last_seen: float = field(default_factory=time.time)
    current_bead: Optional[str] = None
    beads_completed: int = 0
    strand_counts: Dict[str, int] = field(default_factory=dict)
    is_active: bool = True


@dataclass
class AggregateStats:
    """Aggregate statistics across all events"""
    beads_per_minute: float = 0.0
    active_workers: int = 0
    total_events: int = 0
    daily_cost_usd: float = 0.0
    daily_budget_usd: float = 10.0
    budget_warning: bool = False
    recent_failures: List[Dict[str, Any]] = field(default_factory=list)


# -----------------------------------------------------------------------------
# Event Ring Buffer
# -----------------------------------------------------------------------------

class EventRingBuffer:
    """Thread-safe ring buffer for event storage"""

    def __init__(self, max_size: int = RING_BUFFER_SIZE):
        self.max_size = max_size
        self.buffer: Deque[Dict[str, Any]] = deque(maxlen=max_size)
        self.lock = threading.Lock()

    def append(self, event: Dict[str, Any]) -> None:
        """Thread-safe append to buffer"""
        with self.lock:
            self.buffer.append(event)

    def get_recent(self, count: int = 50) -> List[Dict[str, Any]]:
        """Get most recent events"""
        with self.lock:
            events = list(self.buffer)
            return events[-count:] if count < len(events) else events

    def get_all(self) -> List[Dict[str, Any]]:
        """Get all events (for seeding new connections)"""
        with self.lock:
            return list(self.buffer)

    def get_stats(self) -> Dict[str, int]:
        """Get buffer statistics"""
        with self.lock:
            return {
                "total_events": len(self.buffer),
                "capacity": self.max_size,
            }


# -----------------------------------------------------------------------------
# Worker Registry
# -----------------------------------------------------------------------------

class WorkerRegistry:
    """Track worker state from events"""

    def __init__(self):
        self.workers: Dict[str, WorkerState] = {}
        self.lock = threading.Lock()

    def update_from_event(self, event: Dict[str, Any]) -> None:
        """Update worker state from event"""
        event_type = event.get("event", "")
        session = event.get("session", "")
        worker = event.get("worker", "")

        if not session or not worker:
            return

        with self.lock:
            # Create new worker if not exists
            if session not in self.workers:
                self.workers[session] = WorkerState(
                    session=session,
                    worker=worker,
                    started=event.get("ts", ""),
                )

            ws = self.workers[session]
            ws.last_seen = time.time()

            # Update based on event type
            if event_type == "bead.claimed":
                ws.current_bead = event.get("data", {}).get("bead_id")
            elif event_type == "bead.completed":
                ws.current_bead = None
                ws.beads_completed += 1
            elif event_type == "strand.completed":
                strand = event.get("data", {}).get("strand", "")
                if strand:
                    ws.strand_counts[strand] = ws.strand_counts.get(strand, 0) + 1
            elif event_type == "worker.stopped":
                ws.is_active = False

    def get_active_workers(self) -> List[Dict[str, Any]]:
        """Get list of active workers"""
        now = time.time()
        active = []

        with self.lock:
            for session, ws in list(self.workers.items()):
                # Remove workers inactive for more than 5 minutes
                if now - ws.last_seen > 300:
                    del self.workers[session]
                elif ws.is_active:
                    elapsed = int(now - ws.last_seen)
                    active.append({
                        "session": ws.session,
                        "worker": ws.worker,
                        "started": ws.started,
                        "elapsed_seconds": elapsed,
                        "current_bead": ws.current_bead,
                        "beads_completed": ws.beads_completed,
                        "strand_counts": ws.strand_counts,
                    })

        return active

    def get_strand_activity(self) -> Dict[str, Dict[str, Any]]:
        """Get aggregate strand activity across all workers"""
        strand_stats: Dict[str, Dict[str, Any]] = {}

        with self.lock:
            for ws in self.workers.values():
                for strand, count in ws.strand_counts.items():
                    if strand not in strand_stats:
                        strand_stats[strand] = {
                            "count": 0,
                            "last_run": "",
                        }
                    strand_stats[strand]["count"] += count
                    # Use worker's last_seen as proxy for strand activity
                    if not strand_stats[strand]["last_run"] or ws.last_seen > time.time():
                        strand_stats[strand]["last_run"] = datetime.fromtimestamp(
                            ws.last_seen, tz=timezone.utc
                        ).isoformat()

        return strand_stats


# -----------------------------------------------------------------------------
# SSE Client Manager
# -----------------------------------------------------------------------------

class SSEClientManager:
    """Manage SSE client connections"""

    def __init__(self):
        self.clients: Set[Any] = set()
        self.lock = threading.Lock()

    def add_client(self, client) -> None:
        """Register a new SSE client"""
        with self.lock:
            self.clients.add(client)

    def remove_client(self, client) -> None:
        """Unregister an SSE client"""
        with self.lock:
            self.clients.discard(client)

    def broadcast(self, event: Dict[str, Any]) -> None:
        """Broadcast event to all connected clients"""
        with self.lock:
            dead_clients = set()
            for client in self.clients:
                try:
                    client.send_event(event)
                except (BrokenPipeError, OSError):
                    dead_clients.add(client)

            # Remove dead clients
            for client in dead_clients:
                self.clients.discard(client)

    def broadcast_named(self, name: str, data: Any) -> None:
        """Broadcast a named SSE event to all connected clients"""
        with self.lock:
            dead_clients = set()
            for client in self.clients:
                try:
                    client.send_named_event(name, data)
                except (BrokenPipeError, OSError):
                    dead_clients.add(client)

            for client in dead_clients:
                self.clients.discard(client)

    def get_client_count(self) -> int:
        """Get number of connected clients"""
        with self.lock:
            return len(self.clients)


# -----------------------------------------------------------------------------
# Dashboard HTML (Embedded)
# -----------------------------------------------------------------------------

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FABRIC Dashboard</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }

        :root {
            --bg-primary: #0d1117;
            --bg-secondary: #161b22;
            --bg-tertiary: #21262d;
            --border-color: #30363d;
            --text-primary: #c9d1d9;
            --text-secondary: #8b949e;
            --accent-green: #238636;
            --accent-red: #da3633;
            --accent-yellow: #d29922;
            --accent-blue: #58a6ff;
            --accent-purple: #a371f7;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.5;
            padding: 20px;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        header {
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid var(--border-color);
        }

        h1 {
            font-size: 24px;
            font-weight: 600;
            color: var(--text-primary);
        }

        .status-indicator {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-right: 8px;
            animation: pulse 2s infinite;
        }

        .status-indicator.connected { background: var(--accent-green); }
        .status-indicator.disconnected { background: var(--accent-red); }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 16px;
            margin-bottom: 16px;
        }

        .panel {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 6px;
            padding: 16px;
        }

        .panel-title {
            font-size: 14px;
            font-weight: 600;
            color: var(--text-secondary);
            margin-bottom: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .stat-value {
            font-size: 32px;
            font-weight: 300;
            color: var(--text-primary);
        }

        .stat-label {
            font-size: 12px;
            color: var(--text-secondary);
        }

        .worker-item, .strand-item, .event-item {
            padding: 8px 0;
            border-bottom: 1px solid var(--border-color);
        }

        .worker-item:last-child, .strand-item:last-child, .event-item:last-child {
            border-bottom: none;
        }

        .worker-name {
            font-weight: 600;
            color: var(--accent-blue);
        }

        .worker-badges {
            display: flex;
            gap: 8px;
            margin-top: 4px;
        }

        .badge {
            font-size: 11px;
            padding: 2px 6px;
            border-radius: 3px;
            background: var(--bg-tertiary);
            color: var(--text-secondary);
        }

        .event-type {
            font-size: 12px;
            font-weight: 600;
            padding: 2px 6px;
            border-radius: 3px;
            display: inline-block;
        }

        .event-type.bead { background: var(--accent-purple); color: white; }
        .event-type.strand { background: var(--accent-blue); color: white; }
        .event-type.error { background: var(--accent-red); color: white; }
        .event-type.warning { background: var(--accent-yellow); color: var(--bg-primary); }
        .event-type.info { background: var(--bg-tertiary); color: var(--text-secondary); }

        .event-time {
            font-size: 11px;
            color: var(--text-secondary);
        }

        .progress-bar {
            height: 8px;
            background: var(--bg-tertiary);
            border-radius: 4px;
            overflow: hidden;
            margin-top: 8px;
        }

        .progress-fill {
            height: 100%;
            background: var(--accent-green);
            transition: width 0.3s ease;
        }

        .progress-fill.warning { background: var(--accent-yellow); }
        .progress-fill.danger { background: var(--accent-red); }

        .events-container {
            max-height: 400px;
            overflow-y: auto;
        }

        .failure-alert {
            background: rgba(218, 54, 51, 0.1);
            border: 1px solid var(--accent-red);
            border-radius: 6px;
            padding: 12px;
            margin-bottom: 16px;
        }

        .failure-alert .panel-title {
            color: var(--accent-red);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>
                <span id="status-indicator" class="status-indicator disconnected"></span>
                FABRIC Dashboard
                <span style="font-size: 14px; color: var(--text-secondary); margin-left: 16px;">
                    <span id="client-count">0</span> clients connected
                </span>
            </h1>
        </header>

        <!-- Summary Stats -->
        <div class="grid">
            <div class="panel">
                <div class="panel-title">Active Workers</div>
                <div class="stat-value" id="active-workers">0</div>
                <div class="stat-label">processing beads</div>
            </div>

            <div class="panel">
                <div class="panel-title">Throughput</div>
                <div class="stat-value" id="throughput">0.0</div>
                <div class="stat-label">beads/minute</div>
            </div>

            <div class="panel">
                <div class="panel-title">Daily Cost</div>
                <div class="stat-value" id="daily-cost">$0.00</div>
                <div class="stat-label">of $<span id="budget-limit">10.00</span> budget</div>
                <div class="progress-bar">
                    <div class="progress-fill" id="budget-progress" style="width: 0%"></div>
                </div>
            </div>

            <div class="panel">
                <div class="panel-title">Events Processed</div>
                <div class="stat-value" id="total-events">0</div>
                <div class="stat-label">total events</div>
            </div>
        </div>

        <!-- Failure Alerts (shown when present) -->
        <div id="failure-panel" class="panel failure-alert" style="display: none;">
            <div class="panel-title">⚠️ Recent Failures</div>
            <div id="failure-list"></div>
        </div>

        <div class="grid" style="grid-template-columns: 1fr 1fr;">
            <!-- Active Workers -->
            <div class="panel">
                <div class="panel-title">Active Workers</div>
                <div id="workers-list"></div>
            </div>

            <!-- Strand Activity -->
            <div class="panel">
                <div class="panel-title">Strand Activity</div>
                <div id="strands-list"></div>
            </div>
        </div>

        <!-- Recent Events -->
        <div class="panel">
            <div class="panel-title">Recent Events</div>
            <div class="events-container" id="events-list"></div>
        </div>
    </div>

    <script>
        let eventBuffer = [];
        const MAX_EVENTS = 50;

        // Parse event type for styling
        function getEventType(event) {
            const evt = event.event || '';
            if (evt.startsWith('bead.') || evt.startsWith('worker.')) return 'bead';
            if (evt.startsWith('strand.') || evt.startsWith('hook.')) return 'strand';
            if (evt.startsWith('error.') || evt.endsWith('.failed')) return 'error';
            if (evt.endsWith('.warning') || evt.includes('budget')) return 'warning';
            return 'info';
        }

        // Format timestamp
        function formatTime(ts) {
            const date = new Date(ts);
            return date.toLocaleTimeString();
        }

        // Format duration
        function formatDuration(seconds) {
            if (seconds < 60) return `${seconds}s`;
            if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
            return `${Math.floor(seconds / 3600)}h`;
        }

        // Update summary stats
        function updateStats(stats) {
            document.getElementById('active-workers').textContent = stats.active_workers || 0;
            document.getElementById('throughput').textContent = (stats.beads_per_minute || 0).toFixed(1);
            document.getElementById('daily-cost').textContent = `$${(stats.daily_cost_usd || 0).toFixed(2)}`;
            document.getElementById('budget-limit').textContent = (stats.daily_budget_usd || 10).toFixed(2);
            document.getElementById('total-events').textContent = stats.total_events || 0;

            // Update budget progress bar
            const progress = ((stats.daily_cost_usd || 0) / (stats.daily_budget_usd || 10)) * 100;
            const progressBar = document.getElementById('budget-progress');
            progressBar.style.width = `${Math.min(progress, 100)}%`;
            progressBar.className = 'progress-fill';
            if (progress > 90) progressBar.classList.add('danger');
            else if (progress > 70) progressBar.classList.add('warning');
        }

        // Update workers list
        function updateWorkers(workers) {
            const container = document.getElementById('workers-list');
            if (!workers || workers.length === 0) {
                container.innerHTML = '<div class="worker-item" style="color: var(--text-secondary);">No active workers</div>';
                return;
            }

            container.innerHTML = workers.map(w => `
                <div class="worker-item">
                    <div class="worker-name">${w.session}</div>
                    <div style="font-size: 12px; color: var(--text-secondary); margin-top: 4px;">
                        ${w.worker} • ${formatDuration(w.elapsed_seconds)} elapsed
                    </div>
                    ${w.current_bead ? `<div style="font-size: 12px; color: var(--accent-green); margin-top: 4px;">→ ${w.current_bead}</div>` : ''}
                    <div class="worker-badges">
                        <span class="badge">${w.beads_completed} completed</span>
                    </div>
                </div>
            `).join('');
        }

        // Update strands list
        function updateStrands(strands) {
            const container = document.getElementById('strands-list');
            if (!strands || Object.keys(strands).length === 0) {
                container.innerHTML = '<div class="strand-item" style="color: var(--text-secondary);">No strand activity yet</div>';
                return;
            }

            container.innerHTML = Object.entries(strands)
                .sort((a, b) => b[1].count - a[1].count)
                .map(([name, data]) => `
                    <div class="strand-item">
                        <span style="font-weight: 600;">${name}</span>
                        <span style="float: right; color: var(--text-secondary);">${data.count} runs</span>
                    </div>
                `).join('');
        }

        // Update events list
        function updateEvents() {
            const container = document.getElementById('events-list');
            if (eventBuffer.length === 0) {
                container.innerHTML = '<div class="event-item" style="color: var(--text-secondary);">Waiting for events...</div>';
                return;
            }

            container.innerHTML = eventBuffer.slice(0, MAX_EVENTS).map(e => `
                <div class="event-item">
                    <span class="event-type ${getEventType(e)}">${e.event}</span>
                    <span class="event-time">${formatTime(e.ts)}</span>
                    ${e.data && e.data.bead_id ? `<span style="color: var(--accent-purple); margin-left: 8px;">${e.data.bead_id}</span>` : ''}
                </div>
            `).join('');
        }

        // Update failure panel
        function updateFailures(failures) {
            const panel = document.getElementById('failure-panel');
            const list = document.getElementById('failure-list');

            if (!failures || failures.length === 0) {
                panel.style.display = 'none';
                return;
            }

            panel.style.display = 'block';
            list.innerHTML = failures.map(f => `
                <div style="padding: 4px 0;">
                    <span style="font-weight: 600;">${f.bead_id || 'Unknown'}</span>
                    <span style="color: var(--text-secondary); margin-left: 8px;">${f.error || 'Failed'}</span>
                </div>
            `).join('');
        }

        // SSE connection
        function connectSSE() {
            const indicator = document.getElementById('status-indicator');
            const eventSource = new EventSource('/stream');

            eventSource.onopen = () => {
                indicator.className = 'status-indicator connected';
            };

            eventSource.onerror = () => {
                indicator.className = 'status-indicator disconnected';
            };

            eventSource.addEventListener('heartbeat', (e) => {
                const data = JSON.parse(e.data);
                document.getElementById('client-count').textContent = data.clients || 0;
            });

            eventSource.addEventListener('event', (e) => {
                const event = JSON.parse(e.data);
                eventBuffer.unshift(event);
                if (eventBuffer.length > MAX_EVENTS * 2) {
                    eventBuffer = eventBuffer.slice(0, MAX_EVENTS * 2);
                }
                updateEvents();
            });

            eventSource.addEventListener('stats', (e) => {
                const data = JSON.parse(e.data);
                if (data.workers) updateWorkers(data.workers);
                if (data.strands) updateStrands(data.strands);
                if (data.summary) updateStats(data.summary);
                if (data.failures) updateFailures(data.failures);
            });
        }

        // Initial connection
        connectSSE();
        updateEvents();

        // Poll for initial stats (in case we missed SSE setup)
        fetch('/api/summary')
            .then(r => r.json())
            .then(data => {
                if (data.workers) updateWorkers(data.workers);
                if (data.strands) updateStrands(data.strands);
                if (data.summary) updateStats(data.summary);
            })
            .catch(console.error);
    </script>
</body>
</html>
"""


# -----------------------------------------------------------------------------
# HTTP Request Handler
# -----------------------------------------------------------------------------

class DashboardHandler(SimpleHTTPRequestHandler):
    """HTTP request handler for FABRIC dashboard"""

    # Class-level shared state
    event_buffer: EventRingBuffer = None
    worker_registry: WorkerRegistry = None
    sse_manager: SSEClientManager = None

    def log_message(self, format, *args):
        """Suppress default logging"""
        pass

    def _send_sse(self, event: str, data: Any) -> None:
        """Send SSE event to client"""
        response = f"event: {event}\\n"
        response += f"data: {json.dumps(data)}\\n\\n"
        self.wfile.write(response.encode())
        self.wfile.flush()

    def do_GET(self):
        """Handle GET requests"""
        parsed_path = urlparse(self.path)

        if parsed_path.path == "/":
            self._serve_dashboard()
        elif parsed_path.path == "/stream":
            self._handle_sse()
        elif parsed_path.path == "/api/summary":
            self._serve_summary()
        elif parsed_path.path == "/api/events":
            self._serve_events()
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        """Handle POST requests"""
        parsed_path = urlparse(self.path)

        if parsed_path.path == "/ingest":
            self._handle_ingest()
        else:
            self.send_error(404, "Not Found")

    def _serve_dashboard(self) -> None:
        """Serve the dashboard HTML"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(DASHBOARD_HTML.encode())

    def _serve_summary(self) -> None:
        """Serve aggregate statistics"""
        workers = self.worker_registry.get_active_workers()
        strands = self.worker_registry.get_strand_activity()
        stats = self.event_buffer.get_stats()

        summary = {
            "active_workers": len(workers),
            "beads_per_minute": 0.0,  # Would need time-windowed tracking
            "total_events": stats["total_events"],
            "daily_cost_usd": 0.0,  # Would need cost tracking from events
            "daily_budget_usd": 10.0,
            "budget_warning": False,
        }

        response = {
            "workers": workers,
            "strands": strands,
            "summary": summary,
            "failures": [],  # Would need failure tracking
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

    def _serve_events(self) -> None:
        """Serve recent events for initial page load"""
        parsed_path = urlparse(self.path)
        query = parse_qs(parsed_path.query)
        count = int(query.get("count", [50])[0])

        events = self.event_buffer.get_recent(count)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(events).encode())

    def _handle_sse(self) -> None:
        """Handle SSE streaming connection"""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")  # Disable nginx buffering
        self.end_headers()

        # Send recent events as initial data
        for event in self.event_buffer.get_recent(100):
            self._send_sse("event", event)

        # Create a client wrapper for this connection
        client = SSEClient(self)
        self.sse_manager.add_client(client)

        # Send heartbeat every 10 seconds
        try:
            while True:
                # Check for connection timeout
                self.connection.settimeout(10)
                try:
                    # Just wait for timeout or disconnect
                    data = self.rfile.read(1)
                    if not data:  # Client disconnected
                        break
                except (socket.timeout, OSError):
                    # Send heartbeat
                    self._send_sse("heartbeat", {
                        "clients": self.sse_manager.get_client_count(),
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    })
        finally:
            self.sse_manager.remove_client(client)

    def _handle_ingest(self) -> None:
        """Handle event ingestion from FABRIC forwarder"""
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self.send_error(400, "Empty request")
            return

        try:
            body = self.rfile.read(content_length)
            event = json.loads(body.decode())

            # Validate event structure
            if not isinstance(event, dict):
                raise ValueError("Event must be a JSON object")

            # Add to ring buffer
            self.event_buffer.append(event)

            # Update worker registry
            self.worker_registry.update_from_event(event)

            # Broadcast raw event to SSE clients
            self.sse_manager.broadcast(event)

            # Broadcast stats update to SSE clients so dashboards refresh
            workers = self.worker_registry.get_active_workers()
            strands = self.worker_registry.get_strand_activity()
            self.sse_manager.broadcast_named("stats", {
                "workers": workers,
                "strands": strands,
                "summary": {
                    "active_workers": len(workers),
                    "total_events": self.event_buffer.get_stats()["total_events"],
                },
            })

            self.send_response(202)
            self.end_headers()

        except (json.JSONDecodeError, ValueError) as e:
            self.send_error(400, f"Invalid JSON: {e}")


class SSEClient:
    """Wrapper for SSE client connection"""

    def __init__(self, handler: DashboardHandler):
        self.handler = handler

    def send_event(self, event: Dict[str, Any]) -> None:
        """Send an event to this client"""
        try:
            response = f"event: event\\n"
            response += f"data: {json.dumps(event)}\\n\\n"
            self.handler.wfile.write(response.encode())
            self.handler.wfile.flush()
        except (BrokenPipeError, OSError):
            raise

    def send_named_event(self, name: str, data: Any) -> None:
        """Send a named SSE event to this client"""
        try:
            response = f"event: {name}\\n"
            response += f"data: {json.dumps(data)}\\n\\n"
            self.handler.wfile.write(response.encode())
            self.handler.wfile.flush()
        except (BrokenPipeError, OSError):
            raise


# -----------------------------------------------------------------------------
# Server Factory
# -----------------------------------------------------------------------------

class ThreadedHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    """Threaded HTTP server for handling multiple SSE connections"""
    daemon_threads = True


def create_server(
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
) -> HTTPServer:
    """Create and configure the dashboard server"""

    # Initialize shared state
    DashboardHandler.event_buffer = EventRingBuffer()
    DashboardHandler.worker_registry = WorkerRegistry()
    DashboardHandler.sse_manager = SSEClientManager()

    server = ThreadedHTTPServer((host, port), DashboardHandler)
    return server


# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------

def main() -> int:
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="FABRIC Dashboard Server",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help=f"Host to bind to (default: {DEFAULT_HOST})",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Port to bind to (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable verbose logging",
    )

    args = parser.parse_args()

    # Create server
    server = create_server(host=args.host, port=args.port)

    if args.verbose:
        print(f"FABRIC Dashboard starting on http://{args.host}:{args.port}", file=sys.stderr)
        print(f"Endpoints:", file=sys.stderr)
        print(f"  GET  /                    - Dashboard HTML", file=sys.stderr)
        print(f"  GET  /stream              - SSE event stream", file=sys.stderr)
        print(f"  GET  /api/summary         - Aggregate statistics", file=sys.stderr)
        print(f"  GET  /api/events          - Recent events", file=sys.stderr)
        print(f"  POST /ingest              - Ingest events", file=sys.stderr)
        print(file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        if args.verbose:
            print("\\nShutting down...", file=sys.stderr)
        server.shutdown()
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        if args.verbose:
            traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
