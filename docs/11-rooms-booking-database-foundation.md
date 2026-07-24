# Rooms and Booking Database Foundation

**Type:** Implementation record for Phase 4 (`docs/03-migration-architecture.md` §8) of the MeetFlow → CorLink migration. Implements `docs/09-rooms-booking-v1-decisions.md` and `docs/10-rooms-booking-technical-readiness.md` exactly, resolving every implementation-time question those two documents left open (docs/09 §16, docs/10 §20).
**Migration file:** `supabase/patch-rooms-booking-foundation.sql`
**Validation file:** `supabase/validate-rooms-booking-foundation.sql`
**Rollback:** `docs/rollback/002-rooms-booking-foundation.md`
**Date:** 2026-07-22
**Scope actually applied:** Local, disposable PostgreSQL instance only. **Neither the CorLink nor the MeetFlow hosted Supabase project was accessed or modified.** MeetFlow was not touched at all. No frontend code was written or deployed. Nothing was pushed to any remote branch.

---

## 1. What was built

Four new tables, a hybrid conflict-prevention mechanism, 10 RPCs, and role-gated RLS — the full V1 Rooms/Booking database layer described in `docs/09`/`docs/10`.

### Tables

| Table | Purpose |
|---|---|
| `meeting_rooms` | The bookable room catalogue. `org_id`, `name`, `capacity`, `bookable_until`, `is_active`, `created_by`. |
| `meeting_room_managers` | Additive-only per-room manager grant (`room_id`, `user_id`, `assigned_by`) — org-wide supervisors/admins already manage every room in their org automatically; this table only ever *adds* a non-supervisor manager for one specific room, never restricts (docs/10 §8 Option D). |
| `meeting_room_blocks` | Administrative unavailability windows. `room_id`, `start_at`/`end_at`, `reason` (required), `is_active` (soft-deactivation), full conflict-override field set. |
| `meeting_room_bookings` | The single canonical bookings table — `status IN ('hold','pending','confirmed','rejected','cancelled','expired','completed')`, no separate hold/pending/confirmed tables (docs/09 §1). `meeting_id` is nullable with **no foreign key** — the `meetings` table doesn't exist yet (a separate, later, explicitly-authorized phase); adding the FK is future work once that table exists. |

### Statuses and lifecycle (docs/09 §2/§3, unchanged from spec)

`hold → {pending, confirmed, cancelled, expired}`, `pending → {confirmed, rejected, cancelled}`, `confirmed → {cancelled, completed}`. All other states are terminal. Enforced by `valid_booking_status_transition()` + a `BEFORE UPDATE OF status` trigger, the same pattern already used for `requests.status` elsewhere in this codebase. **`completed` is never written** — `booking_effective_status(status, end_at)` is a `STABLE` function computing it at read time only; no `pg_cron` job exists for this (docs/10 §6).

### Conflict prevention (docs/09 §7, docs/10 §4)

Hybrid design, exactly as specified:

1. **Exclusion constraint** (`EXCLUDE USING gist (room_id WITH =, tstzrange(start_at,end_at,'[)') WITH &&) WHERE (status IN ('pending','confirmed') AND NOT conflict_override)`) — enforced by Postgres itself, immune to any application bug or direct-API bypass.
2. **`meeting_room_bookings_conflict_guard()` trigger** — `BEFORE INSERT OR UPDATE OF room_id, start_at, end_at, status`, covers everything the constraint structurally cannot: `hold` rows (time-dependent expiry), cross-table room-block conflicts, and the override escape hatch. Acquires a `pg_advisory_xact_lock` keyed by room UUID (ascending-text-order locking when two rooms are involved, to avoid deadlock on a reassignment), lazily expires stale holds, then checks the incoming row against every other currently-blocking row for that room (`pending`/`confirmed`, or a non-expired `hold`) **and** against active `meeting_room_blocks`.
3. **`meeting_room_blocks_conflict_guard()` trigger** — the reverse-conflict rule (docs/09 §16 item 4, resolved by docs/10 §5): a block cannot be created over an existing active booking unless an authorized override is supplied. No booking row is ever modified by this path — the impacted booking IDs are recorded on the block row (`conflict_override_impacted_booking_ids`) for a manager to act on separately.
4. **Override escape hatch** — a transaction-local `app.booking_override` flag, set only by the authorized RPC path immediately before the write and cleared immediately after, checked alongside a mandatory `conflict_override_reason`/`conflict_overridden_by` on the row itself — never a bare client-settable parameter alone.

### RPCs (docs/10 §14 — 9 mutating + 1 read-only)

`create_booking_hold`, `submit_booking_request`, `create_room_booking`, `approve_booking`, `reject_booking`, `cancel_booking`, `reschedule_booking`, `create_room_block`, `cancel_room_block`, and the read-only `check_room_availability`. All `SECURITY DEFINER`, `SET search_path = public, pg_temp`, actor identity from `auth.uid()` only (never client-supplied), refuse a `NULL` actor outright. `meeting_room_bookings` and `meeting_room_blocks` carry **no INSERT/UPDATE/DELETE RLS policy for any role** — every mutation goes exclusively through these RPCs, matching docs/10 §14's "strongest possible guarantee against direct REST bypass" design.

A few implementation decisions not fully pinned down by docs/10, resolved here:

- **`approve_booking` accepts both `hold` and `pending` bookings** — a manager may fast-track an existing hold straight to `confirmed`, or approve a `pending` request; an expired hold is rejected with an explicit error either way. This single RPC covers both docs/10 §18 test 6 ("approval after expiry fails") and the ordinary approval path without needing an 11th RPC.
- **Self-approval override and conflict override share one mechanism** (`p_override_reason` on `approve_booking`/`create_room_block`) but are recorded distinctly: the `conflict_override_reason`/`conflict_overridden_by`/`conflict_overridden_at` fields are always populated when an override reason is supplied (so a super admin approving their own booking is never silent in the audit trail, per docs/10 §9), while the `conflict_override` **boolean** is only set `TRUE` by the trigger when the row actually needed constraint-exemption from a real scheduling conflict — confirmed via testing (T8) that a self-approval override with no real conflict correctly leaves `conflict_override = FALSE` while still recording the reason/actor/timestamp.
- **`booking_conflict_attention` notification type is not fired by any RPC** — docs/10 §11 describes it as firing "when a second pending/hold is created for a window another pending request already occupies," but docs/09 §3's own "pending blocks availability" rule (a deliberate, approved decision) means a second pending/hold for an already-pending window is rejected outright by the exclusion constraint/trigger before it can ever exist as a row — the scenario this notification describes cannot occur under the approved blocking model. The CHECK-constraint value is included for forward compatibility (e.g. if a future policy change makes `pending` non-blocking) but nothing in this migration triggers it. Documented here as an explicit, deliberate non-implementation, not a silent gap.
- **Rejection/cancellation reasons are stored in `audit_logs.notes`**, not a dedicated column — `meeting_room_bookings` has no `rejected_reason` field in docs/10's own schema appendix (§16), matching the existing codebase convention that `audit_logs.notes` is the one place free-text detail is recorded (docs/10 §12).
- **Room manager authority is org-wide, not section-scoped** — `is_room_manager()` checks for the `mcs_admin`/`authority_admin`/`supervisor` role in *any* active assignment for the room's org, regardless of which section that assignment is scoped to, exactly matching docs/10 §8 Option D's "an org's supervisors/admins manage every room their own org owns, automatically, with zero configuration."

### Notifications and audit (docs/10 §11/§12)

Inserted **only from within the RPCs**, never client-side — a deliberate, narrow deviation from the rest of CorLink's client-insert convention, specifically closing the gap where a malicious/buggy client could otherwise insert an arbitrary `booking_approved` notification without an approval ever having happened (docs/10 §11's own stated rationale). 6 new `notifications.type` values, 3 new `audit_logs.action` values, 3 new `audit_logs.record_type` values — all additive `ALTER TABLE ... DROP CONSTRAINT ... ADD CONSTRAINT`, matching this codebase's existing CHECK-extension convention.

### RLS (docs/09 §15, docs/10 §15)

- `meeting_rooms` — org-wide SELECT (module-gated), INSERT/UPDATE restricted to org supervisors/admins/super admins. No DELETE policy — deactivate via `is_active`, matching the existing `commands`/`departments`/`divisions`/`sections` convention.
- `meeting_room_managers` — SELECT scoped to the room's own org; INSERT/DELETE restricted to a room manager or admin, with an explicit same-org check on the grant's target user.
- `meeting_room_bookings` / `meeting_room_blocks` — **SELECT only**, no write policy of any kind. `meeting_room_bookings_select` composes org membership, `is_room_manager()`, and own-creation, all gated behind `current_user_module_enabled('rooms')`.

---

## 2. Attachments — not extended (per approved scope)

Per docs/09 §13/§14 and docs/10 §13: bookings and rooms receive **no** attachment support in V1. `attachments.record_type`'s CHECK constraint is untouched by this migration. (Meeting attachments are a separate, later, explicitly-scoped concept once the Meetings phase builds `meetings` — noted in docs/10 §13 as reusing this same system with zero new mechanism, not built here.)

---

## 3. Local testing results

Tested against a local, disposable PostgreSQL 16 instance (this repository's established convention: a stub `auth` schema/`auth.uid()`, `authenticated`/`anon` NOLOGIN roles, the real `schema.sql` + `rls.sql` + `notifications.sql` (with `pg_cron`/`CREATE EXTENSION pg_cron` stubbed out — not available on plain local Postgres) + `patch-platform-module-foundation.sql` + this migration, loaded verbatim, plus hex-only synthetic UUID fixture data). `btree_gist` enabled successfully with no issue.

### Sequential functional tests (docs/10 §18 test matrix)

| # | Test | Result |
|---|---|---|
| 1 | Adjacent bookings (10:00–11:00, 11:00–12:00) | Both succeeded (half-open interval) |
| 2 | Overlapping bookings, sequential | Second correctly rejected by the exclusion constraint |
| 5 | Expired hold no longer blocks | A new overlapping request succeeded once the hold's `expires_at` passed; the stale hold was observed flipped to `expired` |
| 6 | Approval after expiry | `approve_booking()` on an expired hold failed with an explicit error |
| 7 | Self-approval | A supervisor could not approve their own `pending` request, despite holding room-manager authority |
| 8 | Super-admin override | Self-approval without an override reason failed identically to test 7; with a reason, it succeeded, recording `conflict_override_reason`/`conflict_overridden_by`/`conflict_overridden_at` |
| 9 | Cross-organization access | An HRCM user could not book an MCS room, and saw 0 MCS rooms in `meeting_rooms_select` |
| 10 | Disabled Rooms module | An HRCM user could not book HRCM's **own** room, since HRCM has `rooms` disabled (org-scoped, not merely cross-org) |
| 11 | Room block over booking | Failed without an override; succeeded with one, correctly recording the impacted booking ID and leaving the booking row itself completely untouched |
| 12 | Booking over an active block | Rejected outright |
| 13 | Cancellation | Creator cancelled their own upcoming booking with no reason required (including when the creator also held manager authority — see the bug fixed below); a manager cancelling someone else's booking without a reason was rejected; with a reason, it succeeded |
| 14 | Rescheduling | Rescheduling into an already-booked window failed with a full re-check; rescheduling into a free window succeeded |
| 15 | Direct REST bypass | A raw `INSERT` against `meeting_room_bookings` was rejected outright by RLS (no matching policy) |
| 16 | Anonymous access | The `anon` role saw 0 rows from `meeting_rooms`; every RPC refused a `NULL` actor |
| 17 | Notification generation | `booking_submitted` correctly fanned out to every org-wide supervisor/admin plus the room's explicit manager grant, deduplicated; `booking_approved` correctly notified the requester |
| 18 | Audit generation | Each RPC produced exactly the expected `audit_logs` row (`submitted`, `approved`, etc.) |

### Concurrency tests (docs/10 §18 tests 3/4, run as genuinely separate `psql` processes with `pg_sleep`-synchronized writes)

| Test | Result |
|---|---|
| Two concurrent `hold` creations, overlapping window, same room | Exactly one succeeded; the other failed cleanly; no deadlock |
| Two concurrent `pending` submissions (`submit_booking_request`), overlapping window | Exactly one succeeded; the other failed cleanly |
| Concurrent `pending` submission vs. `hold` creation, overlapping window (regression check) | Exactly one succeeded — confirmed the trigger's combined check (`status IN ('pending','confirmed') OR (status='hold' AND not expired)`) correctly rejects a new `hold` against an already-committed `pending` row under real concurrency, not just sequentially |

### A real bug found and fixed during testing

`cancel_booking()`'s original logic checked `v_is_manager` (room-manager-or-admin authority) **before** checking whether the actor was the booking's own creator, so a room manager who created their own booking was routed into the "manager cancelling — reason required" branch instead of the "creator cancelling their own booking — no reason required" branch. **Fixed** by checking `created_by = v_actor` first, unconditionally, regardless of `v_is_manager` — the mandatory-reason rule is specifically for a manager/admin acting on someone *else's* booking. Reconfirmed via a targeted retest: a manager creating and cancelling their own booking now succeeds with no reason; a manager cancelling a different user's booking still requires one.

### Idempotency and rollback

- Re-running `patch-rooms-booking-foundation.sql` a second time against the same database produced no duplicate objects — identical table/column/constraint/trigger/policy/function counts before and after.
- Rollback tested end-to-end: the script correctly **failed** on its first attempt (live test rows still carried new enum values — the documented prerequisite in `docs/rollback/002` §1), left the database completely unchanged (confirmed via an immediate re-query), then **succeeded** cleanly once those rows were cleared. Full removal confirmed (`to_regclass()` returns `NULL` for all 4 tables; all 10 RPCs and 9 helper functions absent from `pg_proc`); `btree_gist` correctly left enabled. Reapply-and-revalidate after rollback reproduced an identical structure. See `docs/rollback/002-rooms-booking-foundation.md` for the full script and results.

---

## 4. Known limitations

- **A bare `UPDATE meeting_room_bookings SET timezone = ...` (touching only the `timezone` column) does not fire the conflict-guard trigger** — it only fires on `UPDATE OF room_id, start_at, end_at, status`. This is a narrow, deliberately-scoped gap, not believed to be exploitable: `meeting_room_bookings` has no direct-write RLS policy for any ordinary role (every write goes through the RPCs), so reaching this gap requires either superuser/service-role direct access (which already bypasses all RLS by definition) or a hypothetical future RPC that updates only `timezone` in isolation (none of the 10 RPCs in this migration do). Flagged here rather than silently left undocumented; not fixed in this phase since it would require touching an already-tested trigger's column-watch list for a currently-unreachable scenario.
- **`booking_conflict_attention` notification type exists in the CHECK constraint but is never fired** — see §1 above for the full reasoning (the scenario it describes cannot occur under docs/09 §3's approved "pending blocks" rule).
- **`meeting_room_bookings.meeting_id` has no foreign key** — deliberate, since the `meetings` table doesn't exist yet (docs/10 §17 step 5). Adding the FK is a small, additive follow-up once the Meetings database phase creates that table.
- **`bookable_until`'s exact type** was implemented as `TIME` (docs/10 §20 item 2 left this as a minor open choice between `TIME` and an hour-of-day integer) — not currently read by any RPC or constraint in this migration, purely descriptive metadata for a future frontend.

---

## 5. Hosted Supabase checks still required (not performed this session)

Per this step's own boundary (local PostgreSQL testing only, no hosted Supabase access):

1. Confirm `btree_gist` is enableable on the live CorLink Supabase project — expected to work (Supabase's curated extension allowlist already includes it, and this project's migration role already successfully self-served `pg_cron` the same way, per docs/10 §2), but not verified live.
2. Run `supabase/validate-rooms-booking-foundation.sql` against the live project after applying the migration there.
3. Confirm no naming collision with any object that may have been added to the live project outside of tracked `.sql` files since the last live inventory (`docs/02`).

---

## 6. Files changed

- `supabase/patch-rooms-booking-foundation.sql` (new)
- `supabase/validate-rooms-booking-foundation.sql` (new)
- `docs/rollback/002-rooms-booking-foundation.md` (new)
- `docs/11-rooms-booking-database-foundation.md` (new, this file)
- `docs/03-migration-architecture.md` (surgical update — Phase 4 marked implemented, see below)

No MeetFlow file was touched. No frontend file was touched. Nothing was pushed.
