# Multi-Task Tagged Test Execution — Revised Design Spec

**Date**: 2026-07-16
**Revision**: 2
**Status**: Approved revised design; implementation not started
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
2. Each test task registers once with a global coordinator. The coordinator maps sparse raw PLC
   task indices to compact TcUnit task slots.
3. When every expected test task has registered, the coordinator validates the complete topology,
   creates an immutable ordered execution plan for each task, and seals configuration.
4. After sealing, each test task touches only its own task context, suites, CPU counter, and ADS
   queue. No lock is taken in the test execution path.
5. When all test tasks finish, one designated report coordinator reads the now-immutable suite
   state and publishes deterministic per-task xUnit shards followed by an authoritative manifest.

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
| Shard | One xUnit XML document containing the suites in one task's execution plan. |
| Infrastructure failure | A TcUnit configuration, runtime, capacity, synchronization, or reporting error—not a user assertion failure. |

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

Add a stable, read-only status model for verifier/automation use:

```iecst
TYPE ST_TcUnitTaskRunStatus :
STRUCT
    Slot                    : UINT;
    RawTaskIndex            : DINT;
    CpuCoreIndex            : DINT;
    Tag                     : STRING(32);
    RunMode                 : E_TcUnitRunMode;
    Phase                   : E_TcUnitRunPhase;
    ConfigurationError      : E_TcUnitConfigurationError;
    InfrastructureFailed    : BOOL;
    SelectedSuites          : UDINT;
    FinishedSuites          : UDINT;
    TotalTests              : UDINT;
    PassedTests             : UDINT;
    FailedTests             : UDINT;
    SkippedTests            : UDINT;
    Duration                : LREAL;
    ShardPublished          : BOOL;
    ShardPath               : T_MaxString;
END_STRUCT
END_TYPE
```

Also expose aggregate phase/status, expected/registered/completed task counts, and manifest state.
The exact public accessor may be a read-only GVL status array or getter functions, but it must be
stable, symbol-accessible, and tested by the .NET verifier. Automation must not need to infer
completion by scraping ADS text.

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
| Legacy run-all | `ExpectedNumberOfTestTasks = 1`, runner tag empty | All registered suites are assigned to and executed by the sole runner. Existing suites need no `SetTag()`. |
| Single-task selective | `ExpectedNumberOfTestTasks = 1`, runner tag non-empty | Execute suites owned by the caller whose tag matches. Untagged/nonmatching suites are intentionally idle. Zero matches is a configuration failure. |
| Multi-task | `ExpectedNumberOfTestTasks > 1`, every runner tag non-empty | Every registered suite must have one valid owner and must match the tag latched by a runner on that owner task. Every runner must select at least one suite. |

Plain `RUN()` is invalid when more than one test task is expected. A mixed plain/tagged topology is
rejected before any suite body executes.

In multi-task mode, an unowned suite, a suite whose owner has no registered runner, or a suite whose
tag does not match its owner's runner is a failure. This prevents accidentally omitted suites from
making the distributed run appear green.

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
- coordinator phase (`Open`, `SealedValid`, `SealedInvalid`, `Executing`, `Reporting`, `Complete`);
- raw-task-to-slot mappings;
- latched runner registration records;
- suite assignment records keyed by registry index;
- immutable execution plans;
- per-task completion/reporting flags;
- aggregate infrastructure status and stable error codes;
- report coordinator election (slot 1 unless explicitly changed in a future API);
- authoritative manifest state.

The coordinator's shared mutation methods are synchronized. The lock is used only for:

- first/repeated suite registration;
- first/repeated runner registration;
- configuration sealing;
- one-shot task execution completion;
- one-shot shard publication completion;
- one-shot infrastructure failure publication.

No coordinator lock is entered from `TEST`, assertions, wait helpers, suite bodies, or the normal
per-cycle runner loop after configuration is sealed.

If a non-blocking `TestAndSet()` implementation is used, a failed acquisition defers registration
or completion publication until the next scan. If `FB_IecCriticalSection` is used, the protected
region must contain no loops over tests, no string formatting beyond bounded registration data, no
logging, and no file/ADS access.

### C. Compact task-slot mapping

`MaxNumberOfTestTasks` is a capacity, not a raw PLC task index limit.

On first runner registration:

1. Call `GETCURTASKINDEXEX()` into a `DINT`.
2. Reject `<= 0` before any unsigned conversion.
3. Reuse an existing slot for the same raw index, or assign the next free slot.
4. Fail configuration if no slot remains.

Examples:

```text
Raw PLC tasks: Main=1, Log=2, Motion=3, TestFast=5, TestHeavy=8
TcUnit mapping: TestFast raw 5 → slot 1; TestHeavy raw 8 → slot 2
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
- per-task summary/status and one-shot diagnostic flags.

The full `ST_TestSuiteResults` snapshot and xUnit publisher buffer are deliberately not duplicated
inside every task context.

### E. Immutable execution plans

When the expected runner count has registered, the coordinator validates and seals the complete
topology under synchronization. It then builds each plan by scanning the global suite registry in
registration order and appending suites that belong to that raw task and match that runner tag.

After `SealedValid`:

- task mappings, runner registrations, suite owner/tag records, and execution plans never change;
- each suite registry index appears in at most one plan;
- no runner scans mutable tag strings;
- no runner calls a suite owned by another task;
- plan order is deterministic and preserves global registration order.

The coordinator verifies these invariants before changing phase to `Executing`.

### F. Configuration timeout

Add parameters:

```iecst
MaxNumberOfTestTasks      : UINT := 1;
ExpectedNumberOfTestTasks : UINT := 1;
TaskRegistrationTimeout   : TIME := T#5S;
TaskExecutionTimeout      : TIME := T#0S;
ReportingTimeout          : TIME := T#30S;
```

Validate at compile/startup that
`1 <= ExpectedNumberOfTestTasks <= MaxNumberOfTestTasks`.

Each registered runner starts a task-local configuration wait timer. If the expected number of
unique test tasks does not register before the timeout, the first runner able to enter the
coordinator publishes `MissingExpectedTask` and seals the run invalid. This converts a stopped,
missing, or misconfigured task into a failed result rather than an infinite wait.

`TaskExecutionTimeout = T#0S` preserves the current unlimited behavior. A nonzero value places a
wall-clock ceiling on each task plan and is strongly recommended for CI. Expiration marks an
infrastructure failure, stops further suite execution on that task, and allows other tasks to
finish for diagnostics. `ReportingTimeout` prevents file/report state machines from hanging
automation indefinitely.

### G. Runner state machine

Each task runner uses an explicit persistent state machine:

```text
Unregistered
  → WaitingForConfiguration
  → Ready
  → Executing
  → ExecutionComplete
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
execution. The runner marks task execution complete exactly once through the coordinator.

Task execution timeout uses timestamps from that task's own counter. Aggregate execution duration
is measured entirely by the report-coordinator task—from valid configuration seal until it observes
the final one-shot task completion—so timestamps from different CPU cores are never subtracted from
one another.

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
instances. After task execution completes, that state is immutable. The revised reporting path
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
- aggregate duration: wall-clock span from global execution start through the last task's suite
  completion, not the sum of task durations;
- reporting duration: recorded separately and excluded from test execution time.

---

## Reporting architecture

### Single report coordinator

Per-task files do not require concurrent file writers. Once every task has marked execution
complete, all suite/test state is immutable. The designated report coordinator then publishes all
task shards sequentially.

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

### xUnit correctness

Each shard root reports:

- `tests` = total tests;
- `failures` = failed tests plus a synthetic infrastructure testcase when applicable;
- `skipped` = skipped tests;
- `time` = task execution duration.

Suite identities retain `global registry index - 1`, even when shard entries are compact. This
keeps identities unique and stable across shards.

Include shard provenance as supported xUnit properties or deterministic suite metadata:

- TcUnit library version;
- run identifier;
- normalized tag;
- task slot;
- raw task index;
- CPU core index;
- run mode.

XML control/buffer overflow is a reporting failure. It must never silently truncate output. The
preferred implementation streams bounded chunks across scans. If the first implementation retains
a whole-document buffer, XAE tests must prove the configured buffer is sufficient or emit a failed
infrastructure result and withhold the final shard.

### Manifest and completion contract

In multi-task/tagged mode, the authoritative completion artifact is a manifest written after every
expected shard has closed successfully. Suggested path:

```text
tcunit_xunit_testresults.manifest.json
```

The manifest contains:

- schema version and TcUnit library version;
- run identifier;
- aggregate success/failure and infrastructure status;
- expected, registered, executed, and published task counts;
- aggregate counts/durations;
- one entry per task: slot, raw index, core, tag, mode, shard path, counts, duration, publish status;
- stable infrastructure error code/message if present.

Write the manifest through a temporary file and replace it only after all shard outcomes are known.
Downstream tooling merges only the shard paths listed in the current manifest. A broad
`tcunit_xunit_testresults*.xml` glob is not authoritative because it can include stale shards.

If configuration fails before normal execution, publish a configuration-failure shard containing a
synthetic failed testcase such as `TcUnit.Infrastructure.Configuration`, then publish a manifest
that lists it. If output cannot be written at all, PLC status remains failed and the manifest is
absent; external tooling must treat timeout/absence as failure.

Legacy single-task plain `RUN()` retains the existing file path and may omit the manifest for strict
compatibility. Machine-readable PLC status is still available.

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

Define a strict enum such as `E_TcUnitConfigurationError` / `E_TcUnitInfrastructureError` with at
least:

- `None`
- `InvalidTaskContext`
- `TaskCapacityExceeded`
- `InvalidExpectedTaskCount`
- `TaskRegistrationTimeout`
- `TaskExecutionTimeout`
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
- `SuiteCapacityExceeded`
- `TestCapacityExceeded`
- `AssertionCapacityExceeded`
- `AdsQueueOverflow`
- `StructuredTraceUnavailable`
- `XmlBufferOverflow`
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
  diagnostics.
- Any infrastructure failure makes aggregate status failed.
- Infrastructure failures are not counted as user test assertion failures; xUnit represents them
  with a synthetic framework testcase.
- Every error is one-shot in human logs but persistent in machine-readable status.
- The first error code is retained as primary; subsequent errors may increment a count or populate a
  bounded diagnostic list.

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
- Golden ADS and xUnit outputs are compared with explicitly approved intentional differences.

### Level 3 — single-task selective execution

- Matching tagged suites execute; untagged/nonmatching suites remain untouched and unreported.
- Tags normalize deterministically.
- Invalid/empty/overlong/path-like tags fail closed.
- Zero matches produces infrastructure failure, not green zero tests.
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

Deterministically inject and assert:

- missing expected runner timeout;
- too many unique runner tasks;
- invalid task context (`-1`/`0`) through a test hook;
- mixed plain and tagged multi-task mode;
- same suite configured from two tasks;
- unowned/orphan/mismatched suite;
- duplicate/different runner registration on one task;
- task execution timeout and report publication timeout;
- suite/test/assert/ADS/XML capacity overflow;
- file open/write/close/rename failure;
- stopped task before completion;
- `TEST_FINISHED_NAMED` misuse;
- TwinCATBase trace sink unavailable or overflowed.

Every case must prove:

1. no out-of-bounds or cross-context state write;
2. no affected suite executes more than allowed;
3. machine-readable aggregate status is failed;
4. xUnit contains a failed infrastructure testcase when publication is possible;
5. no success manifest is emitted.

### Level 6 — concurrency and repetition stress

- Synchronize task starts to maximize contention during registration and completion publication.
- Repeat cold-start multi-task runs enough times to expose scheduling-sensitive failures; record the
  chosen count and hardware.
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

2. **Status and coordinator skeleton**
   - Add enums/status DUTs, parameters, coordinator state machine, raw-to-slot registration, and
     fail-closed diagnostics.
   - Keep suite execution disabled until sealing invariants are proven.

3. **Task-context migration**
   - Move runner/current-test/counter/queue state into cohesive contexts.
   - Migrate every mutable reference, including logging/result helpers and function-static state.
   - Keep default one-task legacy verifier green.

4. **Suite assignment and immutable planning**
   - Implement normalized `SetTag`, owner capture, runner registration, timeout, validation, plan
     construction, and seal.
   - Add single-task selective tests before enabling multi-task execution.

5. **Plan-driven runners**
   - Refactor parallel and sequential runners around the same immutable plan abstraction.
   - Add exact-once, ordered, timed, abort, and cross-context tests.

6. **Memory-safe result/reporting pipeline**
   - Remove per-task full snapshots.
   - Add direct immutable suite readers, correct summaries, single report coordinator, shard
     publishing, synthetic infrastructure failures, and manifest.

7. **Committed multi-task verifier and stress suite**
   - Add two-task task objects/PRGs, .NET status polling, fault injection, golden XML/manifest, static
     analysis, core checks, repetition stress, and memory/performance evidence.

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
- [ ] Every negative configuration/fault case fails closed and is machine-readable.
- [ ] Shards have correct counts, unique deterministic paths, and stable suite identities.
- [ ] Manifest is written last and is the only authoritative shard list.
- [ ] No partial or stale output can be mistaken for the current successful run.
- [ ] Memory, task execution, exceed counters, reporting work, and core mapping are recorded.
- [ ] All Photara consumers compile; representative projects run successfully.
- [ ] Documentation, migration notes, version, and compiled library are updated together.
