# Development Breadcrumbs

**Last Updated**: 2026-07-23

Hard-won knowledge, gotchas, and patterns that save future agents from repeating mistakes.

---

## Critical Gotchas

### 1. FB_BaseStatic InstancePath Shadowing

**Symptom**: TraceWithSeverity log entries have empty or incorrect InstancePath.
**Cause**: FB_TestSuite originally declared its own `InstancePath : T_MaxString` with `{attribute 'instance-path'}`, which shadows `FB_BaseStatic.InstancePath : STRING`. The parent's `_FormatLogEntry()` reads from its own `InstancePath` field, which doesn't get the reflection attribute value when shadowed.
**Solution**: Comment out (or delete) the child's `InstancePath` declaration. Let the inherited `FB_BaseStatic.InstancePath` receive the reflection value. Note the type difference: parent uses `STRING` (255 chars), child used `T_MaxString` (also 255 chars in TwinCAT).

### 2. FB_BaseStatic.Initialize() Not Required for TraceWithSeverity

**Symptom**: Concern that TraceWithSeverity won't work without calling Initialize().
**Cause**: `TraceWithSeverity()` gates on the **ring buffer's** initialization state (self-initializing on first call) and `GPL_Base.TRACING_ENABLED`, NOT on `BaseStatus.Initialized`. The `_FormatLogEntry()` reads `InstancePath` directly from the VAR, not from `BaseConfiguration.InstancePath`.
**Solution**: Skip calling `Initialize()` when extending FB_BaseStatic purely for tracing. The ring buffer self-initializes. This avoids the complexity of the 3-phase init chain (children deps → references → dependency config) when it's not needed.

### 3. AreAllTestsFinished Called Every Cycle

**Symptom**: Trace messages logged every cycle instead of once.
**Cause**: `FB_TcUnitRunner.RunTestSuiteTests()` calls `AreAllTestsFinished()` on each test suite every cycle. Any TraceWithSeverity call inside that method fires repeatedly.
**Solution**: Use one-shot flags (e.g., `EmptySuiteTraced : BOOL`) or R_TRIG edge triggers for any trace calls in cyclically-called methods. The `AllTestSuitesFinishedTrigger : R_TRIG` pattern in FB_TcUnitRunner is the model.

### 4. Duplicate Code in RunTestSuiteTests and RunTestSuiteTestsInSequence

**Symptom**: Edits fail with "Found 2 matches" when trying to modify shared code patterns.
**Cause**: Both methods contain nearly identical code blocks (AllTestSuitesFinished logic, test result logging block). String-based edits can't distinguish between them without surrounding context.
**Solution**: Include method-specific context (e.g., the `TimerBetweenExecutionOfTestSuites` line for sequential, or the method closing XML tag) to uniquely identify the edit target.

### 5. FB_TestSuite.TcPOU is Extremely Large (~60K tokens)

**Symptom**: Cannot read FB_TestSuite.TcPOU in a single Read call.
**Cause**: The file contains ~3800 lines of XML with all assertion methods (20+ typed AssertEquals variants, array variants, etc.) inline.
**Solution**: Use `offset` and `limit` parameters on Read, or use Grep to find specific line numbers first, then read targeted sections.

### 6. Centralize Trace Calls — Don't Scatter Across Assert Methods

**Symptom**: 23+ scalar assert methods each needed `_traceExpected`/`_traceActual` assignments before `SetTestFailed`, creating massive code churn for a single trace message.
**Cause**: The original approach put trace responsibility in `SetTestFailed` on `FB_TestSuite`, requiring each Assert method to pre-stage string-converted values into instance variables.
**Solution**: Move the `TraceWithSeverity` call into `FB_AdsAssertMessageFormatter.LogAssertFailure()` instead. Every Assert method already calls `LogAssertFailure` with string-converted Expected/Actual values, so this centralizes tracing in one place. Required making `FB_AdsAssertMessageFormatter EXTENDS Base.FB_BaseStatic`. Eliminated all `_traceExpected`/`_traceActual` code.

### 7. Array Assert Methods Call LogAssertFailure Too

**Symptom**: Concern that array assertions might not get traced.
**Cause**: Array assert methods (1D, 2D, 3D) follow the same pattern as scalar asserts — they all call `AssertMessageFormatter.LogAssertFailure()` on failure.
**Solution**: Centralizing the trace in `LogAssertFailure` automatically covers array assertions. Array ExpectedString/ActualString may be truncated at the 255-char `T_MaxString` limit, but the test path, assertion type, and user message are fully captured.

### 8. Dead Code in FB_AssertResultStatic: GetDetectionCount / GetDetectionCountThisCycle

**Symptom**: `GetDetectionCountThisCycle()` had `.Message = TestInstancePath` instead of `.TestInstancePath = TestInstancePath` — but no observable bug.
**Cause**: Both `GetDetectionCount` and `GetDetectionCountThisCycle` are PRIVATE methods that are **never called**. `ReportResult()` does its own inline matching loop directly against `AssertResultInstances` instead of delegating to these helpers. The typo was in dead code.
**Resolution**: Fixed the typo (correct if someone ever calls it), but this had zero runtime impact. The same two methods are dead code in `FB_AssertArrayResultStatic` as well (though the array variant didn't have the typo).
**Lesson**: Verify callers before claiming a bug fix — dead code with a typo is not an active bug.

### 9. SysFile.Delete on Non-Existent File May Return Error

**Symptom**: TraceWithSeverity fires "file I/O failure" on first run even though the file was successfully created and written.
**Cause**: `FB_xUnitXmlPublisher.DeleteOpenWriteClose()` uses `MAX()` to accumulate results across Delete → Open → Write → Close. If `File.Delete()` returns a non-OK code for a non-existent file (first run), the MAX chain propagates that error even though Open/Write/Close all succeeded.
**Solution**: Track Open/Write/Close results in a separate `WriteResult` variable. Only trace on `WriteResult` failure, not on the combined `DeleteOpenWriteClose` return value. The method's return value still includes the Delete result for backward compatibility.

### 10. SetTestFailed Was PRIVATE — Changed to INTERNAL for FB_TimedTestSuite

**Symptom**: FB_TimedTestSuite cannot call `SetTestFailed` for safety timeout or wait-misuse auto-fail paths.
**Cause**: `SetTestFailed` was `METHOD PRIVATE` on FB_TestSuite, inaccessible to subclasses.
**Solution**: Changed to `METHOD INTERNAL` (accessible within same library). `SetTestFinished` and `CalculateAndSetNumberOfAssertsForTest` were already INTERNAL. The safety timeout path must call all three in sequence to replicate the full `TEST_FINISHED()` bookkeeping.

### 11. _nActiveTimedTestIdx Can Leak Across Test Methods

**Symptom**: `WaitForTime()` or `WaitForCondition()` called outside a valid timed-test body can bind to the previous timed test instead of tripping the "no active timed context" guard.
**Cause**: `_nActiveTimedTestIdx` is reset to 0 only at the START of each `TEST_TIMED` / `TEST_TIMED_ORDERED` call, then left populated after the timed test body returns. After the final timed test method in a scan, the last index can survive long enough for a stray wait call to reuse it.
**Solution**: Treat this as a real hardening issue, not just a caller contract. The next code pass should clear or invalidate timed context on exit, or otherwise give wait helpers a stronger notion of "active timed test" than a nonzero index alone. The current `idx = 0` check is only best-effort.

### 12. WaitForCondition Must Check Condition BEFORE Starting Wait

**Symptom**: `WaitForCondition(TRUE, T#5S)` returns FALSE on first call even though condition is already met.
**Cause**: Original design started the wait timer on first call unconditionally, then checked condition on subsequent calls.
**Solution**: Check `bCondition` before recording `nWaitStartTime`. If condition is TRUE on first call, complete immediately (return TRUE, no wait started). This was caught during spec review v2.

### 13. Wait Misuse Must Auto-Fail, Not Return TRUE

**Symptom**: Calling WaitForTime after WaitForCondition (or vice versa) could let the test pass without actually waiting.
**Cause**: Original design returned TRUE on misuse (bail out safely), which lets the test body proceed and potentially pass — a false green.
**Solution**: Wait misuse now calls `SetTestFailed(Type_WAIT_MISUSE, ...)` with full bookkeeping and returns FALSE. The test always goes red on misuse. Caught during spec review v3.

### 14. GetTimedTestResult Must Normalize TestName Like TEST()/TEST_ORDERED()

**Symptom**: `GetTimedTestResult(' My Test ')` can return a zeroed result even when the timed test exists.
**Cause**: Timed test registration paths trim names before calling `AddTest()`, but `GetTimedTestResult()` currently looks up the raw input string.
**Solution**: Apply the same `F_LTrim(F_RTrim(...))` normalization inside `GetTimedTestResult()` before `_FindTestIndex()`. Any public verifier-facing lookup should match TcUnit's registration behavior exactly.

### 15. Timed Suite Landed Before Validation Coverage

**Symptom**: A substantial new execution path exists without matching Level 1 / Level 2 validation committed alongside it.
**Cause**: The feature landed across seven recent implementation commits before XAE verification and timed-suite tests were written.
**Solution**: The immediate next phase is: harden the two audit findings first, then do XAE build verification, then add green-path timed tests. Treat external verifier coverage as follow-on work, not as implied by the implementation landing.

### 16. GETCURTASKINDEXEX Is a Raw Task Index, Not a TcUnit Slot

**Symptom**: A project configured for one TcUnit test task fails when that task's PLC index is 3 or 5, or a two-task project indexes beyond `MaxNumberOfTestTasks := 2`.
**Cause**: `GETCURTASKINDEXEX()` returns `-1`, `0`, or the actual 1-based PLC task index. Other Main/Log/Motion tasks create gaps; the value is not a compact count of test tasks.
**Solution**: Keep the raw value as `DINT`, reject `<= 0` before conversion, and map positive raw indices to compact TcUnit slots under the Phase 5 coordinator. `MaxNumberOfTestTasks` is a capacity, never a raw-index bound.

### 17. Multi-Task Configuration Must Freeze Before Suite Execution

**Symptom**: A late tag is never picked up, a runner finishes with zero suites, a tag string tears while another task reads it, or two tasks both claim and execute one suite.
**Cause**: Cyclic `SetTag()` writes plus runtime scan/check/set claiming mix configuration mutation with concurrent execution.
**Solution**: `SetTag()` captures owner raw task and normalized tag once under coordinator registration. Runners register/latch once. When all expected tasks arrive, freeze registration briefly under the lock, build immutable registry-index plans *outside* the lock (never scan 1,000 suites in a cross-task critical section), and publish the sealed generation under the lock. Execute only after every runner has acknowledged the plan generation and the report coordinator has opened the execution gate; take no coordinator lock in test bodies/assertions.

### 18. Never Put the Full Result Snapshot in Every Task Runner

**Symptom**: Enabling four task slots adds hundreds of MiB of PLC memory even before suite-instance overhead.
**Cause**: `ST_TestSuiteResults` reserves 1,000 suites × 100 tests, and each test record contains three 255-character strings. `FB_TcUnitRunner` currently contains `FB_TestResults`; making an array of runners would replicate that fixed snapshot.
**Solution**: Detailed truth remains in the suite/test instances. After all owner tasks finish, one report coordinator reads immutable suite state and publishes all shards. Keep at most one compatibility snapshot if a consumer audit proves it is needed. Measure `SIZEOF`/PLC memory in the XAE spike.

### 19. Method VAR Does Not Persist Across Cyclic Calls

**Symptom**: Sequential run completion never latches even though the last suite finished.
**Cause**: TwinCAT reinitializes normal method variables on every call. The current sequential runner declares `NumberOfTestSuitesFinished` as method `VAR`, while only the suite cursor/timer are `VAR_INST`; the final-suite branch does not make the local count equal the total.
**Solution**: Add a committed sequential regression before Phase 5, then use an explicit persistent plan cursor/state machine. State spanning scans belongs on the FB/context or in `VAR_INST`. **FIXED 2026-07-18 (2026.7.18.1)**: the final-suite branch publishes the full finished count so the latch fires for any suite count including 1; regressions = the step-0 REGRESSION campaign (completion-marker assertion) and the verifier `PRG_TEST_SEQUENCE` single-suite check.

### 20. A File Glob Is Not a Distributed-Run Completion Protocol

**Symptom**: CI merges stale shards, reads a partial file, misses a slow task, or treats a configuration-conflict empty shard as green.
**Cause**: Independent tag-only filenames provide neither uniqueness nor an all-writers-complete signal.
**Solution**: Shard names include normalized tag plus raw task index. One report coordinator writes temporary shards, closes/replaces them, and writes an authoritative manifest last. A fresh `RunId` is published in PLC status before execution and embedded in every shard and the manifest; automation accepts only a manifest with the current `RunId`, `publicationComplete = true`, and an explicit `outcome` — file presence alone is never success, and an old successful manifest must be invalidated in preflight. Downstream tooling merges only manifest-listed shards. Infrastructure/configuration errors publish a failed framework testcase when possible.

### 21. "Immutable" Does Not Mean "Visible" Across Cores, and a Stopped Task Cannot Time Itself Out

**Symptom**: A reporter on another core reads a stale or torn view of "finished" suite state; a stopped test task hangs the run forever because its own timeout timer never executes.
**Cause**: Declaring data immutable provides no cross-core memory-ordering guarantee, and any self-evaluated deadline requires the task to still be running.
**Solution**: Two synchronized handoffs carry all cross-task ordering: runners acknowledge the published plan generation before the execution gate opens, and each task publishes a one-shot quiescence record after its final suite-state write. The reporter reads suite state only from quiesced tasks and represents unresponsive tasks with a synthetic infrastructure result (never a partial shard). Detection of a stopped task belongs to *another* clock: a reporter-owned global execution deadline, plus an external verifier watchdog for the case where the reporter itself (or everything) stops. See the Phase 5 design spec §E–§F.

### 22. Reserved-Word Enum Members Compile but Break Save-as-Library

**Symptom**: "Creating Library failed! Object reference not set to an instance of an object." in XAE AND via automation (`SaveAsLibrary` E_POINTER/NRE), while Build succeeds cleanly. Found 2026-07-17; present since the timed suite was authored 2026-05-21 (no library save had been attempted in between — the fault window was invisible).
**Cause**: `E_WaitType` declared a member named `Time`. `TIME` is an IEC 61131-3 reserved type keyword (parser is case-insensitive). With `{attribute 'qualified_only'}` the compiler accepts both the declaration and `E_WaitType.Time` references — but the 4026.21 library packer NREs on any method whose body references the member. Bisection signature: excluding exactly the members referencing the literal makes the save succeed.
**Solution**: Renamed to `E_WaitType.Duration`. The reserved-keyword rule covers **every identifier**: variables, parameters, AND enum members. Scan before authoring new DUTs: `(?i)^\s*(TIME|LTIME|DATE|DT|TOD|TIME_OF_DAY|DATE_AND_TIME)\s*:=` inside `TYPE ... ( ... );` blocks. Diagnostic recipe when the packer NREs with a green build: bisect `<Compile Include>` entries, then members, then stub method bodies — `tpm library save` gives a ~3-minute click-free iteration loop.

### 23. Library Project References Must Resolve Headless

**Symptom**: COM/automation build fails with bare `E_FAIL` ("2 project(s) failed") while interactive XAE builds work; error list (read via typed `EnvDTE80.DTE2`, not dynamic dispatch) shows "Could not open library '#Base'" or "Following library is missing: Tc3_Module".
**Cause**: Two stacked resolution faults: (a) the Base `PlaceholderResolution` pinned `2026.4.8.2`, a version no longer installed on this machine; (b) the plcproj never referenced `Tc3_Module`, which 4026 requires — interactive XAE silently auto-resolves both, headless sessions fail hard.
**Solution**: Keep pins on installed versions (`Base, *` acceptable for this fork; TwinCAT_Tests governs the effective Base) and keep the `Tc3_Module` placeholder in the plcproj. Rebuilding after months of Base evolution REQUIRES a repin — old Base versions get cleaned from the repository.

### 24. A Library Project Needs No Task

**Symptom**: The TcUnit library instance carried Base's `GVL_System.FileHandlerCsv/Json/Xml` EtherCAT-linked input variables ("BuildTask Inputs" in the xti) after rebuilding against 2026.7.x Base.
**Cause**: `BuildTask` (added 2026-04-09) made the build instantiate referenced-library `linkalways` globals, pulling Base's IO-mapped file-handler instances into the library's instance image. Upstream TcUnit's library project has no task — that is the correct shape.
**Solution**: BuildTask removed (tsproj task block, plcproj TcTTO entry, file). The sln was also trimmed to x64-only configurations (fresh COM sessions default to the first configuration alphabetically, which was ARM/CE7). Note: `SaveAsLibrary` automation itself works fine on 4026.21 (`tpm library save`) — the earlier "automation regression" suspicion was actually Gotcha #22's content fault.

### 25. The Trace Pipeline Is Not a Real-Time Observable — Know Its Blind Spots

**Symptom**: 'TEST RUN STARTED' missing from flushed logs on fast campaigns; an honored abort's 'TEST RUN ABORTED' never appearing in any file; the central ring (`GVL_System.RingBufferLog`) reading `WriteIncrement=0` while a run is visibly executing; ring slots reading empty immediately after entries were counted.
**Cause** (all observed 2026-07-17/18 during step-0 A1 work): (a) traces emitted in the first scans are dropped before the trace pipeline is ready; (b) entries reach the file only via the SaveEntryThreshold batch or the TESTS-FINISHED `RequestFlush` — an ABORTED run never reaches that trigger; (c) ADS STOP does not drain the ring to a file, and the restart reinitializes memory, losing pending entries; (d) the LogTask drains and clears ring slots within one of its scans, so post-hoc ADS scans of the ring race the drain and lose.
**Solution**: For deterministic trace-content evidence either force `SAVEENTRYTHRESHOLD=1` for the campaign (the step-0 ABORT selection does this) or assert behavior via ADS state reads instead of trace text. As of TcUnit 2026.7.18.1, aborted and completed are distinct terminal outcomes: the runner emits 'TEST RUN ABORTED' when it HONORS the abort flag (raw online writes included; `AbortRunningTestSuiteTests()` now traces 'TEST RUN ABORT REQUESTED'), and 'TEST RUN COMPLETED', the ADS summary, and xUnit publication are all suppressed after an abort.

### 26. RUN_IN_SEQUENCE Permanently Skips Suites That RETURN Before Calling TEST()

**Symptom**: ADS per-suite results show `tests=0` for a test suite even though the suite has multiple `TEST()` calls and the aggregate test count appears correct. The suite's test methods never execute.
**Cause**: `RUN_IN_SEQUENCE()` advances past a suite after seeing no active tests for a scan. If a test suite uses a multi-scan harness initialization pattern that `RETURN`s from the suite body before calling any test methods (and thus before any `TEST()` calls), TcUnit sees zero active tests on those init scans, marks the suite as done, and never revisits it. The suite is permanently skipped for the remainder of the run.
**Solution**: Never `RETURN` from the suite body before calling test methods. Instead, always call every test method on every scan (which registers them with TcUnit via `TEST()`), and put the init guard *inside* each test method *after* the `TEST()` call:
```iec
// Suite body — no early RETURN
IF NOT bHarnessReady THEN
    // init harness
END_IF
Test_Foo();  // always called, even during init

// Inside each test method:
METHOD Test_Foo
    TEST('Test_Foo');
    IF bDone_Foo THEN RETURN; END_IF
    IF NOT bHarnessReady THEN RETURN; END_IF  // guard AFTER TEST()
    // ... actual test logic ...
    bDone_Foo := TRUE;
    TEST_FINISHED();
```
Working suites like `FB_DispatchClaimTests` follow this pattern — they never gate the `TEST()` registration call behind an init check. Discovered 2026-07-23; affected `FB_OpSeqLifecycleTests` and `FB_CellCycleLifecycleTests` in TwinCAT_Tests (both reported `tests=0` via ADS until fixed).

---

## Architecture Patterns

### TraceWithSeverity Integration Pattern

```
FB_AdsAssertMessageFormatter EXTENDS Base.FB_BaseStatic
    │
    └── LogAssertFailure()   → 'ASSERT FAIL 'path', EXP: val, ACT: val, MSG: msg' (Error)
        └── Called by ALL assert methods (scalar + array) — single trace point for all assertion failures

FB_TestSuite EXTENDS FB_BaseStatic
    │
    ├── SetTestFinished()    → 'TEST PASSED/FAILED: name (0.045s)' (Info/Warning)
    ├── CalculateDuration()  → 'SUITE COMPLETE: path - N passed, N failed, N skipped (Ns)' (Info)
    ├── AddTest() [skipped]  → 'TEST SKIPPED: name' (Info)
    ├── AddTest() [duplicate]→ 'DUPLICATE TEST [name] in suite path' (Warning)
    └── AreAllTestsFinished()→ 'EMPTY TEST SUITE - path' (Warning)

FB_TcUnitRunner EXTENDS FB_BaseStatic
    │
    ├── RunTestSuiteTests()         → 'TEST RUN STARTED - N suite(s), parallel execution' (Info)
    ├── RunTestSuiteTestsInSequence()→ 'TEST RUN STARTED - N suite(s), sequential execution' (Info)
    ├── [both methods]              → 'TEST RUN COMPLETED - N suite(s) finished' (Info)
    └── AbortRunningTestSuiteTests()→ 'TEST RUN ABORTED' (Warning)

FB_AssertResultStatic EXTENDS FB_BaseStatic
    │
    └── AddAssertResult()    → 'SuiteName. Max number of assertions exceeded...' (Error, one-shot)

FB_AssertArrayResultStatic EXTENDS FB_BaseStatic
    │
    └── AddAssertArrayResult()→ 'SuiteName. Max number of assertions exceeded...' (Error, one-shot)

FB_xUnitXmlPublisher EXTENDS FB_BaseStatic IMPLEMENTS I_TestResultLogger
    │
    ├── DeleteOpenWriteClose()→ 'xUnit file I/O failure: path' (Error)
    └── LogTestSuiteResults() → 'xUnit XML exported to path' (Info)

FB_AdsTestResultLogger EXTENDS FB_BaseStatic IMPLEMENTS I_TestResultLogger
    │
    ├── LogTestSuiteResults() [overflow] → 'Test count overflow in suite: name (N > max)' (Error)
    └── LogTestSuiteResults() [complete] → 'TESTS FINISHED - N suites, N passed, N failed' (Info)
```

### Centralized Assert Trace Pattern (via LogAssertFailure)

All assert methods (scalar and array) call `AssertMessageFormatter.LogAssertFailure(Expected, Actual, Message, TestInstancePath)` on failure. The TraceWithSeverity call lives inside that single method on `FB_AdsAssertMessageFormatter`, which now extends `Base.FB_BaseStatic`. This replaced an earlier approach where each of 23 scalar assert methods had to set `_traceExpected`/`_traceActual` instance variables before calling `SetTestFailed`. The centralized approach eliminates ~44 lines of per-method boilerplate and covers array assertions automatically.

### Severity Convention for Test Events

| Severity | Used For |
|----------|----------|
| Error | Assertion failures, buffer overflows, file I/O failures, test count overflow |
| Warning | Test failures (summary), duplicate tests, empty suites, abort |
| Info | Test passes (w/ duration), test skipped, suite complete (w/ counts), run started, run completed, xUnit export success, final test summary |
| Verbose | (reserved for future detailed diagnostics) |

---

## File Map

### Core Files

| File | Purpose |
|------|---------|
| `TcUnit/TcUnit/POUs/FB_TestSuite.TcPOU` | Test suite management, assertions, EXTENDS FB_BaseStatic |
| `TcUnit/TcUnit/POUs/FB_TcUnitRunner.TcPOU` | Test orchestrator, EXTENDS FB_BaseStatic |
| `TcUnit/TcUnit/POUs/FB_AdsAssertMessageFormatter.TcPOU` | ADS assert logging + centralized TraceWithSeverity, EXTENDS Base.FB_BaseStatic |
| `TcUnit/TcUnit/POUs/FB_Test.TcPOU` | Individual test state holder |
| `TcUnit/TcUnit/POUs/FB_TestResults.TcPOU` | Result aggregator |
| `TcUnit/TcUnit/POUs/FB_AdsTestResultLogger.TcPOU` | ADS result output, EXTENDS FB_BaseStatic; overflow + completion traces |
| `TcUnit/TcUnit/POUs/FB_xUnitXmlPublisher.TcPOU` | xUnit XML output, EXTENDS FB_BaseStatic; file I/O error + export success traces |
| `TcUnit/TcUnit/POUs/FB_AssertResultStatic.TcPOU` | Assertion tracking, EXTENDS FB_BaseStatic; overflow trace |
| `TcUnit/TcUnit/POUs/FB_AssertArrayResultStatic.TcPOU` | Array assertion tracking, EXTENDS FB_BaseStatic; overflow trace |
| `TcUnit/TcUnit/POUs/FB_AdsLogStringMessageFifoQueue.TcPOU` | ADS message buffer |

### Config Files

| File | Purpose |
|------|---------|
| `TcUnit/TcUnit/TcUnit.plcproj` | PLC project file; references Base library |
| `TcUnit/TcUnit/GVLs/GVL_TcUnit.TcGVL` | Runtime state and test suite registry |
| `TcUnit/TcUnit/GVLs/GVL_Param_TcUnit.TcGVL` | Tunable parameters (max suites, tests, buffer sizes) |

---

## Common Tasks

### Building TcUnit After Modifications

1. Open `TcUnit.sln` in Visual Studio with TwinCAT XAE
2. Ensure the Base library reference resolves (`Base, * (Photara)`)
3. Build the TcUnit project — check for compile errors especially around `Global.TcEventSeverity` references
4. If InstancePath type mismatch errors appear, verify FB_TestSuite's InstancePath is commented out

### Adding a New TraceWithSeverity Call

1. Identify the FB — it must EXTEND FB_BaseStatic (or FB_BaseCyclic)
2. Find the insertion point using Grep for method names
3. Use `Global.TcEventSeverity.Error/Warning/Info/Verbose` for severity
4. For cyclically-called code, use a one-shot flag or R_TRIG to prevent log spam
5. Test that the ring buffer is being drained (PRG_LOG must be running in the consuming project)

---

## Prompt History

### 2026-02-16 (Session 1)

**Goal**: Integrate TcUnit with Photara Base library's logging infrastructure for structured test result logging to .jsonl/.db files.
**What changed**:
- `FB_TestSuite.TcPOU`: Added `EXTENDS FB_BaseStatic`, commented out InstancePath, added `EmptySuiteTraced` VAR, added 5 TraceWithSeverity calls (SetTestFailed, SetTestFinished, AddTest duplicate, AddTest skipped, AreAllTestsFinished empty)
- `FB_TcUnitRunner.TcPOU`: Added `EXTENDS FB_BaseStatic`, added 4 TraceWithSeverity calls (RunTestSuiteTests start, RunTestSuiteTestsInSequence start, both completion, AbortRunningTestSuiteTests)
- `TcUnit.plcproj`: Base library reference added
**Gotchas hit**: InstancePath shadowing (Gotcha #1), Initialize() not needed (Gotcha #2), cyclic call spam (Gotcha #3), duplicate code blocks in runner (Gotcha #4), large file reads (Gotcha #5)

### 2026-02-16 (Session 1, continued)

**Goal**: Enrich trace data with expected/actual values, test duration, and suite summary (Phase 3).
**What changed**:
- `FB_TestSuite.TcPOU`: Added `_traceExpected`/`_traceActual` instance VARs. Modified 23 scalar assert methods to set trace context before SetTestFailed. Enriched SetTestFailed trace. Added duration to SetTestFinished traces. Added suite completion summary trace in CalculateDuration.
- Created RepoBaseDocs: PROJECT_STATE.md, EXECUTION_PLAN.md, BREADCRUMBS.md, TASK_BRIEFS.md, OPEN_DECISIONS.md, DOCS_STRATEGY.md

### 2026-02-19 (Session 2)

**Goal**: Centralize assertion failure tracing into `LogAssertFailure` instead of scattering across 23+ Assert methods.
**What changed**:
- `FB_AdsAssertMessageFormatter.TcPOU`: Changed to `EXTENDS Base.FB_BaseStatic`. Added `TraceWithSeverity` call inside `LogAssertFailure()` — single centralized trace point for all assertion failures (scalar + array).
- `FB_TestSuite.TcPOU`: Removed `_traceExpected`/`_traceActual` instance VAR declarations. Removed 42 lines of `_traceExpected`/`_traceActual` assignments from 21 scalar Assert methods. Removed `TraceWithSeverity` call from `SetTestFailed` (now redundant — `LogAssertFailure` handles it).
**Design insight**: Every Assert method already calls `LogAssertFailure(Expected, Actual, Message, TestInstancePath)` with string-converted values. Putting the trace there eliminates all per-method boilerplate. The `_traceExpected`/`_traceActual` instance-variable relay pattern was an unnecessary indirection.
**Future optimization ideas**:
- ~~Consider extending `FB_AdsTestResultLogger`, `FB_xUnitXmlPublisher`, `FB_AssertResultStatic`, `FB_AssertArrayResultStatic` with `FB_BaseStatic` for error tracing~~ **Done (Phase 2)**
- `LogAssertFailure` could be extended to trace passing assertions too (Info severity) for full assertion audit trails — would require a new `LogAssertSuccess` method or a pass/fail parameter
- The `AssertMessageFormatter` is injected as `I_AssertMessageFormatter` — if a non-ADS implementation is ever needed, it would also need `TraceWithSeverity` capability (or the interface could be extended)

### 2026-02-19 (Session 2, continued)

**Goal**: Phase 2 — Extend remaining 4 FBs with FB_BaseStatic and add TraceWithSeverity.
**What changed**:
- `FB_AssertResultStatic.TcPOU`: Added `EXTENDS FB_BaseStatic`; added TraceWithSeverity at assert buffer overflow (Error, one-shot via existing `AssertResultOverflow` flag). Corrected typo in dead-code method `GetDetectionCountThisCycle()` (`.Message = TestInstancePath` → `.TestInstancePath = TestInstancePath`) — no runtime impact since the method is never called.
- `FB_AssertArrayResultStatic.TcPOU`: Added `EXTENDS FB_BaseStatic`; added TraceWithSeverity at array assert buffer overflow (Error, one-shot).
- `FB_xUnitXmlPublisher.TcPOU`: Added `EXTENDS FB_BaseStatic IMPLEMENTS I_TestResultLogger`; added TraceWithSeverity at file I/O failure in DeleteOpenWriteClose (Error) and export success in LogTestSuiteResults (Info).
- `FB_AdsTestResultLogger.TcPOU`: Added `EXTENDS FB_BaseStatic IMPLEMENTS I_TestResultLogger`; added TraceWithSeverity at test count overflow (Error) and final results complete (Info).
**Pattern**: All traces are additive — existing ADS logging unchanged. Error traces use existing one-shot flags where available.
