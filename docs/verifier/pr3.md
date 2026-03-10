# PR3 - Parser Hardening And Parse Policy

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
2. Sample valid and malformed log fixtures collected.
3. Fatal vs non-fatal parse policy reviewed.
4. Test evidence template prepared.

## Goal

Make log parsing resilient so malformed lines cannot crash verifier execution.

## Scope

1. Replace unsafe parsing with guarded parsing.
2. Record parse issues with context.
3. Define fatal vs non-fatal parse policy.

## Planned File Changes

1. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/ErrorList.cs`
2. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
3. Optional:
4. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Parsing/VerifierLineParser.cs`
5. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Parsing/ParseIssue.cs`
6. Test files for parser corpus (if test project exists)

## Implementation Checklist

1. Replace `int.Parse`/`double.Parse` with `TryParse`.
2. Guard all regex group access with `match.Success`.
3. Standardize machine-data numeric parsing on `InvariantCulture`.
4. Introduce `ParseIssue` records:
5. source line
6. issue type
7. severity
8. Add parse issue summary in end-of-run report.
9. Define parse policy:
10. fatal: required completion inference impossible
11. non-fatal: isolated malformed informational lines

## Validation Steps

1. Feed valid log fixtures and confirm no issues.
2. Feed malformed timestamp fixtures and confirm no crash.
3. Feed malformed failed-count line and confirm deterministic policy behavior.
4. Confirm parse issue counts appear in summary.

## Merge Gates

1. No unguarded parse operations in critical parsing path.
2. Parser failure never terminates with unhandled exception.
3. Tests/fixtures included for malformed input families.

## Required Test Evidence

1. Valid fixture parse output summary.
2. Malformed timestamp fixture result (no crash).
3. Malformed failed-count fixture result.
4. Parse issue count and severity in final summary.

## CI And Manual Gates

1. CI: parser unit tests and fixture tests.
2. CI: build pass.
3. Manual: run against real captured logs from reference machine.

## Known Unknowns

1. Whether locale parsing should support fallback to current culture for legacy logs.
2. Which parse issues should be fatal by default.

## Roll-Forward Hotfix Plan

1. If strict fatal parse policy blocks valid legacy cases, move specific issue type to non-fatal in patch release.
2. Keep issue count visible so relaxed policy does not hide drift.

## Rollback

1. Revert parser module changes and policy mapping.
2. Preserve fixture files for future hardening attempts.
