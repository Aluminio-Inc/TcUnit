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

_All phases complete. No pending work._

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
