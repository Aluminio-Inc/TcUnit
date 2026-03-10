# PR2 - Timeout And No-Progress Control

## Metadata

| Field | Value |
|------|-------|
| Owner | TBD |
| Reviewer | TBD |
| Status | Planned |
| Target Date | TBD |
| Dependencies | PR1 |

## Definition Of Ready

1. PR1 merged.
2. Baseline wait-loop timing captured.
3. Timeout default proposal agreed.
4. Test evidence template prepared.

## Goal

Remove infinite wait behavior and provide deterministic timeout/no-progress failures with diagnostics.

## Scope

1. Replace unbounded polling loop.
2. Add configurable wait policy options.
3. Track and fail on no-progress conditions.

## Planned File Changes

1. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
2. Optional helper: `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/RunWaitPolicy.cs`

## Implementation Checklist

1. Add CLI flags:
2. `--max-wait-seconds`
3. `--poll-interval-seconds`
4. `--max-no-progress-seconds`
5. Compute `startUtc`, `deadlineUtc`, and `lastProgressUtc`.
6. Replace `while (true)` with deadline-aware loop.
7. Define progress as any of:
8. error line count increases
9. expected completion marker state advances
10. Add no-progress failure when threshold exceeded.
11. Write timeout/no-progress events to `VerificationReport`.
12. Print timing diagnostics in final summary.

## Validation Steps

1. Use very small `--max-wait-seconds`, confirm timeout failure.
2. Use normal values in healthy run, confirm completion.
3. Simulate no-progress condition, confirm no-progress failure category.

## Merge Gates

1. Infinite loop path removed.
2. Timeout and no-progress each have explicit error category.
3. Evidence attached for normal, timeout, and stalled runs.

## Required Test Evidence

1. Default run timing summary and exit code.
2. Forced timeout scenario with exit code and reason.
3. Forced no-progress scenario with exit code and reason.
4. Log paths for all three scenarios.

## CI And Manual Gates

1. CI: build and wait-policy unit tests.
2. CI: timeout logic tests.
3. Manual: TwinCAT smoke run validates completion marker detection.

## Known Unknowns

1. Best default timeout for slower dev machines.
2. Whether no-progress should be measured by line count only or marker progression plus line count.

## Roll-Forward Hotfix Plan

1. If timeout defaults are too aggressive, raise defaults in patch release.
2. Keep behavior configurable via CLI without code changes.

## Rollback

1. Revert wait-policy logic and CLI additions.
2. Keep unrelated diagnostics only if non-invasive.
