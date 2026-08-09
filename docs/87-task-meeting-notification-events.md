# CAP-003 Phase 1.4B — Task & Meeting Notification Event Integration

## Status

Implemented and locally verified against a disposable PostgreSQL harness (full CAP-002 + CAP-003 1.0A–1.4A migration chain applied, extended with the real production Meetings-extension and Task-dependency patch chains — see §9). Not yet pushed — pending a separate push-approval checkpoint.

## Scope

Phase 1.4 wired one pilot event (`task.assigned.v1`). Phase 1.4A added the two generic recipient-target kinds (`task_watchers`, `meeting_participants`) those events needed but did not yet have a producer for. Phase 1.4B wires exactly three additional real business events, each atomically enqueued inside its own already-existing, server-authoritative mutation RPC:

1. **`task.completed.v1`** — `complete_task()`
2. **`meetings.rescheduled.v1`** — `update_meeting()` (time-change only)
3. **`meetings.cancelled.v1`** — `cancel_meeting()`

No new target-descriptor kind, no new `source_record_type` value, no new authorization adapter, and zero changes to `create_notification_intent()`/`resolve_notification_intent()`/`process_platform_outbox_batch()` — all three events resolve through target kinds and authorization adapters Phases 1.4/1.4A already shipped.

## Candidates evaluated

| Candidate | Outcome | Reason |
|---|---|---|
| `task.review_requested.v1` | **Deferred** | No `request_task_review()` (or any review-workflow) RPC exists anywhere in the codebase. Tasks have no review/approval lifecycle today (only create/update/assign/unassign/complete/cancel/watch/comment). Implementing this would require inventing new Task lifecycle behavior — the governing instruction's "STOP for that event" case. |
| `task.returned.v1` | **Deferred** | Same reason — no `return_task_for_correction()` (or equivalent) RPC exists. |
| `task.completed.v1` | **Implemented** | `complete_task()` is the sole, unambiguous authoritative mutation RPC. |
| `meetings.scheduled.v1` | **Deferred** | Two structurally different mutation call sites both produce a "scheduled" meeting, with *inconsistent* existing legacy notification behavior: `create_meeting(p_status:='scheduled')` fires no legacy notification at all; `update_meeting()`'s draft→scheduled publish path does. There is no single, consistent authoritative business intent to mirror without inventing a new, more consistent policy this codebase never actually implements — exactly what "do not guess recipient policy" prohibits. |
| `meetings.rescheduled.v1` | **Implemented** | `update_meeting()` is the sole authoritative mutation RPC for a meeting's own time changing. |
| `meetings.cancelled.v1` | **Implemented** | `cancel_meeting()` is the sole authoritative mutation RPC, single clean transition. |

## Authoritative RPC per implemented event

- **`task.completed.v1`**: `complete_task(p_task_id, p_notes)` — true latest body sourced from `patch-task-dependency-lifecycle-enforcement.sql` (2026-08-02), *not* the superseded `patch-shared-task-foundation.sql` version. Confirmed the sole/final redefinition by a repository-wide search before writing anything.
- **`meetings.rescheduled.v1`** and **`meetings.cancelled.v1`**: `update_meeting()` (true latest 14-parameter body, from `patch-meetings-recurring-phase2-preserve-series-membership.sql`) and `cancel_meeting()` (true latest 3-parameter body, from `patch-meetings-recurring-phase2-notification-suppression.sql`) respectively — confirmed via the same repository-wide search, since both functions had been redefined multiple times by intervening Meetings-extension patches (drafts, lock, recurring, recurring-phase2) not part of the reduced local test harness's own default patch loop.

## Target mapping (no new target kinds)

- **`task.completed.v1`**: mirrors the legacy notification's own recipient set exactly — `created_by AS uid UNION SELECT user_id FROM task_watchers WHERE task_id = p_task_id, WHERE uid IS NOT NULL AND uid <> v_actor` — via **two** atomic outbox events sharing one `correlation_id`:
  - `task_watchers(target_task_id)` — unconditional (target-kind resolution already filters to current watchers).
  - `specific_users([created_by])` — conditional on `created_by IS NOT NULL AND created_by <> actor`, mirroring the legacy self-exclusion.
- **`meetings.rescheduled.v1`** / **`meetings.cancelled.v1`**: `meeting_participants(target_meeting_id)` — the existing Phase 1.4A target kind, exactly matching each function's own legacy notification recipient set.

## Authorization (no new adapters)

Both new source_record_type values already exist (`'task'` since Phase 1.4, `'meeting'` since Phase 1.4A). `intent_user_can_view_task()` already has explicit `t.created_by = p_user` and `task_watchers` `EXISTS` branches — confirmed by direct inspection before any code was written — so it covers *both* `task.completed.v1` recipient kinds with zero changes. `intent_user_can_view_meeting()` (Phase 1.4A) is reused unchanged for both Meeting events. Neither function is modified by this patch.

## Idempotency

Each event's `idempotency_key` is derived from a fresh `audit_logs.id` captured via `RETURNING id` at the exact moment of the real mutation — never a timestamp, never invented.

A genuine, non-obvious finding: `complete_task()`'s own `valid_task_status_transition()` allows `old_status = new_status` unconditionally, meaning `complete_task()` **can legitimately be re-invoked on an already-completed task** without error — pre-existing, unmodified behavior (the legacy notification already re-fires on such a call today). Each genuine execution of `complete_task()`'s mutation body produces its own fresh `audit_logs` row and is therefore its own legitimate, distinguishable occurrence — resolved by reusing the audit trail's own natural per-occurrence identity rather than inventing a fragile key (behavioral scenario 7).

`task.completed.v1`'s second event (`specific_users(created_by)`) needs a *distinct* `idempotency_key` from the first (`task_watchers`), since both share the same `(source_module, source_record_type, source_record_id, event_type)` tuple and `platform_outbox_events`' own uniqueness constraint is keyed on all five columns together. A deterministic `md5(v_audit_id::text || ':task_completed_owner')::UUID` derivation (pgcrypto's `md5()`, already an enabled extension — no new dependency) keeps it reproducible under retry while distinct from the first event's own raw-id key.

## Correlation/causation

Each mutation generates one fresh `gen_random_uuid()` `correlation_id`, shared across every outbox event that single mutation call enqueues (`task.completed.v1`'s two events share one `correlation_id` — both are notification fan-outs of the same completion act). `causation_id` is `NULL` for all three events, identical to `task.assigned.v1`'s own Phase 1.4 precedent.

## Late authorization

Unchanged separation: the domain module determines whether the event can be emitted (its own pre-existing authorization, byte-for-byte unchanged); CAP-003's `resolve_notification_intent()` determines whether each resolved candidate can currently receive the source-linked notification, via the same, unmodified `intent_user_can_view_task()`/`intent_user_can_view_meeting()` adapters. No event payload can override authorization — proven by behavioral scenario 20 (a deliberately mismatched task-sourced intent given a `meeting_participants` target still fails closed at resolution, since `source_record_type='task'` always dispatches to `intent_user_can_view_task()` regardless of which target kind supplied the candidate).

## Dynamic membership

Confirmed for both `task_watchers` (scenario 4: a watcher removed between enqueue and worker processing receives nothing) and `meeting_participants` (concurrency scenario 3: a participant removed mid-flight of a real reschedule race receives nothing or receives the notification depending on transaction-commit ordering, documented as both legitimate serial outcomes) — current membership at processing time, never a stale enqueue-time snapshot, exactly docs/78 §7.2's late-resolution requirement, unchanged from Phase 1.4A.

## Legacy coexistence

All three modified functions' pre-existing legacy `INSERT INTO notifications` dual-write is preserved byte-for-byte and remains fully unconditional except for the `p_suppress_notification` gating each already had (see below) — confirmed directly by the structural validator. No legacy notification write was removed or altered. `complete_task()`'s legacy notification already targeted exactly `created_by UNION task_watchers` (excluding the actor) — this is the *evidenced* business intent the new CAP-003 target mapping mirrors, not an invented one.

## The `p_suppress_notification` finding

`update_meeting()` and `cancel_meeting()` both already carry a `p_suppress_notification BOOLEAN DEFAULT FALSE` parameter (added by `patch-meetings-recurring-phase2-notification-suppression.sql`) specifically so bulk recurring-series operations (`update_entire_series()`, `update_series_this_and_future()`) can update many occurrences per call without generating one notification per occurrence. This is a genuine, non-obvious finding from direct inspection of those bulk RPCs (both call `update_meeting()` with `p_suppress_notification := TRUE` for every per-occurrence mutation) — not something the governing candidate list mentioned explicitly. Both new CAP-003 enqueue calls are gated on the *same* `NOT p_suppress_notification` check the legacy branches already use (behavioral scenarios 13 and 17). Failing to do this would have silently reopened the exact notification-storm vector that flag exists to close, just through a new channel.

## `meetings.rescheduled.v1` scoping

Deliberately narrower than the legacy `meeting_updated` notification's own `v_meaningful_change` condition (title/location/time changes all qualify for the legacy branch). The new CAP-003 event fires only when `v_time_changed AND NOT v_publishing AND v_new_status = 'scheduled'` — a title-only or location-only edit is not a "reschedule" (scenario 11); the first publish of a draft meeting with a start time supplied is `meetings.scheduled.v1` territory, deliberately deferred, never conflated with a genuine reschedule of an already-scheduled meeting (scenario 12).

## Safe payload

`template_params` carries only structural identifiers/timestamps/actor ids, matching `task.assigned.v1`'s own established shape:

- `task.completed.v1`: `task_id`, `task_title`, `completed_by`.
- `meetings.rescheduled.v1`: `meeting_id`, `meeting_title`, `new_start_at`, `new_end_at`, `rescheduled_by`.
- `meetings.cancelled.v1`: `meeting_id`, `meeting_title`, `cancelled_by`.

`p_notes` (`complete_task`) and `p_cancellation_reason` (`cancel_meeting`) are **deliberately excluded** — both are free-text user input, the same "unrestricted user text" category the governing instruction explicitly prohibits carrying into notification payloads. Verified both by the structural validator (substring-scoped check on the enqueue call site) and the behavioral suite (scenarios 1 and 15, which pass a distinctive marker string and assert it never appears in the outbox payload).

## Worker genericity

`process_platform_outbox_batch()` is **not modified at all** by this milestone. All three new event types are registered exactly like `task.assigned.v1` (`uses_generic_notification_envelope = TRUE`), routing through the same registry-driven generic passthrough path with zero worker code changes — proven directly by behavioral scenario 22, which drains a real `task.completed.v1` event and a real `meetings.rescheduled.v1` event through the same unmodified worker call.

## Known, documented limitation: actor self-notification on `task_watchers`/`meeting_participants` targets

The legacy notifications this milestone mirrors all exclude the acting user (`uid <> v_actor` / `meeting_participant_recipient_ids(id, v_actor)`). CAP-003's `specific_users` target is module-controlled, so `task.completed.v1`'s owner-notify event correctly excludes a self-completing creator (scenario 3). However, the `task_watchers`/`meeting_participants` target kinds themselves (Phase 1.4/1.4A, unmodified here) resolve the *full* current membership with no actor-exclusion parameter — if the acting user happens to also be a watcher or participant, they will receive a CAP-003 notification about their own action, a minor UX divergence from legacy. Extending the target-descriptor layer to support self-exclusion would require reopening Phase 1.4A's `resolve_notification_intent()`, out of scope for this milestone. Documented, not worked around.

## What this migration does NOT do

- No `task.review_requested.v1`/`task.returned.v1`/`meetings.scheduled.v1` (deferred above, with exact reasons).
- No Requests/Entry/Internal Collaboration/Prisoner Letters integration.
- No CAP-002/SLA notification producer.
- No new target-descriptor kind, no new `source_record_type`, no new authorization adapter.
- No change to Task/Meeting authorization, status-transition rules, locking, room-booking semantics, participant semantics, or dependency enforcement — every non-enqueue line of every modified function is byte-for-byte unchanged from its true current production body.
- No new mutation RPC, no Realtime cutover, no legacy-table migration, no notification preferences, no email/push/SMS, no frontend change, no scheduler change.

## Testing

- **Structural validator** (`validate-task-meeting-notification-events.sql`): exactly the 3 approved event types registered (registry-driven, `uses_generic_notification_envelope = TRUE`); deferred candidates absent; closed target-type/source_record_type dispatch unchanged since Phase 1.4A; `create_notification_intent`/`resolve_notification_intent`/`process_platform_outbox_batch` completely unmodified (no event-type or module-specific branch); no new authorization adapter; each producer's own `functiondef` contains the real atomic enqueue call, the correct event-type literal, the correct target type(s), no direct `user_notifications` write, and free-text fields excluded from the enqueue call's own payload construction; legacy dual-write preserved; `update_meeting()`'s new enqueue correctly gated by the same three conditions (`p_suppress_notification`, `v_time_changed`, `NOT v_publishing`); no external-delivery/preferences objects; CAP-003 1.0B–1.4A and CAP-002 baseline objects present.
- **Behavioral** (25 scenarios): valid mutation → correct outbox event(s)/target descriptor(s)/safe payload for each of the three events; end-to-end delivery via the real worker; self-exclusion (`task.completed.v1` owner event skipped when creator=actor); late authorization revalidation (watcher removed before processing); idempotent replay; legacy dual-write preserved; legitimate repeat completion produces its own fresh occurrence; nonexistent-task/meeting hard-FK rejection at creation time; title-only edit does NOT fire `meetings.rescheduled.v1`; draft-publish-with-time does NOT fire it either; `p_suppress_notification` suppresses both new events exactly like the legacy ones; cross-organization meeting participant still resolves and is authorized; removed-before-cancellation participant receives nothing; `task.assigned.v1` (Phase 1.4) still works unchanged; a deliberately mismatched task-sourced/meeting-targeted intent fails closed at resolution; no sensitive fields ever reach `notification_intents`; worker genericity proven via the real entry point draining both a task- and a meeting-sourced event; deferred candidates confirmed genuinely absent from the registry and fail deterministically if force-enqueued; pre-existing target kinds unaffected.
- **RLS** (10 scenarios): no direct authenticated `INSERT` into `platform_outbox_events`/`create_notification_intent`/worker invocation for any of the three new event types; `user_notifications` remain strictly recipient-scoped (positive and negative controls); Task/Meeting RLS (`can_view_task`/`can_view_meeting`) unaffected; `platform_event_type_registry` remains admin-write-only despite 3 new rows added via migration; no new write path opened to the legacy `notifications` table.
- **Concurrency** (8 scenarios, genuine `dblink` multi-session): two workers racing the same real `task.completed.v1`/`meetings.cancelled.v1` event resolve exactly once each; two concurrent `complete_task()` calls on the same task (documenting both legitimate serial outcomes, since re-completion is pre-existing allowed behavior); a `meeting_participants` membership removal racing the worker's own resolution of a real `meetings.rescheduled.v1` event (documenting both legitimate serial outcomes per docs/78 §7.2); duplicate `cancel_meeting()` replay rejected by the pre-existing status guard before reaching the new enqueue; unrelated Task/Meeting mutations proceed independently; no deadlock; idempotency-key uniqueness holds under a forced retry.
- **Performance** (6 dimensions, 20,000 historical Tasks / 10,000 historical Meetings / 100,000 background outbox rows): `complete_task()`/`update_meeting()`/`cancel_meeting()` atomic-enqueue overhead at scale (100 calls each, well under 10s); idempotency-key uniqueness lookup index-backed (`EXPLAIN ANALYZE BUFFERS`-verified, no sequential scan against 100,000+ rows); draining 250+ real Phase 1.4B events via the unmodified worker (well under 30s); `task_watchers` resolution remains index-backed. No speculative index added — every access path already had an adequate existing index.

## Rollback

`rollback-task-meeting-notification-events.sql` restores `complete_task()`, `update_meeting()`, and `cancel_meeting()` to their **exact, byte-for-byte** pre-1.4B bodies (copied directly from the true latest pre-1.4B source patches, confirmed by direct file inspection before any code was written), removes the 3 event-type registry rows this milestone added, and refuses (raises, never silently discards data) if any `platform_outbox_events` or `user_notifications` row still uses one of the three new event types. `validate-task-meeting-notification-events-rollback.sql` verifies all of the above plus that every Phase 1.4/1.4A object (`task.assigned.v1`, `task_watchers`, `meeting_participants`, both authorization adapters, the closed target-type dispatch) remains completely unaffected.

## Harness notes (§9)

This milestone required extending the disposable local test harness considerably beyond what Phases 1.0–1.4A needed, because `complete_task()`/`update_meeting()`/`cancel_meeting()` had each been redefined multiple times by real, already-shipped production patches (Meetings extensions: rsvp, attendance, minutes, lock, personal-notes, groups, recurring, drafts, recurring-phase2-notification-suppression, recurring-phase2-preserve-series-membership; Task extensions: relationships, relationships-hardening, dependencies, dependency-lifecycle-enforcement, dependency-candidate-management) that the harness's prior, reduced patch-application loop never applied. Reconstructing this milestone's patch against the *foundation-only* bodies would have silently reverted several real, shipped corrections (the meeting-lock check, the `p_suppress_notification`/`p_preserve_series_membership` parameters, the dependency-lifecycle-aware `complete_task()`). The full, correctly chronologically-ordered patch chain was added to the harness instead (confirmed order via `git log --reverse` across every relevant file, not assumed), and this milestone's own patch was written directly against the resulting *true* latest bodies, verified live via `\df`/`pg_get_functiondef()` before writing a single line of the new patch.

Two harness-only findings surfaced during this reordering and were fixed in the harness scripts alone (never in any patch that ships to production, and never by weakening a real assertion):

1. `01-grants.sql`'s blanket `GRANT ... ON ALL TABLES` (a harness-only stand-in for "RLS, not table grants, is the real gate") was silently reopening `task_relationships`/`task_dependencies`/`task_dependency_waivers`' own narrower, patch-established grants (`REVOKE ALL ... GRANT SELECT ONLY`), since it runs after every patch. Fixed by extending the harness's own existing "re-lock workflow_ tables" pattern to also re-lock these two tables to the exact posture their own patches already establish.
2. A pre-existing dblink-based Task test (`test-task-dependency-lifecycle-concurrency.sql`) hard-deletes its fixture users at teardown; `complete_task()`/`assign_task()` now legitimately leave `platform_outbox_events`/`user_notifications` evidence referencing those users (by design — immutable business evidence, never auto-deleted in production). The test's own cleanup section gained the same evidence-table `DELETE`s already present for every other evidence table it clears, matching its own established pattern.

Two Task-module validators/tests were excluded from this milestone's own regression sweep, not because Phase 1.4B broke them, but because they assert the presence of the *full* Requests/Entry/Internal-Collaboration/Prisoner-Letters/Meetings task-link integration surface (`task_links`, `attachments`, `list_task_request_links`/`list_task_meeting_links`/`list_task_internal_collaboration_links`/`list_task_entry_links`/`list_task_prisoner_letter_links`) — confirmed by direct inspection that these assertions reference functions from patches entirely unrelated to and untouched by CAP-003, belonging to modules the governing instruction explicitly keeps deferred. Importing those patch chains to satisfy an unrelated module's own completeness check would be scope creep well beyond notification-event integration. `validate-task-dependencies.sql` and `test-task-dependency-candidate-management.sql`/`-performance.sql` are the two affected files; every other Task/Meeting validator and behavioral suite this milestone could reasonably include was run and passes.

One pre-existing, unrelated flaky concurrency test (`test-workflow-sla-timer-dispatch-concurrency.sql`, Phase 5.4, CAP-002) was separately confirmed in an earlier phase of this project to be a timing-sensitive test under full-sweep system load, unrelated to any CAP-003 change — noted here only for continuity, not re-investigated in this milestone since nothing in this milestone touches SLA/workflow code.

## Limitations

- Only three events, from two modules (Tasks, Meetings), are wired. `task.review_requested.v1`, `task.returned.v1`, and `meetings.scheduled.v1` remain deferred with documented, specific blockers (missing RPC, or inconsistent existing business-policy evidence) — none of these blockers were worked around.
- The `task_watchers`/`meeting_participants` target kinds have no actor-self-exclusion mechanism at the resolution layer; the acting user, if also a watcher/participant, receives a notification about their own action (documented above, not a security issue).
- Requests, Entry, Internal Collaboration, and Prisoner Letters remain deferred until server-authoritative mutation RPCs exist for those modules (unchanged from Phase 1.4's own finding).
- CAP-003 Phase 1.5 (Realtime/UI + legacy cutover) has not started.
- No frontend/UI changes, no external delivery (email/push/SMS), no notification preferences — all explicitly out of scope, matching every prior CAP-003 phase.
