# Step-0 Verification (Phase 4a/4b + sequential runner + xUnit counts)

Procedure body is added by plan Task 5. This file starts with the Task 0 preflight baseline.

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

- Disposition: _pending_
- `feat/tcunit-step0` created from: _pending_
