# CAP-003 Phase 1.4A — Task Watcher & Meeting Participant Target Expansion

## Status

Implemented and locally verified against a disposable PostgreSQL harness (full CAP-002 + CAP-003 1.0A/1.0B/1.1/1.2/1.3/1.3A/1.4 migration chain applied). Not yet pushed — pending a separate push-approval checkpoint.

## Reason for this milestone

CAP-003 Phase 1.4 established the first real module integration (`task.assigned.v1`). During its own module inventory, two of docs/82's eight deferred target-descriptor kinds — `task_watchers` and `meeting_participants` — were identified as blocking further Tasks/Meetings integration (`task.completed`, and every natural Meetings event) purely because Phase 1.2 never implemented those two target kinds, not because of any deeper architecture gap. This milestone closes exactly those two gaps at the recipient-resolution layer. It adds **no new domain event** — `task.assigned.v1` remains the only Phase 1.4 pilot producer.

## Repository evidence (inspected directly, not from memory)

Phase 1.4 already caught one stale-memory function reconstruction; every claim below was verified against the live schema/functions before implementation, not assumed.

### Task watcher model

`task_watchers` (`patch-shared-task-foundation.sql`): `id`, `task_id`, `user_id`, `created_at`, `UNIQUE(task_id, user_id)`. **No `is_active`/revoked flag at all** — `watch_task()` uses `INSERT ... ON CONFLICT DO NOTHING`, `unwatch_task()` uses a hard `DELETE`. Row existence *is* the "currently watching" state. `can_view_task()` already includes an active-watcher `EXISTS` branch, so Phase 1.4's existing `intent_user_can_view_task()` adapter already authorizes watchers correctly with **zero changes** — `task_watchers`-targeted intents reuse `source_record_type = 'task'` as-is; no new source-authorization branch was needed for the target kind itself.

### Meeting participant model

`meeting_participants` (`patch-meetings-foundation.sql`): `id`, `meeting_id`, `user_id` (nullable), `external_name`/`external_email`/`external_phone`/`external_organization_name` (nullable, mutually exclusive with `user_id` via `meeting_participants_identity_check`), `participant_role`, `invitation_status`, `attendance_status`, `is_organizer`, `removed_at`/`removed_by`/`removal_reason` (soft-delete — "currently a participant" = `removed_at IS NULL`). The already-shipped `meeting_participant_recipient_ids(meeting_id, exclude)` helper already implements exactly the correct resolution query (`DISTINCT`, `user_id IS NOT NULL`, `removed_at IS NULL`) — **reused directly, never duplicated**.

**Supported participant form: direct internal user participants only.** There is no section/org-level participant type in this data model at all — no `scope_type`/`scope_id` or equivalent column exists on `meeting_participants`. This is not an ambiguous form left unimplemented; it structurally does not exist in this codebase's meeting model, confirmed directly against the live schema (behavioral scenario 17 asserts this negatively).

**Unsupported form: external/non-user participants** (`user_id IS NULL`). These are structurally excluded by `meeting_participant_recipient_ids()` itself — never resolve to a candidate, never create a fake `user_notifications` row for a non-CorLink identity (behavioral scenario 18).

Meetings are explicitly cross-organization capable (a participant's `org_id` is never checked by `can_view_meeting()`'s participant branch), so a legitimate cross-org participant does receive notifications — CAP-003 does not impose a same-org restriction the source module was never given (RLS scenario 9).

## Descriptor shapes

Two new nullable target-identifier columns on `notification_intents`, following the exact one-column-per-target-kind convention Phase 1.2 already established:

```
target_task_id    UUID REFERENCES tasks(id)
target_meeting_id UUID REFERENCES meetings(id)
```

```json
{ "target_type": "task_watchers", "target_task_id": "<uuid>" }
{ "target_type": "meeting_participants", "target_meeting_id": "<uuid>" }
```

Both columns have a hard foreign key, matching the exact precedent Phase 1.2 already set for `target_workflow_instance_id`/`target_work_item_id` — a target referencing a nonexistent task/meeting is rejected deterministically at **creation** time (a foreign-key violation), never silently accepted and later resolving to zero candidates at processing time (behavioral scenarios 3, 13).

The target-shape `CHECK` constraint requires exactly its own identifier column populated and every other target_* column `NULL`, identical discipline to every existing branch — a `task_watchers` target cannot carry `target_meeting_id` and vice versa (behavioral scenarios 21, 22).

## Resolution semantics

- **`task_watchers`**: `SELECT array_agg(DISTINCT user_id) FROM task_watchers WHERE task_id = target_task_id` — current row existence at processing time.
- **`meeting_participants`**: `meeting_participant_recipient_ids(target_meeting_id, NULL)` — the already-shipped helper, reused verbatim.

Both are resolved **at worker/resolver processing time, not at enqueue time** (docs/78 §7.2) — the descriptor stores only the source object's id, never a pre-resolved recipient snapshot.

## Late-membership semantics (verified against docs/78 §7.2 before implementing)

- A watcher/participant removed *before* resolution runs is excluded (behavioral scenarios 5, 15).
- A watcher/participant added *after* intent creation but *before* resolution *is* included (behavioral scenarios 6, 16) — current membership at processing time is the correct, deliberate semantic, exactly matching docs/78 §7.2's own "never a pre-resolved snapshot" language.
- Under genuine concurrent races (a membership change landing concurrently with resolution), `resolve_notification_intent()` takes no lock on `task_watchers`/`meeting_participants` themselves (only on the intent row) — both serial orderings (included or excluded) are legitimate outcomes depending on true statement ordering; the non-negotiable invariant is that `resolved_count` always exactly matches the durable `user_notifications` row count, never a torn state (concurrency scenarios 2, 3, 5, 6).

## Late authorization revalidation

- `task_watchers` candidates are revalidated via the **existing** Phase 1.4 `intent_user_can_view_task()` adapter (its watcher-membership branch already covers this case) — `source_record_type` stays `'task'`.
- `meeting_participants` candidates are revalidated via the **new** `intent_user_can_view_meeting(p_meeting_id, p_user)` adapter — a candidate-generalized mirror of `can_view_meeting()`, the same generalization pattern Phase 1.2/1.4 already used twice (`workflow_instance`, `task`). `source_record_type` gains exactly one new value, `'meeting'`.

Target resolution and source authorization are independently enforced — a candidate resolved via a task/meeting's own membership is still correctly denied if the intent's `source_record_id` references a *different* task/meeting than the one that resolved them (behavioral scenarios 8, 19) — proof that "resolved by target" is never itself treated as authorization.

## Cross-organization behavior

Meetings' own architecture is explicitly cross-org capable; this milestone does not add an organization-match requirement `can_view_meeting()` never had. Task watchers follow the task's own organization/visibility rules unchanged (via the existing `intent_user_can_view_task()` adapter, which does enforce organization match).

## Confidentiality

`notification_intents` gained no business-content column — no task description/comments, no meeting notes/agenda, no attachment data. Target descriptors are bare structural identifiers (`target_task_id`/`target_meeting_id`, plain UUIDs) only. The pre-existing 4KB `template_params` bound is unchanged and still enforced (behavioral scenario 24).

## Idempotency

Both new target kinds inherit Phase 1.1/1.2's existing dedup: `notification_intents_dedup_unique UNIQUE(outbox_event_id, target_type, target_key)` at the intent level, and `user_notifications`' own `UNIQUE(outbox_event_id, recipient_user_id)` at the notification level. Replaying `resolve_notification_intent()` on an already-resolved intent is a safe idempotent no-op — proven for both target kinds up to 3x replay in the behavioral suite and confirmed at 10,000-recipient scale in performance dimension 5 (sub-millisecond, proving the early-return-on-non-pending path, not a re-walk).

## Concurrency

8 scenarios, genuine `dblink` multi-session: two concurrent resolutions of the same intent (either target kind) converge to identical status and exactly one durable notification; membership-change races (removal/addition, either target kind) always produce one of the two legitimate serial outcomes with zero torn state; unrelated Task and Meeting resolutions progress independently with no shared lock; no deadlocks across any scenario.

## Performance

Measured at 12,000 `task_watchers` rows (one 10,000-watcher task) and 13,500 `meeting_participants` rows (one 10,000-participant meeting plus 1,500 external rows mixed in): end-to-end resolution of a 10,000-recipient target completes in under 2 seconds for either kind; the real `process_platform_outbox_batch()` worker entry point drains both 10,000-recipient events in under the bound; replay of an already-resolved 10,000-recipient intent completes in under 1ms.

## Indexes

No new index was added. `EXPLAIN (ANALYZE, BUFFERS)` confirms the existing `idx_task_watchers_task` and `idx_meeting_participants_meeting` indexes (both already shipped by their respective foundation patches) are used for realistic, low-selectivity lookups. The one deliberately-high-fanout meeting fixture (≈85% of its own table) correctly triggers a sequential scan by planner choice — the genuinely faster plan at that selectivity, not a missing-index defect — confirmed directly rather than assumed, and not "fixed" with a speculative index per the governing instruction's own explicit constraint.

## Worker genericity

`process_platform_outbox_batch()`'s only change is passing two more `NULLIF(...)::UUID` payload extractions to `create_notification_intent()`, following the exact same generic-passthrough pattern already used for every other target field — no `IF target_type = 'task_watchers'` or `IF module = 'meetings'` branch exists anywhere in the worker (structural validator asserts this negatively; behavioral scenario 25 proves both new target kinds process correctly through the real, unbranched worker entry point).

## Rollback

`rollback-notification-target-expansion.sql` restores `create_notification_intent()`, `resolve_notification_intent()`, and `process_platform_outbox_batch()` to their **exact, byte-for-byte pre-1.4A bodies** — spliced in verbatim from `pg_get_functiondef()` captures taken *before* this milestone's patch was written (not reconstructed from memory), verified via direct diff equality against those captures. Restores all three CHECK constraints to their exact pre-1.4A forms, drops `intent_user_can_view_meeting()`, and drops both new columns entirely. Refuses (raises, never silently discards data) if any `notification_intents` row still uses either new target kind at rollback time. The patch reapplies cleanly afterward with the structural validator passing again.

## Testing

- **Structural validator**: exactly the two new target kinds present with correct shape validation; source dispatch extended by exactly `meeting`; `intent_user_can_view_meeting()` present and locked down (no grant to any role); worker remains generic (no target/module-specific branch, textual scan); no new domain event registered; `task.assigned.v1` remains the sole pilot; Task/Meeting lifecycle RPCs unmodified; CAP-003 1.0B–1.4 and CAP-002 baselines unaffected; Phase 1.5 not started.
- **Behavioral** (25 scenarios): descriptor validation (valid/malformed/nonexistent-FK-rejected) for both kinds; current/removed/newly-added membership semantics for both kinds; deduplication; source/target mismatch denial for both kinds; replay idempotency for both kinds; existing six target kinds unaffected; the "no section/org participant type exists" and "external participant structurally excluded" assertions; cross-target-type descriptor rejection both directions; source-authorization-remains-mandatory; no sensitive payload; real-worker-processes-both-kinds-without-branching.
- **RLS** (10 scenarios): no direct `notification_intents` INSERT/UPDATE by ordinary users (including the RLS-enabled-zero-policy "affects zero rows" denial shape for UPDATE/SELECT, not just exceptions); no direct invocation of `intent_user_can_view_meeting()`/`create_notification_intent()`/the worker; recipient-scoped `user_notifications` reads end to end for both kinds; Task/Meeting RLS not broadened; legitimate cross-org meeting participant does receive notifications; anonymous access denied throughout.
- **Concurrency** (8 scenarios, genuine `dblink`): see Concurrency section above.
- **Performance** (6 dimensions): see Performance section above.

## Limitations

- Only the recipient-resolution **capability** is added. No new domain event was integrated — `task.completed`, `task.review_requested`, `task.returned`, and every Meetings event (`meetings.scheduled`, `meetings.rescheduled`, `meetings.cancelled`) all remain unintegrated; a future milestone would need to add its own real event producer (mirroring exactly how Phase 1.4 wired `task.assigned.v1` through `assign_task()`).
- Requests, Entry/External Correspondence, Internal Collaboration, and Prisoner Letters remain deferred — still no server-side mutation RPC exists for any of them, unchanged by this milestone.
- No section/org-level meeting participant target exists because the underlying data model has no such concept — not a deferred ambiguity, a structural non-existence.
- No Realtime cutover, no legacy-table migration, no notification preferences, no email/push/SMS, no frontend changes, no scheduler/cron deployment.
- CAP-003 Phase 1.5 has not started.

## Next integration possibilities (not implemented here)

A future milestone could now wire `complete_task()` to atomically enqueue a `task.completed.v1` event targeting `task_watchers` (recipients: creator + watchers, per `patch-task-dependency-lifecycle-enforcement.sql`'s own existing legacy fan-out logic), or wire `cancel_meeting()`/`create_meeting()` to atomically enqueue a `meetings.*.v1` event targeting `meeting_participants` — both now have a real, tested target-resolution capability to build on, following exactly the same atomic-enqueue-inside-the-real-mutation-RPC pattern Phase 1.4 established for `assign_task()`.
