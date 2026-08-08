# CAP-003 Phase 1.1 — Notification Outbox & Durable Notification Persistence Foundation

## Status

This is CAP-003's first implementation milestone, per docs/78 §25's own phasing. It implements
**only** the inert persistence foundation: schema, RLS, immutability, two internal/service-only
creation primitives, and two authenticated-facing read APIs. No worker, no recipient
resolution, no module integration, no legacy cutover. Follows docs/78 without redesigning it;
no architecture defect or missing contract was found during implementation (§"Deviations"
below records the one clarification this milestone had to make on its own).

## Scope

Implements docs/78 §25's Phase 1.1 line item exactly: "Transactional outbox table + durable
`user_notifications` table (schema, RLS, immutability triggers on business-fact columns, no
worker yet, no recipient resolution yet — inert persistence foundation, mirroring CAP-002
Phase 5.1's own 'inert foundation' precedent)." The legacy `notifications` table (docs/79,
docs/80) is completely untouched — this milestone is purely additive, verified structurally
and behaviorally (test scenario 20, and the RLS suite's own scenario 10).

## Tables

Three new tables, all `IF NOT EXISTS`, all under standard RLS:

- **`platform_event_type_registry`** — admin-managed reference data (docs/78 §5.4):
  `event_type` (versioned, primary key), `owning_module`, `is_mandatory`,
  `requires_acknowledgement`, `description`. No rows are seeded by this patch — registering
  real business event types is each future module integration's own concern.
- **`platform_outbox_events`** — modeled directly on `workflow_events`' proven shape (docs/78
  §2.5/§5.1), never on `notifications`/`audit_logs`'s closed-enum anti-pattern. See "Event
  envelope" and "Outbox immutability" below for its column split.
- **`user_notifications`** — the durable, recipient-facing row (docs/78 §9). See "Notification
  persistence" and "Notification state" below.

## Event envelope

Both `platform_outbox_events.event_type` and `user_notifications.notification_type` use the
identical open, versioned pattern docs/78 §5.4 specifies:
`^[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+\.v[1-9][0-9]*$` (`<module>.<event_name>.v<version>`) — never
a closed `IN`-list. Adding a new event type requires zero schema migration. Identity/traceability
fields (`source_module`, `source_record_type`, `source_record_id`, `organization_id`,
`actor_id`, `correlation_id`, `causation_id`, `occurred_at` vs. `created_at`) match docs/78 §5.5
exactly.

## Outbox immutability

Business/evidence columns (`event_type`, `source_*`, `organization_id`, `actor_id`,
`correlation_id`, `causation_id`, `occurred_at`, `created_at`, `payload`, `idempotency_key`) are
write-once, enforced by a `BEFORE UPDATE` trigger comparing `NEW`/`OLD` column-by-column and
rejecting any change to them. Mutable processing-state columns (`status`, `claimed_by`,
`claimed_at`, `attempt_count`, `next_attempt_at`, `last_error`, `processed_at`) exist per
docs/78 §5.6/§5.8 but are **not yet used by anything** — no worker exists in this milestone
(§25 Phase 1.3). They're present now so that phase needs no schema migration of its own, exactly
matching this milestone's "inert foundation" mandate. Unlike `workflow_events` (fully
append-only, a single "reject every UPDATE" trigger), this table has legitimately mutable
columns, so a column-diff trigger was required rather than reusing `workflow_events`'
`workflow_reject_immutable_mutation()` pattern verbatim.

## Notification persistence

`user_notifications` carries every column docs/78 §9 specifies: `recipient_user_id`,
`organization_id`, `notification_type`, `title_template_key`, `template_params`, `source_*`,
`outbox_event_id` (traceability, `NOT NULL` — every notification must originate from a real
outbox event), `priority`, `deep_link_module`/`deep_link_params`, `created_at`, `read_at`,
`acknowledged_at`, `archived_at`, `expires_at`. `template_params`/`payload` are both bounded
(`pg_column_size(...) <= 4096`/`8192` bytes respectively) and constrained to `jsonb_typeof = 'object'`
— safe display data only, never a raw array or scalar, never unbounded.

## Notification state

Business-fact columns are immutable by the same column-diff-trigger pattern as the outbox
table. `read_at`/`acknowledged_at`/`archived_at` are the only ever-mutable columns, and only by
the owning recipient (RLS `UPDATE` policy scoped to `recipient_user_id = auth.uid()`).
`acknowledged_at` carries one extra rule straight from docs/78 §10: it may be set once (never
cleared, never re-set) and only for a `notification_type` the registry actually marks
`requires_acknowledgement` — enforced by the same trigger, not left to convention.

## RLS

- **`platform_outbox_events`**: RLS enabled, **zero policies** for `authenticated`/`anon` —
  operational infrastructure, never a user-facing record (docs/78 §17). `service_role`
  (`BYPASSRLS`) is the only role with real access.
- **`user_notifications`**: `SELECT`/`UPDATE` restricted to `recipient_user_id = auth.uid()`.
  **No `INSERT` policy, no `DELETE` policy** for `authenticated`/`anon` at all — creation is
  exclusively the `SECURITY DEFINER` path below, closing docs/78 §2.3's diagnosed gap
  structurally from this table's first day, not by policy refinement afterward.
- **`platform_event_type_registry`**: readable by any authenticated user (safe, non-sensitive
  config), writable only by `is_admin()` — mirrors `commands`/`departments`/`sections`'s own
  convention in `rls.sql`.

## Internal creation boundaries

Two `SECURITY DEFINER`, pinned-`search_path` primitives, both granted to `service_role` only
(revoked from `PUBLIC`/`anon`/`authenticated`) — identical posture to Phase 5.4's own
dispatcher entry point (docs/78 §2.5/§17):

- **`platform_enqueue_outbox_event(...)`** — validates required fields, organization/actor
  existence, then inserts with `ON CONFLICT (source_module, source_record_type,
  source_record_id, event_type, idempotency_key) DO NOTHING`, falling back to a lookup that
  returns the existing row's id for a genuine content-identical replay, or **raises a
  deterministic error** (`unique_violation`) if the same identity/idempotency key is reused
  with a *different* payload or `correlation_id` — a caller bug, never silently discarded or
  merged.
- **`platform_create_user_notification(...)`** — validates the recipient is a real active user
  and the outbox event exists, then inserts with `ON CONFLICT (outbox_event_id,
  recipient_user_id) DO NOTHING`, returning the existing id on a safe replay.

Neither is exposed to ordinary authenticated sessions: recipient resolution and authorization
revalidation (docs/78 §7–§8) don't exist yet, so a generally-callable creation RPC would have
no way to prove a given recipient is legitimately entitled to notice of a given record. A
future domain RPC (itself `SECURITY DEFINER`) calls these as a plain nested function call —
that needs no grant to `authenticated` at all, since the nested call executes under the calling
function's owner role, not the original session's.

## Idempotency and deduplication

Two independent `UNIQUE` constraints, exactly matching docs/78 §14:

1. **Enqueue-level**: `UNIQUE (source_module, source_record_type, source_record_id, event_type,
   idempotency_key)` on `platform_outbox_events`.
2. **Notification-level**: `UNIQUE (outbox_event_id, recipient_user_id)` on `user_notifications`.

Both are real database constraints (backing a real unique index each), not merely
pre-insert existence checks — verified directly under genuine concurrent load (concurrency
suite scenarios 1–2, two real `dblink` sessions racing the same insert).

## Pagination and unread count

`list_my_notifications(p_limit, p_before_created_at, p_before_id, p_unread_only)` — keyset
`(created_at, id)` cursor, never `OFFSET`, `LIMIT` clamped to `[1, 100]` regardless of caller
input — the identical shape `list_workflow_work_items` already established (Phase 5.1).
Verified stable under concurrent inserts directly (behavioral scenario 18: a row inserted
between page 1 and page 2 never leaks into the "older" continuation page, a guarantee
`OFFSET`-based pagination does not have). `count_my_unread_notifications()` is a simple,
RLS-scoped, index-backed count. Both are plain `SECURITY INVOKER` — RLS on `user_notifications`
already fully protects the underlying rows; these add no privilege of their own.

## Indexes

Exactly the shapes docs/78 §20 specifies:

- `idx_platform_outbox_events_pending` — partial, `(next_attempt_at) WHERE status = 'pending'`.
- `idx_platform_outbox_events_org_created`, `idx_platform_outbox_events_created_brin` (BRIN).
- `idx_user_notifications_recipient_read_created` — composite `(recipient_user_id, read_at,
  created_at DESC)`.
- `idx_user_notifications_recipient_unread` — partial, `(recipient_user_id, created_at DESC)
  WHERE read_at IS NULL`.
- `idx_user_notifications_created_brin` (BRIN).

## Performance (measured, 105,005 outbox rows / 1,005,002 notification rows)

All five dimensions use their intended index (verified via `EXPLAIN (ANALYZE, BUFFERS)`, zero
sequential scans on either table) and complete in low single-digit milliseconds or less:

| Dimension | Result |
|---|---|
| Pending outbox lookup (2,000 pending of 100,000) | 0.60 ms, `Index Scan` on `idx_platform_outbox_events_pending` |
| Newest-page list (heavy user, 5,000 total notifications) | 2.56 ms, `Bitmap Index Scan` on `idx_user_notifications_recipient_read_created` |
| Unread count (100 unread of 5,000) | 0.30 ms, `Bitmap Index Scan` on `idx_user_notifications_recipient_unread` |
| Mark-read (single row) | 0.73 ms |
| Idempotency dedup lookup | 0.22 ms, `Index Scan` on the `UNIQUE` constraint's own backing index |

## Testing

- **Structural validator**: hard-fails unless every requirement above is genuinely present —
  versioned envelopes (not closed enums), correlation/causation, both dedup constraints, both
  immutability triggers with the right protected-column set, `user_notifications`'
  recipient-scoped 2-policy RLS shape, outbox's zero-policy RLS shape, both creation primitives
  `SECURITY DEFINER`/pinned/`service_role`-only, the list API bounded and keyset, required
  indexes, **and** that no worker/retry/dead-letter/recipient-resolution/delivery-adapter/
  module-integration object exists yet. **PASSED.**
- **Behavioral suite** (20/20): enqueue, dedup, deterministic conflict rejection, ordinary-user
  and anon denial, notification creation + dedup, own/cross-user/cross-org read scoping,
  mark-read scoping, anon denial, direct INSERT/DELETE denial, safe-metadata CHECK
  enforcement, source-reference-grants-no-access, keyset stability under concurrent insert,
  accurate unread count, legacy behavior unaffected.
- **RLS suite** (10/10): own visible, same-org-unrelated hidden, cross-org hidden, direct
  INSERT denied, direct UPDATE of a business-fact column denied by the immutability trigger
  even though RLS itself would permit the row UPDATE, direct DELETE denied, outbox
  inaccessible to ordinary users, service path works, anon denied, legacy policies unchanged.
- **Concurrency suite** (5/5, real `dblink` sessions): duplicate outbox enqueue race, duplicate
  notification-creation race, concurrent mark-read race (no lost update), unrelated
  organizations progress independently, zero deadlocks.
- **Performance suite**: see table above.
- **Full regression sweep**: all CAP-002 phases, CAP-003 1.0A, and CAP-003 1.0B suites, plus
  this milestone's own four new suites — zero failures.

## Rollback

`rollback-notification-outbox-persistence-foundation.sql` drops every object this patch created
(both RPCs, both triggers and their functions, all three tables) in dependency order, no
`CASCADE`. It **refuses to run** if either `platform_outbox_events` or `user_notifications`
already contains any row — `DROP TABLE` would permanently destroy durable business evidence
(docs/78 §19/§21), and this rollback exists for exact-rollback verification of the still-empty
foundation, not as an operational "undo" once real data exists. Verified directly: the refusal
path (populated tables, real error, zero partial rollback — every Phase 1.1 object still
present and validator-passing afterward) and the clean path (empty tables, rollback succeeds,
`validate-...-rollback.sql` passes, 1.0A/1.0B/CAP-002 baselines all unaffected, this milestone's
own structural validator correctly fails afterward for the expected reasons, and the patch
reapplies cleanly with both the structural validator and behavioral suite passing again).

## Limitations

- **No worker.** `status`/`claimed_*`/`attempt_count`/`next_attempt_at`/`last_error`/
  `processed_at` exist but nothing writes to them yet — Phase 1.3.
- **No recipient resolution or authorization revalidation.** The target-descriptor vocabulary
  (docs/78 §7) and per-candidate revalidation (§8) don't exist — Phase 1.2. This is exactly
  why both creation primitives are `service_role`-only: there is no safe way yet to let an
  arbitrary authenticated caller supply an arbitrary recipient.
- **No module integration.** Nothing in Requests/Meetings/Tasks/Entry/Prisoner Letters calls
  `platform_enqueue_outbox_event` — verified directly by the structural validator's own
  textual scan of every existing module RPC body — Phase 1.4.
- **No Realtime cutover, no delivery-channel adapters, no legacy table migration or retirement.**
  The legacy `notifications` table keeps serving every existing module unchanged — Phase 1.5/2.
- **No retention/archival.** Explicitly deferred per the governing instruction; the schema does
  not use any FK design that would make future archival unsafe.

**Recipient resolution, worker processing, Realtime cutover, module integration, and external
delivery all remain deferred to their own later CAP-003 phases** — nothing in this milestone
begins any of them.

## Deviations / architecture clarifications

One implementation-level clarification was required that docs/78 leaves as an "implementation
phase decision, not fixed here" (§5.7/§13/§26 pattern): whether `source_record_id` on
`platform_outbox_events` is nullable, for a hypothetical future platform-wide event with no
single anchoring record. This milestone makes it `NOT NULL` — every real domain event has a
concrete source record, and a nullable `source_record_id` would silently defeat the
enqueue-level `UNIQUE` constraint (Postgres treats `NULL` as always-distinct in a unique index,
so two "duplicate" events sharing a `NULL` `source_record_id` would never actually conflict,
breaking the exact idempotency guarantee docs/78 §5.6 requires). This is an implementation
detail within docs/78's own stated discretion, not a deviation from anything docs/78 fixes
explicitly.
