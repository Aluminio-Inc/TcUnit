# Open Decisions

Decisions that shape or block project work. Capture decisions as soon as they are identified, even before options are clear.

---

## Open

| # | Decision | Options | Reference | Decide By |
|---|----------|---------|-----------|-----------|
| ~~1~~ | ~~Should FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, and FB_AdsTestResultLogger extend FB_BaseStatic?~~ | Decided: Option A — see ADR-003 | Phase 2 | Decided 2026-02-19 |
| 2 | Should InstancePath in FB_TestSuite be deleted or remain commented out? | A) Delete entirely; B) Keep commented for reference | Phase 1 cleanup | Non-blocking |
| 3 | Should passing assertions also be traced (Info severity) for full audit trails? | A) Add LogAssertSuccess to I_AssertMessageFormatter; B) Add a pass/fail parameter to LogAssertFailure; C) Leave as-is, only trace failures | Future | Non-blocking |
| 4 | Should TcUnit support per-cycle test throttling to prevent cycle overruns with heavy test suites? | A) Add throttling to FB_TestSuite; B) Add a new `RUN_THROTTLED` entry point; C) Leave as-is, consumers split suites | Scaling | Non-blocking |
| 5 | Should TcUnit support suite tagging / selective execution? | A) Tag property on FB_TestSuite + filter param on RUN; B) Named test groups in GVL; C) Leave to consumers (ExcludeFromBuild) | Scaling | Non-blocking |
| 6 | Should FB_TcUnitRunner adaptively throttle based on cycle time usage? | A) Monitor PlcTaskSystemInfo.LastExecTime, skip suites when near limit; B) Leave to consumers | Scaling | Non-blocking |
| 7 | Should FB_TcUnitRunner stagger suite warm-up across cycles? | A) Init-phase that calls one suite per cycle before main execution; B) Leave as-is (all suites active from cycle 1) | Scaling | Non-blocking |
| 8 | Should FB_TestSuite support a per-suite MaxTestsPerCycle property? | A) Add property with windowed method execution; B) Global-only throttling (Decision #4); C) Leave as-is | Scaling | Non-blocking |
| 9 | Should test result reporting be chunked across cycles? | A) FB_TestResults and FB_AdsTestResultLogger spread N results per cycle; B) Leave as-is (burst at end) | Scaling | Non-blocking |

### Decision #4 Context: Per-Cycle Test Throttling

**Problem observed (2026-02-19):** In `TwinCAT_Tests`, running `FB_SequencerAssertTests` with only 5 test harnesses (each containing `FB_OperationSequencer` + 9 mock FBs) causes PLC cycle overruns on TestTask1 (30ms cycle). The root cause is that TcUnit calls the suite body every cycle, which executes ALL test methods in a single scan — including their `InitializeHarness` calls (20 inline `CyclicLogic` iterations each) and `RunHarnessCycles`.

**Current TcUnit behavior:**
- `RUN()` calls all suites every cycle (parallel)
- `RUN_IN_SEQUENCE()` calls one suite per cycle window (sequential) — but within each suite, all test methods still execute in the same scan
- No mechanism exists to spread individual test method execution across cycles

**Option A: Add throttling to FB_TestSuite**

Add a `MaxTestsPerCycle : UINT` property (default 0 = unlimited for backward compat). When set, the suite body tracks which test methods have been called this cycle via a counter. Methods beyond the limit are skipped (return immediately without calling `TEST()`) and deferred to the next cycle.

Implementation sketch:
- `FB_TestSuite` gets `_nTestsExecutedThisCycle : UINT` and `_nTestMethodOffset : UINT`
- At the start of each suite call, `_nTestsExecutedThisCycle := 0`
- Each `TEST('name')` call increments the counter. If `counter > MaxTestsPerCycle`, the call returns FALSE and the method should `RETURN` early
- `_nTestMethodOffset` advances so the next cycle starts from where the previous one left off

Concerns:
- Changes the implicit contract that all test methods run every cycle
- Multi-cycle tests (like WAIT-01 which uses a state machine across real PLC cycles) may need special handling — they rely on being called every cycle to advance their state machines
- The skip mechanism needs to work at the `TEST()` function level, which currently always returns TRUE

**Option B: Add a new `RUN_THROTTLED(MaxTestsPerCycle, TimeBetween)` entry point**

New function that wraps the runner with per-test throttling, separate from existing `RUN` and `RUN_IN_SEQUENCE`. Avoids changing existing behavior.

- `RUN_THROTTLED(nMaxTests := 3, tBetween := T#50MS)`: Each cycle, at most N test methods across all suites are allowed to execute
- Internally, the runner maintains a global counter and method offset
- Existing `RUN()` and `RUN_IN_SEQUENCE()` behavior is unchanged

Concerns:
- More API surface to maintain
- Global throttling (across suites) vs per-suite throttling — which is the right granularity?

**Option C: Leave as-is, consumers restructure tests**

Don't change TcUnit. Consumers split large test suites into micro-suites (1-3 tests each) and use `RUN_IN_SEQUENCE()`. This is the simplest approach but pushes complexity to every consumer.

**Recommendation:** Option B is the safest — additive, non-breaking, and solves the problem at the framework level. However, Option C is viable near-term while Option B is designed and validated.

### Decision #5 Context: Suite Tagging / Selective Execution

**Problem (2026-02-19):** When a test project contains suites across multiple domains (BaseTests, SequencerTests, AuxControlTests), running all of them is often unnecessary and contributes to cycle overruns. Currently the only way to run a subset is `ExcludeFromBuild` in the `.plcproj`, which requires recompilation and redownload.

**Option A: Tag property on FB_TestSuite + filter param on RUN**

Add a `TestTag : STRING` property to `FB_TestSuite` (set in `FB_init` or via a setter). Extend `RUN()` and `RUN_IN_SEQUENCE()` with an optional `sTag : STRING` parameter. When provided, the runner only calls suites whose tag matches.

Implementation sketch:
- `FB_TestSuite` gets `_sTag : STRING(40)` and a `SetTag(sTag)` method or `FB_init` parameter
- `FB_TcUnitRunner.RunTestSuiteTests(sTag)`: skip suites where `_sTag <> sTag` (empty sTag = run all)
- Suite body: `SetTag('sequencer')` in the constructor or first line

Benefits:
- Run subsets without recompiling — all suites stay compiled and debuggable
- Composable: `RUN(sTag := 'fast')` for quick smoke tests, `RUN()` for full suite
- Could support multiple tags with comma-delimited matching

Concerns:
- Adds API surface to FB_TestSuite
- Tag naming convention needs to be documented
- Suites without tags would always run (backward compat) or never run (breaking) — needs a clear default

**Option B: Named test groups in GVL**

Define groups in a GVL as arrays of suite pointers. The runner accepts a group reference. More structured but heavier.

**Option C: Leave to consumers**

Consumers use `ExcludeFromBuild` or separate PRG instances per task. No library changes.

### Decision #6 Context: Adaptive Cycle-Time Throttling

**Problem (2026-02-19):** Different PLCs and test projects have different cycle time budgets. A fixed throttle count (Decision #4) may be too aggressive on fast PLCs or too lenient on slow ones.

**Option A: Monitor PlcTaskSystemInfo.LastExecTime**

`FB_TcUnitRunner` reads `PlcTaskSystemInfo.LastExecTime` and `PlcTaskSystemInfo.CycleTime` each cycle. If `LastExecTime > CycleTime * threshold` (e.g., 80%), the runner skips calling suites for the remainder of this cycle and resumes next cycle.

Implementation sketch:
- `FB_TcUnitRunner` gets `_rCycleTimeThreshold : REAL := 0.8` (configurable)
- Before calling the next suite in the iteration, check: `IF LastExecTime > REAL_TO_UDINT(CycleTime * _rCycleTimeThreshold) THEN RETURN; END_IF`
- The runner remembers which suite it stopped at and resumes from there next cycle

Benefits:
- Self-regulating — works on any PLC without tuning
- Zero configuration needed (sensible default)
- Backward compatible — threshold of 1.0 disables it

Concerns:
- `PlcTaskSystemInfo.LastExecTime` reports the *previous* cycle's time, not the current one. This means the throttle reacts one cycle late. A sudden spike could still overrun once before throttling kicks in.
- Needs access to `PlcTaskSystemInfo` — requires the task's `ADSADDR` or `TcCOM` object ID. May need the caller to pass a reference or use `_TaskInfo` from the task configuration.
- Interaction with `RUN_IN_SEQUENCE` timer — the delay timer and adaptive throttle could conflict.

### Decision #7 Context: Staggered Suite Warm-Up

**Problem (2026-02-19):** All suites register via `FB_init` at PLC startup and the runner starts calling them all on cycle 1. With many heavy suites, the first few cycles see the largest spike — every suite's body runs for the first time, triggering initialization logic, variable allocation, and `InitializeHarness`-style setup.

**Option A: Init-phase in FB_TcUnitRunner**

Add a warm-up state to the runner's execution model. Before entering the main test execution loop, the runner calls one suite per cycle (or per N cycles) to let it complete first-time initialization. Once all suites have been called at least once, transition to normal execution.

Implementation sketch:
- `FB_TcUnitRunner` gets `_eRunPhase : (WarmUp, Execute, Complete)` and `_nWarmUpIndex : UINT`
- During `WarmUp`: call `TestSuiteAddresses[_nWarmUpIndex]^()` once per cycle, increment index
- When `_nWarmUpIndex > NumberOfInitializedTestSuites`, transition to `Execute`
- `Execute` phase is the existing `RunTestSuiteTests` / `RunTestSuiteTestsInSequence` logic

Benefits:
- Spreads the first-call spike across N cycles (where N = number of suites)
- No changes to suite code — transparent to consumers
- Backward compatible if warm-up is opt-in or has a bypass

Concerns:
- Adds latency before tests actually start executing — warm-up of 20 suites at 30ms/cycle = 600ms delay
- Suites may not separate "initialization" from "test execution" cleanly — warm-up calls would run test methods too, potentially finishing tests during warm-up
- Would need to either: (a) add a `WarmUp()` method to `FB_TestSuite` that only does init, or (b) accept that some tests may complete during warm-up

### Decision #8 Context: Per-Suite MaxTestsPerCycle Property

**Problem (2026-02-19):** Decision #4 proposes global throttling, but different suites have vastly different per-test costs. A lightweight `FB_PrimitiveTypes` suite (simple value assertions) can run 50 tests per cycle with no issue, while `FB_SequencerAssertTests` (behavioral mock harnesses with 20+ inline `CyclicLogic` calls per test) overruns at 5 tests. A global throttle would unnecessarily slow down lightweight suites.

**Option A: Per-suite property with windowed execution**

Add `MaxTestsPerCycle : UINT` as a property on `FB_TestSuite`. Each suite manages its own windowing — tracking which test methods have executed this cycle and deferring the rest.

Implementation sketch:
- `FB_TestSuite` gets `P_MaxTestsPerCycle : UINT` (default 0 = unlimited)
- `FB_TestSuite` gets `_nTestWindowStart : UINT` — the index of the first test to run this cycle
- The `TEST('name')` function checks: if this test's index is outside the current window, return FALSE (caller should `RETURN` early)
- After each suite call, `_nTestWindowStart` advances by `MaxTestsPerCycle`

Benefits:
- Heavy suites self-throttle, lightweight suites run at full speed
- Consumer controls the granularity — set it in the suite's constructor or body
- Composable with `RUN_IN_SEQUENCE` — sequential execution + per-suite throttling

Concerns:
- Requires `TEST()` to return a meaningful boolean — currently it always returns TRUE. Changing this is a behavioral change that could surprise existing consumers who ignore the return value.
- Multi-cycle tests (state machines) need to be called every cycle. If `TEST()` returns FALSE and the method returns early, the state machine stalls. Would need an exemption mechanism (e.g., `TEST_MULTI_CYCLE('name')` that always runs).
- The window tracking requires knowing the total test count upfront, or using a round-robin approach.

**Option B: Global-only throttling (Decision #4)**

Keep throttling at the runner level. Simpler but coarser.

### Decision #9 Context: Chunked Result Reporting

**Problem (2026-02-19):** After all tests complete, `FB_TestResults` aggregates results and `FB_AdsTestResultLogger` reports them to ADS. With many suites and tests, this end-of-run phase generates a burst of ADS messages and data copying that can cause a secondary cycle overrun — even after the test execution itself is done.

**Option A: Spread N results per cycle**

Modify `FB_TestResults` and `FB_AdsTestResultLogger` to process a limited number of test results per cycle rather than all at once.

Implementation sketch:
- `FB_TestResults.StoreTestResults()` already iterates through suites sequentially (`StoringTestSuiteResultNumber`). Change it to process at most N suites per cycle (currently it processes all in one cycle when triggered).
- `FB_AdsTestResultLogger` similarly limits the number of ADS messages sent per cycle. The existing `FB_AdsLogStringMessageFifoQueue` already buffers messages — ensure the drain rate respects cycle budget.

Benefits:
- Eliminates the end-of-run spike
- Backward compatible — results still get reported, just spread across more cycles
- Aligns with the existing `FB_AdsLogStringMessageFifoQueue` buffering pattern

Concerns:
- Adds latency between "all tests done" and "all results reported" — xUnit XML file may not be written until several cycles after completion
- External tooling (CI scripts, Visual Studio integration) that polls for completion may need to wait longer
- The `AreTestResultsAvailable()` flag would need to be deferred until all results are actually stored, not just when tests finish

**Option B: Leave as-is**

The existing `FB_AdsLogStringMessageFifoQueue` already provides some buffering. If the test execution phase is throttled (Decisions #4/#8), the number of results per run may be small enough that the burst is acceptable.

---

## Decided

Resolved decisions in numbered ADR (Architecture Decision Record) format. Never delete decided entries — they are the project's decision history.

### ADR-001: FB_TestSuite and FB_TcUnitRunner Extend FB_BaseStatic

**Date**: 2026-02-16 | **Status**: Decided

**Context**: TcUnit's test output was limited to ADS messages (253 char max, rate-limited) and xUnit XML. The Photara Base library provides structured logging to .db/.csv/.jsonl via TraceWithSeverity, which requires extending FB_BaseStatic.

**Options considered**:
1. Option 1 (FB_TestSuite extends FB_BaseStatic) — Direct inheritance gives every test suite TraceWithSeverity capability, mid-test tracing, and automatic instance path context.
2. Option 2 (New FB_BaseTestResultLogger implements I_TestResultLogger) — Pluggable logger that extends FB_BaseStatic; non-breaking but only captures summary results, not mid-test events.

**Decision**: Option 1 — both FB_TestSuite and FB_TcUnitRunner extend FB_BaseStatic directly.

**Rationale**: Since this is a local fork (not pushing upstream), breaking change concerns don't apply. Option 1 provides richer tracing (mid-test, per-assertion) vs Option 2's summary-only output. The Initialize() call is not required for TraceWithSeverity, keeping the integration lightweight.

**Consequences/gaps**: Consuming test projects must reference the Base library. The InstancePath type changed from T_MaxString to STRING (inherited). FB_BaseStatic adds memory overhead per test suite instance (BaseConfiguration, BaseStatus structs).

### ADR-002: Centralize Assert Failure Tracing in LogAssertFailure

**Date**: 2026-02-19 | **Status**: Decided

**Context**: Phase 3 initially added `_traceExpected`/`_traceActual` instance variables to FB_TestSuite, with 23 scalar Assert methods each setting these vars before calling `SetTestFailed()`, which read them for its `TraceWithSeverity` call. This was ~44 lines of boilerplate, didn't cover array assertions, and created an awkward instance-variable relay pattern.

**Options considered**:
1. Option 1 (Keep _traceExpected/_traceActual in SetTestFailed) — Current approach; works but requires every new Assert method to remember to set the vars, and doesn't cover arrays.
2. Option 2 (TraceWithSeverity in each Assert method directly) — Even more boilerplate; 40+ methods would each need a trace call.
3. Option 3 (TraceWithSeverity in LogAssertFailure on FB_AdsAssertMessageFormatter) — Single trace point; requires FB_AdsAssertMessageFormatter to extend FB_BaseStatic; automatically covers all assertion types including arrays.

**Decision**: Option 3 — `FB_AdsAssertMessageFormatter EXTENDS Base.FB_BaseStatic` with `TraceWithSeverity` in `LogAssertFailure`.

**Rationale**: Every Assert method already calls `LogAssertFailure(Expected, Actual, Message, TestInstancePath)` with string-converted values. Putting the trace there eliminates all per-method boilerplate and automatically covers array assertions. The `_traceExpected`/`_traceActual` pattern was an unnecessary indirection.

**Consequences/gaps**: FB_AdsAssertMessageFormatter now has a dependency on Base library. The `I_AssertMessageFormatter` interface doesn't mandate FB_BaseStatic — alternative implementations would need their own tracing strategy. Only failure traces are centralized; passing assertions are not traced (see Open Decision #3).

### ADR-003: Extend All 4 Remaining FBs with FB_BaseStatic

**Date**: 2026-02-19 | **Status**: Decided

**Context**: Four FBs (FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, FB_AdsTestResultLogger) had error conditions that were either ADS-only or completely silent. Phase 2 needed a decision on whether to extend all, some, or none with FB_BaseStatic.

**Options considered**:
1. Option A (Extend all 4) — Consistent pattern; every FB with error conditions gets structured logging. Simple, uniform.
2. Option B (Extend only those with error conditions) — All 4 have error conditions, so this is equivalent to Option A.
3. Option C (Leave as-is, use separate logger FB) — Avoids inheritance change but adds complexity and doesn't surface errors in structured logs.

**Decision**: Option A — Extend all 4 FBs with FB_BaseStatic.

**Rationale**: All 4 FBs have error conditions worth tracing. The pattern is proven (3 FBs already extended in Phase 1). The effort is minimal (EXTENDS + TraceWithSeverity calls). Existing ADS logging is unchanged (traces are additive). This brings the total to 7/7 core FBs with structured logging capability.

**Consequences/gaps**: All core TcUnit FBs now depend on the Base library. This is acceptable for a local fork. Memory overhead per FB instance is the same as Phase 1 (BaseConfiguration, BaseStatus structs from FB_BaseStatic).

---

## Guidelines

- **Capture early**: Add a decision to the Open table as soon as it's identified, even with no options listed. This flags that a choice is needed.
- **Record rationale always**: When moving a decision to Decided, the Rationale field is mandatory. Future agents need to understand *why*, not just *what*.
- **Never delete decided entries**: ADRs are permanent records. If a decision is reversed, add a new ADR that references and supersedes the old one.
- **Reference blocking phases**: If an open decision blocks a phase in EXECUTION_PLAN.md, note the phase in the "Decide By" column. This creates traceability between decisions and work.
- **Number ADRs sequentially**: ADR-001, ADR-002, ADR-003, etc. Never reuse numbers, even if an ADR is superseded.
- **Keep options concrete**: "Use X" is better than "consider alternatives." Each option should be specific enough to evaluate.
