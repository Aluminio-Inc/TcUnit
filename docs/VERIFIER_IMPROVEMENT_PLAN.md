# TcUnit-Verifier Reliability And Modernization Plan

**Date**: 2026-03-10  
**Status**: Proposed  
**Scope**: `TcUnit-Verifier/TcUnit-Verifier_DotNet`

---

## Purpose

This document defines a detailed development plan for improving the reliability, determinism, and maintainability of TcUnit-Verifier_DotNet. The plan focuses on making verifier outcomes trustworthy in local and automated runs, preventing hangs, hardening parsing logic, externalizing environment assumptions, and improving contributor ergonomics.

Detailed per-PR execution checklists are in [docs/verifier/README.md](./verifier/README.md).

---

## Why This Plan Exists

Review findings in the verifier identified these primary risks:

1. Verification mismatches can be logged without forcing a failing exit code.
2. Runtime polling can block indefinitely without timeout.
3. Parsing logic can fail on format drift or locale-sensitive values.
4. Several environment values are hardcoded, reducing portability.
5. Legacy project/dependency setup and minor docs drift increase maintenance cost.

The plan below translates these findings into concrete, phased engineering work.

---

## Objectives And Success Criteria

### Objectives

1. Make success/failure semantics strict and deterministic.
2. Ensure every run has bounded execution time.
3. Make log parsing resilient to malformed lines and locale variation.
4. Remove hardcoded machine assumptions via configuration.
5. Improve build and contributor maintainability.

### Success Criteria

1. No false-green verifier runs: any check mismatch returns non-zero exit code.
2. No infinite wait behavior: all polling loops have timeout and no-progress policies.
3. Parser failures are surfaced as structured diagnostics, not unhandled exceptions.
4. Verifier can be configured for environment-specific values without source edits.
5. Contributor docs describe exact behavior, setup expectations, and troubleshooting.

---

## Non-Goals

1. Replacing TwinCAT or Visual Studio DTE automation architecture.
2. Redesigning TcUnit library test APIs in this phase.
3. Full productization of distributed runner infrastructure.

---

## Current-State Summary

The verifier currently provides useful automation but has reliability gaps that can affect trust in CI and local validation:

1. Assertion helper methods report mismatches via logs instead of a central pass/fail state.
2. The orchestration loop waits for completion markers with unbounded polling.
3. Parsing depends on strict text assumptions and direct parse calls.
4. TwinCAT version/project item assumptions are hardcoded in the code path.
5. Dependency setup uses legacy package management (`packages.config`).

---

## Delivery Strategy

Work is split into six workstreams delivered in staged PRs, from highest risk reduction to lowest.

### Guiding principles

1. First eliminate false positives and hangs.
2. Then harden parsing and portability.
3. Then modernize maintainability surfaces.
4. Keep each PR focused, reversible, and test-backed.

---

## Workstream A: Verification Correctness And Exit Semantics

### Goal

Guarantee that verification failures cannot produce a successful process result.

### Detailed Tasks

1. Introduce a central `VerificationReport` model to accumulate:
2. Failed checks
3. Runtime errors
4. Parse errors
5. Interrupted/timeout state
6. Replace log-only assertion behavior with:
7. `RecordFailure(...)` for mismatch events
8. Optional `RecordWarning(...)` for non-fatal diagnostics
9. Add explicit process exit policy:
10. `0` only if run completed and no failures recorded
11. non-zero for mismatch, timeout, interruption, runtime error, or parse-fatal state
12. Update Ctrl+C handling to mark run interrupted and return non-zero.
13. Emit final summary block:
14. Total checks
15. Failed checks
16. Timeout/interrupted flags
17. Representative failure lines
18. Add tests validating exit codes for all major failure classes.

### Acceptance Criteria

1. Known bad assertion set returns non-zero.
2. Ctrl+C path returns non-zero and logs interruption reason.
3. Known good baseline returns zero.

### Estimated Effort

1. Implementation: 3-5 days
2. Tests/docs: 1-2 days
3. Stabilization: 1 day

---

## Workstream B: Bounded Runtime And Hang Prevention

### Goal

Ensure runs terminate predictably and report clear timeout/no-progress diagnostics.

### Detailed Tasks

1. Replace unbounded `while (true)` polling with timeout-bound loop.
2. Add runtime options:
3. `--max-wait-seconds`
4. `--poll-interval-seconds`
5. `--max-no-progress-seconds`
6. Define progress signals:
7. Error list growth
8. Detection of expected finish markers
9. Automation interface responsiveness
10. Implement no-progress failure path if signals stall past threshold.
11. Replace fixed sleeps where possible with readiness checks.
12. Add transient COM read retry policy with capped backoff.
13. Include timing diagnostics in final summary:
14. Total orchestration time
15. Time-to-first-results
16. Time waiting for completion markers

### Acceptance Criteria

1. Run cannot exceed configured timeout.
2. Stalled environments fail with explicit no-progress message.
3. Timeout behavior is deterministic across repeated runs.

### Estimated Effort

1. Implementation: 4-6 days
2. Fault-injection testing: 1-2 days
3. Stabilization: 1 day

---

## Workstream C: Parsing Hardening And Locale Safety

### Goal

Prevent parser crashes and reduce sensitivity to formatting/locale variation.

### Detailed Tasks

1. Guard all regex group access with match checks.
2. Replace direct parse calls with `TryParse`.
3. Standardize culture usage:
4. Invariant parsing for machine-formatted numeric values
5. Explicit date parsing strategy for timestamp prefixes
6. Introduce `ParseIssue` records with line context and reason.
7. Separate parser from orchestrator for direct unit testing.
8. Build parser test corpus including:
9. Current expected log format
10. Missing timestamp component
11. Corrupted number tokens
12. Alternate whitespace/prefix variants
13. Locale-variant decimal or date segments
14. Decide fatal vs non-fatal parse thresholds and document policy.

### Acceptance Criteria

1. Parser does not throw for malformed lines.
2. Parse issues appear in structured summary output.
3. Unit tests cover normal and edge cases.

### Estimated Effort

1. Implementation: 4-5 days
2. Test corpus: 2 days
3. Stabilization: 1 day

---

## Workstream D: Environment Externalization And Portability

### Goal

Reduce machine coupling by making runtime assumptions configurable and validated.

### Detailed Tasks

1. Externalize hardcoded values into CLI/config:
2. Target NetId
3. TwinCAT version selector
4. Expected failed tests count
5. Polling/timeout defaults
6. Define precedence model:
7. CLI option
8. Config file
9. Built-in default
10. Add startup preflight checks:
11. DTE ProgID availability
12. TwinCAT automation object availability
13. Solution path and project discovery integrity
14. Replace fragile project index access with robust lookup strategy (by name/type with fallback).
15. Improve startup error messages with remediation guidance.

### Acceptance Criteria

1. Typical machine differences no longer require source edits.
2. Startup fails fast with actionable messages on misconfiguration.
3. Project selection remains stable across small solution shape changes.

### Estimated Effort

1. Implementation: 5-7 days
2. Preflight/docs: 2 days
3. Stabilization: 1 day

---

## Workstream E: Dependency And Project Modernization

### Goal

Lower maintenance burden and improve restore/build reproducibility.

### Detailed Tasks

1. Migrate NuGet usage from `packages.config` to `PackageReference`.
2. Keep COM interop behavior unchanged during migration.
3. Evaluate SDK-style project conversion feasibility in a dedicated branch.
4. Document reproducible restore/build flow and supported toolchain versions.
5. Add minimal build verification step suitable for local/CI where possible.

### Acceptance Criteria

1. Clean clone restore/build path is documented and reproducible.
2. Dependency references are centralized and easier to update.
3. No COM interop regressions introduced by migration.

### Estimated Effort

1. `PackageReference` migration: 3-5 days
2. SDK-style evaluation (optional in this phase): 5-8 days
3. Docs/stabilization: 1-2 days

---

## Workstream F: Documentation And Contributor Workflow

### Goal

Align docs with actual verifier behavior and reduce onboarding friction.

### Detailed Tasks

1. Correct broken or outdated contributor links.
2. Add verifier behavior spec:
3. Exit code contract
4. Timeout/no-progress rules
5. Parse error policy
6. Add troubleshooting guide for:
7. DTE version mismatch
8. TwinCAT version mismatch
9. Timeout stalls
10. Parsing anomalies
11. Document process for adding new TwinCAT verifier FB + C# assertion pair.
12. Publish release-note template section for verifier behavior changes.

### Acceptance Criteria

1. New contributor can run verifier and interpret failure classes without guesswork.
2. Docs reflect real implementation behavior.
3. Troubleshooting path is explicit and actionable.

### Estimated Effort

1. Authoring and updates: 2-4 days
2. Review and alignment pass: 1 day

---

## Phased Timeline (Suggested)

### Phase 0: Alignment (Week 1)

1. Confirm exit code policy and timeout defaults.
2. Finalize config surface and compatibility expectations.
3. Approve parser fatal/non-fatal policy.

### Phase 1: Reliability Core (Weeks 2-3)

1. Complete Workstream A.
2. Complete Workstream B.
3. Start Workstream C.

### Phase 2: Robustness And Portability (Weeks 4-5)

1. Complete Workstream C.
2. Complete Workstream D.
3. Update docs for new runtime options and behavior.

### Phase 3: Maintainability Hardening (Weeks 6-7)

1. Complete Workstream E.
2. Complete Workstream F.
3. Run end-to-end verification and prepare release notes.

### Phase 4: Post-Release Observation (Week 8)

1. Monitor timeout/failure rates.
2. Triage emergent issues.
3. Tune defaults and docs based on real usage.

---

## Validation Plan

### Automated tests

1. Unit tests for parser components and failure recording logic.
2. Exit code mapping tests for all major outcome categories.
3. Timeout and no-progress behavior tests using controlled input/mocks.

### Integration checks

1. Replay-style parser tests from saved logs (`dry-run` parse mode if implemented).
2. Full TwinCAT automation smoke checks on configured reference machine.

### Fault injection scenarios

1. Missing completion markers
2. Corrupted report lines
3. DTE startup failure
4. Cancellation during run
5. Non-responsive error list updates

---

## Risk Register

1. COM/DTE nondeterminism can still create intermittent failures.
2. Mitigation: bounded retries, timeouts, and structured diagnostics.
3. Stricter failure semantics may expose previously hidden issues.
4. Mitigation: clear migration notes and optional compatibility toggle during transition.
5. Parser compatibility with historical log variants may be incomplete initially.
6. Mitigation: corpus-based tests and phased parser rollout.
7. Project modernization may risk COM interop behavior.
8. Mitigation: isolate modernization PR and validate against known-good baseline.

---

## PR Breakdown (Recommended)

### PR1: Verification Result Engine And Strict Exit Codes

**Primary workstreams**: A  
**Objective**: Remove false-green outcomes by introducing central failure accounting and deterministic exit behavior.

**Planned code touchpoints**

1. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
2. `TcUnit-Verifier_DotNet/TcUnit-Verifier/TestFunctionBlockAssert.cs`
3. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Constants.cs`
4. New file: `TcUnit-Verifier_DotNet/TcUnit-Verifier/VerificationReport.cs` (or equivalent)

**Implementation tasks**

1. Add `VerificationReport` domain model:
2. TotalChecks, FailedChecks, Warnings, RuntimeErrors, Interrupted, TimedOut
3. Failure records with category, message, and optional context
4. Thread-safe record methods if needed
5. Wire assertion helpers to call report API instead of only `log.Info`.
6. Add final summary output block from report object.
7. Map summary outcome to process return code at single exit point.
8. Update Ctrl+C handler to set interrupted state and return non-zero.
9. Ensure existing informational logging remains for operator readability.

**Tests**

1. Unit tests for report aggregation logic.
2. Unit/integration tests for exit code mapping:
3. pass path => `0`
4. mismatch path => non-zero
5. interrupted path => non-zero

**Backward compatibility**

1. Log format should remain mostly stable.
2. Exit behavior intentionally becomes stricter; document as a breaking behavioral improvement.

**Rollback strategy**

1. Revert `VerificationReport` wiring and exit mapping commit only.
2. Keep non-invasive logging changes if harmless.

---

### PR2: Timeout-Bound Orchestration And No-Progress Detection

**Primary workstreams**: B  
**Objective**: Eliminate infinite wait states and improve diagnosability of stalled runs.

**Planned code touchpoints**

1. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
2. Optional new helper: `TcUnit-Verifier_DotNet/TcUnit-Verifier/RunWaitPolicy.cs`

**Implementation tasks**

1. Add CLI options:
2. `--max-wait-seconds`
3. `--poll-interval-seconds`
4. `--max-no-progress-seconds`
5. Implement bounded polling loop with deadline evaluation.
6. Implement no-progress tracker (line count and marker progression).
7. Add explicit timeout and no-progress failure reasons to report model.
8. Add runtime timing diagnostics (start/end/deltas).
9. Replace fixed sleeps where direct readiness checks are available.

**Tests**

1. Unit tests for deadline/no-progress logic.
2. Controlled integration tests with synthetic no-growth error stream.
3. Validation that timeout and no-progress map to non-zero exit.

**Backward compatibility**

1. Defaults should mimic current behavior but with bounded upper limit.
2. New flags optional for existing scripts.

**Rollback strategy**

1. Revert wait-policy helper and CLI option parsing additions.
2. Retain harmless logging additions.

---

### PR3: Parser Hardening, Parse Policy, And Test Corpus

**Primary workstreams**: C  
**Objective**: Prevent parsing exceptions and provide robust diagnostics for malformed data.

**Planned code touchpoints**

1. `TcUnit-Verifier_DotNet/TcUnit-Verifier/ErrorList.cs`
2. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
3. `TcUnit-Verifier_DotNet/TcUnit-Verifier/TestFunctionBlockAssert.cs` (if parse assumptions surface here)
4. Optional new files:
5. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Parsing/VerifierLineParser.cs`
6. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Parsing/ParseIssue.cs`
7. Test project/files for parser tests

**Implementation tasks**

1. Replace direct `Parse` calls with `TryParse` variants where appropriate.
2. Guard regex match/group access before consumption.
3. Normalize culture strategy to `InvariantCulture` where input is machine-generated.
4. Add parse issue capture and summary reporting.
5. Define fatal vs non-fatal parse policy:
6. Fatal: required completion markers impossible to determine
7. Non-fatal: recoverable malformed informational lines
8. Add parser test corpus files with representative real-world lines.

**Tests**

1. Valid line parsing tests.
2. Missing timestamp and malformed number tests.
3. Locale variant tests.
4. Policy tests (fatal vs non-fatal behavior).

**Backward compatibility**

1. More robust parsing should be backward compatible.
2. Some runs may newly fail if they were previously passing despite hidden parse corruption.

**Rollback strategy**

1. Revert parser component and fall back to prior inline parse behavior.
2. Keep test corpus files for future reattempt.

---

### PR4: Configuration Surface, Preflight, And Environment Decoupling

**Primary workstreams**: D  
**Objective**: Make verifier behavior configurable and fail-fast on environment issues.

**Planned code touchpoints**

1. `TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
2. `TcUnit-Verifier_DotNet/TcUnit-Verifier/VisualStudioInstance.cs`
3. `TcUnit-Verifier_DotNet/TcUnit-Verifier/AutomationInterface.cs`
4. Optional new files:
5. `TcUnit-Verifier_DotNet/TcUnit-Verifier/VerifierConfig.cs`
6. `TcUnit-Verifier_DotNet/TcUnit-Verifier/PreflightChecks.cs`

**Implementation tasks**

1. Add configurable options for:
2. TwinCAT target NetId
3. TwinCAT runtime version
4. Expected failed test count
5. Wait-policy defaults
6. Define precedence: CLI > config file > hard defaults.
7. Add startup preflight routine:
8. DTE ProgID availability check
9. Solution file and project discovery checks
10. TwinCAT automation object availability check
11. Replace project child index assumptions with safer lookup logic.
12. Standardize startup error messages with remediation hints.

**Tests**

1. Config precedence tests.
2. Preflight failure-path tests.
3. Project lookup tests against representative solution structures.

**Backward compatibility**

1. Existing invocation remains valid with default values.
2. Hardcoded assumptions become defaults, not mandatory code constants.

**Rollback strategy**

1. Revert config/preflight modules while preserving parsing and exit improvements.

---

### PR5: Dependency And Build Modernization

**Primary workstreams**: E  
**Objective**: Improve maintainability of dependency management and build reproducibility.

**Planned code touchpoints**

1. `TcUnit-Verifier_DotNet/TcUnit-Verifier/TcUnit-Verifier.csproj`
2. `TcUnit-Verifier_DotNet/TcUnit-Verifier/packages.config` (remove or deprecate)
3. Docs:
4. `TcUnit-Verifier/README.md`
5. `docs/CONTRIBUTING.md` or new verifier-focused contributor doc

**Implementation tasks**

1. Migrate NuGet package references to `PackageReference`.
2. Validate COM reference behavior remains intact.
3. Document restore/build commands and prerequisites.
4. Optionally evaluate SDK-style conversion in a separate spike branch.
5. Add clear build troubleshooting notes for common setup issues.

**Tests**

1. Clean restore/build on reference machine.
2. Build consistency check after cache clear.
3. Manual validation that verifier runtime still loads dependencies correctly.

**Backward compatibility**

1. Runtime behavior should remain unchanged.
2. Developer setup process changes should be documented in release notes.

**Rollback strategy**

1. Revert project/dependency file changes only.

---

### PR6: Documentation Consolidation And Operator Runbooks

**Primary workstreams**: F  
**Objective**: Ensure repo documentation matches implementation behavior and maintenance workflow.

**Planned code touchpoints**

1. `docs/VERIFIER_IMPROVEMENT_PLAN.md`
2. `TcUnit-Verifier/README.md`
3. `README.md` (root link corrections if needed)
4. `docs/PROJECT_STATE.md`
5. `docs/EXECUTION_PLAN.md`

**Implementation tasks**

1. Publish final verifier behavior specification:
2. Exit code contract
3. Timeout/no-progress policy
4. Parse policy
5. Add troubleshooting matrix and remediation steps.
6. Add “adding new verifier test pair” workflow guide.
7. Update state/plan docs to indicate completion status by PR.
8. Add release-note template section for verifier behavioral changes.

**Tests**

1. Documentation QA pass for link validity and command correctness.
2. Dry-run walkthrough by a maintainer not authoring the changes.

**Backward compatibility**

1. Documentation-only changes.

**Rollback strategy**

1. Revert docs commits directly; no runtime impact.

---

## Workstream Backlog (Ticket-Level)

The following backlog can be used to create GitHub issues or project board items directly.

### Workstream A Tickets

1. WS-A-01: Define `VerificationReport` model and failure categories.
2. WS-A-02: Refactor assertion helpers to write failures to report.
3. WS-A-03: Implement centralized exit code mapping.
4. WS-A-04: Add final summary printer.
5. WS-A-05: Add interruption semantics and tests.

### Workstream B Tickets

1. WS-B-01: Add CLI timeout/no-progress options.
2. WS-B-02: Replace unbounded polling with deadline loop.
3. WS-B-03: Implement progress heartbeat and stall detection.
4. WS-B-04: Add wait diagnostics and timing summary.
5. WS-B-05: Add no-progress and timeout tests.

### Workstream C Tickets

1. WS-C-01: Extract parser logic into isolated component.
2. WS-C-02: Replace parse calls with safe parsing methods.
3. WS-C-03: Add parse-issue model and reporting.
4. WS-C-04: Build parser corpus fixtures.
5. WS-C-05: Add parser policy tests (fatal/non-fatal).

### Workstream D Tickets

1. WS-D-01: Define `VerifierConfig` schema and precedence.
2. WS-D-02: Add CLI and config file loading.
3. WS-D-03: Add preflight checks and structured failures.
4. WS-D-04: Replace fragile project lookup assumptions.
5. WS-D-05: Add config and preflight tests.

### Workstream E Tickets

1. WS-E-01: Migrate `packages.config` to `PackageReference`.
2. WS-E-02: Validate COM reference stability post-migration.
3. WS-E-03: Document restore/build prerequisites and commands.
4. WS-E-04: SDK-style conversion feasibility spike (optional).

### Workstream F Tickets

1. WS-F-01: Update verifier docs to reflect new runtime policies.
2. WS-F-02: Add operator troubleshooting matrix.
3. WS-F-03: Add contributor runbook for new verifier tests.
4. WS-F-04: Align root/docs navigation and cross-links.

---

## Merge Gates Per PR

All PRs in this plan should satisfy these minimum gates:

1. Code builds successfully for verifier project.
2. New/changed behavior has tests or explicit rationale if not testable.
3. Exit code behavior is verified where relevant.
4. Logging remains actionable and non-ambiguous.
5. Documentation updated for user-visible behavior changes.

---

## Release And Rollout Plan

1. Merge PR1-PR3 first as reliability baseline.
2. Run a full reference environment verification cycle.
3. Merge PR4 after preflight/config validation.
4. Merge PR5 after build reproducibility confirmation.
5. Merge PR6 as final documentation lock-in.
6. Tag release with a verifier behavior-change note highlighting:
7. strict exit semantics
8. timeout/no-progress policy
9. parser hardening and diagnostics

---

## PR Dependency Map

| PR | Depends On | Notes |
|----|------------|-------|
| PR1 | None | Foundation for strict outcomes |
| PR2 | PR1 | Uses report model and centralized exit behavior |
| PR3 | PR1 | Uses report model for parse issue summaries |
| PR4 | PR1, PR2 | Preflight and config should align with timeout/exit policy |
| PR5 | PR4 (recommended) | Build updates after runtime behavior stabilizes |
| PR6 | PR1-PR5 | Final docs lock-in after implementation |

---

## Definition Of Ready (Per PR)

Before starting any PR:

1. Branch created with naming convention in this plan.
2. Owner and reviewer assigned.
3. Dependencies merged and pulled locally.
4. Baseline run completed and captured.
5. Target files and acceptance criteria copied into PR description.
6. Required test evidence template prepared.

---

## Required Test Evidence Format

Attach this evidence block in every PR:

1. Environment:
2. OS version
3. Visual Studio version
4. TwinCAT version
5. Command(s) run:
6. Exact command string(s)
7. Expected result:
8. Exit code
9. Key summary lines
10. Actual result:
11. Exit code
12. Key summary lines
13. Artifacts:
14. Log path(s)
15. Screenshot(s) if UI/DTE behavior is relevant

---

## CI And Manual Gate Policy

### CI gates (required on every PR)

1. Verifier project build check.
2. Unit tests for changed logic (where available).
3. Static docs/link checks for docs-only PRs.

### Manual gates (required before merge to main)

1. Full TwinCAT automation smoke run on reference machine.
2. Exit code behavior spot-check for changed outcome paths.
3. Parse summary spot-check when parsing path changes.

---

## Tracking Template

Use this checklist in project tracking:

- [ ] PR1 merged
- [ ] PR2 merged
- [ ] PR3 merged
- [ ] PR4 merged
- [ ] PR5 merged
- [ ] PR6 merged
- [ ] Full reference environment run passed
- [ ] Docs verified by non-author maintainer

---

## Completion Tracker Table

| PR | Status | Owner | Reviewer | Target Date | Merged Date | Follow-ups |
|----|--------|-------|----------|-------------|-------------|------------|
| PR1 | Planned | TBD | TBD | TBD | TBD | TBD |
| PR2 | Planned | TBD | TBD | TBD | TBD | TBD |
| PR3 | Planned | TBD | TBD | TBD | TBD | TBD |
| PR4 | Planned | TBD | TBD | TBD | TBD | TBD |
| PR5 | Planned | TBD | TBD | TBD | TBD | TBD |
| PR6 | Planned | TBD | TBD | TBD | TBD | TBD |

---

## Actionable Execution Playbook

This section is intentionally procedural and can be executed step-by-step by maintainers.

### Branching Convention

1. `feature/verifier-pr1-exit-semantics`
2. `feature/verifier-pr2-timeout-policy`
3. `feature/verifier-pr3-parser-hardening`
4. `feature/verifier-pr4-config-preflight`
5. `feature/verifier-pr5-build-modernization`
6. `docs/verifier-pr6-runbooks`

### Commit Convention

1. `verifier(pr1): add VerificationReport and strict exit mapping`
2. `verifier(pr2): replace infinite polling with timeout/no-progress policy`
3. `verifier(pr3): harden parsing and add parse issue ledger`
4. `verifier(pr4): add config precedence and environment preflight`
5. `verifier(pr5): migrate to PackageReference and update build docs`
6. `docs(verifier): publish operator and contributor runbooks`

### PR1 Implementation Checklist (File-Level)

1. `Program.cs`
2. Create single outcome path at process end.
3. Replace direct `Environment.Exit(...)` scatter with `return code` flow where practical.
4. Ensure Ctrl+C marks interrupted state before shutdown.
5. `TestFunctionBlockAssert.cs`
6. Convert assertion mismatch logging into report failure writes.
7. Keep `log.Info` text for human readability after recording failure.
8. `Constants.cs`
9. Add explicit return codes if adding categories (`RETURN_TIMEOUT`, `RETURN_INTERRUPTED` optional).
10. Add `VerificationReport.cs`
11. Add failure categories enum and summary renderer.

### PR1 Validation Commands

1. Build verifier project.
2. Run good baseline scenario and confirm exit code `0`.
3. Inject known mismatch and confirm non-zero exit code.
4. Simulate interruption and confirm non-zero exit code.

### PR2 Implementation Checklist (File-Level)

1. `Program.cs`
2. Add CLI options for max wait, poll interval, and no-progress threshold.
3. Replace `while (true)` with loop driven by `deadlineUtc`.
4. Track progress state (`lastErrorCount`, `lastProgressUtc`).
5. Add timeout and no-progress failure records in `VerificationReport`.
6. Optional: add `RunWaitPolicy.cs` for pure logic and easy unit testing.

### PR2 Validation Commands

1. Run with tiny timeout and verify deterministic timeout failure.
2. Run with normal timeout and verify completion in stable environment.
3. Run with no-progress simulation and verify non-zero exit + reason text.

### PR3 Implementation Checklist (File-Level)

1. `ErrorList.cs`
2. Guard regex with `match.Success`.
3. Replace direct parse calls with `TryParse`.
4. Use explicit `CultureInfo.InvariantCulture` for machine numbers.
5. Add parse issue record emission.
6. Optional parser extraction:
7. `Parsing/VerifierLineParser.cs`
8. `Parsing/ParseIssue.cs`
9. `Program.cs`
10. Consume parse issues and include in final summary.

### PR3 Validation Commands

1. Run parser tests against:
2. valid fixture
3. malformed timestamp fixture
4. malformed failed-test-count fixture
5. mixed locale fixture
6. Confirm no unhandled exceptions; failures are report-driven.

### PR4 Implementation Checklist (File-Level)

1. `Program.cs`
2. Add config file load option and precedence handling.
3. Add startup preflight call before expensive operations.
4. `VisualStudioInstance.cs`
5. Replace hardcoded TwinCAT version assignment with configurable value.
6. Improve DTE ProgID null handling with explicit remediation.
7. `AutomationInterface.cs`
8. Support robust project lookup and failure explanation.
9. Optional:
10. `VerifierConfig.cs`
11. `PreflightChecks.cs`

### PR4 Validation Commands

1. Run with defaults, ensure backward-compatible startup.
2. Run with overridden config values, confirm precedence correctness.
3. Run with intentionally invalid values, confirm fail-fast diagnostics.

### PR5 Implementation Checklist (File-Level)

1. `TcUnit-Verifier.csproj`
2. Convert package references to `PackageReference`.
3. Preserve COM reference declarations and interop behavior.
4. `packages.config`
5. Remove or deprecate after successful migration.
6. `TcUnit-Verifier/README.md` and/or docs
7. Add exact restore/build steps and requirements.

### PR5 Validation Commands

1. Clean restore and build on reference machine.
2. Rebuild after clearing NuGet cache.
3. Verify runtime launch still resolves dependencies.

### PR6 Implementation Checklist (File-Level)

1. `TcUnit-Verifier/README.md`
2. Add exit-code table and failure category definitions.
3. Add timeout and parse policy explanations.
4. `docs/VERIFIER_IMPROVEMENT_PLAN.md`
5. Mark delivered items complete with links to merged PRs.
6. `README.md` and docs sidebars/state files
7. Fix and verify all plan/document cross-links.

### PR6 Validation Commands

1. Link-check docs manually.
2. Execute runbook from clean shell and validate expected outputs.

---

## Acceptance Test Matrix (Executable)

Use this matrix to decide “ready to merge” status.

### A. Exit Semantics

1. Scenario: all checks pass.
2. Expected: exit code 0, summary shows 0 failed checks.
3. Scenario: single assertion mismatch.
4. Expected: non-zero exit, failure category `verification_mismatch`.
5. Scenario: Ctrl+C during run.
6. Expected: non-zero exit, failure category `interrupted`.

### B. Timeout/No-Progress

1. Scenario: forced short timeout.
2. Expected: non-zero exit, failure category `timeout`.
3. Scenario: no new errors for configured threshold.
4. Expected: non-zero exit, failure category `no_progress`.

### C. Parsing

1. Scenario: malformed count line.
2. Expected: no crash, parse issue recorded, deterministic fail/pass per policy.
3. Scenario: malformed timestamp line.
4. Expected: no crash, parse issue recorded, summary includes issue count.

### D. Config/Preflight

1. Scenario: invalid TwinCAT version configured.
2. Expected: preflight failure with remediation text.
3. Scenario: missing solution path.
4. Expected: fail-fast preflight error.

---

## GitHub Issue Templates (Copy/Paste)

### Template: Workstream ticket

1. Title: `WS-X-YY <short task name>`
2. Description:
3. Problem statement
4. Scope (in/out)
5. Files expected to change
6. Acceptance criteria
7. Test evidence required
8. Rollback note

### Template: PR description

1. Summary
2. Why this change
3. Files changed
4. Behavior changes
5. Backward compatibility
6. Test evidence
7. Risk and rollback
8. Follow-up items

---

## Done Criteria Per PR (Strict)

### PR1 done when

1. At least one forced mismatch returns non-zero.
2. All assertion helpers route through failure recorder.
3. Summary block includes counts and categories.

### PR2 done when

1. Infinite polling path removed.
2. Timeout and no-progress are user-configurable.
3. Timeout/no-progress each verified by tests.

### PR3 done when

1. No direct unguarded parse operations remain in parsing path.
2. Parse issues are visible in final summary.
3. Parser fixtures cover malformed input families.

### PR4 done when

1. Config precedence works as documented.
2. Hardcoded environment assumptions are optional defaults.
3. Preflight blocks invalid setup before run starts.

### PR5 done when

1. `PackageReference` migration complete and builds from clean restore.
2. COM references still functional.
3. Build/run docs updated.

### PR6 done when

1. Docs reflect actual shipped behavior.
2. New maintainer run-through succeeds using docs only.
3. Cross-links verified.

---

## Operating Metrics

Track these metrics for at least one release cycle:

1. Non-zero exits by category (`verification`, `timeout`, `runtime`, `interrupt`, `parse`).
2. Runtime distribution (median/p95).
3. Timeout/no-progress frequency.
4. Parse issue count per run.
5. Preflight failure rate and top causes.
6. Confirmed false-green incidents (target: zero).

---

## Definition Of Done

1. Verifier cannot return success when verification checks fail.
2. Verifier cannot block indefinitely.
3. Parsing is resilient and test-covered.
4. Environment assumptions are configurable and validated.
5. Contributor documentation is updated and accurate.
6. Build/dependency setup is maintainable and reproducible.
