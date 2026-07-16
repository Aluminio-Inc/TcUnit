# Multi-Task Tagged Test Execution — Design Spec

**Date**: 2026-07-16
**Status**: Approved (design); implementation not started
**Depends on**: Phase 4a/4b (timed-suite hardening + XAE verification) landing first
**Resolves**: OPEN_DECISIONS.md #5 (suite tagging); enables parallel suite execution across PLC tasks

---

## Problem

TcUnit today supports exactly one executing task. All runtime state lives in `GVL_TcUnit` as
single mutable globals (`TcUnitRunner`, `CurrentTestSuiteBeingCalled`, `CurrentTestNameBeingCalled`,
`CurrentTestIsFinished`, `IgnoreCurrentTest`, `GetCpuCounter`, `StartedAt`, `Duration`,
`AdsMessageQueue`), and the runner executes **every** registered suite body in whichever task calls
`RUN()` — suites cannot be pinned to a task, and two tasks calling `RUN()` concurrently would race
on the per-call context globals and corrupt results.

Consequences observed in consumers (TwinCAT_Tests): heavy behavioral suites overrun a single
TestTask's cycle budget, and there is no way to spread suite execution across CPU cores.

## Goals

1. Run disjoint sets of test suites concurrently on multiple PLC tasks (true core parallelism).
2. Selective execution by tag (`RUN(sTag := 'heavy')`) — usable single-task too (smoke vs. full).
3. Zero changes to test-author APIs: `TEST()`, `TEST_ORDERED()`, `TEST_FINISHED()`, all assertions,
   and `FB_TimedTestSuite` wait helpers are untouched from the test body's point of view.
4. Full backward compatibility: a single task calling plain `RUN()` behaves exactly as today, and
   the existing TcUnit-Verifier must stay green unchanged.

## Non-Goals

- Per-suite/per-cycle throttling (OPEN_DECISIONS #4/#8) — complementary, separate feature.
- Merged single xUnit file across tasks — per-task files chosen (decision below).
- Automatic task-affinity detection — suites are assigned to tasks explicitly via tags.
- Upstream contribution — this is fork-local.

---

## Design

### A. API surface

| Element | Change |
|---------|--------|
| `FB_TestSuite.SetTag(sTag : T_MaxString)` | **New** public method. Idempotent; called from the owning PRG each cycle (or once). Stores the trimmed tag on the suite. |
| `RUN(sTag : T_MaxString := '')` | **Extended** with optional input, default `''`. Empty tag = run all suites (today's behavior). |
| `RUN_IN_SEQUENCE(TimeBetween..., sTag : T_MaxString := '')` | Same optional input. |

Consumer usage:

```
// PRG_TESTS_HEAVY (runs on TestTaskHeavy)
SequencerSuite.SetTag('heavy');
WebDriveSuite.SetTag('heavy');
RUN(sTag := 'heavy');

// PRG_TESTS_FAST (runs on TestTaskFast)
PrimitiveSuite.SetTag('fast');
TimedSuite.SetTag('fast');
RUN(sTag := 'fast');
```

**Compat check required at implementation time**: verify TwinCAT accepts `RUN()` (no args) when
the FUNCTION gains a defaulted `VAR_INPUT`. If positional/formal call rules break any existing
call sites, fall back to keeping `RUN()`/`RUN_IN_SEQUENCE()` untouched and adding
`RUN_TAGGED(sTag)` / `RUN_IN_SEQUENCE_TAGGED(...)` instead. The rest of the design is unchanged
either way.

### B. Per-task state partitioning

New parameter in `GVL_Param_TcUnit` (parameter list — per-project override, no recompile):

```
MaxNumberOfTestTasks : UINT := 4;
```

`GVL_TcUnit` singletons become slot arrays `ARRAY[1..GVL_Param_TcUnit.MaxNumberOfTestTasks] OF ...`:

| Global (today) | After | Notes |
|----------------|-------|-------|
| `TcUnitRunner : FB_TcUnitRunner` | `TcUnitRunners : ARRAY[..] OF FB_TcUnitRunner` | Runner already contains `TestResults`, `AdsTestResultLogger`, `xUnitXmlPublisher` (FB_TcUnitRunner.TcPOU:12-25) — per-task results/logging comes along free. |
| `CurrentTestSuiteBeingCalled` | slot array | Per-call context used by free functions. |
| `CurrentTestNameBeingCalled` | slot array | 〃 |
| `CurrentTestIsFinished` | slot array | Written by `TEST()` (TEST.TcPOU:28) and 7 sites in `FB_TimedTestSuite`. |
| `IgnoreCurrentTest` | slot array | Read by every assertion guard in `FB_TestSuite`. |
| `GetCpuCounter : GETCPUCOUNTER` | slot array | A single `GETCPUCOUNTER` FB instance called from two tasks races its outputs — must be per-task. |
| `StartedAt`, `Duration` | move into `FB_TcUnitRunner` | Per-run state belongs on the (now per-task) runner, not in the GVL. |
| `AdsMessageQueue` | slot array | Per-task FIFO; `ADSLOGSTR` itself is service-side safe. |
| `TestSuiteAddresses[]`, `NumberOfInitializedTestSuites` | **unchanged** | Written only during single-threaded `FB_init` registration; read-only afterward — safe for concurrent readers. |
| `CurrentlyRunningOrderedTestInTestSuite[]` | **unchanged** | Indexed per-suite; each suite has exactly one owner task, so no cross-task sharing. |
| `TestSuiteIsRegistered` | **unchanged** | FB_init-time only. |

**Slot key**: `GETCURTASKINDEXEX()` (Tc2_System) — returns the caller's 1-based PLC task index,
callable from any POU including free functions. Guard: if index is 0 or
`> MaxNumberOfTestTasks`, trace Error (one-shot) and no-op the call. Implementation must verify
the returned index matches `_TaskInfo` indexing on TwinCAT 3.1.4026.

All `GVL_TcUnit.X` references in `FB_TcUnitRunner`, `FB_TestSuite`, `FB_TimedTestSuite`, and the
free functions (`TEST`, `TEST_ORDERED`, `TEST_FINISHED`, `TEST_FINISHED_NAMED`,
`IS_TEST_FINISHED`, `RUN`, `RUN_IN_SEQUENCE`) change to slot access resolved once per call
(~40-50 sites, mechanical). A small `F_GetTaskSlot : UINT` helper function centralizes the
`GETCURTASKINDEXEX()` call + range guard.

### C. Suite ownership (claiming)

New per-suite state on `FB_TestSuite`: `Tag : T_MaxString` (set by `SetTag`, trimmed) and
`OwnerTaskIndex : UINT := 0` (0 = unclaimed).

Runner iteration rule (both run modes):

1. Skip suites whose `Tag` does not match the runner's `sTag`. Empty runner tag matches **all** suites (backward compat).
2. Before first execution of a matching suite: if `OwnerTaskIndex = 0`, claim it (set to this task's slot).
3. If `OwnerTaskIndex` is nonzero and differs from this task: **skip** and trace Error one-shot:
   `'SUITE CLAIM CONFLICT: <suitepath> owned by task N, attempted by task M'`.

This makes misconfiguration (two tasks with the same tag; plain `RUN()` alongside tagged runs)
loud instead of silently double-running. Startup ordering is inherently safe: a suite that has not
yet been tagged (its PRG hasn't cycled) matches no tagged runner, and gets picked up once tagged.

**Documented multi-task usage rule**: every concurrently-running task uses a distinct non-empty
tag, and every suite is tagged. Plain `RUN()` remains valid only in single-task projects.

Completion semantics per runner: a runner's "all test suites finished" check counts suites it has
claimed plus matching-but-unclaimed suites (still pending pickup). Suites skipped due to a claim
conflict belong to another runner and are excluded. A runner whose tag matches zero suites
completes immediately with the existing empty-run trace path.

### D. Results and reporting

- **Per-suite assert state is already isolated**: `AssertResults`, `AssertArrayResults`,
  `AdsAssertMessageFormatter` are per-suite instances (FB_TestSuite.TcPOU:32-38). Single ownership
  ⇒ no cross-task contention.
- **Run lifecycle traces**: each runner's `TEST RUN STARTED / COMPLETED` messages include its tag,
  e.g. `TEST RUN STARTED [heavy] - 3 suite(s), parallel execution`.
- **xUnit XML — per-task files** (decided): when the runner's tag is non-empty, derive the
  filename from `GVL_Param_TcUnit.xUnitFilePath` by inserting `_<tag>` before the extension
  (`tcunit_xunit_testresults_heavy.xml`). Empty tag keeps the configured path verbatim —
  single-task output is byte-identical to today. Downstream tooling globs
  `tcunit_xunit_testresults*.xml` and merges.
- **ADS/VS error list**: per-task `AdsMessageQueue` instances drain independently; interleaving in
  the error list is acceptable (each line already carries suite/test identity).

### E. Cross-library prerequisite (rollout gate)

Seven TcUnit FBs call `Base.TraceWithSeverity`, which writes the TwinCATBase ring buffer. With
two or more test tasks tracing concurrently (plus LogTask draining), the ring buffer must be
**verified multi-writer safe** in TwinCATBase before this feature is used in production. That
audit belongs to the TwinCATBase repo; it gates enabling multi-task runs, not merging this
feature. If the buffer is not multi-writer safe, mitigation options: fix in Base (preferred) or
serialize TcUnit traces through the per-task ADS queue only.

### F. Backward compatibility and verification

Compatibility contract:

- Single task + plain `RUN()`: slot 1, empty tag matches all, claims never conflict — behavior
  identical to today (including xUnit filename).
- No test-author API changes; no assertion changes; `GVL_Param` additions only (additive).
- Memory: `MaxNumberOfTestTasks` (default 4) multiplies runner + queue footprint. The ADS FIFO is
  the dominant term (~1 MB each at default ring size) — document that consumers with one test task
  can set `MaxNumberOfTestTasks := 1` in their `.plcproj` to keep today's footprint. Consider
  default 2 if 4x proves heavy.

Verification plan (TDD — every new behavior proven red first):

1. **Existing TcUnit-Verifier stays green unchanged** — the compat proof.
2. **Level 1 (consumer, two tasks)**: two TestTasks + two tagged PRGs; verify each runner's
   pass/fail counts, per-task xUnit files, and no cross-contamination of test names/durations.
3. **Negative controls**: (a) same tag on two tasks ⇒ claim-conflict Error trace fires, suite runs
   exactly once; (b) `GETCURTASKINDEXEX` slot-overflow guard ⇒ Error trace, no state corruption.
   Prove each red by temporarily disabling the guard under test.
4. **Regression for decision #5 single-task use**: `RUN(sTag := 'smoke')` runs only tagged subset;
   untagged suites idle (not failed, not reported).

## Implementation order

1. `F_GetTaskSlot` helper + `MaxNumberOfTestTasks` param + slot arrays in `GVL_TcUnit` (compiles, single-task still green).
2. Free functions + `FB_TestSuite` + `FB_TimedTestSuite` slot access.
3. `SetTag` + claim logic + tagged runner iteration + `RUN`/`RUN_IN_SEQUENCE` params.
4. Per-task xUnit filename derivation.
5. Verifier run (unchanged, green) → version bump/recompile → Level 1 two-task tests in consumer.

Every new method/property/function gets a fresh randomized GUID (project rule).

## Risks / open items

| Risk | Handling |
|------|----------|
| Defaulted `VAR_INPUT` on existing FUNCTIONs breaks some call styles | Compile-check early; fallback to `RUN_TAGGED` variants (Section A). |
| `GETCURTASKINDEXEX()` index semantics differ on 4026 | Verify against `_TaskInfo` in step 1 before depending on it. |
| Base ring buffer not multi-writer safe | Rollout gate (Section E); audit in TwinCATBase first. |
| Memory growth from slot arrays | `MaxNumberOfTestTasks` is a GPL parameter; consumers tune per-project. |
| Runner completion/statistics logic assumes "all registered suites" | Rework counts to "matching suites" carefully in both duplicated run methods (BREADCRUMBS #4: near-identical code blocks — edit with method-specific context). |
