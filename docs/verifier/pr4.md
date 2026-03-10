# PR4 - Configuration Surface And Preflight

## Metadata

| Field | Value |
|------|-------|
| Owner | TBD |
| Reviewer | TBD |
| Status | Planned |
| Target Date | TBD |
| Dependencies | PR1, PR2 |

## Definition Of Ready

1. PR1 and PR2 merged.
2. Current machine-specific overrides documented.
3. Config precedence proposal agreed.
4. Test evidence template prepared.

## Goal

Externalize environment assumptions and fail fast when setup is invalid.

## Scope

1. Add config precedence model (CLI > config > defaults).
2. Add preflight checks before expensive operations.
3. Reduce fragile assumptions around TwinCAT/solution/project selection.

## Planned File Changes

1. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/Program.cs`
2. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/VisualStudioInstance.cs`
3. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/AutomationInterface.cs`
4. Optional:
5. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/VerifierConfig.cs`
6. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/PreflightChecks.cs`

## Implementation Checklist

1. Add config options for:
2. target NetId
3. TwinCAT version
4. expected failed test count
5. wait policy defaults
6. Implement precedence:
7. CLI overrides config file
8. config file overrides hard defaults
9. Add preflight checks:
10. DTE ProgID discovery and creation feasibility
11. solution path validation
12. project discovery validation
13. TwinCAT automation object access validation
14. Replace index-based project selection with robust lookup strategy.
15. Add remediation guidance to preflight failures.

## Validation Steps

1. Run with only defaults, verify backward compatibility.
2. Run with config overrides, verify values take effect.
3. Run with intentionally invalid values, verify fail-fast diagnostics.
4. Confirm no source edits required for machine-specific values.

## Merge Gates

1. Config precedence tests pass.
2. Preflight catches misconfiguration before runtime operations.
3. Project lookup no longer depends solely on child index.

## Required Test Evidence

1. Default config run evidence.
2. CLI override evidence.
3. Config file override evidence.
4. Invalid config fail-fast evidence with remediation message.

## CI And Manual Gates

1. CI: config parsing and precedence tests.
2. CI: preflight logic unit tests (mocked where needed).
3. Manual: reference-machine preflight and full run.

## Known Unknowns

1. Preferred config file path and naming convention.
2. How strict project lookup should be when multiple PLC projects exist.

## Roll-Forward Hotfix Plan

1. If preflight is too strict, downgrade selected checks to warnings in patch release.
2. Keep hard-fail for invalid solution path and DTE startup failure.

## Rollback

1. Revert config/preflight modules.
2. Restore previous defaults-based runtime behavior.
