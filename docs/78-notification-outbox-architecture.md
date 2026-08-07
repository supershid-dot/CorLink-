# CAP-003 Phase 1.0 — Shared Notification & Outbox Platform Architecture

## Document status

This is an architecture-only design. It contains no SQL, no migrations, no RPC signatures,
no table DDL, no Edge Functions, no worker implementation, no frontend code, and no
notification delivery of any kind. Nothing in this document changes CAP-002 (the Workflow
& Process Engine) or any other already-approved module. It follows the same
"architecture first, implementation later" discipline docs/60 and docs/73 established: a
complete, implementable design, traceable to repository evidence, that a future,
separately approved milestone would implement without inventing policy this document
should have settled.

## 1. Purpose

CorLink has no shared notification or asynchronous-processing infrastructure today. Every
module that needs to tell a user something either writes directly to one shared
`notifications` table from the browser, or — for one deadline sweep — from a
`pg_cron`-scheduled Postgres function. Nothing is transactional with the business mutation
it announces, nothing is idempotent, and every new event type requires widening the same
closed `CHECK` constraint (see §2).

CAP-003 defines **one platform service** — a transactional outbox plus a durable, versioned
notification model — that every future module (and, eventually, every existing module)
consumes through a single, narrow integration contract. Modules never invent their own
notification tables, delivery engines, retry mechanisms, recipient-resolution logic, or
preference systems. This mirrors exactly how CAP-002 became "a future shared execution
layer that modules may adopt incrementally" (docs/60) rather than a Workflow-specific
subsystem — CAP-003 is the same kind of platform capability, for a different concern.

## 2. Existing CorLink evidence

Repository inspection (full-text search across `supabase/`, `js/`, `docs/` for
notification/outbox/inbox/event/activity/alert/reminder/email/push/realtime/websocket/
broadcast/worker/queue/cron/scheduler/delivery/recipient/read_at/seen_at/acknowledged/
preference/subscription) found the following. **No outbox, queue, or message-broker
infrastructure exists anywhere in this codebase.** No file, table, or extension matching
"outbox," "queue," or "broker" exists. What does exist:

### 2.1 `notifications` (schema.sql:671) — the current in-app model

```
id, user_id, type TEXT CHECK (type IN (...30 literal values...)),
record_type TEXT, record_id UUID, message TEXT, is_read BOOLEAN, created_at
```

Eleven separate patches (`patch-cancel-request`, `patch-entry-module`,
`patch-meetings-foundation`, five `patch-meetings-recurring*` patches, `patch-meetings-rsvp`,
`patch-rooms-booking-foundation`, `patch-shared-task-foundation`) each `DROP CONSTRAINT` /
`ADD CONSTRAINT notifications_type_check` to widen the same closed enum every time a module
needed one more notification type. The current constraint (as of
`patch-shared-task-foundation.sql`) lists 30 literal type strings spanning Requests, Entry,
Prisoner Letters, Meetings, Rooms, and Tasks. **This is the exact anti-pattern CAP-003 must
not repeat**: every new event type today requires a schema migration touching a table five
unrelated modules already depend on.

`audit_logs` (schema.sql:649) has the identical shape and the identical problem —
`action TEXT CHECK (action IN (...))` and `record_type TEXT CHECK (record_type IN (...))`,
both closed enums modules widen as they're added. Two independent tables in this codebase
already show the same anti-pattern; CAP-003's event-type design (§5) must not become a
third.

### 2.2 `js/data/notifications-api.js` — client-orchestrated, best-effort writes

`NotificationsAPI.notify(userIds, {...})` is called from the browser **after** a module's
real mutation has already succeeded, and its own comment states the failure mode plainly:
*"a notification failing to insert (RLS hiccup, transient network error) should never break
the workflow action it's attached to, so this swallows its own errors rather than
throwing."* This is docs/60's own diagnosed weakness ("A business mutation can commit
before approval history, audit, or notification fails... Client-generated audit and
notification writes are easier to omit and are not naturally idempotent") *already
happening in production code*, not a hypothetical. Recipient resolution
(`section_user_ids()`, `org_supervisor_user_ids()`, both in `supabase/notifications.sql`)
is likewise driven from the client: the browser calls the RPC to get a user-id list, then
issues a second, unrelated `INSERT` — two separate round trips, no atomicity between them
or with the mutation that triggered them.

### 2.3 `notif_insert` RLS policy — a genuine existing gap

```sql
CREATE POLICY "notif_insert" ON notifications FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
```

Any authenticated user can insert a `notifications` row for **any** `user_id`, with
arbitrary free-text `message` content and an unvalidated `record_type`/`record_id` pair —
the policy checks only that the caller is logged in, never that `user_id = auth.uid()` or
that the caller has any relationship to the record being referenced. This is not
CAP-003-relevant scope creep to fix retroactively (this document changes nothing), but it
is a concrete lesson CAP-003's design must not repeat: §9 and §17 require that the new
durable notification table have **no direct client `INSERT` policy at all** — creation
happens exclusively through a server-side, `SECURITY DEFINER` path.

### 2.4 `check_deadlines()` / `pg_cron` — the one existing scheduled-worker precedent

`supabase/notifications.sql` installs `pg_cron` and schedules
`check_deadlines()` (`SECURITY DEFINER`, no `auth.uid()` dependency, scoped explicitly by
section/org id) to run daily at 03:00 UTC, flipping overdue Requests and inserting
`notifications` rows directly. This is the only existing "background worker" in CorLink and
confirms `pg_cron` is already enabled and available on this Supabase project — real,
usable infrastructure, not something CAP-003 needs to newly provision. It is also
architecturally naive in the way CAP-003 must not be: it loops over every un-notified
overdue row with no batching bound, no claim/lock discipline, and no retry state — safe
today only because Request volume is small.

### 2.5 `workflow_events` (CAP-002) — the correct existing precedent

CAP-002's own event ledger is the one place in this codebase that already gets event-type
extensibility right:

```sql
event_type TEXT NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_]{0,62}$'),
correlation_id UUID NOT NULL, causation_id UUID, idempotency_key UUID NOT NULL,
metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
CONSTRAINT workflow_events_sequence_unique UNIQUE (instance_id, event_sequence),
CONSTRAINT workflow_events_idempotency_unique UNIQUE (instance_id, idempotency_key)
```

An open, pattern-checked `TEXT` type (never a closed `IN`-list), `correlation_id`/
`causation_id` for cross-event traceability, a server-generated `idempotency_key`, and a
`JSONB metadata` column for safe, non-sensitive event detail — appended to, never widened
by `ALTER TABLE`. `idx_workflow_events_created_brin` (a BRIN index on `created_at`) is the
existing precedent for cheap indexing on a high-volume, time-ordered, append-only table.
CAP-003's outbox event contract (§5) is modeled directly on this shape rather than on
`notifications`/`audit_logs`.

CAP-002 Phase 5.4 (`process_workflow_sla_due_batch`, docs/77) is additionally the most
directly relevant *worker* precedent in this codebase: bounded per-category batch claiming
via `SELECT ... FOR UPDATE SKIP LOCKED`, business-state re-derivation under the lock (never
trusting the earlier non-locking candidate read), per-item failure isolation via a plpgsql
`BEGIN...EXCEPTION` block so one bad item never aborts the batch, a hard-clamped batch-size
ceiling independent of caller input, and a `service_role`-only execution grant with zero
grant to `authenticated`/`anon`. §13 and §17 adopt this pattern directly rather than
inventing a new one.

### 2.6 Realtime — already used, already correctly scoped as UX transport only

`js/views/shell.js` (`_subscribeRealtime`) opens one `postgres_changes` channel per session
on `notifications`, filtered to `user_id=eq.<self>`, `event: 'INSERT'` — and does nothing
with the payload except call `this.loadNotifications()`, which re-fetches from the table
via the normal authorized query. Realtime is not treated as a source of truth anywhere in
this codebase today; it is purely "something changed, go re-fetch." `js/views/request-detail.js`
uses the same `postgres_changes` mechanism for live-updating an open record's own detail
view (not notifications), with an explicit comment noting that an *unfiltered*
`postgres_changes` subscription "evaluates RLS for every write" — i.e., the existing code
is already aware Realtime's evaluation cost scales with total write volume, not just
matched rows, which matters for CAP-003's own Realtime design (§16).

### 2.7 Platform module and authorization model

`docs/04-platform-module-foundation.md` defines the two-layer module-access model
(`platform_modules`/`organization_modules` for org-level enablement, layered under the
existing role/scope checks) every CorLink module already uses. `supabase/rls.sql` defines
the organization/section/command/department scope hierarchy (`get_my_org_id()`,
`scope_section_ids()`, `my_section_ids()`, `is_admin()`, `is_supervisor_or_above()`,
`has_role()`) and the narrow, flat `is_prisoner_letters_staff()` confidentiality flag
(deliberately *not* tied to section/role, "since prisoner letters correspondence is a
narrow duty a specific staffer is assigned to, not a whole section's business"). CAP-003's
recipient-resolution and authorization-revalidation design (§7–§8) reuses these predicates
directly rather than inventing a parallel permission system, exactly as CAP-002 §2 and
Phase 5.3's authorization helpers already did.

`docs/03-migration-architecture.md` §2 records that a Telegram delivery channel was
evaluated once during the MeetFlow migration and explicitly deferred ("CorLink's existing
bell becomes the V1 delivery channel; Telegram integration is evaluated later as an
addition, not a replacement"). No SMS channel appears anywhere in the repository's history,
architecture documents, or product decisions. §12 treats Telegram as a previously-considered,
still-deferred future channel and does not add SMS to the initial architecture, per the
governing instruction.

### 2.8 Architecture-defect conclusion

Nothing found materially conflicts with a shared outbox/notification platform — the
opposite is true: the existing `notifications`/`audit_logs` closed-enum pattern and
client-orchestrated writes are exactly the fragmentation CAP-003 exists to replace, and
`workflow_events` plus the Phase 5.4 dispatcher are proof this codebase already knows how
to build the correct shape when a phase is allowed to do so properly. **No STOP condition
applies.** §24 defines a non-disruptive coexistence/migration path for the existing
`notifications` table rather than an immediate rip-and-replace.

## 3. Architectural principles

1. **One platform service, not a Workflow-specific subsystem.** Every module — including
   CAP-002 — is a *consumer* of CAP-003, never an owner of a competing implementation.
2. **Seven distinct concepts, never collapsed for convenience** (§4–§10): domain event,
   transactional outbox event, notification intent, recipient resolution, user notification,
   delivery attempt, user notification state. Two of these (notification intent, delivery
   attempt-as-persisted-row) are deliberately *not* separate tables in the phases this
   document scopes — see §6 and §12 for the reasoning; the concepts remain distinct even
   where their persistence is folded into a neighboring record.
3. **Atomicity with the domain transaction.** A domain mutation and its outbox enqueue
   commit together or not at all — never a second, unrelated client round trip (fixing
   §2.2's demonstrated failure mode).
4. **Reuse authorization, never duplicate it.** Recipient resolution and revalidation call
   the same predicates (`can_view_workflow_instance`, `is_prisoner_letters_staff()`, section
   scope helpers, module-specific RLS-equivalent checks) the source module's own RLS/RPCs
   already use. Notification targeting is never itself an authorization source.
5. **At-least-once processing, idempotent side effects.** Exactly-once is never claimed.
   Every write CAP-003 performs is safe to repeat.
6. **Fail closed, skip silently, never block the batch.** A recipient who fails
   authorization revalidation is skipped, not notified, and never aborts processing of
   other recipients or other events.
7. **Realtime is a signal, never the record.** The durable row is written first, inside the
   same transaction as its own creation logic; Realtime tells a connected client "go
   re-fetch," exactly matching §2.6's existing, correct usage.
8. **Business evidence and operational telemetry are separate retention classes** (§19).
9. **Bounded everything.** No unbounded worker scan/loop, no unlimited event log, no
   unindexed per-user query — mirroring CAP-002 Phase 5.4's own governing discipline.

## 4. Domain-event model

A **domain event** is a business fact ("Task 123 was assigned to user X") — a concept, not
necessarily its own persisted row. CorLink already has two shapes of domain-event source:

- **Modules with their own append-only event ledger** (CAP-002's `workflow_events` today;
  a future Case or Task event ledger conceivably later). For these, the domain event
  already exists as a durable fact independent of CAP-003; the outbox event (§5) *references*
  it (via `source_module`/`source_record_type`/`source_record_id` plus an optional
  `source_event_id`) rather than re-deriving or duplicating it.
- **Modules with only a mutable business row** (Requests, Meetings, Tasks, Entry, Internal
  Collaboration, Prisoner Letters today). For these, the domain event has no independent
  existence outside the mutation itself — the outbox event row *is* the durable record that
  the fact occurred, written atomically alongside the mutation.

CAP-003 does not require every module to grow its own event ledger before it can notify.
Requiring that would block every module except CAP-002 from participating and duplicates
effort CAP-002 already paid for. The outbox event is sufficient durable evidence of "this
happened" for modules that don't already have something stronger.

## 5. Transactional outbox

### 5.1 Where outbox records live

One shared, platform-owned table (working name `platform_outbox_events`), modeled directly
on `workflow_events`' proven shape (§2.5), not on `notifications`/`audit_logs`'s closed-enum
shape. Single physical table for all modules — partitioning by time is a scalability
tactic (§20), not a per-module table split, which would recreate the fragmentation CAP-003
exists to prevent.

### 5.2 How domain transactions enqueue atomically

Every domain module calls one shared, `SECURITY DEFINER`, platform-owned enqueue function
(working name `platform_enqueue_outbox_event(...)`) as the **last statement before COMMIT**
in its own existing RPC — the same discipline CAP-002's RPCs already use for writing their
own `workflow_events` row inside the same transaction as the business mutation. Modules
**never** `INSERT` into the outbox table directly (no direct `INSERT` grant to
`authenticated` at all, exactly as §2.3's lesson requires) and never perform the enqueue as
a second, separate client-side call. This closes §2.2's demonstrated gap by construction:
if the domain transaction rolls back, the enqueue rolls back with it; if it commits, the
outbox row exists.

### 5.3 Immutable payload requirements

`payload JSONB NOT NULL DEFAULT '{}'::JSONB`, written once at enqueue time, never updated
afterward (processing state lives in separate columns, §5.emphasis below). Payload contains
only what recipient resolution and safe notification rendering need: safe display strings,
references, and identifiers — **never** confidential business content (a Prisoner Letter's
body, a Request's substantive text). This mirrors `workflow_events.metadata`'s existing
"opaque subject identity and non-sensitive codes, not titles, correspondence bodies,
prisoner data" discipline (docs/60) applied to a new table.

### 5.4 Event type naming/versioning

`event_type TEXT NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+\.v[1-9][0-9]*$')`
— three dot-separated segments: `<module>.<event_name>.v<version>` (e.g.
`task.assigned.v1`, `workflow.sla_breached.v1`). Never a closed `IN`-list — adding
`meeting.rescheduled.v1` requires zero schema migration, exactly the property `notifications`/
`audit_logs` lack (§2.1) and `workflow_events` already has (§2.5). A breaking payload-shape
change ships as `.v2` of the same event name; old consumers keyed to `.v1` are unaffected
until deliberately retired — this is the "future event evolution without breaking old
consumers" requirement, satisfied structurally rather than by a registry service.

An **event-type registry** (a small, admin-managed reference table, not a code constant)
records, per `event_type`: the owning module, whether it is `is_mandatory` (§11), whether it
`requires_acknowledgement` (§10), and a human-readable description. This registry is what a
future preference layer reads to know which types can never be suppressed — it is
configuration data, not itself part of this architecture's runtime hot path.

### 5.5 Source and identity fields

`source_module TEXT`, `source_record_type TEXT`, `source_record_id UUID`,
`organization_id UUID NOT NULL` (owning organization — the same field every other
`workflow_*` runtime table already carries for scoping), `actor_id UUID` (nullable —
`NULL` for system/automatic events, exactly matching Phase 5.4's own `actor_id = NULL` /
`triggered_by = 'automatic'` convention for non-human-triggered facts), `correlation_id UUID
NOT NULL`, `causation_id UUID` (nullable — the event that caused this one, when known),
`occurred_at TIMESTAMPTZ NOT NULL` (business time — when the fact became true) distinct
from `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` (row time — when it was durably
recorded; these differ for automatic/batch-originated events).

### 5.6 Processing status, retry state, idempotency, deduplication

`status TEXT CHECK (status IN ('pending','claimed','processing','completed','failed','dead_letter'))`,
`claimed_by TEXT` (opaque worker/session identifier, operational only), `claimed_at
TIMESTAMPTZ`, `attempt_count INTEGER NOT NULL DEFAULT 0`, `next_attempt_at TIMESTAMPTZ`,
`last_error TEXT`, `idempotency_key UUID NOT NULL`. A module supplies (or the enqueue
helper derives) an `idempotency_key` unique per logical fact — `UNIQUE (source_module,
source_record_type, source_record_id, event_type, idempotency_key)` — so a domain RPC that
is itself retried (network hiccup, client resubmission) never enqueues the same outbox
event twice; a second enqueue with the same key is a safe no-op, mirroring every CAP-002
RPC's own idempotency-key replay discipline.

### 5.7 Concurrency claiming and bounded worker batches

`FOR UPDATE SKIP LOCKED` per-candidate claiming against a partial index on
`(status = 'pending' AND next_attempt_at <= now())`, ordered by `next_attempt_at` — the
identical pattern to `idx_workflow_sla_clocks_breach_due` (§2.5) and Phase 5.4's own claim
loop (§2.5). The worker-facing entry point accepts a `p_limit` clamped to an operational
`[1, N]` range regardless of caller input, exactly mirroring
`process_workflow_sla_due_batch`'s own hard ceiling (§5 of docs/77) — the exact numeric
bound is an implementation-phase operational constant, not fixed by this architecture (§26).

### 5.8 Terminal failure / dead-letter handling

Bounded `attempt_count` with exponential backoff (`next_attempt_at` pushed out on each
failed attempt); exceeding the bound transitions `status = 'dead_letter'` — the row is
**never deleted**. A dead-lettered event is administrator-visible and explicitly
re-playable (an operator action that resets `status = 'pending'`, `attempt_count = 0`,
itself an audited administrative act, not an automatic retry).

### 5.9 Retention/archive strategy

Outbox rows are **operational evidence**, not the compliance record (§19) — a `completed`
row's job is done once its downstream notification/evidence exists. A retention window
(operational default, exact duration an open decision, §26) governs pruning/archival of
`completed` rows; `dead_letter` rows are retained until explicitly resolved by an operator.

## 6. Notification-intent model

A **notification intent** is the decision "these recipients should learn about this event,"
produced by the outbox worker while processing one outbox event. This document deliberately
does **not** persist notification intent as its own table in the phases it scopes: the
outbox event row (event_type + payload, §5) already carries everything the intent
represents, and the resulting `user_notification` rows (§9) already carry the resolved,
per-recipient outcome. A third row recording the intent itself would duplicate information
already present at both ends without adding any new fact — exactly the "collapse for
convenience" the governing instruction warns against, inverted: adding a table here would
be complexity for no informational gain, not simplification. The concept remains
architecturally real (§7 processes it explicitly) even though it is not separately
persisted; a future phase may reconsider this if a genuine need for standalone intent
auditing (independent of both the outbox event and its resulting notifications) emerges.

## 7. Recipient targeting and resolution

### 7.1 Target descriptor vocabulary

A small, closed, versioned vocabulary of target *descriptors* (not resolved user-id lists)
travels in the outbox event's payload:

`specific_user(user_id)`, `specific_users(user_ids[])`, `section(section_id)`,
`section_leadership(section_id)`, `department_leadership(department_id)`,
`command_leadership(command_id)`, `org_role(org_id, role)`, `org_admins(org_id)`,
`workflow_participants(instance_id)`, `task_assignees(task_id)`, `task_watchers(task_id)`,
`meeting_participants(meeting_id)`, `record_owner(module, record_id)`,
`dynamic(resolver_key, resolver_args)` — an explicit escape hatch for a future module whose
recipient logic doesn't fit the fixed vocabulary, resolved by a module-registered function,
never by generic/arbitrary SQL the platform executes on the module's behalf.

### 7.2 Resolution timing

Descriptors are resolved **at worker processing time, not at enqueue time.** The payload
captures *what* to resolve (deterministic, replayable), never a pre-resolved user-id
snapshot. This is a deliberate choice: resolving early would bake in a set of recipients
that could include someone who lost their assignment/role between event creation and
processing, or exclude someone who gained it — late resolution against live
`user_assignments`/module state is the only way to keep recipients current without a second
invalidation mechanism.

### 7.3 What targeting must never do

Resolving a `section(section_id)` descriptor to a set of user ids is **never** itself an
authorization decision — it only produces candidates. Every candidate must independently
pass §8 before a `user_notification` row is ever created for them.

## 8. Authorization revalidation

Every resolved candidate is revalidated, at processing time, against the **source module's
own** visibility predicate — never a parallel notification-specific permission system. For
a workflow event, `can_view_workflow_instance(instance_id)`; for a Prisoner Letter event,
`is_prisoner_letters_staff()` combined with the same participant check
`rls.sql` already applies (§2.7); for a Task event, the existing task-visibility check
Tasks already enforce. A candidate who fails is recorded as `recipient_skipped` (telemetry,
§19) and receives nothing — silently, not as a batch failure. If a user is disabled
(`users.is_active = FALSE`) or their organization/module access is disabled
(`organization_modules.is_enabled = FALSE`) at resolution time, they fail revalidation the
same way and are skipped, addressing failure scenarios 4–6 (§22).

## 9. Durable in-app notifications

A new table (working name `user_notifications`) — this is the record a user actually sees,
distinct from the outbox event that produced it:

`id, recipient_user_id UUID NOT NULL, organization_id UUID NOT NULL, notification_type TEXT`
(same `<module>.<event>.v<n>` family as `event_type`, §5.4), `title_template_key TEXT`,
`template_params JSONB` (safe, non-confidential values only — parameters substituted into a
client-side or server-rendered template, never a pre-rendered sentence containing anything
the recipient couldn't already independently see through the source module's own
authorization), `source_module TEXT, source_record_type TEXT, source_record_id UUID,
outbox_event_id UUID` (traceability back to §5), `priority TEXT CHECK (priority IN
('low','normal','high','urgent'))`, `deep_link_module TEXT, deep_link_params JSONB` (a
module+params reference the frontend resolves into a route at render time — never a raw
baked-in URL, so route changes don't require rewriting historical notifications), `created_at
TIMESTAMPTZ NOT NULL DEFAULT NOW()`, `read_at TIMESTAMPTZ`, `acknowledged_at TIMESTAMPTZ`
(nullable; populated only for `notification_type`s the registry marks
`requires_acknowledgement`), `archived_at TIMESTAMPTZ`, `expires_at TIMESTAMPTZ` (nullable
— only for genuinely time-boxed notification types; most never expire).

Row creation happens exclusively through a `SECURITY DEFINER` worker path — **no direct
client `INSERT` grant at all**, closing §2.3's gap by construction rather than by policy
refinement.

Business-content parity with §5.3: `template_params` never carries confidential content the
recipient isn't independently authorized to see — deep-link navigation re-authorizes via
the source module's own RLS/RPC when the user actually opens the record, exactly as it does
today for every other CorLink detail view.

## 10. Notification state

- **Unread/read**: `read_at IS NULL` = unread. Set once, by the recipient only, via a
  server-side call scoped to `recipient_user_id = auth.uid()` — matching the one correct
  part of the existing `notif_update` policy (§2.1), generalized.
- **Acknowledgement**: `acknowledged_at`, populated only where the event-type registry
  (§5.4) declares `requires_acknowledgement` — a distinct, stronger state than read, for
  notification types where organizational governance needs positive confirmation, not
  implicit dismissal.
- **Archive/dismiss**: `archived_at` — a personal view-state change (hide from the default
  inbox view); the row is never deleted, so it remains available to §19's audit trail and
  to a future "show archived" view.
- **Mutability boundary**: `notification_type`, `template_params`, `source_*`, and
  `outbox_event_id` are write-once at creation (business-fact fields, effectively
  immutable); only `read_at`/`acknowledged_at`/`archived_at` are ever updated afterward, and
  only by the owning recipient (or an administrator acting on their behalf, itself an
  audited action) — mirroring the same "evidence vs. mutable lifecycle state" split CAP-002
  already draws between `workflow_sla_clock_events` (immutable) and `workflow_sla_clocks`
  (mutable current state).

## 11. Preferences

**Not implemented in this milestone** (architecture only, per the governing instruction).
The load-bearing decision this document does make: a **mandatory/optional split** must
exist structurally before any preference system is built, so that a future preference layer
is physically incapable of suppressing a mandatory business notification. The event-type
registry's `is_mandatory` flag (§5.4) is the enforcement point — a future preference check
runs only for `is_mandatory = FALSE` event types, never as a gate in front of mandatory
in-app notification *creation* itself (it may still legitimately gate optional *delivery
channels*, e.g., "don't also email me for this," §12).

Future preference hierarchy (design sketch, not built now): platform-mandatory (cannot be
overridden by anyone) → organization-mandated (an org admin requires it for their org,
overridable only by platform) → module default → event-type preference → channel
preference → quiet hours → digest-vs-immediate. Each level may only narrow what the level
above allows, never widen it — the same "configuration cannot grant visibility or
authority" principle docs/60 already applies to workflow definitions.

## 12. Delivery-channel architecture

Channel adapters are **separate consumers** of a completed `user_notification` row (or, for
channels needing their own retry state, a lightweight per-channel delivery-attempt record
derived from it) — never a code path domain modules call directly, and never logic the
outbox worker itself contains. In-app (§9) is the only channel this milestone's proposed
implementation phases (§27) build; it requires no adapter, since the durable row *is* the
in-app notification.

Future channels: **email** and **mobile push**, per the governing instruction's explicit
list. **Telegram** remains a previously-considered, still-deferred option per §2.7's
evidence — evaluated on the same footing as email/push if a future milestone revisits it,
not assumed. **SMS is not added to this architecture** — no repository or business evidence
justifies it (per the governing instruction's explicit exclusion and §2.7's findings).

A channel adapter's contract (future, not built now): given a `user_notification` row (or a
channel-specific projection of it), attempt delivery, record success/failure as its own
operational telemetry (§19), and never mutate the `user_notification` row's own read/ack/
archive state — delivery success is not the same fact as "the user has seen this,"
deliberately kept distinct.

## 13. Worker and queue model

PostgreSQL/Supabase-native, matching every other CAP-002/CAP-003-adjacent worker this
codebase has built — no external message broker; nothing in this repository demonstrates a
need for one, and the governing instruction requires evidence before proposing one. Model:
`FOR UPDATE SKIP LOCKED` bounded-batch claiming (§5.7), a single worker-facing entry point
callable by multiple concurrent worker processes safely (horizontal scalability by simply
running more workers — no partitioning/sharding logic required, identical to Phase 5.4's own
"safe for multiple worker instances" property). Scheduling/deployment (whether via existing
`pg_cron` — already installed, §2.4 — an Edge Function on a timer, or an external scheduler)
is explicitly **an implementation-phase decision, not fixed here**, matching how Phase 5.4
itself deferred scheduler deployment as out of scope for an architecture/foundation
milestone.

## 14. Idempotency and deduplication

Two independent layers, matching CAP-002's own established discipline:

1. **Enqueue-level**: `idempotency_key` uniqueness (§5.6) — a retried domain transaction
   never produces a duplicate outbox event.
2. **Notification-level**: `UNIQUE (outbox_event_id, recipient_user_id)` on
   `user_notifications` — a worker that claims the same event twice (crash-and-retry, or a
   dead-lettered event replayed) never creates duplicate notifications for the same
   recipient, exactly mirroring how `idx_workflow_sla_clock_events_warning_once` and
   `_breach_once` backstop CAP-002's own automatic-dispatch idempotency independent of
   whatever the processing code itself does.

## 15. Retry and dead-letter handling

Bounded attempts with exponential backoff and jitter (exact curve/cap an operational
constant, §26); `next_attempt_at` governs re-eligibility, filtered by the same partial
index used for claiming (§5.7); terminal failure transitions to `dead_letter` (§5.8), never
silent deletion. Poison-event handling (failure scenario 8, §22) is exactly the
`dead_letter` path — a repeatedly-failing event stops consuming worker attempts once its
bound is reached, remains inspectable, and requires an explicit operator replay rather than
retrying forever.

## 16. Realtime

Formalizes §2.6's already-correct existing pattern platform-wide rather than inventing a
new one: a Realtime channel on `user_notifications`, `event: INSERT`, filtered to
`recipient_user_id=eq.<self>` — exactly the shape `shell.js` already uses on `notifications`
today — signals "your notification set changed"; the client re-fetches via its own
authorized query. **Realtime never carries the notification body as the wire payload of
record** — the durable row, already committed before the Realtime event fires (Realtime
publishes from the WAL after commit, never before), is the only source of truth. A client
offline at publish time simply sees the row on its next authorized fetch; nothing is lost,
because nothing was ever *only* in the Realtime message (failure scenario 15, §22).

## 17. Security and confidentiality

- **Organization isolation**: every `user_notifications`/`platform_outbox_events` row
  carries `organization_id`; RLS scopes `SELECT` to `recipient_user_id = auth.uid()` on
  notifications (a user only ever sees their own — organization scoping is redundant but
  cheap defense-in-depth) and to service-role-only visibility on the outbox table (it is
  operational infrastructure, not a user-facing record).
- **User-level visibility**: `user_notifications` RLS: `SELECT`/`UPDATE` (read/ack/archive
  only) restricted to `recipient_user_id = auth.uid()`; **no `INSERT` policy for
  `authenticated`/`anon` at all** — creation is exclusively a `SECURITY DEFINER` worker
  path, closing §2.3's demonstrated gap structurally.
- **Service-role processing**: the outbox worker's entry point is granted `EXECUTE` only to
  `service_role`, revoked from `PUBLIC`/`anon`/`authenticated` — the identical posture
  Phase 5.4 established for `process_workflow_sla_due_batch` (§2.5), for the identical
  reason: this is a worker/system execution path, never something an end-user session
  should be able to invoke directly.
- **`SECURITY DEFINER` boundaries**: the enqueue helper, the resolution/authorization-
  revalidation logic, and the notification-creation path are all `SECURITY DEFINER`,
  pinned `search_path`, following the exact pattern every CAP-002 RPC already establishes —
  no new convention introduced.
- **Safe metadata rules**: §5.3/§9 — payload and template params carry only what the
  recipient could already see through the source module's own authorization; confidential
  content (a Prisoner Letter's body, a Request's substantive text) is never duplicated into
  notification storage merely to make rendering easier, per the governing instruction's
  explicit prohibition.
- **Prisoner Letter protection**: a Prisoner Letter event's recipient resolution must pass
  `is_prisoner_letters_staff()` plus the same participant check `rls.sql` already applies
  (§2.7/§8) — a user who is not flagged prisoner-letters staff can never become a resolved
  recipient of a prisoner-letter-sourced notification, regardless of section/org membership,
  exactly mirroring the existing RLS policy's own logic.
- **Cross-organization events**: §18.
- **Authorization revalidation**: §8 — every candidate, every time, no caching of a
  stale "was authorized at enqueue time" fact.
- **Auditability / immutable processing evidence**: §19.

Notification payloads must never become a bypass around the authorization model — this is
restated because it is, per the governing instruction, the single most load-bearing
constraint on this entire architecture, exactly as docs/60's equivalent sentence governs
CAP-002's escalation design.

## 18. Cross-organization behavior

The outbox/notification layer never *creates* a cross-organization boundary — it only
notifies within whatever boundary the source module already established. A workflow
instance's `participant_organization_ids` (CAP-002) or a Prisoner Letter's two-organization
model already define who may legitimately be involved; a `workflow_participants(instance_id)`
or equivalent target descriptor (§7.1) resolves candidates only from within that
already-approved set, and §8's revalidation still applies per candidate. CAP-003 adds no
new cross-organization routing capability of its own (failure scenario 11, §22).

## 19. Audit and observability

Two explicitly separate retention classes, per the governing instruction's own demand not
to create an unlimited log merely because auditing is useful:

**Immutable business evidence** (retained per business/records-retention policy, §21):
the `platform_outbox_events` row itself (an event happened, with its payload, forever
traceable to the domain transaction that produced it) and the `user_notifications` row's
creation fact (a specific recipient was notified of a specific thing at a specific time) —
both write-once on their business-fact columns (§5.3, §10).

**Operational telemetry** (short-retention, prunable, §21): claimed / processing started /
retried / delivery attempted / delivery succeeded / delivery failed / recipient skipped —
high-volume, high-churn, useful for debugging and monitoring but not itself a compliance
record. These are recorded either as mutable columns on the outbox row itself
(`attempt_count`, `last_error`, `claimed_at` — no separate row per attempt) or, only where a
genuine per-attempt history is operationally valuable (e.g., per-channel delivery attempts
once channels exist, §12), a small bounded/prunable log table — never an unbounded append
for every telemetry-class event.

## 20. Scalability and indexing expectations

Expected index shapes (named for continuity with the implementation phase; not created by
this document):

- Partial index on `platform_outbox_events (next_attempt_at) WHERE status = 'pending'` —
  the claim query's own access path, mirroring `idx_workflow_sla_clocks_breach_due`.
- Composite index on `user_notifications (recipient_user_id, read_at, created_at DESC)` —
  the unread-list/unread-count access path, so "my unread notifications" never scans a
  user's full historical set, addressing failure scenario 14 (thousands of unread rows for
  one user) directly.
- Partial index on `user_notifications (recipient_user_id, created_at DESC) WHERE read_at IS
  NULL` — a cheaper unread-count-specific path if the composite index above proves
  insufficient at measured scale (an implementation-phase decision informed by real
  `EXPLAIN` output, matching Phase 5.4's own "only add an index when the measured query plan
  demonstrates need" discipline — no index is spuriously proposed here beyond what the
  access patterns already imply).
- BRIN index on `platform_outbox_events (created_at)` and `user_notifications (created_at)`
  — the same low-cost, high-volume time-ordered precedent `idx_workflow_events_created_brin`
  already establishes.
- Keyset pagination (`(created_at, id)` cursor), never `OFFSET`, for both the outbox
  worker's own scan and any future user-facing notification list/history view — addressing
  failure scenario 13 (millions of historical rows) directly; an `OFFSET`-based list view
  degrades linearly with history size exactly where this table is expected to grow
  largest.

No index is created by this document, per the governing instruction.

## 21. Retention/archive strategy

- **Outbox `completed` rows**: pruned/archived after a short operational retention window
  (exact duration an open decision, §26) — they are operational evidence, not the
  compliance record, once their downstream `user_notifications` row(s) exist.
- **Outbox `dead_letter` rows**: retained until an operator explicitly resolves/replays
  them — never auto-pruned, since they represent an unresolved operational problem.
- **`user_notifications` rows**: retained per business/records-retention policy (a longer,
  business-owned duration — exact figure an open decision, §26), since these are the
  durable evidence a specific user was told a specific thing, which may itself have
  compliance relevance (e.g., "was the assigned staff member notified of the SLA breach").
- **Operational telemetry**: short retention, aggressively prunable, independent of both of
  the above (§19).

## 22. Failure scenarios

1. **Domain transaction succeeds, worker offline.** The outbox row exists (enqueued
   atomically, §5.2) and sits `pending`. No loss — the worker processes it whenever it next
   runs; there is no time-sensitive coupling between commit and processing.
2. **Worker crashes after claiming.** The claiming transaction's lock is released when the
   crashed connection drops; the row remains `claimed`/`processing` with no further updates.
   A staleness check (an implementation-phase detail: e.g., `claimed_at` older than a
   processing-timeout threshold with no terminal status) makes it eligible for reclaim by
   another worker — never permanently stuck.
3. **Worker processes the same event twice.** §14's two idempotency layers make this a
   no-op: the notification-level `UNIQUE (outbox_event_id, recipient_user_id)` constraint
   prevents a duplicate `user_notifications` row regardless of how many times processing
   re-runs.
4. **Recipient loses authorization after event creation.** §8's late (processing-time, not
   enqueue-time) revalidation catches this — they are skipped, never notified of something
   they can no longer see.
5. **User is disabled before delivery.** Same mechanism as scenario 4 — `users.is_active =
   FALSE` fails revalidation, recipient skipped.
6. **Organization/module access is disabled.** Same mechanism — `organization_modules.is_enabled
   = FALSE` (or the module's own equivalent gate) fails revalidation, recipient skipped.
7. **Email/push provider unavailable.** Contained entirely within that channel adapter's own
   retry/backoff (§12, future work) — never blocks in-app notification creation, which has
   already happened by the time any external channel is attempted.
8. **Poison event repeatedly fails.** Bounded attempts, then `dead_letter` (§15) — stops
   consuming worker capacity, remains inspectable, requires explicit operator replay.
9. **Notification already exists when event is replayed.** §14's notification-level
   uniqueness constraint makes replay (operator-triggered dead-letter replay, or a duplicate
   enqueue that somehow bypassed §5.6's idempotency key) a safe no-op — no duplicate ever
   created.
10. **Two workers claim work concurrently.** `FOR UPDATE SKIP LOCKED` (§5.7) guarantees
    exactly one worker wins the row; the other sees zero candidates for it and moves on —
    the identical guarantee CAP-002 Phase 5.4's concurrency suite already verified for the
    SLA dispatcher.
11. **Cross-organization workflow generates a notification.** §18 — resolution stays within
    the source module's own already-approved participant-organization set; no new
    cross-org boundary is created.
12. **Confidential Prisoner Letter produces a notification.** §17 — recipient resolution
    requires `is_prisoner_letters_staff()` plus the existing participant check; payload
    never carries the letter's actual content (§5.3/§9).
13. **Millions of historical notifications exist.** §20's keyset pagination and composite/
    partial indexes keep both the worker's own queries and any future user-facing history
    view bounded regardless of total row count; §21's retention strategy keeps the
    *operational* tables (outbox, telemetry) from growing unbounded in the first place.
14. **A user has thousands of unread notifications.** §20's partial/composite index on
    `(recipient_user_id, read_at, created_at)` keeps the unread list and unread-count query
    bounded by the user's own unread set, not the platform's total notification volume.
15. **Client is offline during realtime publication.** §16 — no loss, since the durable row
    already exists independently of the Realtime message; the client simply sees it on its
    next authorized fetch.

## 23. CAP-002 integration

**Nothing in CAP-002 changes.** Workflow graph execution, approval decisions, delegation
semantics, substitution semantics, SLA calculation, escalation decisions, and the Phase 5.4
SLA timer dispatcher's own behavior are all explicitly out of scope for modification, per
the governing instruction — and this document proposes none.

The exact future seam (not built now): `workflow_sla_process_due_warnings`/`_breaches`/
`_escalations` (docs/77 §"Warning/Breach/Escalation processing") already wrap each
candidate's claim-and-mutate sequence in its own `BEGIN...EXCEPTION` block, writing the
existing evidence row (`workflow_sla_clock_events`/`workflow_escalation_events`) inside that
same per-item transaction. A future, separately approved CAP-002-successor milestone would
add exactly one more statement to that same per-item block — a call to CAP-003's
`platform_enqueue_outbox_event(...)` helper — so the outbox enqueue is atomic with the
evidence write, using the evidence's own already-computed fields (`clock_id`, `instance_id`,
warning/breach/escalation-level identity) as the outbox event's `source_record_id`/payload.
`process_workflow_sla_due_batch` itself would not need a new dispatcher, a new claim
mechanism, or any change to its own SKIP LOCKED/bounded-batch logic — it already visits
every due item exactly once per successful claim; the future patch only adds a second write
to a transaction that already exists. This document does not implement that change; it
records the seam so the next milestone doesn't have to rediscover it.

## 24. Other CorLink module integration model

Standard contract every future (and, on its own migration timeline, every existing) module
follows:

```
DOMAIN TRANSACTION (existing module RPC)
      ↓
DOMAIN STATE CHANGE (existing module mutation, unchanged)
      ↓
ATOMIC OUTBOX ENQUEUE (one call to platform_enqueue_outbox_event(...), same transaction)
      ↓
COMMIT
      ↓
OUTBOX WORKER (platform-owned, SKIP LOCKED, bounded batches)
      ↓
RECIPIENT RESOLUTION (target descriptors → candidates, processing-time)
      ↓
AUTHORIZATION REVALIDATION (source module's own predicate, per candidate)
      ↓
DURABLE USER NOTIFICATION (user_notifications row, SECURITY DEFINER creation only)
      ↓
REALTIME SIGNAL (INSERT event on the recipient's own filtered channel)
      ↓
CHANNEL DELIVERY (future — in-app is already "delivered" by the row's existence)
```

This is the governing instruction's own suggested diagram, reviewed against repository
evidence and **adopted without refinement** — nothing found during research (§2) suggests a
different shape is warranted; if anything, §2.5/§2.6 show CorLink already independently
converged on pieces of this exact flow (CAP-002's atomic event-write-in-transaction, and
Realtime-as-signal) without a shared platform tying them together yet.

Modules integrate by calling the enqueue helper with a target-descriptor set (§7.1) — they
never resolve recipients to concrete user ids themselves (except the literal
`specific_user`/`specific_users` descriptors, which are already concrete by definition),
never write to `platform_outbox_events` or `user_notifications` directly, and never contain
delivery-channel logic of their own. A module that needs a target shape not in §7.1's fixed
vocabulary registers a `dynamic` resolver function rather than the platform accepting
arbitrary module-supplied SQL.

## 25. Proposed CAP-003 implementation phases

Adjusted from the governing instruction's suggestion based on repository evidence — the
sequence is unchanged in substance; phase boundaries are drawn so each phase leaves a
coherent, independently-testable increment, matching every CAP-002 phase's own precedent:

- **CAP-003 Phase 1.1** — Transactional outbox table + durable `user_notifications` table
  (schema, RLS, immutability triggers on business-fact columns, no worker yet, no
  recipient resolution yet — inert persistence foundation, mirroring CAP-002 Phase 5.1's
  own "inert foundation" precedent).
- **CAP-003 Phase 1.2** — Recipient resolution + authorization-revalidation-safe
  notification creation (the target-descriptor vocabulary, §7–§8, exercised synchronously/
  manually first, before any automatic worker exists — mirroring how CAP-002 Phase 5.3
  shipped synchronous SLA primitives a full phase before Phase 5.4's automatic dispatcher).
- **CAP-003 Phase 1.3** — Outbox worker: bounded-batch `SKIP LOCKED` claiming, retry/
  backoff, dead-letter handling — the direct architectural sibling of CAP-002 Phase 5.4.
- **CAP-003 Phase 1.4** — Module integration foundation: the `platform_enqueue_outbox_event`
  contract finalized and adopted by one pilot module (candidate chosen by evidence at that
  time, not fixed here — Tasks or Meetings are the most structurally simple existing
  integration points based on this review).
- **CAP-003 Phase 1.5** — Realtime in-app delivery/read-state integration: the
  `postgres_changes` signal channel (§16) plus the frontend inbox/bell UI consuming
  `user_notifications` directly, retiring the legacy `notifications` table's role once
  parity is confirmed (a deliberate, reviewed cutover — never a silent dual-write period
  left indefinitely).
- **CAP-003 Phase 2** — External delivery-channel adapters (email, mobile push; Telegram
  only if separately revisited, §12) — explicitly out of scope until the in-app foundation
  above is complete and stable.

## 26. Explicitly deferred capabilities

Per the governing instruction, none of the following are implemented by this milestone:
any SQL, table, RPC, Edge Function, or worker code; notification delivery of any kind
(email, SMS, push); cron/scheduler deployment; module integrations; frontend components;
notification preferences (§11); delivery-channel adapters (§12); indexes (§20 specifies
shapes only).

## 27. Open decisions

Business-policy-dependent questions this document cannot resolve from existing CorLink
principles and does not invent an answer to:

1. **Exact retention durations** — how long `completed` outbox rows, operational
   telemetry, and (separately) `user_notifications` rows are kept before archival/deletion
   is a records-retention policy decision, not an architectural one (§21).
2. **Exact retry/backoff curve and attempt cap** — an operational tuning constant (§5.7,
   §15), the same category of decision Phase 5.4 left to its own implementation phase for
   batch size.
3. **Which event types require acknowledgement** (§10) — a per-type governance decision
   for whoever owns each module's business process, not something this platform
   architecture can decide generically.
4. **Whether digest-vs-immediate delivery is ever built at all** (§11) — genuinely
   product-dependent; sketched as a future preference-hierarchy layer but not committed to.
5. **Whether Telegram is ever actually pursued as a channel** (§12) — previously deferred
   once already (§2.7); this document does not re-open or resolve that product decision.
6. **The exact numeric batch-size/worker-count operational constants** (§5.7, §13) — left
   to the implementation phase, consistent with how Phase 5.4 treated the identical class
   of decision.
7. **Which existing module is the Phase 1.4 pilot integration** (§25) — a scheduling/
   prioritization decision for whoever sequences CAP-003's implementation, not an
   architectural one.

## 28. Final architecture summary

CAP-003 is one platform-owned transactional outbox (`platform_outbox_events`, modeled on
`workflow_events`' proven open-event-type shape, never on `notifications`/`audit_logs`'s
closed-enum anti-pattern) plus one platform-owned durable notification table
(`user_notifications`, created exclusively through a `SECURITY DEFINER` path, never direct
client `INSERT`). Domain modules enqueue atomically, within their own existing transaction,
through a single shared helper — never inventing their own tables, delivery logic, or
recipient resolution. A `service_role`-only worker, built on the exact `FOR UPDATE SKIP
LOCKED` bounded-batch pattern CAP-002 Phase 5.4 already established and proved, claims due
outbox work, resolves recipients late against a fixed target-descriptor vocabulary, and
independently revalidates every candidate against the source module's own authorization
before ever creating a notification. Realtime signals change; it never carries the record.
Business evidence and operational telemetry are retained on separate, explicitly bounded
schedules. Nothing in CAP-002 changes; a documented, unbuilt seam exists for a future
milestone to connect the SLA dispatcher's existing evidence writes to this platform without
touching the dispatcher's own claim/processing logic.
