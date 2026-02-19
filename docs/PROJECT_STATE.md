# Project State

_Last updated: 2026-02-19_

---

## Project Overview

TcUnit is an open-source unit testing framework for TwinCAT 3 (IEC 61131-3 Structured Text). It provides test suite management, assertion methods for all primitive and array types, and result reporting via ADS messages and xUnit XML output. This fork extends TcUnit with Photara Base library integration for structured logging to .db/.csv/.jsonl files.

---

## Current State Summary

7 FBs extended with FB_BaseStatic, centralized assert failure tracing in LogAssertFailure, test lifecycle and run lifecycle tracing, Phases 1, 2, and 3 complete.

---

## What is Done

| Phase | What Was Built | Status |
|-------|---------------|--------|
| Phase 1: Base Integration | FB_TestSuite, FB_TcUnitRunner, FB_AdsAssertMessageFormatter EXTENDS FB_BaseStatic; TraceWithSeverity calls at assertion failures, test pass/fail, test skipped, duplicate tests, empty suites, run start/complete, abort | Done |
| Phase 2: Extend Remaining FBs | FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, FB_AdsTestResultLogger EXTENDS FB_BaseStatic; overflow/error/completion traces | Done |
| Phase 3: Enrich Test Logging | Centralized assert failure tracing in LogAssertFailure with expected/actual/message/path; test duration in pass/fail traces; suite completion summary with pass/fail/skip counts and duration | Done |

---

## What is Active

_No active work items. All phases complete._

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

---

## Known Tech Debt

- FB_TestSuite.InstancePath is commented out (lines 13-15) rather than deleted — relies on inherited FB_BaseStatic.InstancePath (STRING vs T_MaxString type difference)
- ~~FB_AdsTestResultLogger, FB_xUnitXmlPublisher, FB_AssertResultStatic, FB_AssertArrayResultStatic have error conditions only logged via ADS — no structured logging~~ **Resolved (Phase 2)**
- No CLAUDE.md in this repo yet for project-specific agent instructions
- `I_AssertMessageFormatter` interface doesn't require `FB_BaseStatic` — if a non-ADS implementation is created, it would need its own trace strategy

---

## For New Agents

Read these documents in this order:

1. **PROJECT_STATE.md** (this file) — Where we are
2. **EXECUTION_PLAN.md** — What to build next
3. **BREADCRUMBS.md** — What to watch out for
4. **Your assigned TASK_BRIEF** — What specifically to do

Do not rebuild completed work. The "What is Done" table above shows what's already built. Check BREADCRUMBS.md before starting — it contains gotchas that will save you time.
