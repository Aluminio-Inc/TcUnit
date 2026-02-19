# Documentation Strategy

_Last updated: 2026-02-16_

This document defines **when and how** project documentation must be updated. It is the enforcement mechanism for the RepoBaseDocs framework. Agents and humans follow these rules to prevent documentation drift.

---

## Mandatory Update Triggers

| Event | EXECUTION_PLAN | TASK_BRIEFS | BREADCRUMBS | PROJECT_STATE | OPEN_DECISIONS |
|-------|---------------|-------------|-------------|---------------|----------------|
| Phase/task completed | Mark Done | Remove or archive brief | -- | Move to Done section | -- |
| New phase/task created | Add phase card | Add task brief | -- | -- | -- |
| Gotcha discovered | -- | -- | Add to Critical Gotchas | -- | -- |
| Architecture pattern identified | -- | -- | Add to Architecture Patterns | -- | -- |
| Decision made | Update phase if unblocked | -- | -- | Update if work unblocked | Move to Decided (ADR) |
| New decision needed | Add to phase prerequisites | -- | -- | Add to Blocked if blocking | Add to Open table |
| Session ending | -- | -- | Add Prompt History entry | Update Active/Done | -- |
| Blocker encountered | -- | -- | Add gotcha if technical | Add to Blocked section | Add decision if needed |

---

## Update Rules Per Document

### EXECUTION_PLAN.md

The execution plan is the **single source of truth** for what to build and in what order. Update it when phases complete (mark Done in the Completed Work table), when new phases are added (append a phase card), or when dependencies change. Never delete completed phases -- they are the project's history. The acceptance criteria for each phase are binding; a phase is not Done until all criteria are met.

### TASK_BRIEFS.md

Task briefs are the **work packets** agents consume. Each brief must be self-contained: an agent should be able to read one brief and start working without asking questions. Update when a task completes (remove or mark done), when a new task is scoped (add a full brief), or when requirements change mid-flight. Every brief must have explicit File Ownership and Verification sections.

### BREADCRUMBS.md

Breadcrumbs are **institutional memory**. Add entries when you discover something surprising (a gotcha), when you identify a pattern worth reusing, or when you complete a significant prompt exchange. Never delete gotchas -- they save future agents from repeating mistakes. Keep the File Map current when files are added, renamed, or deleted.

### PROJECT_STATE.md

Project state is the **dashboard**. It answers "where are we?" at a glance. Update at the start and end of every session. Move items between Active, Done, and Blocked as work progresses. Keep the Key Components table current. The "For New Agents" section is critical -- it defines the reading order for onboarding.

### OPEN_DECISIONS.md

Open decisions track **choices that block or shape work**. Add decisions as soon as they are identified, even before options are clear. When a decision is made, move it to the Decided section using the ADR format -- never delete the Open entry, replace it with an ADR. Include rationale and consequences so future agents understand *why*.

### DOCS_STRATEGY.md (this file)

Update this file when the documentation process itself changes -- new triggers, new documents added to the set, or changes to the session handoff ritual.

---

## Session Handoff Ritual

Every agent must execute this protocol before ending a session. The purpose is to leave the project in a state where the next agent (or human) can pick up immediately without re-discovery.

### Before Ending Any Session

1. **What was done**: List completed work with commit references or file changes. Be specific: "Implemented Phase 1 TraceWithSeverity integration (10 trace points across FB_TestSuite and FB_TcUnitRunner)" not "added logging."

2. **What's in flight**: Any partially completed work, uncommitted changes, or experiments that didn't land. Include branch names if applicable.

3. **Test harness knowledge**: How to verify the system works right now. Include exact commands, expected output, and known failures.

4. **Gotchas encountered**: Anything surprising discovered during the session. Add these to BREADCRUMBS.md as well.

5. **Next steps**: The top 3-5 concrete actions for the next session, ordered by priority. Reference specific phases or tasks from EXECUTION_PLAN.md.

### Where to Record

- Update **PROJECT_STATE.md** with items 1, 2, and 5.
- Update **BREADCRUMBS.md** with items 3 and 4 (add gotchas, update file map if files changed).
- If a decision was made or deferred, update **OPEN_DECISIONS.md**.

---

## Agent Session Checklist

Use this checklist at the end of every agent session:

- [ ] PROJECT_STATE.md reflects current Active/Done/Blocked status
- [ ] Any new gotchas are recorded in BREADCRUMBS.md
- [ ] Any decisions made are recorded in OPEN_DECISIONS.md as ADRs
- [ ] EXECUTION_PLAN.md phase statuses are current
- [ ] Completed task briefs are marked done in TASK_BRIEFS.md
- [ ] Session handoff information is recorded (what was done, what's next)

---

## File Ownership Rules

To prevent agent collisions when multiple agents work in parallel:

- Each task brief in TASK_BRIEFS.md declares **explicit file ownership** -- which files that task is allowed to modify.
- No two active task briefs may own the same file. If overlap is unavoidable, one task must complete before the other starts (sequential gating).
- Shared files (like a main app entry point) should be owned by at most one task at a time. Other tasks that need changes to shared files should document their requirements and defer to the owning task.
- Documentation files (BREADCRUMBS.md, PROJECT_STATE.md) are append-only during parallel work -- agents may add entries but should not reorganize or rewrite sections another agent might be reading.

---

## Staleness Prevention

Documentation decays when updates are deferred. These rules prevent it:

1. **No session ends without a PROJECT_STATE.md update.** This is non-negotiable.
2. **Gotchas are recorded immediately**, not "later." If you hit a surprising behavior, add it to BREADCRUMBS.md before moving on.
3. **Decisions are captured when identified**, not when resolved. An open decision with no options listed yet is still valuable -- it flags that a choice is needed.
4. **Monthly review**: If any document hasn't been updated in 30 days, review it for accuracy. Stale docs are worse than no docs.
5. **Dead content gets deleted**, not commented out. Git history preserves the old version.
