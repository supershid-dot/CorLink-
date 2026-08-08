# CAP-003 Phase 1.4 — Notification Module Integration Foundation

## Status

Implemented and locally verified against a disposable PostgreSQL harness (full CAP-002 + CAP-003 1.0A/1.0B/1.1/1.2/1.3/1.3A migration chain applied). Not yet pushed — pending a separate push-approval checkpoint.

## Scope

The first real module producer wired atomically through the CAP-003 pipeline built in Phases 1.0–1.3: `assign_task()` (`patch-shared-task-foundation.sql`) now enqueues a `task.assigned.v1` platform outbox event in the same transaction as its `task_assignments` write, which the existing worker (`process_platform_outbox_batch()`) resolves into a real `user_notifications` row via the existing `create_notification_intent()`/`resolve_notification_intent()` pipeline.

This is a single, narrowly-justified pilot integration — not a general module-integration framework and not a legacy-notification cutover. The legacy `INSERT INTO notifications` call inside `assign_task()` is completely unchanged (dual-write during the transition period).

## Module inventory (full reasoning)

Every module was inspected for (a) a real server-authoritative mutation RPC atomic enqueue could hook into, and (b) whether its natural notification-worthy events fit Phase 1.2's six already-supported target-descriptor kinds.

| Module | Server-side mutation RPC? | Fits an existing target kind? | Outcome |
|---|---|---|---|
| Requests | No — `js/data/requests-api.js` does a direct `db.from('requests').insert(...)` | N/A | Deferred — no atomic enqueue path exists today |
| Entry / External Correspondence | No — `js/data/entry-api.js` does a direct `db.from('external_correspondence').insert(...)` | N/A | Deferred — same reason |
| Internal Collaboration | No — `js/data/internal-requests-api.js` does a direct `db.from('internal_requests').insert(...)` | N/A | Deferred — same reason |
| Prisoner Letters | No — `js/data/prisoner-letters-api.js` does a direct `db.from('prisoner_letters').insert(...)` | N/A | Deferred — same reason |
| Meetings | Yes — `create_meeting`, `cancel_meeting`, `reschedule_booking` (`patch-meetings-foundation.sql`) | No — every natural event fans out to the full participant set, requiring a `meeting_participants` target kind Phase 1.2 does not support (one of docs/82's eight explicitly deferred kinds) | Deferred — missing target contract, not a module-adapter gap |
| Tasks — `task.completed` | Yes — `complete_task` (`patch-task-dependency-lifecycle-enforcement.sql`) | No — recipients are `created_by` + `task_watchers`, requiring a `task_watchers` target kind (also one of the eight deferred kinds) | Deferred — same missing-target-contract reason |
| **Tasks — `task.assigned`** | **Yes — `assign_task`** | **Yes — single recipient, fits the already-supported `specific_users` kind** | **Implemented (this milestone)** |

`task.assigned` is the only event in this inventory that both (a) has a real atomic server-side mutation path and (b) needs no Phase 1.2 target-descriptor extension — the single pilot this milestone implements, per the governing instruction's "do NOT integrate every module in one milestone" directive.

CAP-002 workflow events were also confirmed to have zero production enqueue call sites today (`platform_enqueue_outbox_event` is called from nowhere in the real migration chain outside this milestone) — `workflow_instance` has been a supported `source_record_type` since Phase 1.2, but no CAP-002 code path actually uses it yet. Wiring a real CAP-002 producer is out of scope for this milestone and untouched.

## The one genuine extension: closed `source_record_type` dispatch

Phase 1.2's `create_notification_intent()`/`resolve_notification_intent()` reject every `source_record_type` except `'workflow_instance'` and `'platform'` — and Phase 1.2's own header comment names this closed set as deliberately narrow "for this milestone," explicitly deferring Requests/Entry/Internal Collaboration/Prisoner Letters/Tasks/Meetings to "Phase 1.4's own module adapters." Extending it with `'task'` is therefore not a redesign of Phase 1.2's architecture but the literal, explicitly-anticipated next step it named — confirmed by direct inspection of `patch-notification-recipient-resolution.sql`'s own comments before any code was written for this milestone.

The extension is narrow and structural (one more allowed literal in a `CASE`/`IN`-list, never dynamic SQL) and is backed by `intent_user_can_view_task(p_task_id, p_user)`, a candidate-generalized mirror of the existing `can_view_task()` RLS helper (`patch-shared-task-foundation.sql`) — exactly the same generalization pattern Phase 1.2 itself used to derive `intent_user_can_view_workflow_instance()` from `can_view_workflow_instance()`. Every branch reuses `tasks`/`task_assignments`/`task_watchers`/`user_assignments`/`scope_section_ids()` directly; no parallel permission system is invented.

The table-level `notification_intents_source_record_type_check` CHECK constraint was widened from `('workflow_instance', 'platform')` to `('workflow_instance', 'platform', 'task')` alongside the two dispatch functions.

## Generic event→intent mapping, not a worker branch

The governing instruction is explicit: "Do not modify `process_platform_outbox_batch` with module-specific branches if a generic event→intent mapping layer can handle it." Phase 1.3's worker hardcoded a single literal event_type string (`'platform.generic_notification_request.v1'`) as the only "generic-envelope-shaped" event it would process. This migration replaces that hardcoded literal with a registry-driven boolean column, `platform_event_type_registry.uses_generic_notification_envelope` — any event_type whose registry row is flagged `TRUE` is processed via the exact same generic `create_notification_intent()`-parameter-passthrough path, regardless of which module owns it. This is data-driven configuration, not a new code branch per module: `task.assigned.v1` is simply the second registry row ever flagged this way; a future module's event_type needs only its own registry row, no worker code change (proven directly by behavioral scenario 19, which registers a brand-new synthetic event_type and shows the unmodified worker processes it).

Every other property of `process_platform_outbox_batch()` — bounded batch claiming (`FOR UPDATE SKIP LOCKED`), the `[1,200]` hard clamp, deterministic exponential backoff, the five-attempt dead-letter threshold, per-item exception isolation, the `processed`/`processed_zero_recipients`/`retry_scheduled`/`dead_lettered`/`failed_before_claim` outcome vocabulary — is byte-for-byte unchanged from Phase 1.3.

## Notification authorization stays owned by CAP-003

`assign_task()`'s own pre-existing authorization (who may assign whom to what task) is completely unchanged and untouched by this patch. The new outbox enqueue call merely records that a `task.assigned.v1` event occurred; CAP-003's own `resolve_notification_intent()` late revalidation (via `intent_user_can_view_task()`) remains the sole, final authority over whether the assignee actually receives a notification. Behavioral scenario 17 proves this concretely: revoking the assignee's `task_assignments.is_active` row between enqueue and worker processing means the candidate receives nothing, even though `assign_task()`'s own authorization succeeded at enqueue time — authorization is genuinely revalidated late (docs/78 §8), never cached from an enqueue-time snapshot.

## Atomicity

`assign_task()` calls `platform_enqueue_outbox_event()` in the exact same transaction as its `task_assignments` INSERT, after the same authorization/validation checks that already gated the domain mutation. The idempotency key is the newly-created `task_assignments.id` itself — deterministic and unique per genuine assignment event, since `task_assignments`' own `ON CONFLICT (task_id, user_id) WHERE is_active DO NOTHING` plus early `RETURN` already guarantee this code path is reached at most once per real assignment. Concurrency scenario 1 proves two genuinely concurrent sessions racing to assign the same (task, user) pair produce exactly one active assignment row and exactly one outbox event.

## What this migration does NOT do

- No Requests/Entry/Internal Collaboration/Prisoner Letters/Meetings integration (all deferred, with reasons documented above).
- No `task.completed` event (blocked on the `task_watchers` target-kind gap — a Phase 1.2 target-descriptor extension, not a module adapter; out of scope for a module-adapter milestone).
- No removal of `assign_task()`'s existing legacy `INSERT INTO notifications` call (dual-write continues; legacy cutover is explicitly out of scope).
- No change to `process_platform_outbox_batch()`'s retry/dead-letter state machine, batch-claiming, or backoff logic — only its dispatch-eligibility check became registry-driven.
- No new target-descriptor kind.
- No CAP-002 workflow event producer wired (confirmed zero production call sites exist for `platform_enqueue_outbox_event` with `source_record_type='workflow_instance'` today).

## Testing

- **Structural validator** (`validate-notification-module-integration-foundation.sql`): registry column/flag presence, `task.assigned.v1` registration, `process_platform_outbox_batch()` registry-driven (no hardcoded literal, no leaked module-specific branch), `intent_user_can_view_task()` present and locked down (no grant to any role), closed dispatch extended by exactly one literal, `assign_task()` atomically enqueues alongside its unmodified legacy dual-write, every CAP-003 1.0B–1.3A and CAP-002 baseline object present and unaffected.
- **Behavioral** (20 scenarios): atomic enqueue correctness and payload shape; idempotent re-assignment (no duplicate event); `platform_enqueue_outbox_event`'s own idempotency-key dedup; registry-driven worker dispatch for a real module event; end-to-end notification creation; legacy dual-write preservation; `intent_user_can_view_task()`'s ten authorization branches (assignee, creator, completer, watcher, private-visibility denial, section-visibility grant/denial, supervisor-cascade, org-admin, super_admin, organization-visibility with cross-org denial), exercised only indirectly through the real `create_notification_intent`/`resolve_notification_intent` pipeline (never called directly — it is granted to no role, matching Phase 1.2's own `intent_user_can_view_workflow_instance()` posture); late (processing-time) authorization revalidation under a revoked assignment; the closed dispatch's continued rejection of an unsupported `source_record_type` (e.g. `meeting`); registry-driven genericity (a synthetic event_type processes with zero worker code changes); an unregistered event_type still fails deterministically through the shared retry/dead-letter machinery.
- **RLS** (9 scenarios): `intent_user_can_view_task()`/`process_platform_outbox_batch()`/`create_notification_intent()` remain unreachable to ordinary authenticated users; `assign_task()`'s own pre-existing authorization boundary is unchanged and gates the new enqueue too (no outbox event on a rejected caller); end-to-end read path via `list_my_notifications()` for the assignee only; `platform_event_type_registry` cannot be written by ordinary users; positive control confirming denials are real grant/RLS enforcement, not a broken harness; `assign_task()`'s pre-existing anon rejection (`auth.uid() IS NULL` check, not a REVOKE boundary) preserved byte-for-byte.
- **Concurrency** (4 scenarios, `dblink`-based genuine multi-session): two racing `assign_task()` calls for the same (task, user) produce exactly one assignment and one outbox event; a concurrent different-recipient assignment doesn't interfere; two workers racing to claim the same real `task.assigned.v1` event resolve exactly like Phase 1.3's own generic-envelope race; a concurrent `task_assignments` revocation racing `resolve_notification_intent()`'s row lock never produces a torn result.
- **Performance** (5 dimensions, 20,000-task / 2,000-user / 20-section scale): single-candidate task-sourced intent resolution (<500ms); `task_assignments` membership lookup uses its existing index (EXPLAIN-verified, no sequential scan); draining 1,000 real `task.assigned.v1` events across hard-capped 200-event batches (<15s); the registry-driven dispatch check uses the registry's primary key (EXPLAIN-verified); 500 `assign_task()` calls including the new atomic enqueue each (<10s).

## Rollback

`rollback-notification-module-integration-foundation.sql` restores `assign_task()`, `resolve_notification_intent()`, `create_notification_intent()`, and `process_platform_outbox_batch()` to their **exact, byte-for-byte** pre-1.4 bodies (verified via `pg_get_functiondef()` equality against a baseline built with the Phase 1.4 patch excluded from the loop — including every original comment, not just equivalent logic), restores the `notification_intents_source_record_type_check` constraint to exactly `('workflow_instance', 'platform')`, drops `intent_user_can_view_task()`, removes the `task.assigned.v1` registry row, and drops the `uses_generic_notification_envelope` column entirely. The constraint restoration refuses (raises, does not silently discard data) if any `notification_intents` row still has `source_record_type='task'` at rollback time. `validate-notification-module-integration-foundation-rollback.sql` verifies all of the above plus that every CAP-003 1.0B–1.3A and CAP-002 baseline object remains present.

## Limitations

- Only one event (`task.assigned`) from one module (Tasks) is wired. `task.completed`, Meetings, and the four direct-client-write modules all remain deferred with documented, specific blockers (missing target kind, or missing server-side mutation RPC) — none of these blockers were worked around.
- The `meeting_participants` and `task_watchers` target-descriptor kinds remain unimplemented; adding either is Phase 1.2-authorization-surface work, not a module adapter, and was explicitly left out of this milestone's scope per the governing instruction's "STOP for that module" directive for missing target contracts.
- No frontend/UI changes, no Realtime cutover, no legacy-table migration, no notification preferences, no email/push/SMS — all explicitly out of scope, matching every prior CAP-003 phase.
