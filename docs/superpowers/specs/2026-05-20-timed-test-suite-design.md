# FB_TimedTestSuite — Real-Time Elapsed Testing for TcUnit

**Date:** 2026-05-20 (revised 2026-05-21)
**Status:** Draft v4
**Scope:** TcUnitFork (C:\Users\scott\Documents\TcUnitFork)

## Problem

TcUnit tests execute cyclically and complete in milliseconds. There is no built-in way to write a test that intentionally waits for real wall-clock time to pass on the PLC, then asserts on the outcome. This makes it impossible to validate time-dependent FB behavior under real runtime conditions — command timeouts, TON/TOF/TP timers, debounce filters, sequencer timing — without hand-rolling CASE state machines with manual timing logic in every test method.

The downstream `FB_TestTimeProvider` / `I_TimeProvider` pattern (defined in TwinCAT_Base, not in this repo) handles deterministic unit tests by injecting a fake clock and advancing it precisely. This feature addresses the complementary case: queue up a bank of real-time tests and walk away. Come back minutes or hours later to results.

## Solution

A new `FB_TimedTestSuite` that extends `FB_TestSuite`, adding per-test wait state tracked internally by the suite. Consumer test suites extend this instead of `FB_TestSuite`. Each test gets one wait point (setup → wait → assert → done) and a safety timeout to prevent the bank from hanging.

## Design Decisions

1. **Separate suite type, not mixed into FB_TestSuite.** Timed suites are explicitly different — the runner can identify them, report differently, and the 3800-line FB_TestSuite stays untouched except for one access modifier change.

2. **One wait per test.** No ordinal tracking, no chained waits. Multi-checkpoint scenarios are split into separate tests (e.g., "still busy at 5s" and "timeout at 10s" are two tests). Tests that share DUT state across checkpoints MUST use `TEST_TIMED_ORDERED` or isolated fixture instances (see Fixture Isolation below).

3. **Suite manages all wait state.** No FBs instantiated in test methods. Wait state lives in a `ST_TimedTestState` array on the suite, indexed parallel to the existing `Tests[]` array. Wait parameters are latched on first call — subsequent cycles' parameter values are ignored.

4. **CPU counter timing.** Uses the same `F_GetCpuCounterAs64bit()` / `HundredNanosecondToSecond` infrastructure TcUnit already uses for test duration measurement. 100ns precision.

5. **Safety timeout auto-fails.** Every test registered via `TEST_TIMED` or `TEST_TIMED_ORDERED` declares a safety timeout. If `TEST_FINISHED()` is not called within that window, the framework auto-fails the test with full TcUnit bookkeeping (assertion count, duration, xUnit reporting) and moves on. This guarantees completion for all timed-managed tests. Tests registered via plain `TEST()` that misuse wait helpers are NOT covered by this guarantee and may hang (see Edge Case 3).

6. **TEST_TIMED returns BOOL to gate execution.** Follows the `TEST_ORDERED` pattern — the caller wraps the test body in `IF TEST_TIMED(...) THEN ... END_IF`. When safety timeout fires, the test is finished/skipped, or `IgnoreCurrentTest` is set, subsequent calls return FALSE, preventing further DUT mutation.

7. **Latched timed-test context with explicit lifecycle.** The suite tracks `_nActiveTimedTestIdx` which is reset to 0 at the entry of every `TEST_TIMED` / `TEST_TIMED_ORDERED` call before lookup, then set to the resolved index on success. Wait methods called between test methods (after the last TEST_TIMED returns but before the next is entered) hit `_nActiveTimedTestIdx = 0` and fail. This is best-effort detection, not a guarantee — out-of-context wait calls during the same scan after the final test method may still bind to the last test's index. This is documented as undefined behavior; the correct pattern is to only call wait methods inside an `IF TEST_TIMED(...) THEN ... END_IF` block.

8. **Wait misuse auto-fails, never silently passes.** A wait called without timed-test context returns FALSE and traces an Error — it blocks the test body from proceeding but cannot fail a specific test. A wait with a type mismatch (WaitForTime after WaitForCondition or vice versa) auto-fails the identified test with `Type_WAIT_MISUSE` and returns FALSE. Either way, misuse produces red or stalls, never a false green.

## Data Model

### ST_TimedTestState

```
TYPE ST_TimedTestState :
STRUCT
    // Safety timeout
    tSafetyTimeout     : TIME;     // Latched from first TEST_TIMED call
    nSafetyStartTime   : LWORD;    // CPU counter when test first entered
    bSafetyTimedOut    : BOOL;     // Safety timeout fired -> test auto-failed
    bInitialized       : BOOL;     // First-call initialization done

    // Wait state (one wait per test)
    nWaitStartTime     : LWORD;    // 0 = not started, >0 = active wait
    bWaitComplete      : BOOL;     // Wait finished (pass-through on subsequent cycles)
    bConditionTimedOut : BOOL;     // WaitForCondition expired before condition met
    eWaitType          : E_WaitType; // None, Time, Condition — latched on first wait call
    tLatchedDuration   : TIME;     // Duration/timeout latched on first wait call
END_STRUCT
END_TYPE
```

### E_WaitType

```
TYPE E_WaitType :
(
    None      := 0,
    Time      := 1,
    Condition := 2
);
END_TYPE
```

### ST_TimedTestResult (verifier read-only surface)

```
TYPE ST_TimedTestResult :
STRUCT
    TestName           : T_MaxString;
    bIsFailed          : BOOL;
    bIsSkipped         : BOOL;
    bIsFinished        : BOOL;
    sFailureMessage    : T_MaxString;
    eFailureType       : E_AssertionType;
    nNumberOfAsserts   : UINT;
    lrDuration         : LREAL;        // seconds
    stTimedState       : ST_TimedTestState;
END_STRUCT
END_TYPE
```

### FB_TimedTestSuite

```
FUNCTION_BLOCK FB_TimedTestSuite EXTENDS FB_TestSuite
VAR
    TimedTestStates      : ARRAY[1..GVL_Param_TcUnit.MaxNumberOfTestsForEachTestSuite]
                           OF ST_TimedTestState;
    _nActiveTimedTestIdx : UINT;   // 0 = no active timed test; >0 = index into Tests[]/TimedTestStates[]
END_VAR
```

## API

### TEST_TIMED (method on FB_TimedTestSuite)

```
METHOD PUBLIC TEST_TIMED : BOOL
VAR_INPUT
    TestName       : T_MaxString;
    tSafetyTimeout : TIME;
END_VAR
```

**Returns:** `TRUE` when the test body should execute. `FALSE` when the test is finished, timed out, skipped, ignored, or should not run.

**Behavior (called every cycle at top of test method):**

1. **Reset context.** Set `_nActiveTimedTestIdx := 0` (clear stale context from previous test method in this scan).
2. **Trim name.** `TestName := F_LTrim(F_RTrim(TestName))` (matches TEST_ORDERED behavior).
3. **Register test.** Call the free function `TEST(TestName)` to register the test. This sets `GVL_TcUnit.CurrentTestNameBeingCalled` and invokes `AddTest()` on the current suite.
4. **Check skip/ignore.** If `GVL_TcUnit.IgnoreCurrentTest = TRUE` (disabled test via `'disabled_'` prefix, same-cycle duplicate name, or other TcUnit ignore conditions): do NOT initialize timed state, return `FALSE`.
5. **Find test index.** Search `Tests[]` by name to find the index. Store in `_nActiveTimedTestIdx`.
6. **Check already finished.** If `bSafetyTimedOut` is TRUE OR test is already finished (via `TEST_FINISHED()`): set `GVL_TcUnit.CurrentTestIsFinished := TRUE`, return `FALSE`.
7. **Initialize on first call** (`bInitialized = FALSE`): record `nSafetyStartTime := F_GetCpuCounterAs64bit()`, latch `tSafetyTimeout` into `TimedTestStates[idx].tSafetyTimeout`, set `bInitialized := TRUE`.
8. **Check safety timeout.** Compute elapsed: `(F_GetCpuCounterAs64bit() - nSafetyStartTime) * HundredNanosecondToSecond`. Compare against the **stored** field: `TIME_TO_LREAL(TimedTestStates[idx].tSafetyTimeout) / 1000.0`. If exceeded:
   - Call `SetTestFailed(E_AssertionType.Type_TIMEOUT, 'SAFETY TIMEOUT: Test exceeded Xs')`.
   - Call `SetTestFinished(TestName, F_GetCpuCounterAs64bit())`.
   - Call `CalculateAndSetNumberOfAssertsForTest(TestName)`.
   - Set `bSafetyTimedOut := TRUE`.
   - Set `GVL_TcUnit.CurrentTestIsFinished := TRUE`.
   - Trace at Warning severity: `'SAFETY TIMEOUT: Test "name" exceeded Xs'`.
   - Return `FALSE`.
9. Return `TRUE` (test body should execute).

Note: `SetStartedAtIfNotSet` is already called by the free function `TEST()` in step 3 (TEST.TcPOU line 27). No duplicate call is needed here.

**Caller pattern:**
```
IF TEST_TIMED('My test', T#15S) THEN
    // test body — only executes when TRUE
    TEST_FINISHED();
END_IF
```

### TEST_TIMED_ORDERED (method on FB_TimedTestSuite)

```
METHOD PUBLIC TEST_TIMED_ORDERED : BOOL
VAR_INPUT
    TestName       : T_MaxString;
    tSafetyTimeout : TIME;
END_VAR
VAR
    CounterTestSuiteAddress : UINT;
    SuiteIndex              : UINT;
    Test                    : REFERENCE TO FB_Test;
END_VAR
```

Combines `TEST_ORDERED` sequencing semantics with `TEST_TIMED` safety timeout and wait capability. Tests execute one at a time within the suite — the next ordered timed test does not begin until the current one finishes.

**Behavior (called every cycle at top of test method):**

This method replicates the exact algorithm of `TEST_ORDERED` (TcUnit/POUs/Functions/TEST_ORDERED.TcPOU lines 34-82) and adds safety timeout logic. Each step maps to the original:

1. **Reset context.** Set `_nActiveTimedTestIdx := 0`.
2. **Trim name.** `TestName := F_LTrim(F_RTrim(TestName))` (matches TEST_ORDERED line 34).
3. **Set global test name.** `GVL_TcUnit.CurrentTestNameBeingCalled := TestName` (matches line 37).
4. **Find suite in runner registry.** Iterate `GVL_TcUnit.TestSuiteAddresses[1..NumberOfInitializedTestSuites]`, find the entry where `TestSuiteAddresses[CounterTestSuiteAddress] = GVL_TcUnit.CurrentTestSuiteBeingCalled`. Store the matched loop index as `SuiteIndex := CounterTestSuiteAddress`. If not found: return `FALSE`.
5. **Register as ordered test.** `Test REF= TestSuiteAddresses[SuiteIndex]^.AddTest(TestName, IsTestOrdered := TRUE)` (matches line 48).
6. **Set CurrentTestIsFinished.** `GVL_TcUnit.CurrentTestIsFinished := TestSuiteAddresses[SuiteIndex]^.IsTestFinished(TestName)` (matches line 49).
7. **Check skip/ignore.** If `GVL_TcUnit.IgnoreCurrentTest = TRUE`: return `FALSE` (matches lines 76-78).
8. **Check ordered cursor.** Compare `GetTestOrderNumber(TestName)` against `GVL_TcUnit.CurrentlyRunningOrderedTestInTestSuite[SuiteIndex]`:
   - **Not this test's turn** (order number != cursor): set `GVL_TcUnit.IgnoreCurrentTest := TRUE`, return `FALSE` (matches lines 70-73).
   - **This test's turn AND already finished** (`CurrentTestIsFinished = TRUE`): advance cursor `CurrentlyRunningOrderedTestInTestSuite[SuiteIndex] += 1`, set `IgnoreCurrentTest := TRUE`, return `FALSE` (matches lines 58-62).
   - **This test's turn AND not finished**: proceed to timed-test logic below.
9. **Find timed test index.** Search `Tests[]` by name. Store in `_nActiveTimedTestIdx`.
10. **Check already timed out.** If `TimedTestStates[_nActiveTimedTestIdx].bSafetyTimedOut` is TRUE: set `CurrentTestIsFinished := TRUE`, return `FALSE`.
11. **Initialize on first call** (`bInitialized = FALSE`): record `nSafetyStartTime := F_GetCpuCounterAs64bit()`, latch `tSafetyTimeout` into `TimedTestStates[idx].tSafetyTimeout`, set `bInitialized := TRUE`.
12. **Check safety timeout.** Compare elapsed against **stored** `TimedTestStates[idx].tSafetyTimeout`. If exceeded: same auto-fail bookkeeping as TEST_TIMED step 8. Return `FALSE`.
13. **Set started timestamp.** If `__ISVALIDREF(Test)`: `Test.SetStartedAtIfNotSet(F_GetCpuCounterAs64bit())` (matches line 66).
14. Return `TRUE`.

**Caller pattern:**
```
IF TEST_TIMED_ORDERED('Step 1: busy at 5s', T#10S) THEN
    // executes only when it's this test's turn in the ordered sequence
    TEST_FINISHED();
END_IF
```

### WaitForTime (method on FB_TimedTestSuite)

```
METHOD PUBLIC WaitForTime : BOOL
VAR_INPUT
    tDuration : TIME;
END_VAR
```

**Returns:** `TRUE` when wait is complete. `FALSE` while still waiting or on error.

**Precondition:** Must be called inside a `TEST_TIMED` or `TEST_TIMED_ORDERED` block.

**Behavior:**

1. **Context check.** If `_nActiveTimedTestIdx = 0`: trace Error `'WaitForTime called without active timed test context'`. Return `FALSE` (block execution — cannot identify a test to fail).
2. If `bWaitComplete = TRUE`: return `TRUE` (pass-through for subsequent cycles).
3. **Type mismatch check.** If `eWaitType = Condition`: auto-fail the test via `SetTestFailed(E_AssertionType.Type_WAIT_MISUSE, 'WaitForTime called but WaitForCondition already active')`, `SetTestFinished(...)`, `CalculateAndSetNumberOfAssertsForTest(...)`, `GVL_TcUnit.CurrentTestIsFinished := TRUE`. Return `FALSE`.
4. If `nWaitStartTime = 0` (first call):
   - Latch: `eWaitType := Time`, `tLatchedDuration := tDuration`.
   - Record `nWaitStartTime := F_GetCpuCounterAs64bit()`.
   - Trace at Verbose: `'Wait started: Xs for test "name"'`.
   - Return `FALSE`.
5. Compute elapsed seconds: `lrElapsed := (F_GetCpuCounterAs64bit() - nWaitStartTime) * HundredNanosecondToSecond`.
6. Convert latched duration to seconds: `lrDuration := TIME_TO_LREAL(tLatchedDuration) / 1000.0`.
7. If `lrElapsed < lrDuration`: return `FALSE`.
8. Set `bWaitComplete := TRUE`. Trace at Info: `'Wait completed: Xs elapsed for test "name"'`. Return `TRUE`.

### WaitForCondition (method on FB_TimedTestSuite)

```
METHOD PUBLIC WaitForCondition : BOOL
VAR_INPUT
    bCondition : BOOL;
    tTimeout   : TIME;
END_VAR
```

**Returns:** `TRUE` when either condition is met or timeout fires. `FALSE` while waiting or on error.

**Precondition:** Same as WaitForTime — requires active timed test context.

**Behavior:**

1. **Context check.** If `_nActiveTimedTestIdx = 0`: trace Error, return `FALSE`.
2. If `bWaitComplete = TRUE`: return `TRUE` (pass-through).
3. **Type mismatch check.** If `eWaitType = Time`: auto-fail the test via `SetTestFailed(E_AssertionType.Type_WAIT_MISUSE, ...)`, `SetTestFinished(...)`, `CalculateAndSetNumberOfAssertsForTest(...)`, `GVL_TcUnit.CurrentTestIsFinished := TRUE`. Return `FALSE`.
4. **Check condition before starting wait.** If `bCondition = TRUE` AND `nWaitStartTime = 0` (first call, condition already met): set `bWaitComplete := TRUE`, `bConditionTimedOut := FALSE`, `eWaitType := Condition`. Trace at Info. Return `TRUE`. (Immediate completion — no wait needed.)
5. If `nWaitStartTime = 0` (first call, condition not yet met):
   - Latch: `eWaitType := Condition`, `tLatchedDuration := tTimeout`.
   - Record `nWaitStartTime := F_GetCpuCounterAs64bit()`.
   - Trace at Verbose.
   - Return `FALSE`.
6. If `bCondition = TRUE`: set `bWaitComplete := TRUE`, `bConditionTimedOut := FALSE`. Trace at Info. Return `TRUE`.
7. Compute elapsed. If elapsed >= `TIME_TO_LREAL(tLatchedDuration) / 1000.0`: set `bWaitComplete := TRUE`, `bConditionTimedOut := TRUE`. Trace at Warning: `'WaitForCondition timed out after Xs for test "name"'`. Return `TRUE`.
8. Return `FALSE`.

### WaitTimedOut (property on FB_TimedTestSuite)

```
PROPERTY PUBLIC WaitTimedOut : BOOL   // GET only
```

Returns `bConditionTimedOut` for the current test (via `_nActiveTimedTestIdx`). Used after `WaitForCondition` to distinguish "condition met" from "gave up."

### GetTimedTestResult (public read-only accessor)

```
METHOD PUBLIC GetTimedTestResult : ST_TimedTestResult
VAR_INPUT
    TestName : T_MaxString;
END_VAR
```

Returns a copy of the test result + timed state for a named test. This is the **sole public inspection API** for the Level 2 verifier. Internally it finds the test by name, reads from `Tests[]` (name, failed, skipped, finished, failure message, failure type, assertion count, duration) and `TimedTestStates[]` (timed state copy), and returns the composite struct.

If the test name is not found, returns a zeroed struct with empty `TestName`.

## Runner Integration

No changes to `FB_TcUnitRunner`. The runner already operates on `POINTER TO FB_TestSuite`. Since `FB_TimedTestSuite EXTENDS FB_TestSuite`, it registers identically via `FB_init` and is called identically via `Suite^()`.

Timed suites simply take longer to report `AreAllTestsFinished() = TRUE`. The runner loops until all suites (fast and timed) complete. This is the "queue up and walk away" behavior.

`RUN_IN_SEQUENCE` also works — timed suites block the sequence until their tests finish, which is correct (you don't want the next suite to start while timed tests are still waiting).

## Fixture Isolation

When splitting multi-checkpoint scenarios into separate tests, the tests run in parallel within a suite (standard TcUnit behavior). This creates races if tests share DUT state. Two solutions:

**Option A: Isolated fixture instances (recommended for most cases).** Each test operates on its own DUT instance, indexed by test. This is the pattern shown in the examples — `Component[0]` for test 0, `Component[1]` for test 1, etc. Tests are independent and can run in any order.

**Option B: TEST_TIMED_ORDERED for shared state.** When tests must observe the same DUT at different time points (e.g., "DUT enters state X at 5s" then "DUT enters state Y at 10s"), use `TEST_TIMED_ORDERED` so they execute sequentially. The first test finishes before the second starts.

The examples in this spec use Option A exclusively. Option B is available but should be reserved for cases where fixture duplication is impractical.

## Tracing

Follows existing Photara Base patterns with `TraceWithSeverity`:

| Event | Severity | One-shot guard |
|-------|----------|----------------|
| Wait started | Verbose | `nWaitStartTime` transition from 0 |
| Wait completed (time) | Info | `bWaitComplete` flag |
| Wait completed (condition met) | Info | `bWaitComplete` flag |
| Wait completed (condition timed out) | Warning | `bWaitComplete` flag |
| Safety timeout fired | Warning | `bSafetyTimedOut` flag |
| Wait called without timed test context | Error | (none — always fires, indicates programming error) |
| Wait type mismatch (auto-fail) | Error | (once — test is failed and finished) |

All trace messages include the test name and elapsed time for diagnostic context.

## Edge Cases

1. **`WaitForTime(T#0S)`**: Elapsed is always >= 0, so completes on the first elapsed check (second cycle). Effectively a one-cycle delay.

2. **Safety timeout < wait duration**: Safety timeout fires first. `TEST_TIMED` returns `FALSE` on the next cycle, gating the entire test body including the `WaitForTime` call. The test is marked failed with `Type_TIMEOUT` and full bookkeeping. The bank continues.

3. **Wait called without `TEST_TIMED`**: `_nActiveTimedTestIdx` is 0. Wait method traces an Error and returns `FALSE` (blocks execution — the code after the wait does not run). Since the test was registered via plain `TEST()` not `TEST_TIMED`, it has no safety timeout. If the test method has no other exit path, it will run every cycle indefinitely without calling `TEST_FINISHED`, and the suite's `AreAllTestsFinished()` will never return TRUE. This is a programming error — wait methods are only valid inside timed test blocks.

4. **Wait type switch (WaitForTime then WaitForCondition)**: `eWaitType` is latched on first wait call. A second wait call of a different type auto-fails the test with `Type_WAIT_MISUSE` and full bookkeeping. The test reports red with a clear message identifying the type conflict.

5. **Duration/timeout changes across scans**: `tLatchedDuration` is set on the first wait call and used for all subsequent comparisons. Parameter values on later cycles are ignored.

6. **`WaitForCondition(TRUE, T#5S)` on first call**: Condition is checked BEFORE starting the wait. Since condition is already TRUE, completes immediately — returns `TRUE` on the first call. No wait is started.

7. **PLC cycle time jitter**: Wait duration accuracy is bounded by the PLC task cycle time. A `WaitForTime(T#10S)` on a 10ms task completes within 10ms of the target. For tests asserting on timing behavior, build in tolerance (e.g., wait 10.5s for a 10s timeout).

8. **No `TEST_FINISHED` call after wait completes**: Safety timeout eventually fires. `TEST_TIMED` returns `FALSE`, gating the body. Test is auto-failed with full bookkeeping. The bank continues.

9. **Second `WaitForTime` call after wait completes (one-wait violation)**: `bWaitComplete` is already TRUE, so returns `TRUE` immediately (pass-through). Code after the second "wait" executes without delay. This is harmless but misleading — trace a Verbose message: `'Wait already completed for test "name" — pass-through'`.

10. **Disabled test (`'disabled_'` prefix)**: `TEST()` / `AddTest()` sets `IgnoreCurrentTest := TRUE`. `TEST_TIMED` checks this in step 4 and returns `FALSE` before initializing any timed state. No safety timeout is armed. No wait state is allocated. The test is reported as skipped via standard TcUnit paths.

11. **Duplicate test name in same cycle**: `AddTest()` sets `IgnoreCurrentTest := TRUE` for the duplicate. `TEST_TIMED` returns `FALSE` in step 4. Same behavior as standard `TEST()`.

12. **Out-of-context wait after final test method in a scan**: `_nActiveTimedTestIdx` retains the last test's index until the next `TEST_TIMED` call resets it. A stray wait call in this window would bind to the last test. This is documented as undefined behavior — wait methods must only be called inside `IF TEST_TIMED(...) THEN ... END_IF`.

13. **Safety timeout input changes across scans**: `tSafetyTimeout` is latched in `TimedTestStates[idx].tSafetyTimeout` on first call (step 7). The safety check in step 8 compares against the stored value. Subsequent calls' `tSafetyTimeout` input values are ignored.

## File Changes

### New Files

| File | Type | Description |
|------|------|-------------|
| `DUTs/ST_TimedTestState.TcDUT` | Data type | Per-test wait state struct |
| `DUTs/ST_TimedTestResult.TcDUT` | Data type | Read-only composite for verifier inspection |
| `DUTs/E_WaitType.TcDUT` | Enum | Wait type discriminator (None, Time, Condition) |
| `POUs/FB_TimedTestSuite.TcPOU` | Function block | Extends FB_TestSuite with TEST_TIMED, TEST_TIMED_ORDERED, WaitForTime, WaitForCondition, WaitTimedOut, GetTimedTestResult |

### Modified Files

| File | Change |
|------|--------|
| `TcUnit.plcproj` | Add `<Compile Include>` entries for new files |
| `POUs/FB_TestSuite.TcPOU` | Change `SetTestFailed` from `METHOD PRIVATE` to `METHOD INTERNAL` (one-word change, line 3777) |
| `DUTs/E_AssertionType.TcDUT` | Add `Type_TIMEOUT` and `Type_WAIT_MISUSE` values |
| `POUs/Functions/F_AssertionTypeToString.TcPOU` | Add CASE branches for `Type_TIMEOUT => 'TIMEOUT'` and `Type_WAIT_MISUSE => 'WAIT_MISUSE'` |

### No Changes Required

| File | Reason |
|------|--------|
| `FB_TcUnitRunner.TcPOU` | Works polymorphically via pointer |
| `FB_Test.TcPOU` | No changes — safety timeout calls existing INTERNAL methods on FB_TestSuite |
| `GVL_TcUnit.TcGVL` | No new globals needed |
| `GVL_Param_TcUnit.TcGVL` | No new parameters (safety timeout is per-test) |
| `FB_xUnitXmlPublisher.TcPOU` | Already emits `<failure>` for any non-UNDEFINED type — `Type_TIMEOUT` and `Type_WAIT_MISUSE` work automatically via `F_AssertionTypeToString` |

## Test Strategy

Testing a test framework extension requires a two-level validation approach, since a self-referential "intentionally failing test" just makes the suite red without proving the framework is correct.

### Level 1: Green-path validation (self-referential TcUnit tests)

Write test suites in TwinCAT_Tests that extend `FB_TimedTestSuite` and validate behaviors that result in passing tests:

- `WaitForTime(T#1S)` completes after ~1 second (assert elapsed within tolerance)
- `WaitForCondition(TRUE, T#5S)` completes immediately on first call (`WaitTimedOut() = FALSE`)
- `WaitForCondition(FALSE, T#1S)` completes after ~1s with `WaitTimedOut() = TRUE`
- Multiple tests in one timed suite run correctly with isolated fixtures
- Timed suites coexist with fast suites in the same runner
- `TEST_TIMED_ORDERED` tests execute in declared order

These tests take a few seconds total (short real-time durations) and produce an all-green suite.

### Level 2: Verifier-style validation (safety timeout and failure paths)

**Scope:** Level 2 is **local framework validation only** — used during development of FB_TimedTestSuite itself. The subject suite's intentional failures are aggregated into the overall TcUnit run by `FB_TestResults` (line 108), making the run red by design. This is not suitable for CI pass/fail gating. For CI-clean validation of failure paths, use the existing .NET TcUnit-Verifier external harness, which is out of scope for this feature.

**In-PLC mechanism:**

1. **Subject suite** (`FB_TimedTestSubject EXTENDS FB_TimedTestSuite`): Contains intentionally broken timed tests — e.g., a test with `tSafetyTimeout := T#2S` that never calls `TEST_FINISHED`, a test that calls `WaitForTime` then `WaitForCondition` (type mismatch), a disabled timed test.

2. **Verifier suite** (`FB_TimedTestVerifier EXTENDS FB_TestSuite`): A standard fast test suite that holds a `POINTER TO FB_TimedTestSubject` (wired via suite-level VAR initialization or FB_init). Each verifier test method:
   - Checks `SubjectSuite^.AreAllTestsFinished()` (PUBLIC method on FB_TestSuite). If FALSE, returns without asserting (waits for subject to complete).
   - Once TRUE, calls `SubjectSuite^.GetTimedTestResult(TestName)` — the **sole public inspection API** — for each subject test it wants to verify.
   - Asserts on the returned `ST_TimedTestResult`: `bIsFailed`, `sFailureMessage` contains `'SAFETY TIMEOUT'`, `eFailureType = Type_TIMEOUT`, `nNumberOfAsserts` preserved, `stTimedState.bSafetyTimedOut = TRUE`.

Both suites register with the same runner. The verifier's tests stay "running" (no `TEST_FINISHED`) until the subject completes, then assert and finish. The overall run is red (subject failures are counted), but the verifier suite itself is green if and only if the subject produced the expected failures. The developer inspects the verifier suite's results, not the aggregate.

## Example: Complete Timed Test Suite

All test-specific state (DUT instances, setup flags, FBs under test) is declared as suite-level VARs — not method-local VARs. This follows TcUnit's multi-cycle testing guidance (see FAQ Section 1). Each test uses an isolated fixture instance via array indexing.

```
FUNCTION_BLOCK FB_CommandTimingTests EXTENDS FB_TimedTestSuite

VAR
    Component    : ARRAY[0..3] OF FB_TestComponent;
    iCmd         : ARRAY[0..3] OF I_Command;
    bSetup       : ARRAY[0..3] OF BOOL;
    fbTon        : TON;
    Sequencer    : FB_TestSequencer;
END_VAR
```

```
METHOD Test_Timeout_At_10s
IF TEST_TIMED('Command fires RequestTimeout at 10s', tSafetyTimeout := T#15S) THEN

    IF NOT bSetup[0] THEN
        Component[0].TM_ConfigureCommandSlot(0, tTimeout := T#10S);
        Component[0].ExecuteCommand(CmdIndex := 0);
        iCmd[0] := Component[0].TM_GetCommand(0);
        bSetup[0] := TRUE;
    END_IF

    Component[0].CyclicLogic();

    IF NOT WaitForTime(T#10500MS) THEN RETURN; END_IF

    Component[0].CyclicLogic();
    AssertEquals_DINT(E_CommandResult.RequestTimeout, iCmd[0].Result,
        'Should be RequestTimeout');
    AssertTrue(iCmd[0].BaseStatus.Error, 'Should be in error state');
    AssertFalse(iCmd[0].BaseStatus.Busy, 'Should not be busy');
    TEST_FINISHED();

END_IF
```

```
METHOD Test_StillBusy_At_5s
IF TEST_TIMED('Command still busy at 5s (timeout is 10s)', tSafetyTimeout := T#10S) THEN

    IF NOT bSetup[1] THEN
        Component[1].TM_ConfigureCommandSlot(0, tTimeout := T#10S);
        Component[1].ExecuteCommand(CmdIndex := 0);
        iCmd[1] := Component[1].TM_GetCommand(0);
        bSetup[1] := TRUE;
    END_IF

    Component[1].CyclicLogic();

    IF NOT WaitForTime(T#5S) THEN RETURN; END_IF

    Component[1].CyclicLogic();
    AssertTrue(iCmd[1].BaseStatus.Busy, 'Should still be busy at 5s');
    AssertEquals_DINT(E_CommandResult.Accepted, iCmd[1].Result,
        'Should still be Accepted');
    TEST_FINISHED();

END_IF
```

```
METHOD Test_Sequencer_Completes_Within_30s
IF TEST_TIMED('Sequencer reaches Complete', tSafetyTimeout := T#45S) THEN

    IF NOT bSetup[2] THEN
        Sequencer.Start();
        bSetup[2] := TRUE;
    END_IF

    Sequencer.CyclicLogic();

    IF NOT WaitForCondition(Sequencer.IsComplete, T#30S) THEN RETURN; END_IF

    IF WaitTimedOut() THEN
        AssertTrue(FALSE, 'Sequencer did not complete in 30s');
    ELSE
        AssertEquals_DINT(200, Sequencer.Result, 'Should be Ok');
    END_IF
    TEST_FINISHED();

END_IF
```

```
METHOD Test_TON_Fires_At_500ms
IF TEST_TIMED('TON output TRUE after 500ms', tSafetyTimeout := T#2S) THEN

    fbTon(IN := TRUE, PT := T#500MS);

    IF NOT WaitForTime(T#600MS) THEN RETURN; END_IF

    AssertTrue(fbTon.Q, 'TON output should be TRUE');
    TEST_FINISHED();

END_IF
```

## Revision History

| Date | Change | Motivation |
|------|--------|------------|
| 2026-05-20 | Initial draft | — |
| 2026-05-21 | v2: Address 9 review findings | SetTestFailed access + Type_TIMEOUT. TEST_TIMED returns BOOL. Latched test context. WaitForCondition immediate-completion. Full bookkeeping on safety timeout. Fixture isolation + TEST_TIMED_ORDERED. Suite-level VARs in examples. Latched wait params + type guard. Two-level verifier test strategy. |
| 2026-05-21 | v3: Address 6 follow-up findings | IgnoreCurrentTest gate. _nActiveTimedTestIdx lifecycle. Concrete verifier mechanism. Full TEST_TIMED_ORDERED algorithm. Wait misuse auto-fails. Example cleanup. |
| 2026-05-21 | v4: Address 5 precision findings | Finding 1: Level 2 verifier scoped to local-only validation, red run explicitly acknowledged. Finding 2: Sole public inspection API via GetTimedTestResult + ST_TimedTestResult struct, no reliance on INTERNAL methods. Finding 3: TEST_TIMED_ORDERED fully specified with line-by-line correspondence to TEST_ORDERED source, SuiteIndex defined as local VAR from loop counter. Finding 4: Safety timeout compares against stored TimedTestStates[idx].tSafetyTimeout, not live input. Finding 5: Completion guarantee narrowed to TEST_TIMED*-managed tests only. Also: Type_WAIT_MISUSE for non-timeout misuse, name trimming in TEST_TIMED. |
