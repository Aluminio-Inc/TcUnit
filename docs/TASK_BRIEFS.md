# Task Briefs

Self-contained task descriptions for parallel agent work. Each task is a complete work packet — an agent should be able to read one brief and start working without asking questions.

**Execution plan**: See [EXECUTION_PLAN.md](./EXECUTION_PLAN.md) for the full phase sequence and priorities.

---

## Task A: Extend FB_AssertResultStatic with FB_BaseStatic

**Priority**: Medium
**Scope**: 1 file, ~10 lines
**Dependencies**: None (Phase 1 complete)
**Phase**: Phase 2.1

**Impact**: Surfaces assert buffer overflow errors in structured .jsonl logs instead of ADS-only messages.

### Context

FB_AssertResultStatic tracks all assertion results. When the assertion count exceeds `GVL_Param_TcUnit.MaxNumberOfAssertsForEachTestSuite`, an overflow error is logged via ADS only. This is invisible in .jsonl logs.

### What to Build

#### 1. Add EXTENDS FB_BaseStatic

Modify the FB declaration to extend FB_BaseStatic.

#### 2. Add TraceWithSeverity at Overflow

In the overflow condition (where `AssertResultOverflow` is set), add a TraceWithSeverity call at Error severity.

### Key Files to Read

- `TcUnit/TcUnit/POUs/FB_AssertResultStatic.TcPOU` — Find the `AssertResultOverflow` flag and ADS WriteLog call
- `TcUnit/TcUnit/TcUnit.plcproj` — Verify Base library reference exists

### File Ownership

| File | Action |
|------|--------|
| `TcUnit/TcUnit/POUs/FB_AssertResultStatic.TcPOU` | Modify |

### Verification

Build the TcUnit project in Visual Studio — no compile errors.

---

## Task B: Extend FB_AssertArrayResultStatic with FB_BaseStatic

**Priority**: Medium
**Scope**: 1 file, ~10 lines
**Dependencies**: None (Phase 1 complete)
**Phase**: Phase 2.1

**Impact**: Same as Task A but for array assertion overflow.

### Context

Parallel structure to FB_AssertResultStatic. Same overflow pattern, same ADS-only logging gap.

### What to Build

Same pattern as Task A applied to FB_AssertArrayResultStatic.

### Key Files to Read

- `TcUnit/TcUnit/POUs/FB_AssertArrayResultStatic.TcPOU` — Find the overflow condition

### File Ownership

| File | Action |
|------|--------|
| `TcUnit/TcUnit/POUs/FB_AssertArrayResultStatic.TcPOU` | Modify |

### Verification

Build the TcUnit project in Visual Studio — no compile errors.

---

## Task C: Extend FB_xUnitXmlPublisher with FB_BaseStatic

**Priority**: Medium
**Scope**: 1 file, ~15 lines
**Dependencies**: None (Phase 1 complete)
**Phase**: Phase 2.2

**Impact**: Surfaces xUnit XML file write failures — currently completely silent.

### Context

FB_xUnitXmlPublisher writes test results to an xUnit-compatible XML file. The `DeleteOpenWriteClose` method returns error codes but they are never traced. File I/O failures are invisible.

### What to Build

#### 1. Add EXTENDS FB_BaseStatic

Modify the FB declaration to extend FB_BaseStatic.

#### 2. Add TraceWithSeverity at File I/O Errors

In `DeleteOpenWriteClose`, when the result code indicates failure, trace at Error severity with the file path and error code.

### Key Files to Read

- `TcUnit/TcUnit/POUs/FB_xUnitXmlPublisher.TcPOU` — Read DeleteOpenWriteClose method

### File Ownership

| File | Action |
|------|--------|
| `TcUnit/TcUnit/POUs/FB_xUnitXmlPublisher.TcPOU` | Modify |

### Verification

Build the TcUnit project in Visual Studio — no compile errors.

---

## Task Priority Matrix

| Task | Priority | Effort | Can Start Now? | Phase |
|------|----------|--------|----------------|-------|
| Task A: FB_AssertResultStatic | Medium | Small | Yes | 2.1 |
| Task B: FB_AssertArrayResultStatic | Medium | Small | Yes | 2.1 |
| Task C: FB_xUnitXmlPublisher | Medium | Small | Yes | 2.2 |

---

## Guidelines

### Sizing Tasks

- A task should be completable in **1-4 agent sessions**. If it's larger, break it into subtasks.
- Each task should modify a **bounded set of files**. If a task touches everything, it's too big.
- Tasks within the same phase can run in parallel if their file ownership doesn't overlap.

### File Ownership Rules

- Every task declares which files it creates or modifies.
- No two active tasks may own the same file. If overlap is unavoidable, one task must complete first (sequential gating).
- Shared files (e.g., main entry point, config) should be owned by at most one task at a time.

### Verification Requirements

- Every task must include executable verification commands.
- Prefer automated checks (test commands, curl requests, lint) over manual inspection.
- Include expected output or success criteria for each command.

### Self-Containment

- A task brief must include enough context for an agent to work without reading the entire codebase.
- Reference specific files and line numbers, not vague pointers like "see the recommendation module."
- Include relevant data structures, function signatures, and interface contracts directly in the brief.
