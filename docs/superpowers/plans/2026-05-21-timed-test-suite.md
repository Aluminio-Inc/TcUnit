# FB_TimedTestSuite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time elapsed testing to TcUnit — tests that wait for wall-clock time, then assert on time-dependent FB outcomes.

**Architecture:** New `FB_TimedTestSuite EXTENDS FB_TestSuite` with per-test wait state tracking. Three new DUTs, one new FB with 6 methods + 1 property, and minimal modifications to 3 existing files. The runner needs no changes — polymorphic `POINTER TO FB_TestSuite` handles timed suites automatically.

**Tech Stack:** TwinCAT 3 Structured Text, TcUnit xUnit framework, Photara Base library (TraceWithSeverity)

**Spec:** `docs/superpowers/specs/2026-05-20-timed-test-suite-design.md` (v4)

**Build note:** This is a TwinCAT library project. There are no CLI build/test commands. Compilation verification requires opening the solution in TwinCAT XAE (Visual Studio) and building. Runtime verification requires deploying to a PLC or local TwinCAT runtime. Each task's "verify" step describes what to check in XAE.

---

## File Map

### New Files (all under `TcUnit/TcUnit/`)

| File | Responsibility |
|------|---------------|
| `DUTs/E_WaitType.TcDUT` | Enum: None, Time, Condition |
| `DUTs/ST_TimedTestState.TcDUT` | Per-test wait state struct |
| `DUTs/ST_TimedTestResult.TcDUT` | Read-only composite for verifier inspection |
| `POUs/FB_TimedTestSuite.TcPOU` | The main FB — TEST_TIMED, TEST_TIMED_ORDERED, WaitForTime, WaitForCondition, WaitTimedOut, GetTimedTestResult, _FindTestIndex |

### Modified Files

| File | Change |
|------|--------|
| `DUTs/E_AssertionType.TcDUT` | Add Type_TIMEOUT and Type_WAIT_MISUSE |
| `POUs/Functions/F_AssertionTypeToString.TcPOU` | Add 2 CASE branches |
| `POUs/FB_TestSuite.TcPOU` | `METHOD PRIVATE` → `METHOD INTERNAL` on SetTestFailed (line 3778) |
| `TcUnit.plcproj` | Add 4 `<Compile Include>` entries |

---

### Task 1: Create Data Type Files

**Files:**
- Create: `TcUnit/TcUnit/DUTs/E_WaitType.TcDUT`
- Create: `TcUnit/TcUnit/DUTs/ST_TimedTestState.TcDUT`
- Create: `TcUnit/TcUnit/DUTs/ST_TimedTestResult.TcDUT`

- [ ] **Step 1: Create E_WaitType.TcDUT**

Write this file to `TcUnit/TcUnit/DUTs/E_WaitType.TcDUT`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <DUT Name="E_WaitType" Id="{4db9ff95-8ff6-4357-9c34-09b67956b168}">
    <Declaration><![CDATA[{attribute 'qualified_only'}
{attribute 'strict'}
TYPE E_WaitType :
(
    None      := 0,
    Time      := 1,
    Condition := 2
);
END_TYPE]]></Declaration>
  </DUT>
</TcPlcObject>
```

- [ ] **Step 2: Create ST_TimedTestState.TcDUT**

Write this file to `TcUnit/TcUnit/DUTs/ST_TimedTestState.TcDUT`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <DUT Name="ST_TimedTestState" Id="{9d0fddee-0599-470c-b101-f38bc2c77ade}">
    <Declaration><![CDATA[TYPE ST_TimedTestState :
STRUCT
    tSafetyTimeout     : TIME;
    nSafetyStartTime   : LWORD;
    bSafetyTimedOut    : BOOL;
    bInitialized       : BOOL;

    nWaitStartTime     : LWORD;
    bWaitComplete      : BOOL;
    bConditionTimedOut : BOOL;
    eWaitType          : E_WaitType;
    tLatchedDuration   : TIME;
END_STRUCT
END_TYPE]]></Declaration>
  </DUT>
</TcPlcObject>
```

- [ ] **Step 3: Create ST_TimedTestResult.TcDUT**

Write this file to `TcUnit/TcUnit/DUTs/ST_TimedTestResult.TcDUT`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <DUT Name="ST_TimedTestResult" Id="{491ec40a-95a0-4b2a-93d5-e96dd1d68451}">
    <Declaration><![CDATA[TYPE ST_TimedTestResult :
STRUCT
    TestName           : T_MaxString;
    bIsFailed          : BOOL;
    bIsSkipped         : BOOL;
    bIsFinished        : BOOL;
    sFailureMessage    : T_MaxString;
    eFailureType       : E_AssertionType;
    nNumberOfAsserts   : UINT;
    lrDuration         : LREAL;
    stTimedState       : ST_TimedTestState;
END_STRUCT
END_TYPE]]></Declaration>
  </DUT>
</TcPlcObject>
```

- [ ] **Step 4: Commit**

```bash
git add TcUnit/TcUnit/DUTs/E_WaitType.TcDUT TcUnit/TcUnit/DUTs/ST_TimedTestState.TcDUT TcUnit/TcUnit/DUTs/ST_TimedTestResult.TcDUT
git commit -m "feat(timed-suite): add E_WaitType, ST_TimedTestState, ST_TimedTestResult data types"
```

---

### Task 2: Modify Existing Base Files

**Files:**
- Modify: `TcUnit/TcUnit/DUTs/E_AssertionType.TcDUT`
- Modify: `TcUnit/TcUnit/POUs/Functions/F_AssertionTypeToString.TcPOU`
- Modify: `TcUnit/TcUnit/POUs/FB_TestSuite.TcPOU` (line 3778)

- [ ] **Step 1: Add Type_TIMEOUT and Type_WAIT_MISUSE to E_AssertionType**

In `TcUnit/TcUnit/DUTs/E_AssertionType.TcDUT`, add two new entries after the array types block, before the closing `) BYTE;`:

```
    Type_Array_WORD,

    // Timed test types
    Type_TIMEOUT,
    Type_WAIT_MISUSE
) BYTE;
```

The change: add a comma after `Type_Array_WORD`, then add the two new entries.

- [ ] **Step 2: Add CASE branches to F_AssertionTypeToString**

In `TcUnit/TcUnit/POUs/Functions/F_AssertionTypeToString.TcPOU`, add these two CASE branches before the `ELSE` block:

```iecst
    E_AssertionType.Type_Array_WORD :
        F_AssertionTypeToString := 'Array_WORD';

    (* Timed test types *)
    E_AssertionType.Type_TIMEOUT :
        F_AssertionTypeToString := 'TIMEOUT';

    E_AssertionType.Type_WAIT_MISUSE :
        F_AssertionTypeToString := 'WAIT_MISUSE';

    ELSE
        F_AssertionTypeToString := 'UNDEFINED';
```

- [ ] **Step 3: Change SetTestFailed from PRIVATE to INTERNAL**

In `TcUnit/TcUnit/POUs/FB_TestSuite.TcPOU`, find the `SetTestFailed` method declaration (line 3778). Change:

```
METHOD PRIVATE SetTestFailed
```

to:

```
METHOD INTERNAL SetTestFailed
```

One word change. This allows `FB_TimedTestSuite` (same library) to call it for safety timeout and wait-misuse auto-fail paths.

- [ ] **Step 4: Commit**

```bash
git add TcUnit/TcUnit/DUTs/E_AssertionType.TcDUT TcUnit/TcUnit/POUs/Functions/F_AssertionTypeToString.TcPOU TcUnit/TcUnit/POUs/FB_TestSuite.TcPOU
git commit -m "feat(timed-suite): add Type_TIMEOUT/Type_WAIT_MISUSE, widen SetTestFailed to INTERNAL"
```

---

### Task 3: Create FB_TimedTestSuite — Skeleton + _FindTestIndex + TEST_TIMED

**Files:**
- Create: `TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU`

This task creates the TcPOU file with the FB declaration, the private helper `_FindTestIndex`, and the `TEST_TIMED` method. Subsequent tasks add more methods to this file.

- [ ] **Step 1: Create the TcPOU file**

Write the following to `TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_TimedTestSuite" Id="{5e33d4a6-9874-4cbf-870e-04aa88da4d32}" SpecialFunc="None">
    <Declaration><![CDATA[FUNCTION_BLOCK FB_TimedTestSuite EXTENDS FB_TestSuite
VAR
    TimedTestStates      : ARRAY[1..GVL_Param_TcUnit.MaxNumberOfTestsForEachTestSuite] OF ST_TimedTestState;
    _nActiveTimedTestIdx : UINT;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[]]></ST>
    </Implementation>
    <Method Name="_FindTestIndex" Id="{93a8820b-d223-4dd7-9fef-df26f4027590}">
      <Declaration><![CDATA[METHOD PRIVATE _FindTestIndex : UINT
VAR_INPUT
    TestName : T_MaxString;
END_VAR
VAR
    i : UINT;
    nMax : UINT;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[_FindTestIndex := 0;
nMax := GetNumberOfTestsToAnalyse();
FOR i := 1 TO nMax BY 1 DO
    IF Tests[i].GetName() = TestName THEN
        _FindTestIndex := i;
        RETURN;
    END_IF
END_FOR]]></ST>
      </Implementation>
    </Method>
    <Method Name="TEST_TIMED" Id="{0013f9b0-ffec-48b5-9296-b6859eeadc7a}">
      <Declaration><![CDATA[METHOD PUBLIC TEST_TIMED : BOOL
VAR_INPUT
    TestName       : T_MaxString;
    tSafetyTimeout : TIME;
END_VAR
VAR
    idx         : UINT;
    lrElapsed   : LREAL;
    lrTimeout   : LREAL;
    sMsg        : T_MaxString;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[TEST_TIMED := FALSE;

// Step 1: Reset context
_nActiveTimedTestIdx := 0;

// Step 2: Trim name
TestName := F_LTrim(in := F_RTrim(in := TestName));

// Step 3: Register test via free function TEST()
TEST(TestName := TestName);

// Step 4: Check skip/ignore
IF GVL_TcUnit.IgnoreCurrentTest THEN
    RETURN;
END_IF

// Step 5: Find test index
idx := _FindTestIndex(TestName := TestName);
IF idx = 0 THEN
    RETURN;
END_IF
_nActiveTimedTestIdx := idx;

// Step 6: Check already finished
IF TimedTestStates[idx].bSafetyTimedOut OR IsTestFinished(TestName := TestName) THEN
    GVL_TcUnit.CurrentTestIsFinished := TRUE;
    RETURN;
END_IF

// Step 7: Initialize on first call
IF NOT TimedTestStates[idx].bInitialized THEN
    TimedTestStates[idx].nSafetyStartTime := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter);
    TimedTestStates[idx].tSafetyTimeout := tSafetyTimeout;
    TimedTestStates[idx].bInitialized := TRUE;
END_IF

// Step 8: Check safety timeout (compare against stored value)
lrElapsed := ULINT_TO_LREAL(F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter) - TimedTestStates[idx].nSafetyStartTime)
             * GVL_TcUnit.HundredNanosecondToSecond;
lrTimeout := TIME_TO_LREAL(TimedTestStates[idx].tSafetyTimeout) / 1000.0;

IF lrElapsed > lrTimeout THEN
    sMsg := CONCAT('SAFETY TIMEOUT: Test "', CONCAT(TestName, CONCAT('" exceeded ', LREAL_TO_FMTSTR(lrTimeout, 1, TRUE))));
    sMsg := CONCAT(sMsg, 's');

    SetTestFailed(AssertionType := E_AssertionType.Type_TIMEOUT,
                  AssertionMessage := sMsg);
    SetTestFinished(TestName := TestName,
                    FinishedAt := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
    CalculateAndSetNumberOfAssertsForTest(TestName := TestName);

    TimedTestStates[idx].bSafetyTimedOut := TRUE;
    GVL_TcUnit.CurrentTestIsFinished := TRUE;

    TraceWithSeverity(Message := sMsg, Severity := TcEventSeverity.Warning);
    RETURN;
END_IF

// Step 9: Test body should execute
TEST_TIMED := TRUE;]]></ST>
      </Implementation>
    </Method>
  </POU>
</TcPlcObject>
```

- [ ] **Step 2: Commit**

```bash
git add TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU
git commit -m "feat(timed-suite): FB_TimedTestSuite skeleton with _FindTestIndex and TEST_TIMED"
```

---

### Task 4: Add WaitForTime, WaitForCondition, and WaitTimedOut

**Files:**
- Modify: `TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU`

Insert these three XML elements before the closing `</POU>` tag in FB_TimedTestSuite.TcPOU.

- [ ] **Step 1: Add WaitForTime method**

Insert this `<Method>` block before `</POU>`:

```xml
    <Method Name="WaitForTime" Id="{0b99ca77-8d17-42e3-83bf-783cf70692bb}">
      <Declaration><![CDATA[METHOD PUBLIC WaitForTime : BOOL
VAR_INPUT
    tDuration : TIME;
END_VAR
VAR
    idx       : UINT;
    lrElapsed : LREAL;
    lrTarget  : LREAL;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[WaitForTime := FALSE;
idx := _nActiveTimedTestIdx;

// Step 1: Context check
IF idx = 0 THEN
    TraceWithSeverity(
        Message := 'WaitForTime called without active timed test context',
        Severity := TcEventSeverity.Error);
    RETURN;
END_IF

// Step 2: Pass-through if already complete
IF TimedTestStates[idx].bWaitComplete THEN
    WaitForTime := TRUE;
    RETURN;
END_IF

// Step 3: Type mismatch check
IF TimedTestStates[idx].eWaitType = E_WaitType.Condition THEN
    SetTestFailed(AssertionType := E_AssertionType.Type_WAIT_MISUSE,
                  AssertionMessage := 'WaitForTime called but WaitForCondition already active');
    SetTestFinished(TestName := GVL_TcUnit.CurrentTestNameBeingCalled,
                    FinishedAt := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
    CalculateAndSetNumberOfAssertsForTest(TestName := GVL_TcUnit.CurrentTestNameBeingCalled);
    GVL_TcUnit.CurrentTestIsFinished := TRUE;
    RETURN;
END_IF

// Step 4: First call — start wait
IF TimedTestStates[idx].nWaitStartTime = 0 THEN
    TimedTestStates[idx].eWaitType := E_WaitType.Time;
    TimedTestStates[idx].tLatchedDuration := tDuration;
    TimedTestStates[idx].nWaitStartTime := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter);
    TraceWithSeverity(
        Message := CONCAT('Wait started: ', CONCAT(TIME_TO_STRING(tDuration), CONCAT(' for test "', CONCAT(GVL_TcUnit.CurrentTestNameBeingCalled, '"')))),
        Severity := TcEventSeverity.Verbose);
    RETURN;
END_IF

// Steps 5-8: Check elapsed
lrElapsed := ULINT_TO_LREAL(F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter) - TimedTestStates[idx].nWaitStartTime)
             * GVL_TcUnit.HundredNanosecondToSecond;
lrTarget := TIME_TO_LREAL(TimedTestStates[idx].tLatchedDuration) / 1000.0;

IF lrElapsed >= lrTarget THEN
    TimedTestStates[idx].bWaitComplete := TRUE;
    TraceWithSeverity(
        Message := CONCAT('Wait completed: ', CONCAT(LREAL_TO_FMTSTR(lrElapsed, 3, TRUE), CONCAT('s elapsed for test "', CONCAT(GVL_TcUnit.CurrentTestNameBeingCalled, '"')))),
        Severity := TcEventSeverity.Info);
    WaitForTime := TRUE;
END_IF]]></ST>
      </Implementation>
    </Method>
```

- [ ] **Step 2: Add WaitForCondition method**

Insert this `<Method>` block before `</POU>`:

```xml
    <Method Name="WaitForCondition" Id="{88c233a4-16ee-418c-977a-40982d9a34b2}">
      <Declaration><![CDATA[METHOD PUBLIC WaitForCondition : BOOL
VAR_INPUT
    bCondition : BOOL;
    tTimeout   : TIME;
END_VAR
VAR
    idx       : UINT;
    lrElapsed : LREAL;
    lrTarget  : LREAL;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[WaitForCondition := FALSE;
idx := _nActiveTimedTestIdx;

// Step 1: Context check
IF idx = 0 THEN
    TraceWithSeverity(
        Message := 'WaitForCondition called without active timed test context',
        Severity := TcEventSeverity.Error);
    RETURN;
END_IF

// Step 2: Pass-through if already complete
IF TimedTestStates[idx].bWaitComplete THEN
    WaitForCondition := TRUE;
    RETURN;
END_IF

// Step 3: Type mismatch check
IF TimedTestStates[idx].eWaitType = E_WaitType.Time THEN
    SetTestFailed(AssertionType := E_AssertionType.Type_WAIT_MISUSE,
                  AssertionMessage := 'WaitForCondition called but WaitForTime already active');
    SetTestFinished(TestName := GVL_TcUnit.CurrentTestNameBeingCalled,
                    FinishedAt := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
    CalculateAndSetNumberOfAssertsForTest(TestName := GVL_TcUnit.CurrentTestNameBeingCalled);
    GVL_TcUnit.CurrentTestIsFinished := TRUE;
    RETURN;
END_IF

// Step 4: First call with condition already TRUE — immediate completion
IF bCondition AND TimedTestStates[idx].nWaitStartTime = 0 THEN
    TimedTestStates[idx].bWaitComplete := TRUE;
    TimedTestStates[idx].bConditionTimedOut := FALSE;
    TimedTestStates[idx].eWaitType := E_WaitType.Condition;
    TraceWithSeverity(
        Message := CONCAT('WaitForCondition: condition already TRUE for test "', CONCAT(GVL_TcUnit.CurrentTestNameBeingCalled, '"')),
        Severity := TcEventSeverity.Info);
    WaitForCondition := TRUE;
    RETURN;
END_IF

// Step 5: First call, condition not yet met — start wait
IF TimedTestStates[idx].nWaitStartTime = 0 THEN
    TimedTestStates[idx].eWaitType := E_WaitType.Condition;
    TimedTestStates[idx].tLatchedDuration := tTimeout;
    TimedTestStates[idx].nWaitStartTime := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter);
    TraceWithSeverity(
        Message := CONCAT('WaitForCondition started: timeout ', CONCAT(TIME_TO_STRING(tTimeout), CONCAT(' for test "', CONCAT(GVL_TcUnit.CurrentTestNameBeingCalled, '"')))),
        Severity := TcEventSeverity.Verbose);
    RETURN;
END_IF

// Step 6: Condition met during wait
IF bCondition THEN
    TimedTestStates[idx].bWaitComplete := TRUE;
    TimedTestStates[idx].bConditionTimedOut := FALSE;
    TraceWithSeverity(
        Message := CONCAT('WaitForCondition: condition met for test "', CONCAT(GVL_TcUnit.CurrentTestNameBeingCalled, '"')),
        Severity := TcEventSeverity.Info);
    WaitForCondition := TRUE;
    RETURN;
END_IF

// Step 7: Check timeout
lrElapsed := ULINT_TO_LREAL(F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter) - TimedTestStates[idx].nWaitStartTime)
             * GVL_TcUnit.HundredNanosecondToSecond;
lrTarget := TIME_TO_LREAL(TimedTestStates[idx].tLatchedDuration) / 1000.0;

IF lrElapsed >= lrTarget THEN
    TimedTestStates[idx].bWaitComplete := TRUE;
    TimedTestStates[idx].bConditionTimedOut := TRUE;
    TraceWithSeverity(
        Message := CONCAT('WaitForCondition timed out after ', CONCAT(LREAL_TO_FMTSTR(lrElapsed, 3, TRUE), CONCAT('s for test "', CONCAT(GVL_TcUnit.CurrentTestNameBeingCalled, '"')))),
        Severity := TcEventSeverity.Warning);
    WaitForCondition := TRUE;
END_IF

// Step 8: Still waiting — return FALSE (default)]]></ST>
      </Implementation>
    </Method>
```

- [ ] **Step 3: Add WaitTimedOut property**

Insert this `<Property>` block before `</POU>`:

```xml
    <Property Name="WaitTimedOut" Id="{6125a451-2aab-41bb-83d8-06512aed2ebe}">
      <Declaration><![CDATA[PROPERTY PUBLIC WaitTimedOut : BOOL]]></Declaration>
      <Get Name="Get" Id="{70c9814c-731b-4ad8-8dae-52538dfcf02b}">
        <Declaration><![CDATA[VAR
END_VAR]]></Declaration>
        <Implementation>
          <ST><![CDATA[IF _nActiveTimedTestIdx > 0 THEN
    WaitTimedOut := TimedTestStates[_nActiveTimedTestIdx].bConditionTimedOut;
ELSE
    WaitTimedOut := FALSE;
END_IF]]></ST>
        </Implementation>
      </Get>
    </Property>
```

- [ ] **Step 4: Commit**

```bash
git add TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU
git commit -m "feat(timed-suite): add WaitForTime, WaitForCondition, WaitTimedOut"
```

---

### Task 5: Add TEST_TIMED_ORDERED

**Files:**
- Modify: `TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU`

Insert this `<Method>` block before `</POU>` in FB_TimedTestSuite.TcPOU.

- [ ] **Step 1: Add TEST_TIMED_ORDERED method**

This method replicates the exact algorithm of `TEST_ORDERED` (lines 34-82 in TEST_ORDERED.TcPOU) and adds safety timeout logic.

```xml
    <Method Name="TEST_TIMED_ORDERED" Id="{5e0303e8-2443-4c00-9f81-4aeaec60b00c}">
      <Declaration><![CDATA[METHOD PUBLIC TEST_TIMED_ORDERED : BOOL
VAR_INPUT
    TestName       : T_MaxString;
    tSafetyTimeout : TIME;
END_VAR
VAR
    CounterTestSuiteAddress : UINT;
    SuiteIndex              : UINT;
    Test                    : REFERENCE TO FB_Test;
    idx                     : UINT;
    lrElapsed               : LREAL;
    lrTimeout               : LREAL;
    sMsg                    : T_MaxString;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[TEST_TIMED_ORDERED := FALSE;

// Step 1: Reset context
_nActiveTimedTestIdx := 0;

// Step 2: Trim name (matches TEST_ORDERED line 34)
TestName := F_LTrim(in := F_RTrim(in := TestName));

// Step 3: Set global test name (matches line 37)
GVL_TcUnit.CurrentTestNameBeingCalled := TestName;

// Step 4: Find suite in runner registry (matches lines 44-47)
SuiteIndex := 0;
FOR CounterTestSuiteAddress := 1 TO GVL_TcUnit.NumberOfInitializedTestSuites BY 1 DO
    IF GVL_TcUnit.TestSuiteAddresses[CounterTestSuiteAddress] = GVL_TcUnit.CurrentTestSuiteBeingCalled THEN
        SuiteIndex := CounterTestSuiteAddress;
        EXIT;
    END_IF
END_FOR
IF SuiteIndex = 0 THEN
    RETURN;
END_IF

// Step 5: Register as ordered test (matches line 48)
Test REF= GVL_TcUnit.TestSuiteAddresses[SuiteIndex]^.AddTest(TestName := TestName, IsTestOrdered := TRUE);

// Step 6: Set CurrentTestIsFinished (matches line 49)
GVL_TcUnit.CurrentTestIsFinished := GVL_TcUnit.TestSuiteAddresses[SuiteIndex]^.IsTestFinished(TestName := TestName);

// Step 7: Check skip/ignore (matches lines 76-78)
IF GVL_TcUnit.IgnoreCurrentTest THEN
    RETURN;
END_IF

// Step 8: Check ordered cursor (matches lines 55-74)
IF GetTestOrderNumber(TestName := TestName) = GVL_TcUnit.CurrentlyRunningOrderedTestInTestSuite[SuiteIndex] THEN
    IF GVL_TcUnit.CurrentTestIsFinished THEN
        // Already finished — advance cursor (matches lines 58-62)
        GVL_TcUnit.CurrentlyRunningOrderedTestInTestSuite[SuiteIndex] :=
            GVL_TcUnit.CurrentlyRunningOrderedTestInTestSuite[SuiteIndex] + 1;
        GVL_TcUnit.IgnoreCurrentTest := TRUE;
        RETURN;
    END_IF
ELSE
    // Not this test's turn (matches lines 70-73)
    GVL_TcUnit.IgnoreCurrentTest := TRUE;
    RETURN;
END_IF

// --- From here: this test's turn AND not finished. Add timed-test logic. ---

// Step 9: Find timed test index
idx := _FindTestIndex(TestName := TestName);
IF idx = 0 THEN
    RETURN;
END_IF
_nActiveTimedTestIdx := idx;

// Step 10: Check already timed out
IF TimedTestStates[idx].bSafetyTimedOut THEN
    GVL_TcUnit.CurrentTestIsFinished := TRUE;
    RETURN;
END_IF

// Step 11: Initialize on first call
IF NOT TimedTestStates[idx].bInitialized THEN
    TimedTestStates[idx].nSafetyStartTime := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter);
    TimedTestStates[idx].tSafetyTimeout := tSafetyTimeout;
    TimedTestStates[idx].bInitialized := TRUE;
END_IF

// Step 12: Check safety timeout (compare against stored value)
lrElapsed := ULINT_TO_LREAL(F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter) - TimedTestStates[idx].nSafetyStartTime)
             * GVL_TcUnit.HundredNanosecondToSecond;
lrTimeout := TIME_TO_LREAL(TimedTestStates[idx].tSafetyTimeout) / 1000.0;

IF lrElapsed > lrTimeout THEN
    sMsg := CONCAT('SAFETY TIMEOUT: Test "', CONCAT(TestName, CONCAT('" exceeded ', LREAL_TO_FMTSTR(lrTimeout, 1, TRUE))));
    sMsg := CONCAT(sMsg, 's');

    SetTestFailed(AssertionType := E_AssertionType.Type_TIMEOUT,
                  AssertionMessage := sMsg);
    SetTestFinished(TestName := TestName,
                    FinishedAt := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
    CalculateAndSetNumberOfAssertsForTest(TestName := TestName);

    TimedTestStates[idx].bSafetyTimedOut := TRUE;
    GVL_TcUnit.CurrentTestIsFinished := TRUE;

    TraceWithSeverity(Message := sMsg, Severity := TcEventSeverity.Warning);
    RETURN;
END_IF

// Step 13: Set started timestamp (matches line 66)
IF __ISVALIDREF(Test) THEN
    Test.SetStartedAtIfNotSet(Timestamp := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
END_IF

// Step 14: Test body should execute
TEST_TIMED_ORDERED := TRUE;]]></ST>
      </Implementation>
    </Method>
```

- [ ] **Step 2: Commit**

```bash
git add TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU
git commit -m "feat(timed-suite): add TEST_TIMED_ORDERED with full ordered cursor + safety timeout"
```

---

### Task 6: Add GetTimedTestResult

**Files:**
- Modify: `TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU`

Insert this `<Method>` block before `</POU>` in FB_TimedTestSuite.TcPOU.

- [ ] **Step 1: Add GetTimedTestResult method**

```xml
    <Method Name="GetTimedTestResult" Id="{0d1b3cc6-3a78-434f-bd11-b934903f7c9d}">
      <Declaration><![CDATA[METHOD PUBLIC GetTimedTestResult : ST_TimedTestResult
VAR_INPUT
    TestName : T_MaxString;
END_VAR
VAR
    idx  : UINT;
    Test : REFERENCE TO FB_Test;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[idx := _FindTestIndex(TestName := TestName);
IF idx = 0 THEN
    RETURN;
END_IF

Test REF= Tests[idx];
IF NOT __ISVALIDREF(Test) THEN
    RETURN;
END_IF

GetTimedTestResult.TestName := Test.GetName();
GetTimedTestResult.bIsFailed := Test.IsFailed();
GetTimedTestResult.bIsSkipped := Test.IsSkipped();
GetTimedTestResult.bIsFinished := Test.IsFinished();
GetTimedTestResult.sFailureMessage := Test.GetAssertionMessage();
GetTimedTestResult.eFailureType := Test.GetAssertionType();
GetTimedTestResult.nNumberOfAsserts := Test.GetNumberOfAssertions();
GetTimedTestResult.lrDuration := Test.GetDuration();
GetTimedTestResult.stTimedState := TimedTestStates[idx];]]></ST>
      </Implementation>
    </Method>
```

- [ ] **Step 2: Commit**

```bash
git add TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU
git commit -m "feat(timed-suite): add GetTimedTestResult public read-only accessor"
```

---

### Task 7: Wire Into plcproj and Final Verification

**Files:**
- Modify: `TcUnit/TcUnit/TcUnit.plcproj`

- [ ] **Step 1: Add Compile Include entries**

In `TcUnit/TcUnit/TcUnit.plcproj`, add these four entries in the `<ItemGroup>` that contains the other DUT and POU `<Compile Include>` entries.

Add the DUT entries after the existing DUT block (after the `U_ExpectedOrActual.TcDUT` entry around line 84):

```xml
    <Compile Include="DUTs\E_WaitType.TcDUT">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="DUTs\ST_TimedTestState.TcDUT">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="DUTs\ST_TimedTestResult.TcDUT">
      <SubType>Code</SubType>
    </Compile>
```

Add the POU entry after the existing `FB_TestSuite.TcPOU` entry (around line 140):

```xml
    <Compile Include="POUs\FB_TimedTestSuite.TcPOU">
      <SubType>Code</SubType>
    </Compile>
```

- [ ] **Step 2: Verify in XAE**

Open `TcUnit/TcUnit.sln` in TwinCAT XAE. The new files should appear in the Solution Explorer under TcUnit. Build the solution (Ctrl+Shift+B). Expected: clean build with 0 errors. Warnings about unused variables are acceptable at this stage.

Check that:
- `FB_TimedTestSuite` appears under POUs and shows all methods (TEST_TIMED, TEST_TIMED_ORDERED, WaitForTime, WaitForCondition, WaitTimedOut, GetTimedTestResult, _FindTestIndex)
- The three DUTs appear under DUTs
- E_AssertionType shows Type_TIMEOUT and Type_WAIT_MISUSE
- FB_TestSuite.SetTestFailed shows as INTERNAL (hover or open declaration)

- [ ] **Step 3: Commit**

```bash
git add TcUnit/TcUnit/TcUnit.plcproj
git commit -m "feat(timed-suite): wire new files into plcproj — FB_TimedTestSuite complete"
```

---

## Verification Checklist

After all tasks complete and XAE builds clean:

- [ ] `FB_TimedTestSuite EXTENDS FB_TestSuite` compiles without errors
- [ ] `TEST_TIMED` returns BOOL and calls `TEST()` internally
- [ ] `TEST_TIMED_ORDERED` returns BOOL with ordered cursor logic
- [ ] `WaitForTime` returns FALSE on first call, TRUE after duration
- [ ] `WaitForCondition(TRUE, ...)` returns TRUE immediately (first call)
- [ ] `WaitTimedOut` property reads `bConditionTimedOut` from active test
- [ ] `GetTimedTestResult` returns populated `ST_TimedTestResult`
- [ ] `SetTestFailed` is callable from `FB_TimedTestSuite` (was PRIVATE, now INTERNAL)
- [ ] `F_AssertionTypeToString(Type_TIMEOUT)` returns `'TIMEOUT'`
- [ ] `F_AssertionTypeToString(Type_WAIT_MISUSE)` returns `'WAIT_MISUSE'`
- [ ] xUnit publisher emits `<failure type="TIMEOUT">` for timed-out tests (Type_TIMEOUT != Type_UNDEFINED)
- [ ] Save TcUnit as library and install — consumer projects can instantiate `FB_TimedTestSuite`

## Next Steps (out of scope for this plan)

1. **Level 1 tests** in TwinCAT_Tests: Write `FB_TimedSuiteGreenPathTests EXTENDS FB_TimedTestSuite` with short real-time waits (T#1S, T#2S)
2. **Level 2 verifier** in TwinCAT_Tests: Write subject + verifier suite pair for safety timeout validation (local-only, red run expected)
3. **Library recompile**: Bump TcUnit version, save as library, install, update consumer plcproj references
4. **Real-world timed tests**: Write FB_CommandTimingTests per the spec examples to validate actual FB_Command timeout behavior
