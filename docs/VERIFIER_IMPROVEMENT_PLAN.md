# TcUnit-Verifier Reliability And Modernization Plan

**Date**: 2026-03-10
**Status**: Proposed
**Scope**: `TcUnit-Verifier/TcUnit-Verifier_DotNet`

---

## Problem Statement

The verifier C# harness has five reliability gaps that undermine trust in its results:

1. **False greens**: Assertion mismatches are logged but don't affect the exit code. The Ctrl+C handler explicitly exits with code 0.
2. **Infinite hang**: The `while (true)` polling loop (Program.cs ~line 108) has no timeout — if TwinCAT never produces all 7 completion markers, the process blocks forever.
3. **Unsafe parsing**: `int.Parse(error.Description.Split().Last())` for the failed test count will throw on malformed input. `ErrorList.ParseTimestampFromDescription` accesses regex groups without checking `match.Success`.
4. **Hardcoded environment**: `expectedNumberOfFailedTests = 121`, `tcUnitTargetNetId = "127.0.0.1.1.1"`, and TwinCAT version `"3.1.4022.32"` are all baked into source.
5. **Legacy dependencies**: `packages.config` with a single log4net reference; no documented restore/build flow.

> **Note**: Duration parsing already uses `float.TryParse` with `InvariantCulture` — that path is safe.

---

## Delivery: Two PRs

Work is split into two PRs, ordered by risk reduction. PR1 fixes all correctness and safety issues. PR2 improves portability and maintainability.

### PR1: Reliability Core (Workstreams A + B + C)

**Goal**: No false greens, no infinite hangs, no parsing crashes.

#### A. Strict exit semantics

| Task | File | Detail |
|------|------|--------|
| Add `VerificationReport` model | New: `VerificationReport.cs` | Tracks TotalChecks, FailedChecks, Warnings, RuntimeErrors, TimedOut, Interrupted. Thread-safe `RecordFailure(category, message)`. |
| Wire assertion mismatches | `TestFunctionBlockAssert.cs` | Each Assert helper calls `report.RecordFailure(...)` in addition to existing `log.Info`. |
| Centralize exit mapping | `Program.cs` | Single exit point: return 0 only when run completed with zero failures. Replace scattered `Environment.Exit()` calls. |
| Fix Ctrl+C handler | `Program.cs` | Set `report.Interrupted = true`, exit non-zero. Currently exits with `RETURN_SUCCESSFULL`. |
| Add summary output | `Program.cs` | Print total checks, failed checks, category breakdown, and representative failure lines before exit. |
| Extend exit codes | `Constants.cs` | Optional: add `RETURN_TIMEOUT`, `RETURN_INTERRUPTED` if distinct codes are useful. |

#### B. Bounded runtime

| Task | File | Detail |
|------|------|--------|
| Add CLI options | `Program.cs` / `Options` | `--max-wait-seconds` (default 600), `--poll-interval-seconds` (default 10), `--max-no-progress-seconds` (default 120). |
| Deadline-bound loop | `Program.cs` | Replace `while (true)` with `while (DateTime.UtcNow < deadline)`. |
| No-progress detection | `Program.cs` | Track `lastErrorCount` and `lastProgressUtc`. If error list count hasn't grown and no new markers found within threshold, fail with `no_progress`. |
| Timing diagnostics | `Program.cs` | Print total orchestration time, time-to-first-results, and time waiting for completion in summary. |

#### C. Parsing hardening

| Task | File | Detail |
|------|------|--------|
| Safe failed-count parse | `Program.cs` | Replace `int.Parse(error.Description.Split().Last())` with `int.TryParse`. On failure, record a parse issue instead of throwing. |
| Guard regex access | `ErrorList.cs` | Check `match.Success` before accessing `match.Groups[1]` in `ParseTimestampFromDescription`. |
| Record parse issues | `VerificationReport` or new `ParseIssue` record | Capture line content + reason. Include count in final summary. |
| Define fatal vs non-fatal | — | Fatal: can't determine completion state (e.g., failed-count line unparseable). Non-fatal: timestamp on an informational line. |

**Acceptance criteria**:
- Known-good baseline returns exit 0 with summary showing 0 failures
- Forced assertion mismatch returns non-zero with failure category
- Ctrl+C returns non-zero and logs interruption
- Short `--max-wait-seconds` triggers deterministic timeout failure
- Malformed error list lines produce parse issue diagnostics, not exceptions

**Tests**:
- Unit tests for `VerificationReport` aggregation and exit code mapping
- Unit tests for deadline/no-progress logic (extract to `RunWaitPolicy` if useful)
- Parser tests: valid lines, malformed count, malformed timestamp, missing markers

---

### PR2: Portability And Modernization (Workstreams D + E + F)

**Goal**: No source edits needed for machine-specific values. Clean build from clone.

**Depends on**: PR1 merged and stable.

#### D. Configuration externalization

| Task | File | Detail |
|------|------|--------|
| Externalize hardcoded values | `Program.cs`, new `VerifierConfig.cs` | CLI options for: target NetId, TwinCAT version, expected failed test count, wait-policy defaults. |
| Config precedence | `VerifierConfig.cs` | CLI > config file (optional JSON) > built-in defaults. |
| Preflight checks | New `PreflightChecks.cs` | Before expensive DTE operations: check DTE ProgID availability, solution path exists, TwinCAT automation accessible. Fail fast with remediation guidance. |
| Robust project lookup | `AutomationInterface.cs` | Replace fragile child-index access with name/type lookup + fallback. |

#### E. Dependency modernization

| Task | File | Detail |
|------|------|--------|
| PackageReference migration | `TcUnit-Verifier.csproj` | Convert log4net from `packages.config` to `<PackageReference>`. |
| Remove packages.config | `packages.config` | Delete after migration verified. |
| Validate COM interop | — | Ensure COM references still compile and resolve at runtime. |

#### F. Documentation

| Task | File | Detail |
|------|------|--------|
| Exit code contract | `TcUnit-Verifier/README.md` | Table of exit codes and their meanings. |
| Timeout/parse policy | `TcUnit-Verifier/README.md` | Document defaults, CLI overrides, no-progress behavior, parse issue handling. |
| Troubleshooting guide | `TcUnit-Verifier/README.md` | DTE version mismatch, TwinCAT mismatch, timeout stalls, parsing anomalies. |
| Build/restore steps | `TcUnit-Verifier/README.md` | Exact commands for clean-machine setup. |
| Update project docs | `docs/PROJECT_STATE.md`, `docs/EXECUTION_PLAN.md` | Mark plan status and link to results. |

**Acceptance criteria**:
- Verifier runs on a different machine without source edits (only CLI args or config file)
- Preflight catches invalid DTE/solution setup before waiting for TwinCAT
- Clean clone → restore → build works with documented steps
- COM interop unaffected by PackageReference migration

**Tests**:
- Config precedence unit tests
- Preflight failure-path tests (mocked COM objects)
- Clean restore/build on reference machine

---

## Risk Register

| Risk | Mitigation |
|------|-----------|
| COM/DTE nondeterminism causes intermittent failures | Bounded retries, timeouts, structured diagnostics |
| Stricter exits expose previously hidden mismatches | Expected — this is the point. Document as intentional behavioral change. |
| PackageReference migration breaks COM interop | Isolate in PR2; validate against known-good baseline before merge |

---

## Validation Plan

**Automated**: Unit tests for report model, exit mapping, deadline logic, parser safety.

**Integration**: Full TwinCAT automation run on reference machine after each PR.

**Fault injection scenarios**:
1. Missing completion markers → timeout
2. Corrupted error list lines → parse issues recorded, no crash
3. DTE startup failure → preflight catches, exits non-zero
4. Ctrl+C during run → interrupted, exits non-zero

---

## Tracking

- [ ] PR1: Reliability Core — merged
- [ ] PR2: Portability & Modernization — merged
- [ ] Full reference environment run passed after both PRs
