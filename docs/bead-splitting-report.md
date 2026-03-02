# NEEDLE Bead Splitting Report

**Date:** 2026-03-02
**Action:** Comprehensive bead review and splitting
**Result:** 4 oversized beads split into 13 focused beads

---

## Executive Summary

Reviewed all 82 beads in NEEDLE project to identify oversized tasks that should be split. Found **4 beads that were too large** and combined multiple concerns, increasing timeout risk and reducing parallel work opportunities.

**Key Improvements:**
- ✅ Split 4 oversized beads into 13 focused beads
- ✅ Reduced complexity per bead (fewer acceptance criteria)
- ✅ Enabled incremental progress on critical features
- ✅ Established clear dependencies between split beads
- ✅ Reduced timeout risk on complex implementations

---

## Beads Split

### 1. nd-qzu: Implement needle run command
**Status:** Closed (split)
**Original Size:** ~4,200 characters, 12+ acceptance criteria
**Problem:** Combined CLI parsing, validation, process management, and multi-worker spawning

**Split Into:**
- **nd-3up:** CLI parsing and validation (P0)
  - Parse command options
  - Validate workspace and agent
  - Apply config defaults

- **nd-2ov:** Single worker invocation (P0)
  - Session name generation
  - Environment setup
  - Start single worker in tmux

- **nd-2pw:** Multi-worker spawning (P1, Phase 2)
  - Handle --count=N option
  - Spawn multiple workers in parallel
  - Worker naming via NATO alphabet

**Benefits:**
- Parts 1-2 (P0) enable MVP with single worker
- Part 3 can be deferred to Phase 2
- Faster testing of basic functionality

---

### 2. nd-b6n: Implement needle init command
**Status:** Closed (split)
**Original Size:** ~4,500 characters, 8+ acceptance criteria
**Problem:** Combined dependency checking, installation, config generation, and workspace setup

**Split Into:**
- **nd-20k:** Dependency checker (P1)
  - Check for required tools (br, yq, jq, tmux)
  - Report status and versions
  - Suggest next steps

- **nd-14y:** Interactive prompts and config (P1)
  - Prompt for workspace, agent, budget
  - Generate config.yaml
  - Validate workspace has .beads/

- **nd-2q6:** State files and hook templates (P2)
  - Create ~/.needle/ directory structure
  - Initialize state files
  - Create hook templates

**Benefits:**
- Dependency checking is separable from config
- Each step can be tested independently
- Better error messages per phase

---

### 3. nd-qft: Implement main worker loop
**Status:** Closed (split)
**Original Size:** ~3,800 characters, 10+ acceptance criteria
**Problem:** Combined loop structure, bead execution, cleanup, and crash recovery

**Split Into:**
- **nd-qni:** Core structure and initialization (P0)
  - Main loop iteration
  - Graceful shutdown handling
  - Call strand engine for work detection

- **nd-1pu:** Bead execution and effort recording (P0)
  - Atomic bead claiming
  - Agent invocation via dispatcher
  - Token extraction and cost calculation

- **nd-3i6:** Cleanup and crash recovery (P1)
  - Handle exit codes (success/failure/timeout)
  - Release beads on failure
  - Exponential backoff on repeated failures

**Benefits:**
- Core loop (Parts 1-2) can work without advanced recovery
- Recovery logic can be enhanced later
- Critical for MVP - splitting reduces risk

---

### 4. nd-qpj: Implement Strand 6: Pulse
**Status:** Closed (split)
**Original Size:** ~4,800 characters, 8+ detectors
**Problem:** Combined framework with 5+ separate detector implementations

**Split Into:**
- **nd-2oy:** Framework and state management (P3)
  - Frequency checking
  - State files (last_scan, seen_issues)
  - Bead creation helper
  - Max beads per run enforcement

- **nd-21h:** Security scan detector (P3)
  - npm audit integration
  - pip-audit integration
  - CVE parsing and bead creation

- **nd-1fr:** Dependency freshness detector (P3)
  - Check package ages via registries
  - Flag stale dependencies (>1 year)

- **nd-gn2:** Doc drift, coverage, TODO detectors (P3)
  - Documentation drift (broken references)
  - Test coverage gaps (<70%)
  - Stale TODO comments

**Benefits:**
- Framework (Part 1) can be implemented first
- Detectors (Parts 2-4) can be added incrementally
- Each detector is independently testable
- Phase 3 feature - incremental delivery appropriate

---

## Analysis Criteria

### Why These Beads Were Split

**Multiple Distinct Deliverables:**
- nd-qzu had CLI + process mgmt + multi-worker
- nd-b6n had checking + prompting + installing + setup
- nd-qft had loop + execution + cleanup + recovery
- nd-qpj had framework + 5 detectors

**High Acceptance Criteria Count:**
- nd-qzu: 12+ criteria across different concerns
- nd-b6n: 8+ criteria with sequential dependencies
- nd-qft: 10+ criteria mixing state and execution
- nd-qpj: 8+ criteria for unrelated detectors

**Sequential Dependencies:**
- "First check dependencies, then install, then create config"
- "Initialize loop, then execute, then cleanup"
- "Create framework, then add detectors"

**Timeout Risk:**
- Several closed beads (~20%) had timeout escalations
- Original beads >4,000 characters had higher failure rate
- Splitting reduces scope and timeout likelihood

---

## Beads NOT Split (Appropriately Sized)

### Test Suites (Focused)
- nd-2uy: Bead claim test suite
- nd-14v: Agent adapter test suite
- nd-2lv: Bead selection test suite
- nd-3kc: Worker loop test suite
- nd-h6o: Bootstrap test suite

### Single-Purpose Modules
- nd-15b: PATH management
- nd-2nr: OS detection
- nd-xnj: Worker naming (NATO alphabet)
- nd-vt9: Config creation
- nd-2kh: Workspace setup

### CLI Commands (Simple)
- nd-33b: needle agents
- nd-338: needle restart
- Most closed CLI commands (10-12 successfully completed)

---

## Impact on Project

### Before Splitting
- **Total beads:** 82
- **Closed:** 50 (61%)
- **Open:** 27 (33%)
- **In Progress:** 5 (6%)
- **Timeout/escalations:** ~20% of closed beads

### After Splitting
- **Total beads:** 95 (+13)
- **Closed:** 54 (57%)
- **Open:** 36 (38%)
- **In Progress:** 5 (5%)
- **Average bead size:** Reduced by ~30%

### Critical Path Changes

**MVP Critical Beads (Before):**
1. nd-qft: Worker loop (huge, risky)
2. nd-qzu: needle run (huge, risky)
3. nd-b6n: needle init (large)

**MVP Critical Beads (After):**
1. nd-qni: Loop core (focused)
2. nd-1pu: Loop execution (focused)
3. nd-3up: Run CLI parsing (focused)
4. nd-2ov: Run single worker (focused)
5. nd-20k: Init dependency check (focused)
6. nd-14y: Init config prompts (focused)

**Result:** 3 risky beads → 6 focused beads with clear scope

---

## Recommendations

### For Future Beads

**Split If:**
- Description >4,000 characters
- 10+ acceptance criteria
- Multiple distinct files/modules to create
- Sequential phases ("first X, then Y, then Z")
- Mixes concerns (CLI + execution + recovery)

**Keep Together If:**
- Single file/module
- <3,000 characters
- <8 acceptance criteria on same concern
- Simple, focused task
- No clear split points

### Pattern: Three-Part Split

Most splits followed this pattern:
1. **Part 1:** Setup/infrastructure/framework (P0)
2. **Part 2:** Core implementation/execution (P0)
3. **Part 3:** Advanced features/cleanup/recovery (P1 or P2)

This pattern enables:
- MVP with Parts 1-2
- Enhanced functionality with Part 3 later
- Clear dependencies (Part 2 blocks on Part 1)

---

## Conclusion

**Splitting large beads improves:**
- ✅ **Velocity** - Smaller beads complete faster
- ✅ **Parallelism** - More workers can work simultaneously
- ✅ **Testability** - Each part independently verifiable
- ✅ **Risk reduction** - Lower timeout likelihood
- ✅ **Clarity** - Clear scope per bead

**Project Status:**
- 95 beads with appropriate granularity
- 54 closed (good progress rate)
- 41 open/in-progress with manageable scope
- MVP achievable with ~10 focused P0/P1 beads

**Next Steps:**
1. Workers should focus on P0 beads (nd-qni, nd-1pu, nd-3up, nd-2ov)
2. Bootstrap system needs attention (nd-39i, nd-n0y, nd-2nr)
3. Phase 2 features can proceed in parallel after MVP
4. Phase 3 features well-organized for incremental delivery
