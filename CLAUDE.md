# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Identity

TcUnitFork is a Photara-specific fork of the [TcUnit](https://www.tcunit.org) xUnit testing framework for Beckhoff TwinCAT 3. It extends the upstream framework with Photara Base library integration (`FB_BaseStatic`, `TraceWithSeverity`) for structured test result logging to .jsonl/.db files. Used as the testing foundation across all Photara TwinCAT projects.

## Build & Version

**Build**: Open `TcUnit.sln` in Visual Studio with TwinCAT XAE → Build (Ctrl+Shift+B) → Right-click PLC project → "Save as library and install...". There is no CLI build — TwinCAT requires the XAE IDE or COM automation.

**Compiled library**: `TcUnit.library` at repo root (binary, committed to git).

**Version** (current `2026.3.3.3`): Must be updated in TWO files that stay in sync:
1. `TcUnit/TcUnit/TcUnit.plcproj` → `<ProjectVersion>` tag
2. `TcUnit/TcUnit/Version/Global_Version.TcGVL` → `stLibVersion_TcUnit` fields

## Verification Tests

The `TcUnit-Verifier/` directory contains a two-part self-test:
- **TcUnit-Verifier_TwinCAT/**: PLC test suites that intentionally produce known pass/fail counts
- **TcUnit-Verifier_DotNet/**: C# harness that builds the PLC project via TwinCAT automation API, runs it, and validates expected assertion counts match actual

Verification requires a TwinCAT runtime — it cannot run in CI or headless.

## Architecture

### Execution Flow

```
RUN() / RUN_IN_SEQUENCE()          ← Entry point functions (called cyclically)
  └─ FB_TcUnitRunner               ← Orchestrates all registered test suites
       ├─ FB_TestSuite[]            ← Each suite contains tests + assertion methods
       │    ├─ FB_Test[]            ← Individual test state (name, pass/fail, duration)
       │    ├─ FB_AssertResultStatic      ← Deduplicates scalar assertion failures
       │    └─ FB_AssertArrayResultStatic ← Deduplicates array assertion failures
       ├─ FB_TestResults            ← Aggregates results from all suites
       ├─ FB_AdsTestResultLogger    ← Logs to VS error list via ADS
       └─ FB_xUnitXmlPublisher      ← Optional xUnit XML file export
```

Test suites auto-register in `GVL_TcUnit.TestSuiteAddresses[]` at startup. The runner iterates them each PLC cycle. `RUN()` runs all suites concurrently; `RUN_IN_SEQUENCE()` runs one per cycle with a configurable delay.

### Key Design Decisions

- **All assertion failures route through `FB_AdsAssertMessageFormatter.LogAssertFailure()`** — this is the single centralized trace point for both scalar and array assertion failures. Adding a new assertion type means it automatically gets traced.
- **7 core FBs extend `FB_BaseStatic`** for structured logging. `Initialize()` is NOT called — `TraceWithSeverity` works without it because it gates on the ring buffer's self-initialization, not `BaseStatus.Initialized`.
- **Assertion deduplication**: `FB_AssertResultStatic` tracks (Expected, Actual, Message, TestInstancePath) tuples per cycle to prevent duplicate log entries when assertions re-execute cyclically.
- **GVL_Param_TcUnit is a Parameter List** (`ParameterList="True"`) — its values can be overridden per-project in the consumer's `.plcproj` without recompiling TcUnit.

### Source Layout

All library source lives under `TcUnit/TcUnit/`:
- `POUs/` — Function blocks and functions (entry points, runner, suites, assertions, result loggers)
- `DUTs/` — Enums (`E_AssertionType`), structs (`ST_TestCaseResult`, `ST_TestSuiteResult`), union (`U_ExpectedOrActual`)
- `GVLs/` — `GVL_TcUnit` (runtime state), `GVL_Param_TcUnit` (tunable config)
- `ITFs/` — `I_AssertMessageFormatter`, `I_TestResults`, `I_TestResultLogger`
- `POUs/Functions/` — `RUN`, `RUN_IN_SEQUENCE`, `TEST`, `TEST_FINISHED`, `TEST_ORDERED`, assertion helper functions, `WRITE_PROTECTED_*` wrappers

### Global State

All runtime state is in `GVL_TcUnit`: the runner instance, test suite registry (pointer array), current-test-being-called tracking, ADS message queue, and CPU counter for timing. This global state allows the free functions (`TEST()`, `TEST_FINISHED()`, etc.) to access context.

## Project-Specific Gotchas

1. **FB_TestSuite.TcPOU is ~3800 lines** — use `offset`/`limit` on Read or Grep to find specific sections. It contains all 20+ typed assertion methods inline.

2. **InstancePath shadowing**: FB_TestSuite's own `InstancePath` declaration is commented out (lines ~13-15). The inherited `FB_BaseStatic.InstancePath` with its `{attribute 'instance-path'}` reflection attribute must be the one that receives the runtime value. Do not re-add a local declaration.

3. **One-shot flags required for cyclic traces**: Any `TraceWithSeverity` call in a method called every PLC cycle (e.g., `AreAllTestsFinished`, `RunTestSuiteTests`) MUST use a one-shot flag or `R_TRIG` edge trigger. See `EmptySuiteTraced`, `AllTestSuitesFinishedTrigger` for the pattern.

4. **Duplicate code in runner**: `RunTestSuiteTests()` and `RunTestSuiteTestsInSequence()` have nearly identical code blocks. When editing shared patterns, include method-specific context to uniquely identify the edit target.

5. **Dead code**: `GetDetectionCount()` and `GetDetectionCountThisCycle()` in both `FB_AssertResultStatic` and `FB_AssertArrayResultStatic` are PRIVATE and never called. `ReportResult()` does its own inline matching.

6. **plcproj wiring**: Every new `.TcPOU`, `.TcGVL`, `.TcIO`, `.TcDUT` file must have a `<Compile Include>` entry in `TcUnit.plcproj`. Subdirectories need `<Folder Include>` entries. Files on disk are NOT automatically part of the build.

## Constraints

- **API compatibility**: Must maintain backward compatibility with existing test suites across all Photara projects (TwinCAT_Base, AuxControl, Vision, Motion, Communication, V3Tool, ContinuousTool)
- **Do not remove or weaken** existing assertion methods
- **Upstream conventions preferred** unless a Photara-specific need justifies deviation
- This is a local fork — no upstream contribution workflow

## Documentation

Project uses RepoBaseDocs. Key docs in `docs/`:
- `PROJECT_SPEC.md` — Identity, constraints, scope (human-authored, immutable)
- `PROJECT_STATE.md` — Current status, what's done/active/blocked
- `EXECUTION_PLAN.md` — Phase-ordered work sequence
- `BREADCRUMBS.md` — Gotchas, architecture patterns, file map, session history
- `OPEN_DECISIONS.md` — Unresolved scaling decisions (#4 and #6-#9) plus ADR-004/ADR-005 for decided multi-task tagged execution
- `docs/superpowers/specs/2026-07-16-multitask-tagged-execution-design.md` — Revised Phase 5 design: coordinated registration, compact task slots, immutable execution plans, task-owned state, and manifest-based reporting

Read order for new sessions: PROJECT_SPEC → PROJECT_STATE → EXECUTION_PLAN → BREADCRUMBS.
