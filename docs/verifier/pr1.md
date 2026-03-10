# PR1 - Verification Result Engine And Strict Exit Codes

## Metadata

| Field | Value |
|------|-------|
| Owner | TBD |
| Reviewer | TBD |
| Status | Planned |
| Target Date | TBD |
| Dependencies | None |

## Definition Of Ready

1. Baseline verifier run captured with current behavior.
2. Owner and reviewer assigned.
3. Acceptance criteria copied into PR description.
4. Test evidence template prepared.

## Goal

Eliminate false-green verifier runs by recording failures centrally and mapping outcomes to deterministic exit codes.

## Scope

1. Introduce `VerificationReport` model.
2. Route assertion mismatches into report model.
3. Centralize process exit decision.
4. Treat user interruption as non-success outcome.

## Planned File Changes

1. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
2. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/TestFunctionBlockAssert.cs`
3. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Constants.cs`
4. New file: `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/VerificationReport.cs`

## Implementation Checklist

1. Create `VerificationReport` with:
2. `TotalChecks`, `FailedChecks`, `Warnings`, `RuntimeErrors`
3. `TimedOut`, `Interrupted`
4. `RecordFailure`, `RecordWarning`, `RecordRuntimeError`
5. `Program.cs`: instantiate one shared report instance.
6. `TestFunctionBlockAssert.cs`: on each assertion mismatch, call report recorder.
7. Preserve log lines but stop using logs as the only failure mechanism.
8. Replace scattered `Environment.Exit(...)` with unified result mapping.
9. Add summary output at end of run from `VerificationReport`.
10. Ensure Ctrl+C sets `Interrupted=true`.

## Exit Code Policy

1. `0` only when:
2. run completed normally
3. no verification/runtime/parse failures
4. non-zero when:
5. verification mismatch exists
6. interruption occurs
7. timeout occurs
8. runtime exception occurs

## Validation Steps

1. Run baseline scenario with expected-good results, verify exit code is `0`.
2. Force one known mismatch, verify exit code is non-zero.
3. Interrupt run (Ctrl+C), verify exit code is non-zero and interruption is logged.
4. Verify summary includes failed count and category.

## Merge Gates

1. No remaining log-only mismatch paths.
2. One and only one final exit mapping point in `Program.cs`.
3. Evidence attached for pass, mismatch, and interrupt scenarios.

## Required Test Evidence

1. Build command and result.
2. Pass scenario exit code and summary lines.
3. Forced mismatch exit code and summary lines.
4. Ctrl+C exit code and summary lines.
5. Paths to produced logs.

## CI And Manual Gates

1. CI: verifier project builds.
2. CI: unit tests for report and exit mapping pass.
3. Manual: TwinCAT smoke run confirms non-zero on mismatch.

## Known Unknowns

1. Whether interruption should use distinct exit code vs generic failure code.
2. Whether legacy behavior compatibility flag is needed immediately.

## Roll-Forward Hotfix Plan

1. If stricter exits break downstream scripts, add temporary flag:
2. `--legacy-exit-success-on-mismatch` (default `false`)
3. Document sunset date and remove after one release cycle.

## Rollback

1. Revert `VerificationReport` integration commit.
2. Restore previous exit mapping if required.
