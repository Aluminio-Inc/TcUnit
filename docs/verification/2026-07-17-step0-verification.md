# Step-0 Verification Procedure (Phase 4a/4b + sequential runner + xUnit counts)

Campaigns live in TwinCAT_Tests (branch `feat/tcunit-step0`). xUnit output:
`%TC_BOOTPRJPATH%tcunit_step0_xunit.xml` — this resolves ON THE PLC
(`C:\TwinCAT\3.1\Boot\tcunit_step0_xunit.xml` at 192.168.225.2); retrieve it over
the share (e.g. `\\192.168.225.2\Logs` sibling admin path or copy via RDP) before
running the script.
Run RED against the TcUnit **2026.7.17.1** baseline, GREEN against the Step-0 candidate.
Every xUnit claim is asserted by `Verify-StepZeroXUnit.ps1`, never by eyeball.

## Scripted execution (preferred)

`Run-StepZeroCampaign.ps1 -Campaign <REGRESSION|COUNTS|EDGE|ABORT> -Phase <RED|GREEN>`
automates the recipe below: campaign selection (TestTask1 PouCall swap + ExcludeFromBuild
on all other test PRGs), stale-xUnit deletion on the PLC, `tpm test`
(build/deploy/run/collect), xUnit fetch + freshness/hash, the Verify script, and an
EventLog marker check. Equivalences: the online isolation preflight (step 5) is enforced
post-hoc by the Verify script's exact-suite assertion (record P1 from the asserted suite
count); the latch observation (R2/G2/R3/G3) is evidenced by the presence/absence of the
'TEST RUN COMPLETED' trace, which only the completion latch emits. `-Restore` reverts the
selection edits; `-SelectOnly` / `-ResultsOnly` split the phases. ABORT deploys then
prints the manual abort steps (A1 stays hands-on by design). The ExcludeFromBuild
mechanism is fail-safe: if it did not isolate, the exact-suite assertion fails the run.

## Per-campaign run recipe

1. Open `TwinCAT_Tests.sln` in XAE. **Isolate the campaign**: exclude from build
   every `PRG_TEST_*` program AND every other step-0 campaign PRG except this
   campaign's PRG (multi-select in Solution Explorer -> Properties -> Exclude
   from build). Assign the campaign PRG to TestTask1 (TestTask2/3 stay empty).
2. Build (Ctrl+Shift+B) - must compile clean.
3. Delete the previous xUnit file on the PLC if present. Record that it is absent.
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
8. Retrieve the xUnit file from the PLC; verify it was freshly created (creation
   time after step 4; record `Get-FileHash`), then run:
   `pwsh -File C:\Users\scott\Documents\TcUnitFork\docs\verification\Verify-StepZeroXUnit.ps1 -Path <retrieved-file> -Campaign <X> -Phase <RED|GREEN> [-OutCanonical <path>]`
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
| P1 | Isolation preflight, EVERY run: NumberOfInitializedTestSuites | exactly 2/2/3/1 per campaign; first run records what unassigned-PRG registration empirically does | RED runs: xUnit exact-suite assertion held (2/2 suites, zero non-campaign) with exclusions in force; registration behavior remains method-neutral (excluded PRGs never compiled) |
| R1 | REGRESSION RED: script exit code | 0 (all RED-model assertions hold) | **0** — all 26 assertions passed; failures exactly {Test_PaddedNameLookup 15.03s timeout, Test_StaleContextGuard 0.03s misuse-kill, Test_Ordered3_Guard 0.03s misuse-kill}; root tests="5" (successful-count bug live) |
| R2 | REGRESSION RED: AllTestSuitesFinished after summary | stays FALSE for 60 s (breadcrumb #19) | latch never fired: 'TEST RUN COMPLETED' trace absent from all flushed logs after full run + collection (marker evidence per scripted-execution equivalence) |
| R3 | REGRESSION RED: 'TEST RUN COMPLETED' trace | absent | **absent** |
| R4 | REGRESSION RED: out-of-context Error traces | repeated burst from ordered probe (unguarded in baseline) | **25 traces** ('...without active timed test context') across the run's EventLog rotation (1+8+9+7) |
| R5 | COUNTS RED: script exit code | 0 | **0** — all 22 assertions passed; root tests="3", failures="1"=Test_IntentionalFail, no skipped attr; SKIP testcase carries no failure element |
| R6 | COUNTS RED: ADS 'Successful tests:' line | 3 (skipped counted as successful: 4 total - 1 fail) | trace form captured: "TESTS FINISHED - 2 suites, **3 passed**, 1 failed" (2 real passes + 1 skipped counted as passed) |
| G1 | REGRESSION GREEN: script exit code | 0 (zero failures anywhere) | _pending_ |
| G2 | REGRESSION GREEN: AllTestSuitesFinished | TRUE within 60 s | _pending_ |
| G3 | REGRESSION GREEN: 'TEST RUN COMPLETED' trace | present exactly once | _pending_ |
| G4 | REGRESSION GREEN: out-of-context Error trace | exactly once per suite instance (one-shot) | _pending_ |
| G5 | COUNTS GREEN: script exit code | 0 (sole failure identity = Test_IntentionalFail) | _pending_ |
| G6 | COUNTS GREEN: ADS 'Successful tests:' line | 2 (4 total - 1 fail - 1 skip) | _pending_ |
| G7 | EDGE GREEN: script exit code | 0; AllTestSuitesFinished TRUE | _pending_ |
| G8 | xUnit file freshness | absent before each run; fresh creation time + new hash after | _pending_ |
| A1 | ABORT campaign: run PRG_TEST_TCUNIT_STEP0_ABORT; first OBSERVE AllTestSuitesFinished = FALSE and the run in progress (Test_AbortWindow registered, 'TEST RUN STARTED' trace), then online-write TcUnit.GVL_TcUnit.TcUnitRunner.AbortRunningTestSuites := TRUE | precondition observations recorded; after the write, AllTestSuitesFinished latches TRUE promptly and 'TEST RUN ABORTED' trace appears; no ADS summary/xUnit export expected (results never complete); delete any xUnit file afterward | _pending_ |
| S1 | Single-suite (TcUnit-Verifier): exclude PRG_TEST from build, assign PlcTask to PRG_TEST_SEQUENCE, run | AllTestSuitesFinished TRUE with NumberOfInitializedTestSuites = 1; restore PRG_TEST and task assignment afterward; verifier-repo git status clean | _pending_ |

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
| 2026-07-17 | 2026.7.17.1 (baseline) | REGRESSION/RED | 0 | All model assertions held; 3 predicted failures with predicted mechanisms; COMPLETED trace absent (breadcrumb #19 live); 25 unguarded out-of-context traces (R4) |
| 2026-07-17 | 2026.7.17.1 (baseline) | COUNTS/RED | 0 (xUnit model) | All model assertions held; root tests=3/failures=1/no-skipped (count bugs live); 'TEST RUN STARTED' absent from flushed logs (flush-latency artifact on 0.00s run — STARTED check downgraded to WARN in runner) |

---

## Appendix: Baseline repo state (Task 0, recorded 2026-07-17)

### TcUnitFork

- Branch: `feat/timed-test-suite`
- HEAD: `e1de994` docs(step0): plan Revision 4 - re-baseline on 2026.7.17.1, reconcile review findings
- Working tree: clean
- RED baseline library: `TcUnit 2026.7.17.1` (tag `TcUnit-2026.7.17.1`, local-only), installed in the machine library repository and deployed to the PLC via the 2026-07-17 toolchain-validation run (30/30 green on the Raylase campaign).

### TwinCAT_Tests

- Branch: `multi-sequencer-dispatch`
- HEAD: `80daa4c` test: 19 second-order controller tests against Base.FB_SecondOrderController
- Working tree (dirty; disposition pending per Task 0 Step 2):

```
 M README.md
 M TwinCAT_Tests/TwinCAT_Tests/AuxControlTests/PRG_TEST_AUX_LASER.TcPOU
 M TwinCAT_Tests/TwinCAT_Tests/TwinCAT_Tests.plcproj
 M docs/PROJECT_STATE.md
 M test-results/test-timing.jsonl
 M tpm.json
?? TwinCAT_Tests/TwinCAT_Tests/AuxControlTests/FB_RaylaseLaserADSTests.TcPOU
?? TwinCAT_Tests/TwinCAT_Tests/AuxControlTests/MockComponents/FB_RaylaseLaserADSTest.TcPOU
?? docs/TEST_RUN_2026-07-16_RAYLASE_ADS.md
?? runs/
```

Notes: the dirty `TwinCAT_Tests.plcproj` contains BOTH Scott's in-flight Raylase ADS campaign changes AND the TcUnit resolution bump `2026.4.9.1 -> 2026.7.17.1` applied during the 2026-07-17 toolchain validation (proven green, 30/30). Disposition decision recorded below when made.

- Disposition (Scott, 2026-07-17): **Commit Raylase work first** — committed as `c82eb8d` "test: Raylase ADS command-bridge tests; consume TcUnit 2026.7.17.1" on `multi-sequencer-dispatch` (10 files; includes the plcproj with TcUnit resolution 2026.7.17.1).
- `feat/tcunit-step0` created from: `c82eb8d`
- Known carried dirty file: `TwinCAT_Tests/TwinCAT_Tests/DispatchTests/FB_SecondOrderTests.TcPOU` went modified after the disposition commit (likely the open XAE session) — Scott's second-order work, deliberately left untouched; expect it in later cleanliness checks.
