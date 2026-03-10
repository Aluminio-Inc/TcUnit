# PR6 - Documentation Consolidation And Runbooks

## Metadata

| Field | Value |
|------|-------|
| Owner | TBD |
| Reviewer | TBD |
| Status | Planned |
| Target Date | TBD |
| Dependencies | PR1, PR2, PR3, PR4, PR5 |

## Definition Of Ready

1. Implementation PRs merged.
2. Final behavior confirmed from merged code paths.
3. Maintainer walkthrough reviewer identified.
4. Test evidence template prepared.

## Goal

Lock documentation to shipped behavior so maintainers can run, debug, and extend verifier work predictably.

## Scope

1. Publish final behavior contract.
2. Add troubleshooting matrix.
3. Add contributor workflow for adding verifier test pairs.
4. Ensure docs cross-links are correct.

## Planned File Changes

1. `TcUnit-Verifier/README.md`
2. `docs/VERIFIER_IMPROVEMENT_PLAN.md`
3. `docs/verifier/README.md`
4. `docs/_sidebar.md`
5. `docs/PROJECT_STATE.md`
6. `docs/EXECUTION_PLAN.md`
7. Root `README.md` if link corrections are needed

## Implementation Checklist

1. Add/confirm exit code table with category definitions.
2. Document timeout and no-progress behavior and defaults.
3. Document parse issue policy (fatal vs non-fatal).
4. Add troubleshooting table:
5. DTE unavailable
6. TwinCAT version mismatch
7. no-progress timeout
8. parsing anomalies
9. Add runbook: adding new TwinCAT FB + C# assertion class pair.
10. Verify and fix all docs links.

## Validation Steps

1. Follow runbook from clean shell and confirm steps are complete.
2. Have non-author maintainer validate docs flow.
3. Check docs navigation includes all PR plan pages.

## Merge Gates

1. Behavior docs match implemented runtime behavior.
2. Link validation passes.
3. Maintainer walkthrough feedback addressed.

## Required Test Evidence

1. Link-check output or manual link validation list.
2. Walkthrough notes from non-author maintainer.
3. Confirmation that docs describe actual exit/timeout/parse behavior.

## CI And Manual Gates

1. CI: docs build/link checks pass.
2. Manual: runbook executed end-to-end by maintainer.

## Known Unknowns

1. Whether verifier behavior changes need a dedicated migration note in root release notes.
2. Whether to maintain both condensed and detailed runbook variants.

## Roll-Forward Hotfix Plan

1. If post-merge feedback finds ambiguity, ship docs patch release with clarified examples.
2. Keep canonical references in one place (`docs/verifier/`) to avoid drift.

## Rollback

1. Revert documentation commits only.
