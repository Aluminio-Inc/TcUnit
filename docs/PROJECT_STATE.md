# Project State

_Last updated: 2026-07-16_

---

## Project Overview

TcUnit is an open-source unit testing framework for TwinCAT 3 (IEC 61131-3 Structured Text). It provides test suite management, assertion methods for all primitive and array types, and result reporting via ADS messages and xUnit XML output. This fork extends TcUnit with Photara Base library integration for structured logging to .db/.csv/.jsonl files.

---

## Current State Summary

7 FBs extended with FB_BaseStatic, centralized assert failure tracing in LogAssertFailure, test lifecycle and run lifecycle tracing, Phases 1-3 complete. **Phase 4a/4b and the Phase 5 Step-0 prerequisites are COMPLETE** (2026-07-18, candidate `2026.7.18.1`, tag pending release approval): timed-suite hardening (cycle-guarded wait context, trimmed result lookup, one-shot misuse traces), the `RUN_IN_SEQUENCE` completion latch, corrected xUnit/JUnit count semantics with UDINT aggregates and `<skipped/>` elements, and distinct abort/completed terminal outcomes — all proven red-green on hardware (192.168.225.2.1.1) with committed campaigns, canonical goldens, an automated abort probe, and the full verifier battery at its expected 121 failures. Evidence: `docs/verification/2026-07-17-step0-verification.md`. Phase 5 multi-task tagged execution (ADR-004/ADR-005, spec Revision 3) is next: the compile/ABI spike.

---

## What is Done

| Phase | What Was Built | Status |
|-------|---------------|--------|
| Phase 1: Base Integration | FB_TestSuite, FB_TcUnitRunner, FB_AdsAssertMessageFormatter EXTENDS FB_BaseStatic; TraceWithSeverity calls at assertion failures, test pass/fail, test skipped, duplicate tests, empty suites, run start/complete, abort | Done |
| Phase 2: Extend Remaining FBs | FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, FB_AdsTestResultLogger EXTENDS FB_BaseStatic; overflow/error/completion traces | Done |
| Phase 3: Enrich Test Logging | Centralized assert failure tracing in LogAssertFailure with expected/actual/message/path; test duration in pass/fail traces; suite completion summary with pass/fail/skip counts and duration | Done |
| Phase 4: Timed Test Suite | FB_TimedTestSuite EXTENDS FB_TestSuite — real-time elapsed testing with TEST_TIMED, TEST_TIMED_ORDERED, WaitForTime, WaitForCondition, WaitTimedOut, GetTimedTestResult; safety timeout auto-fail; E_WaitType (member `Duration`, renamed from reserved word), ST_TimedTestState, ST_TimedTestResult DUTs; Type_TIMEOUT and Type_WAIT_MISUSE assertion types | **Done** — hardened (cycle-guarded context) and hardware-verified 2026-07-18 via the step-0 campaigns |
| Phase 5 Step 0: Prerequisites | Sequential completion latch fix; xUnit counts (UDINT aggregates, total=passed+failed+skipped, `<skipped/>` elements, no `disabled` attr); distinct ABORTED/COMPLETED terminal outcomes; committed campaigns + runner/probe/verify tooling; verifier single-suite check | **Done** — release candidate 2026.7.18.1, tag pending approval |

---

## What is Active

| Item | Branch | Status | Next Step |
|------|--------|--------|-----------|
| Step-0 release | `feat/timed-test-suite` | All gates green on 2026.7.18.1 (campaigns, A1, S1, verifier battery 121/121); library binary + tag await release approval (replacement verifier gate + credential-rotation decision) | Tag `TcUnit-2026.7.18.1`, then start the Phase 5 compile/ABI spike |

---

## Planned (Proposed)

- **Phase 5: Multi-Task Tagged Execution** — approved high-level direction plus coordinated runtime refinement: compact raw-task-to-slot mapping, immutable suite plans, task-owned state, fail-closed status, bounded-memory reporting, per-task xUnit shards, and an authoritative manifest. Design: [2026-07-16-multitask-tagged-execution-design.md](./superpowers/specs/2026-07-16-multitask-tagged-execution-design.md)
- **Phase 6: Per-Cycle Test Throttling** — remains proposed under OPEN_DECISIONS #4/#8 after multi-task support
- Verifier reliability and modernization plan for `TcUnit-Verifier_DotNet`: [VERIFIER_IMPROVEMENT_PLAN.md](./VERIFIER_IMPROVEMENT_PLAN.md)

---

## What is Blocked

_Nothing blocked._

---

## Key Components

| Component | Status | Notes |
|-----------|--------|-------|
| FB_TestSuite | Modified | EXTENDS FB_BaseStatic; 4 trace points (test pass/fail w/ duration, test skipped, duplicate test, empty suite) + suite completion summary |
| FB_TcUnitRunner | Modified | EXTENDS FB_BaseStatic; 4 TraceWithSeverity calls (run started parallel/sequential, run completed, abort) |
| FB_AdsAssertMessageFormatter | Modified | EXTENDS Base.FB_BaseStatic; centralized TraceWithSeverity in LogAssertFailure — single trace point for all assertion failures (scalar + array) |
| FB_AdsTestResultLogger | Modified | EXTENDS FB_BaseStatic; test count overflow (Error) + final results summary (Info) traces |
| FB_xUnitXmlPublisher | Modified | EXTENDS FB_BaseStatic; file I/O failure (Error) + export success (Info) traces |
| FB_AssertResultStatic | Modified | EXTENDS FB_BaseStatic; assert buffer overflow (Error) trace; dead-code typo fix in GetDetectionCountThisCycle |
| FB_AssertArrayResultStatic | Modified | EXTENDS FB_BaseStatic; array assert buffer overflow (Error) trace |
| FB_TimedTestSuite | **New** | EXTENDS FB_TestSuite; real-time elapsed testing — TEST_TIMED, TEST_TIMED_ORDERED, WaitForTime, WaitForCondition, WaitTimedOut property, GetTimedTestResult, _FindTestIndex |
| E_WaitType | **New** | Enum: None, Duration, Condition (member renamed from `Time` 2026-07-17 — reserved word broke Save-as-Library, Gotcha #22) |
| ST_TimedTestState | **New** | Per-test wait state struct (safety timeout + wait tracking) |
| ST_TimedTestResult | **New** | Read-only composite for Level 2 verifier inspection |

---

## Known Tech Debt

- FB_TestSuite.InstancePath is commented out (lines 13-15) rather than deleted — relies on inherited FB_BaseStatic.InstancePath (STRING vs T_MaxString type difference)
- ~~FB_AdsTestResultLogger, FB_xUnitXmlPublisher, FB_AssertResultStatic, FB_AssertArrayResultStatic have error conditions only logged via ADS — no structured logging~~ **Resolved (Phase 2)**
- ~~No CLAUDE.md in this repo yet for project-specific agent instructions~~ **Resolved (2026-02-16)**
- `I_AssertMessageFormatter` interface doesn't require `FB_BaseStatic` — if a non-ADS implementation is created, it would need its own trace strategy
- ~~`FB_TimedTestSuite._nActiveTimedTestIdx` is only a best-effort context guard~~ **Resolved 2026-07-18** (cycle + test-name guard `_GetActiveWaitContext`; residual: a bare wait in the same scan directly after an executing block remains textually indistinguishable from a legitimate call)
- ~~`FB_TimedTestSuite.GetTimedTestResult()` does not normalize whitespace~~ **Resolved 2026-07-18** (trims like `TEST()`)
- ~~No XAE build verification or Level 1 timed-suite validation recorded for Phase 4~~ **Resolved 2026-07-18** (step-0 campaigns, hardware-verified)
- ~~`RUN_IN_SEQUENCE()` has no active committed verifier path~~ **Resolved 2026-07-18** (fix + REGRESSION campaign completion assertion + verifier `PRG_TEST_SEQUENCE` single-suite check)
- The .NET verifier harness cannot build on this machine (needs full VS/MSBuild with Windows SDK COM tools); the on-target battery + ADS count comparison is the operating verifier gate
- Campaign evidence is timestamp-scoped, not RunId-correlated — superseded by the Phase 5 run-epoch design
- Raylase ADS suite hardening (review M2-M4: real Ack/sequence lifecycle, readiness boundary cases, ADS-visible diagnostics) is tracked in TwinCAT_Tests, owner Scott
- Multi-task production execution is gated on a TwinCATBase ring-buffer multi-writer/one-reader safety audit and stress test
- The current fixed `ST_TestSuiteResults` snapshot is too large to replicate per task; Phase 5 must use the memory-safe reporting architecture in ADR-005

---

## For New Agents

Read these documents in this order:

1. **PROJECT_SPEC.md** — What this project is (identity, constraints, scope)
2. **PROJECT_STATE.md** (this file) — Where we are
3. **EXECUTION_PLAN.md** — What to build next
4. **BREADCRUMBS.md** — What to watch out for
5. **Your assigned TASK_BRIEF** — What specifically to do

Do not rebuild completed work. The "What is Done" table above shows what's already built. Check BREADCRUMBS.md before starting — it contains gotchas that will save you time.
