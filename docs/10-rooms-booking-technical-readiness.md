# Rooms, Room Blocks and Bookings — Technical Implementation Readiness

**Type:** Technical implementation-readiness assessment (follow-up to `docs/08-meetflow-booking-schema-analysis.md` and `docs/09-rooms-booking-v1-decisions.md`). **No database migration was created or applied. No application code was changed. Neither Supabase project was written to. No Edge Function was invoked. Nothing was deployed or pushed.**
**Companion documents:** `docs/03-migration-architecture.md`, `docs/08-meetflow-booking-schema-analysis.md`, `docs/09-rooms-booking-v1-decisions.md` (this document resolves that document's §16 open technical questions and produces the concrete schema/RPC/RLS shape those decisions imply).
**Date:** 2026-07-21
**Method:** Full static inspection of `supabase/schema.sql`, `supabase/rls.sql`, `supabase/notifications.sql`, `supabase/storage-policies.sql`, `supabase/patch-platform-module-foundation.sql`, and every existing patch file's naming/trigger/RPC conventions. **Live CorLink schema inspection was attempted and was unavailable** (Supabase MCP connector `enabledInChat: false` for the duration of this step, same connector-availability issue observed throughout this session) — every finding below is explicitly labeled **[static]** (derived from repository inspection, high confidence — this is source-of-truth SQL, not documentation-of-intent) or **[unverified-live]** (would require a live query this session could not run).

---

## 0. Verified vs. unverified — read this first

- **[static]** findings below come directly from reading `supabase/*.sql` in this repository. Since CorLink's own convention (confirmed repeatedly across this session's history, e.g. `docs/02`'s finding of zero live/repo drift on the CorLink side) is that the live CorLink project matches its tracked SQL exactly, these findings are treated as high-confidence, not merely "documented intent" — but they are still not a live query, and are labeled `[static]` throughout for precision.
- **[unverified-live]** items — primarily whether `btree_gist` is currently enabled, and whether the migration role has privilege to enable it — could not be checked this session. §2 gives the exact read-only SQL to run once the connector is available, and a fallback design that does not depend on the answer.

---

## 1. Existing CorLink Systems to Reuse

| Concept | Exact existing object(s) `[static]` | Reuse plan |
|---|---|---|
| Organizations | `organizations` (`id`, `type` CHECK IN `('mcs','authority')`, `org_id` FK convention used by every top-level table) | `meeting_rooms.org_id` / `meeting_room_bookings.org_id` follow this exact pattern — no new organization concept needed. |
| Users / profiles | `users` (`id` = `auth.users.id`, `org_id`, `is_super_admin` boolean, `is_active`) | `created_by`, `approved_by`, `cancelled_by`, override actor fields all `REFERENCES users(id)`, matching every existing FK-to-users column in the schema (`requests.created_by`, `attachments.uploaded_by`, etc.). |
| Role assignments | `user_assignments` (`scope_type` CHECK IN `('organization','command','department','division','section')`, `scope_id`, `role` CHECK IN `('mcs_admin','authority_admin','supervisor','assigned_receiver','staff')`, `is_primary`, `is_active`) | Room-manager authority composes with this table rather than adding a new role value — see §10. |
| Permissions / scope resolution | `get_my_org_id()`, `scope_org_id()`, `scope_section_ids()`, `has_role()`, `has_role_in_section()`, `my_section_ids()`, `my_supervised_section_ids()`, `is_admin()`, `is_supervisor_or_above()` — all `SQL STABLE SECURITY DEFINER`, no `search_path` pin (matches every function in `rls.sql`) | Reused directly, unmodified, in every new RLS policy and RPC below. No parallel permission system is introduced. |
| Organization membership / module gating | `is_super_admin()`; **`platform_modules`/`organization_modules`** (Phase 1, already shipped per `docs/04`) with helpers `module_enabled_for_org(p_org_id, p_module_key)`, `current_user_module_enabled(p_module_key)`, `is_module_active(p_module_key)` | The module key **`rooms` already exists** in the seeded catalogue (`route IS NULL` today — unshipped, unreachable). No new module key or table is needed for Layer 1 gating; Phase 4 only needs to set `route = 'rooms'` once the frontend ships, and add `organization_modules` rows enabling it per-org (deliberately not automatic for any org — see §10/§7 of `docs/09`). |
| Super-admin detection | `is_super_admin()` (reads `users.is_super_admin`) | Reused directly — no new "platform admin" concept. |
| Audit | `audit_logs` (`id`, `user_id NOT NULL`, `action` CHECK-constrained enum, `record_type` CHECK-constrained enum, `record_id`, `notes`, `ip_address`, `created_at`; INSERT policy `user_id = auth.uid()`; SELECT scoped to super-admin / org-admin-of-the-actor; **no UPDATE/DELETE policy — immutable by construction**) | Reused directly. **New CHECK-constraint values needed** (not a new table) — see §16. Existing convention inserts audit rows from client-side `logAudit()` calls in `js/data/*.js`; §14 below recommends a deliberate, narrow deviation for booking-specific state changes (server-side insert from within the new RPCs) — justified and flagged explicitly, not silently different. |
| Notifications | `notifications` (`id`, `user_id NOT NULL`, `type` CHECK-constrained enum, `record_type TEXT` — **not** CHECK-constrained, `record_id NOT NULL`, `message`, `is_read`, `created_at`); INSERT policy is `auth.uid() IS NOT NULL` only (no `user_id = auth.uid()` restriction — any authenticated user may insert a notification addressed to anyone); SELECT/UPDATE strictly own-row | Reused directly. **New `type` CHECK-constraint values needed** — see §11. Existing convention: helper RPCs `section_user_ids(p_section_id, p_roles)` / `org_supervisor_user_ids(p_org_id)` resolve recipients, then either client code or a `SECURITY DEFINER` function (`check_deadlines()`) inserts rows. §11 recommends booking notifications be inserted only from the new RPCs (§14), not client code — see §11's rationale. |
| Attachments | `attachments` (`record_type` CHECK-constrained enum, `record_id`, `storage_path`, private Storage bucket `attachments`, path convention `attachments/{record_type}/{record_id}/{filename}`, Storage RLS delegated back to the `attachments` table's own `attachments_select` policy via `EXISTS`) | Per `docs/09` §13: meetings reuse this system later (new `record_type` value); bookings and rooms get **no** attachment support in V1 — confirmed again in §17 below, no new bucket needed. |
| Existing room-related objects | **None found.** `[static]` — a repository-wide search for `room`/`rooms`/`booking`/`calendar` across `supabase/*.sql` and `js/` returns no hits outside this migration's own planning documents. CorLink has zero existing scheduling/room domain today. | No collision risk; `meeting_rooms`/`meeting_room_blocks`/`meeting_room_bookings` are entirely new, per `docs/03` §5's already-established naming (chosen specifically to avoid colliding with MeetFlow's own legacy `rooms`/`room_blocks`/`bookings` table names, per `docs/08`). |
| Existing calendar/scheduling objects | **None found.** `[static]` | Confirmed net-new domain — no existing table to reconcile against. |
| `updated_at` trigger helper | `trigger_set_updated_at()` (generic `BEFORE UPDATE ... NEW.updated_at = NOW()`), already attached to 10 existing tables plus `platform_modules`/`organization_modules` | Attach identically to `meeting_rooms`, `meeting_room_blocks`, `meeting_room_bookings`, and any room-manager assignment table — zero new trigger logic needed for this concern. |
| UUID generation | `CREATE EXTENSION IF NOT EXISTS "pgcrypto"` (only extension currently enabled `[static]`); every table's PK is `UUID PRIMARY KEY DEFAULT gen_random_uuid()`, with zero exceptions anywhere in `schema.sql` | Followed identically for every new table — no serial/identity PKs anywhere in the proposed design (§16). |
| Soft-delete convention | CorLink has **no generic `deleted_at`/soft-delete column pattern**. Two distinct existing patterns instead: (a) reference/structural tables (`commands`, `departments`, `divisions`, `sections`, `designations`) use `is_active BOOLEAN DEFAULT TRUE`; (b) workflow tables (`requests`, `responses`, `external_correspondence`) use a terminal **status value** (`cancelled`, `closed`) rather than any deletion flag — rows are never hard-deleted, matching `docs/09`'s own "cancellation updates status and audit fields rather than delete the row" decision | `meeting_room_bookings` follows pattern (b) — `status = 'cancelled'`/`'rejected'`/`'expired'` are the "soft delete." `meeting_room_blocks` follows pattern (a) — `is_active BOOLEAN DEFAULT TRUE`, matching its own status as reference/administrative data rather than a workflow record with its own lifecycle states. |
| Status CHECK constraints / enums | CorLink uses **plain `TEXT` + `CHECK (... IN (...))`**, never a native Postgres `ENUM` type, for every status/type/role/action/record_type column in the schema — zero `CREATE TYPE ... AS ENUM` statements exist anywhere in `supabase/schema.sql`. Status-transition *logic* (not just allowed values) is separately enforced via a `valid_X_status_transition(old,new) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE` function + a `BEFORE UPDATE OF status` trigger calling it and `RAISE EXCEPTION` on violation — this exact pattern exists three times already: `valid_request_status_transition`/`trigger_check_request_status`, `valid_response_status_transition`/`trigger_check_response_status`, `valid_entry_status_transition`/`trigger_check_entry_status` (+ the entry-reply variant) | `meeting_room_bookings.status` follows the identical `TEXT + CHECK` + `valid_booking_status_transition()`/`trigger_check_booking_status` pattern — see §5/§16. No enum type is introduced, keeping the new tables stylistically indistinguishable from the rest of the schema. |
| SQL extension usage | `pgcrypto` (schema.sql, UUID generation) and `pg_cron` (`notifications.sql`, `CREATE EXTENSION IF NOT EXISTS pg_cron`, confirmed already enabled and running a daily job, `cron.schedule('check-deadlines-daily', ...)`) — **`btree_gist` is not currently enabled** `[static — confirmed absent from every tracked SQL file; live status is `[unverified-live]`, see §2]`. | §2 addresses `btree_gist` specifically; `pg_cron` is explicitly **not** used for V1 booking completion (§6, per the approved decision) even though it's already available — a deliberate non-use, not an oversight. |

**No duplicate system is recommended anywhere in this document.** Every concept above maps to an existing CorLink mechanism, not a bespoke reimplementation.

---

## 2. PostgreSQL Capability Findings

### `btree_gist`

- **1. Already enabled?** `[unverified-live]` — not confirmed this session (connector unavailable). `[static]`: absent from every tracked `.sql` file, so if it *is* enabled live, it was done manually outside version control (unlikely, but not ruled out without a live check).
- **2. Can the migration role enable it?** `[unverified-live]`. On Supabase, the SQL Editor / migration connection runs as a role with `CREATEDB`-adjacent privileges sufficient for `CREATE EXTENSION` on Supabase's curated allowlist — `notifications.sql`'s own comment on `pg_cron` (`"Supabase allows enabling pg_cron directly via SQL (it's on their curated extension allowlist)"`) is direct evidence this project's migration role already successfully self-served at least one extension this way. `btree_gist` is a standard, long-stable PostgreSQL contrib extension on Supabase's publicly documented supported-extensions list, so the same self-service path is expected to work — but this is an expectation from general Supabase platform knowledge, not a finding verified against *this* project this session, and is reported as such.
- **3. Does Supabase's Postgres environment support it?** Expected yes (same reasoning as above) — `[unverified-live]`.
- **4. Material risk to existing objects?** **None expected.** `btree_gist` only adds new GiST operator-class definitions to the catalog (for scalar types like `uuid`/`int`/`timestamptz` to be used in GiST indexes/exclusion constraints) — it creates no tables, alters no existing table, and has no interaction with `pgcrypto` or `pg_cron`. This is a low-risk, purely additive extension by design.

**Exact read-only SQL to check later** (no writes, safe to run against production for information only):

```sql
-- Is it already enabled, and what version?
SELECT extname, extversion FROM pg_extension WHERE extname = 'btree_gist';

-- Is it available to enable on this Postgres build at all?
SELECT name, default_version, installed_version
FROM pg_available_extensions WHERE name = 'btree_gist';

-- Does the connected role have privilege to CREATE EXTENSION?
-- (Supabase's migration/SQL-editor role typically does; this confirms it directly.)
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb
FROM pg_roles WHERE rolname = current_user;

-- Sanity-check pgcrypto/pg_cron are still the only two enabled, as expected from tracked SQL:
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

**Fallback design if `btree_gist` turns out to be unavailable or the role cannot enable it:** the entire conflict-prevention model can run on the trigger-plus-advisory-lock mechanism alone (§4, §7), with **no exclusion constraint at all** — every status (`hold`, `pending`, `confirmed`) checked via the same `pg_advisory_xact_lock`-serialized, lazy-hold-expiring trigger function described in §4, rather than splitting `pending`/`confirmed` off into a constraint-enforced fast path. This is strictly safe (the advisory lock serializes all writes to a given room regardless of status, so there is no window for a race even without the constraint) but loses the "enforced by Postgres itself, independent of trigger correctness" defense-in-depth property described in §4 — recommended only as a fallback, not as the primary design, and only if §2's live check comes back negative.

### Other capabilities

- **`tstzrange`** — built into core PostgreSQL (`temporal` range types), no extension required. Available regardless of `btree_gist`'s status.
- **Exclusion constraints (`EXCLUDE USING gist (...)`)** — core PostgreSQL feature; the `gist` access method itself needs no extension, but excluding on a `uuid` equality column (`room_id WITH =`) alongside a range operator (`tstzrange WITH &&`) specifically requires `btree_gist` for the equality operator class on `uuid` to participate in a GiST index. Without it, only single-column range exclusion is possible — insufficient here, since conflicts must be scoped per-room.
- **Advisory locks (`pg_advisory_xact_lock`)** — core PostgreSQL, no extension required, available regardless of `btree_gist`.
- **Transaction-safe trigger functions** — core PostgreSQL (`PL/pgSQL`), already used extensively in this exact codebase (§1's status-transition triggers, `trigger_track_previous_section()`, `trigger_set_updated_at()`).

**Conclusion: nothing in the approved design is blocked by `btree_gist` unavailability** — it's an optimization/defense-in-depth layer, not a hard dependency, given the fallback above.

---

## 3. Timestamp-Range Design

**Recommended: the expression directly inside the exclusion constraint, not a stored/generated column.**

```
tstzrange(start_at, end_at, '[)')
```

- **Half-open interval `'[)'`** (inclusive start, exclusive end) — this is the only interval mode that allows adjacent bookings (10:00–11:00 and 11:00–12:00) to coexist: `tstzrange('10:00','11:00','[)')` and `tstzrange('11:00','12:00','[)')` do not overlap (`&&` is false), because the first range does not include the instant `11:00` itself. A closed interval `'[]'` would incorrectly reject this exact adjacent-booking case.
- **`start_at >E nd_at` rejection** is **not** delegated to the range/exclusion machinery at all — it's a plain, separate `CHECK (end_at > start_at)` constraint on the table. This is simpler, cheaper to evaluate, and independent of whether the exclusion constraint or `btree_gist` is even in use (works identically under §2's fallback design too).
- **Timezone/DST correctness is automatic, not something this design has to solve separately**: `timestamptz` values are stored and compared as absolute UTC instants internally — `tstzrange`/`&&` comparisons operate on those instants directly, with no dependency on session timezone, wall-clock representation, or DST transitions. A booking spanning a DST transition, or two bookings compared across different timezones, compare correctly by construction. This is precisely why `docs/09` §11 mandated `timestamptz` (not `timestamp`) as the authoritative type.
- **The stored `timezone` column is never referenced by the range expression or the exclusion constraint** — confirmed by construction, since the expression above only reads `start_at`/`end_at`. `timezone` remains purely descriptive/display metadata, exactly as `docs/09` §11 requires.
- **Why not a generated column?** PostgreSQL does support `GENERATED ALWAYS AS (tstzrange(start_at, end_at, '[)')) STORED` for this exact case (both inputs are plain columns, the expression is immutable). It would work identically for the exclusion constraint. It is **not recommended** here purely because it adds a redundant stored column with no correctness or performance benefit over referencing the expression directly in the constraint (the GiST index over the expression is built and maintained the same way either way) — consistent with this codebase's own repeatedly-stated discipline against adding fields without a clear need (`docs/09`'s "avoid speculative fields" instruction, §7 of this document's own instructions warning against speculative complexity). Not a hard rule — a generated column is an acceptable equivalent if a future implementer finds it more convenient for ad hoc querying (e.g. `SELECT * WHERE booking_range && tstzrange(...)` reads slightly more naturally than repeating the `tstzrange(start_at,end_at,'[)')` expression at every call site) — but it is not the default recommendation.

---

## 4. Hybrid Conflict Model — Race Conditions and Recommended Design

### Race conditions identified

| # | Scenario | Risk without mitigation | Mitigation |
|---|---|---|---|
| 1 | Two concurrent `hold` requests for the same/overlapping room-window | Both transactions read "no conflict" before either commits, both insert, both succeed → double hold | `pg_advisory_xact_lock` keyed by `room_id`, acquired unconditionally at the top of the trigger (§ below) before any conflict read — the second transaction blocks until the first commits or rolls back, then re-reads current state correctly. |
| 2 | A `hold` and a `pending` request created concurrently for overlapping windows | The exclusion constraint (if scoped only to `pending`/`confirmed`) does not know about an uncommitted `hold` in another transaction, and does not check against `hold` rows **at all** even once committed (holds are outside the constraint's `WHERE` filter, by design — see §2) → a `pending` request could be accepted into a window a `hold` already occupies | The **same** advisory-lock trigger (not a `hold`-only trigger) fires on **every** insert/update to `meeting_room_bookings`, regardless of target status, and checks the incoming row against currently-live `hold` rows for that room before allowing the write to proceed — closing exactly the gap the exclusion constraint alone cannot cover. |
| 3 | Approval of a `hold`→`confirmed`/`pending`→`confirmed` transition racing a new booking attempt for the same window | Same shape as #1/#2 — the approval is itself a write to the same row/room and must go through the identical lock | Approval happens exclusively through `approve_booking()` (§14), which acquires the same `room_id`-keyed advisory lock before re-validating the target window is still free. |
| 4 | Changing a booking's room (reassigning `room_id`) | A naive `UPDATE ... SET room_id = new_room` only re-checks conflicts if the trigger fires on the new value and locks the **new** room, not the old one | The trigger must acquire the advisory lock for **both** `OLD.room_id` (if changed and not null) and `NEW.room_id`, in a fixed order (see "Lock ordering" below) to avoid deadlock, and re-run the full conflict check against the new room/window. Room reassignment is only exposed through `reschedule_booking()` (§14), never a bare client `UPDATE`. |
| 5 | Changing a booking's `start_at`/`end_at` | Same class as #4 — a time change is a new conflict check against the (possibly unchanged) room | Same `reschedule_booking()` RPC path — re-acquires the room's lock and re-validates before committing the new window. |
| 6 | Creating a `meeting_room_block` over an existing active booking | Per the approved V1 rule (`docs/09` follow-up instruction, §5 here), this must **fail**, not silently coexist | `create_room_block()` (§14) acquires the same room-keyed advisory lock (blocks are checked against the same lock domain as bookings, since they compete for the same room/window) and queries `meeting_room_bookings` for overlapping `hold`/`pending`/`confirmed` rows before inserting; fails unless an authorized override is supplied (§5 below). |
| 7 | Creating a booking over an active block | A booking request landing inside an already-blocked window must be rejected | The booking-creation RPCs (`create_booking_hold`/`submit_booking_request`/`approve_booking` when creating pre-confirmed) additionally check `meeting_room_blocks` (active, non-cancelled) for the room/window as part of the same locked check — not a separate, un-synchronized query. |
| 8 | An expired `hold` being confirmed | Per `docs/09` §6, confirmation must fail once `expires_at < now()` | The lazy-expiry step (flip stale `hold` rows to `expired`) runs **before** the conflict check inside the same locked section, so a hold that has logically expired is never treated as confirmable nor as a blocking conflict for a competing request — both effects fall out of the same single expiry step. |
| 9 | Conflict override operations | An override must bypass the conflict *raise* without bypassing the *lock*, and must be distinguishable from an unauthorized attempt to skip the check entirely | See "Override signaling" below — a transaction-scoped flag set only by the authorized RPC path, defense-in-depth-checked against a mandatory `override_reason`, never a client-settable parameter alone. |

### Recommended design: one trigger function, all statuses, plus the exclusion constraint as a backstop

```
FUNCTION meeting_room_bookings_conflict_guard() — BEFORE INSERT OR UPDATE OF room_id, start_at, end_at, status ON meeting_room_bookings, FOR EACH ROW:

1. Validate end_at > start_at (belt-and-suspenders alongside the table CHECK).
2. Acquire pg_advisory_xact_lock(hashtext(NEW.room_id::text)) — and, on an UPDATE that changes room_id,
   also acquire it for OLD.room_id, in ascending value order (see Lock ordering below) to avoid deadlock
   against a concurrent transaction moving a different booking the other way between the same two rooms.
3. Lazily expire this room's own stale holds:
     UPDATE meeting_room_bookings SET status = 'expired'
     WHERE room_id = NEW.room_id AND status = 'hold' AND expires_at < now() AND id <> NEW.id;
4. If NEW.status IN ('hold','pending','confirmed'):
     a. Check NEW's [start_at,end_at) against remaining live 'hold' rows for room_id (excluding NEW.id) —
        the exclusion constraint does not cover this case (holds are outside its WHERE filter, §5).
     b. Check NEW's [start_at,end_at) against active meeting_room_blocks for room_id (race #7).
     c. On conflict: if current_setting('app.booking_override', true) = 'true' AND
        NEW.conflict_override_reason IS NOT NULL AND NEW.conflict_overridden_by IS NOT NULL,
        allow the write through (the override path — race #9). Otherwise RAISE EXCEPTION.
   ('pending'/'confirmed' vs. other 'pending'/'confirmed' rows is NOT re-checked here — that is the
   exclusion constraint's job, §5, kept as an independent, Postgres-enforced backstop.)
5. RETURN NEW.
```

**The exclusion constraint** (`EXCLUDE USING gist (room_id WITH =, tstzrange(start_at,end_at,'[)') WITH &&) WHERE (status IN ('pending','confirmed') AND NOT conflict_override)`) runs as an ordinary constraint check immediately after the row is written — genuinely enforced by Postgres itself, not by any application or trigger logic, closing the gap even if the trigger function above ever had a bug. The `WHERE` clause excludes overridden rows from the constraint's own scope, since an authorized override is, by definition, an intentional exception — the trigger's explicit reason/actor check (step 4c) is what gates entry into that exempted state, not the constraint.

### Lock ordering

To avoid deadlock when two concurrent transactions each touch two rooms in opposite order (transaction A locks room X then wants room Y; transaction B locks room Y then wants room X — classic deadlock shape), **always acquire advisory locks in ascending order of the room UUID's text representation** (or any other fixed, total, transaction-independent order — UUID text order is simplest and requires no extra state). A reassignment (`OLD.room_id ≠ NEW.room_id`) acquires both locks up front, in that fixed order, before doing any conflict-checking work — never "check old room, then check new room" as two separate lock/unlock cycles, which would reintroduce exactly the race the lock exists to prevent.

### Should one canonical RPC own creation/approval/rescheduling? — Yes, and this deliberately adjusts the trigger-only assumption

CorLink's existing convention (§1: `requests`/`responses`/`external_correspondence`) is direct client `.update()` calls gated by RLS plus a `BEFORE UPDATE OF status` trigger enforcing the transition table. That pattern is sufficient there because none of those tables has a **concurrency-sensitive, lock-requiring** invariant — two supervisors racing to approve the same request produces, at worst, a redundant no-op UPDATE, never a double-booking-shaped correctness failure. Bookings are the first table in this codebase with a genuine "two concurrent writers must not both succeed" requirement, which is exactly the class of problem RLS and a plain trigger cannot fully own on their own (RLS decides *who* may attempt a write; a `BEFORE` trigger can enforce a *single row's* invariant, but the advisory-lock-plus-lazy-expiry-plus-cross-table-block-check sequence above is inherently a multi-step, ordered procedure that needs to run atomically as one unit, with authorization, state transition, audit, and notification bundled into that same atomic unit rather than performed as separate, independently-racy client-side steps).

**Recommendation: yes, canonical `SECURITY DEFINER` RPCs own every operation that requires locking, cross-table conflict-checking, or override authorization** — full list and rationale in §14. Simple, non-conflict-sensitive operations (plain room CRUD, room-manager assignment) remain direct-table-write-plus-RLS, exactly matching existing convention, per "do not create an RPC for every trivial operation."

---

## 5. Reverse Room-Block Conflicts (V1 rule, as specified)

Enforced entirely within `create_room_block()` (§14), inside the same advisory-lock scope as booking writes for that room (§4):

1. Before inserting, query `meeting_room_bookings` for rows with `room_id` matching, `status IN ('hold','pending','confirmed')`, and an overlapping `[start_at,end_at)` (excluding already-expired holds, which the same lazy-expiry step clears first).
2. **If any exist and no override is supplied:** the insert fails (`RAISE EXCEPTION`), naming the conflicting booking IDs in the error detail so the caller can surface them to the manager.
3. **If an override is supplied:** requires (a) a non-null `override_reason` parameter, (b) the acting user to be authorized (room manager for this room, org admin, or super admin — §10), and (c) the RPC itself resolves and records the exact set of impacted booking IDs found in step 1 — stored on the block row as `conflict_override_impacted_booking_ids UUID[]` (§16 schema appendix) alongside the standard override fields. **No impacted booking row is modified in any way** — this satisfies the explicit "no booking is silently modified" rule; a manager who wants to actually resolve the conflict must separately cancel/reschedule the affected bookings through their own RPCs, as a distinct, visible action.
4. The block-creation event (including the override, if any) is audited via the same server-side audit-insert convention as §14/§12.
5. **Automatic reassignment is not implemented** — confirmed absent, per the approved deferral.

This is enforced entirely server-side inside the RPC (which itself runs with no direct-table-INSERT RLS policy available to bypass, per §14's "no direct writes" design for this table) — a direct REST `POST` to `meeting_room_blocks` has no policy permitting it at all (§14), so this logic cannot be routed around.

---

## 6. Booking Completion (Derived, No Cron Job)

**Recommendation: a `STABLE` SQL helper function, not a view and not a cron job.**

```
FUNCTION booking_effective_status(p_status TEXT, p_end_at TIMESTAMPTZ) RETURNS TEXT
  — STABLE (not IMMUTABLE: depends on now()), SQL:
  SELECT CASE WHEN p_status = 'confirmed' AND p_end_at < now() THEN 'completed' ELSE p_status END;
```

- **Why a function over a view:** a function composes cleanly into any context — a plain `SELECT`, an RPC's return shape, a future dashboard-count RPC (mirroring the existing `requests_action_needed_counts()` pattern, §1) — without forcing every caller to `JOIN`/`SELECT FROM` a specific view. A thin convenience view (`meeting_room_bookings_effective AS SELECT *, booking_effective_status(status, end_at) AS effective_status FROM meeting_room_bookings`) can be added on top of the function at zero marginal design cost if the frontend ends up wanting to query it that way — the function is the one piece of logic; the view, if built, is just a wrapper.
- **Why not computed purely in API/JS logic:** the same `now() > end_at` comparison would then need to be duplicated in every API layer file (`js/data/rooms-api.js`, any admin reporting screen, any future RPC) with no single source of truth — a function keeps that logic in exactly one place, consistent with this codebase's general preference for centralizing business rules in Postgres (e.g. `valid_request_status_transition()`, `generate_reference_number()`) rather than JS.
- **Records remain stored as `confirmed`** — no write ever happens to flip a row to `completed` in the database; `completed` is purely a read-time projection. This means `status = 'confirmed'` in a raw query includes both "still upcoming" and "already finished" bookings — any query that needs to distinguish them (e.g. "confirmed and still upcoming" for a room's live availability check) filters on `end_at >= now()` directly rather than on `status` alone; §4's conflict-check logic already does exactly this (an overlap check on `[start_at,end_at)` naturally excludes any booking whose window has fully passed, with no dependency on `status` ever becoming `'completed'`).
- **No `pg_cron` job is added for this**, per the explicit instruction, even though `pg_cron` is already enabled and available (§1) — a deliberate non-use.
- **If reporting/workflow needs later require a real stored `completed` status** (explicitly allowed as a future addition per the approved rule), the migration path is additive: a `pg_cron` job analogous to `check_deadlines()` could sweep `confirmed AND end_at < now()` rows to a stored `completed` status without any schema change, since the column already exists in the CHECK-constrained enum (§3 of `docs/09`).

---

## 7. Room Access Granularity

**V1 rule, restated and resolved:** room access is organization-scoped by default; no per-room access-restriction table is built in V1.

- **`meeting_rooms.org_id`** — the room's owning organization. A user may request/book a room only when their own `users.org_id` equals the room's `org_id` — **no cross-organization room sharing in V1**, matching the approved decision's "external organizations receive no access automatically" and matching MeetFlow's own original scope (a single-org tool, per `docs/01`/`docs/02`) closely enough that no new cross-org sharing concept needs inventing from scratch.
- **Role gate:** any **active** user of that organization whose org has the `rooms` module enabled (Layer 1) may request a room — no narrower default role gate is added, mirroring `is_entry_staff()`'s and `is_prisoner_registry_manager()`'s existing "zero-rows-configured means any org member" fallback shape (§1). This is deliberately the *simplest* default that satisfies the approved decision's four-part gate (module active, module enabled for org, appropriate role, allowed to use the specific room) without inventing a fifth concept.
- **No per-room access-restriction table is recommended for V1** — per this step's own instruction ("do not build complex room ACLs speculatively") and `docs/09` §16 item 2's finding that there is no known current requirement for narrower-than-org-wide room access. If a real need emerges later (e.g. a secure room restricted to specific staff), the *shape* to reach for is the same `entry_sections`-style join table already used elsewhere (§1) — not designed further here, since building it now would be exactly the speculative complexity this step is instructed to avoid.

### Four concepts, explicitly separated

| Concept | Representation |
|---|---|
| **Room owner organization** | `meeting_rooms.org_id` — fixed at room creation, who maintains/administers the physical room. |
| **Booking requester organization** | `meeting_room_bookings.org_id` — denormalized onto the booking row at creation time (mirrors `requests.from_org_id`/`to_org_id`'s existing denormalization convention, §1), always equal to the room's `org_id` in V1 (no cross-org booking), but stored explicitly rather than always re-derived via a join, for RLS-policy simplicity and consistency with how every other CorLink top-level table carries its own `org_id`. |
| **Room manager assignment** | §10 below — composed of org-supervisor default + optional per-room addition, entirely separate from ownership. |
| **Platform super-admin access** | `is_super_admin()` — unconditional override across every organization's rooms/bookings/blocks, identical to its role everywhere else in this schema. |

---

## 8. Manager Authority — Option Evaluation

| Option | Description | Evaluation against CorLink's architecture |
|---|---|---|
| **A — Global permission strings** (`rooms.manage`, `rooms.approve`, `rooms.override_conflicts`) | A granular, named-permission-bit system | **Rejected.** CorLink has no permission-string system anywhere today — `user_assignments.role` is a fixed, small, CHECK-constrained enum, not an extensible bag of permission bits. Introducing one here would be a new architectural primitive with no other user in the codebase, pure speculative complexity for a V1 module. |
| **B — `room_managers` table scoped to individual rooms** | A join table naming specific room-manager users per room | Directly matches the `entry_sections` precedent (§1) in *shape*, but used **alone** it would mean a brand-new room has **zero** managers until someone explicitly grants one — a bootstrapping gap `entry_sections`/`prisoner_registry_section_id` avoid via their "zero rows = fall back to broader default" behavior. Usable, but incomplete on its own. |
| **C — Organization-level room-management roles only** | Any `is_supervisor_or_above()` user manages every room in their org, no per-room granularity at all | Simplest, zero new tables, and satisfies the approved decision's requirements out of the box (works from the moment `organization_modules` enables `rooms` for an org, no separate setup step). Downside: cannot ever narrow management of one specific room to a subset of an org's supervisors — but per `docs/09` §16 item 2, no known V1 requirement demands that narrowing. |
| **D — Minimal combination: org permission (default) + optional room-level assignment (addition only)** | Option C's default always applies; `room_managers` (Option B's table) only ever **adds** non-supervisor managers for a specific room, never restricts | **Recommended.** Ships with zero rows needed in the new table (Option C's simplicity, working day one) while still providing the exact "future-compatible access table" the approved decision explicitly permits building *if* needed — and because the table only ever grants, never restricts, it can never accidentally lock out an org's own supervisors/admins from a room they should obviously be able to manage, avoiding the over-permission/under-permission failure modes on both sides. |

**Recommended V1 approach: Option D.**

- **Default authority:** `is_supervisor_or_above()` **and** `get_my_org_id() = meeting_rooms.org_id` (org-scoped, not global) — an org's supervisors/admins manage every room their own org owns, automatically, with zero configuration.
- **Optional addition:** `meeting_room_managers (room_id UUID REFERENCES meeting_rooms(id) ON DELETE CASCADE, user_id UUID REFERENCES users(id) ON DELETE CASCADE, created_at TIMESTAMPTZ, PRIMARY KEY (room_id, user_id))` — a helper `is_room_manager(p_room_id, p_user_id DEFAULT auth.uid())` composes both: `is_super_admin() OR (is_supervisor_or_above() AND get_my_org_id() = (SELECT org_id FROM meeting_rooms WHERE id = p_room_id)) OR EXISTS (SELECT 1 FROM meeting_room_managers WHERE room_id = p_room_id AND user_id = p_user_id)`.
- Ships in the initial migration but is expected to remain empty for most/all rooms at launch — exercised only when a specific non-supervisor staff member needs to manage one particular room, which is a real but likely rare V1 case.

---

## 9. Self-Approval Enforcement

**Exact server-side check** (inside `approve_booking()`, §14 — never relying on RLS alone, since approval requires the multi-step locked procedure from §4 regardless):

```
v_actor := auth.uid();

IF v_actor IS NULL THEN
  RAISE EXCEPTION 'approve_booking requires an authenticated caller';
  -- Closes the service-role/anonymous-context gap explicitly: a NULL actor would
  -- otherwise make "created_by = v_actor" evaluate to NULL (neither true nor false)
  -- rather than cleanly denying the call, and would leave no accountable actor for
  -- the resulting audit row. Service-role execution of this RPC path is refused
  -- outright — there is no ordinary-approval code path that runs without a real user.
END IF;

IF booking.created_by = v_actor AND NOT (v_is_super_admin_override) THEN
  RAISE EXCEPTION 'Cannot approve your own booking request';
  -- Applies even if v_actor also passes is_room_manager()/is_admin() — the check is
  -- unconditional on identity, not gated behind "unless you're also a manager".
END IF;

IF NOT (is_room_manager(booking.room_id, v_actor) OR is_admin()) THEN
  RAISE EXCEPTION 'Not authorized to approve this booking';
END IF;
```

- **`auth.uid()`** is the sole actor-identity source, matching every existing helper function in this codebase (§1) — never a client-supplied "approved_by" parameter.
- **`created_by`** (booking's own creator field) is the comparison target, matching the approved decision's wording exactly.
- **Super-admin override path:** per the approved rule ("platform super admins may only do so through an explicit override path with a mandatory reason and audit event"), a super admin approving their own booking is **not** the normal `approve_booking()` call — it must go through the same conflict-override machinery as §4/§10 (`v_is_super_admin_override` above is only ever set when the RPC is invoked with an explicit override reason **and** `is_super_admin()` is true — an ordinary admin cannot set it), producing the same `conflict_override_*` fields and audit event as any other override, so "a super admin approved their own request" is never silent or indistinguishable from a normal approval in the audit trail.
- **Service-role behavior:** addressed directly above — the RPC refuses to run for an unauthenticated/service-role caller in the ordinary path. If a legitimate server-side/administrative need to approve on someone's behalf ever exists (not part of V1), it would need its own separate, clearly-named, audited entry point — not a silent behavior of `approve_booking()`.

---

## 10. Conflict-Override Storage

**Recommended fields, stored directly on the affected row** (both `meeting_room_bookings` and `meeting_room_blocks`), per the instruction and consistent with `docs/09` §10/§16:

- `conflict_override BOOLEAN NOT NULL DEFAULT FALSE`
- `conflict_override_reason TEXT`
- `conflict_overridden_by UUID REFERENCES users(id)`
- `conflict_overridden_at TIMESTAMPTZ`
- (on `meeting_room_blocks` specifically, additionally: `conflict_override_impacted_booking_ids UUID[]`, per §5)

**Fits CorLink's conventions:** this mirrors an existing, already-present pattern in this exact schema — a "latest decision recorded directly on the row" field set (e.g. `deadline_extensions.reviewed_by`/`reviewed_at`/`status`, `prisoner_letters`-style single-decision columns, §1) alongside a fully separate, append-only `audit_logs` history. Not a new convention.

**If overrides can occur multiple times on the same row:** yes — e.g. a booking could theoretically be overridden into conflict more than once across its lifecycle (unlikely in practice, but not structurally prevented). **The row stores only the latest override** (a plain overwrite of the four/five fields above on each override event); **`audit_logs` preserves every event**, one row per override action, each carrying its own `notes` describing the specific reason/impacted-IDs at that point in time. This is the same "current-state-on-row, full-history-in-audit" split every other stateful field in this schema already follows (status columns generally, `reviewed_by`/`reviewed_at`, etc.) — no special-casing needed for overrides specifically.

---

## 11. Notification Integration

**[static] existing architecture** (§1, restated with full detail here):

- **Table shape:** `notifications(id, user_id NOT NULL REFERENCES users(id) ON DELETE CASCADE, type TEXT NOT NULL CHECK (...), record_type TEXT NOT NULL, record_id UUID NOT NULL, message TEXT NOT NULL, is_read BOOLEAN DEFAULT FALSE, created_at)`.
- **Supported types today:** `new_request`, `new_response`, `approval_requested`, `draft_returned`, `deadline_warning`, `extension_requested`, `extension_decided`, `new_prisoner_letter`, `letter_replied`, `new_external_correspondence`, `external_correspondence_replied`, `request_cancelled` — a closed CHECK-constrained list, requiring extension for booking events (§16).
- **Recipient model:** one row per (recipient, event) — no fan-out table, no digest/grouping; a single logical event that should notify N users produces N separate `notifications` rows (visible directly in `check_deadlines()`'s `SELECT uid FROM section_user_ids(...)` fan-out pattern).
- **Organization scoping:** not enforced by the `notifications` table itself — scoping happens upstream, in *who gets resolved as a recipient* (via `section_user_ids()`/`org_supervisor_user_ids()`), not via an `org_id` column on the notification row.
- **Read/unread:** `is_read` boolean, own-row `UPDATE` only.
- **Creation mechanism — two paths exist today:** (a) client-side direct insert (`js/data/*.js`, after resolving recipients via `section_user_ids()`), permitted because the INSERT policy is merely `auth.uid() IS NOT NULL` (**not** `user_id = auth.uid()`) — any authenticated user can insert a notification addressed to any other user; (b) server-side `SECURITY DEFINER` function insert (`check_deadlines()`, bypassing RLS as the table owner, §14).
- **Are DB triggers or application APIs the generator today?** Application APIs (path a) are the dominant existing pattern for user-initiated events (new request, approval requested, etc.); only the one scheduled job (`check_deadlines()`) uses the server-side path.

**Recommended V1 events and recipients:**

| Event | Recipient(s) | New `type` value |
|---|---|---|
| Booking submitted | Room manager(s) for that room (§10) | `booking_submitted` |
| Booking approved | Requester (`created_by`) | `booking_approved` |
| Booking rejected | Requester | `booking_rejected` |
| Booking cancelled | The other party (manager(s) if requester cancelled; requester if a manager/admin cancelled) | `booking_cancelled` |
| Booking changed by an authorized manager (reschedule, override) | Requester / any registered internal participants (if `meeting_id` is set and the linked meeting has participants) | `booking_changed` |
| Conflicting request requiring manager attention | Room manager(s) — fires when a second `pending`/`hold` is created for a window another `pending` request already occupies (both still awaiting a decision) | `booking_conflict_attention` |

**Recommendation — deviate deliberately from the existing client-insert pattern for this module:** per this step's explicit instruction ("avoid sending notifications from insecure client-controlled inserts"), booking notifications should be inserted **only from within the new RPCs** (§14), not from client-side `js/data/rooms-api.js` code, even though every *other* CorLink module currently uses the client-insert path. This is deliberate and narrow: it costs nothing extra (the RPCs already run `SECURITY DEFINER` and already need to resolve recipients for the audit trail), and it closes the one real gap in the existing pattern (a malicious or buggy client could otherwise insert an arbitrary `booking_approved` notification without an approval ever having happened) specifically for a new module being built with stricter scrutiny — it is not presented as a retroactive fix for the other modules' existing behavior, which remains outside this step's scope.

---

## 12. Audit Integration

**[static] existing architecture** (§1, full detail):

- **Table shape:** `audit_logs(id, user_id NOT NULL REFERENCES users(id), action TEXT NOT NULL CHECK (...), record_type TEXT NOT NULL CHECK (...), record_id UUID, notes TEXT, ip_address INET, created_at)`.
- **Accepted `action` values today:** `created`, `edited`, `submitted`, `approved`, `returned`, `sent`, `received`, `routed`, `assigned`, `returned_to_sender`, `cancelled`, `extension_requested`, `extension_approved`, `extension_denied`, `viewed`, `login`, `logout`, `login_failed`, `locked`, `password_changed`, `user_created`, `user_deactivated`.
- **Accepted `record_type` values today:** `request`, `response`, `internal_request`, `prisoner_letter`, `deadline_extension`, `user`, `organization`, `section`, `session`, `attachment`, `external_correspondence`.
- **Actor field:** `user_id`, RLS-enforced to equal `auth.uid()` on insert (§1) — no separate "acted on behalf of" field exists anywhere in this schema.
- **Organization field:** none directly on `audit_logs` — org-scoping for the SELECT policy is resolved via a join back to `users.org_id` (`audit_select`, §1), not a denormalized column.
- **Old/new-value storage:** none — `audit_logs` has no `old_value`/`new_value` JSON columns; the free-text `notes` field is the only place additional detail is recorded (e.g. `check_deadlines()`'s deadline-warning message text). This schema is intentionally lightweight, not a full field-level diff log.
- **Helper functions:** none dedicated to writing audit rows (no `logAudit()`-equivalent SQL function exists — that name refers to a client-side JS helper in `js/data/*.js`, not a database object) — every existing audit row is a plain `INSERT`.
- **Insertion permissions:** any authenticated user, self-attributed only (`audit_insert`, §1).
- **Retention:** no expiry/purge mechanism anywhere — append-only and permanent, matching "cancelled and rejected bookings remain available for authorized audit viewing" (`docs/09` §15).

**Recommended new `action`/`record_type` values (CHECK-constraint extensions needed, §16):**

| Concept | `record_type` | `action` values needed |
|---|---|---|
| Rooms | `meeting_room` | `created`, `edited` (reuses existing values) |
| Room blocks | `meeting_room_block` (new) | `created`, `cancelled` (reuse), `conflict_overridden` (new) |
| Bookings | `meeting_room_booking` (new) | `created` (reuse — covers hold + direct-confirm creation), `submitted` (reuse — pending request), `approved` (reuse), `rejected` (new — not currently in the list; `denied`-style rejection exists in other tables like `staff_requests`-adjacent status values but not in this enum), `cancelled` (reuse), `rescheduled` (new), `conflict_overridden` (new) |

`rejected` and `rescheduled` and `conflict_overridden` are genuinely new values not covered by the existing 21-item list — the CHECK constraint on `audit_logs.action` **must be extended** (a real, concrete implementation-time schema change, exact wording deferred to Phase 4's actual migration authoring per `docs/09` §16 item 6). `record_type` similarly needs `meeting_room`, `meeting_room_block`, `meeting_room_booking` added.

**Given §14's RPC-centric design**, audit rows for booking/block state changes are inserted **from within the RPCs** (server-side, `SECURITY DEFINER`, bypassing RLS the same way `check_deadlines()` already does — a proven pattern in this exact codebase, §1) rather than as a separate client-side `logAudit()` call after the fact. This closes the same atomicity gap identified in §11 for notifications, for the same reason, and is likewise a deliberate, narrow deviation from the general client-insert convention used elsewhere — not a claim that the rest of CorLink's audit logging is broken.

---

## 13. Attachment Integration

**[static] confirmed linkage mechanism** (§1): `attachments.record_type` (CHECK-constrained) + `attachments.record_id` (untyped `UUID`, polymorphic — no FK, matching `approvals.record_id`/`user_assignments.scope_id`'s existing polymorphic-reference convention in this schema) + Storage bucket `attachments` (private) with path convention `attachments/{record_type}/{record_id}/{filename}`, and Storage RLS delegated back to the `attachments` table's own `attachments_select` policy via `EXISTS`.

**Confirmed for this step, per the approved decisions:**

- **Bookings receive no attachment support in V1** — `meeting_room_bookings` is not added to `attachments.record_type`'s CHECK list in this phase.
- **Rooms receive no attachment support in V1** — `meeting_rooms` is likewise not added.
- **No new Storage bucket is needed** — the existing private `attachments` bucket, if this ever ships later, would take a new `record_type` value (`meeting_room_booking`) under the same path convention; no new bucket, no new Storage RLS pattern.
- **Meeting attachments (a separate, V1-scoped concept per `docs/03` §2) should reuse this exact system** when the Meetings module itself is built — adding `'meeting'` to `attachments.record_type`'s CHECK list and nothing else structurally new. Not built in this step (Meetings schema is a separate phase, `docs/03` §8 Phase 3) — noted here only to confirm no divergent attachment mechanism is being planned for the Meetings side either.

---

## 14. Recommended Canonical Database Operations

### Evaluated against the listed candidates

| Candidate | Needs locking? | Needs conflict check? | Needs authorization beyond RLS? | Needs audit+notification bundling? | Recommendation |
|---|---|---|---|---|---|
| `create_room_booking` (direct-confirm, by a manager/admin) | Yes | Yes | Yes (manager/admin only) | Yes | **RPC** |
| `create_booking_hold` | Yes | Yes | No beyond module+org gate | Yes | **RPC** |
| `submit_booking_request` (ordinary user → `pending`) | Yes | Yes | No beyond module+org gate | Yes | **RPC** |
| `approve_booking` | Yes | Yes (re-validate window still free) | Yes (manager/admin, self-approval check, §9) | Yes | **RPC** |
| `reject_booking` | No (moving to a non-blocking status can't create a new conflict) | No | Yes (manager/admin) | Yes | **RPC** — qualifies on authorization + audit + notification alone, per this step's own prioritization criteria, even without a locking need |
| `cancel_booking` | No | No | Yes (creator-before-start, or manager/admin with mandatory reason) | Yes | **RPC** — same reasoning as `reject_booking` |
| `reschedule_booking` | Yes | Yes (full re-check against the new window/room) | Yes (creator or manager/admin, subject to the same authorization as the original creation path) | Yes | **RPC** |
| `create_room_block` | Yes | Yes (against bookings, §5) | Yes (room manager/admin) | Yes | **RPC** |
| `cancel_room_block` | No | No | Yes (room manager/admin) | Yes | **RPC** — same reasoning as `cancel_booking`/`reject_booking` |
| `check_room_availability` | No (pure read) | N/A (reads, doesn't write) | No (any module-enabled org member) | No | **RPC recommended for read convenience** (a single call returning free/busy windows, mirroring `requests_action_needed_counts()`'s existing read-only-RPC pattern, §1) — but this one *could* also be a plain `SELECT` against `meeting_room_bookings`/`meeting_room_blocks` under normal SELECT-permissive RLS instead; recommended as an RPC mainly for query-ergonomics (computing free slots server-side) rather than because direct SELECT would be unsafe. |

**9 mutating RPCs total**, all justified individually against the task's own prioritization criteria (locks, conflict checks, authorization, state transitions, audit logging, notifications) — none created merely because "an RPC feels tidier." Every one of the 9 satisfies at least authorization-beyond-RLS **and** audit/notification bundling, even the four (`reject_booking`/`cancel_booking`/`cancel_room_block`, plus arguably `approve_booking`'s non-locking siblings) that don't strictly need the locking machinery.

### Which tables may safely allow direct inserts/updates

| Table | Direct INSERT/UPDATE from the client (RLS-gated, no RPC)? | Reasoning |
|---|---|---|
| `meeting_rooms` | **Yes** — plain RLS (`is_supervisor_or_above()` + org match, or `is_super_admin()`) for INSERT/UPDATE/DELETE, no locking or conflict-check concern at all. Matches `commands`/`departments`/`divisions`/`sections`' existing direct-write convention exactly. | No RPC needed — simple reference-data CRUD. |
| `meeting_room_managers` (§10) | **Yes** — plain RLS, room-manager-or-admin-write, matches `entry_sections`' existing direct-write convention. | Same reasoning — simple assignment-table CRUD. |
| `meeting_room_bookings` | **No — SELECT only.** No INSERT/UPDATE/DELETE RLS policy is granted to any non-owning role at all; every mutation goes exclusively through the 7 RPCs above (which run `SECURITY DEFINER` and therefore bypass RLS internally, the same proven mechanism `check_deadlines()` already uses, §1). | This is the strongest possible guarantee against "direct REST bypass attempts" (explicitly tested in §17) — with no matching policy, Postgres RLS denies the write outright, independent of any application-layer correctness. |
| `meeting_room_blocks` | **No — SELECT only**, same reasoning as bookings (`create_room_block`/`cancel_room_block` own every write). | Same rationale — the reverse-conflict-check requirement (§5) makes this table conflict-sensitive in exactly the same way bookings are. |

---

## 15. RLS Responsibilities

Given §14's design, RLS's job on the two conflict-sensitive tables narrows specifically to **read-access scoping** — write authorization moves into the RPCs themselves:

- **`meeting_room_bookings_select`** — `is_super_admin() OR org_id = get_my_org_id() OR is_room_manager(room_id) OR created_by = auth.uid()`. (Org-wide read visibility for a room's *availability* — even a private/sensitive booking's existence should be visible enough to prevent double-booking attempts, matching `docs/03` §7's "a room's availability is visible org-wide even though a meeting's content may be private" principle carried over from the Meetings design — booking rows carry no confidential content themselves in V1, only scheduling metadata, so no further narrowing is needed here.)
- **`meeting_room_blocks_select`** — same shape, org-wide within the owning org, plus super admin.
- **`meeting_rooms_select`** — org-wide within the owning org (a room's existence/name/capacity is not sensitive), plus super admin.
- **No `anon` policy exists anywhere** — every policy above implicitly requires `auth.uid()`-resolvable helper functions to return non-null/true, and no policy is ever written granting anything to the `anon` role, matching every existing table in this schema (§1's "deny by default" restatement).
- **Module-gate composition**: per `docs/09` §15, every SELECT (and, indirectly, every RPC's internal authorization check) additionally requires `current_user_module_enabled('rooms')` (or the target org's equivalent via `module_enabled_for_org()`) — composed into the same policy expression / RPC precondition, not a separate policy layer, matching how `requests` already composes ownership+section+CC+internal-collab checks into single `USING` expressions (§1).

---

## 16. Required Extensions and Constraints — Schema Appendix

**No executable SQL is included below** — field-level definitions only, per this step's own instruction.

### `meeting_rooms`

| Field | Type | Nullable | Default | FK | Purpose |
|---|---|---|---|---|---|
| `id` | UUID | No | `gen_random_uuid()` | — | PK, matches every table in this schema |
| `org_id` | UUID | No | — | `organizations(id)` | Owning organization (§7) |
| `name` | TEXT | No | — | — | Display name |
| `capacity` | INTEGER | Yes | `0` | — | Optional headcount, mirrors MeetFlow's `rooms.capacity` concept (`docs/08`) |
| `bookable_until` | TIME or INTEGER | Yes | — | — | Optional operating-hours cutoff, renamed from MeetFlow's `end_hour` for clarity (`docs/03` §5) — exact type (a `TIME` vs. an hour-of-day integer) is a minor implementation-time choice, not resolved further here |
| `is_active` | BOOLEAN | No | `TRUE` | — | Reference-data soft-delete convention (§1) |
| `created_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard |
| `updated_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard, `trigger_set_updated_at()` attached |

### `meeting_room_managers` (optional, per §10's recommended Option D — additive-only room-manager grants)

| Field | Type | Nullable | Default | FK | Purpose |
|---|---|---|---|---|---|
| `room_id` | UUID | No | — | `meeting_rooms(id) ON DELETE CASCADE` | Composite PK component |
| `user_id` | UUID | No | — | `users(id) ON DELETE CASCADE` | Composite PK component |
| `created_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard |

(PK: `(room_id, user_id)`, matching `meeting_group_access`/`entry_sections`' existing composite-PK join-table convention, §1.)

### `meeting_room_blocks`

| Field | Type | Nullable | Default | FK | Purpose |
|---|---|---|---|---|---|
| `id` | UUID | No | `gen_random_uuid()` | — | PK |
| `room_id` | UUID | No | — | `meeting_rooms(id) ON DELETE CASCADE` | The blocked room |
| `start_at` | TIMESTAMPTZ | No | — | — | Block window start (§3, §11 of `docs/09`) |
| `end_at` | TIMESTAMPTZ | No | — | — | Block window end; `CHECK (end_at > start_at)` |
| `reason` | TEXT | No | — | — | Required, per `docs/09` §9 |
| `is_active` | BOOLEAN | No | `TRUE` | — | Deactivation without hard delete, per `docs/09` §9 |
| `conflict_override` | BOOLEAN | No | `FALSE` | — | §5/§10 |
| `conflict_override_reason` | TEXT | Yes | — | — | §10 — required only when `conflict_override = TRUE`, enforced by application/RPC logic (a `CHECK` constraint referencing another column's boolean state is expressible directly in Postgres too, e.g. `CHECK (NOT conflict_override OR conflict_override_reason IS NOT NULL)` — recommended as an additional defense-in-depth constraint) |
| `conflict_overridden_by` | UUID | Yes | — | `users(id)` | §10 |
| `conflict_overridden_at` | TIMESTAMPTZ | Yes | — | — | §10 |
| `conflict_override_impacted_booking_ids` | UUID[] | Yes | — | — | §5 — explicit record of which bookings were left in place despite the override |
| `created_by` | UUID | No | — | `users(id)` | Standard actor field |
| `created_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard |
| `updated_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard, `trigger_set_updated_at()` attached |

### `meeting_room_bookings`

| Field | Type | Nullable | Default | FK | Purpose |
|---|---|---|---|---|---|
| `id` | UUID | No | `gen_random_uuid()` | — | PK |
| `org_id` | UUID | No | — | `organizations(id)` | Denormalized requester/owning org, §7 |
| `room_id` | UUID | No | — | `meeting_rooms(id)` | The booked room — deliberately **not** `ON DELETE CASCADE` (a room with booking history should not be silently deletable; room deactivation is `meeting_rooms.is_active = FALSE`, not deletion) |
| `meeting_id` | UUID | Yes | — | `meetings(id)` (Meetings module, later phase) | Optional linkage, per `docs/09` §10 — nullable by design |
| `section_id` | UUID | Yes | — | `sections(id)` | Optional requesting section, for section-scoped visibility/reporting parity with other CorLink modules |
| `status` | TEXT | No | `'hold'` or `'pending'` (depends on which RPC creates the row — no single universal default) | `CHECK (status IN ('hold','pending','confirmed','rejected','cancelled','expired','completed'))` | Per `docs/09` §3. (`'completed'` is included in the CHECK list for future-proofing per §6, even though V1 never writes it.) |
| `start_at` | TIMESTAMPTZ | No | — | — | §3 |
| `end_at` | TIMESTAMPTZ | No | — | — | §3; `CHECK (end_at > start_at)` |
| `timezone` | TEXT | No | `'Indian/Maldives'` | — | `docs/09` §11 — descriptive only, never used in conflict logic |
| `expires_at` | TIMESTAMPTZ | Yes | — | — | Meaningful only while `status = 'hold'`; `docs/09` §6's 10-minute default is computed by the creating RPC (`created_at + interval '10 minutes'`), not a column `DEFAULT` expression (since it must be computed relative to the row's own `created_at`, which itself defaults to `NOW()` — Postgres column defaults cannot reference sibling columns being inserted in the same statement) |
| `created_by` | UUID | No | — | `users(id)` | Requester (§9's self-approval comparison target) |
| `approved_by` | UUID | Yes | — | `users(id)` | Set on `confirmed` transition via approval |
| `approved_at` | TIMESTAMPTZ | Yes | — | — | Paired with above |
| `rejected_by` | UUID | Yes | — | `users(id)` | Set on `rejected` transition |
| `rejected_at` | TIMESTAMPTZ | Yes | — | — | Paired with above |
| `cancelled_by` | UUID | Yes | — | `users(id)` | Set on `cancelled` transition |
| `cancelled_at` | TIMESTAMPTZ | Yes | — | — | Paired with above |
| `cancellation_reason` | TEXT | Yes | — | — | Required only for manager/admin-initiated cancellation (`docs/09` §8), enforceable via the RPC and/or a conditional `CHECK` |
| `conflict_override` | BOOLEAN | No | `FALSE` | — | §4/§10 |
| `conflict_override_reason` | TEXT | Yes | — | — | §10 (same conditional-`CHECK` recommendation as on `meeting_room_blocks`) |
| `conflict_overridden_by` | UUID | Yes | — | `users(id)` | §10 |
| `conflict_overridden_at` | TIMESTAMPTZ | Yes | — | — | §10 |
| `created_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard |
| `updated_at` | TIMESTAMPTZ | No | `NOW()` | — | Standard, `trigger_set_updated_at()` attached |

**Required constraints (in addition to the CHECK columns above):**

- `CHECK (end_at > start_at)` on both `meeting_room_bookings` and `meeting_room_blocks`.
- `valid_booking_status_transition(old_status, new_status)` + `trigger_check_booking_status` (`BEFORE UPDATE OF status`), following the exact §1 pattern, encoding `docs/09` §3's transition table (`hold → {pending,confirmed,cancelled,expired}`, `pending → {confirmed,rejected,cancelled}`, `confirmed → {cancelled,completed}`, all others terminal).
- `EXCLUDE USING gist (room_id WITH =, tstzrange(start_at, end_at, '[)') WITH &&) WHERE (status IN ('pending','confirmed') AND NOT conflict_override)` (§3/§4) — requires `btree_gist` (§2); omitted entirely under the fallback design if unavailable.
- `meeting_room_bookings_conflict_guard()` trigger (§4), `BEFORE INSERT OR UPDATE OF room_id, start_at, end_at, status`.
- Equivalent block-side conflict trigger for the reverse-conflict rule (§5), `BEFORE INSERT ON meeting_room_blocks`.

**Required extension:** `btree_gist` (§2) — optional if the fallback design (advisory-lock-only, no exclusion constraint) is adopted instead.

---

## 17. Migration Execution Order

Sequenced within `docs/03`'s existing Phase 4 (§8 of that document, already updated per the prior step to reflect this readiness work as its content):

1. Enable `btree_gist` (or confirm the fallback design if unavailable) — §2.
2. Create `meeting_rooms` (+ `trigger_set_updated_at`) — no dependency on anything else new.
3. Create `meeting_room_managers` (depends on `meeting_rooms`, `users`).
4. Create `meeting_room_blocks` (depends on `meeting_rooms`, `users`) — including its own conflict-check trigger, which itself depends on `meeting_room_bookings` existing (so this table's trigger is actually attached in step 6, after both tables exist — table creation and trigger attachment can be sequenced independently within one transaction).
5. Create `meeting_room_bookings` (depends on `meeting_rooms`, `sections`, `users`; `meeting_id` FK deferred/nullable-only until the Meetings module's own table exists in a later phase — no hard ordering dependency on Meetings).
6. Attach both conflict-check triggers (booking-side and block-side) and the exclusion constraint, now that both tables exist.
7. Extend `audit_logs.action`/`record_type` and `notifications.type` CHECK constraints (§12/§11) — additive `ALTER TABLE ... DROP CONSTRAINT ... ADD CONSTRAINT` (CorLink's existing convention for CHECK-constraint extension elsewhere in this codebase, matching how Entry's own review-comment work extended `review_comments`'s `record_type` CHECK, per session history).
8. Create the 9 RPCs (§14) — depends on every table/trigger/helper above existing.
9. Add RLS policies (§15) — SELECT-only for the two conflict-sensitive tables, full CRUD-by-role for `meeting_rooms`/`meeting_room_managers`.
10. Add `module_key = 'rooms'`'s `route` value once the frontend ships (a later phase, not this one) — `platform_modules`/`organization_modules` themselves need no schema change at all, only a data update (§1) at that later point.
11. Local Postgres RLS/concurrency verification (§18) before any live application.

No step above depends on live Supabase access to design or write — only to *apply*.

---

## 18. Validation Test Matrix

| # | Test | Expected result |
|---|---|---|
| 1 | Adjacent bookings, room X: 10:00–11:00 then 11:00–12:00 | Both succeed (half-open interval, §3) |
| 2 | Overlapping bookings, room X: 10:00–11:00 then 10:30–11:30 | Second fails (exclusion constraint and/or trigger, depending on status combination) |
| 3 | Concurrent booking creation, two transactions, same room/overlapping window, both `pending` | Exactly one succeeds; the other fails cleanly (no deadlock, no double-commit) — exercises the advisory lock (§4) |
| 4 | Concurrent holds, two transactions, same room/overlapping window | Exactly one succeeds |
| 5 | Expired hold no longer blocks | A `hold` past `expires_at`; a new overlapping `pending`/`confirmed` request against the same window succeeds, and the stale hold is observed flipped to `expired` afterward |
| 6 | Approval after expiry | `approve_booking()` on an expired hold fails with an explicit error, per `docs/09` §6 |
| 7 | Self-approval | A user attempting to approve their own `pending` booking (even while also a room manager/admin for that room) fails, per §9 |
| 8 | Super-admin override | A super admin approving their own booking without the override path fails identically to test 7; with the override path (reason supplied) it succeeds and produces both the row-level override fields and an audit event |
| 9 | Cross-organization access | A user from Org B cannot read, book, approve, or manage a room owned by Org A — verified across `meeting_rooms_select`, `meeting_room_bookings_select`, and every RPC's internal authorization check |
| 10 | Disabled Rooms module | A user of an org where `organization_modules` has `rooms.is_enabled = FALSE` cannot successfully call any of the 9 RPCs or read any Rooms/Booking table row, even if their role would otherwise qualify |
| 11 | Room block over booking | `create_room_block()` targeting a window with an existing active `hold`/`pending`/`confirmed` booking fails without an override; succeeds with a valid override, recording the impacted booking IDs and modifying no booking row (§5) |
| 12 | Booking over room block | A booking-creation RPC targeting a window covered by an active block fails |
| 13 | Cancellation | Creator cancels their own upcoming booking successfully; a manager/admin cancellation without a `cancellation_reason` fails (per `docs/09` §8's mandatory-reason-for-manager-cancellation rule); a started/completed booking is never hard-deleted by any cancellation path |
| 14 | Rescheduling | `reschedule_booking()` changing room and/or time re-runs the full conflict check against the new target and correctly releases any lock-relevant state tied to the old room/window |
| 15 | Direct REST bypass attempts | A raw `POST`/`PATCH`/`DELETE` against `meeting_room_bookings` or `meeting_room_blocks` (bypassing every RPC) is rejected outright by RLS (no matching policy, §14) regardless of the caller's role |
| 16 | Anonymous access | An unauthenticated (`anon`-role) request against any of the three new tables or any of the 9 RPCs is denied |
| 17 | Notification generation | Each of the 6 events in §11 produces exactly the expected `notifications` row(s), addressed to the expected recipient(s), and **no** notification is inserted by a path other than the owning RPC (verified by attempting a direct client-side insert of a `booking_approved` notification and confirming it either fails or — if the general `notifications` INSERT policy still technically permits it — is at minimum never triggered by the RPC's own normal operation, and is a separately-tracked known gap if the general policy is left unchanged, §11) |
| 18 | Audit generation | Each of the 9 RPCs produces exactly the expected `audit_logs` row (`action`/`record_type`/`record_id`/`user_id`), including override events |
| 19 | Rollback safety | Applying, then rolling back (per `docs/rollback/`-style convention already used for Phase 1, session history) the full Phase 4 migration leaves no orphaned FK, no leftover trigger, and zero impact on any existing (non-Rooms) table — mirroring the exact rollback-then-reapply verification already performed for Phase 1 (`docs/07`) |

This matrix should be executed against local Postgres first (this repository's established convention, §1/session history: stub `auth` schema, real `schema.sql`+`rls.sql`+the new patch, hex-only UUID fixture data, `SET LOCAL ROLE`/`SET LOCAL request.jwt.claim.sub` impersonation) before any live Supabase application, exactly as Phase 1 was verified (`docs/07`).

---

## 19. Rollback Considerations

- Every new object (3 tables, 1 optional 4th, ~5 functions, 2 triggers, 9 RPCs, extended CHECK constraints, 1 extension) is strictly additive — no existing table, column, function, or policy is altered or dropped, mirroring Phase 1's own rollback-safety property (`docs/rollback/001-platform-module-foundation.md`).
- A rollback script should, in FK-safe order: drop the 9 RPCs → drop the 2 conflict-guard triggers and the `set_updated_at` triggers on the 3-4 new tables → drop the exclusion constraint (if created) → drop the status-transition trigger/function → drop the CHECK-constraint extensions on `audit_logs`/`notifications` (reverting to their prior constraint definitions) → drop the 3-4 new tables in dependency order (`meeting_room_managers`, `meeting_room_blocks`, `meeting_room_bookings`, then `meeting_rooms`) → leave `btree_gist` enabled (dropping an extension is unnecessary and riskier than leaving an unused, harmless extension enabled — matches how Phase 1's rollback never proposed disabling any extension either).
- **`btree_gist` is not something rollback needs to reverse** — per §2, it has no destructive footprint; leaving it enabled after a rollback is safe and matches this codebase's general bias toward reversible, low-blast-radius changes.

---

## 20. Remaining Blockers

**None that block starting Phase 4 implementation.** The items below are implementation-time details to resolve *during* Phase 4 authoring, not prerequisites that must be resolved *before* Phase 4 can begin — consistent with how `docs/09` §16's items were characterized:

1. `btree_gist` live availability/permission — `[unverified-live]`, §2, with a working fallback design already specified.
2. `bookable_until`'s exact type (`TIME` vs. hour-of-day integer) — §16, a minor field-type choice.
3. Exact final wording of the new `audit_logs.action`/`record_type` and `notifications.type` CHECK-constraint string values — §11/§12, a schema-authoring detail.
4. Whether `check_room_availability` ships as an RPC or a plain scoped `SELECT` — §14, a minor ergonomics choice with no security implication either way.
5. `meeting_id`'s FK target (`meetings(id)`) does not exist yet, since the Meetings module schema is a separate, later phase per `docs/03` §8 — `meeting_room_bookings.meeting_id` should be created nullable with **no FK constraint** initially (or a deferred/added-later FK once `meetings` exists), to avoid Phase 4 depending on a table it doesn't otherwise need.

---

## Final Control (performed before committing)

- **No executable migration was created** — this document contains field-level descriptions and illustrative pseudocode/expressions only (the two explicitly-requested exact snippets — the `btree_gist` read-only diagnostic queries in §2, and the `tstzrange(...)` expression in §3 — are not migrations; neither creates, alters, nor writes anything).
- **No application source file was changed** — confirmed via `git status` before writing (see below).
- **No Supabase write occurred** — the connector was unavailable for the duration of this step; even the read-only live checks in §2 were not executed this session, only documented for later use.
- **MeetFlow was not modified** — not accessed at all this step; every finding is either CorLink-repository-static or restates prior findings from `docs/02`/`docs/08`.
- **Verified live findings vs. static conclusions are distinguished throughout** via the `[static]`/`[unverified-live]` labels introduced in §0 and used consistently in §1/§2.

---

*End of document. No database table was created. No RLS policy was written to a live project. No RPC was deployed. No extension was enabled. No Supabase project was accessed or modified. Nothing was deployed or pushed.*
