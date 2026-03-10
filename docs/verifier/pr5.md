# PR5 - Dependency And Build Modernization

## Metadata

| Field | Value |
|------|-------|
| Owner | TBD |
| Reviewer | TBD |
| Status | Planned |
| Target Date | TBD |
| Dependencies | PR4 (recommended) |

## Definition Of Ready

1. Runtime behavior PRs (PR1-PR4) stabilized.
2. Clean-machine baseline restore/build steps captured.
3. COM interop validation checklist prepared.
4. Test evidence template prepared.

## Goal

Improve dependency maintainability and build reproducibility for the verifier project.

## Scope

1. Migrate from `packages.config` to `PackageReference`.
2. Preserve COM interop behavior.
3. Update build/restore documentation.

## Planned File Changes

1. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/TcUnit-Verifier.csproj`
2. `TcUnit-Verifier/TcUnit-Verifier_DotNet/TcUnit-Verifier/packages.config` (remove/deprecate)
3. `TcUnit-Verifier/README.md`
4. `docs/CONTRIBUTING.md` (if verifier setup is documented there)

## Implementation Checklist

1. Convert NuGet dependency declarations to `PackageReference`.
2. Remove legacy package hint paths where replaced by package references.
3. Validate COM references still compile and run.
4. Document exact restore/build steps for clean machine setup.
5. Add troubleshooting section for common restore/build failures.

## Validation Steps

1. Clean restore and build on reference machine.
2. Rebuild after NuGet cache clear.
3. Run verifier startup smoke test to confirm runtime dependency resolution.

## Merge Gates

1. Clean machine restore/build succeeds.
2. No COM interop regressions observed.
3. Contributor docs updated with exact commands.

## Required Test Evidence

1. Clean restore/build logs.
2. Rebuild after cache clear logs.
3. Runtime startup smoke evidence after migration.
4. Updated docs snippets with exact commands.

## CI And Manual Gates

1. CI: restore/build succeeds with new project dependency format.
2. CI: docs checks for updated commands and links.
3. Manual: runtime smoke test confirms dependency resolution.

## Known Unknowns

1. Whether SDK-style conversion should be included or deferred.
2. Any COM reference edge cases on older Visual Studio installations.

## Roll-Forward Hotfix Plan

1. If package migration causes environment-specific restore failures, patch with explicit package version pins.
2. If needed, defer SDK-style conversion to separate post-plan milestone.

## Rollback

1. Revert project dependency changes and restore `packages.config` path.
2. Keep documentation notes if still useful.
