# Phase 5 Step-0 Prerequisites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the Step-0 prerequisites of the multi-task tagged execution design: harden FB_TimedTestSuite (Phase 4a), fix the RUN_IN_SEQUENCE completion latch, correct xUnit count semantics, and prove all three with a committed red-green verification campaign (Phase 4b), ending with library 2026.7.17.1 installed and consumed by TwinCAT_Tests.

**Architecture:** Test artifacts are written first in TwinCAT_Tests (which already runs `RUN_IN_SEQUENCE()`), run RED against the currently installed TcUnit 2026.4.9.1, then the three fixes land in TcUnitFork sources, the library is rebuilt as 2026.7.17.1, and the same campaign is rerun GREEN. Verification is XAE-manual (no CLI build exists); every run step is an exact XAE procedure with expected observable values, recorded in a committed verification doc.

**Tech Stack:** TwinCAT 3.1.4026.x XAE, IEC 61131-3 ST (`.TcPOU`/`.TcDUT` XML), TcUnit fork, PowerShell for canonicalization, git.

## Plan sequence context

This is **Plan 1 of the Phase 5 series** (spec: `docs/superpowers/specs/2026-07-16-multitask-tagged-execution-design.md`, implementation order step 0). Later plans, in order: compile/ABI spike; status+seams+coordinator skeleton; task-context migration; planning/barriers+selective execution; reporting pipeline; multi-task verifier; consumer qualification. The TwinCATBase multi-writer audit is an **external gate** in the TwinCATBase repo — it gates production multi-task enablement, not this plan.

## Global Constraints

- Every new TwinCAT object AND every new method/property gets a fresh random GUID: `python -c "import uuid; print('{' + str(uuid.uuid4()) + '}')"` — never reuse or pattern GUIDs; verify uniqueness with Grep before adding.
- ASCII only in ST string literals (no em dashes/arrows) — they corrupt UTF-8 log parsing.
- `.TcPOU`/`.TcDUT`/`.TcGVL` files on disk are NOT built unless listed as `<Compile Include>` in the `.plcproj`; new folders need `<Folder Include>`.
- Library version lives in TWO files that must stay in sync: `TcUnit/TcUnit/TcUnit.plcproj` `<ProjectVersion>` and `TcUnit/TcUnit/Version/Global_Version.TcGVL` `stLibVersion_TcUnit`. New version this plan: **2026.7.17.1**. Tag `TcUnit-2026.7.17.1` on the commit containing bump + `.library` binary.
- Never use IEC reserved words (`DT`, `TIME_OF_DAY`, …) as identifiers.
- Any `TraceWithSeverity` reachable cyclically MUST be one-shot guarded.
- Do not remove or weaken existing assertions or public API. The only new members allowed by this plan: `FB_TimedTestSuite._GetActiveWaitContext` (PRIVATE method), two new VARs on FB_TimedTestSuite, two new DUT fields — all approved via the Phase 5 spec Step 0 scope.
- TcUnitFork work happens on branch `feat/timed-test-suite`; TwinCAT_Tests work on new branch `feat/tcunit-step0`.
- XAE builds/runs are USER ACTIONS — Scott runs them; the executor prepares exact instructions and waits for reported results before proceeding.
- `TcUnit.library` at the fork repo root is currently deleted in the working tree (pre-existing). Task 8 regenerates and commits it — do not restore or commit it before then.

---

### Task 1: Timed-suite regression tests (TwinCAT_Tests, written first)

**Files:**
- Create: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TcUnitTests\FB_TimedSuiteGreenPathTests.TcPOU`

**Interfaces:**
- Consumes: `TcUnit.FB_TimedTestSuite` API as shipped in 2026.4.9.1: `TEST_TIMED(TestName, tSafetyTimeout)`, `WaitForTime(tDuration)`, `WaitForCondition(bCondition, tTimeout)`, `WaitTimedOut`, `GetTimedTestResult(TestName) : ST_TimedTestResult` (fields `TestName`, `bIsFinished`).
- Produces: FB `FB_TimedSuiteGreenPathTests` with 5 tests: `Test_Wait1s`, `Test_ConditionMet`, `Test_ConditionTimeoutDetected`, `Test_PaddedNameLookup`, `Test_StaleContextGuard`. Task 2's PRG instantiates it as `TimedSuiteTests`.

- [ ] **Step 1: Create the TwinCAT_Tests branch**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git checkout -b feat/tcunit-step0
```

- [ ] **Step 2: Generate one fresh GUID**

Run: `python -c "import uuid; print('{' + str(uuid.uuid4()) + '}')"`
Then verify it is unused: Grep the printed GUID across `C:\Users\scott\Documents\TwinCAT_Tests` and `C:\Users\scott\Documents\TcUnitFork`. Expected: no matches. Use it as `<GUID-1>` below.

- [ ] **Step 3: Write the failing tests**

Create `FB_TimedSuiteGreenPathTests.TcPOU` with this exact content (substitute `<GUID-1>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_TimedSuiteGreenPathTests" Id="<GUID-1>" SpecialFunc="None">
    <Declaration><![CDATA[(* Level 1 green-path and Phase 4a regression tests for TcUnit.FB_TimedTestSuite.
   Test_PaddedNameLookup and Test_StaleContextGuard are regressions for the two
   Phase 4a hardening items (GetTimedTestResult trim, stale wait context). They
   FAIL against TcUnit 2026.4.9.1 and PASS from 2026.7.17.1. *)
FUNCTION_BLOCK FB_TimedSuiteGreenPathTests EXTENDS TcUnit.FB_TimedTestSuite
VAR
    nConditionCounter             : UDINT;
    bOutOfContextWaitReturnedTrue : BOOL;
    bBareWaitReturn               : BOOL;
    stPaddedLookup                : TcUnit.ST_TimedTestResult;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[(* Regression probe for the stale timed-context gotcha: a wait helper called
   before any timed test block in this scan must never bind to the previous
   scan's context. Against 2026.4.9.1 this binds to the last block's state. *)
bBareWaitReturn := WaitForTime(tDuration := T#10MS);
IF bBareWaitReturn THEN
    bOutOfContextWaitReturnedTrue := TRUE;
END_IF

IF TEST_TIMED(TestName := 'Test_Wait1s', tSafetyTimeout := T#10S) THEN
    IF WaitForTime(tDuration := T#1S) THEN
        AssertFalse(Condition := WaitTimedOut, Message := 'Plain time wait must not report a condition timeout');
        TEST_FINISHED();
    END_IF
END_IF

IF TEST_TIMED(TestName := 'Test_ConditionMet', tSafetyTimeout := T#10S) THEN
    nConditionCounter := nConditionCounter + 1;
    IF WaitForCondition(bCondition := (nConditionCounter >= 5), tTimeout := T#5S) THEN
        AssertFalse(Condition := WaitTimedOut, Message := 'Condition must be met before timeout');
        TEST_FINISHED();
    END_IF
END_IF

IF TEST_TIMED(TestName := 'Test_ConditionTimeoutDetected', tSafetyTimeout := T#10S) THEN
    IF WaitForCondition(bCondition := FALSE, tTimeout := T#1S) THEN
        AssertTrue(Condition := WaitTimedOut, Message := 'Timeout must be reported via WaitTimedOut');
        TEST_FINISHED();
    END_IF
END_IF

IF TEST_TIMED(TestName := 'Test_PaddedNameLookup', tSafetyTimeout := T#20S) THEN
    stPaddedLookup := GetTimedTestResult(TestName := '   Test_Wait1s   ');
    IF WaitForCondition(bCondition := stPaddedLookup.bIsFinished, tTimeout := T#15S) THEN
        AssertFalse(Condition := WaitTimedOut, Message := 'Padded-name lookup must resolve Test_Wait1s');
        AssertEquals_STRING(Expected := 'Test_Wait1s',
                            Actual := stPaddedLookup.TestName,
                            Message := 'GetTimedTestResult must trim the lookup name');
        TEST_FINISHED();
    END_IF
END_IF

IF TEST_TIMED(TestName := 'Test_StaleContextGuard', tSafetyTimeout := T#30S) THEN
    IF WaitForCondition(bCondition := GetTimedTestResult(TestName := 'Test_Wait1s').bIsFinished, tTimeout := T#20S) THEN
        AssertFalse(Condition := bOutOfContextWaitReturnedTrue, Message := 'Out-of-context WaitForTime must never return TRUE');
        TEST_FINISHED();
    END_IF
END_IF]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

Why these two are RED against 2026.4.9.1: `TEST_TIMED` in 2026.4.9.1 sets `_nActiveTimedTestIdx` before its finished-check and never clears it between scans, so the bare `WaitForTime` at the top of the body binds to the previous scan's last block (`Test_StaleContextGuard`, whose wait type is Condition) and fails it with `Type_WAIT_MISUSE` from scan 2 onward. `GetTimedTestResult` in 2026.4.9.1 does not trim, so the padded lookup never resolves, its condition wait times out, and both of its asserts fail.

- [ ] **Step 4: Commit**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TcUnitTests/FB_TimedSuiteGreenPathTests.TcPOU
git commit -m "test(tcunit-step0): add timed-suite Level 1 + Phase 4a regression tests (red vs 2026.4.9.1)

- FB_TimedSuiteGreenPathTests.TcPOU: 3 green-path timed tests plus padded-name and stale-context regressions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

(The file is not yet in the plcproj — wiring happens in Task 2 with the PRG; the commit is safe because TwinCAT_Tests builds only plcproj-listed files.)

---

### Task 2: Count-semantics fixture, campaign PRG, and plcproj wiring (TwinCAT_Tests)

**Files:**
- Create: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TcUnitTests\FB_StepZeroCounts_ShouldFail.TcPOU`
- Create: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TcUnitTests\PRG_TEST_TCUNIT_STEP0.TcPOU`
- Modify: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests.plcproj` (Folder Include ~line 562-579 block, Compile Include ~line 21+ block, TcUnit Parameters under the PlaceholderReference at ~line 527)

**Interfaces:**
- Consumes: `FB_TimedSuiteGreenPathTests` from Task 1; `TcUnit.RUN_IN_SEQUENCE()`; TcUnit `disabled_` test-name prefix (produces a skipped test).
- Produces: PRG `PRG_TEST_TCUNIT_STEP0` with suite instances `TimedSuiteTests` and `StepZeroCounts_ShouldFail` (registration order: timed suite first). Deterministic campaign totals: 8 tests, 1 failed, 1 skipped (green run). The `_ShouldFail` suffix follows the repo's convention for suites with intentional failures.

- [ ] **Step 1: Generate two fresh GUIDs**

Run `python -c "import uuid; print('{' + str(uuid.uuid4()) + '}')"` twice; Grep both across both repos (expected: no matches). Use as `<GUID-2>` and `<GUID-3>`.

- [ ] **Step 2: Write the count-semantics fixture**

Create `FB_StepZeroCounts_ShouldFail.TcPOU`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_StepZeroCounts_ShouldFail" Id="<GUID-2>" SpecialFunc="None">
    <Declaration><![CDATA[(* Deterministic count-semantics fixture: exactly 1 pass, 1 intentional fail,
   1 skipped (disabled_) test. Expected xUnit contribution: tests=3, failures=1,
   skipped=1. The _ShouldFail suffix marks the failure as intentional. *)
FUNCTION_BLOCK FB_StepZeroCounts_ShouldFail EXTENDS TcUnit.FB_TestSuite]]></Declaration>
    <Implementation>
      <ST><![CDATA[TEST('Test_Pass');
AssertTrue(Condition := TRUE, Message := 'Passing test');
TEST_FINISHED();

TEST('Test_IntentionalFail');
AssertTrue(Condition := FALSE, Message := 'Intentional Step-0 count-semantics failure');
TEST_FINISHED();

TEST('disabled_Test_Skipped');
AssertTrue(Condition := TRUE, Message := 'Never evaluated - test is skipped');
TEST_FINISHED();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

- [ ] **Step 3: Write the campaign PRG**

Create `PRG_TEST_TCUNIT_STEP0.TcPOU`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="PRG_TEST_TCUNIT_STEP0" Id="<GUID-3>" SpecialFunc="None">
    <Declaration><![CDATA[(* Step-0 verification campaign for the TcUnit fork.
   Runs sequentially so the RUN_IN_SEQUENCE completion latch is exercised:
   against TcUnit 2026.4.9.1, TcUnit.GVL_TcUnit.TcUnitRunner.AllTestSuitesFinished
   never becomes TRUE (breadcrumb #19); from 2026.7.17.1 it latches TRUE.
   Verification procedure: TcUnitFork docs/verification/2026-07-17-step0-verification.md *)
PROGRAM PRG_TEST_TCUNIT_STEP0
VAR
    TimedSuiteTests           : FB_TimedSuiteGreenPathTests;
    StepZeroCounts_ShouldFail : FB_StepZeroCounts_ShouldFail;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[TcUnit.RUN_IN_SEQUENCE();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

- [ ] **Step 4: Wire the plcproj**

In `TwinCAT_Tests.plcproj`:

1. Add to the `<Folder Include>` block (the ItemGroup containing `<Folder Include="BaseTests" />`):

```xml
    <Folder Include="TcUnitTests" />
```

2. Add to the Compile ItemGroup (alongside the existing `<Compile Include=...>` entries):

```xml
    <Compile Include="TcUnitTests\FB_TimedSuiteGreenPathTests.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\FB_StepZeroCounts_ShouldFail.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\PRG_TEST_TCUNIT_STEP0.TcPOU">
      <SubType>Code</SubType>
    </Compile>
```

3. Enable xUnit publication via GPL override. Locate the `<PlaceholderReference Include="TcUnit">` element (its `<DefaultResolution>` is at ~line 527) and add inside it:

```xml
      <Parameters>
        <Parameter ListName="GVL_PARAM_TCUNIT">
          <Key>XUNITENABLEPUBLISH</Key>
          <Value>1</Value>
        </Parameter>
      </Parameters>
```

If XAE rejects this format on first build, fall back to setting the parameter in XAE (References → TcUnit → Parameters tab → `xUnitEnablePublish` = TRUE), then diff the plcproj to capture the format XAE writes and keep that. Note: this enables xUnit file output (`C:\tcunit_xunit_testresults.xml`) for ALL TwinCAT_Tests campaigns — one small file per completed run, harmless, and useful.

- [ ] **Step 5: Commit**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TcUnitTests/FB_StepZeroCounts_ShouldFail.TcPOU TwinCAT_Tests/TwinCAT_Tests/TcUnitTests/PRG_TEST_TCUNIT_STEP0.TcPOU TwinCAT_Tests/TwinCAT_Tests/TwinCAT_Tests.plcproj
git commit -m "test(tcunit-step0): add count-semantics fixture, campaign PRG, plcproj wiring

- FB_StepZeroCounts_ShouldFail.TcPOU: 1 pass + 1 intentional fail + 1 skipped fixture
- PRG_TEST_TCUNIT_STEP0.TcPOU: sequential campaign PRG (RUN_IN_SEQUENCE completion regression)
- TwinCAT_Tests.plcproj: TcUnitTests folder + 3 compile entries + xUnitEnablePublish override

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

---

### Task 3: Committed verification procedure and canonicalization tooling (TcUnitFork)

**Files:**
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md`
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\Canonicalize-XUnit.ps1`

**Interfaces:**
- Consumes: campaign artifacts from Tasks 1-2; xUnit output path `C:\tcunit_xunit_testresults.xml` (TcUnit default).
- Produces: the RED/GREEN procedure Scott executes in Tasks 4 and 9, with result-recording tables; `Canonicalize-XUnit.ps1 -Path <file> -OutPath <file>` which blanks all `time="..."` attribute values.

- [ ] **Step 1: Write the canonicalization script**

Create `Canonicalize-XUnit.ps1`:

```powershell
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutPath
)
# Blanks every time="..." attribute so runs differing only in duration compare byte-identical.
$content = Get-Content -Path $Path -Raw
$canonical = $content -replace 'time="[^"]*"', 'time=""'
Set-Content -Path $OutPath -Value $canonical -NoNewline -Encoding UTF8
Write-Host "Canonicalized $Path -> $OutPath"
```

- [ ] **Step 2: Write the verification procedure**

Create `2026-07-17-step0-verification.md` with exactly this structure (result cells left as `_pending_` for Tasks 4/9 to fill):

```markdown
# Step-0 Verification Procedure (Phase 4a/4b + sequential runner + xUnit counts)

Campaign: `PRG_TEST_TCUNIT_STEP0` in TwinCAT_Tests (branch `feat/tcunit-step0`).
Run once RED against TcUnit **2026.4.9.1**, once GREEN against **2026.7.17.1**.

## Run recipe (identical for RED and GREEN)

1. Open `TwinCAT_Tests.sln` in XAE.
2. Assign `PRG_TEST_TCUNIT_STEP0` to TestTask (replace the currently assigned PRG_TEST_* for this run; restore afterward).
3. Build (Ctrl+Shift+B) — must compile clean.
4. Activate configuration, restart in Run mode, log in.
5. Wait for the ADS summary block in the Error List (appears when all suites stored).
6. Online-view `TcUnit.GVL_TcUnit.TcUnitRunner.AllTestSuitesFinished` and watch for 60 s after the summary appears.
7. Copy `C:\tcunit_xunit_testresults.xml` aside; run `Canonicalize-XUnit.ps1` on it.
8. Record every row below. RED must match the RED column before any fix is trusted;
   GREEN must match the GREEN column before release.

## Expected observations

| # | Observation | RED (2026.4.9.1) | GREEN (2026.7.17.1) | RED actual | GREEN actual |
|---|---|---|---|---|---|
| 1 | Test_Wait1s / Test_ConditionMet / Test_ConditionTimeoutDetected | all PASS | all PASS | _pending_ | _pending_ |
| 2 | Test_PaddedNameLookup | FAIL (condition wait times out; 2 asserts fail) | PASS | _pending_ | _pending_ |
| 3 | Test_StaleContextGuard | FAIL (Type_WAIT_MISUSE from stale bare wait) | PASS | _pending_ | _pending_ |
| 4 | FB_StepZeroCounts_ShouldFail | Test_Pass PASS; Test_IntentionalFail FAIL; disabled_Test_Skipped SKIP | same (intentional fixture) | _pending_ | _pending_ |
| 5 | `AllTestSuitesFinished` within 60 s of summary | stays FALSE (breadcrumb #19) | TRUE | _pending_ | _pending_ |
| 6 | 'TEST RUN COMPLETED' trace in EventLog | absent | present once | _pending_ | _pending_ |
| 7 | xUnit root `tests` attribute | 5 (successful-count bug: 8 total - 3 failed) | 8 (total) | _pending_ | _pending_ |
| 8 | xUnit root `failures` attribute | 3 (2 timed regressions + 1 intentional) | 1 (intentional only) | _pending_ | _pending_ |
| 9 | xUnit root `skipped` attribute | absent | 1 | _pending_ | _pending_ |
| 10 | testsuite[TimedSuiteTests] tests/failures/skipped | 5 / 2 / (absent) | 5 / 0 / 0 | _pending_ | _pending_ |
| 11 | testsuite[StepZeroCounts_ShouldFail] tests/failures/skipped | 3 / 1 / (absent) | 3 / 1 / 1 | _pending_ | _pending_ |
| 12 | ADS summary 'successful tests' count | 5 (skipped counted as pass; 2 timed regressions failing) | 6 (8 - 1 fail - 1 skip) | _pending_ | _pending_ |
| 13 | Out-of-context wait Error trace | may repeat (unguarded in 2026.4.9.1) | exactly once (one-shot) | _pending_ | _pending_ |

## Golden

After the GREEN run matches all rows, copy the canonicalized GREEN xUnit file to
`docs/verification/goldens/2026-07-17-step0-xunit-canonical.xml` and commit it.
This golden is the Level 2 baseline for the Phase 5 refactor: future runs of this
campaign must reproduce it byte-identically after canonicalization, with any
intentional difference explicitly approved and the golden re-committed.

## Results log

| Date | Library | Runner | Outcome | Notes |
|---|---|---|---|---|
| _pending_ | 2026.4.9.1 | | RED run | |
| _pending_ | 2026.7.17.1 | | GREEN run | |
```

- [ ] **Step 3: Commit (TcUnitFork)**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md docs/verification/Canonicalize-XUnit.ps1
git commit -m "docs(step0): add committed verification procedure and xUnit canonicalization script

- 2026-07-17-step0-verification.md: RED/GREEN campaign procedure with 13 expected observations
- Canonicalize-XUnit.ps1: blanks time attributes for byte-comparable goldens

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

---

### Task 4: USER ACTION — RED run against 2026.4.9.1

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (fill "RED actual" column and results log)

**Interfaces:**
- Consumes: the run recipe from Task 3; campaign from Tasks 1-2.
- Produces: recorded proof that all three defects reproduce (the Red of red-green). Tasks 5-7 must not start until every RED row matches.

- [ ] **Step 1: Ask Scott to execute the RED run**

Present the Task 3 run recipe verbatim. TwinCAT_Tests still references `TcUnit, 2026.4.9.1` — no reference change needed for RED.

- [ ] **Step 2: Record results**

Fill the "RED actual" column and the results-log row from Scott's report. Expected: rows 2, 3, 5, 6, 7, 9 show the defects (regression tests fail, completion never latches, counts wrong).

If any RED row does NOT match (e.g., a regression test unexpectedly passes), STOP: the test is not exercising the defect — rework the test in Task 1/2 before touching any implementation.

- [ ] **Step 3: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md
git commit -m "docs(step0): record RED run results against TcUnit 2026.4.9.1

- 2026-07-17-step0-verification.md: all three defects reproduced; regression tests proven load-bearing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

---

### Task 5: FB_TimedTestSuite hardening (Phase 4a fixes)

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_TimedTestSuite.TcPOU`

**Interfaces:**
- Consumes: inherited `FB_TestSuite` members `Tests[]`, `GetCurrentTaskIndex` (FB instance), `TraceWithSeverity`; `GVL_TcUnit.CurrentTestNameBeingCalled`; `TwinCAT_SystemInfoVarList._TaskInfo[].CycleCount`.
- Produces: hardened invariant — `_nActiveTimedTestIdx` is valid only when set in the CURRENT task cycle by a `TEST_TIMED*` call whose test name is still the framework's current test. New PRIVATE method `_GetActiveWaitContext : UINT` (returns 0 = no valid context). Public API unchanged.

- [ ] **Step 1: Generate one fresh GUID** for the new method (same command/uniqueness check as Task 1 Step 2). Use as `<GUID-4>`.

- [ ] **Step 2: Add the two new VARs**

In the FUNCTION_BLOCK declaration, change:

```iecst
VAR
    TimedTestStates      : ARRAY[1..GVL_Param_TcUnit.MaxNumberOfTestsForEachTestSuite] OF ST_TimedTestState;
    _nActiveTimedTestIdx : UINT;
END_VAR
```

to:

```iecst
VAR
    TimedTestStates      : ARRAY[1..GVL_Param_TcUnit.MaxNumberOfTestsForEachTestSuite] OF ST_TimedTestState;
    _nActiveTimedTestIdx : UINT;
    (* Task cycle in which _nActiveTimedTestIdx was set; a wait helper only accepts
       the context if it was set in the same cycle (guards cross-scan staleness) *)
    _nActiveTimedTestCycle : UDINT;
    // One-shot for the out-of-context wait Error trace (cyclic path - must not storm)
    bOutOfContextWaitTraced : BOOL;
END_VAR
```

- [ ] **Step 3: Add the `_GetActiveWaitContext` method**

Add as a new `<Method>` element (before the closing `</POU>`), with `<GUID-4>`:

```xml
    <Method Name="_GetActiveWaitContext" Id="<GUID-4>">
      <Declaration><![CDATA[(* Returns the timed-test index for a wait-helper call, or 0 when the call is
   out of context. Valid context requires all three: an index was set, it was
   set in the current task cycle (TEST_TIMED* ran earlier in this scan and
   selected this test for body execution), and the framework's current test
   name still matches (defense against later TEST() calls in the same scan). *)
METHOD PRIVATE _GetActiveWaitContext : UINT
VAR
    idx : UINT;
END_VAR]]></Declaration>
      <Implementation>
        <ST><![CDATA[_GetActiveWaitContext := 0;
idx := _nActiveTimedTestIdx;
IF idx = 0 THEN
    RETURN;
END_IF

GetCurrentTaskIndex();
IF _nActiveTimedTestCycle <> TwinCAT_SystemInfoVarList._TaskInfo[GetCurrentTaskIndex.index].CycleCount THEN
    RETURN;
END_IF

IF Tests[idx].GetName() <> GVL_TcUnit.CurrentTestNameBeingCalled THEN
    RETURN;
END_IF

_GetActiveWaitContext := idx;]]></ST>
      </Implementation>
    </Method>
```

- [ ] **Step 4: Fix the context lifecycle in TEST_TIMED**

Remove the early assignment (currently after the `_FindTestIndex` null check):

```iecst
_nActiveTimedTestIdx := idx;
```

and instead set the context immediately before the body-executes return at the end of the method, so every early-return path leaves the context cleared (it is reset to 0 at Step 1 of the method):

```iecst
// Step 9: Test body should execute - arm the wait context for this cycle only
_nActiveTimedTestIdx := idx;
GetCurrentTaskIndex();
_nActiveTimedTestCycle := TwinCAT_SystemInfoVarList._TaskInfo[GetCurrentTaskIndex.index].CycleCount;
TEST_TIMED := TRUE;
```

- [ ] **Step 5: Fix the context lifecycle in TEST_TIMED_ORDERED**

Identical change: remove `_nActiveTimedTestIdx := idx;` from Step 9 of that method, and change the final lines (after the `SetStartedAtIfNotSet` block) to:

```iecst
// Step 14: Test body should execute - arm the wait context for this cycle only
_nActiveTimedTestIdx := idx;
GetCurrentTaskIndex();
_nActiveTimedTestCycle := TwinCAT_SystemInfoVarList._TaskInfo[GetCurrentTaskIndex.index].CycleCount;
TEST_TIMED_ORDERED := TRUE;
```

- [ ] **Step 6: Route WaitForTime through the guard with a one-shot trace**

Replace the first two steps of `WaitForTime`:

```iecst
WaitForTime := FALSE;
idx := _nActiveTimedTestIdx;

// Step 1: Context check
IF idx = 0 THEN
    TraceWithSeverity(
        Message := 'WaitForTime called without active timed test context',
        Severity := TcEventSeverity.Error);
    RETURN;
END_IF
```

with:

```iecst
WaitForTime := FALSE;
idx := _GetActiveWaitContext();

// Step 1: Context check (one-shot trace - this path is cyclic)
IF idx = 0 THEN
    IF NOT bOutOfContextWaitTraced THEN
        bOutOfContextWaitTraced := TRUE;
        TraceWithSeverity(
            Message := 'WaitForTime called without active timed test context',
            Severity := TcEventSeverity.Error);
    END_IF
    RETURN;
END_IF
```

- [ ] **Step 7: Same change in WaitForCondition**

Apply the identical replacement in `WaitForCondition` (message text `'WaitForCondition called without active timed test context'`).

- [ ] **Step 8: Route WaitTimedOut through the guard**

Replace the property Get implementation:

```iecst
IF _nActiveTimedTestIdx > 0 THEN
    WaitTimedOut := TimedTestStates[_nActiveTimedTestIdx].bConditionTimedOut;
ELSE
    WaitTimedOut := FALSE;
END_IF
```

with (also add `idx : UINT;` to the Get accessor's currently empty `VAR ... END_VAR` block):

```iecst
idx := _GetActiveWaitContext();
IF idx > 0 THEN
    WaitTimedOut := TimedTestStates[idx].bConditionTimedOut;
ELSE
    WaitTimedOut := FALSE;
END_IF
```

- [ ] **Step 9: Trim the lookup name in GetTimedTestResult**

At the top of `GetTimedTestResult`, before `idx := _FindTestIndex(...)`, add:

```iecst
// Normalize the same way TEST(), TEST_ORDERED(), and TEST_TIMED() do
TestName := F_LTrim(in := F_RTrim(in := TestName));
```

- [ ] **Step 10: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU
git commit -m "fix(timed-suite): cycle-guarded wait context, one-shot misuse traces, trimmed result lookup

- FB_TimedTestSuite.TcPOU: context armed only when a body executes and validated per task cycle + test name (_GetActiveWaitContext); out-of-context wait traces one-shot; GetTimedTestResult trims TestName

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

Known residual (documented in Task 9's breadcrumb update): a bare wait placed in the same scan immediately after an executing block, while that block's test is still the current test, is textually indistinguishable from a legitimate in-body call and remains accepted.

---

### Task 6: RUN_IN_SEQUENCE completion fix

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_TcUnitRunner.TcPOU` (method `RunTestSuiteTestsInSequence` only)

**Interfaces:**
- Consumes: existing `AllTestSuitesFinished` latch and `NumberOfTestSuitesFinished` scan-local completion check.
- Produces: `AllTestSuitesFinished` latches TRUE one scan after the final suite reports finished, for any suite count including 1. Parallel runner untouched.

- [ ] **Step 1: Replace the advance/finish block**

In `RunTestSuiteTestsInSequence`, replace:

```iecst
        IF GVL_TcUnit.TestSuiteAddresses[CurrentlyRunningTestSuite]^.AreAllTestsFinished() THEN
            IF CurrentlyRunningTestSuite <> GVL_TcUnit.NumberOfInitializedTestSuites THEN
                NumberOfTestSuitesFinished := NumberOfTestSuitesFinished + 1;
                CurrentlyRunningTestSuite := CurrentlyRunningTestSuite + 1;
                TimerBetweenExecutionOfTestSuites.IN := TRUE;
				GVL_TcUnit.CurrentTestSuiteBeingCalled^.CalculateDuration(FinishedAt := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
            END_IF
```

with:

```iecst
        IF GVL_TcUnit.TestSuiteAddresses[CurrentlyRunningTestSuite]^.AreAllTestsFinished() THEN
            IF CurrentlyRunningTestSuite <> GVL_TcUnit.NumberOfInitializedTestSuites THEN
                (* Address the finished suite directly: CurrentTestSuiteBeingCalled is
                   null until a suite has executed, e.g. when the first suite is empty *)
                GVL_TcUnit.TestSuiteAddresses[CurrentlyRunningTestSuite]^.CalculateDuration(FinishedAt := F_GetCpuCounterAs64bit(GVL_TcUnit.GetCpuCounter));
                CurrentlyRunningTestSuite := CurrentlyRunningTestSuite + 1;
                TimerBetweenExecutionOfTestSuites.IN := TRUE;
            ELSE
                (* The cursor is on the final suite and it reports finished - the whole
                   sequence is done. NumberOfTestSuitesFinished is a method VAR (reset
                   every call), so incremental counting can never reach the total; the
                   completion latch below fires from this assignment. Breadcrumb #19. *)
                NumberOfTestSuitesFinished := GVL_TcUnit.NumberOfInitializedTestSuites;
            END_IF
```

(The existing `ELSIF NOT TimerBetweenExecutionOfTestSuites.Q THEN ... END_IF`, abort block, and `IF NumberOfTestSuitesFinished = ... THEN AllTestSuitesFinished := TRUE` latch stay exactly as they are.)

- [ ] **Step 2: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/POUs/FB_TcUnitRunner.TcPOU
git commit -m "fix(runner): RUN_IN_SEQUENCE completion latches when the final suite finishes

- FB_TcUnitRunner.TcPOU: final-suite branch publishes the full finished count (method VAR resets each scan, so incremental counting never completed - breadcrumb #19); duration call addresses the finished suite directly instead of the possibly-null CurrentTestSuiteBeingCalled

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

---

### Task 7: xUnit count semantics

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\DUTs\ST_TestSuiteResult.TcDUT`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\DUTs\ST_TestSuiteResults.TcDUT`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_TestResults.TcPOU`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_xUnitXmlPublisher.TcPOU`

**Interfaces:**
- Consumes: existing `FB_TestSuite.GetNumberOfSkippedTests()` (INTERNAL, already present).
- Produces: `ST_TestSuiteResult.NumberOfSkippedTests : UINT(...)`; `ST_TestSuiteResults.NumberOfSkippedTestCases : UINT`; invariant `NumberOfTestCases = Successful + Failed + Skipped`; xUnit root `tests` = total (was successful-only), root+suite `skipped` attributes. ADS text format unchanged (the printed successful number changes semantically — spec-approved bug fix, observation row 12). Adding struct fields grows the (padded) struct — no consumer memory issue, but note it compiles all consumers on next qualification.

- [ ] **Step 1: Add the per-suite skipped field**

In `ST_TestSuiteResult.TcDUT`, after `NumberOfFailedTests`:

```iecst
    NumberOfSkippedTests : UINT(0..GVL_Param_TcUnit.MaxNumberOfTestsForEachTestSuite);
```

- [ ] **Step 2: Add the aggregate skipped field**

In `ST_TestSuiteResults.TcDUT`, after `NumberOfFailedTestCases`:

```iecst
    NumberOfSkippedTestCases : UINT; // The total number of test cases that were skipped (disabled)
```

- [ ] **Step 3: Store and aggregate skipped counts in FB_TestResults**

In the FB body, after the "Store number of failed tests in test suite" block, add:

```iecst
        // Store number of skipped tests in test suite
        TestSuiteResults.TestSuiteResults[StoringTestSuiteResultNumber].NumberOfSkippedTests :=
            GVL_TcUnit.TestSuiteAddresses[StoringTestSuiteResultNumber]^.GetNumberOfSkippedTests();
```

In the aggregate FOR loop, replace:

```iecst
        TestSuiteResults.NumberOfSuccessfulTestCases := TestSuiteResults.NumberOfSuccessfulTestCases +
                                                        (TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfTests -
                                                         TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfFailedTests);
        TestSuiteResults.NumberOfFailedTestCases := TestSuiteResults.NumberOfFailedTestCases + TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfFailedTests;
```

with:

```iecst
        (* A skipped test is not a successful test: total = passed + failed + skipped *)
        TestSuiteResults.NumberOfSuccessfulTestCases := TestSuiteResults.NumberOfSuccessfulTestCases +
                                                        (TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfTests -
                                                         TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfFailedTests -
                                                         TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfSkippedTests);
        TestSuiteResults.NumberOfFailedTestCases := TestSuiteResults.NumberOfFailedTestCases + TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfFailedTests;
        TestSuiteResults.NumberOfSkippedTestCases := TestSuiteResults.NumberOfSkippedTestCases + TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfSkippedTests;
```

- [ ] **Step 4: Correct the xUnit attributes in FB_xUnitXmlPublisher**

Replace the root-element parameters:

```iecst
    Xml.NewParameter('failures', UINT_TO_STRING(UnitTestResults.NumberOfFailedTestCases));
    Xml.NewParameter('tests', UINT_TO_STRING(UnitTestResults.NumberOfSuccessfulTestCases));
    Xml.NewParameter('time', LREAL_TO_STRING(UnitTestResults.Duration));
```

with:

```iecst
    Xml.NewParameter('failures', UINT_TO_STRING(UnitTestResults.NumberOfFailedTestCases));
    (* 'tests' is the TOTAL testcase count; the previous successful-only value was a bug *)
    Xml.NewParameter('tests', UINT_TO_STRING(UnitTestResults.NumberOfTestCases));
    Xml.NewParameter('skipped', UINT_TO_STRING(UnitTestResults.NumberOfSkippedTestCases));
    Xml.NewParameter('time', LREAL_TO_STRING(UnitTestResults.Duration));
```

And the per-suite parameters — after the suite `failures` line:

```iecst
        Xml.NewParameter('failures', UINT_TO_STRING(UnitTestResults.TestSuiteResults[CurrentSuiteNumber].NumberOfFailedTests));
```

add:

```iecst
        Xml.NewParameter('skipped', UINT_TO_STRING(UnitTestResults.TestSuiteResults[CurrentSuiteNumber].NumberOfSkippedTests));
```

- [ ] **Step 5: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/DUTs/ST_TestSuiteResult.TcDUT TcUnit/TcUnit/DUTs/ST_TestSuiteResults.TcDUT TcUnit/TcUnit/POUs/FB_TestResults.TcPOU TcUnit/TcUnit/POUs/FB_xUnitXmlPublisher.TcPOU
git commit -m "fix(xunit): total = passed + failed + skipped; root tests attribute reports total

- ST_TestSuiteResult.TcDUT: add NumberOfSkippedTests
- ST_TestSuiteResults.TcDUT: add NumberOfSkippedTestCases
- FB_TestResults.TcPOU: store per-suite skipped; successful no longer includes skipped
- FB_xUnitXmlPublisher.TcPOU: root tests = total testcases (was successful-only); skipped attribute at root and suite level

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

---

### Task 8: Version bump 2026.7.17.1, USER ACTION — build and install the library

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\TcUnit.plcproj` (`<ProjectVersion>`, line ~35)
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\Version\Global_Version.TcGVL` (line ~10)
- Create (regenerated by XAE): `C:\Users\scott\Documents\TcUnitFork\TcUnit.library`

**Interfaces:**
- Consumes: Tasks 5-7 source changes.
- Produces: installed library `TcUnit 2026.7.17.1 (www.tcunit.org)`; git tag `TcUnit-2026.7.17.1`. This commit also resolves the long-standing working-tree deletion of `TcUnit.library` by committing the freshly built binary.

- [ ] **Step 1: Bump both version locations**

In `TcUnit.plcproj`: `<ProjectVersion>2026.4.9.1</ProjectVersion>` → `<ProjectVersion>2026.7.17.1</ProjectVersion>`

In `Global_Version.TcGVL`:

```iecst
	stLibVersion_TcUnit : ST_LibVersion := (iMajor := 2026, iMinor := 7, iBuild := 17, iRevision := 1, nFlags := 0, sVersion := '2026.7.17.1');
```

- [ ] **Step 2: USER ACTION — build and install in XAE**

Ask Scott to:
1. Open `TcUnit.sln` in XAE.
2. Build (Ctrl+Shift+B). Expected: 0 errors. If compile errors appear in Tasks 5-7 code, report them back verbatim — fix, and rebuild before continuing.
3. Right-click PLC project → "Save as library and install..." → save as `C:\Users\scott\Documents\TcUnitFork\TcUnit.library` (repo root, replacing the deleted file).
4. Confirm the library repository shows TcUnit 2026.7.17.1.

- [ ] **Step 3: Commit and tag**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/TcUnit.plcproj TcUnit/TcUnit/Version/Global_Version.TcGVL TcUnit.library
git commit -m "chore(release): TcUnit 2026.7.17.1 - step-0 fixes compiled and installed

- TcUnit.plcproj: ProjectVersion 2026.7.17.1
- Global_Version.TcGVL: stLibVersion_TcUnit 2026.7.17.1
- TcUnit.library: rebuilt binary (also restores the previously deleted file)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
git tag TcUnit-2026.7.17.1
```

---

### Task 9: USER ACTION — GREEN run, golden capture, doc reconciliation

**Files:**
- Modify: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests.plcproj` (`<Resolution>TcUnit, 2026.4.9.1 ...` line ~592)
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (GREEN column + results log)
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\goldens\2026-07-17-step0-xunit-canonical.xml`
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\PROJECT_STATE.md`, `docs\EXECUTION_PLAN.md`, `docs\BREADCRUMBS.md`

**Interfaces:**
- Consumes: installed 2026.7.17.1; Task 3 procedure; Task 4 RED baseline.
- Produces: Step-0 acceptance evidence; committed golden; Phase 4a/4b closed in tracking docs; the next plan (compile/ABI spike) unblocked.

- [ ] **Step 1: Point TwinCAT_Tests at the new library**

In `TwinCAT_Tests.plcproj`: `<Resolution>TcUnit, 2026.4.9.1 (www.tcunit.org)</Resolution>` → `<Resolution>TcUnit, 2026.7.17.1 (www.tcunit.org)</Resolution>`

- [ ] **Step 2: USER ACTION — GREEN run**

Ask Scott to repeat the Task 3 run recipe exactly. Every GREEN-column row must match — headline values: `AllTestSuitesFinished` = TRUE within 60 s; root `tests="8"`, `failures="1"`, `skipped="1"` (only the intentional fixture failure remains); the out-of-context wait trace appears exactly once.

- [ ] **Step 3: Capture the golden**

```powershell
pwsh -File C:\Users\scott\Documents\TcUnitFork\docs\verification\Canonicalize-XUnit.ps1 -Path C:\tcunit_xunit_testresults.xml -OutPath C:\Users\scott\Documents\TcUnitFork\docs\verification\goldens\2026-07-17-step0-xunit-canonical.xml
```

Then Read the golden and verify the attribute rows (7-11) against the table before committing.

- [ ] **Step 4: Record results and reconcile docs**

- Fill GREEN column + results log in the verification doc.
- `PROJECT_STATE.md`: Phase 4 row → Done (hardened + verified); tech-debt items for `_nActiveTimedTestIdx`, `GetTimedTestResult` trim, missing Phase 4 validation, and `RUN_IN_SEQUENCE` verifier path → resolved (strikethrough with date); "What is Active" row updated.
- `EXECUTION_PLAN.md`: Phase 4a/4b → Completed Work table; Phase 5 step 1 (compile/ABI spike) becomes "What to Build Next"; Phase 5 implementation-sequence item 1 marked done.
- `BREADCRUMBS.md`: update gotcha #19 solution line (fixed 2026-07-17, regression = PRG_TEST_TCUNIT_STEP0 campaign + golden); add gotcha: timed wait context is cycle-guarded — a bare wait in the same scan directly after an executing block remains undetectable by design; document the `disabled_` prefix ↔ skipped-count semantics and the corrected root `tests` attribute as an intentional divergence from upstream.

- [ ] **Step 5: Commit both repos**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TwinCAT_Tests.plcproj
git commit -m "chore(tcunit-step0): consume TcUnit 2026.7.17.1

- TwinCAT_Tests.plcproj: TcUnit resolution 2026.4.9.1 -> 2026.7.17.1

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"

cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md docs/verification/goldens/2026-07-17-step0-xunit-canonical.xml docs/PROJECT_STATE.md docs/EXECUTION_PLAN.md docs/BREADCRUMBS.md
git commit -m "docs(step0): GREEN run recorded, golden committed, Phase 4a/4b closed

- 2026-07-17-step0-verification.md: all 13 observations green against 2026.7.17.1
- goldens/2026-07-17-step0-xunit-canonical.xml: Level 2 baseline for the Phase 5 refactor
- PROJECT_STATE.md / EXECUTION_PLAN.md / BREADCRUMBS.md: Phase 4a/4b complete; next: compile/ABI spike

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EoFvrbvCLLZNw4VWSCLxi6"
```

---

## Out of scope (deferred to later plans in the series)

- `<skipped/>` child elements, UTF-8/control-char/decimal formatting contract → reporting-pipeline plan (spec step 6).
- TcUnit-Verifier_DotNet expectation updates → verifier plan (the verifier is not currently the active validation path; VERIFIER_IMPROVEMENT_PLAN.md tracks its modernization).
- TwinCATBase ring-buffer multi-writer audit → TwinCATBase repo (external production gate).
- All coordinator/tagging/multi-task work → spec steps 1-8 plans.
