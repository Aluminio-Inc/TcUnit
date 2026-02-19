# Development Breadcrumbs

**Last Updated**: 2026-02-19

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
