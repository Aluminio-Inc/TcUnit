# Open Decisions

Decisions that shape or block project work. Capture decisions as soon as they are identified, even before options are clear.

---

## Open

| # | Decision | Options | Reference | Decide By |
|---|----------|---------|-----------|-----------|
| ~~1~~ | ~~Should FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, and FB_AdsTestResultLogger extend FB_BaseStatic?~~ | Decided: Option A — see ADR-003 | Phase 2 | Decided 2026-02-19 |
| 2 | Should InstancePath in FB_TestSuite be deleted or remain commented out? | A) Delete entirely; B) Keep commented for reference | Phase 1 cleanup | Non-blocking |
| 3 | Should passing assertions also be traced (Info severity) for full audit trails? | A) Add LogAssertSuccess to I_AssertMessageFormatter; B) Add a pass/fail parameter to LogAssertFailure; C) Leave as-is, only trace failures | Future | Non-blocking |

---

## Decided

Resolved decisions in numbered ADR (Architecture Decision Record) format. Never delete decided entries — they are the project's decision history.

### ADR-001: FB_TestSuite and FB_TcUnitRunner Extend FB_BaseStatic

**Date**: 2026-02-16 | **Status**: Decided

**Context**: TcUnit's test output was limited to ADS messages (253 char max, rate-limited) and xUnit XML. The Photara Base library provides structured logging to .db/.csv/.jsonl via TraceWithSeverity, which requires extending FB_BaseStatic.

**Options considered**:
1. Option 1 (FB_TestSuite extends FB_BaseStatic) — Direct inheritance gives every test suite TraceWithSeverity capability, mid-test tracing, and automatic instance path context.
2. Option 2 (New FB_BaseTestResultLogger implements I_TestResultLogger) — Pluggable logger that extends FB_BaseStatic; non-breaking but only captures summary results, not mid-test events.

**Decision**: Option 1 — both FB_TestSuite and FB_TcUnitRunner extend FB_BaseStatic directly.

**Rationale**: Since this is a local fork (not pushing upstream), breaking change concerns don't apply. Option 1 provides richer tracing (mid-test, per-assertion) vs Option 2's summary-only output. The Initialize() call is not required for TraceWithSeverity, keeping the integration lightweight.

**Consequences/gaps**: Consuming test projects must reference the Base library. The InstancePath type changed from T_MaxString to STRING (inherited). FB_BaseStatic adds memory overhead per test suite instance (BaseConfiguration, BaseStatus structs).

### ADR-002: Centralize Assert Failure Tracing in LogAssertFailure

**Date**: 2026-02-19 | **Status**: Decided

**Context**: Phase 3 initially added `_traceExpected`/`_traceActual` instance variables to FB_TestSuite, with 23 scalar Assert methods each setting these vars before calling `SetTestFailed()`, which read them for its `TraceWithSeverity` call. This was ~44 lines of boilerplate, didn't cover array assertions, and created an awkward instance-variable relay pattern.

**Options considered**:
1. Option 1 (Keep _traceExpected/_traceActual in SetTestFailed) — Current approach; works but requires every new Assert method to remember to set the vars, and doesn't cover arrays.
2. Option 2 (TraceWithSeverity in each Assert method directly) — Even more boilerplate; 40+ methods would each need a trace call.
3. Option 3 (TraceWithSeverity in LogAssertFailure on FB_AdsAssertMessageFormatter) — Single trace point; requires FB_AdsAssertMessageFormatter to extend FB_BaseStatic; automatically covers all assertion types including arrays.

**Decision**: Option 3 — `FB_AdsAssertMessageFormatter EXTENDS Base.FB_BaseStatic` with `TraceWithSeverity` in `LogAssertFailure`.

**Rationale**: Every Assert method already calls `LogAssertFailure(Expected, Actual, Message, TestInstancePath)` with string-converted values. Putting the trace there eliminates all per-method boilerplate and automatically covers array assertions. The `_traceExpected`/`_traceActual` pattern was an unnecessary indirection.

**Consequences/gaps**: FB_AdsAssertMessageFormatter now has a dependency on Base library. The `I_AssertMessageFormatter` interface doesn't mandate FB_BaseStatic — alternative implementations would need their own tracing strategy. Only failure traces are centralized; passing assertions are not traced (see Open Decision #3).

### ADR-003: Extend All 4 Remaining FBs with FB_BaseStatic

**Date**: 2026-02-19 | **Status**: Decided

**Context**: Four FBs (FB_AssertResultStatic, FB_AssertArrayResultStatic, FB_xUnitXmlPublisher, FB_AdsTestResultLogger) had error conditions that were either ADS-only or completely silent. Phase 2 needed a decision on whether to extend all, some, or none with FB_BaseStatic.

**Options considered**:
1. Option A (Extend all 4) — Consistent pattern; every FB with error conditions gets structured logging. Simple, uniform.
2. Option B (Extend only those with error conditions) — All 4 have error conditions, so this is equivalent to Option A.
3. Option C (Leave as-is, use separate logger FB) — Avoids inheritance change but adds complexity and doesn't surface errors in structured logs.

**Decision**: Option A — Extend all 4 FBs with FB_BaseStatic.

**Rationale**: All 4 FBs have error conditions worth tracing. The pattern is proven (3 FBs already extended in Phase 1). The effort is minimal (EXTENDS + TraceWithSeverity calls). Existing ADS logging is unchanged (traces are additive). This brings the total to 7/7 core FBs with structured logging capability.

**Consequences/gaps**: All core TcUnit FBs now depend on the Base library. This is acceptable for a local fork. Memory overhead per FB instance is the same as Phase 1 (BaseConfiguration, BaseStatus structs from FB_BaseStatic).

---

## Guidelines

- **Capture early**: Add a decision to the Open table as soon as it's identified, even with no options listed. This flags that a choice is needed.
- **Record rationale always**: When moving a decision to Decided, the Rationale field is mandatory. Future agents need to understand *why*, not just *what*.
- **Never delete decided entries**: ADRs are permanent records. If a decision is reversed, add a new ADR that references and supersedes the old one.
- **Reference blocking phases**: If an open decision blocks a phase in EXECUTION_PLAN.md, note the phase in the "Decide By" column. This creates traceability between decisions and work.
- **Number ADRs sequentially**: ADR-001, ADR-002, ADR-003, etc. Never reuse numbers, even if an ADR is superseded.
- **Keep options concrete**: "Use X" is better than "consider alternatives." Each option should be specific enough to evaluate.
