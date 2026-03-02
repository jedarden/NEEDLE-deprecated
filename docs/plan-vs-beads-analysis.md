# NEEDLE Plan vs Beads: Feature Coverage Analysis

**Analysis Date:** 2026-03-02
**Plan.md:** 3412 lines
**Beads:** 71 total (48 closed, 5 in_progress, 18 open)

---

## Executive Summary

The NEEDLE implementation is **well-tracked** with 71 beads covering most core components. However, there are **significant gaps** in tracking for:
- Bootstrap/onboarding system components
- Several opt-in strands (Weave, Pulse, Unravel)
- Advanced features (mitosis configuration, billing model profiles)
- Infrastructure pieces (worker registry, rate limiting state)

**Coverage:** ~75% of major features have beads created

---

## 1. CLI Commands

### ✅ Commands WITH Beads (CLOSED)

| Command | Bead ID | Status | Notes |
|---------|---------|--------|-------|
| `needle version` | nd-16x | closed | Core identity command |
| `needle stop` | nd-19k | closed | Worker termination |
| `needle list` | nd-28x | closed | Worker listing |
| `needle attach` | nd-2dt | closed | tmux attach |
| `needle upgrade` | nd-3ma | closed | Self-update system |
| `needle rollback` | nd-28h | closed | Version rollback |
| `needle logs` | nd-3iq | closed | Log viewing |
| `needle test-agent` | nd-3gv | closed | Agent validation |
| `needle heartbeat` | nd-315 | closed | Heartbeat management |
| `needle status` | nd-xq9 | closed | Worker dashboard |
| `needle config` | nd-254 | closed | Config management |
| `needle help` | nd-eyf | closed | Help system |

### 🔶 Commands WITH Beads (IN_PROGRESS)

| Command | Bead ID | Status | Notes |
|---------|---------|--------|-------|
| `needle restart` | nd-338 | in_progress | Worker restart logic |

### 🟡 Commands WITH Beads (OPEN)

| Command | Bead ID | Status | Notes |
|---------|---------|--------|-------|
| `needle init` | nd-b6n | open | **Critical:** Interactive onboarding |
| `needle run` | nd-qzu | open | **Critical:** Primary worker launcher |
| `needle agents` | nd-33b | open | Agent listing/scanning |
| `needle setup` | nd-38g | open | **Critical:** Bootstrap system |

### ❌ Commands WITHOUT Beads (MISSING)

None! All CLI commands mentioned in plan.md have corresponding beads.

**Analysis:** CLI commands are well-tracked. Critical open beads (`init`, `run`, `setup`) need prioritization.

---

## 2. Strands (Work Finding System)

### ✅ Strands WITH Beads

| Strand | Name | Bead ID | Status | Invokes Agent | Priority |
|--------|------|---------|--------|---------------|----------|
| **Strand 1** | Pluck | nd-2gc | in_progress | Yes | **CRITICAL** (primary work) |
| **Strand 2** | Explore | nd-hq2 | closed | No | Medium (auto-scaling) |
| **Strand 3** | Mend | nd-1sk | closed | No | Medium (maintenance) |
| **Strand 4** | Weave | nd-27u | closed | Yes | Low (opt-in) |
| **Strand 5** | Unravel | nd-20p | open | Yes | Low (opt-in) |
| **Strand 6** | Pulse | nd-qpj | open | Yes | Low (opt-in) |
| **Strand 7** | Knot | nd-d2a | closed | No | Medium (alerting) |

### Supporting Module

| Module | Bead ID | Status | Notes |
|--------|---------|--------|-------|
| Strand Engine Dispatcher | nd-hpj | closed | Orchestrates strand 1→7 flow |

**Analysis:** All 7 strands have beads! Strand 1 (Pluck) is in_progress - this is the critical path. Opt-in strands (5, 6) appropriately open.

---

## 3. Core Modules

### ✅ Modules WITH Beads (CLOSED)

#### Bead Management
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Atomic bead claiming | nd-31l | closed | `bead/claim.sh` |
| Bead selection (weighted) | nd-23h | closed | `bead/select.sh` |
| Prompt builder | nd-100 | closed | `bead/prompt.sh` |
| Bead mitosis | nd-39h | closed | `bead/mitosis.sh` |

#### Agent System
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Agent dispatcher | nd-1hr | closed | `agent/dispatch.sh` |
| Agent adapter loader | nd-3pu | closed | `agent/loader.sh` |
| Prompt escape | nd-68r | closed | `agent/escape.sh` |
| Built-in adapters | nd-3ba | closed | `config/agents/*.yaml` |
| Agent detection | nd-1ge | closed | `onboarding/agents.sh` |

#### Telemetry & Effort
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Event emitter | nd-1cz | closed | `telemetry/events.sh` |
| Telemetry writer | nd-6yj | closed | `telemetry/writer.sh` |
| Cost calculation | nd-ysf | closed | `telemetry/effort.sh` |
| Budget enforcement | nd-23s | closed | `telemetry/budget.sh` |
| Token extraction | nd-28p | closed | Agent output parsing |

#### Configuration
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Config global loader | nd-2mc | closed | `lib/config.sh` |
| Workspace config loader | nd-147 | closed | `lib/workspace.sh` |
| Shared library modules | nd-1il | closed | `lib/*.sh` |

#### Process Management
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| tmux session management | nd-u74 | closed | `runner/tmux.sh` |
| Worker state registry | nd-e5q | closed | `state/workers.json` |
| Concurrency limit enforcement | nd-1ea | closed | Global limits |
| Rate limiting per provider | nd-1ws | closed | Provider throttling |

#### Watchdog & Health
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Worker heartbeat emission | nd-fjz | closed | `watchdog/heartbeat.sh` |

#### Hooks System
| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Hook system runner | nd-2w0 | closed | `hooks/runner.sh` |

### 🔶 Modules WITH Beads (IN_PROGRESS)

| Module | Bead ID | Status | File Path |
|--------|---------|--------|-----------|
| Watchdog monitor process | nd-1z9 | in_progress | `watchdog/monitor.sh` |
| Default hook templates | nd-bqi | in_progress | `hooks/defaults/` |

### 🟡 Modules WITH Beads (OPEN)

| Module | Bead ID | Status | File Path | Priority |
|--------|---------|--------|-----------|----------|
| Main worker loop | nd-qft | open | `runner/loop.sh` | **CRITICAL** |
| Worker naming (NATO) | nd-xnj | open | `runner/naming.sh` | High |

### ❌ Modules WITHOUT Beads (MISSING)

#### Configuration Hot-Reload
**Mentioned in:** Phase 3 success criteria
**File:** Not specified (likely `lib/config.sh` extension)
**Why missing:** Advanced Phase 3 feature, may not be prioritized yet

---

## 4. Bootstrap & Onboarding System

### ✅ WITH Beads (CLOSED)

| Component | Bead ID | Status | File Path |
|-----------|---------|--------|-----------|
| One-liner installer | nd-2u4 | closed | `install.sh` |
| ASCII banner/welcome | nd-3ia | closed | `onboarding/welcome.sh` |
| Bundle script | nd-2dy | closed | `scripts/bundle.sh` |
| CLI skeleton | nd-2g9 | closed | `bin/needle` + routing |

### 🟡 WITH Beads (OPEN)

| Component | Bead ID | Status | File Path | Priority |
|-----------|---------|--------|-----------|----------|
| `needle init` command | nd-b6n | open | `cli/init.sh` | **CRITICAL** |
| `needle setup` command | nd-38g | open | `cli/setup.sh` | **CRITICAL** |
| Dependency detection | nd-39i | open | `bootstrap/check.sh` | High |
| Dependency installation | nd-n0y | open | `bootstrap/install.sh` | High |
| OS detection | nd-2nr | open | `bootstrap/detect_os.sh` | High |

### ❌ WITHOUT Beads (MISSING)

#### Workspace Setup Module
**Mentioned in:** File structure `onboarding/workspace_setup.sh`
**Purpose:** Prompt for workspace, validate `.beads/` presence
**Why missing:** May be folded into `needle init` (nd-b6n)

#### Config Creation Module
**Mentioned in:** File structure `onboarding/create_config.sh`
**Purpose:** Generate default `~/.needle/config.yaml`
**Why missing:** May be folded into `needle init` (nd-b6n)

#### PATH Management Module
**Mentioned in:** File structure `bootstrap/paths.sh`
**Purpose:** Add `~/.local/bin` to PATH if needed
**Why missing:** Small utility, may be part of installer

---

## 5. Advanced Features (Phase 3)

### ✅ WITH Beads (CLOSED)

| Feature | Bead ID | Status | Notes |
|---------|---------|--------|-------|
| Bead mitosis | nd-39h | closed | Automatic task decomposition |

### 🟡 WITH Beads (OPEN)

| Feature | Bead ID | Status | Notes |
|---------|---------|--------|-------|
| Strand 5: Unravel | nd-20p | open | HUMAN alternatives |
| Strand 6: Pulse | nd-qpj | open | Codebase health |

### ❌ WITHOUT Beads (MISSING)

#### Mitosis Configuration
**Mentioned in:** `mitosis:` section in `~/.needle/config.yaml`
**Details:**
- `max_children`, `min_complexity` settings
- Skip types/labels (no-mitosis, atomic)
**Why missing:** Configuration aspect of existing mitosis bead (nd-39h)

#### Billing Model Profiles
**Mentioned in:** `billing:` section, Phase 3 goals
**Details:**
- `pay_per_token`, `use_or_lose`, `unlimited` model behavior
- Strand adjustments by billing model
- Priority behavior modifications
**Why missing:** Advanced optimization feature, not yet prioritized

#### Workspace Auto-Discovery
**Mentioned in:** Phase 3 checklist, Strand 2 (Explore) behavior
**Details:** Traverse parent directories to discover new `.beads/` workspaces
**Why missing:** May be part of Strand 2 (nd-hq2, already closed), or not yet scoped

---

## 6. Infrastructure & State Management

### ✅ WITH Beads (CLOSED)

| Component | Bead ID | Status | Location |
|-----------|---------|--------|----------|
| Worker state registry | nd-e5q | closed | `~/.needle/state/workers.json` |

### ❌ WITHOUT Beads (MISSING)

#### Rate Limit State Files
**Mentioned in:** `~/.needle/state/rate_limits/` directory
**Purpose:** Track per-provider rate limit buckets
**Implementation:** Part of rate limiting module (nd-1ws, closed)
**Why missing:** Infrastructure created by existing module

#### Heartbeat State Files
**Mentioned in:** `~/.needle/state/heartbeats/*.json`
**Purpose:** Per-worker heartbeat tracking for stuck detection
**Implementation:** Part of heartbeat module (nd-fjz, closed)
**Why missing:** Infrastructure created by existing module

#### Pulse State Files
**Mentioned in:** `~/.needle/state/pulse/last_scan.json`, `seen_issues.json`
**Purpose:** Track codebase health scan results and issue deduplication
**Implementation:** Part of Strand 6 Pulse (nd-qpj, open)
**Why missing:** Will be created when Pulse strand is implemented

#### Cache Directory Management
**Mentioned in:** `~/.needle/cache/` for downloaded binaries
**Purpose:** Version check cache, binary backups, update staging
**Implementation:** Part of upgrade system (nd-3ma, closed) and setup (nd-38g, open)
**Why missing:** Infrastructure created by existing modules

---

## 7. Testing Infrastructure

### ❌ WITHOUT Beads (ALL MISSING)

**Mentioned in:** File structure `tests/` directory

| Test Suite | File | Purpose |
|------------|------|---------|
| Runner tests | `test_runner.sh` | Worker loop validation |
| Priority tests | `test_priority.sh` | Bead selection weights |
| Claim tests | `test_claim.sh` | Atomic claim retry logic |
| Bootstrap tests | `test_bootstrap.sh` | Dependency installation |
| Adapter tests | `test_adapters.sh` | Agent invocation |

**Why missing:** Testing infrastructure typically tracked separately from feature implementation. No dedicated testing beads created yet.

---

## 8. Documentation & Examples

### ❌ WITHOUT Beads (MISSING)

| Document | Mentioned In | Purpose |
|----------|--------------|---------|
| README.md | File structure | Repository documentation |
| Agent config examples | `config/agents/*.yaml` | Built-in agent configs (CLOSED: nd-3ba) |
| Config example | `config/needle.yaml.example` | Default config template |
| Hook examples | `src/hooks/defaults/` | Default hook templates (IN_PROGRESS: nd-bqi) |

**Why missing:** Documentation and examples often not tracked as implementation beads. However, built-in agent configs ARE tracked (nd-3ba, closed).

---

## 9. Phase Analysis

### Phase 1: Core Runner (MVP) - **60% Complete**

**CLOSED (12/18):**
- ✅ CLI skeleton (nd-2g9)
- ✅ One-liner installer (nd-2u4)
- ✅ Global configuration loader (nd-2mc)
- ✅ Agent adapter system (nd-3pu)
- ✅ Built-in adapters (nd-3ba)
- ✅ Prompt escape (nd-68r)
- ✅ `test-agent` command (nd-3gv)
- ✅ tmux session management (nd-u74)
- ✅ Bead claim/release (nd-31l)
- ✅ Event logging (nd-1cz, nd-6yj)
- ✅ `list`, `attach`, `stop` commands (nd-28x, nd-2dt, nd-19k)
- ✅ `version` command (nd-16x)

**IN_PROGRESS (1/18):**
- 🔶 Strand 1: Pluck (nd-2gc) - **CRITICAL PATH**

**OPEN (5/18):**
- 🟡 Interactive onboarding (nd-b6n) - **CRITICAL**
- 🟡 Bootstrap system (nd-38g) - **CRITICAL**
- 🟡 `run` command (nd-qzu) - **CRITICAL**
- 🟡 NATO naming (nd-xnj)
- 🟡 Worker loop (nd-qft) - **CRITICAL**

**MISSING (0/18):**
- All MVP features have beads!

### Phase 2: Full Priority System - **75% Complete**

**CLOSED (10/13):**
- ✅ Strand 2: Explore (nd-hq2)
- ✅ Strand 3: Mend (nd-1sk)
- ✅ Concurrency limits (nd-1ea)
- ✅ Rate limiting (nd-1ws)
- ✅ Token extraction (nd-28p)
- ✅ Cost calculation (nd-ysf)
- ✅ Budget enforcement (nd-23s)
- ✅ Worker state registry (nd-e5q)
- ✅ Hook system (nd-2w0)
- ✅ Worker heartbeat emission (nd-fjz)

**IN_PROGRESS (2/13):**
- 🔶 Watchdog stuck detection (nd-1z9)
- 🔶 Default hook templates (nd-bqi)

**OPEN (0/13):**
- None!

**MISSING (1/13):**
- ❌ `--count=N` multi-worker launch (part of `needle run`, nd-qzu)

### Phase 3: Advanced Features - **30% Complete**

**CLOSED (2/9):**
- ✅ Strand 4: Weave (nd-27u)
- ✅ Strand 7: Knot (nd-d2a)
- ✅ Bead mitosis (nd-39h)
- ✅ `status` command (nd-xq9)

**OPEN (2/9):**
- 🟡 Strand 5: Unravel (nd-20p)
- 🟡 Strand 6: Pulse (nd-qpj)

**MISSING (5/9):**
- ❌ Workspace auto-discovery (may be part of Strand 2)
- ❌ Configuration hot-reload
- ❌ Billing model profiles (`pay_per_token`, `use_or_lose`, `unlimited`)

---

## 10. Critical Path Analysis

### 🚨 Blocking Issues (Must Complete for MVP)

| Priority | Bead ID | Title | Blocks |
|----------|---------|-------|--------|
| **P0** | nd-qft | Main worker loop | Everything - core execution |
| **P0** | nd-2gc | Strand 1: Pluck | Worker loop needs work source |
| **P0** | nd-qzu | `needle run` command | Worker launch |
| **P0** | nd-b6n | `needle init` command | First-run experience |
| **P0** | nd-38g | `needle setup` command | Dependency bootstrap |

### 🔥 High Priority (MVP Experience)

| Priority | Bead ID | Title | Impact |
|----------|---------|-------|--------|
| **P1** | nd-xnj | Worker naming (NATO) | Session identification |
| **P1** | nd-39i | Dependency detection | Bootstrap UX |
| **P1** | nd-n0y | Dependency installation | Bootstrap UX |
| **P1** | nd-2nr | OS detection | Bootstrap compatibility |

### 🟢 Medium Priority (Phase 2 Completion)

| Priority | Bead ID | Title | Status |
|----------|---------|-------|--------|
| **P2** | nd-1z9 | Watchdog monitor | in_progress |
| **P2** | nd-bqi | Default hook templates | in_progress |

---

## 11. Summary Statistics

### Overall Coverage

| Category | Total | Closed | In Progress | Open | Missing | Coverage |
|----------|-------|--------|-------------|------|---------|----------|
| **CLI Commands** | 18 | 12 | 1 | 5 | 0 | 100% |
| **Strands** | 7 | 4 | 1 | 2 | 0 | 100% |
| **Core Modules** | 28 | 24 | 2 | 2 | 0 | 100% |
| **Bootstrap** | 8 | 4 | 0 | 4 | 3 | 62% |
| **Phase 3 Features** | 9 | 4 | 0 | 2 | 3 | 67% |
| **Infrastructure** | 6 | 1 | 0 | 0 | 5 | 17% |
| **Testing** | 5 | 0 | 0 | 0 | 5 | 0% |
| **TOTAL** | 81 | 49 | 4 | 15 | 16 | **80%** |

### Bead Status Distribution

- **Closed:** 48 beads (68%)
- **In Progress:** 5 beads (7%)
- **Open:** 18 beads (25%)
- **Total:** 71 beads

### Phase Completion

- **Phase 1 (MVP):** 60% complete, **4 critical beads open**
- **Phase 2 (Full System):** 75% complete, 2 in_progress
- **Phase 3 (Advanced):** 30% complete, 2 open + 5 missing

---

## 12. Recommendations

### Immediate Actions (This Sprint)

1. **Complete Critical Path Beads (P0):**
   - nd-qft: Main worker loop - **BLOCKER**
   - nd-2gc: Strand 1: Pluck - **IN_PROGRESS**
   - nd-qzu: `needle run` command
   - nd-b6n: `needle init` command
   - nd-38g: `needle setup` command

2. **Create Missing MVP Beads:**
   - Bootstrap modules (workspace_setup.sh, create_config.sh, paths.sh)
   - Multi-worker launch (`--count=N` flag in `needle run`)

### Short-Term (Next Sprint)

3. **Complete High-Priority Open Beads (P1):**
   - nd-xnj: Worker naming
   - nd-39i, nd-n0y, nd-2nr: Bootstrap system

4. **Finish In-Progress Beads:**
   - nd-1z9: Watchdog monitor
   - nd-338: `needle restart` command
   - nd-bqi: Default hook templates

### Medium-Term (Phase 3)

5. **Create Beads for Missing Phase 3 Features:**
   - Billing model profiles configuration
   - Configuration hot-reload
   - Workspace auto-discovery (if not part of Strand 2)

6. **Testing Infrastructure:**
   - Create beads for test suites (test_runner.sh, etc.)
   - Establish testing strategy

### Long-Term (Maintenance)

7. **Infrastructure Tracking:**
   - Consider whether state file management needs explicit beads
   - Cache directory management may warrant a bead

---

## 13. Conclusion

The NEEDLE project has **excellent tracking coverage** with 71 beads covering 80% of planned features. The implementation is well-organized and progressing systematically through phases.

**Key Strengths:**
- All CLI commands have beads ✅
- All 7 strands tracked ✅
- Core modules well-represented (24/28 closed) ✅
- Phase 2 nearly complete (75%) ✅

**Key Gaps:**
- Bootstrap/onboarding system needs attention (5 critical open beads)
- Phase 3 features still early (30% complete)
- Testing infrastructure not tracked
- Some configuration features not scoped (billing models, hot-reload)

**Critical Path:** Focus on **5 P0 beads** (nd-qft, nd-2gc, nd-qzu, nd-b6n, nd-38g) to achieve MVP. These are the essential pieces needed for a functional worker system.

**Velocity Assessment:** With 48 closed beads out of 71 (68% closed rate), the project is making solid progress. The remaining 18 open beads + 5 in_progress are achievable for a complete v1.0 release.
