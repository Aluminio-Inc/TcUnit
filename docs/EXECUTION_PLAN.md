# Execution Plan

**Date**: 2026-02-19
**Status**: Complete — All phases done (1, 2, 3)
**Purpose**: Single, value-ordered sequence of development phases. Open this file and know exactly what to build next.

---

## How to Use This Document

1. **Start at the first incomplete phase.** Phases are ordered by value — highest first.
2. **Check prerequisites.** Each phase lists what must be complete before starting.
3. **Reference detailed docs.** Each phase points to the doc(s) with full specs.
4. **Mark phases complete** in the Completed Work table as work finishes.

---

## Completed Work

| Phase | What Was Built | Reference |
|-------|---------------|-----------|
| Phase 1 | FB_BaseStatic integration into FB_TestSuite, FB_TcUnitRunner, FB_AdsAssertMessageFormatter; TraceWithSeverity across assertion failures, test lifecycle, run lifecycle | BREADCRUMBS.md |
| Phase 2 | FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, FB_AdsTestResultLogger EXTENDS FB_BaseStatic; overflow/error/completion traces; dead-code typo fix in GetDetectionCountThisCycle | BREADCRUMBS.md |
| Phase 3 | Centralized assert failure tracing in LogAssertFailure; duration in pass/fail; suite completion summary with counts | BREADCRUMBS.md |

**Current state**: 7 FBs extended, all phases complete, structured logging pipeline fully active

---

## What to Build Next

### Phase 4: Per-Cycle Test Throttling (Proposed)

**Value**: High | **Effort**: Medium | **Prerequisites**: None (Phases 1-3 complete)
**Status**: Brainstorming — see OPEN_DECISIONS.md decision #4
**Why**: Heavy test suites (e.g., `FB_SequencerAssertTests` with behavioral mock harnesses) cause PLC cycle overruns because TcUnit executes all test methods within a suite in a single scan. This blocks scaling to 25+ sequencer tests.

**Proposed approach**: Add `RUN_THROTTLED(nMaxTests, tBetween)` entry point that limits how many test methods execute per PLC cycle. Non-breaking — existing `RUN()` and `RUN_IN_SEQUENCE()` unchanged.

**Open questions**:
- Should throttling be global (across all suites) or per-suite? (Decisions #4 vs #8)
- How do multi-cycle tests (state machines that need to be called every cycle) interact with throttling?
- What's the right default? Unlimited (backward compat) vs conservative (e.g., 3)?

**Related scaling proposals** (all in OPEN_DECISIONS.md):
- **#4** Per-cycle test throttling (global `RUN_THROTTLED` entry point)
- **#5** Suite tagging / selective execution (`RUN(sTag := 'sequencer')`)
- **#6** Adaptive cycle-time throttling (monitor `PlcTaskSystemInfo.LastExecTime`, auto-back-off)
- **#7** Staggered suite warm-up (init-phase calls one suite per cycle before main execution)
- **#8** Per-suite `MaxTestsPerCycle` property (heavy suites self-throttle, lightweight suites unaffected)
- **#9** Chunked result reporting (spread ADS messages and result aggregation across cycles)

These can be implemented independently. Rough priority by value:
1. **#5 (tagging)** + **#8 (per-suite throttle)** — highest practical impact, most likely to be adopted
2. **#6 (adaptive throttle)** — elegant but depends on `PlcTaskSystemInfo` access pattern
3. **#7 (warm-up)** + **#9 (chunked reporting)** — smooth edges, lower priority
4. **#4 (global RUN_THROTTLED)** — may be superseded by #8 if per-suite is chosen

**Decision required before implementation**: OPEN_DECISIONS.md #4–#9

---

### Phase 2: Extend TraceWithSeverity to Remaining FBs [DONE]

**Value**: Medium | **Effort**: Small | **Prerequisites**: Phase 1 complete
**Why**: Assert buffer overflow and xUnit file I/O errors are currently silent or ADS-only. Adding structured logging surfaces these in .jsonl for agent analysis.

#### 2.1 FB_AssertResultStatic and FB_AssertArrayResultStatic [DONE]

Extended both with FB_BaseStatic. Added TraceWithSeverity at assert buffer overflow (Error, one-shot). Corrected typo in dead-code method `GetDetectionCountThisCycle()` (`.Message` compared twice instead of `.TestInstancePath`) — no runtime impact, method is never called.

#### 2.2 FB_xUnitXmlPublisher [DONE]

Extended with FB_BaseStatic. Added TraceWithSeverity at file I/O failure (Error) and export success (Info).

#### 2.3 FB_AdsTestResultLogger [DONE]

Extended with FB_BaseStatic. Added TraceWithSeverity at test count overflow (Error) and final results summary (Info).

**Acceptance**: **Met.** All 4 FBs extend FB_BaseStatic; error/overflow conditions traced at Error severity; existing ADS logging unchanged.

---

### Phase 3: Enrich Test Result Logging [DONE]

**Value**: High | **Effort**: Medium | **Prerequisites**: Phase 1 complete
**Why**: The .jsonl output is the primary value proposition for agent-driven test analysis. Richer structured data in each trace entry enables more powerful queries.

#### 3.1 Test Duration in Trace Messages [DONE]

TEST PASSED/FAILED traces now include duration: `TEST PASSED: TestName (0.045s)`

#### 3.2 Suite Summary Trace [DONE]

CalculateDuration traces: `SUITE COMPLETE: path - 4 passed, 1 failed, 1 skipped (0.23s)`

#### 3.3 Assert Detail in Trace Messages [DONE]

Centralized in `FB_AdsAssertMessageFormatter.LogAssertFailure()` — single TraceWithSeverity call covers all assertion failures (scalar and array). Trace format: `ASSERT FAIL 'TestPath', EXP: value, ACT: value, MSG: message`. Earlier approach using `_traceExpected`/`_traceActual` instance vars was replaced with this cleaner design.

**Pipeline**: Iterative

**Acceptance**: ~~.jsonl entries contain duration, counts, and assertion details; agents can extract pass rates and timing from logs alone.~~ **Met.**

---

## Assumptions & Constraints

- This is a local fork — no upstream compatibility constraints
- The Photara Base library (TwinCATBase) is available and referenced in the .plcproj
- PRG_LOG / LogTask infrastructure exists in consuming test projects to drain the ring buffer to .jsonl/.db
- FB_BaseStatic's TraceWithSeverity does not require Initialize() to be called when only using the ring buffer logging path

---

## Phase Dependency Graph

```
Phase 1: Base Integration (FB_TestSuite, FB_TcUnitRunner)  [DONE]
    │
    ├──────────────┐
    ▼              ▼
Phase 2:        Phase 3:
Extend to       Enrich Test
Remaining FBs   Result Logging [DONE]
[DONE]
```

---

## Pipeline Recommendations

| Phase | Pipeline | Rationale |
|-------|----------|-----------|
| Phase 1 | Iterative | Well-scoped, 2 FBs, clear insertion points |
| Phase 2 | Iterative | Repeat same pattern on 4 more FBs |
| Phase 3 | Iterative | Enhance existing trace calls with richer data |

---

## Value x Effort Matrix

| Phase | Value | Effort | Pipeline | Category |
|-------|-------|--------|----------|----------|
| Phase 1 | High | Small | Iterative | Done |
| Phase 2 | Medium | Small | Iterative | Done |
| Phase 3 | High | Medium | Iterative | Done |

---

## Open Decisions

Decisions that affect the execution plan are tracked in [OPEN_DECISIONS.md](./OPEN_DECISIONS.md). Reference them here when a phase is blocked by an unresolved decision.

---

## For New Agents / Sessions

1. **Read this file first** — it tells you what to build next
2. **Check PROJECT_STATE.md** — it tells you what's currently in progress
3. **Read BREADCRUMBS.md** — it saves you from repeating mistakes
4. **Read the detailed reference doc** for whatever phase you're working on
5. **Don't rebuild completed phases** — the table at the top shows what's done
