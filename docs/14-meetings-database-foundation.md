# Meetings Database Foundation

**Type:** Implementation record for Phase 3 (`docs/03-migration-architecture.md` §8, sequenced after the already-implemented Phase 4 Rooms/Booking foundation). Implements `docs/12-meetings-v1-decisions.md` and `docs/13-meetings-technical-readiness.md`, resolving every implementation-time detail those two documents left open.
**Migration file:** `supabase/patch-meetings-foundation.sql`
**Validation file:** `supabase/validate-meetings-foundation.sql`
**Rollback:** `docs/rollback/003-meetings-foundation.md`
**Date:** 2026-07-22
**Scope actually applied:** Local, disposable PostgreSQL instance only. **Neither the CorLink nor the MeetFlow hosted Supabase project was accessed or modified.** MeetFlow was not touched at all. No frontend code was written or deployed. Nothing was pushed to any remote branch.

---

## 1. Schema

### `meetings`

`id`, `organization_id`, `created_by`, `updated_by` (nullable, auto-set by a new generic `trigger_set_updated_by()` — see §9), `title`, `description`, `meeting_type` (`general`/`interview`/`training`/`operational`/`administrative`/`other`, default `general`), `status` (`draft`/`scheduled`/`cancelled`, default `draft`), `visibility` (`private`/`participants`/`organization`, default `participants`), `location_mode` (nullable, `room`/`external`/`virtual`), `timezone` (default `Indian/Maldives`), `start_at`/`end_at`, `external_location`, `virtual_link` (HTTPS-only), `cancellation_reason`/`cancelled_by`/`cancelled_at`, `created_at`/`updated_at`. Full field-level `CHECK` constraint set exactly as specified in `docs/13` §4/§5, including the bidirectional cancellation-alignment constraint.

### `meeting_participants`

`id`, `meeting_id`, `user_id` (nullable) XOR `external_name` (nullable) + `external_email`/`external_phone`/`external_organization_name`, `participant_role` (`organizer`/`attendee`/`observer`), `invitation_status`, `attendance_status`, `is_organizer` (permanently synchronized with `participant_role = 'organizer'` via `CHECK`), `invited_by`, `removed_at`/`removed_by`/`removal_reason` (soft removal), `notes`, timestamps. Three partial unique indexes: internal dedup (re-addable after removal), external dedup by normalized email, and at-most-one-active-organizer.

### `meeting_room_bookings` extensions

The FK on `meeting_id` (deliberately deferred by the Rooms/Booking migration since `meetings` didn't exist yet) is added. A new partial unique index enforces at most one active (`hold`/`pending`/`confirmed`) linked booking per meeting.

---

## 2. Meeting lifecycle

Stored: `draft`, `scheduled`, `cancelled`. Allowed transitions: `draft → scheduled`, `draft → cancelled`, `scheduled → cancelled` — enforced by `valid_meeting_status_transition()` + a `BEFORE UPDATE OF status` trigger, the third instance of this exact pattern in the schema (after `requests.status` and `meeting_room_bookings.status`). `scheduled` can never return to `draft` — an ordinary correction stays `scheduled`. **`completed` is never stored** — `meeting_effective_status(status, end_at)` is a `STABLE` function computing it at read time only, confirmed via testing: a `scheduled` meeting with a past `end_at` reads as `completed` while its stored `status` column remains unchanged.

---

## 3. Participant model

Single table for internal (`user_id`) and external (`external_name` + optional contact fields) participants, XOR-enforced. The meeting creator is automatically inserted as the sole organizer (`is_organizer = TRUE`, `invitation_status = 'accepted'`) in the same transaction as `create_meeting`. Removal is soft (`removed_at`/`removed_by`/`removal_reason`); a removed participant's row is retained, and the same person can be re-added afterward (confirmed via testing). The sole active organizer cannot be removed (confirmed — `remove_participant` raises an explicit error). Internal duplicates and same-normalized-email external duplicates are rejected with a friendly message (dedup indexes caught via an exception handler); two different external people sharing a name with no email, or different emails, are both allowed (confirmed via testing).

---

## 4. Permission model

Composes the existing two-layer model exactly: Layer 1 (`is_module_active('meetings') AND module_enabled_for_org(...)`, plus `rooms_module_active_for()` additionally for room assignment); Layer 2 (creator manages their own meeting; org-wide, not section-scoped, supervisors/admins manage any meeting in their org — the identical authority model already established for Rooms/Booking's room management; super admins manage across orgs; internal participants read only, subject to `visibility`; external participants have no CorLink identity and therefore no access of any kind). No new permission-string or ACL infrastructure.

---

## 5. RLS

`SELECT`-only on both `meetings` and `meeting_participants` — **no `INSERT`/`UPDATE`/`DELETE` policy exists for either table**, confirmed directly via `pg_policies` (2 total policies across both tables, both `SELECT`). `meetings_select` composes `can_view_meeting()`, which resolves `docs/12` §6's visibility semantics: `private`/`participants` both reduce to creator + active participant + org supervisor/admin + super admin (confirmed identical in practice via testing); `organization` visibility additionally grants any module-enabled org member. `meeting_participants_select` is deliberately narrower — an ordinary participant reads only their own row; full raw-table visibility (including unredacted contact fields) is manager-only.

---

## 6. RPC contracts

Seven RPCs, no `complete_meeting` (completion is derived only): `create_meeting`, `update_meeting`, `cancel_meeting`, `add_participant`, `remove_participant`, `assign_room_booking`, `detach_room_booking`. All `SECURITY DEFINER`, `SET search_path = public, pg_temp`, actor from `auth.uid()` only, refusing a `NULL` actor outright — confirmed via testing that the `anon` role cannot successfully call any of them. Full per-RPC input/output/authorization/error contracts as specified in `docs/13` §9, implemented essentially as designed with one real deviation found and fixed during testing (§10 below).

Participants are added only through `add_participant` — `create_meeting` does not accept an inline participant array, per the resolved "simpler and safer" contract.

---

## 7. Booking integration

`meeting_room_bookings.meeting_id` remains the sole database pointer — `meetings` has no `room_id`/`room_booking_id` column of its own. A new, separate trigger (`meeting_room_bookings_meeting_link_guard()`, kept deliberately independent from the already-shipped, unmodified `meeting_room_bookings_conflict_guard()`) enforces that a linked *active* booking's organization, time, and timezone exactly match its meeting's. `assign_room_booking` delegates to the existing `create_room_booking`/`submit_booking_request` RPCs (branching on `is_room_manager()`) rather than performing a raw `INSERT`, so the conflict engine is never duplicated — confirmed via testing that room-conflict rejection, advisory locking, and the exclusion constraint all continue to function unchanged for meeting-linked bookings.

**One real design bug found and fixed during testing**: the original `assign_room_booking` contract (per `docs/13` §9) exposed `p_start_at`/`p_end_at` as optional override parameters, defaulting to the meeting's own window when not supplied. Testing (concurrency test 1 — two different meetings assigning the same room) immediately hit `ERROR: Booking time does not match its meeting's time` from the meeting-link-guard trigger, because **any caller-supplied value differing from the meeting's own window can never succeed** — the trigger's exact-match requirement makes those parameters structurally incapable of ever being used for anything other than their default. Removed entirely; `assign_room_booking(p_meeting_id, p_room_id)` now always uses the meeting's own `start_at`/`end_at`/`timezone` directly. This is a strict simplification with no loss of real functionality, since the removed parameters could never have succeeded with a different value in the first place.

**One required, additive touch to the already-shipped `reschedule_booking()`**: extended with an optional `p_new_timezone` parameter so a timezone-only `update_meeting` call can sync the linked booking's timezone too — confirmed via a dedicated regression test (T33) that this succeeds and keeps both records' timezone in sync.

---

## 8. Cancellation asymmetry

`cancel_meeting` atomically cancels the meeting and any active linked booking (direct `UPDATE`, not a nested `cancel_booking()` call — the meeting-managing actor's authority may exceed that RPC's own narrower requester-or-room-manager check). An **independent** `cancel_booking()` call (through the Rooms/Booking module directly, not via Meetings) does **not** cancel the meeting — confirmed via testing (T29): the meeting remains `scheduled` with `location_mode` still `'room'`, a documented, deliberate, known limitation (the correct path to keep both records consistent is `detach_room_booking`, which does clear `location_mode`). `detach_room_booking` cancels the active booking, preserves the meeting, and clears `location_mode` to `NULL` — confirmed via testing (T30).

---

## 9. Notable implementation decisions beyond the design documents

- **`trigger_set_updated_by()` did not already exist.** `docs/13` §4 stated it was "already created by Rooms/Booking, generic, not room-specific" — a factual error, confirmed by grepping the entire `supabase/` directory before writing any code: no such function exists anywhere, and `meeting_rooms`/`meeting_room_bookings` have no `updated_by` column at all. Created fresh, generically (not meetings-specific in its own definition, even though its only current caller is `meetings`), matching the pattern `trigger_set_updated_at()` already establishes.
- **A leftover-overload idempotency gap, found twice via testing, fixed both times.** Extending an already-shipped function's signature via `CREATE OR REPLACE` does not replace the old signature — Postgres distinguishes functions by argument list, so the old 4-parameter `reschedule_booking` and (briefly, during drafting) a 4-parameter `assign_room_booking` both would have persisted alongside their new signatures after a rerun. Confirmed directly (`\df` showing 2 rows for each before the fix) and fixed by adding an explicit `DROP FUNCTION IF EXISTS <old-signature>` immediately before each `CREATE OR REPLACE`. Re-verified clean (exactly 1 overload of each) after a full clean rebuild and again after a third reapply.

---

## 10. Attachment integration

Reuses the existing `attachments` table/bucket as-is. `attachments.record_type` gains `'meeting'`. `attachments_select`/`attachments_insert`/`attachments_delete` each gain one new branch calling `can_view_meeting()`/`can_manage_meeting()`, with every one of the 8 pre-existing branches preserved verbatim. Delete authority stays uploader-only for meetings too (the existing table-wide `uploaded_by = auth.uid()` wrapper structurally forces this — widening it would touch all 8 other record types, out of scope, per `docs/12` §14's own documented reasoning). No new Storage bucket, no attachments array, no room or booking attachment support.

---

## 11. Notifications and audit

6 new `notifications.type` values (`meeting_created`, `participant_added`, `meeting_updated`, `room_assigned`, `meeting_cancelled`, `participant_removed`) — `meeting_reminder` deliberately excluded. All 6 confirmed firing correctly via a dedicated multi-participant test, addressed to every active internal participant except the actor, with `meeting_updated` correctly gated on a *meaningful* field change (description-only edits don't fire it).

5 new `audit_logs.action` values (`unassigned`, `participant_added`, `participant_removed`, `attachment_added`, `attachment_removed` — `created`/`edited`/`cancelled`/`rescheduled`/`assigned` already existed from Rooms/Booking, reused not re-added) and 1 new `record_type` value (`meeting`, covering every Meetings event including participant events — `record_id` is always the meeting's own id, keeping one coherent per-meeting timeline rather than splitting across two record types). Confirmed via testing that every RPC produces exactly the expected audit row(s).

---

## 12. Local testing results

Tested against a local, disposable PostgreSQL 16 instance, following the exact required order: bootstrap → Phase 1 → Rooms/Booking → validate Rooms/Booking → Meetings → validate Meetings → rerun Meetings migration → rerun both validations → concurrency tests → rollback tests → reapply → revalidate both.

### Sequential functional tests

Every test in `docs/13` §18's matrix was exercised, including: valid draft/scheduled creation; invalid time ranges, location-mode combinations, and unsafe (`http://`, `javascript:`) virtual-link schemes all rejected; module-disabled denial; creator/supervisor/ordinary-user permission tiers; participant read visibility; duplicate participant rejection (internal and external-by-email); external dedup correctly allowing same-name-different-identity; soft removal and re-add; sole-organizer removal refusal; cancellation terminality; derived completion; one-active-booking-per-meeting; cancellation cascade; the documented cancellation asymmetry; detachment behavior; atomic rescheduling (including a full rollback-under-conflict test — T32 — confirming a reschedule into an already-occupied window rolls back both the meeting's and the booking's changes together); the timezone-only regression test (T33); full 6-type notification fan-out; audit generation; direct-mutation RLS rejection; anonymous denial; and `meeting_participant_list()` redaction (confirmed a privileged caller sees full contact fields, a non-privileged caller sees `NULL` for the same fields on another participant's row).

### Concurrency tests (6 required scenarios, run as genuinely separate `psql` processes, `pg_sleep`-synchronized)

| # | Scenario | Result |
|---|---|---|
| 1 | Two different meetings, same room, overlapping windows, concurrent `assign_room_booking` | Exactly one succeeded; the other failed cleanly on the room conflict check |
| 2 | Two concurrent `assign_room_booking` calls for the *same* meeting, different rooms | Exactly one succeeded; the meeting row's own lock serialized the two attempts, and the loser correctly found the one-active-booking pre-check already tripped |
| 3 | `update_meeting` reschedule racing a separate, unrelated direct room booking for the same room/window | Exactly one succeeded; the reschedule attempt's failure rolled back cleanly, leaving the meeting's title/time completely unchanged |
| 4 | `cancel_meeting` racing an independent `cancel_booking` on the same linked booking | Both completed without error — whichever ran first cancelled the booking; the second (via either path) found no active booking left to touch and cleanly skipped that half of its own work, ending in a fully consistent state (both meeting and booking cancelled) with no double-cancel and no partial state |
| 5 | Two concurrent `add_participant` calls, same internal user | Exactly one succeeded; the other failed cleanly on the dedup index |
| 6 | Two concurrent `add_participant` calls, same normalized external email | Exactly one succeeded, same mechanism as #5 |

All six deterministic, no partial state, no deadlock.

### Idempotency and rollback

- The migration was reapplied three times against the same database with no duplicate objects at any point, **except two real leftover-overload bugs found and fixed during this exact testing** (§9) — confirmed clean (single overload of each affected function) after the fix, across two subsequent reapplications.
- Rollback tested end-to-end, including two distinct real failures found and fixed along the way: a dependency-ordering bug (helper functions dropped before the attachment policies referencing them — fixed by reordering) and a documented prerequisite-check failure (live rows using new enum values — the transaction rolled back atomically both times, confirmed via immediate re-query). After both fixes, rollback succeeded cleanly, `meetings`/`meeting_participants` and all 7 RPCs confirmed absent, `reschedule_booking()` confirmed restored to its exact original signature, and Rooms/Booking confirmed fully intact (`validate-rooms-booking-foundation.sql` passing with zero errors, all pre-existing row counts unchanged).
- **A third real finding, specific to the rollback-then-reapply cycle**: reapplying Meetings immediately after a rollback failed at the FK-recreation step, because booking rows that had been linked to now-deleted meetings still carried those (now-dangling) `meeting_id` values — rollback deliberately never touches booking data. Resolved by nulling dangling `meeting_id` references before reapplying (documented precisely, with the exact required statement, in `docs/rollback/003` §1b). After that cleanup, reapply-and-revalidate succeeded cleanly for both foundations.

---

## 13. Known limitations

- **Independent booking cancellation does not clear a meeting's `location_mode`** — the same class of limitation already documented for Rooms/Booking's own design (`docs/12` §11): fixing it would require reaching back from `meeting_room_bookings` into `meetings` from within the already-shipped Rooms/Booking migration, out of scope for this phase. `detach_room_booking` is the correct, supported path to keep both records consistent.
- **Rollback-then-reapply requires a manual cleanup step if any bookings were linked to meetings at rollback time** — documented precisely in `docs/rollback/003` §1b, including the exact statement to run. Not a limitation of ordinary forward operation, only of a rollback immediately followed by a reapply in the same environment.
- **The Rooms/Booking-side, already-documented `docs/11` §4 limitation** (a bare `timezone`-only `UPDATE` on `meeting_room_bookings` not firing the conflict-guard trigger) is now also relevant to `meeting_room_bookings_meeting_link_guard()`, which watches the same column list plus `meeting_id`/`org_id` — the same reasoning applies (no direct-write RLS policy exists for either role, so this remains reachable only via superuser/service-role bypass, which already bypasses RLS by definition).

---

## 14. Hosted Supabase checks still required (not performed this session)

Per this step's own boundary (local PostgreSQL testing only, no hosted Supabase access):

1. Run `supabase/validate-meetings-foundation.sql` against the live project after applying `patch-meetings-foundation.sql` there (requires `patch-rooms-booking-foundation.sql` already applied).
2. Confirm the live project's `meeting_room_bookings`/`reschedule_booking()` match this document's §2 findings exactly (expected, given `docs/02`'s established zero-drift finding, but not verified live).
3. If Rooms/Booking has not yet been applied to the live project, it must be applied first — this migration hard-depends on it.

---

## 15. Files changed

- `supabase/patch-meetings-foundation.sql` (new)
- `supabase/validate-meetings-foundation.sql` (new)
- `docs/rollback/003-meetings-foundation.md` (new)
- `docs/14-meetings-database-foundation.md` (new, this file)
- `docs/03-migration-architecture.md` (surgical update — Phase 3 marked implemented, see below)

No MeetFlow file was touched. No frontend file was touched. Nothing was pushed.
