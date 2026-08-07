# CAP-002 Phase 5.2 — Live Delegation & Substitution Integration

## Scope

This milestone integrates the approved Phase 5.1 delegation/substitution persistence foundation into the existing workflow engine, via the two seams `docs/73-workflow-delegation-escalation-architecture.md` designed for exactly this purpose (self-authored in Phase 5.0):

1. **Substitution** plugs into the **candidate-resolution seam** — `workflow_resolve_approval_candidates()`. It changes *who* resolves for a selector; it never touches selector syntax, node validation, or the skip/proceed classification logic.
2. **Delegation** plugs into the **work-item-authorization seam** — `decide_workflow_work_item()`'s single `assigned_to` check. It changes *who may act* on a work item already offered to a specific person; it never touches candidate resolution, round policy, or quorum.

No new persistence model, no new delegation model, no new substitution model. Phase 5.1's four tables and ten RPCs are reused completely and are entirely unmodified by this milestone — confirmed structurally (see "Validation" below).

**Explicitly out of scope, unchanged from Phase 5.1's own boundary:** escalation execution, SLA timers, notifications, background workers, module adapters, the frontend, the visual workflow designer, multi-token execution.

## What changed, and what didn't

Every change in this milestone is a `CREATE OR REPLACE FUNCTION` against an *existing* signature. **Zero DDL** — no new table, no new column (`workflow_approval_positions.section_id` already existed since Phase 2B.2; this milestone is the first to populate it), no new grant, no new RLS policy.

| Function | Change |
|---|---|
| `workflow_resolve_approval_candidates` | Substitution now transforms each resolved candidate's `user_id` to its live-effective substitute, if any, *before* self-approval filtering/dedup/ordinal assignment — applied identically at both call sites (the main resolution CTE and the duplicate-check subquery), via a new shared helper. The output JSON gains a `section_id` field per candidate (populated only for `section_role`-selector rows). Selector syntax and the four `UNION ALL` branches are byte-for-byte unchanged. |
| `workflow_enter_downstream_node` | Only change: the candidate JSON's new `section_id` field is carried through into `workflow_approval_positions.section_id` on insert. Every other line — including the Phase 4.2 `gateway_exclusive` routing branch — is untouched. |
| `decide_workflow_work_item` | The `assigned_to IS DISTINCT FROM v_actor` check is widened: if the actor isn't the original assignee, a new helper checks for a matching active delegation before rejecting. `workflow_decisions.authority_source` and the `decision_recorded` event's metadata gain delegation traceability (see "Traceability" below) when a delegate acted. Every other line — decision recording, outcome calculation, round closure, sequential delivery, event emission, downstream entry, the Phase 4.3 expected-lock-version replay comparison — is untouched. |
| *(new)* `workflow_resolve_effective_candidate` | Private, `STABLE SECURITY DEFINER`, ungranted to `anon`/`authenticated` (reached only from `workflow_resolve_approval_candidates`, mirroring that function's own precedent). Given an originally-resolved candidate (a user, optionally with a role+scope), returns the substitution-effective user. |
| *(new)* `workflow_resolve_active_delegation` | Private, same posture. Given a work item's original assignee and the actor attempting to act, returns the matching active delegation id, checked against all four delegation scope types. |

## Live effectiveness, without a worker

Phase 5.1 deliberately built no background worker to flip a delegation/substitution's stored `status` from `scheduled` to `active` (or to `expired`) when its window's boundary arrives — `accept_workflow_delegation` computes `scheduled` vs. `active` once, at accept time, by comparing `starts_at` to the current instant, and nothing revisits that decision later.

Both new helpers therefore compute effectiveness **live, at query time**, rather than trusting the stored status literal alone:

```
status IN ('scheduled', 'active') AND now() >= starts_at AND now() < effective_end
```

The stored `status` only needs to mean "non-terminal, already past `pending_acceptance`/`rejected`/`revoked`/`expired`/`cancelled`"; whether a record is in effect *right now* is always re-derived from the window at the moment of the query. This is documented here as the correct, necessary consequence of Phase 5.1's stored-state model at live-query time — not a redesign of it. Scenario 7/8 of the behavioral suite exercise this directly: a substitution whose window has already ended has zero live effect regardless of its stored status, and a substitution stuck at `status = 'scheduled'` (because no worker ever ran) is still treated as effective once its window has genuinely started.

## Substitution resolution

`workflow_resolve_effective_candidate(p_user_id, p_organization_id, p_role, p_role_organization_id, p_section_id, p_now)` checks, in priority order:

1. An active `planned_leave` substitution naming `p_user_id` directly (`represented_type = 'user'`).
2. Absent that, an active `acting_appointment` substitution for the given role+scope (`organization_role` or `section_role`), if the caller supplied one.

A named, person-level substitution always outranks a role-wide one, since it is more specific. If neither applies, the original user is returned unchanged.

This is invoked via `LATERAL` join once per originally-resolved candidate row, inside a new `resolved` CTE that sits between the existing four-branch `raw` resolution and the existing `filtered`/`deduped_check`/`ordered` pipeline — so every downstream stage (self-approval exclusion, duplicate detection, ordinal assignment) operates on the already-substituted user with no further change needed. The exact same transform is applied to the separate duplicate-check subquery the function already carries (used only when `allow_multi_capacity = false`), so the two call sites can never drift on substitution behavior — mirroring the existing precedent where `scope_org_id`/`scope_section_ids` are already called identically from both places.

**A substitution can legitimately produce more than one work item for the same substitute.** If `allow_multi_capacity = true` and two distinct role-holders are both covered by the same acting-appointment substitution, both positions remain distinct after substitution (substitution changes identity, not capacity) — two positions, two work items, both assigned to the substitute. This is exercised by behavioral scenario 1. Conversely, if `allow_multi_capacity = false`, the existing duplicate-candidate rejection correctly fires the moment substitution collapses two distinct role-holders onto the same effective user (scenario 9) — this is the pre-existing `allow_multi_capacity` contract working exactly as designed, not a new interaction this milestone had to build.

### An emergent property, not a special case

The instruction governing this milestone asks that work items be created "for the effective delegate/substitute." For substitution, this falls out of the design above with **no additional code**: because substitution transforms `user_id` before `workflow_enter_downstream_node`'s position/work-item-creation loop ever runs, `workflow_work_items.assigned_to` is already the substitute's id by the time that INSERT happens — there is no "original" work item that then gets reassigned. The behavioral suite's scenario 1 confirms the original role-holders receive *zero* work items while a substitution is active, and scenario 3 confirms reverting the substitution restores the original electorate on the next fresh instance.

## Delegation authorization

`workflow_resolve_active_delegation(p_delegator_id, p_delegate_id, p_organization_id, p_work_item_id, p_definition_id, p_step_key, p_role, p_role_organization_id, p_section_id, p_now)` matches an active delegation against whichever of the four scope types applies:

- `work_item` / `definition_step` — matched directly against the concrete work item or step, regardless of which selector type originally resolved the assignee.
- `organization_role` / `section_role` — matched only when the caller supplies the role and scope that actually resolved the assignee as a candidate in the first place.

`decide_workflow_work_item` derives that role/scope from the **position's own already-stored data** — `workflow_approval_positions.authority_source` (parsed only for its `organization_role:`/`section_role:` prefix and role name) plus `organization_id`/`section_id` — never by re-running candidate resolution. This is why `section_id` needed to start being populated on positions (see "What changed" above): without it, a `section_role`-scoped delegation would have had no way to be matched against the exact section a position was resolved under.

### Work items are never duplicated for delegation

Unlike substitution, delegation does **not** create a second work-item row for the delegate. `workflow_work_items.assigned_to` remains the original assignee throughout — delegation only widens *who may complete the existing row*. This is the literal, explicit design docs/73 states ("delegation widens authorization on the original assignee's existing work item; it does not create a second work item"), and this milestone's own behavioral scenario 10/11 confirm `assigned_to` never changes when a delegate decides.

**Reconciling this with the "create work items for the effective delegate" framing**: read together with substitution's emergent behavior above, the instruction is satisfied for both mechanisms, but by two different, individually-correct routes — substitution because the effective identity is baked into the electorate before any work item exists, delegation because the delegate becomes able to *complete* the existing item without a duplicate ever being created. This is not a contradiction requiring an architecture-defect stop: it is the direct, foreseeable consequence of the two seams' different positions in the pipeline (before vs. after work-item creation), and is recorded here explicitly rather than silently resolved.

## Non-exclusive delegation

docs/73 never states that an active delegation revokes the original assignee's own ability to act. This milestone therefore treats delegation as **additive**: both the original assignee and an authorized delegate may decide the work item, whichever acts first closing the position. No new mechanism was needed to make this safe — the existing state guards (`workflow_work_items.state` and `workflow_approval_positions.state` both required to be `'offered'` before any decision proceeds) already reject a second attempt by either party the instant the first decision lands, before authorization is even evaluated. Behavioral scenarios 21/22 exercise this directly: the original assignee can still decide with an active delegation outstanding, and the delegate's later attempt on the now-completed item fails at a pre-existing guard, not new delegation logic.

This is a deliberate, reasoned interpretation of docs/73's silence on exclusivity, recorded here rather than assumed silently. It is also the natural asymmetry with substitution: substitution *is* effectively exclusive, but only as a structural consequence of where it sits in the pipeline — the represented person's identity never appears in `assigned_to` in the first place, so there is nothing for them to additionally act on, not because delegation and substitution follow different exclusivity rules by design.

## Traceability

Reuses existing fields — no new event type, no new column:

- `workflow_decisions.authority_source` (free text, already unconstrained beyond non-empty) gains an appended `|delegated_from:<delegator_uuid>|delegation_id:<uuid>` suffix, but only when the deciding actor is a delegate rather than the original assignee.
- The `decision_recorded` event's metadata gains one new key, `delegation_id` — always present, `NULL` when no delegation was involved.
- `workflow_decisions.actor_id` is already the deciding actor (delegate or original, whichever acted) — no change needed.
- For substitution, `workflow_approval_positions.authority_source` / `workflow_participants.authority_source` (the same free-text column, same precedent) gain an appended `|substituted_from:<original_user_uuid>|substitution_id:<uuid>` suffix when a candidate was substitution-resolved.

Together these satisfy docs/73's traceability requirement — the delegate who acted, the delegation record, and the original delegator (or substitute and original candidate) are all recoverable from data already being written, with no new persistence surface.

## Concurrency

No new lock is acquired anywhere in this milestone. `workflow_resolve_effective_candidate` and `workflow_resolve_active_delegation` are both pure `SELECT` (`STABLE`, no `FOR UPDATE`, no advisory lock) — every lock `decide_workflow_work_item`/`workflow_enter_downstream_node`/`workflow_resolve_approval_candidates` acquires is byte-identical to the pre-5.2 lock order (the single advisory lock keyed by `workflow_decision:actor:instance:command_id`, then the existing row locks on `workflow_instances`/`workflow_instance_steps`/`workflow_approval_rounds`/`workflow_approval_positions`/`workflow_work_items`, in that order). Deadlock with the existing engine is therefore structurally impossible, verified in practice by the concurrency suite: the original assignee and a delegate racing for the same work item resolve to exactly one winner and exactly one decision row (no deadlock, no duplicate); two different delegates racing on the same work item resolve the same way; a substitution create and an unrelated instance start in the same organization proceed without blocking each other.

## Validation

- **Structural**: `validate-workflow-delegation-runtime-integration.sql` — both new helpers private/ungranted/`STABLE`/`SECURITY DEFINER`/pinned `search_path`; substitution wired into both candidate-resolution call sites; selector-branch mechanics unaltered; `section_id` passthrough present; the Phase 4.2 `gateway_exclusive` baseline and Phase 4.3 expected-lock-version baseline both intact; delegation genuinely widens `decide_workflow_work_item` with full traceability; `workflow_enter_downstream_node` itself carries zero direct references to `workflow_delegations`/`workflow_substitutions` (substitution only ever reaches it indirectly, through `workflow_resolve_approval_candidates`); zero new tables/columns; no out-of-scope RPC; prior-phase baseline intact.
- **Behavioral**: `test-workflow-delegation-runtime-integration.sql`, 24/24 scenarios — organization-role and section-role acting-appointment substitution, planned-leave substitution, substitution priority, live-effectiveness with and without a worker having run, the duplicate-candidate interaction, work-item-scope/organization-role-scope/section-role-scope/definition-step-scope delegation, full traceability, revoked/pending-acceptance delegation rejection, non-exclusive delegation, the pre-existing state-guard interaction, and the 1:1 work-item-to-position invariant across every substitution/delegation-affected instance.
- **RLS**: `test-workflow-delegation-runtime-integration-rls.sql`, 8/8 scenarios — confirms zero new grants; confirms an authorized-but-not-yet-acting delegate has no direct RLS visibility into the delegator's work item (being authorized to *decide* is not the same relationship RLS already grants a resolved participant, and this milestone adds no new one); confirms deciding as a delegate does not retroactively grant any new visibility.
- **Concurrency**: `test-workflow-delegation-runtime-integration-concurrency.sql`, 5/5 scenarios (dblink) — no deadlock observed in any race.
- **Performance**: `test-workflow-delegation-runtime-integration-performance.sql` — candidate resolution against 10,000 pre-existing substitution rows and delegated decision authorization against 10,000 pre-existing delegation rows both complete in well under 100ms; `EXPLAIN` confirms index usage (never a sequential scan) on both the substitution and delegation lookup queries at that scale.
- **Existing Phase 5.1 test boundary, updated**: `test-workflow-delegation-substitution-foundation.sql`'s own "LIVE-INTEGRATION BOUNDARY" fixture (scenarios 33–35) was written under Phase 5.1's deliberate "no live integration" scope and originally proved the *opposite* of what is now true by design. Scenario 33 (a work-item-scoped delegation never changes `assigned_to`) remains true and unmodified. Scenarios 34/35, which asserted zero references to the delegation/substitution tables from the engine's core functions, are updated to assert the new, intended integrated behavior instead — following the same superseded-assertion discipline already used elsewhere in this codebase (e.g. the workflow table count going from 12 to 16 in Phase 5.1's own structural validator) rather than leaving them to assert something this milestone correctly makes false. Additionally, scenario 22's leftover active acting-appointment substitution (never revoked by the original test, since nothing downstream cared under the old boundary) is now revoked before the live-integration fixture runs, since it would otherwise collapse the fixture's two-supervisor electorate to one under the newly-live substitution seam — an update to test *fixture hygiene*, not to any assertion about correct behavior.
- **Full regression**: every prior-phase structural validator (Phase 1 through 5.1, 10 files) and every prior-phase behavioral/RLS/concurrency/performance suite (25 files total including this milestone's own four) pass together against the same patched database — zero failures.
- **Rollback**: `rollback-workflow-delegation-runtime-integration.sql` restores all three modified functions to their exact pre-5.2 bodies (verified byte-for-byte against a true independent pre-5.2 baseline — a `pg_dump --schema-only` diff and a `public`-schema function-name-list diff both show zero difference) and drops the two new private helpers. `validate-workflow-delegation-runtime-integration-rollback.sql` confirms this plus Phase 5.1's foundation and the Phase 1–4.3 baseline remaining completely untouched. Reapplying the patch afterward and rerunning the structural and behavioral suites both pass again, confirming clean reapplication.

## Deviations from the literal instruction text, explicitly recorded

1. **"Create work items for the effective delegate/substitute"** is satisfied by two different, individually-correct mechanisms rather than one uniform one — see "An emergent property, not a special case" and "Work items are never duplicated for delegation" above. Judged reconcilable, not a genuine architecture conflict warranting a STOP.
2. **Delegation exclusivity** is not specified by docs/73; this milestone interprets it as additive/non-exclusive, reasoned through in "Non-exclusive delegation" above.
3. **Live-effectiveness computation** (status-plus-window, not status alone) is a necessary consequence of Phase 5.1's deliberate no-worker design, not a new design decision this milestone was free to make differently — documented in "Live effectiveness, without a worker" above.

No other deviation from docs/60 through docs/74 was found or made. The architecture was followed as designed; nothing here required redesigning it.
