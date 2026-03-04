# PROJECT_SPEC

**Tier 1 — Human-Authored.** This document defines the project's identity, constraints, and scope boundaries. Executing agents treat this as immutable context. Only a human edits this file.

---

## Intent

TcUnitFork is a custom fork of the TcUnit xUnit-style testing framework for Beckhoff TwinCAT 3. It maintains Photara-specific additions and fixes that are not contributed upstream. The framework provides assertion methods, test suite organization, and test runner infrastructure for PLC unit testing in IEC 61131-3 Structured Text. Used as the testing foundation across all Photara TwinCAT projects (TwinCAT_Base, AuxControl, Vision, Motion, Communication, V3Tool, ContinuousTool). An executing agent should optimize for backward compatibility with existing test suites and consistency with the upstream TcUnit API where possible.

---

## Core Constraints

1. **MUST** maintain API compatibility with existing test suites across all Photara projects
2. **MUST NOT** remove or weaken existing assertion methods
3. **MUST** follow the xUnit pattern conventions (test suites as FBs, test methods, setup/teardown)
4. **PREFER** upstream TcUnit conventions unless a Photara-specific need justifies deviation

---

## Quality Attributes (ordered)

1. **Code quality & reusability** over shortcuts
2. **Correctness** over speed
3. **Testability / maintainability** over convenience
4. **Performance** follows

---

## Scope Boundaries

| In Scope | Out of Scope |
|----------|-------------|
| xUnit-style test framework for TwinCAT 3 PLC testing | General-purpose testing tools |
| Assertion methods, test suite lifecycle, test runner infrastructure | Contributing changes upstream to TcUnit |
| Photara Base library integration (FB_BaseStatic, TraceWithSeverity) | Test harness patterns — those are defined in consuming projects |
| Structured logging of test results to .jsonl/.db via ring buffer | |

---

## Key Interfaces

| Interface | Direction | Notes |
|-----------|-----------|-------|
| Beckhoff TwinCAT 3 runtime | Dependency | IEC 61131-3 Structured Text execution environment |
| Beckhoff system libraries | Dependency | Tc2_System, Tc2_Utilities, etc. |
| Photara Base library (TwinCATBase) | Dependency | FB_BaseStatic, TraceWithSeverity, ring buffer logging |
| All Photara TwinCAT projects | Consumed by | TwinCAT_Base, AuxControl, Vision, Motion, Communication, V3Tool, ContinuousTool |

---

## Photara-Specific Additions (vs. upstream TcUnit)

- 7 core FBs extended with `FB_BaseStatic` for structured logging
- Centralized assertion failure tracing via `LogAssertFailure` on `FB_AdsAssertMessageFormatter`
- Test duration in pass/fail traces, suite completion summaries with counts
- Error/overflow conditions surfaced via `TraceWithSeverity` (previously ADS-only or silent)

---

## Versioning

Library versioning follows the Photara convention: `YYYY.M.D.revision`. See global CLAUDE.md "Library Versioning and Recompilation" for the two-file sync requirement (`.plcproj` + `Global_Version.TcGVL`).
