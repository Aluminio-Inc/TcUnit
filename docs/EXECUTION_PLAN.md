# Execution Plan

**Date**: 2026-07-16
**Status**: Phase 4 implemented and audited; hardening/verification remain next, followed by the approved multi-task tagged-execution architecture
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

| Phase 4 | FB_TimedTestSuite — real-time elapsed testing (TEST_TIMED, TEST_TIMED_ORDERED, WaitForTime, WaitForCondition, WaitTimedOut, GetTimedTestResult); 3 new DUTs; Type_TIMEOUT + Type_WAIT_MISUSE assertion types; SetTestFailed widened to INTERNAL | [timed-test-suite-design.md](./superpowers/specs/2026-05-20-timed-test-suite-design.md) |

**Current state**: 8 FBs (7 extended + 1 new), Phase 4 code landed on `feat/timed-test-suite`, and a seven-commit audit identified two immediate hardening fixes before XAE verification: active timed-context lifecycle and `GetTimedTestResult()` name normalization.

---

## What to Build Next

### Phase 4a: Timed Test Suite Hardening from Audit

**Value**: High | **Effort**: Small | **Prerequisites**: Phase 4 code complete (branch `feat/timed-test-suite`)
**Status**: Next up

1. Fix `_nActiveTimedTestIdx` lifecycle so out-of-context wait calls cannot reuse the previous timed test's state after the final timed test method in a scan
2. Normalize `GetTimedTestResult(TestName)` with the same trim behavior used by `TEST()`, `TEST_ORDERED()`, and `TEST_TIMED()`
3. Re-review wait-context assumptions after the code change and update BREADCRUMBS/PROJECT_STATE if the implementation strategy changes

**Acceptance**:
- Out-of-context waits do not bind to stale timed state
- `GetTimedTestResult(' padded name ')` resolves the same test as the registration paths
- Repo tracking docs reflect the hardened behavior accurately

### Phase 4b: Timed Test Suite Verification and Level 1 Tests

**Value**: High | **Effort**: Small | **Prerequisites**: Phase 4a complete
**Status**: After Phase 4a

1. Open TcUnit.sln in XAE, build, verify clean compilation
2. Write Level 1 green-path tests in TwinCAT_Tests: `FB_TimedSuiteGreenPathTests EXTENDS FB_TimedTestSuite` with short real-time waits (T#1S, T#2S)
3. Recompile TcUnit as library, bump version, install, update consumer plcproj references
4. Optionally: write Level 2 verifier suite (local-only, red run expected — see spec for mechanism)

### Phase 5: Multi-Task Tagged Execution

**Value**: High | **Effort**: Large | **Prerequisites**: Phase 4a/4b, sequential-runner regression, TwinCATBase multi-writer audit before production enablement
**Status**: Revised design approved by ADR-004/ADR-005; implementation after Phase 4b

Implement selective suite tags and safe multi-task execution using compact raw-task-to-slot
registration, coordinator-sealed immutable execution plans, task-owned mutable contexts,
machine-readable failure/status, memory-safe result handling, centrally published per-task xUnit
shards, and an authoritative manifest.

Detailed design:
[2026-07-16-multitask-tagged-execution-design.md](./superpowers/specs/2026-07-16-multitask-tagged-execution-design.md)

Implementation sequence:

1. Fix and commit `RUN_IN_SEQUENCE` completion coverage and correct xUnit count semantics
2. Run the XAE compile/memory/ABI spike
3. Add coordinator, status/error DUTs, compact task registration, and task contexts
4. Migrate every mutable global/function-static reference while keeping one-task verifier green
5. Add immutable suite assignment/planning and single-task tagged selection
6. Refactor both run modes over the common plan and enable multi-task execution
7. Replace per-task full result snapshots with immutable suite readers and central shard/manifest reporting
8. Add committed two-task verifier, negative fault injection, static analysis, stress, memory, cycle-time, and core-placement evidence
9. Qualify all Photara consumers, update docs, bump version, and rebuild/install the library

**Acceptance**: All acceptance gates in the revised design spec are mandatory. In particular, no
configuration error may produce a green run, no suite may execute more than once, no task may touch
another task's mutable execution context, task capacity must support sparse raw task indices, the
default memory delta must be measured/approved, and downstream merging must consume the manifest.

### Phase 6: Per-Cycle Test Throttling (Proposed)

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
- **#5** Suite tagging / selective execution — decided by ADR-004 and refined by ADR-005; Phase 5
- **#6** Adaptive cycle-time throttling (monitor `PlcTaskSystemInfo.LastExecTime`, auto-back-off)
- **#7** Staggered suite warm-up (init-phase calls one suite per cycle before main execution)
- **#8** Per-suite `MaxTestsPerCycle` property (heavy suites self-throttle, lightweight suites unaffected)
- **#9** Chunked result reporting (spread ADS messages and result aggregation across cycles)

These can be implemented independently. Rough priority by value:
1. **#8 (per-suite throttle)** — highest remaining practical impact after Phase 5
2. **#6 (adaptive throttle)** — elegant but depends on `PlcTaskSystemInfo` access pattern
3. **#7 (warm-up)** + remaining **#9 (chunked ADS/result details)** — smooth edges, lower priority
4. **#4 (global RUN_THROTTLED)** — may be superseded by #8 if per-suite is chosen

**Decision required before implementation**: OPEN_DECISIONS.md #4 and #6–#9. Decision #5 is complete.

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
[DONE]          │
                ▼
            Phase 4: Timed Test Suite [CODE COMPLETE]
                │
                ▼
            Phase 4a: Hardening from Audit [NEXT]
                │
                ▼
            Phase 4b: XAE Verification + Level 1 Tests
                │
                ▼
            Phase 5: Multi-Task Tagged Execution
                │
                ▼
            Phase 6: Per-Cycle Test Throttling [PROPOSED]
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
| Phase 4a | High | Small | Iterative | Next |
| Phase 4b | High | Small | Iterative | After 4a |
| Phase 5 | High | Large | Staged/verification-gated | After 4b |
| Phase 6 | High | Medium | TBD after decision #4/#8 | Proposed |

---

## Open Decisions

Decisions that affect the execution plan are tracked in [OPEN_DECISIONS.md](./OPEN_DECISIONS.md). Reference them here when a phase is blocked by an unresolved decision.

For detailed hardening and modernization work in `TcUnit-Verifier_DotNet`, see [VERIFIER_IMPROVEMENT_PLAN.md](./VERIFIER_IMPROVEMENT_PLAN.md).

---

## For New Agents / Sessions

1. **Read this file first** — it tells you what to build next
2. **Check PROJECT_STATE.md** — it tells you what's currently in progress
3. **Read BREADCRUMBS.md** — it saves you from repeating mistakes
4. **Read the detailed reference doc** for whatever phase you're working on
5. **Don't rebuild completed phases** — the table at the top shows what's done
