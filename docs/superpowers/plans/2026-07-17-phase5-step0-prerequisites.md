# Phase 5 Step-0 Prerequisites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision 4** — Rev 2 incorporated the first review (release gating, xUnit path/freshness, UDINT aggregates, verifier gate, ordered coverage, campaign split, XML semantic assertions, preflight, Parameters merge, attribution removal). Rev 3 incorporated the second review: campaign isolation replaces the unverified multi-PRG registration assumption (exclude-from-build per campaign + empirical suite-count preflight + hard failure on unexpected suites), a dedicated deterministic abort campaign, and a verifier-repo cleanliness gate after the manual S1 switch. Rev 4 re-baselines after the 2026-07-17 toolchain-validation release: **TcUnit 2026.7.17.1 shipped as the RED baseline** (it contains all three Step-0 defects; it is NOT the Step-0 release), the Step-0 candidate version is determined at execution time, library build/install is automated via `tpm library save`, and stale exact-suite-isolation/S1 wording from Rev 2 is reconciled.

**Goal:** Complete the Step-0 prerequisites of the multi-task tagged execution design: harden FB_TimedTestSuite (Phase 4a), fix the RUN_IN_SEQUENCE completion latch, correct xUnit count semantics with UDINT-wide aggregates, and prove all three with committed red-green verification campaigns, ending with the Step-0 candidate library released only after GREEN + verifier evidence.

**Architecture:** Test artifacts are written first (TwinCAT_Tests campaigns + a sequential check in TcUnit-Verifier), run RED against the installed TcUnit 2026.7.17.1 baseline, then the fixes land in TcUnitFork sources, the Step-0 candidate is built and installed via `tpm library save` (headless — proven 2026-07-17), the existing .NET verifier must pass unchanged, the GREEN campaigns must pass the XML semantic verifier script, and only then is the library binary committed and tagged. Campaign runs remain XAE-manual (task assignment and build exclusions); every run step is an exact procedure with script-asserted expected values.

**Tech Stack:** TwinCAT 3.1.4026.x XAE, IEC 61131-3 ST (`.TcPOU`/`.TcDUT` XML), TcUnit fork, PowerShell 7 for XML verification, TcUnit-Verifier_DotNet, git.

## Plan sequence context

This is **Plan 1 of the Phase 5 series** (spec: `docs/superpowers/specs/2026-07-16-multitask-tagged-execution-design.md`, implementation order step 0). Later plans, in order: compile/ABI spike; status+seams+coordinator skeleton; task-context migration; planning/barriers+selective execution; reporting pipeline; multi-task verifier; consumer qualification. The TwinCATBase multi-writer audit is an **external gate** in the TwinCATBase repo — it gates production multi-task enablement, not this plan. The fully .NET-automated `RUN_IN_SEQUENCE` verifier configuration lands with the verifier plan; this plan commits the sequential single-suite check (Task 4) as its committed precursor.

## Global Constraints

- Every new TwinCAT object AND every new method gets a fresh random GUID: `python -c "import uuid; print('{' + str(uuid.uuid4()) + '}')"` — never reuse or pattern GUIDs; verify uniqueness with Grep across BOTH repos before adding.
- ASCII only in ST string literals (no em dashes/arrows) — they corrupt UTF-8 log parsing.
- `.TcPOU`/`.TcDUT`/`.TcGVL` files on disk are NOT built unless listed as `<Compile Include>` in the `.plcproj`; new folders need `<Folder Include>`.
- Library version lives in TWO files that must stay in sync: `TcUnit/TcUnit/TcUnit.plcproj` `<ProjectVersion>` and `TcUnit/TcUnit/Version/Global_Version.TcGVL` `stLibVersion_TcUnit`. **RED baseline: `2026.7.17.1`** — released/tagged 2026-07-17 as a toolchain-validation rebuild; it contains all three Step-0 defects and must never be mistaken for the Step-0 release. **Step-0 candidate version (written `<candidate>` in commands below): the next `YYYY.M.D.revision` per the versioning rules on the day Task 10 executes** (new day → revision 1; same-day rebuilds increment revision). The tag `TcUnit-<candidate>` is created ONLY in Task 13, after GREEN + verifier evidence.
- Never use IEC reserved words (`DT`, `TIME_OF_DAY`, …) as identifiers.
- Any `TraceWithSeverity` reachable cyclically MUST be one-shot guarded.
- Do not remove or weaken existing assertions or public API. New members allowed by this plan: `FB_TimedTestSuite._GetActiveWaitContext` (PRIVATE method), two new VARs on FB_TimedTestSuite, two new DUT fields, UDINT widening of four aggregate DUT fields — all within the Phase 5 spec Step-0 scope.
- Commit messages: first line summary + per-file `- filename:` bullets. No co-author or session metadata.
- TcUnitFork work happens on branch `feat/timed-test-suite`; TwinCAT_Tests work on new branch `feat/tcunit-step0` created from a clean tree (Task 0 gates this).
- XAE builds/runs are USER ACTIONS — Scott runs them; the executor prepares exact instructions and waits for reported results before proceeding.
- `TcUnit.library` at the fork repo root is currently deleted in the working tree (pre-existing). It is regenerated in Task 10 and committed only in Task 13 — do not restore or commit it earlier.
- Campaign xUnit path: `%TC_BOOTPRJPATH%tcunit_step0_xunit.xml` (resolves to `C:\TwinCAT\3.1\Boot\tcunit_step0_xunit.xml` on this machine). TcUnit's default is `%TC_BOOTPRJPATH%tcunit_xunit_testresults.xml` — the campaign uses its own name so no other run can be mistaken for it.
- **Campaign isolation** (drives all count expectations): whether suite instances in PRGs not assigned to any task register via `FB_init` is deliberately NOT assumed — it is a TwinCAT linker/initialization behavior this plan verifies empirically instead of asserting. Every campaign run therefore: (a) excludes ALL non-campaign test PRGs from build (`PRG_TEST_*` and the other step-0 campaign PRGs) via XAE "Exclude from build"; (b) asserts `TcUnit.GVL_TcUnit.NumberOfInitializedTestSuites` equals the exact campaign suite count online before results are trusted — a mismatch is a hard STOP (isolation broken or registration behaves unexpectedly; record what was observed); (c) the verifier script hard-fails on ANY suite in the xUnit file that is not in the campaign model. Suite `id` attributes depend on registration order and are never asserted. What the preflight empirically shows about unassigned-PRG registration is recorded in the verification doc — it settles a question the Phase 5 design needs answered anyway.

---

### Task 0: Preflight — repo state gate

**Files:**
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (baseline appendix only; Task 5 fills the body)

**Interfaces:**
- Produces: recorded `git status` baselines for both repos; a clean starting tree for the TwinCAT_Tests campaign branch.

- [ ] **Step 1: Record both repo states**

```powershell
cd C:\Users\scott\Documents\TcUnitFork; git status --porcelain; git log -1 --oneline
cd C:\Users\scott\Documents\TwinCAT_Tests; git status --porcelain; git branch --show-current; git log -1 --oneline
```

Save both outputs verbatim into a "Baseline repo state" appendix section of the verification doc (create the file with just a title and this appendix; Task 5 prepends the procedure body).

- [ ] **Step 2: Gate on TwinCAT_Tests cleanliness**

TwinCAT_Tests is known to have uncommitted local edits including `TwinCAT_Tests.plcproj`. Do NOT stash or commit them unilaterally. Ask Scott to disposition them first (commit on their own branch, or stash with a named stash), so `feat/tcunit-step0` branches from a clean tree and this campaign's plcproj diff contains only campaign changes. STOP until the tree is clean or Scott explicitly approves branching with specific listed files left dirty (record the approval in the appendix).

- [ ] **Step 3: Create the campaign branch and commit the baseline**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests; git checkout -b feat/tcunit-step0
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md
git commit -m "docs(step0): record preflight repo baselines

- 2026-07-17-step0-verification.md: baseline git state for TcUnitFork and TwinCAT_Tests"
```

---

### Task 1: Timed unordered suite tests (TwinCAT_Tests, written first)

**Files:**
- Create: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TcUnitTests\FB_TimedSuiteGreenPathTests.TcPOU`

**Interfaces:**
- Consumes: `TcUnit.FB_TimedTestSuite` API as shipped in 2026.7.17.1: `TEST_TIMED(TestName, tSafetyTimeout)`, `WaitForTime(tDuration)`, `WaitForCondition(bCondition, tTimeout)`, `WaitTimedOut`, `GetTimedTestResult(TestName) : ST_TimedTestResult` (fields `TestName`, `bIsFinished`).
- Produces: FB `FB_TimedSuiteGreenPathTests` with 5 tests: `Test_Wait1s`, `Test_ConditionMet`, `Test_ConditionTimeoutDetected`, `Test_PaddedNameLookup`, `Test_StaleContextGuard`. Task 3's regression PRG instantiates it as `TimedSuiteTests`.

- [ ] **Step 1: Generate one fresh GUID**

Run: `python -c "import uuid; print('{' + str(uuid.uuid4()) + '}')"`
Grep the printed GUID across `C:\Users\scott\Documents\TwinCAT_Tests` and `C:\Users\scott\Documents\TcUnitFork` (expected: no matches). Use as `<GUID-1>`.

- [ ] **Step 2: Write the failing tests**

Create `FB_TimedSuiteGreenPathTests.TcPOU` (substitute `<GUID-1>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_TimedSuiteGreenPathTests" Id="<GUID-1>" SpecialFunc="None">
    <Declaration><![CDATA[(* Level 1 green-path and Phase 4a regression tests for TcUnit.FB_TimedTestSuite.
   Test_PaddedNameLookup and Test_StaleContextGuard are regressions for the two
   Phase 4a hardening items (GetTimedTestResult trim, stale wait context). They
   FAIL against the TcUnit 2026.7.17.1 baseline and PASS from the Step-0 candidate.
   The WaitTimedOut probe latch is asserted in the guard test; its defect is not
   independently red-demonstrable (masked by the WAIT_MISUSE kill), but it routes
   through the same _GetActiveWaitContext guard that the two red-proven probes
   (here and in FB_TimedOrderedGreenPathTests) exercise. *)
FUNCTION_BLOCK FB_TimedSuiteGreenPathTests EXTENDS TcUnit.FB_TimedTestSuite
VAR
    nConditionCounter             : UDINT;
    bBareWaitReturn               : BOOL;
    bOutOfContextWaitReturnedTrue : BOOL;
    bStaleWaitTimedOutObserved    : BOOL;
    stPaddedLookup                : TcUnit.ST_TimedTestResult;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[(* Regression probes for the stale timed-context gotcha: helpers called before
   any timed test block in this scan must never bind to the previous scan's
   context. Against 2026.7.17.1 both bind to the last block's state. *)
bBareWaitReturn := WaitForTime(tDuration := T#10MS);
IF bBareWaitReturn THEN
    bOutOfContextWaitReturnedTrue := TRUE;
END_IF
IF WaitTimedOut THEN
    bStaleWaitTimedOutObserved := TRUE;
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
        AssertFalse(Condition := bStaleWaitTimedOutObserved, Message := 'Out-of-context WaitTimedOut must always read FALSE');
        TEST_FINISHED();
    END_IF
END_IF]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

Why the regressions are RED against 2026.7.17.1: `TEST_TIMED` sets `_nActiveTimedTestIdx` before its finished-check and never clears it between scans, so the bare `WaitForTime` at the top of the body binds to the previous scan's last block (`Test_StaleContextGuard`, whose wait type is Condition) and kills it with `Type_WAIT_MISUSE` from scan 2 onward. `GetTimedTestResult` does not trim, so the padded lookup never resolves, its condition wait times out, and both of its asserts fail.

- [ ] **Step 3: Commit**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TcUnitTests/FB_TimedSuiteGreenPathTests.TcPOU
git commit -m "test(tcunit-step0): timed-suite Level 1 + Phase 4a regressions (red vs 2026.7.17.1)

- FB_TimedSuiteGreenPathTests.TcPOU: 3 green-path timed tests plus padded-name, stale-WaitForTime, and stale-WaitTimedOut probes"
```

(Unwired files are safe to commit — TwinCAT builds only plcproj-listed files; wiring lands in Task 3.)

---

### Task 2: Timed ORDERED suite tests (TwinCAT_Tests)

**Files:**
- Create: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TcUnitTests\FB_TimedOrderedGreenPathTests.TcPOU`

**Interfaces:**
- Consumes: `TcUnit.FB_TimedTestSuite.TEST_TIMED_ORDERED(TestName, tSafetyTimeout)` plus the wait helpers.
- Produces: FB `FB_TimedOrderedGreenPathTests` with 3 ordered tests `Test_Ordered1_Wait`, `Test_Ordered2_ConditionMet`, `Test_Ordered3_Guard`. Covers the `TEST_TIMED_ORDERED` context-lifecycle change and the out-of-context `WaitForCondition` path. Task 3's regression PRG instantiates it as `TimedOrderedTests`.

- [ ] **Step 1: Generate one fresh GUID** (same command/uniqueness check). Use as `<GUID-2>`.

- [ ] **Step 2: Write the failing tests**

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_TimedOrderedGreenPathTests" Id="<GUID-2>" SpecialFunc="None">
    <Declaration><![CDATA[(* Ordered timed-test coverage for TEST_TIMED_ORDERED plus the out-of-context
   WaitForCondition regression. Against 2026.7.17.1 the bare WaitForCondition
   probe binds Test_Ordered3_Guard's context one scan into its turn (its wait
   type is Time, the probe is Condition) and kills it with Type_WAIT_MISUSE.
   From the Step-0 candidate the cycle guard rejects the probe and all 3 tests pass.
   RED-run note: during turns 1-2 the probe sees no context (ordered blocks
   reset it), so 2026.7.17.1 emits its unguarded out-of-context Error trace
   repeatedly - expected noise that itself evidences the missing one-shot. *)
FUNCTION_BLOCK FB_TimedOrderedGreenPathTests EXTENDS TcUnit.FB_TimedTestSuite
VAR
    nOrderedConditionCounter           : UDINT;
    bBareConditionReturn               : BOOL;
    bOutOfContextConditionReturnedTrue : BOOL;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[bBareConditionReturn := WaitForCondition(bCondition := FALSE, tTimeout := T#50MS);
IF bBareConditionReturn THEN
    bOutOfContextConditionReturnedTrue := TRUE;
END_IF

IF TEST_TIMED_ORDERED(TestName := 'Test_Ordered1_Wait', tSafetyTimeout := T#10S) THEN
    IF WaitForTime(tDuration := T#500MS) THEN
        AssertFalse(Condition := WaitTimedOut, Message := 'Ordered time wait must not report a condition timeout');
        TEST_FINISHED();
    END_IF
END_IF

IF TEST_TIMED_ORDERED(TestName := 'Test_Ordered2_ConditionMet', tSafetyTimeout := T#10S) THEN
    nOrderedConditionCounter := nOrderedConditionCounter + 1;
    IF WaitForCondition(bCondition := (nOrderedConditionCounter >= 5), tTimeout := T#5S) THEN
        AssertFalse(Condition := WaitTimedOut, Message := 'Ordered condition must be met before timeout');
        TEST_FINISHED();
    END_IF
END_IF

IF TEST_TIMED_ORDERED(TestName := 'Test_Ordered3_Guard', tSafetyTimeout := T#20S) THEN
    IF WaitForTime(tDuration := T#500MS) THEN
        AssertFalse(Condition := bOutOfContextConditionReturnedTrue, Message := 'Out-of-context WaitForCondition must never return TRUE');
        TEST_FINISHED();
    END_IF
END_IF]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

- [ ] **Step 3: Commit**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TcUnitTests/FB_TimedOrderedGreenPathTests.TcPOU
git commit -m "test(tcunit-step0): ordered timed-suite coverage + out-of-context WaitForCondition regression

- FB_TimedOrderedGreenPathTests.TcPOU: 3 TEST_TIMED_ORDERED tests; bare WaitForCondition probe red vs 2026.7.17.1"
```

---

### Task 3: Fixtures, edge suites, three campaign PRGs, plcproj wiring (TwinCAT_Tests)

**Files:**
- Create (in `...\TwinCAT_Tests\TcUnitTests\`): `FB_StepZeroSimplePass.TcPOU`, `FB_StepZeroEmptySuite.TcPOU`, `FB_StepZeroCounts_ShouldFail.TcPOU`, `FB_StepZeroAbortSuite.TcPOU`, `PRG_TEST_TCUNIT_STEP0.TcPOU`, `PRG_TEST_TCUNIT_STEP0_COUNTS.TcPOU`, `PRG_TEST_TCUNIT_STEP0_EDGE.TcPOU`, `PRG_TEST_TCUNIT_STEP0_ABORT.TcPOU`
- Modify: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests.plcproj`

**Interfaces:**
- Consumes: suites from Tasks 1-2; TcUnit `disabled_` prefix (registers the test as `Test_Skipped`, skipped).
- Produces: four campaigns —
  - `PRG_TEST_TCUNIT_STEP0` (REGRESSION, all-passing when green): `TimedSuiteTests`, `TimedOrderedTests` (2 suites). GREEN = zero failures anywhere.
  - `PRG_TEST_TCUNIT_STEP0_COUNTS` (COUNTS, intentional-failure fixture): `PassSuite`, `CountsSuite_ShouldFail` (2 suites). GREEN = exactly one failure, identity `Test_IntentionalFail` (script-asserted).
  - `PRG_TEST_TCUNIT_STEP0_EDGE` (EDGE, green-only): `EmptyFirstSuite`, `MidPassSuite`, `EmptyFinalSuite` (3 suites) — empty-first and empty-final suite traversal.
  - `PRG_TEST_TCUNIT_STEP0_ABORT` (ABORT, green-only): `AbortSuite` (1 suite) — deterministic abort window: its only test waits on a 5-minute condition timeout, so the run cannot complete on its own during the session and the operator aborts unhurried.
  All run `TcUnit.RUN_IN_SEQUENCE()` with a nonzero inter-suite delay (GPL override `T#100MS`). Campaign suite counts (2/2/3/1) are the expected `NumberOfInitializedTestSuites` values for the isolation preflight.

- [ ] **Step 1: Generate eight fresh GUIDs** (`<GUID-3>`…`<GUID-10>`), uniqueness-checked as before.

- [ ] **Step 2: Write the three suite FBs**

`FB_StepZeroSimplePass.TcPOU` (`<GUID-3>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_StepZeroSimplePass" Id="<GUID-3>" SpecialFunc="None">
    <Declaration><![CDATA[// Single always-passing test; reused across step-0 campaigns.
FUNCTION_BLOCK FB_StepZeroSimplePass EXTENDS TcUnit.FB_TestSuite]]></Declaration>
    <Implementation>
      <ST><![CDATA[TEST('Test_SimplePass');
AssertTrue(Condition := TRUE, Message := 'Passing test');
TEST_FINISHED();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

`FB_StepZeroEmptySuite.TcPOU` (`<GUID-4>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_StepZeroEmptySuite" Id="<GUID-4>" SpecialFunc="None">
    <Declaration><![CDATA[(* Deliberately empty suite: registers zero tests and is trivially finished.
   Placed first and last in the EDGE campaign to exercise sequential-cursor
   traversal over suites that finish without ever executing. *)
FUNCTION_BLOCK FB_StepZeroEmptySuite EXTENDS TcUnit.FB_TestSuite]]></Declaration>
    <Implementation>
      <ST><![CDATA[]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

`FB_StepZeroCounts_ShouldFail.TcPOU` (`<GUID-5>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_StepZeroCounts_ShouldFail" Id="<GUID-5>" SpecialFunc="None">
    <Declaration><![CDATA[(* Deterministic count-semantics fixture: exactly 1 pass, 1 intentional fail,
   1 skipped test (disabled_ prefix; registers as 'Test_Skipped'). Expected
   xUnit contribution: tests=3, failures=1, skipped=1. The _ShouldFail suffix
   marks the failure as intentional per repo convention. *)
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

`FB_StepZeroAbortSuite.TcPOU` (`<GUID-6>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_StepZeroAbortSuite" Id="<GUID-6>" SpecialFunc="None">
    <Declaration><![CDATA[(* Deterministic abort-window suite: the single test waits on a condition that
   never becomes TRUE with a 5-minute timeout, so the ABORT campaign cannot
   complete on its own during the session. The operator verifies the run is
   in progress, writes AbortRunningTestSuites := TRUE, and observes the latch.
   If the abort is never issued, the 5-minute timeout fails the test closed. *)
FUNCTION_BLOCK FB_StepZeroAbortSuite EXTENDS TcUnit.FB_TimedTestSuite]]></Declaration>
    <Implementation>
      <ST><![CDATA[IF TEST_TIMED(TestName := 'Test_AbortWindow', tSafetyTimeout := T#10M) THEN
    IF WaitForCondition(bCondition := FALSE, tTimeout := T#5M) THEN
        AssertTrue(Condition := FALSE, Message := 'Abort was not issued within 5 minutes');
        TEST_FINISHED();
    END_IF
END_IF]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

- [ ] **Step 3: Write the four campaign PRGs**

`PRG_TEST_TCUNIT_STEP0.TcPOU` (`<GUID-7>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="PRG_TEST_TCUNIT_STEP0" Id="<GUID-7>" SpecialFunc="None">
    <Declaration><![CDATA[(* Step-0 REGRESSION campaign (all-passing when green). Sequential run
   exercises the RUN_IN_SEQUENCE completion latch: against TcUnit 2026.7.17.1
   TcUnit.GVL_TcUnit.TcUnitRunner.AllTestSuitesFinished never becomes TRUE
   (breadcrumb #19); from the Step-0 candidate it latches TRUE. Also the abort-phase
   vehicle (timed waits give an abort window).
   Procedure: TcUnitFork docs/verification/2026-07-17-step0-verification.md *)
PROGRAM PRG_TEST_TCUNIT_STEP0
VAR
    TimedSuiteTests   : FB_TimedSuiteGreenPathTests;
    TimedOrderedTests : FB_TimedOrderedGreenPathTests;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[TcUnit.RUN_IN_SEQUENCE();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

`PRG_TEST_TCUNIT_STEP0_COUNTS.TcPOU` (`<GUID-8>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="PRG_TEST_TCUNIT_STEP0_COUNTS" Id="<GUID-8>" SpecialFunc="None">
    <Declaration><![CDATA[(* Step-0 COUNTS campaign: xUnit count-semantics fixture. GREEN means exactly
   one failed test whose identity is Test_IntentionalFail (script-asserted),
   never zero failures. Kept separate from the all-passing REGRESSION campaign
   so a green REGRESSION run is trivially recognizable. *)
PROGRAM PRG_TEST_TCUNIT_STEP0_COUNTS
VAR
    PassSuite             : FB_StepZeroSimplePass;
    CountsSuite_ShouldFail : FB_StepZeroCounts_ShouldFail;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[TcUnit.RUN_IN_SEQUENCE();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

`PRG_TEST_TCUNIT_STEP0_EDGE.TcPOU` (`<GUID-9>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="PRG_TEST_TCUNIT_STEP0_EDGE" Id="<GUID-9>" SpecialFunc="None">
    <Declaration><![CDATA[(* Step-0 EDGE campaign (green-only): empty first suite, one passing suite,
   empty final suite. Exercises sequential-cursor traversal over suites that
   finish without executing, including the duration-call path that in
   2026.7.17.1 dereferenced the possibly-null CurrentTestSuiteBeingCalled
   (fixed in the Step-0 candidate by addressing the finished suite directly). *)
PROGRAM PRG_TEST_TCUNIT_STEP0_EDGE
VAR
    EmptyFirstSuite : FB_StepZeroEmptySuite;
    MidPassSuite    : FB_StepZeroSimplePass;
    EmptyFinalSuite : FB_StepZeroEmptySuite;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[TcUnit.RUN_IN_SEQUENCE();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

`PRG_TEST_TCUNIT_STEP0_ABORT.TcPOU` (`<GUID-10>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="PRG_TEST_TCUNIT_STEP0_ABORT" Id="<GUID-10>" SpecialFunc="None">
    <Declaration><![CDATA[(* Step-0 ABORT campaign (green-only): a single suite whose only test waits on
   a 5-minute condition timeout. Procedure: verify AllTestSuitesFinished = FALSE
   and the run in progress, then online-write
   TcUnit.GVL_TcUnit.TcUnitRunner.AbortRunningTestSuites := TRUE and observe the
   latch plus the 'TEST RUN ABORTED' trace. The run cannot complete on its own
   during the session, so the abort timing is never a race. *)
PROGRAM PRG_TEST_TCUNIT_STEP0_ABORT
VAR
    AbortSuite : FB_StepZeroAbortSuite;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[TcUnit.RUN_IN_SEQUENCE();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

- [ ] **Step 4: Wire the plcproj**

In `TwinCAT_Tests.plcproj`:

1. Add `<Folder Include="TcUnitTests" />` to the Folder ItemGroup (alongside `<Folder Include="BaseTests" />`).
2. Add ten `<Compile Include>` entries to the Compile ItemGroup (the Tasks 1-2 suites, the four fixture/edge/abort suites, and the four campaign PRGs), each in the established format:

```xml
    <Compile Include="TcUnitTests\FB_TimedSuiteGreenPathTests.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\FB_TimedOrderedGreenPathTests.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\FB_StepZeroSimplePass.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\FB_StepZeroEmptySuite.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\FB_StepZeroCounts_ShouldFail.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\FB_StepZeroAbortSuite.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\PRG_TEST_TCUNIT_STEP0.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\PRG_TEST_TCUNIT_STEP0_COUNTS.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\PRG_TEST_TCUNIT_STEP0_EDGE.TcPOU">
      <SubType>Code</SubType>
    </Compile>
    <Compile Include="TcUnitTests\PRG_TEST_TCUNIT_STEP0_ABORT.TcPOU">
      <SubType>Code</SubType>
    </Compile>
```

3. **Merge** three parameters into the EXISTING `<Parameters>` block under `<PlaceholderReference Include="TcUnit">` (it already holds `LOGEXTENDEDRESULTS`; preserve XAE's emitted format exactly, including the `xmlns=""` attribute on `<Parameter>` — do NOT add a second `<Parameters>` block):

```xml
      <Parameters>
        <Parameter ListName="GVL_PARAM_TCUNIT" xmlns="">
          <Key>LOGEXTENDEDRESULTS</Key>
          <Value>FALSE</Value>
        </Parameter>
        <Parameter ListName="GVL_PARAM_TCUNIT" xmlns="">
          <Key>XUNITENABLEPUBLISH</Key>
          <Value>TRUE</Value>
        </Parameter>
        <Parameter ListName="GVL_PARAM_TCUNIT" xmlns="">
          <Key>XUNITFILEPATH</Key>
          <Value>%TC_BOOTPRJPATH%tcunit_step0_xunit.xml</Value>
        </Parameter>
        <Parameter ListName="GVL_PARAM_TCUNIT" xmlns="">
          <Key>TIMEBETWEENTESTSUITESEXECUTION</Key>
          <Value>T#100MS</Value>
        </Parameter>
      </Parameters>
```

Notes: `TIMEBETWEENTESTSUITESEXECUTION = T#100MS` provides the nonzero-delay coverage and applies to all TwinCAT_Tests sequential campaigns (~100 ms per registered suite — negligible, documented). After the first XAE build, diff the plcproj: if XAE rewrote the block, keep XAE's format.

- [ ] **Step 5: Commit**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TcUnitTests TwinCAT_Tests/TwinCAT_Tests/TwinCAT_Tests.plcproj
git commit -m "test(tcunit-step0): count fixture, edge/abort suites, four campaign PRGs, plcproj wiring

- FB_StepZeroSimplePass.TcPOU / FB_StepZeroEmptySuite.TcPOU / FB_StepZeroCounts_ShouldFail.TcPOU / FB_StepZeroAbortSuite.TcPOU: campaign suites
- PRG_TEST_TCUNIT_STEP0.TcPOU: all-passing REGRESSION campaign (sequential latch)
- PRG_TEST_TCUNIT_STEP0_COUNTS.TcPOU: intentional-failure counts campaign
- PRG_TEST_TCUNIT_STEP0_EDGE.TcPOU: empty-first/final sequential edge campaign
- PRG_TEST_TCUNIT_STEP0_ABORT.TcPOU: deterministic 5-minute abort-window campaign
- TwinCAT_Tests.plcproj: TcUnitTests folder, 10 compile entries, merged xUnit path/publish/delay params"
```

---

### Task 4: Sequential single-suite check in TcUnit-Verifier (TcUnitFork)

**Files:**
- Create: `C:\Users\scott\Documents\TcUnitFork\TcUnit-Verifier\TcUnit-Verifier_TwinCAT\TcUnit-Verifier_TwinCAT\TcUnitVerifier\POUs\FB_SequentialSingleSuite.TcPOU`
- Create: `C:\Users\scott\Documents\TcUnitFork\TcUnit-Verifier\TcUnit-Verifier_TwinCAT\TcUnit-Verifier_TwinCAT\TcUnitVerifier\POUs\PRG_TEST_SEQUENCE.TcPOU`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit-Verifier\TcUnit-Verifier_TwinCAT\TcUnit-Verifier_TwinCAT\TcUnitVerifier\TcUnitVerifier.plcproj`

**Interfaces:**
- Consumes: installed TcUnit (verifier resolves `TcUnit, *` — picks up whatever is installed).
- Produces: the committed single-suite sequential check. Per the campaign-isolation constraint, registration behavior of unassigned PRGs is never assumed — and TwinCAT_Tests cannot GUARANTEE `NumberOfInitializedTestSuites = 1` without excluding every other test PRG from its build, so the verifier project is the minimal N=1 vehicle: with `PRG_TEST` excluded from build, only this PRG's suite can register, and the same suite-count preflight (`NumberOfInitializedTestSuites` = 1) verifies it empirically before the result is trusted. This PRG is NOT assigned to any task by default — the existing verifier configuration is untouched.

- [ ] **Step 1: Generate two fresh GUIDs** (`<GUID-11>`, `<GUID-12>`), uniqueness-checked. Then confirm the verifier POU folder layout with Glob (`TcUnit-Verifier/**/POUs/*.TcPOU`) and mirror the existing `<Compile Include>` path style found in `TcUnitVerifier.plcproj`; if POUs live at a different relative path, place the new files beside the existing PRG_TEST.

- [ ] **Step 2: Write the suite and PRG**

`FB_SequentialSingleSuite.TcPOU` (`<GUID-11>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="FB_SequentialSingleSuite" Id="<GUID-11>" SpecialFunc="None">
    <Declaration><![CDATA[// One passing test; used by PRG_TEST_SEQUENCE for the N=1 sequential check.
FUNCTION_BLOCK FB_SequentialSingleSuite EXTENDS TcUnit.FB_TestSuite]]></Declaration>
    <Implementation>
      <ST><![CDATA[TEST('Test_SingleSequentialPass');
AssertTrue(Condition := TRUE, Message := 'Single-suite sequential run');
TEST_FINISHED();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

`PRG_TEST_SEQUENCE.TcPOU` (`<GUID-12>`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1">
  <POU Name="PRG_TEST_SEQUENCE" Id="<GUID-12>" SpecialFunc="None">
    <Declaration><![CDATA[(* Committed single-suite RUN_IN_SEQUENCE check (precursor of the fully
   automated sequential verifier configuration; see the Phase 5 verifier plan).
   Usage: exclude PRG_TEST from build, assign PlcTask to this PRG, run, and
   verify TcUnit.GVL_TcUnit.TcUnitRunner.AllTestSuitesFinished latches TRUE.
   With exactly one registered suite, 2026.7.17.1 never latches (the final-suite
   branch never published the finished count); the Step-0 candidate latches. *)
PROGRAM PRG_TEST_SEQUENCE
VAR
    SingleSuite : FB_SequentialSingleSuite;
END_VAR]]></Declaration>
    <Implementation>
      <ST><![CDATA[TcUnit.RUN_IN_SEQUENCE();]]></ST>
    </Implementation>
  </POU>
</TcPlcObject>
```

- [ ] **Step 3: Add both files to `TcUnitVerifier.plcproj`** as `<Compile Include>` entries matching the existing entries' path style.

- [ ] **Step 4: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit-Verifier
git commit -m "test(verifier): committed single-suite RUN_IN_SEQUENCE check

- FB_SequentialSingleSuite.TcPOU: one-test suite for the N=1 sequential case
- PRG_TEST_SEQUENCE.TcPOU: unassigned-by-default sequential check PRG with usage procedure
- TcUnitVerifier.plcproj: compile entries for both"
```

---

### Task 5: XML semantic verifier script and verification procedure (TcUnitFork)

**Files:**
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\Verify-StepZeroXUnit.ps1`
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (prepend procedure body above the Task 0 appendix)

**Interfaces:**
- Consumes: campaign xUnit file `C:\TwinCAT\3.1\Boot\tcunit_step0_xunit.xml`; suite naming `PRG_<name>.<instance>` (TcUnit strips the project prefix).
- Produces: `Verify-StepZeroXUnit.ps1 -Path <xml> -Campaign REGRESSION|COUNTS|EDGE -Phase RED|GREEN [-OutCanonical <path>]` — parses the XML, asserts exact suite/test names, counts, statuses, and failure identity; enforces exact-suite isolation (asserts the suite count equals the campaign model and hard-fails on any suite not in it); normalizes only `time` attributes when emitting the canonical golden. Exit code 0 = all assertions pass.

- [ ] **Step 1: Write the verifier script**

```powershell
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][ValidateSet('REGRESSION', 'COUNTS', 'EDGE')][string]$Campaign,
    [Parameter(Mandatory = $true)][ValidateSet('RED', 'GREEN')][string]$Phase,
    [string]$OutCanonical
)

$script:failCount = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "PASS  $Message" }
    else { Write-Host "FAIL  $Message" -ForegroundColor Red; $script:failCount++ }
}

if (-not (Test-Path $Path)) { Write-Host "FAIL  xUnit file not found: $Path" -ForegroundColor Red; exit 1 }
[xml]$doc = Get-Content -Path $Path -Raw
$root = $doc.testsuites

# Expected model per campaign/phase. failing/skippedNames are exact test-name sets.
# RED root semantics (2026.7.17.1 bugs): tests attr = successful count; no skipped attr.
$model = @{}
switch ("$Campaign/$Phase") {
    'REGRESSION/RED' {
        $model['PRG_TEST_TCUNIT_STEP0.TimedSuiteTests']   = @{ tests = 5; failing = @('Test_PaddedNameLookup', 'Test_StaleContextGuard'); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0.TimedOrderedTests'] = @{ tests = 3; failing = @('Test_Ordered3_Guard'); skippedNames = @() }
        $rootTests = '5'; $rootFailures = '3'; $rootSkipped = $null
    }
    'REGRESSION/GREEN' {
        $model['PRG_TEST_TCUNIT_STEP0.TimedSuiteTests']   = @{ tests = 5; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0.TimedOrderedTests'] = @{ tests = 3; failing = @(); skippedNames = @() }
        $rootTests = '8'; $rootFailures = '0'; $rootSkipped = '0'
    }
    'COUNTS/RED' {
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.PassSuite']              = @{ tests = 1; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.CountsSuite_ShouldFail'] = @{ tests = 3; failing = @('Test_IntentionalFail'); skippedNames = @('Test_Skipped') }
        $rootTests = '3'; $rootFailures = '1'; $rootSkipped = $null
    }
    'COUNTS/GREEN' {
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.PassSuite']              = @{ tests = 1; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_COUNTS.CountsSuite_ShouldFail'] = @{ tests = 3; failing = @('Test_IntentionalFail'); skippedNames = @('Test_Skipped') }
        $rootTests = '4'; $rootFailures = '1'; $rootSkipped = '1'
    }
    'EDGE/GREEN' {
        $model['PRG_TEST_TCUNIT_STEP0_EDGE.EmptyFirstSuite'] = @{ tests = 0; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_EDGE.MidPassSuite']    = @{ tests = 1; failing = @(); skippedNames = @() }
        $model['PRG_TEST_TCUNIT_STEP0_EDGE.EmptyFinalSuite'] = @{ tests = 0; failing = @(); skippedNames = @() }
        $rootTests = '1'; $rootFailures = '0'; $rootSkipped = '0'
    }
    'EDGE/RED' { Write-Host 'FAIL  EDGE campaign is GREEN-only by design' -ForegroundColor Red; exit 1 }
}

# Root attribute assertions
Assert-True ($root.tests -eq $rootTests)       "root tests='$($root.tests)' expected '$rootTests'"
Assert-True ($root.failures -eq $rootFailures) "root failures='$($root.failures)' expected '$rootFailures'"
if ($null -eq $rootSkipped) {
    Assert-True ($null -eq $root.GetAttribute('skipped') -or $root.GetAttribute('skipped') -eq '') "root skipped attribute absent (RED semantics)"
} else {
    Assert-True ($root.skipped -eq $rootSkipped) "root skipped='$($root.skipped)' expected '$rootSkipped'"
}

$suites = @($root.testsuite)
foreach ($name in $model.Keys) {
    $suite = $suites | Where-Object { $_.name -eq $name }
    Assert-True ($null -ne $suite) "suite present: $name"
    if ($null -eq $suite) { continue }
    $m = $model[$name]
    Assert-True ([int]$suite.tests -eq $m.tests)              "$name tests=$($suite.tests) expected $($m.tests)"
    Assert-True ([int]$suite.failures -eq $m.failing.Count)   "$name failures=$($suite.failures) expected $($m.failing.Count)"
    if ($Phase -eq 'GREEN') {
        Assert-True ($suite.skipped -eq [string]$m.skippedNames.Count) "$name skipped=$($suite.skipped) expected $($m.skippedNames.Count)"
    }
    $cases = @($suite.testcase)
    Assert-True ($cases.Count -eq $m.tests) "$name testcase count=$($cases.Count) expected $($m.tests)"
    $actualFailing = @($cases | Where-Object { $_.status -eq 'FAIL' } | ForEach-Object { $_.name })
    $actualSkipped = @($cases | Where-Object { $_.status -eq 'SKIP' } | ForEach-Object { $_.name })
    Assert-True (-not (Compare-Object $actualFailing $m.failing))      "$name failing set = [$($actualFailing -join ',')] expected [$($m.failing -join ',')]"
    Assert-True (-not (Compare-Object $actualSkipped $m.skippedNames)) "$name skipped set = [$($actualSkipped -join ',')] expected [$($m.skippedNames -join ',')]"
    foreach ($case in $cases) {
        if ($case.name -in $m.failing) {
            Assert-True ($null -ne $case.failure) "$name/$($case.name) carries a <failure> element"
        } else {
            Assert-True ($null -eq $case.failure) "$name/$($case.name) carries no <failure> element"
        }
    }
}

# Campaign isolation: the xUnit file must contain EXACTLY the campaign suites.
# Any other suite means a non-campaign PRG was compiled into the run - hard failure,
# because hidden registered suites make counts and sequence traversal ambiguous.
Assert-True ($suites.Count -eq $model.Count) "suite count=$($suites.Count) expected exactly $($model.Count)"
foreach ($suite in $suites) {
    Assert-True ($model.ContainsKey($suite.name)) "unexpected non-campaign suite present: $($suite.name)"
}

if ($OutCanonical) {
    $content = Get-Content -Path $Path -Raw
    $canonical = $content -replace 'time="[^"]*"', 'time=""'
    Set-Content -Path $OutCanonical -Value $canonical -NoNewline -Encoding UTF8
    Write-Host "Canonical golden written to $OutCanonical"
}

Write-Host ""
if ($script:failCount -eq 0) { Write-Host "ALL ASSERTIONS PASSED ($Campaign/$Phase)"; exit 0 }
else { Write-Host "$script:failCount ASSERTION(S) FAILED ($Campaign/$Phase)" -ForegroundColor Red; exit 1 }
```

- [ ] **Step 2: Prepend the procedure body to the verification doc**

Above the Task 0 appendix, add:

```markdown
# Step-0 Verification Procedure (Phase 4a/4b + sequential runner + xUnit counts)

Campaigns live in TwinCAT_Tests (branch `feat/tcunit-step0`). xUnit output:
`C:\TwinCAT\3.1\Boot\tcunit_step0_xunit.xml` (campaign-specific override).
Run RED against the TcUnit **2026.7.17.1** baseline, GREEN against the Step-0 candidate.
Every xUnit claim is asserted by `Verify-StepZeroXUnit.ps1`, never by eyeball.

## Per-campaign run recipe

1. Open `TwinCAT_Tests.sln` in XAE. **Isolate the campaign**: exclude from build
   every `PRG_TEST_*` program AND every other step-0 campaign PRG except this
   campaign's PRG (multi-select in Solution Explorer -> Properties -> Exclude
   from build). Assign the campaign PRG to TestTask.
2. Build (Ctrl+Shift+B) - must compile clean.
3. Delete `C:\TwinCAT\3.1\Boot\tcunit_step0_xunit.xml` if present. Record that
   it is absent.
4. Activate configuration, restart in Run mode, log in.
5. **Isolation preflight**: online-read `TcUnit.GVL_TcUnit.NumberOfInitializedTestSuites`.
   It must equal this campaign's suite count exactly (REGRESSION 2, COUNTS 2,
   EDGE 3, ABORT 1). Mismatch = STOP: record the observed value (on the first
   run this also settles empirically whether unassigned-PRG suites register),
   fix the exclusions, and rerun. Do not trust any result from a run whose
   preflight mismatched.
6. Wait for the ADS summary block (`| ==========TESTS FINISHED RUNNING==========`).
7. Watch `TcUnit.GVL_TcUnit.TcUnitRunner.AllTestSuitesFinished` online for 60 s
   after the summary appears; record its value.
8. Verify the xUnit file was freshly created (creation time after step 4;
   record `Get-FileHash`), then run:
   `pwsh -File C:\Users\scott\Documents\TcUnitFork\docs\verification\Verify-StepZeroXUnit.ps1 -Path C:\TwinCAT\3.1\Boot\tcunit_step0_xunit.xml -Campaign <X> -Phase <RED|GREEN> [-OutCanonical <path>]`
9. Record script output (PASS/FAIL lines) and the observations table. After the
   last run of a phase, restore all build exclusions and the original TestTask
   assignment, and confirm with `git status` that only intended changes remain.

## Phase matrix

| Phase | Campaigns | Extra checks |
|---|---|---|
| RED (baseline 2026.7.17.1) | REGRESSION, COUNTS | rows R1-R6 below |
| GREEN (Step-0 candidate) | REGRESSION, COUNTS, EDGE, ABORT | rows G1-G8, abort A1, single-suite S1 |

## Non-XML observations

| # | Observation | Expected | Actual |
|---|---|---|---|
| P1 | Isolation preflight, EVERY run: NumberOfInitializedTestSuites | exactly 2/2/3/1 per campaign; first run records what unassigned-PRG registration empirically does | _pending_ |
| R1 | REGRESSION RED: script exit code | 0 (all RED-model assertions hold) | _pending_ |
| R2 | REGRESSION RED: AllTestSuitesFinished after summary | stays FALSE for 60 s (breadcrumb #19) | _pending_ |
| R3 | REGRESSION RED: 'TEST RUN COMPLETED' trace | absent | _pending_ |
| R4 | REGRESSION RED: out-of-context Error traces | repeated burst from ordered probe (unguarded in 2026.7.17.1) | _pending_ |
| R5 | COUNTS RED: script exit code | 0 | _pending_ |
| R6 | COUNTS RED: ADS 'Successful tests:' line | 3 (skipped counted as successful: 4 total - 1 fail) | _pending_ |
| G1 | REGRESSION GREEN: script exit code | 0 (zero failures anywhere) | _pending_ |
| G2 | REGRESSION GREEN: AllTestSuitesFinished | TRUE within 60 s | _pending_ |
| G3 | REGRESSION GREEN: 'TEST RUN COMPLETED' trace | present exactly once | _pending_ |
| G4 | REGRESSION GREEN: out-of-context Error trace | exactly once per suite instance (one-shot) | _pending_ |
| G5 | COUNTS GREEN: script exit code | 0 (sole failure identity = Test_IntentionalFail) | _pending_ |
| G6 | COUNTS GREEN: ADS 'Successful tests:' line | 2 (4 total - 1 fail - 1 skip) | _pending_ |
| G7 | EDGE GREEN: script exit code | 0; AllTestSuitesFinished TRUE | _pending_ |
| G8 | xUnit file freshness | absent before each run; fresh creation time + new hash after | _pending_ |
| A1 | ABORT campaign: run PRG_TEST_TCUNIT_STEP0_ABORT; first OBSERVE AllTestSuitesFinished = FALSE and the run in progress (Test_AbortWindow registered, 'TEST RUN STARTED' trace), then online-write TcUnit.GVL_TcUnit.TcUnitRunner.AbortRunningTestSuites := TRUE | precondition observations recorded; after the write, AllTestSuitesFinished latches TRUE promptly and 'TEST RUN ABORTED' trace appears; no ADS summary/xUnit export expected (results never complete); delete any xUnit file afterward | _pending_ |
| S1 | Single-suite (TcUnit-Verifier): exclude PRG_TEST from build, assign PlcTask to PRG_TEST_SEQUENCE, run | AllTestSuitesFinished TRUE with exactly 1 registered suite; restore PRG_TEST afterward | _pending_ |

## Memory evidence (Task 10)

| Measurement | Before (baseline 2026.7.17.1) | After (candidate) | Delta |
|---|---|---|---|
| SIZEOF(ST_TestSuiteResult) | _pending_ | _pending_ | expected +2 bytes (+padding) |
| SIZEOF(ST_TestSuiteResults) | _pending_ | _pending_ | expected ~ +2 KB (1000 x 2 bytes + aggregate UDINT widening + padding) |
| TwinCAT_Tests build: allocated data size | _pending_ | _pending_ | record from build output |

## Golden

After GREEN REGRESSION and COUNTS runs pass, re-run the script with
`-OutCanonical` and commit the outputs as
`docs/verification/goldens/2026-07-17-step0-<campaign>-canonical.xml`.
These are the Level 2 baselines for the Phase 5 refactor: future campaign runs
must reproduce them byte-identically after canonicalization, with intentional
differences explicitly approved and the goldens re-committed.

## Results log

| Date | Library | Campaign/Phase | Script exit | Notes |
|---|---|---|---|---|
```

- [ ] **Step 3: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/Verify-StepZeroXUnit.ps1 docs/verification/2026-07-17-step0-verification.md
git commit -m "docs(step0): XML semantic verifier script and full verification procedure

- Verify-StepZeroXUnit.ps1: parses campaign xUnit, asserts exact suite/test names, counts, statuses, failure identity, exact-suite isolation (hard failure on any non-campaign suite); canonical golden emitter
- 2026-07-17-step0-verification.md: per-campaign recipes, RED/GREEN phase matrix, abort and single-suite checks, memory-evidence table"
```

---

### Task 6: USER ACTION — RED runs against 2026.7.17.1

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (rows R1-R6 + results log)

**Interfaces:**
- Consumes: Task 5 recipes; campaigns from Tasks 1-3 (TwinCAT_Tests still resolves `TcUnit, 2026.7.17.1` — no reference change for RED).
- Produces: recorded proof all three defects reproduce and the regression tests are load-bearing. Tasks 7-9 must not start until R1-R6 match.

- [ ] **Step 1: Ask Scott to run REGRESSION then COUNTS per the recipe**, running the script with `-Phase RED` after each. EDGE is not run RED (green-only by design; its null-pointer hazard is code-inspection-based and the plan does not deliberately crash the runtime).

- [ ] **Step 2: Record R1-R6 and results-log rows.** If any RED assertion unexpectedly passes (script exit 0 not achieved the way the model predicts, or a regression test green), STOP — the test is not exercising the defect; rework Tasks 1-3 before touching implementation.

- [ ] **Step 3: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md
git commit -m "docs(step0): RED runs recorded against TcUnit 2026.7.17.1

- 2026-07-17-step0-verification.md: R1-R6 filled; all three defects reproduced; regressions proven load-bearing"
```

---

### Task 7: FB_TimedTestSuite hardening (Phase 4a fixes)

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_TimedTestSuite.TcPOU`

**Interfaces:**
- Consumes: inherited `FB_TestSuite` members `Tests[]`, `GetCurrentTaskIndex` (FB instance), `TraceWithSeverity`; `GVL_TcUnit.CurrentTestNameBeingCalled`; `TwinCAT_SystemInfoVarList._TaskInfo[].CycleCount`.
- Produces: hardened invariant — `_nActiveTimedTestIdx` is valid only when set in the CURRENT task cycle by a `TEST_TIMED*` call whose test name is still the framework's current test. New PRIVATE method `_GetActiveWaitContext : UINT` (0 = no valid context). Public API unchanged.

- [ ] **Step 1: Generate one fresh GUID** for the new method (`<GUID-13>`), uniqueness-checked.

- [ ] **Step 2: Add the two new VARs**

Change the declaration block to:

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

New `<Method>` element before `</POU>`, with `<GUID-13>`:

```xml
    <Method Name="_GetActiveWaitContext" Id="<GUID-13>">
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

Remove the early `_nActiveTimedTestIdx := idx;` (currently after the `_FindTestIndex` null check). Replace the method's final lines:

```iecst
// Step 9: Test body should execute
TEST_TIMED := TRUE;
```

with:

```iecst
// Step 9: Test body should execute - arm the wait context for this cycle only
_nActiveTimedTestIdx := idx;
GetCurrentTaskIndex();
_nActiveTimedTestCycle := TwinCAT_SystemInfoVarList._TaskInfo[GetCurrentTaskIndex.index].CycleCount;
TEST_TIMED := TRUE;
```

- [ ] **Step 5: Same lifecycle fix in TEST_TIMED_ORDERED**

Remove its `_nActiveTimedTestIdx := idx;` (Step 9 of that method). Replace its final lines:

```iecst
// Step 14: Test body should execute
TEST_TIMED_ORDERED := TRUE;
```

with:

```iecst
// Step 14: Test body should execute - arm the wait context for this cycle only
_nActiveTimedTestIdx := idx;
GetCurrentTaskIndex();
_nActiveTimedTestCycle := TwinCAT_SystemInfoVarList._TaskInfo[GetCurrentTaskIndex.index].CycleCount;
TEST_TIMED_ORDERED := TRUE;
```

- [ ] **Step 6: Route WaitForTime through the guard with a one-shot trace**

Replace:

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

- [ ] **Step 7: Identical change in WaitForCondition** (message text `'WaitForCondition called without active timed test context'`).

- [ ] **Step 8: Route WaitTimedOut through the guard**

Add `idx : UINT;` to the Get accessor's `VAR ... END_VAR` block, then replace the implementation with:

```iecst
idx := _GetActiveWaitContext();
IF idx > 0 THEN
    WaitTimedOut := TimedTestStates[idx].bConditionTimedOut;
ELSE
    WaitTimedOut := FALSE;
END_IF
```

- [ ] **Step 9: Trim the lookup name in GetTimedTestResult**

Before `idx := _FindTestIndex(TestName := TestName);` add:

```iecst
// Normalize the same way TEST(), TEST_ORDERED(), and TEST_TIMED() do
TestName := F_LTrim(in := F_RTrim(in := TestName));
```

- [ ] **Step 10: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/POUs/FB_TimedTestSuite.TcPOU
git commit -m "fix(timed-suite): cycle-guarded wait context, one-shot misuse traces, trimmed result lookup

- FB_TimedTestSuite.TcPOU: context armed only when a body executes and validated per task cycle + test name (_GetActiveWaitContext); WaitForTime/WaitForCondition/WaitTimedOut all route through the guard; out-of-context traces one-shot; GetTimedTestResult trims TestName"
```

Known residual (Task 13 documents it): a bare wait placed in the same scan immediately after an executing block, while that block's test is still the current test, is textually indistinguishable from a legitimate in-body call and remains accepted.

---

### Task 8: RUN_IN_SEQUENCE completion fix

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_TcUnitRunner.TcPOU` (method `RunTestSuiteTestsInSequence` only)

**Interfaces:**
- Consumes: existing `AllTestSuitesFinished` latch and scan-local `NumberOfTestSuitesFinished` completion check.
- Produces: `AllTestSuitesFinished` latches when the final suite reports finished, for any suite count including 1 (proven by S1). Parallel runner untouched.

- [ ] **Step 1: Replace the advance/finish block**

Replace:

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

(The `ELSIF NOT TimerBetweenExecutionOfTestSuites.Q THEN ... END_IF` execution branch, the abort block, and the `IF NumberOfTestSuitesFinished = ... THEN AllTestSuitesFinished := TRUE` latch stay exactly as they are.)

- [ ] **Step 2: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/POUs/FB_TcUnitRunner.TcPOU
git commit -m "fix(runner): RUN_IN_SEQUENCE completion latches when the final suite finishes

- FB_TcUnitRunner.TcPOU: final-suite branch publishes the full finished count (method VAR resets each scan, so incremental counting never completed - breadcrumb #19); duration call addresses the finished suite directly instead of the possibly-null CurrentTestSuiteBeingCalled"
```

---

### Task 9: xUnit count semantics with UDINT aggregates

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\DUTs\ST_TestSuiteResult.TcDUT`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\DUTs\ST_TestSuiteResults.TcDUT`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_TestResults.TcPOU`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_xUnitXmlPublisher.TcPOU`
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\POUs\FB_AdsTestResultLogger.TcPOU`

**Interfaces:**
- Consumes: existing `FB_TestSuite.GetNumberOfSkippedTests()` (INTERNAL, already present).
- Produces: `ST_TestSuiteResult.NumberOfSkippedTests : UINT(...)`; aggregate fields `NumberOfTestCases`/`NumberOfSuccessfulTestCases`/`NumberOfFailedTestCases`/`NumberOfSkippedTestCases` all **UDINT** (spec: count types from capacity products — 1000 suites x 100 tests exceeds UINT); invariant `NumberOfTestCases = Successful + Failed + Skipped`; xUnit root `tests` = total, root+suite `skipped` attributes. ADS text FORMAT unchanged (`UDINT_TO_STRING` prints identical digits; only the successful number's semantics changes — spec-approved, observation R6/G6). The .NET verifier is unaffected: it presence-checks lines and asserts only the failed count, and no verifier suite has skipped tests.

- [ ] **Step 1: Per-suite skipped field** — in `ST_TestSuiteResult.TcDUT` after `NumberOfFailedTests`:

```iecst
    NumberOfSkippedTests : UINT(0..GVL_Param_TcUnit.MaxNumberOfTestsForEachTestSuite);
```

- [ ] **Step 2: UDINT aggregates** — in `ST_TestSuiteResults.TcDUT` replace the three aggregate testcase counters and add the fourth:

```iecst
    NumberOfTestCases : UDINT; // The total number of test cases (for all test suites)
    NumberOfSuccessfulTestCases : UDINT; // The total number of test cases that had all ASSERTS successful
    NumberOfFailedTestCases : UDINT; // The total number of test cases that had at least one ASSERT failed
    NumberOfSkippedTestCases : UDINT; // The total number of test cases that were skipped (disabled)
```

(`NumberOfTestSuites : UINT` stays — bounded by the UINT parameter `MaxNumberOfTestSuites`.)

- [ ] **Step 3: FB_TestResults — store skipped, correct successful**

After the "Store number of failed tests in test suite" block add:

```iecst
        // Store number of skipped tests in test suite
        TestSuiteResults.TestSuiteResults[StoringTestSuiteResultNumber].NumberOfSkippedTests :=
            GVL_TcUnit.TestSuiteAddresses[StoringTestSuiteResultNumber]^.GetNumberOfSkippedTests();
```

In the aggregate FOR loop, replace the successful/failed accumulation with:

```iecst
        (* A skipped test is not a successful test: total = passed + failed + skipped *)
        TestSuiteResults.NumberOfSuccessfulTestCases := TestSuiteResults.NumberOfSuccessfulTestCases +
                                                        (TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfTests -
                                                         TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfFailedTests -
                                                         TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfSkippedTests);
        TestSuiteResults.NumberOfFailedTestCases := TestSuiteResults.NumberOfFailedTestCases + TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfFailedTests;
        TestSuiteResults.NumberOfSkippedTestCases := TestSuiteResults.NumberOfSkippedTestCases + TestSuiteResults.TestSuiteResults[GeneralTestResultsTestSuitesCounter].NumberOfSkippedTests;
```

- [ ] **Step 4: FB_xUnitXmlPublisher — corrected attributes with UDINT conversions**

Root element — replace the `failures`/`tests` parameter lines with:

```iecst
    Xml.NewParameter('failures', UDINT_TO_STRING(UnitTestResults.NumberOfFailedTestCases));
    (* 'tests' is the TOTAL testcase count; the previous successful-only value was a bug *)
    Xml.NewParameter('tests', UDINT_TO_STRING(UnitTestResults.NumberOfTestCases));
    Xml.NewParameter('skipped', UDINT_TO_STRING(UnitTestResults.NumberOfSkippedTestCases));
```

Suite element — after the suite `failures` line add:

```iecst
        Xml.NewParameter('skipped', UINT_TO_STRING(UnitTestResults.TestSuiteResults[CurrentSuiteNumber].NumberOfSkippedTests));
```

- [ ] **Step 5: FB_AdsTestResultLogger — UDINT conversions**

In the final-summary block, change the three aggregate conversions (`| Tests:`, `| Successful tests:`, `| Failed tests:` lines) from `UINT_TO_STRING(...)` to `UDINT_TO_STRING(...)`, and the same two fields inside the `TESTS FINISHED - ` TraceWithSeverity concatenation. Then sweep for stragglers:

Grep `UINT_TO_STRING\(TcUnitTestResults\.NumberOf(TestCases|SuccessfulTestCases|FailedTestCases)` and `UINT_TO_STRING\(UnitTestResults\.NumberOf` across `TcUnit/TcUnit` — expected zero matches after the edits.

- [ ] **Step 6: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/DUTs/ST_TestSuiteResult.TcDUT TcUnit/TcUnit/DUTs/ST_TestSuiteResults.TcDUT TcUnit/TcUnit/POUs/FB_TestResults.TcPOU TcUnit/TcUnit/POUs/FB_xUnitXmlPublisher.TcPOU TcUnit/TcUnit/POUs/FB_AdsTestResultLogger.TcPOU
git commit -m "fix(xunit): total = passed + failed + skipped; UDINT aggregate counters; root tests attribute reports total

- ST_TestSuiteResult.TcDUT: add NumberOfSkippedTests
- ST_TestSuiteResults.TcDUT: aggregate testcase counters widened to UDINT (capacity product 1000x100 exceeds UINT); add NumberOfSkippedTestCases
- FB_TestResults.TcPOU: store per-suite skipped; successful no longer includes skipped
- FB_xUnitXmlPublisher.TcPOU: root tests = total testcases; skipped attribute at root and suite level; UDINT conversions
- FB_AdsTestResultLogger.TcPOU: UDINT conversions for aggregate summary lines (text format unchanged)"
```

---

### Task 10: Version bump, USER ACTION — build/install candidate, memory evidence

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\TcUnit.plcproj` (`<ProjectVersion>`, ~line 35)
- Modify: `C:\Users\scott\Documents\TcUnitFork\TcUnit\TcUnit\Version\Global_Version.TcGVL` (~line 10)
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (memory-evidence table)

**Interfaces:**
- Consumes: Tasks 7-9 source changes.
- Produces: the **Step-0 candidate** library (version `<candidate>` per Global Constraints) installed locally. The `.library` binary and the git tag are deliberately NOT committed here — they land in Task 13 after evidence. This commit contains sources only.

- [ ] **Step 1: Bump both version locations**

`TcUnit.plcproj`: `<ProjectVersion>2026.7.17.1</ProjectVersion>` → `<ProjectVersion><candidate></ProjectVersion>`

`Global_Version.TcGVL`: set `stLibVersion_TcUnit` to the same `<candidate>` value (`iMajor.iMinor.iBuild.iRevision` = the dotted version; `sVersion` = the full string).

- [ ] **Step 2: Build and install the candidate (automated), USER ACTION — measure**

Build + install headless (proven 2026-07-17; no XAE clicks needed):

```powershell
& "C:\Users\scott\Documents\ToolPackageManager\src\ToolPackageManager.Cli\bin\Release\net8.0-windows\ToolPackageManager.Cli.exe" library save C:\Users\scott\Documents\TcUnitFork\TcUnit.sln --project TcUnit --output C:\Users\scott\Documents\TcUnitFork\TcUnit.library
```

Expected: `Build succeeded.` / `Library saved` / `Installed in the local TwinCAT library repository.` Compile failures come back verbatim for fixing before proceeding. Confirm the repository lists the candidate version. Reminder (Gotcha #22): if the save NREs with a green build, bisect for a reserved-word identifier before anything else.

Memory evidence (USER ACTION): in a logged-in TwinCAT_Tests session (or the verifier project), read `SIZEOF(TcUnit.ST_TestSuiteResult)` and `SIZEOF(TcUnit.ST_TestSuiteResults)` (watch window accepts SIZEOF expressions; alternatively a temporary `nSize : UDINT := SIZEOF(...)` watch variable) — once against the 2026.7.17.1 baseline (before updating the resolution, i.e. now) and once against the candidate (during Task 12's first GREEN session). Record the TwinCAT_Tests build's allocated data size from the build output both times.

- [ ] **Step 3: Commit sources only (no tag yet)**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit/TcUnit/TcUnit.plcproj TcUnit/TcUnit/Version/Global_Version.TcGVL docs/verification/2026-07-17-step0-verification.md
git commit -m "chore(release-candidate): TcUnit <candidate> sources; library binary and tag follow GREEN evidence

- TcUnit.plcproj: ProjectVersion <candidate>
- Global_Version.TcGVL: stLibVersion_TcUnit <candidate>
- 2026-07-17-step0-verification.md: baseline SIZEOF measurements recorded"
```

---

### Task 11: USER ACTION — verifier gate against the candidate

**Files:**
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (results log + S1)

**Interfaces:**
- Consumes: the installed Step-0 candidate; `TcUnit-Verifier_DotNet` (resolves `TcUnit, *` — picks up the candidate automatically); Task 4's `PRG_TEST_SEQUENCE`.
- Produces: spec Level-2 gate evidence — "existing verifier runs unchanged" — plus the single-suite sequential check (S1). Task 12 must not start until both pass.

- [ ] **Step 1: USER ACTION — run the existing verifier unchanged**

Ask Scott to run TcUnit-Verifier_DotNet exactly as documented in `TcUnit-Verifier/` (builds TcUnit-Verifier_TwinCAT via the automation API, runs it, asserts the expected failed-test count and assertion texts). Expected: same result as its last known-good run — the count-semantics change does not alter it (no verifier suite has skipped tests; ADS line format unchanged). Any deviation is a STOP: diagnose before proceeding. If the verifier harness itself fails on infrastructure (its known reliability issues, see VERIFIER_IMPROVEMENT_PLAN.md), record the failure mode and fall back to building + activating TcUnit-Verifier_TwinCAT manually in XAE and comparing the ADS failed-count summary against the expectation constant in `TcUnit-Verifier_DotNet\TcUnit-Verifier\Program.cs` — record which path was used.

- [ ] **Step 2: USER ACTION — single-suite sequential check (S1)**

Per the PRG_TEST_SEQUENCE header: exclude `PRG_TEST` from build, assign PlcTask to `PRG_TEST_SEQUENCE`, run, verify `AllTestSuitesFinished` = TRUE with `NumberOfInitializedTestSuites` = 1 (online preflight, same rule as the campaigns), then restore `PRG_TEST` and the original task assignment. Record S1.

**Cleanup gate** — the manual switch must not silently alter the verifier configuration that Step 1's "existing verifier unchanged" claim rests on. After restoring, run:

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git status --porcelain TcUnit-Verifier
```

Expected: empty (Task 4's new files are already committed). Any modification to existing verifier files is a STOP: review the diff, revert with `git checkout -- <file>` if it is leftover switch state, and re-run Step 1 if the verifier configuration was touched before its run.

- [ ] **Step 3: Commit**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md
git commit -m "docs(step0): verifier gate passed against the Step-0 candidate <candidate>

- 2026-07-17-step0-verification.md: existing verifier green unchanged; single-suite sequential check S1 recorded"
```

---

### Task 12: USER ACTION — GREEN runs, script verification, golden capture

**Files:**
- Modify: `C:\Users\scott\Documents\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests\TwinCAT_Tests.plcproj` (`<Resolution>TcUnit, 2026.7.17.1 ...`, ~line 592)
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\verification\2026-07-17-step0-verification.md` (G1-G8, A1, memory table, results log)
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\goldens\2026-07-17-step0-regression-canonical.xml`
- Create: `C:\Users\scott\Documents\TcUnitFork\docs\verification\goldens\2026-07-17-step0-counts-canonical.xml`

**Interfaces:**
- Consumes: candidate library; Task 5 recipes and script; Task 6 RED baseline.
- Produces: GREEN evidence for all campaigns (script exit 0), abort behavior (A1), memory after-measurements, committed canonical goldens. Task 13 must not start until everything is green.

- [ ] **Step 1: Point TwinCAT_Tests at the candidate**

`<Resolution>TcUnit, 2026.7.17.1 (www.tcunit.org)</Resolution>` → `<Resolution>TcUnit, <candidate> (www.tcunit.org)</Resolution>`

- [ ] **Step 2: USER ACTION — GREEN campaign runs**

Per the recipe (isolation exclusions + preflight for every run), in order: REGRESSION (`-Phase GREEN -OutCanonical ...step0-regression-canonical.xml`), COUNTS (`-OutCanonical ...step0-counts-canonical.xml`), EDGE (no golden — its value is the traversal checks), then ABORT per observation A1 (verify run-in-progress preconditions, write the abort flag, verify latch + ABORTED trace, delete any xUnit file). Record P1 for every run, G1-G8, A1, and the after-column of the memory table (SIZEOF + build allocated size). After the last run: restore all exclusions and the original TestTask assignment, then run `git status --porcelain` in TwinCAT_Tests — the only expected change is the TcUnit `<Resolution>` bump from Step 1; anything else is leftover switch state to review and revert.

- [ ] **Step 3: Verify and record**

All script runs exit 0; Read both canonical goldens and sanity-check them against the model (root `tests="8"`/`failures="0"`/`skipped="0"` for REGRESSION; `tests="4"`/`failures="1"`/`skipped="1"` for COUNTS). Fill every remaining `_pending_` cell.

- [ ] **Step 4: Commit (TcUnitFork docs only — the TwinCAT_Tests resolution commit lands in Task 13 with the release)**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add docs/verification/2026-07-17-step0-verification.md docs/verification/goldens
git commit -m "docs(step0): GREEN evidence recorded; canonical goldens committed

- 2026-07-17-step0-verification.md: G1-G8, A1, S1, memory table complete; all script runs exit 0
- goldens/: REGRESSION and COUNTS canonical baselines for the Phase 5 refactor"
```

---

### Task 13: Release — library binary, tag, doc reconciliation

**Files:**
- Commit (already regenerated in Task 10): `C:\Users\scott\Documents\TcUnitFork\TcUnit.library`
- Modify: `C:\Users\scott\Documents\TcUnitFork\docs\PROJECT_STATE.md`, `docs\EXECUTION_PLAN.md`, `docs\BREADCRUMBS.md`
- Commit (edited in Task 12): TwinCAT_Tests plcproj resolution

**Interfaces:**
- Consumes: full evidence chain (RED → fixes → candidate → verifier gate → GREEN + goldens).
- Produces: released `TcUnit-<candidate>`; both repos reconciled; the next plan (compile/ABI spike) unblocked.

- [ ] **Step 1: Reconcile the tracking docs**

- `PROJECT_STATE.md`: Phase 4 row → Done (hardened + verified at execution date); strike resolved tech-debt items (`_nActiveTimedTestIdx` guard, `GetTimedTestResult` trim, missing Phase 4 validation, `RUN_IN_SEQUENCE` verifier path); update "What is Active"; current version = `<candidate>`.
- `EXECUTION_PLAN.md`: Phase 4a/4b → Completed Work; Phase 5 step 1 (compile/ABI spike) becomes "What to Build Next"; sequence item 1 marked done.
- `BREADCRUMBS.md`: gotcha #19 solution updated (fixed 2026-07-17; regression = step-0 campaigns + goldens + verifier S1). New gotchas: (a) timed wait context is cycle-guarded — a bare wait in the same scan directly after an executing block remains undetectable by design; (b) registration of suites in PRGs not assigned to any task must never be assumed — step-0 campaigns isolate via exclude-from-build plus an empirical `NumberOfInitializedTestSuites` preflight, and the verifier script hard-fails on unexpected suites; record what P1 empirically showed, since Phase 5's topology validation needs that answer; (c) root xUnit `tests` now reports the total (intentional divergence from the upstream successful-only value) and `disabled_` tests surface in the `skipped` counts.
- Project `CLAUDE.md` version reference: update to `<candidate>`.

- [ ] **Step 2: Release commit and tag (TcUnitFork)**

```powershell
cd C:\Users\scott\Documents\TcUnitFork
git add TcUnit.library docs/PROJECT_STATE.md docs/EXECUTION_PLAN.md docs/BREADCRUMBS.md CLAUDE.md
git commit -m "chore(release): TcUnit <candidate> - step-0 fixes released after GREEN + verifier evidence

- TcUnit.library: rebuilt binary (also restores the previously deleted file)
- PROJECT_STATE.md / EXECUTION_PLAN.md / BREADCRUMBS.md: Phase 4a/4b closed; gotcha #19 resolved; new gotchas recorded; next: compile/ABI spike
- CLAUDE.md: current version reference updated"
git tag TcUnit-<candidate>
```

- [ ] **Step 3: Consumer commit (TwinCAT_Tests)**

```powershell
cd C:\Users\scott\Documents\TwinCAT_Tests
git add TwinCAT_Tests/TwinCAT_Tests/TwinCAT_Tests.plcproj
git commit -m "chore(tcunit-step0): consume TcUnit <candidate>

- TwinCAT_Tests.plcproj: TcUnit resolution 2026.7.17.1 -> <candidate>"
```

---

## Out of scope (deferred to later plans in the series)

- `<skipped/>` child elements, UTF-8/control-char/decimal formatting contract → reporting-pipeline plan (spec step 6).
- Fully .NET-automated `RUN_IN_SEQUENCE` verifier configuration → verifier plan (Task 4's committed check is its precursor).
- TwinCATBase ring-buffer multi-writer audit → TwinCATBase repo (external production gate).
- All coordinator/tagging/multi-task work → spec steps 1-8 plans.
