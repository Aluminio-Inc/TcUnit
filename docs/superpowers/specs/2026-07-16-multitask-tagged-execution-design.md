# Multi-Task Tagged Test Execution — Revised Design Spec

**Date**: 2026-07-16
**Revision**: 3
**Status**: Revised per implementation-readiness review; awaiting approval; implementation not started
**Depends on**: Phase 4a/4b (timed-suite hardening and XAE verification), sequential-runner regression coverage, and the TwinCATBase multi-writer audit
**Decisions**: ADR-004 chooses tagged selective execution plus multi-task support; ADR-005 refines task registration, ownership, synchronization, result storage, and reporting
**Target**: TwinCAT 3.1.4026.x, with the exact supported build floor recorded after the compile spike

---

## Executive summary

TcUnit will support one or more PLC test tasks without allowing those tasks to share mutable test
execution state. Test suites continue to register globally during `FB_init`, but configuration and
execution become separate phases:

1. Each owning test PRG calls `SetTag()` before its first `RUN*()` call. The call records both the
   suite's normalized tag and the raw PLC task index of the caller.
2. Each test task registers once with a global coordinator. Registrations are collected keyed by
   raw PLC task index.
3. When every expected test task has registered, the coordinator briefly freezes registration,
   builds and validates immutable per-task execution plans outside the critical section, assigns
   deterministic compact task slots (positive raw indices sorted ascending), and publishes the
   sealed plan generation. The lowest raw task index becomes the report coordinator.
4. Every runner observes the published plan generation through the coordinator and acknowledges
   it. The report coordinator then performs output preflight (fresh `RunId`, exact stale-output
   invalidation), starts the aggregate clock, and opens the synchronized execution gate.
5. After the gate opens, each test task touches only its own task context, suites, CPU counter,
   and ADS queue. No lock is taken in the test execution path.
6. Each task publishes a one-shot quiescence record through the coordinator after its final
   suite-state write. The report coordinator reads suite state only from quiesced tasks.
7. When all tasks are quiesced (or the reporter-clock execution deadline expires), the report
   coordinator streams deterministic per-task xUnit shards and finally an authoritative manifest
   carrying the run's `RunId`, `publicationComplete`, and `outcome`.

Configuration and infrastructure errors fail closed. They are exposed as machine-readable run
status and, when xUnit output is enabled, as a synthetic failed framework testcase. A configuration
error can never produce a green empty run.

The feature is opt-in for multi-task consumers. Defaults retain one task context and therefore do
not multiply the current memory footprint.

---

## Problem

TcUnit currently supports exactly one executing task. Mutable execution state lives in
`GVL_TcUnit` as singletons (`TcUnitRunner`, current suite/test context, ignore/finished flags,
`GETCPUCOUNTER`, run timing, and the ADS queue). The runner also assumes every registered suite
belongs to it, and the result and logging pipeline iterates the complete global registry.

Calling `RUN()` from two PLC tasks can therefore:

- overwrite the current suite and current test name while another task is asserting;
- route assertion or completion state to the wrong test;
- call a stateful function block instance from multiple task contexts;
- corrupt the ADS ring buffer or structured trace ring buffer;
- execute the same suite twice;
- publish incomplete, conflicting, or overwritten xUnit output.

Consumers also need selective execution without recompiling and a way to distribute suites across
configured PLC cores. Splitting suites between tasks reduces the load per test task, although it
does not solve a single suite or single test method that individually exceeds its task budget.

---

## Design principles and quality order

The implementation follows these principles, in order:

1. **Correct attribution** — an assertion, finish call, duration, and log entry must belong to the
   exact suite/test that caused it.
2. **Exactly-once suite execution** — a suite is present in no more than one immutable execution
   plan per PLC activation.
3. **Fail closed** — invalid topology, capacity overflow, reporting failure, and framework misuse
   cannot be represented as a successful empty test run.
4. **Determinism** — registry order, test identity, tag normalization, output names, counts, and
   completion semantics are stable across runs.
5. **Real-time boundedness** — synchronization is confined to configuration and one-shot state
   transitions; no mutex is taken while test bodies are executing.
6. **Machine-readable truth** — PLC run status and the xUnit manifest are authoritative. ADS and
   structured traces are diagnostic views, not the only completion signal.
7. **Backward compatibility** — single-task plain `RUN()` preserves existing test-body behavior,
   file location, and source call sites.
8. **Bounded memory** — adding task contexts must not replicate the current full 1000-by-100 test
   result snapshot for every task.
9. **Diagnosability** — all framework errors have stable codes and identify task, slot, tag, suite,
   phase, and output shard where applicable.

---

## Goals

1. Run disjoint, explicitly owned sets of suites concurrently from multiple PLC tasks.
2. Support selective execution by tag in single-task and multi-task projects.
3. Preserve all test-body APIs: `TEST`, `TEST_ORDERED`, `TEST_FINISHED`, assertions, and timed-suite
   wait helpers.
4. Preserve plain single-task `RUN()` behavior without requiring suites to be tagged.
5. Make every invalid configuration produce a deterministic failed infrastructure result.
6. Publish correct per-task xUnit shards and an authoritative completion manifest.
7. Expose stable run status for verifier and automation clients without scraping the Visual Studio
   Error List.
8. Verify task isolation, exact-once execution, reporting, memory, cycle time, and true core
   placement with committed tests.

## Non-goals

- Per-test/per-cycle execution throttling (OPEN_DECISIONS #4/#8).
- Adaptive execution throttling based on previous-cycle time (OPEN_DECISIONS #6).
- Running a second independent test selection without a PLC reset or explicit future reset API.
- Multiple labels on one suite in this revision; each suite has one normalized execution tag.
- A single merged xUnit document generated inside the PLC. The manifest describes shards for an
  external merger.
- Automatically assigning a PLC task or CPU core. Ownership is captured from the PRG that calls
  `SetTag`; core placement remains a TwinCAT configuration responsibility.
- Making an individually over-budget suite or test method real-time safe. Distributing suites is
  complementary to throttling.
- Synchronizing consumer-owned function blocks, global mocks, hardware, files, or I/O that are
  shared by tests. TcUnit isolates its own state; test authors must partition or synchronize the
  system under test.

---

## Definitions

| Term | Definition |
|---|---|
| Raw task index | The `DINT` returned by `GETCURTASKINDEXEX()`: `-1`, `0`, or the sparse 1-based PLC task index. |
| Task slot | A compact TcUnit index in `1..MaxNumberOfTestTasks`, assigned to a unique positive raw task index. |
| Suite registry index | The stable 1-based position assigned by `FB_TestSuite.FB_init`. |
| Owner task | The raw task index captured by the suite's first valid `SetTag()` call, or assigned to the sole legacy runner during sealing. |
| Execution tag | A normalized, filename-safe suite selection label. Empty is reserved for legacy run-all mode. |
| Execution plan | The immutable registry-index list selected for one task slot, in global registration order. |
| Shard | One JUnit-style XML document containing the suites in one task's execution plan. |
| Infrastructure failure | A TcUnit configuration, runtime, capacity, synchronization, or reporting error—not a user assertion failure. |
| Plan generation | The one-shot sealed configuration published by the coordinator; runners acknowledge it before execution. |
| Execution gate | The synchronized one-shot signal, opened by the report coordinator after preflight, that allows runners to begin executing their plans. |
| Quiescence | A task's one-shot coordinator record, published after its final suite-state write, stating it will write no further test state this run. |
| Report coordinator | The task on the lowest positive raw task index; owns preflight, the execution gate, the aggregate clock, shard publication, and the manifest. |
| RunId | An opaque identifier generated once per activation/run; published in PLC status before the gate opens and embedded in every shard and the manifest. |

Beckhoff documents `GETCURTASKINDEXEX()` as returning `-1` in Windows context, `0` in non-cyclic
real-time context (including automatic `FB_init`), and `1..n` in a cyclic PLC task. The returned
positive value indexes `TwinCAT_SystemInfoVarList._TaskInfo[]`; it is not a compact count of TcUnit
test tasks.

---

## Public API

### Test-suite assignment

```iecst
METHOD PUBLIC SetTag
VAR_INPUT
    sTag : T_MaxString;
END_VAR
```

Contract:

- The caller must invoke `SetTag()` from the PRG/task that owns the suite.
- It must occur before that task's first `RUN*()` call.
- The first valid call registers the normalized tag and the caller's positive raw task index with
  the coordinator.
- Repeating the same normalized tag from the same raw task is a no-op with no shared string write.
- A different tag, different caller task, invalid context, or post-seal mutation is an
  infrastructure configuration failure.
- The suite does not perform an unsynchronized runtime owner claim.

### Runner entry points

Preferred source-compatible signatures, subject to an early XAE compile check:

```iecst
FUNCTION RUN
VAR_INPUT
    sTag : T_MaxString := '';
END_VAR

FUNCTION RUN_IN_SEQUENCE
VAR_INPUT
    sTag : T_MaxString := '';
END_VAR
```

`RUN_IN_SEQUENCE` continues to obtain its delay from
`GVL_Param_TcUnit.TimeBetweenTestSuitesExecution`; it does not add a positional time input.

If adding a defaulted input breaks any supported source call form or compiled-library behavior,
keep the existing functions unchanged and add:

```iecst
RUN_TAGGED(sTag)
RUN_IN_SEQUENCE_TAGGED(sTag)
```

The fallback decision is made in the compile spike before broad implementation. All Photara
consumer repositories must be searched and compiled against the chosen API.

Runner registration contract:

- A raw PLC task registers at most one runner per activation.
- The first call latches normalized tag and run mode (`Parallel` or `Sequential`).
- Subsequent cyclic calls must use the identical tag and mode.
- Changing tag or mode, or calling two runner entry points from the same raw task, is a
  configuration failure.

### Machine-readable status

The public status ABI is a versioned, symbol-readable GVL (`GVL_TcUnitStatus`) — not getter
functions. ADS clients read structures containing strings, counters, and `LREAL` values, so a raw
read can observe a torn update. Every externally published structure therefore uses a
sequence-validated snapshot protocol: the writer increments `StatusSequence` to an odd value,
writes the snapshot, then increments to the next even value; the reader copies the structure,
re-reads the sequence, and retries on mismatch or odd value. (A double-buffered published
generation is an acceptable equivalent; the compile spike picks one and the choice is frozen.)

All published enums (`E_TcUnitRunMode`, `E_TcUnitRunPhase`, `E_TcUnitErrorCode`) carry explicit
stable numeric values, frozen at first release. New values may be appended; existing values never
change meaning.

Status is split by owner. Task-owned execution status is written only by the owning task;
publication status is written only by the report coordinator. `ShardPublished`/`ShardPath` are
deliberately not task-owned fields.

```iecst
TYPE ST_TcUnitAggregateStatus :
STRUCT
    StatusSchemaVersion     : UINT;            // constant per library release
    StatusSequence          : UDINT;           // seqlock: even = consistent
    RunId                   : STRING(32);      // fresh per activation, before gate opens
    Phase                   : E_TcUnitRunPhase;
    PrimaryErrorCode        : E_TcUnitErrorCode;
    FirstErrorPhase         : E_TcUnitRunPhase;
    ErrorCount              : UDINT;
    ExpectedTasks           : UINT;
    RegisteredTasks         : UINT;
    AcknowledgedTasks       : UINT;
    QuiescedTasks           : UINT;
    DiscoveredSuites        : UDINT;           // all registered suites
    SelectedSuites          : UDINT;           // in some execution plan
    ExcludedSuites          : UDINT;           // discovered - selected
    TotalTests              : UDINT;
    PassedTests             : UDINT;
    FailedTests             : UDINT;
    SkippedTests            : UDINT;
    ExecutionDurationSec    : LREAL;           // seconds, reporter clock, gate-open → last quiescence
    ReportingDurationSec    : LREAL;           // seconds
    OutputEnabled           : BOOL;            // xUnitEnablePublish at seal
    PublishedShards         : UINT;
    PublicationComplete     : BOOL;
    ManifestPublished       : BOOL;
END_STRUCT
END_TYPE

TYPE ST_TcUnitTaskExecutionStatus :   // written only by the owning task
STRUCT
    Slot                    : UINT;
    RawTaskIndex            : DINT;
    CpuCoreIndex            : DINT;
    Tag                     : STRING(32);
    RunMode                 : E_TcUnitRunMode;
    RunnerState             : E_TcUnitRunnerState;
    PrimaryErrorCode        : E_TcUnitErrorCode;
    SelectedSuites          : UDINT;
    FinishedSuites          : UDINT;
    TotalTests              : UDINT;
    PassedTests             : UDINT;
    FailedTests             : UDINT;
    SkippedTests            : UDINT;
    ExecutionDurationSec    : LREAL;           // seconds, task-local clock
    Quiesced                : BOOL;
    QuiescedAfterTimeout    : BOOL;            // TimedOutAndQuiesced
END_STRUCT
END_TYPE

TYPE ST_TcUnitTaskPublicationStatus : // written only by the report coordinator
STRUCT
    ShardPublished          : BOOL;
    ShardOutcome            : E_TcUnitShardOutcome;  // Published, WithheldUnresponsive, WithheldError, Disabled
    ShardPath               : T_MaxString;
END_STRUCT
END_TYPE
```

A single error-code enum with `PrimaryErrorCode`, `FirstErrorPhase`, and `ErrorCount` replaces the
earlier `ConfigurationError` + `InfrastructureFailed : BOOL` pair, which could not represent the
runtime and reporting error codes listed in the failure model. All duration fields are explicitly
seconds. The .NET verifier reads this GVL by symbol name and must not infer completion by scraping
ADS text.

---

## Tag semantics

Tags are normalized once during registration:

1. Trim leading and trailing whitespace.
2. Convert ASCII letters to lowercase.
3. Require `1..32` characters for tagged mode.
4. Permit only `[a-z0-9][a-z0-9_-]*`.

Empty is reserved for plain legacy run-all mode. Invalid, truncated, or empty-after-normalization
tags fail configuration. Tags are stored as `STRING(32)`, not `T_MaxString`, after validation.

Tag matching is exact after normalization. This deliberately avoids locale, case, delimiter,
path, and truncation ambiguity.

Two tasks may use the same selection tag because ownership is independent and output filenames
also contain raw task identity. This permits a selection such as `smoke` to span task partitions.
The same suite still has exactly one owner and appears in exactly one plan.

This revision supports one tag per suite. Multi-label selection is a future additive feature and
must not be simulated with comma-delimited strings.

---

## Configuration modes

| Mode | Conditions | Selection and validation |
|---|---|---|
| Legacy run-all | `ExpectedNumberOfTestTasks = 1`, runner tag empty, **zero suites called `SetTag()`** | All registered suites are assigned to and executed by the sole runner. |
| Single-task selective | `ExpectedNumberOfTestTasks = 1`, runner tag non-empty | Execute suites owned by the caller whose tag matches. Untagged and nonmatching suites are intentionally excluded and recorded as such. Zero selected suites is a configuration failure. |
| Multi-task | `ExpectedNumberOfTestTasks > 1`, every runner tag non-empty | Every registered suite must have one valid owner and must match the tag latched by a runner on that owner task. Every runner must select at least one suite. |

Plain legacy `RUN()` is valid **only when no suite in the project has called `SetTag()`**. Any
`SetTag()` call combined with a plain empty-tag runner — in any task count — is
`MixedLegacyAndMultiTaskMode`. A legacy runner never silently absorbs or overrides a captured
owner. Plain `RUN()` is likewise invalid when more than one test task is expected. All mixed
topologies are rejected at seal, before any suite body executes.

### Selection truth table

Behavior of every suite state in every mode ("owner" is the raw task captured by `SetTag()`;
"runner" is the task evaluating the row):

| Suite state | Legacy run-all | Single-task selective | Multi-task |
|---|---|---|---|
| Untagged (never called `SetTag()`) | Selected | Excluded (reason `Untagged`) | Configuration failure `UnownedSuite` |
| Tagged, owner = runner task, tag matches runner | Configuration failure `MixedLegacyAndMultiTaskMode` | Selected | Selected |
| Tagged, owner = runner task, tag does not match runner | Configuration failure `MixedLegacyAndMultiTaskMode` | Excluded (reason `TagMismatch`) | Configuration failure `SuiteTagDoesNotMatchOwnerRunner` |
| Tagged, owner is a different task, tag matches this runner | Configuration failure `MixedLegacyAndMultiTaskMode` | Configuration failure `SuiteWithoutRunner` (no runner on the owner task) | Selected by the owner's runner if the tag also matches there — never by this runner; otherwise configuration failure `SuiteTagDoesNotMatchOwnerRunner` |
| Tagged, owner is a different task, tag matches no runner | Configuration failure `MixedLegacyAndMultiTaskMode` | Configuration failure `SuiteWithoutRunner` | Configuration failure: `SuiteWithoutRunner` if the owner task has no runner, else `SuiteTagDoesNotMatchOwnerRunner` |

Single-task selective mode is intentional partial selection: same-owner suites with a nonmatching
tag are deliberate exclusions (reason `TagMismatch`), not errors. Multi-task mode is fail-closed
total coverage: every registered suite must be owned, matched, and planned, so the same condition
is a configuration failure there. Exclusions are recorded per suite with a reason code and
surfaced as counts plus a per-suite list in the manifest; excluded suites are never merely
omitted.

### Empty-run semantics

These four conditions are distinct and separately reported:

1. **Zero suites selected** — a tagged or multi-task runner whose plan is empty:
   configuration failure `RunnerHasNoSuites`.
2. **A selected suite contains zero tests** — the suite executes, finishes with zero tests, and is
   reported with zero counts (existing empty-suite trace retained). Not itself a failure.
3. **An aggregate run executes zero tests** — tagged and multi-task runs fail with
   `ZeroTestsExecuted`. Legacy run-all keeps its current behavior by default; the parameter
   `FailOnZeroTests : BOOL := FALSE` opts legacy mode into the same rule.
4. **Intentionally excluded suites** — recorded with exclusion reasons (`Untagged`, `TagMismatch`)
   in status counts and the manifest; excluded suites are not executed and not counted as skipped
   tests.

No combination of these may produce a green run for a tagged or multi-task configuration that
executed nothing.

### Consumer concurrency contract

Moving suites from one PLC task to several changes their scheduling semantics: suites in different
plans can now execute truly concurrently. TcUnit guarantees its own state isolation, not isolation
of the function blocks, globals, files, hardware, mocks, or I/O exercised by those suites.

Suites that share mutable system-under-test state must either:

- remain on the same owner task;
- use separate SUT instances/resources; or
- use an application-appropriate synchronization/data-exchange mechanism whose cycle-time impact is
  understood.

The migration guide must call this out explicitly. Representative consumer qualification includes
an audit for globals and FB instances accessed from more than one new test-task plan.

---

## Runtime architecture

### A. Global suite registration remains initialization-only

`FB_TestSuite.FB_init` continues to append `THIS` to `TestSuiteAddresses[]` and increment
`NumberOfInitializedTestSuites`. Registration happens before cyclic test execution. Add an explicit
capacity check so exceeding `MaxNumberOfTestSuites` becomes an infrastructure failure rather than
an out-of-bounds write.

After PLC initialization and before configuration sealing:

- registry indices and pointers are stable;
- no runner executes a suite;
- online-change behavior is handled as a new activation/reconfiguration boundary, described below.

### B. Global coordinator

Add one `FB_TcUnitCoordinator` instance responsible for configuration and one-shot cross-task state
transitions. It owns:

- a short critical-section primitive;
- coordinator phase (`Open`, `Sealing`, `SealedValid`, `SealedInvalid`, `AwaitingAcknowledgement`,
  `Preflight`, `Executing`, `Reporting`, `Complete` — explicitly numbered, frozen at release);
- registration records collected keyed by raw task index;
- raw-task-to-slot mappings (final, assigned deterministically at seal);
- latched runner registration records;
- suite assignment records keyed by registry index;
- the published plan generation and per-task acknowledgement records;
- immutable execution plans;
- the execution gate;
- per-task quiescence and reporting records;
- aggregate infrastructure status and stable error codes;
- report coordinator election (the task with the lowest positive raw index, i.e. slot 1);
- authoritative manifest state.

The coordinator's shared mutation methods are synchronized, and the critical section is kept
short by construction. The lock is entered only for:

- first suite registration (`SetTag`) and first runner registration;
- freezing registration at the start of sealing;
- publishing the finished plan generation at the end of sealing;
- one-shot plan acknowledgement per task;
- one-shot execution-gate open;
- one-shot quiescence publication per task;
- one-shot shard/manifest publication completion;
- one-shot infrastructure failure publication.

Two categories of work are explicitly kept **outside** the lock:

1. **Cyclic idempotency.** Repeated `SetTag()` and repeated cyclic `RUN*()` calls first check the
   caller's task-local latched state; a call that changes nothing returns without touching the
   coordinator. Only a first-time registration or an observed conflict enters the lock.
2. **Plan construction and validation.** Sealing is three steps: (a) briefly freeze registration
   under the lock and transition to `Sealing`; (b) construct and validate all plans incrementally
   from the frozen registration records, outside the lock, bounded per scan — no other task may
   mutate the frozen records, so no protection is needed; (c) briefly publish the finished plan
   generation and final slot assignments under the lock (`SealedValid`/`SealedInvalid`). Scanning
   up to 1,000 suites never happens inside a cross-task critical section.

No coordinator lock is entered from `TEST`, assertions, wait helpers, suite bodies, or the normal
per-cycle runner loop after the execution gate opens. Pre-gate polling (waiting for seal,
acknowledgement, or gate-open) may take the lock once per scan because no test body is executing
yet; the post-gate execution path takes it exactly once more — to publish quiescence.

If a non-blocking `TestAndSet()` implementation is used, a failed acquisition defers registration
or completion publication until the next scan. If `FB_IecCriticalSection` is used, the protected
region must contain no loops over tests, no string formatting beyond bounded registration data, no
logging, and no file/ADS access.

### C. Compact task-slot mapping

`MaxNumberOfTestTasks` is a capacity, not a raw PLC task index limit.

Slot assignment is deterministic and independent of registration order. Which task happens to
register first depends on scheduling and must not change the report coordinator, manifest
ordering, or the status array between boots.

On first runner registration:

1. Call `GETCURTASKINDEXEX()` into a `DINT`.
2. Reject `<= 0` before any unsigned conversion.
3. Record the registration keyed by raw task index. Any first-come registration index used while
   collecting is internal and transient — it is never exposed and never becomes the slot.
4. Fail configuration if more unique raw indices register than `MaxNumberOfTestTasks`.

At seal:

1. Sort the registered positive raw task indices ascending.
2. Assign final compact slots `1..N` in that sorted order.
3. Elect the task with the lowest raw index (slot 1) as the report coordinator.

Examples:

```text
Raw PLC tasks: Main=1, Log=2, Motion=3, TestFast=5, TestHeavy=8
TcUnit mapping (regardless of which registered first):
  TestFast raw 5 → slot 1 (report coordinator); TestHeavy raw 8 → slot 2
```

`F_ResolveTaskSlot` performs a bounded lookup over the configured mappings and returns both
`bValid` and `nSlot`. Callers must branch on validity before indexing. Invalid context has explicit
safe return behavior:

- `RUN*`: no suite execution; publish configuration failure where possible.
- `TEST_ORDERED`, `TEST_FINISHED`, `IS_TEST_FINISHED`: return `FALSE`.
- assertion and timed helper methods: no-op and mark framework misuse if an active task context
  exists.
- diagnostic logging: use a bounded coordinator diagnostic path that does not require indexing an
  invalid task slot.

### D. Per-task context

Replace parallel singleton arrays with one cohesive task-context array:

```text
GVL_TcUnit.TaskContexts[1..MaxNumberOfTestTasks]
```

Each context contains only task-owned mutable state:

- runner execution state and persistent selected-suite cursor;
- current suite pointer and current test name;
- current-test finished and ignore flags;
- per-task `GETCPUCOUNTER` instance and run timing;
- per-task ADS FIFO;
- latched raw task index, normalized tag, run mode, and core index;
- immutable selected suite registry indices and selected count;
- per-task execution summary/status (`ST_TcUnitTaskExecutionStatus`) and one-shot diagnostic flags,
  including the quiescence latch.

Publication state (`ST_TcUnitTaskPublicationStatus`) is owned by the report coordinator, not the
task context. The full `ST_TestSuiteResults` snapshot and xUnit publisher buffer are deliberately
not duplicated inside every task context.

### E. Immutable execution plans and the publication barrier

When the expected runner count has registered, the sealing task freezes registration (under the
lock), builds each plan outside the lock by scanning the global suite registry in registration
order and appending suites that belong to that raw task and match that runner tag, verifies the
invariants below, and publishes the finished plan generation (under the lock).

After `SealedValid`:

- task mappings, runner registrations, suite owner/tag records, and execution plans never change;
- each suite registry index appears in at most one plan;
- no runner scans mutable tag strings;
- no runner calls a suite owned by another task;
- plan order is deterministic and preserves global registration order.

Declaring the plans "immutable" does not by itself guarantee that another CPU core observes every
plan write. Cross-core visibility is guaranteed by two explicit synchronized handoffs; all
cross-task ordering claims in this document reduce to them:

1. **Plan barrier (config → execution).** Plan writes complete before the plan generation is
   published under the coordinator lock. Each runner observes the published generation through the
   same primitive, resolves its own plan reference, and acknowledges (one-shot, under the lock).
   The execution gate cannot open until every expected runner has acknowledged, so every runner's
   plan reads happen strictly after the sealing task's plan writes, ordered by the lock.
2. **Quiescence barrier (execution → reporting).** A task publishes its quiescence record (under
   the lock) only after its final suite-state write. The report coordinator observes all
   quiescence records through the same primitive before reading any suite instance, so its reads
   of suite/test state happen strictly after every owning task's writes.

Between the two barriers, no synchronization is needed inside tests, assertions, or suite bodies:
each task writes only state it exclusively owns.

### F. Timeouts and the stopped-task model

Add parameters:

```iecst
MaxNumberOfTestTasks      : UINT := 1;
ExpectedNumberOfTestTasks : UINT := 1;
TaskRegistrationTimeout   : TIME := T#5S;   // also bounds plan acknowledgement
TaskExecutionTimeout      : TIME := T#0S;   // per-task self-limit; 0 = unlimited
GlobalExecutionTimeout    : TIME := T#0S;   // reporter-clock deadline; 0 = unlimited
ReportingTimeout          : TIME := T#30S;
FailOnZeroTests           : BOOL := FALSE;  // legacy mode only; tagged modes always fail
```

Validate at compile/startup that
`1 <= ExpectedNumberOfTestTasks <= MaxNumberOfTestTasks`.

**Registration and acknowledgement.** Each registered runner starts a task-local configuration
wait timer. If the expected number of unique test tasks does not register before the timeout, the
first runner able to enter the coordinator publishes `TaskRegistrationTimeout` and seals the run
invalid. After seal, plan acknowledgement must complete within the same window measured by the
report coordinator; expiry publishes `PlanAcknowledgementTimeout`. Both convert a stopped,
missing, or misconfigured task into a failed result rather than an infinite wait.

**Two distinct timeout mechanisms cover execution.** A task that is genuinely stopped cannot
evaluate its own timer, so a self-check alone cannot detect it:

- `TaskExecutionTimeout` is a task-local self-limit evaluated on the task's own clock. Expiry
  stops that task's further suite execution, marks `TaskExecutionTimeout` on the task, and the
  task **still publishes quiescence**. Its status reads `QuiescedAfterTimeout = TRUE`
  (*TimedOutAndQuiesced*). Its completed suite state is safe for the reporter to read.
- `GlobalExecutionTimeout` is evaluated by the report coordinator on its own clock, from gate-open
  until all quiescence records are observed. Expiry marks every task that has not quiesced as
  **Unresponsive** (`TaskUnresponsive`) and moves the run to reporting.

**The reporter never traverses suite state belonging to an unquiesced task.** Without the
quiescence barrier there is no ordering guarantee on that state. For an unresponsive task the
reporter publishes only a synthetic infrastructure result (shard outcome `WithheldUnresponsive`)
— never a partial user-test shard. `ReportingTimeout` separately prevents the file/report state
machine from hanging automation indefinitely.

**Cases no PLC-side timer can cover.** If the report coordinator's own task stops, or no runner
ever starts, no PLC code is running to publish failure. The .NET verifier and CI automation must
run an external watchdog: absence of the expected fresh `RunId`/manifest within the harness
deadline is a failed run. This is part of the completion contract, not an optional nicety.

**Recovery.** After a run has been failed with an unresponsive task, restarting that task must not
let it resume executing its stale plan into a completed run. The coordinator's phase gates this: a
late task observing `Reporting`/`Complete` (or a generation mismatch) parks in a failed state. A
PLC reset is required before another run.

### G. Runner state machine

Each task runner uses an explicit persistent state machine:

```text
Unregistered
  → WaitingForConfiguration     (registration collected; awaiting seal)
  → AcknowledgingPlan           (observed plan generation; acknowledge one-shot)
  → WaitingForGate              (acknowledged; awaiting execution-gate open)
  → Executing
  → Quiescing                   (final suite-state write done; publish quiescence one-shot)
  → WaitingForGlobalReport
  → Complete

Any pre-execution failure:
  → ConfigurationFailed
  → WaitingForGlobalReport
  → Complete
```

Do not infer lifecycle from local method variables. State that must survive scans is declared on the
runner/context or as `VAR_INST`.

Parallel mode iterates the immutable plan each scan, calling each unfinished suite. Sequential mode
maintains a persistent plan cursor and delay timer. It advances over selected suites only and
applies `TimeBetweenTestSuitesExecution` only between selected suites.

Completion counts only plan entries. Nonmatching and unowned suites are never consulted during
execution. The runner publishes quiescence exactly once through the coordinator — after its final
suite-state write, whether execution finished normally or stopped on `TaskExecutionTimeout` or a
task-scoped infrastructure failure.

**Execution gate ownership and aggregate timing.** The sealing task is whichever runner's cyclic
call observes registration completion; it cannot start a clock on the reporter's behalf. The
report coordinator therefore owns the aggregate measurement end to end. In order, it:

1. completes output preflight (RunId, stale-output invalidation);
2. starts its aggregate CPU counter;
3. opens the synchronized execution gate;
4. stops the counter after observing the final quiescence record.

Per-task execution timeout uses timestamps from that task's own counter; the aggregate duration is
measured entirely on the reporter's clock, so timestamps from different CPU cores are never
subtracted from one another. Documented consequence: the aggregate duration includes up to one
reporter task cycle of completion-observation latency (plus gate-to-first-execution latency on
other tasks), and is therefore an upper bound on the true concurrent execution span.

### H. Test call context

Before invoking a suite, the runner sets the current suite pointer in its own task context. Free
functions resolve the current task slot once per call and use only that context. Assertions and
timed helpers use the same resolved context.

The migration includes every mutable reference, not only runner and free-function files:

- `FB_TcUnitRunner`
- `FB_TestSuite`
- `FB_TimedTestSuite`
- `FB_TestResults` or its replacement
- `FB_AdsTestResultLogger`
- `FB_xUnitXmlPublisher`
- `FB_AssertResultStatic`
- `FB_AssertArrayResultStatic`
- `FB_AdsAssertMessageFormatter`
- `TEST`, `TEST_ORDERED`, `TEST_FINISHED`, `TEST_FINISHED_NAMED`
- `IS_TEST_FINISHED`, `RUN`, `RUN_IN_SEQUENCE`, and tagged fallbacks if used
- `TCUNIT_ADSLOGSTR`

`TEST_FINISHED_NAMED`'s shared `VAR_STAT` diagnostic counters move into task context. No mutable
function-static state may remain shared between test tasks.

---

## Result model and memory architecture

### Do not replicate the full result snapshot per task

The current result type reserves up to 1,000 suites × 100 tests. Every test result contains three
`T_MaxString` values. Replicating `FB_TestResults` with every runner would consume hundreds of MiB
at default capacities and is rejected by this design.

The authoritative detailed state already exists inside each owned `FB_TestSuite` and its `FB_Test`
instances. Once the owning task has published quiescence, that state is immutable and visible to
the reporter (quiescence barrier, §E). The revised reporting path
therefore reads suites directly through internal read-only getters and maintains only a small
per-task summary during execution.

Add or revise internal getters to return references/read-only values without copying whole
`FB_Test` instances where TwinCAT permits it.

If a cross-repository audit finds supported external use of `I_TestResults` or
`ST_TestSuiteResults`, retain one compatibility adapter/snapshot—not one per task—and document its
availability semantics. Do not silently remove a public symbol that consumers use.

### Correct count semantics

Every task and aggregate summary records separate values:

- suites selected/finished;
- tests total;
- passed;
- failed;
- skipped;
- assertion failures;
- infrastructure failures;
- duration.

Use `UDINT` or wider for aggregate suite/test/assertion counters. The configured maximum of 1,000
suites × 100 tests already exceeds `UINT`; count types must be selected from capacity products, not
from current consumer sizes.

The invariant is:

```text
total = passed + failed + skipped
```

Skipped tests are not successful tests. An infrastructure failure is distinct from an assertion
failure but makes the aggregate run unsuccessful.

Duration semantics:

- suite duration: unchanged, from first suite execution to suite completion;
- task duration: first execution after seal through final suite completion;
- aggregate duration: wall-clock span on the reporter's clock from execution-gate open through
  observation of the final quiescence record — not the sum of task durations (see §G for the
  documented observation latency);
- reporting duration: recorded separately and excluded from test execution time.

---

## Reporting architecture

### Single report coordinator

Per-task files do not require concurrent file writers. Suite/test state owned by a task is
guaranteed visible and immutable to the reporter only once that task's quiescence record has been
observed through the coordinator (the quiescence barrier in §E). The report coordinator publishes
task shards sequentially, reads suite state only from quiesced tasks, and represents an
unresponsive task solely by a synthetic infrastructure result — never a partial user-test shard.

Benefits:

- one `FB_xUnitXmlPublisher` and one XML buffer/stream state;
- no concurrent `SysFile` access from test tasks;
- no per-task full result copies;
- deterministic shard order;
- one authoritative manifest written last;
- one final TwinCATBase flush request.

The reporting state machine is called cyclically and performs bounded work per scan. File and XML
errors become infrastructure failures. The implementation must not publish a partial document as a
final shard.

If `ReportingTimeout` expires, publication stops, aggregate PLC status remains failed, no success
manifest is written, and any completed temporary/final shard outcomes remain listed in diagnostic
status only.

### Shard filenames

For a tagged or multi-task run, derive each filename by inserting normalized tag and raw task index
before the final extension:

```text
tcunit_xunit_testresults_<tag>_task<raw-index>.xml
```

If a task tag is empty in legacy mode, use `GVL_Param_TcUnit.xUnitFilePath` verbatim. This preserves
the established single-task filename.

Path rules:

- derive into an instance/local path; never write the parameter GVL;
- find the extension only after the last path separator;
- support a path with no extension by appending the suffix;
- reject a derived path that exceeds `T_MaxString` rather than truncating it;
- delete only the publisher's exact temporary/final target;
- write `<final>.tmp`, close successfully, then atomically rename/replace the final path if the
  supported SysFile API provides that operation;
- if atomic replace is unavailable, record and test the exact fallback contract.

### XML dialect and formatting contract

The shard format is **JUnit-style XML** (the Jenkins/Maven-Surefire-consumed dialect TcUnit
already approximates) — not a universal "xUnit" schema. The exact contract:

- Root element `<testsuites>` with attributes `tests`, `failures`, `skipped`, `time`, and the run
  identifier. Each `<testsuite>` carries `name`, `id`, `tests`, `failures`, `skipped`, `time`.
- `tests` = total tests; `failures` = failed tests plus the synthetic infrastructure testcase when
  applicable; `skipped` = skipped tests; `time` = task execution duration in seconds.
- Skipped tests are represented by a `<skipped/>` child element on the `<testcase>`, not only a
  status attribute.
- Multiple-failure policy: the deterministic **first** assertion failure is emitted as the
  `<failure>` detail; the total assertion-failure count for that test is emitted as a
  deterministic count marker (message suffix or property) so additional failures are visible, not
  silently dropped.
- Decimal formatting is locale-independent: `.` decimal separator, fixed non-scientific notation,
  explicit formatting code (never locale-dependent conversion).
- Files are UTF-8 without BOM.
- Characters invalid in XML 1.0 (control characters other than tab/LF/CR) are substituted with a
  documented printable replacement before escaping; they are never emitted raw or "escaped" as
  invalid character references.
- Suite identities retain `global registry index - 1`, even when shard entries are compact,
  keeping identities unique and stable across shards.
- Shard provenance is emitted as deterministic suite properties/metadata: TcUnit library version,
  `RunId`, normalized tag, task slot, raw task index, CPU core index, run mode.
- Compatibility is proven against the actual downstream consumers (the ToolPackageManager merge
  path and the CI parser in use), not only by schema inspection.

### Streaming publication

For tagged and multi-task reporting, incremental generation is **mandatory**, not preferred. A
whole-document buffer cannot represent worst-case configured capacity (100,000 testcases with
maximum-length names and messages), so "prove the buffer is sufficient" is only viable for much
smaller capacities and is not the supported design.

- XML is generated incrementally and written in bounded chunks across scans.
- The per-scan work budget (bytes and/or testcases per scan) is a configurable parameter and is
  reported in diagnostics.
- Every write checks both the error return code **and** the written-byte count; a short write is a
  publication failure (`FileWriteFailed`), not a retry loop.
- Retry policy is explicit: **no automatic retries**. Any file error fails that publication
  deterministically; the failure is machine-readable and the run is failed.
- If the selected SysFile APIs can block the calling task, reporting must run on a dedicated
  low-priority reporting task; otherwise the compile spike must record their proven worst-case
  behavior on the supported build. This decision is frozen before implementation.
- `xUnitEnablePublish = FALSE`: no preflight file operations, no shards, no manifest;
  `OutputEnabled = FALSE` and shard outcomes read `Disabled` in status. Machine-readable PLC
  status is then the sole completion authority, and file absence must not be interpreted as
  failure by tooling configured for status-based completion.

Legacy single-task whole-buffer publication may remain internally for strict compatibility, but
tagged/multi-task shards always use the streaming path. XML buffer overflow anywhere is a
reporting failure and never silently truncates output.

### Run epoch, manifest, and completion contract

Writing the manifest last prevents partial publication, but an old successful manifest can remain
on disk while a new run is configuring or failing. Stale-success rejection is therefore enforced
with a run epoch, not file presence:

1. **Fresh `RunId`.** Generated once per activation/run and published in PLC status before the
   execution gate opens. It is opaque, unique per activation, and embedded in status, every shard,
   and the manifest — always the same value for one run.
2. **Output preflight** (report coordinator, before the gate opens, when publication is enabled):
   delete the previous manifest by its exact path, and delete this run's exact `.tmp` targets.
   File-not-found is success; any other deletion failure is `OutputPreflightFailed` and fails the
   run before any test executes. There is **no broad wildcard cleanup** — only exactly named
   paths are ever deleted.
3. **Automation handshake.** Automation first observes the new `RunId` in PLC status, then accepts
   only a manifest that (a) carries that same `RunId`, (b) has `publicationComplete = true`, and
   (c) states an explicit `outcome`. File presence alone is never success. Timeout or absence is
   failure (subject to the `OutputEnabled` status flag for status-based completion).

In multi-task/tagged mode the authoritative completion artifact is the manifest, written after
every expected shard outcome is known. Suggested path:

```text
tcunit_xunit_testresults.manifest.json
```

The manifest contains:

- `schemaVersion` and TcUnit library version;
- `runId` (identical to PLC status and all shards);
- `publicationComplete : bool` — true only when every listed shard outcome is final;
- `outcome : "passed" | "test_failed" | "infrastructure_failed"` — explicit; never inferred from
  file presence;
- expected, registered, quiesced, and published task counts;
- discovered, selected, and excluded suite counts, plus a per-suite excluded list with reason
  codes;
- aggregate counts/durations (seconds);
- one entry per task: slot, raw index, core, tag, mode, shard path, shard outcome, counts,
  duration;
- primary infrastructure error code/message and error count if present.

All JSON string values are escaped per RFC 8259. A JSON Schema for the manifest is committed to
the repository (`docs/schemas/tcunit-manifest.schema.json`) and validated in the verifier.

Write the manifest through a temporary file and replace it only after all shard outcomes are
known. Downstream tooling merges only the shard paths listed in the manifest whose `runId` matches
PLC status. A broad `tcunit_xunit_testresults*.xml` glob is not authoritative because it can
include stale shards.

If configuration fails before normal execution, publish a configuration-failure shard containing a
synthetic failed testcase such as `TcUnit.Infrastructure.Configuration`, then publish a manifest
with `outcome = "infrastructure_failed"` that lists it. If output cannot be written at all, PLC
status remains failed and the manifest is absent; external tooling must treat timeout/absence as
failure.

Legacy single-task plain `RUN()` retains the existing file path and may omit the manifest for
strict compatibility. Machine-readable PLC status (including `RunId`) is still available.

### ADS and structured traces

Each task retains its own ADS FIFO for assertion-time ordering and to avoid cross-task calls on one
stateful queue FB. Tagged/multi-task messages are prefixed with normalized tag and raw task index.
Plain legacy messages retain existing text where compatibility requires it.

`TCUNIT_ADSLOGSTR` guarantees ordering only relative to messages in the caller's active test-task
queue. It does not promise a total order across test tasks.

Queue overflow sets an infrastructure failure flag with a stable code. Dropped diagnostics must not
be silent.

TwinCATBase structured traces continue to be emitted from task-owned FB instances. Production
multi-task enablement remains gated on a verified multi-writer/one-reader ring-buffer implementation.
Only the report coordinator requests the final JSON trace flush after all reporting completes.

If structured tracing is deliberately disabled by configuration, its absence is not a test
failure. If tracing is configured as required and loses/corrupts events or cannot initialize, it is
an infrastructure failure. The required/optional policy must be explicit rather than inferred.

---

## Failure model

Define one strict enum `E_TcUnitErrorCode` with explicit stable numeric values (grouped in
numbered ranges: configuration, execution, capacity, reporting) containing at least:

- `None`
- `InvalidTaskContext`
- `TaskCapacityExceeded`
- `InvalidExpectedTaskCount`
- `TaskRegistrationTimeout`
- `PlanAcknowledgementTimeout`
- `TaskExecutionTimeout`
- `GlobalExecutionTimeout`
- `TaskUnresponsive`
- `ReportingTimeout`
- `RunnerRegistrationChanged`
- `MixedLegacyAndMultiTaskMode`
- `InvalidTag`
- `SuiteAssignmentChanged`
- `SuiteOwnerConflict`
- `UnownedSuite`
- `SuiteWithoutRunner`
- `SuiteTagDoesNotMatchOwnerRunner`
- `RunnerHasNoSuites`
- `ZeroTestsExecuted`
- `SuiteCapacityExceeded`
- `TestCapacityExceeded`
- `AssertionCapacityExceeded`
- `AdsQueueOverflow`
- `StructuredTraceUnavailable`
- `XmlBufferOverflow`
- `OutputPreflightFailed`
- `FileDeleteFailed`
- `FileOpenFailed`
- `FileWriteFailed`
- `FileCloseFailed`
- `FileRenameFailed`
- `ManifestPublishFailed`
- `FrameworkMisuse`

Rules:

- Configuration errors prevent all suite execution.
- A test-task infrastructure failure after execution starts stops that task's further suite
  execution where continuing would corrupt attribution, but other tasks may finish to maximize
  diagnostics. The failed task still publishes quiescence.
- Any infrastructure failure makes aggregate status failed.
- Infrastructure failures are not counted as user test assertion failures; xUnit represents them
  with a synthetic framework testcase.
- Every error is one-shot in human logs but persistent in machine-readable status.
- The first error is retained as `PrimaryErrorCode` together with `FirstErrorPhase`; subsequent
  errors increment `ErrorCount` and may populate a bounded diagnostic list.

`TEST_FINISHED_NAMED` misuse aborts/fails the current task runner, not unrelated task contexts. The
aggregate run still fails and other tasks may complete for diagnostic value.

---

## Online change, reset, and lifecycle

This revision supports one distributed test run per PLC activation.

- Cold/warm reset initializes coordinator, mappings, ownership records, plans, contexts, and report
  state before cyclic execution.
- Online change must not preserve a sealed mapping when suite instances, registry order, task
  indices, or runner topology may have changed.
- Use `FB_reinit` where required to invalidate/rebuild coordinator and instance references after
  moved copy-code instances.
- If safe automatic online-change reconfiguration cannot be proven, detect the generation change,
  fail the active run, and require a PLC reset before another run.
- Never silently rebind a suite to a new task after execution begins.

The exact reset/online-change behavior is verified in XAE and recorded in user documentation.

---

## Backward compatibility contract

For one expected task calling plain `RUN()`:

- no `SetTag()` calls are required;
- all registered suites run in global registration order as today;
- test-body APIs and assertion behavior are unchanged;
- the configured xUnit filepath is unchanged;
- no task-tag prefix is added to legacy ADS messages unless separately versioned/documented;
- one task context and one ADS FIFO are allocated by default;
- the existing verifier remains green;
- `RUN_IN_SEQUENCE()` receives committed regression coverage and correct completion behavior.

Compatibility means supported source and observable behavior, not an undocumented promise that
every internal GVL symbol or PLC memory layout remains identical. Before implementation, search all
Photara consumers for direct use of `GVL_TcUnit`, `FB_TcUnitRunner`, `I_TestResults`, and
`ST_TestSuiteResults`. Preserve an adapter or document/version any supported use.

Fixing incorrect xUnit count semantics is an intentional bug fix. Validate every downstream xUnit
consumer against golden outputs before release.

---

## Memory and real-time acceptance

### Memory

The compile spike records XAE `SIZEOF`/PLC memory for:

- current single-runner baseline;
- revised default (`MaxNumberOfTestTasks = 1`);
- two-task and four-task configurations;
- one task context;
- one ADS queue;
- coordinator/plan storage;
- report publisher/buffer state.

Acceptance:

- Default single-task memory must remain within an explicitly recorded small delta from baseline.
- Increasing task capacity must not duplicate the full detailed result snapshot.
- All capacity products are checked for compile-time/runtime overflow.
- Parameter documentation provides a byte-cost formula or measured table.

### Cycle time and core placement

Verification records for every test task:

- raw task index and configured core index;
- cycle time, priority, and maximum/last execution time;
- task exceed counter before and after the run;
- configuration, execution, and reporting durations.

Two PLC tasks on the same core prove isolation but not core parallelism. The parallel-performance
acceptance test must configure distinct cores and verify them using the supported Beckhoff task/core
API. No claim of throughput improvement is accepted without this evidence.

The feature must not introduce blocking synchronization in the execution path. Reporting is spread
across scans with a documented work budget so the end-of-run phase does not create a new cycle spike.

---

## Verification strategy

All behavior is covered by committed projects/tests. Consumer-only experiments are supplementary,
not the permanent regression suite.

### Test seams — injectable providers

Fault injection must not require manually modifying production guards. The implementation exposes
internal injectable providers, with production defaults bound to the real primitives:

- task identity (`GETCURTASKINDEXEX` wrapper) — inject `-1`/`0`/arbitrary raw indices;
- monotonic time (`GETCPUCOUNTER` wrapper) — inject stalls, jumps, and wraparound;
- file operations (SysFile wrapper) — inject open/write/short-write/close/rename/delete failures;
- synchronization primitive — inject acquisition failure and forced contention;
- ADS queue capacity — inject overflow;
- trace sink — inject unavailable/overflowed structured tracing.

Every Level 5 fault case is driven through these seams. The seams are internal (not public API)
and their production bindings are themselves covered by Level 1/2 tests.

### Reference state-machine model

The .NET verifier contains an executable reference model of the coordinator and runner state
machines: registration, sealing, slot assignment, acknowledgement, gate, execution, quiescence,
and reporting. Generated event traces (registration orders, timings, injected faults) are fed to
both the model and the PLC implementation; phase transitions, final slots, error codes, and final
status must agree. Formal transition coverage is required: every phase transition and every error
code is exercised by at least one trace.

### Metamorphic properties

- Permuting task registration/start order must not change final slot assignment, plans, shard
  names, or manifest content (after canonicalization).
- Moving tasks between CPU cores must not change any semantic result — only measured durations.

### Level 0 — design and static analysis

- Inventory every mutable global and function-static reference.
- Classify each as initialization-only, coordinator-protected, task-owned, or immutable after seal.
- Run TwinCAT Static Analysis rules SA0006 and SA0103.
- Review every suppression, including indirect pointer/reference access that static analysis cannot
  detect.
- Audit TwinCATBase ring-buffer producer/consumer memory ordering, overflow, and string copying.

### Level 1 — compile and ABI spike

Before broad edits, prove in XAE:

- defaulted `VAR_INPUT` compatibility for `RUN()` and `RUN_IN_SEQUENCE()`;
- array-of-task-context and contained FB initialization;
- per-element interface/reference injection does not alias slot 1;
- `GETCURTASKINDEXEX()` and `_TaskInfo[]` agree on the supported 4026 build;
- critical-section primitive works on supported targets;
- temporary-file rename/replace behavior;
- `FB_reinit` behavior during online change;
- exact memory sizes.

### Level 2 — legacy regression

- Existing verifier runs unchanged with plain `RUN()`.
- Add a committed `RUN_IN_SEQUENCE()` verifier configuration.
- Verify no-argument namespaced and unqualified call styles used by consumers.
- Verify raw test task index greater than 1 maps to TcUnit slot 1.
- Golden ADS and xUnit/manifest outputs are compared after canonicalization that excludes only the
  intentionally nondeterministic fields (durations, fresh `RunId`, timestamps); every other byte
  is compared. Intentional differences from current output are explicitly approved.

### Level 3 — single-task selective execution

- Matching tagged suites execute; untagged/nonmatching suites are never executed and are recorded
  as excluded with reason codes (`Untagged`/`TagMismatch`) — not reported as skipped tests.
- Every selection-truth-table row and empty-run condition has a dedicated test.
- Tags normalize deterministically.
- Invalid/empty/overlong/path-like tags fail closed.
- Zero matches produces infrastructure failure, not green zero tests; `ZeroTestsExecuted` fires
  when selected suites execute no tests.
- Repeated identical `SetTag`/`RUN` calls are idempotent.
- Tag, mode, or owner mutation is rejected.
- Registry identities remain stable in compact output.

### Level 4 — multi-task functional verifier

Create a committed verifier configuration with at least two PLC tasks and interleaved registry
order. Include:

- parallel runner on one task and sequential runner on another;
- plain, ordered, and timed test suites;
- identical test names on different tasks;
- intentionally different task cycle times;
- suites with deterministic invocation counters;
- per-task status inspection;
- per-task shard and manifest verification;
- distinct-core and same-core configurations.

Assertions:

- every suite executes on its recorded owner raw task;
- every suite body invocation belongs to exactly one task;
- every suite appears in exactly one plan/shard;
- test names, finished flags, durations, ordered indices, assertions, and abort state never cross
  task contexts;
- task and aggregate counts satisfy `total = passed + failed + skipped`;
- aggregate duration uses wall-clock span, not sum;
- the manifest appears only after all listed shards close successfully.

### Level 5 — negative/fault-injection verifier

Deterministically inject (through the test seams) and assert:

- missing expected runner: registration timeout;
- registered runner that never acknowledges: plan acknowledgement timeout;
- too many unique runner tasks;
- invalid task context (`-1`/`0`);
- mixed plain and tagged mode, including one `SetTag()` suite plus a plain legacy runner;
- same suite configured from two tasks;
- unowned/orphan/mismatched suite;
- duplicate/different runner registration on one task;
- zero tests executed in tagged and multi-task mode; legacy `FailOnZeroTests` both settings;
- task execution self-timeout: task quiesces, `QuiescedAfterTimeout = TRUE`, its completed suites
  are reported;
- stopped task after gate-open: global execution deadline fires, task marked `TaskUnresponsive`,
  reporter publishes only a synthetic infrastructure result and never traverses that task's suite
  state; restarting the task does not resume execution; run requires reset;
- reporter task stopped / no runner ever started: external verifier watchdog fails the run on
  missing fresh `RunId`/manifest;
- report publication timeout;
- suite/test/assert/ADS/XML capacity overflow;
- output preflight failure (undeletable stale manifest);
- stale successful manifest from a previous run present at start: automation rejects it via the
  `RunId` handshake;
- `xUnitEnablePublish = FALSE`: no file operations, status-based completion works;
- file open/write/short-write/close/rename failure;
- crash-cut at every publication boundary: before temp open, mid-write, after close, after shard
  rename, before manifest replace, after manifest replace — automation never accepts a stale or
  partial result in any cut;
- arithmetic boundaries: every capacity product at maximum, every counter at its width limit,
  maximum-length derived filenames, and CPU-counter/`TIME` wraparound;
- `TEST_FINISHED_NAMED` misuse;
- TwinCATBase trace sink unavailable or overflowed.

Every case must prove:

1. no out-of-bounds or cross-context state write;
2. no affected suite executes more than allowed;
3. machine-readable aggregate status is failed;
4. xUnit contains a failed infrastructure testcase when publication is possible;
5. no success manifest is emitted.

### Level 6 — concurrency and repetition stress

Stress supplements the synchronization-correctness arguments (the two barriers plus the reference
model); it does not prove them.

- Synchronize task starts to maximize contention during registration, acknowledgement, and
  quiescence publication.
- Repeat cold-start multi-task runs a minimum of 500 times (raise if any failure reproduces at
  lower counts); record the exact count, hardware, TwinCAT build, and library version with the
  results.
- Vary task priorities, periods, and core placement.
- Stress simultaneous assertion failures and per-task ADS queues.
- Stress TwinCATBase with all test writers plus LogTask reader.
- Include suite/test names and failure messages containing XML/JSON metacharacters, non-ASCII text,
  empty strings, and maximum supported lengths; verify escaping and UTF-8 output.
- Verify deterministic plans, counts, shard names, and manifest content across repetitions.

### Level 7 — consumer qualification

Build and run representative suites from TwinCAT_Base, AuxControl, Vision, Motion, Communication,
V3Tool, ContinuousTool, and TwinCAT_Tests. Audit direct internal API use and verify downstream xUnit
merge behavior from the manifest.

### Mutation checks

After tests pass, intentionally disable or alter one guard at a time to prove the relevant test
fails. Mutation checks supplement red-first tests; they do not replace deterministic assertions.

### Requirements traceability

Every requirement below must be traceable to at least one committed test; the table is kept
current as tests are written (test names filled in during implementation).

| ID | Requirement | Verified by |
|---|---|---|
| R1 | Correct attribution — assertions/finishes/durations bind to the exact suite/test | L4 isolation asserts; L6 stress; mutation |
| R2 | Exactly-once suite execution; each suite in ≤1 plan | L4 invocation counters; L5 owner-conflict cases |
| R3 | Fail closed — no invalid topology/capacity/reporting error yields a green run | L3 invalid-tag/zero-match; L5 full fault matrix |
| R4 | Deterministic slots/plans/output independent of registration order | Metamorphic permutation tests; canonicalized goldens |
| R5 | No lock in the test execution path between the two barriers | L0 static analysis + code review; L6 cycle-time evidence |
| R6 | Plan barrier — runners read plans only after synchronized acknowledgement | Reference model traces; L5 acknowledgement-timeout case |
| R7 | Quiescence barrier — reporter reads only quiesced tasks' suite state | Reference model traces; L5 unresponsive-task case |
| R8 | Stopped-task detection — self-timeout, global deadline, external watchdog | L5 timeout/unresponsive/watchdog cases |
| R9 | Run-epoch handshake — stale success never accepted | L5 stale-manifest and crash-cut cases |
| R10 | Streaming publication with bounded per-scan work and short-write detection | L1 spike; L5 file faults; L6 cycle-time metrics |
| R11 | Count semantics `total = passed + failed + skipped`; UDINT widths | L2/L4 goldens; arithmetic boundary tests |
| R12 | Legacy `RUN()`/`RUN_IN_SEQUENCE()` behavior preserved | L2 regression; consumer qualification (L7) |
| R13 | Selection truth table and empty-run semantics enforced per mode | L3/L5 per-row tests; manifest exclusion assertions |
| R14 | Status ABI versioned, numbered, torn-read-safe | L1 spike; .NET seqlock reader tests; L6 stress |
| R15 | Memory — no per-task replication of the full result snapshot | L1 measured sizes; acceptance gate |
| R16 | XML dialect/formatting contract (skipped element, decimals, UTF-8, control chars) | Golden shards; downstream CI parser compatibility tests |
| R17 | Manifest schema validity and JSON escaping | Committed JSON Schema validation in verifier |
| R18 | Online-change/reset lifecycle safety | L1 `FB_reinit` spike; L5 generation-change case |

---

## Implementation order

0. **Prerequisites**
   - Complete timed-suite Phase 4a/4b.
   - Add/fix sequential-runner completion regression.
   - Correct and golden-test total/passed/failed/skipped xUnit semantics.
   - Complete TwinCATBase multi-writer audit before production multi-task enablement.

1. **Compile/memory spike**
   - Decide `RUN` signature strategy.
   - Prove compact task lookup, synchronization primitive, context-array initialization, rename,
     online change, and exact memory.

2. **Status, seams, and coordinator skeleton**
   - Add numbered enums, status DUTs and the versioned status GVL with its seqlock/double-buffer
     protocol, parameters, injectable provider seams, the coordinator state machine with the
     `Sealing` phase, registration keyed by raw index, deterministic sorted slot assignment, and
     fail-closed diagnostics.
   - Keep suite execution disabled until sealing, acknowledgement, and gate invariants are proven
     against the reference model.

3. **Task-context migration**
   - Move runner/current-test/counter/queue state into cohesive contexts.
   - Migrate every mutable reference, including logging/result helpers and function-static state.
   - Keep default one-task legacy verifier green.

4. **Suite assignment, immutable planning, and barriers**
   - Implement normalized `SetTag`, owner capture, runner registration, timeouts, the selection
     truth table, out-of-lock plan construction, seal, plan acknowledgement, and the execution
     gate with reporter-owned preflight and aggregate timing.
   - Add single-task selective tests before enabling multi-task execution.

5. **Plan-driven runners**
   - Refactor parallel and sequential runners around the same immutable plan abstraction.
   - Add exact-once, ordered, timed, abort, and cross-context tests.

6. **Memory-safe result/reporting pipeline**
   - Remove per-task full snapshots.
   - Add quiescence-gated immutable suite readers, correct summaries, the single report
     coordinator, `RunId` generation and output preflight, streaming shard publication with a
     per-scan work budget, synthetic infrastructure failures, and the manifest with its committed
     JSON Schema.

7. **Committed multi-task verifier and stress suite**
   - Add two-task task objects/PRGs, .NET status polling with the seqlock reader and external
     watchdog, the reference state-machine model, seam-driven fault injection, crash-cut and
     metamorphic tests, canonicalized golden XML/manifest comparisons plus downstream CI parser
     compatibility, static analysis, core checks, recorded-count repetition stress, arithmetic
     boundary tests, and memory/performance evidence. Fill in the traceability table.

8. **Consumer qualification and release**
   - Audit/compile all Photara consumers.
   - Update user guide, FAQ, examples, CLAUDE, BREADCRUMBS, PROJECT_STATE, EXECUTION_PLAN, and
     migration notes.
   - Bump both version locations, build/install the library, and record the qualified TwinCAT/Base
     versions and measured resource table.

Every new TwinCAT object and method/property/function receives a fresh randomized GUID and a
`TcUnit.plcproj` compile entry where applicable.

---

## Rollout strategy

1. Merge the task-context/coordinator architecture with defaults fixed at one expected/max task and
   prove legacy parity.
2. Enable single-task tagged selection and qualify it.
3. Enable multi-task configurations only after the Base audit and dedicated verifier pass.
4. Require multi-task consumers to set both `ExpectedNumberOfTestTasks` and
   `MaxNumberOfTestTasks` explicitly and to consume the manifest.
5. Keep throttling as a separate follow-on for suites or individual tests that still exceed their
   assigned task budget.

---

## Risks and controls

| Risk | Control |
|---|---|
| Raw task indices are sparse or change | Compact synchronized mapping; expose raw and slot; reset/reinit contract. |
| Shared configuration tears or double-claims | Coordinator protection; immutable seal; ownership captured during `SetTag`. |
| A task never registers | Expected task count plus bounded registration timeout and failed infrastructure result. |
| A suite is silently omitted | Full topology validation in multi-task mode; every runner must select suites. |
| Runner tag/mode changes between scans | Latch first registration; reject mutation. |
| Full results multiply memory | Direct immutable suite reporting; one report coordinator; default one context. |
| Same tag creates file collision | Include raw task index in shard name; validate derived path. |
| Stale shards are merged | Manifest is authoritative and written last. |
| Partial XML appears complete | Temporary file plus atomic replace/fallback contract; no final shard on error. |
| Configuration error appears green | Persistent failed status plus synthetic infrastructure testcase. |
| ADS summaries interleave ambiguously | Per-task queues and tag/task prefix in tagged mode. |
| Base ring buffer corrupts under writers | Production gate, code audit, static analysis, and repeated stress test. |
| File/reporting work overruns a cycle | Single cyclic report state machine with bounded work per scan and metrics. |
| A multi-cycle test or report never completes | Configurable task/report timeout; failed infrastructure status; no success manifest. |
| Tasks share a core | Verify and report core index; do not claim parallel speedup without distinct cores. |
| Consumer suites race on a shared SUT/resource | Explicit ownership/migration contract and consumer concurrency audit. |
| Existing internal API consumers break | Cross-repository symbol audit and compatibility adapter/migration notes. |
| Sequential runner filtering regresses | Shared plan abstraction plus committed sequential verifier. |
| Another core misses plan/suite writes | Plan and quiescence barriers: all cross-task handoffs ordered by the coordinator primitive. |
| Sealing scans 1,000 suites under a cross-task lock | `Sealing` phase: freeze briefly, build/validate plans outside the lock, publish briefly. |
| Slot/reporter identity varies between boots | Deterministic sorted-raw-index slot assignment at seal; metamorphic tests. |
| Stopped task hangs or corrupts the run | Reporter-clock global deadline; `TaskUnresponsive`; reporter never reads unquiesced state; external watchdog; reset before rerun. |
| Old successful manifest read as current | Run epoch: fresh `RunId` handshake, preflight invalidation, `publicationComplete`/`outcome` fields. |
| ADS reads a torn status snapshot | Versioned status GVL with seqlock/double-buffer publication protocol. |
| Whole-document XML buffer cannot hold worst case | Mandatory streaming publication with bounded per-scan budget and short-write detection. |

---

## Acceptance gates

Implementation is complete only when all are true:

- [ ] Phase 4a/4b and sequential-runner prerequisite tests pass.
- [ ] TwinCATBase multi-writer audit and stress test pass.
- [ ] `RUN` signature strategy is compile-proven across supported call styles.
- [ ] Default one-task memory is measured and approved.
- [ ] Additional tasks do not duplicate the full detailed result snapshot.
- [ ] SA0006/SA0103 findings are zero or individually justified.
- [ ] Legacy `RUN` and `RUN_IN_SEQUENCE` verifier configurations pass.
- [ ] Single-task selective tests pass, including zero-match and invalid-tag failures.
- [ ] Multi-task exact-once/isolation tests pass on same-core and distinct-core configurations.
- [ ] Plan and quiescence barriers are implemented as specified and the PLC implementation agrees
      with the reference state-machine model on all generated traces, with full phase/error
      transition coverage.
- [ ] Slot assignment and reporter election are proven order-independent (metamorphic tests).
- [ ] Every selection-truth-table row and empty-run condition has a passing test.
- [ ] Every negative configuration/fault case fails closed and is machine-readable, driven through
      the injectable seams.
- [ ] The status GVL's torn-read protection is verified by the .NET seqlock reader under load.
- [ ] Shards have correct counts, unique deterministic paths, and stable suite identities, and
      pass the downstream CI parser compatibility tests.
- [ ] Streaming publication respects its per-scan work budget and detects short writes.
- [ ] Manifest is written last, matches the committed JSON Schema, and is the only authoritative
      shard list.
- [ ] The `RunId` handshake rejects stale output in every crash-cut scenario.
- [ ] No partial or stale output can be mistaken for the current successful run.
- [ ] The requirements traceability table is complete, with every row naming committed tests.
- [ ] Memory, task execution, exceed counters, reporting work, and core mapping are recorded.
- [ ] All Photara consumers compile; representative projects run successfully.
- [ ] Documentation, migration notes, version, and compiled library are updated together.
