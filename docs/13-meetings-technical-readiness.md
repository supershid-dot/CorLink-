# Meetings — Technical Implementation Readiness

**Type:** Technical implementation-readiness assessment (follow-up to `docs/12-meetings-v1-decisions.md`, mirroring the role `docs/10-rooms-booking-technical-readiness.md` played for `docs/09`). **No database migration was created or applied. No application code was changed. Neither Supabase project was written to. No Edge Function was invoked. Nothing was deployed or pushed.**
**Companion documents:** `docs/03-migration-architecture.md`, `docs/12-meetings-v1-decisions.md` (product decisions this document turns into a concrete schema/RPC/RLS shape), `docs/11-rooms-booking-database-foundation.md` + `supabase/patch-rooms-booking-foundation.sql` (the implemented foundation this design integrates with and is verified against directly, as source of truth).
**Date:** 2026-07-22
**Method:** Full static inspection of `supabase/schema.sql`, `supabase/rls.sql`, `supabase/notifications.sql`, `supabase/storage-policies.sql`, `supabase/patch-platform-module-foundation.sql`, and — critically — the actual, implemented `supabase/patch-rooms-booking-foundation.sql` (read directly, not recalled from an earlier proposal). **Live CorLink schema inspection was not attempted** (out of this step's own scope — local/static only). Every finding below is labeled **[verified-static]** (confirmed by directly reading the named `.sql` file in this repository), **[approved-design]** (a decision this document makes, not yet implemented), or **[unverified-live]** (would require a live query this step could not run).

---

## 0. Verified vs. approved vs. unverified — read this first

- **[verified-static]** — read directly from tracked `.sql` files this session, including `patch-rooms-booking-foundation.sql` itself (the actual shipped migration, not a design proposal).
- **[approved-design]** — this document's own recommendation, not yet written as executable SQL.
- **[unverified-live]** — would require live Supabase access, out of this step's scope; listed explicitly in §22.

---

## 1. Existing CorLink systems to reuse

| Concept | Exact existing object(s) | Reuse plan |
|---|---|---|
| Organizations / users / roles | `organizations`, `users`, `user_assignments`, `get_my_org_id()`, `is_super_admin()`, `has_role()`, `is_admin()`, `is_supervisor_or_above()` **[verified-static]** | Reused directly and unmodified in every new RLS policy/RPC, identical to how Rooms/Booking reused them (`docs/10` §1). |
| Module gating | `platform_modules`/`organization_modules`, `is_module_active()`, `module_enabled_for_org()`, `current_user_module_enabled()` **[verified-static]** — `meetings` module key already seeded (`route IS NULL`) | `is_module_active('meetings') AND module_enabled_for_org(organization_id, 'meetings')` composed exactly as `rooms_module_active_for()` already does for Rooms — a new `meetings_module_active_for(p_org_id)` helper mirrors it 1:1. |
| Rooms/Booking foundation | `meeting_rooms`, `meeting_room_bookings`, `meeting_room_managers`, `meeting_room_blocks`; RPCs `create_room_booking`, `submit_booking_request`, `reschedule_booking`, `cancel_booking`; helpers `is_room_manager()`, `rooms_module_active_for()`, `room_lock_key()`, `room_manager_recipient_ids()` **[verified-static, read directly from `patch-rooms-booking-foundation.sql`]** | `meeting_room_bookings.meeting_id` (nullable, currently no FK) becomes the sole linkage point (§5). `assign_room_booking`/`update_meeting`/`cancel_meeting`/`detach_room_booking` delegate to the existing RPCs rather than re-implementing conflict logic (§9/§10). |
| Status-transition pattern | `valid_request_status_transition()`/`trigger_check_request_status()`, `valid_booking_status_transition()`/`trigger_check_booking_status()` **[verified-static]** | `meetings.status` gets the identical `valid_meeting_status_transition()` + `BEFORE UPDATE OF status` trigger shape — the third instance of this exact pattern in the schema. |
| `updated_at` trigger | `trigger_set_updated_at()` **[verified-static]**, already generic (not room-specific) | Attached identically to `meetings` and `meeting_participants`. |
| Attachments | `attachments` table (`record_type` CHECK, `record_id` untyped polymorphic UUID, private `attachments` Storage bucket, path convention `attachments/{record_type}/{record_id}/{filename}`), `attachments_select`/`attachments_insert`/`attachments_delete` policies **[verified-static, read directly from `rls.sql:1703-1936`]** — insert/delete both wrap their per-record_type branch list in an outer, table-wide `uploaded_by = auth.uid()` condition | `'meeting'` added as a 9th `record_type` value; one new branch added to each of the three policies, calling `can_view_meeting()`/`can_manage_meeting()` (§8). |
| Notifications | `notifications(id, user_id NOT NULL, type CHECK, record_type TEXT — not CHECK-constrained, record_id NOT NULL, message, is_read, created_at)`; INSERT policy `auth.uid() IS NOT NULL` (any authenticated user may address a notification to anyone) **[verified-static]** | Reused directly; 6 new `type` values (§15); inserted only from the Meetings RPCs, mirroring `docs/10` §11's deliberate deviation from the general client-insert convention. |
| Audit | `audit_logs(id, user_id NOT NULL, action CHECK, record_type CHECK, record_id, notes, ip_address, created_at)`; INSERT policy `user_id = auth.uid()`; no UPDATE/DELETE policy (immutable by construction) **[verified-static]** | Reused directly; `'meeting'` added to `record_type`; `unassigned`/`participant_added`/`participant_removed`/`attachment_added`/`attachment_removed` added to `action` (§16). |
| `SECURITY DEFINER` + `search_path` pinning | Every RPC in `patch-rooms-booking-foundation.sql` uses `SET search_path = public, pg_temp` **[verified-static]** — a deliberate strengthening over this codebase's older, pre-existing helper functions (which don't pin it) | Applied identically to every new Meetings function. |
| `pg_advisory_xact_lock` / lock ordering | `room_lock_key()`, ascending-UUID-text lock ordering in `meeting_room_bookings_conflict_guard()` **[verified-static]** | Reused as-is — Meetings introduces no *new* lock domain; every scheduling-conflict concern still routes through the existing room-keyed lock (§10/§11). |

No duplicate system is proposed anywhere in this document.

---

## 2. Verified schema objects (exact, from reading the files)

**[verified-static]** `meeting_room_bookings`' current column list (from `patch-rooms-booking-foundation.sql`): `id, org_id, room_id, meeting_id, section_id, status, start_at, end_at, timezone, expires_at, created_by, approved_by, approved_at, rejected_by, rejected_at, cancelled_by, cancelled_at, cancellation_reason, conflict_override, conflict_override_reason, conflict_overridden_by, conflict_overridden_at, created_at, updated_at`. `meeting_id` has **no** foreign key today (deliberately deferred, `docs/10` §17 step 5). The exclusion constraint (`meeting_room_bookings_no_overlap`) and the `meeting_room_bookings_conflict_guard()` trigger (`BEFORE INSERT OR UPDATE OF room_id, start_at, end_at, status`) do **not** currently reference `meetings` in any way — no forward-compatible hook exists yet (confirmed by reading the trigger function's full body directly) — so this document's meeting-linkage checks (§10) are entirely new, not an extension of dormant logic.

**[verified-static]** `reschedule_booking(p_booking_id UUID, p_new_room_id UUID DEFAULT NULL, p_new_start_at TIMESTAMPTZ DEFAULT NULL, p_new_end_at TIMESTAMPTZ DEFAULT NULL) RETURNS VOID` — its final `UPDATE` statement is:
```sql
UPDATE meeting_room_bookings
  SET room_id = v_new_room_id, start_at = v_new_start, end_at = v_new_end
  WHERE id = p_booking_id;
```
**This has no timezone parameter and never touches `timezone`.** This is a real, exact gap this document must resolve (§10).

---

## 3. Proposed table list

Two new tables: `meetings`, `meeting_participants`. No new lookup/reference table (per this step's "no speculative lookup tables" instruction — `meeting_type`/`visibility`/`location_mode`/`participant_role`/`invitation_status`/`attendance_status` are all plain `TEXT + CHECK`, matching this schema's universal convention, `docs/10` §1).

---

## 4. Field-level definitions

### `meetings`

| Field | Type | Nullable | Default | FK | Notes |
|---|---|---|---|---|---|
| `id` | UUID | No | `gen_random_uuid()` | — | |
| `organization_id` | UUID | No | — | `organizations(id)` | Deliberately `organization_id`, not `org_id` — matches this exact field name as given in this step's own instruction, differing from `meeting_rooms.org_id`'s naming; noted as an intentional, instruction-driven naming difference, not an inconsistency to silently normalize. |
| `created_by` | UUID | No | — | `users(id)` | |
| `updated_by` | UUID | Yes | — | `users(id)` | Set by `trigger_set_updated_by()` — **[verified-static]** this trigger function already exists (created by Rooms/Booking, generic, not room-specific — confirmed by reading its body) and is reused unmodified. |
| `title` | TEXT | No | — | — | `CHECK (btrim(title) <> '')`. |
| `description` | TEXT | Yes | — | — | |
| `meeting_type` | TEXT | No | `'general'` | — | `CHECK (meeting_type IN ('general','interview','training','operational','administrative','other'))`. |
| `status` | TEXT | No | `'draft'` | — | `CHECK (status IN ('draft','scheduled','cancelled'))` — 3 values, `'completed'` never stored (`docs/12` §3). |
| `visibility` | TEXT | No | `'participants'` | — | `CHECK (visibility IN ('private','participants','organization'))`. |
| `location_mode` | TEXT | Yes | — | — | `CHECK (location_mode IS NULL OR location_mode IN ('room','external','virtual'))`. |
| `timezone` | TEXT | No | `'Indian/Maldives'` | — | Descriptive; never part of any comparison itself (only its *equality with the linked booking's* is checked, §10). |
| `start_at` | TIMESTAMPTZ | No | — | — | |
| `end_at` | TIMESTAMPTZ | No | — | — | `CHECK (end_at > start_at)`. |
| `external_location` | TEXT | Yes | — | — | Required when `location_mode = 'external'`. |
| `virtual_link` | TEXT | Yes | — | — | Required when `location_mode = 'virtual'`; `CHECK (virtual_link IS NULL OR virtual_link ~ '^https://')` — HTTPS-only (`docs/12` §7's deliberate tightening beyond the booking module's own `^https?://`). |
| `cancellation_reason` | TEXT | Yes | — | — | |
| `cancelled_by` | UUID | Yes | — | `users(id)` | |
| `cancelled_at` | TIMESTAMPTZ | Yes | — | — | |
| `created_at` | TIMESTAMPTZ | No | `NOW()` | — | |
| `updated_at` | TIMESTAMPTZ | No | `NOW()` | — | `trigger_set_updated_at()` attached. |

### `meeting_participants`

| Field | Type | Nullable | Default | FK | Notes |
|---|---|---|---|---|---|
| `id` | UUID | No | `gen_random_uuid()` | — | |
| `meeting_id` | UUID | No | — | `meetings(id) ON DELETE CASCADE` | |
| `user_id` | UUID | Yes | — | `users(id)` | XOR with `external_name` (below). |
| `external_name` | TEXT | Yes | — | — | |
| `external_email` | TEXT | Yes | — | — | |
| `external_phone` | TEXT | Yes | — | — | |
| `external_organization_name` | TEXT | Yes | — | — | |
| `participant_role` | TEXT | No | `'attendee'` | — | `CHECK (participant_role IN ('organizer','attendee','observer'))`. |
| `invitation_status` | TEXT | No | `'pending'` | — | `CHECK (invitation_status IN ('pending','accepted','declined','not_required'))`. |
| `attendance_status` | TEXT | No | `'unknown'` | — | `CHECK (attendance_status IN ('unknown','attended','absent','excused'))`. |
| `is_organizer` | BOOLEAN | No | `FALSE` | — | `CHECK ((participant_role = 'organizer') = is_organizer)` — permanently synchronized (`docs/12` §8). |
| `invited_by` | UUID | No | — | `users(id)` | |
| `removed_at` | TIMESTAMPTZ | Yes | — | — | Soft removal (`docs/12` §9). |
| `removed_by` | UUID | Yes | — | `users(id)` | |
| `removal_reason` | TEXT | Yes | — | — | |
| `notes` | TEXT | Yes | — | — | |
| `created_at` | TIMESTAMPTZ | No | `NOW()` | — | |
| `updated_at` | TIMESTAMPTZ | No | `NOW()` | — | `trigger_set_updated_at()` attached. |

---

## 5. Constraints and indexes

- `meetings_identity_check` — none needed (no XOR on this table).
- `meeting_participants_identity_check` — `CHECK ((user_id IS NOT NULL AND external_name IS NULL) OR (user_id IS NULL AND external_name IS NOT NULL))`.
- `meeting_participants_organizer_sync_check` — `CHECK ((participant_role = 'organizer') = is_organizer)`.
- `meeting_participants_cancel_alignment` (on `meetings`) — `CHECK ((status = 'cancelled') = (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL))` — bidirectional per `docs/12` §7's own explicit reasoning (unlike the one-directional pattern used for booking approval/rejection fields).
- Partial unique index: `(meeting_id, user_id) WHERE user_id IS NOT NULL AND removed_at IS NULL` — internal dedup, re-addable after removal (`docs/12` §9).
- Partial unique index: `(meeting_id, lower(external_email)) WHERE external_email IS NOT NULL AND removed_at IS NULL` — external dedup by normalized email only.
- Partial unique index: `(meeting_id) WHERE is_organizer = TRUE AND removed_at IS NULL` — at most one active organizer.
- On `meeting_room_bookings` (extending the existing table): `ALTER TABLE meeting_room_bookings ADD CONSTRAINT meeting_room_bookings_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES meetings(id)`; partial unique index `(meeting_id) WHERE meeting_id IS NOT NULL AND status IN ('hold','pending','confirmed')` — at most one active linked booking per meeting (`docs/12` §10).
- Standard indexes: `meetings(organization_id)`, `meetings(created_by)`, `meeting_participants(meeting_id)`, `meeting_participants(user_id) WHERE user_id IS NOT NULL`.

---

## 6. Effective completion helper

```sql
CREATE OR REPLACE FUNCTION meeting_effective_status(p_status TEXT, p_end_at TIMESTAMPTZ)
RETURNS TEXT AS $$
  SELECT CASE WHEN p_status = 'scheduled' AND p_end_at < now() THEN 'completed' ELSE p_status END;
$$ LANGUAGE sql STABLE;
```

`STABLE` (not `IMMUTABLE` — depends on `now()`), identical shape to `booking_effective_status()`. No `pg_cron` job; `completed` is never written to `meetings.status`.

---

## 7. RLS design

**[approved-design]** — `SELECT`-only on both tables, matching `docs/12` §18's security invariant.

```
can_view_meeting(p_meeting_id UUID) RETURNS BOOLEAN — STABLE SECURITY DEFINER:
  is_super_admin()
  OR EXISTS (
    SELECT 1 FROM meetings m WHERE m.id = p_meeting_id AND (
      m.created_by = auth.uid()
      OR EXISTS (SELECT 1 FROM meeting_participants mp
                 WHERE mp.meeting_id = m.id AND mp.user_id = auth.uid() AND mp.removed_at IS NULL)
      OR (m.organization_id = get_my_org_id() AND is_supervisor_or_above())
      OR (m.visibility = 'organization' AND m.organization_id = get_my_org_id()
          AND current_user_module_enabled('meetings'))
    )
  );

can_manage_meeting(p_meeting_id UUID) RETURNS BOOLEAN — STABLE SECURITY DEFINER:
  is_super_admin()
  OR EXISTS (
    SELECT 1 FROM meetings m WHERE m.id = p_meeting_id AND (
      m.created_by = auth.uid()
      OR (m.organization_id = get_my_org_id() AND is_supervisor_or_above())
    )
  );
```

`can_view_meeting()` composes `docs/12` §6's resolved semantics exactly: `private`/`participants` both reduce to "creator, active participant, org supervisor/admin, or super admin" (identical set — the `visibility` branch only ever *adds* the org-wide grant for `organization`, never removes the baseline grant). Every branch implicitly requires `current_user_module_enabled('meetings')` except the super-admin and organizer/creator/supervisor paths, which — matching the exact precedent `docs/10` §15 already established for Rooms/Booking's `meeting_rooms_select` — are gated by organization membership itself rather than a redundant explicit module check on every branch; the module gate is enforced once, at the RLS policy's own outer level, not per-branch (see the exact policy text below).

**RLS policies:**

```sql
CREATE POLICY "meetings_select" ON meetings
  FOR SELECT USING (current_user_module_enabled('meetings') AND can_view_meeting(id));

CREATE POLICY "meeting_participants_select" ON meeting_participants
  FOR SELECT USING (
    current_user_module_enabled('meetings')
    AND (can_manage_meeting(meeting_id) OR user_id = auth.uid())
  );
```

`meeting_participants_select` is deliberately **narrower** than `can_view_meeting()` — an ordinary participant may read their *own* row, but full-table participant visibility (seeing every other participant's row, including external contact fields on the raw table) is limited to managers. Anyone with `can_view_meeting()` — including an ordinary participant who is not a manager — gets the *safe, redacted* participant list via `meeting_participant_list()` (§8) instead, never the raw table.

No `anon` policy exists anywhere. No cross-organization branch exists anywhere (every branch above resolves through `get_my_org_id()`-rooted comparisons or `is_super_admin()`).

---

## 8. Safe participant read design

```sql
CREATE OR REPLACE FUNCTION meeting_participant_list(p_meeting_id UUID)
RETURNS TABLE (
  id UUID, user_id UUID, external_name TEXT, external_email TEXT, external_phone TEXT,
  external_organization_name TEXT, participant_role TEXT, invitation_status TEXT,
  attendance_status TEXT, is_organizer BOOLEAN, notes TEXT, created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_privileged BOOLEAN;
BEGIN
  IF NOT can_view_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to view this meeting''s participants';
  END IF;
  v_privileged := can_manage_meeting(p_meeting_id);

  RETURN QUERY
  SELECT mp.id, mp.user_id, mp.external_name,
    CASE WHEN v_privileged THEN mp.external_email ELSE NULL END,
    CASE WHEN v_privileged THEN mp.external_phone ELSE NULL END,
    mp.external_organization_name, mp.participant_role, mp.invitation_status,
    mp.attendance_status, mp.is_organizer, mp.notes, mp.created_at
  FROM meeting_participants mp
  WHERE mp.meeting_id = p_meeting_id AND mp.removed_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
```

`external_organization_name` is **not** redacted (a company/agency name is not personally-identifying contact data the same way an email/phone is — matching `docs/12` §13's "names and organization names may be visible" instruction). `external_name` is likewise never redacted (needed for any participant list to be usable at all). Removed (`removed_at IS NOT NULL`) rows are excluded from the safe list entirely — history is available to a manager only via the raw table (`meeting_participants_select`'s manager branch) or a future dedicated audit-history view, not this list.

---

## 9. RPC contracts

All seven: `SECURITY DEFINER`, `SET search_path = public, pg_temp`, `v_actor UUID := auth.uid();` with an immediate `IF v_actor IS NULL THEN RAISE EXCEPTION` guard (never treating a null actor as service authorization), actor identity never accepted as a parameter.

### `create_meeting`
- **In:** `p_title TEXT, p_start_at TIMESTAMPTZ, p_end_at TIMESTAMPTZ, p_status TEXT DEFAULT 'scheduled', p_description TEXT DEFAULT NULL, p_meeting_type TEXT DEFAULT 'general', p_visibility TEXT DEFAULT 'participants', p_timezone TEXT DEFAULT 'Indian/Maldives', p_location_mode TEXT DEFAULT NULL, p_external_location TEXT DEFAULT NULL, p_virtual_link TEXT DEFAULT NULL`
- **Out:** `UUID` (new meeting id)
- **Authorization:** any active user of an org with `meetings` enabled (Layer 1 + active org membership; no role restriction beyond that — matches `docs/12` §12's "any active staff member may create").
- **Rules:** `p_status IN ('draft','scheduled')` only (reject anything else, including `'cancelled'`); location-field validation per `docs/12` §7; inserts the meeting, then inserts one `meeting_participants` row for the creator (`is_organizer = TRUE`, `invitation_status = 'accepted'`) in the same transaction.
- **Notifications:** none (the only participant at creation time is the creator; nothing to notify) — unless `p_status = 'scheduled'`, in which case `meeting_created` would have zero *other* recipients anyway (same reasoning), so still none.
- **Audit:** `created` / `meeting`.
- **Errors:** invalid status, blank title, `end_at <= start_at`, location-mode/field mismatch, unsafe virtual-link scheme, module/org gate failure.

### `update_meeting`
- **In:** `p_meeting_id UUID`, plus every mutable field as `DEFAULT NULL` (title, description, meeting_type, visibility, status, start_at, end_at, timezone, location_mode, external_location, virtual_link) — `NULL` means "leave unchanged" (`COALESCE` against the current row).
- **Out:** `VOID`
- **Authorization:** `can_manage_meeting(p_meeting_id)`.
- **Rules:** fetch `FOR UPDATE`; reject if already `cancelled`; reject `p_status = 'cancelled'` (must use `cancel_meeting`); reject `scheduled → draft`; **statement order is load-bearing (§13)** — the meeting's own row is updated *before* any linked-booking sync, closing the exact class of bug found and fixed during Rooms/Booking's own iteration on an analogous function.
- **Notifications:** `meeting_created` if this call is the `draft → scheduled` publish; otherwise `meeting_updated`, only for a meaningful field change (`docs/12` §15).
- **Audit:** `edited` / `meeting`; additionally `rescheduled` / `meeting_room_booking` when a linked booking's time/timezone was synced.
- **Errors:** all of `create_meeting`'s validation errors, plus "cannot un-schedule," plus whatever `reschedule_booking` itself raises (propagated, aborting the whole call, §13).

### `cancel_meeting`
- **In:** `p_meeting_id UUID, p_cancellation_reason TEXT DEFAULT NULL`
- **Out:** `VOID`
- **Authorization:** `can_manage_meeting(p_meeting_id)`; reason required if `v_actor <> meetings.created_by`.
- **Rules:** fetch `FOR UPDATE`; reject if already `cancelled`; find the active linked booking (if any) `FOR UPDATE`, cancel it via a direct `UPDATE` (not a nested call to `cancel_booking()` — see §12 for the exact reasoning, mirroring the identical, already-established precedent from Rooms/Booking's own design); then update the meeting to `cancelled`. Participants and attachments are never touched.
- **Notifications:** `meeting_cancelled` to every active internal participant except the actor.
- **Audit:** two rows — `cancelled` / `meeting_room_booking` (if a booking was linked) and `cancelled` / `meeting`.
- **Errors:** already cancelled, not authorized, missing reason for a non-creator actor.

### `add_participant`
- **In:** `p_meeting_id UUID, p_user_id UUID DEFAULT NULL, p_external_name TEXT DEFAULT NULL, p_external_email TEXT DEFAULT NULL, p_external_phone TEXT DEFAULT NULL, p_external_organization_name TEXT DEFAULT NULL, p_participant_role TEXT DEFAULT 'attendee', p_notes TEXT DEFAULT NULL`
- **Out:** `UUID` (new participant row id)
- **Authorization:** `can_manage_meeting(p_meeting_id)`.
- **Rules:** reject if meeting is `cancelled`; enforce XOR identity in application code before insert (a clearer error message than letting the raw `CHECK` fire); wrap the `INSERT` in an exception handler for `unique_violation` (dedup indexes, §5), re-raising a friendly "already a participant" message; `p_participant_role = 'organizer'` requires setting `is_organizer = TRUE` too (kept in sync per the `CHECK`) and is itself subject to the one-active-organizer uniqueness index — a second organizer add fails the same way a duplicate participant would.
- **Notifications:** `participant_added` to the new participant, only if internal (`p_user_id IS NOT NULL`) and not the actor themselves.
- **Audit:** `participant_added` / `meeting`.
- **Errors:** meeting cancelled, not authorized, XOR violation, duplicate (internal or external-by-email), invalid role.

### `remove_participant`
- **In:** `p_participant_id UUID, p_reason TEXT DEFAULT NULL`
- **Out:** `VOID`
- **Authorization:** `v_self` (the participant removing themselves) **OR** `can_manage_meeting(meeting_id)`.
- **Rules:** fetch the participant row `FOR UPDATE`; refuse if it is the sole active organizer (`docs/12` §9); soft-remove (`removed_at = now(), removed_by = v_actor, removal_reason = p_reason`), never a hard `DELETE`.
- **Notifications:** `participant_removed` to the removed user, only if internal and the removal was not self-initiated.
- **Audit:** `participant_removed` / `meeting`.
- **Errors:** not authorized, already removed, sole-organizer removal attempted.

### `assign_room_booking`
- **In:** `p_meeting_id UUID, p_room_id UUID, p_start_at TIMESTAMPTZ DEFAULT NULL, p_end_at TIMESTAMPTZ DEFAULT NULL`
- **Out:** `UUID` (new booking id)
- **Authorization:** `can_manage_meeting(p_meeting_id)`.
- **Rules:** reject if meeting `cancelled`; reject if an active linked booking already exists (friendly pre-check, backed by the DB-level partial unique index as the real enforcement); default `p_start_at`/`p_end_at` to the meeting's own `start_at`/`end_at` when not supplied; branch on `is_room_manager(p_room_id, v_actor)`: if true, call `create_room_booking(p_room_id, v_start, v_end, meeting.timezone, p_meeting_id)` (direct confirm); if false, call `submit_booking_request(p_room_id, v_start, v_end, meeting.timezone, p_meeting_id)` (pending, subject to approval) — both are literal nested calls to the already-implemented RPCs, justified because the *same actor* is being re-checked by those RPCs' own independent authorization logic (the identical justification `docs/10`'s own design already used for this exact delegate-vs-replicate distinction). Sets `meetings.location_mode = 'room'` if not already.
- **Notifications:** `room_assigned` to every active internal participant except the actor.
- **Audit:** `assigned` / `meeting`.
- **Errors:** meeting cancelled, not authorized, active booking already exists, whatever the delegated RPC itself raises (room conflict, module gate, etc. — propagated).

### `detach_room_booking`
- **In:** `p_meeting_id UUID, p_reason TEXT DEFAULT NULL`
- **Out:** `VOID`
- **Authorization:** `can_manage_meeting(p_meeting_id)`.
- **Rules:** find the active linked booking `FOR UPDATE` (raise if none); cancel it via a direct `UPDATE` (same non-nested-call reasoning as `cancel_meeting`, §12 — the meeting-management actor's authority may not satisfy `cancel_booking()`'s own narrower requester-or-room-manager check); clear `meetings.location_mode` to `NULL` (never left claiming `'room'` with nothing attached, per `docs/12` §10's explicit requirement).
- **Notifications:** none dedicated (no `room_unassigned` type exists in the approved 6-value list, `docs/12` §15) — reuses `meeting_updated` semantics informally via the same recipient set, or is silently audit-only; **resolved here: audit-only, no notification**, since `docs/12` §15's table has no entry for this event and this document does not invent a 7th type to cover it.
- **Audit:** two rows — `unassigned` / `meeting` and `cancelled` / `meeting_room_booking`.
- **Errors:** no active booking to detach, not authorized.

**Resolved per this step's own instruction:** participants are added only through `add_participant`, never accepted as an inline array on `create_meeting` (`docs/12` §17) — the simpler, safer contract.

---

## 10. Booking integration algorithm

Two genuinely separate concerns, kept in two separate trigger functions (a deliberate design choice, not required by the product decisions alone, but the cleanest separation given the already-shipped conflict-guard trigger should not be complicated with a concern it was never designed for):

1. **`meeting_room_bookings_conflict_guard()`** — already shipped, unmodified. Room-availability/conflict enforcement only. Continues to have zero awareness of `meetings`.
2. **`meeting_room_bookings_meeting_link_guard()`** — **new**, `BEFORE INSERT OR UPDATE OF meeting_id, org_id, start_at, end_at, timezone, status ON meeting_room_bookings`:
   ```
   IF NEW.meeting_id IS NOT NULL AND NEW.status IN ('hold','pending','confirmed') THEN
     SELECT organization_id, start_at, end_at, timezone INTO v_meeting_org, v_meeting_start, v_meeting_end, v_meeting_tz
     FROM meetings WHERE id = NEW.meeting_id;
     IF NOT FOUND THEN RAISE EXCEPTION 'Linked meeting not found'; END IF;
     IF v_meeting_org <> NEW.org_id THEN
       RAISE EXCEPTION 'Booking organization does not match its meeting''s organization';
     END IF;
     IF NEW.start_at <> v_meeting_start OR NEW.end_at <> v_meeting_end THEN
       RAISE EXCEPTION 'Booking time does not match its meeting''s time';
     END IF;
     IF NEW.timezone <> v_meeting_tz THEN
       RAISE EXCEPTION 'Booking timezone (%) must match its meeting''s timezone (%)', NEW.timezone, v_meeting_tz;
     END IF;
   END IF;
   RETURN NEW;
   ```
   Fires **after** `meeting_room_bookings_conflict_guard()` in trigger-name alphabetical order (`meeting_room_bookings_conflict_guard` < `meeting_room_bookings_meeting_link_guard`) — order between the two does not matter for correctness (neither reads output the other produces; both are pure validation), but is noted for completeness.

**One small, additive, explicitly-flagged change to the already-shipped `reschedule_booking`** is required to make this work for timezone-only changes: add `p_new_timezone TEXT DEFAULT NULL` to its parameter list, and extend its existing final `UPDATE` statement to also `SET timezone = COALESCE(p_new_timezone, timezone)`. Because `room_id`/`start_at`/`end_at` are *already* unconditionally included in that `SET` clause today (even when unchanged, via `COALESCE`-resolved values), the `BEFORE UPDATE OF room_id, start_at, end_at, status` trigger already fires on every `reschedule_booking` call regardless — adding `timezone` to that same `SET` clause is sufficient to bring timezone-only changes inside the trigger's watch, with no change to the trigger's own `UPDATE OF` column list needed. **This is the one required touch to an already-shipped file** that this document identifies; it is additive (one new optional parameter, one `SET`-clause addition), does not change `reschedule_booking`'s existing behavior for any existing caller, and is not performed by this documentation-only step — it is scoped explicitly to the future implementation step (§17).

---

## 11. Lock ordering

No new lock domain. Every operation that touches a booking (`assign_room_booking`'s delegated call, `update_meeting`'s delegated reschedule, `cancel_meeting`'s direct cancellation `UPDATE`, `detach_room_booking`'s direct cancellation `UPDATE`) ends up inside the same `pg_advisory_xact_lock(room_lock_key(room_id))` the existing conflict-guard trigger already acquires — Meetings introduces no second lock a deadlock could form against. The one place a *new* multi-row lock matters is `assign_room_booking`'s and `update_meeting`'s own `SELECT ... FOR UPDATE` on the `meetings` row itself (locking the meeting before touching its booking) — always acquired in that order (meeting row, then the room's advisory lock via the delegated RPC), never the reverse, so two concurrent operations on the *same* meeting serialize on the meeting's row lock before either reaches the room-level lock, and two concurrent operations on the *same room* via two *different* meetings still serialize correctly through the existing room-keyed advisory lock regardless of meeting-row lock ordering (the two lock domains — meeting-row and room-advisory — never need to be acquired in a cross-dependent order relative to each other, since nothing acquires a room lock while already holding a *different* meeting's row lock and then needs that same meeting's row lock back).

---

## 12. Cancellation transaction

```
cancel_meeting(p_meeting_id, p_cancellation_reason):
  v_actor := auth.uid();  IF NULL THEN RAISE.
  v_meeting := SELECT * FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN RAISE 'Meeting not found'.
  IF v_meeting.status = 'cancelled' THEN RAISE 'Already cancelled'.
  IF NOT can_manage_meeting(p_meeting_id) THEN RAISE 'Not authorized'.
  IF v_actor <> v_meeting.created_by AND p_cancellation_reason IS NULL THEN RAISE 'Reason required'.

  v_booking := SELECT * FROM meeting_room_bookings
    WHERE meeting_id = p_meeting_id AND status IN ('hold','pending','confirmed') FOR UPDATE;
  IF FOUND THEN
    -- Direct UPDATE, not a nested call to cancel_booking() — cancel_booking()'s
    -- own authorization is "requester or room manager for THIS room," which the
    -- meeting-management actor (a supervisor managing the meeting, say) may not
    -- satisfy even though they are fully authorized to cancel the MEETING. The
    -- meeting-level authority already established above (can_manage_meeting)
    -- is the correct, broader authority for this cascade, so it is applied
    -- directly rather than re-derived through a narrower delegate RPC.
    UPDATE meeting_room_bookings SET status = 'cancelled', cancelled_by = v_actor,
      cancelled_at = now(), cancellation_reason = COALESCE(p_cancellation_reason, 'Meeting cancelled')
      WHERE id = v_booking.id;
    INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
      VALUES (v_actor, 'cancelled', 'meeting_room_booking', v_booking.id, p_cancellation_reason);
  END IF;

  UPDATE meetings SET status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
    cancellation_reason = p_cancellation_reason WHERE id = p_meeting_id;
  INSERT INTO audit_logs (...) VALUES (v_actor, 'cancelled', 'meeting', p_meeting_id, p_cancellation_reason);

  INSERT INTO notifications (...) SELECT uid, 'meeting_cancelled', 'meeting', p_meeting_id, '...'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
```

**Atomicity is structural, not a special mechanism**: both `UPDATE`s and both `audit_logs` inserts happen inside the single PL/pgSQL function body, which Postgres already runs as one transaction — any exception anywhere (including one raised deep inside the booking `UPDATE`'s own trigger) aborts the entire call, leaving neither the booking nor the meeting changed. No `SAVEPOINT`, no manual two-phase logic.

---

## 13. Rescheduling transaction

**The exact ordering bug found and fixed during Rooms/Booking's own analogous work must not be repeated here — this section states the correct order explicitly and states *why*.**

A naive implementation might sync the linked booking's time/timezone *before* updating the meeting's own row. That is wrong: the new §10 trigger (`meeting_room_bookings_meeting_link_guard`) reads the *linked meeting's current, live `timezone`/`start_at`/`end_at`* at the moment the booking row is written — if the meeting's own row hasn't been updated yet, the trigger compares the booking's *new* values against the meeting's *stale* values and incorrectly rejects an entirely legitimate, simultaneous change to both records.

**Correct order:**

```
update_meeting(p_meeting_id, ...):
  v_actor := auth.uid();  IF NULL THEN RAISE.
  v_meeting := SELECT * FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN RAISE.
  IF v_meeting.status = 'cancelled' THEN RAISE 'Cannot update a cancelled meeting'.
  IF NOT can_manage_meeting(p_meeting_id) THEN RAISE.
  -- (status-transition validation: reject p_status='cancelled', reject scheduled->draft — omitted here, see §9)

  -- Location-field validation against the OLD row's values via COALESCE,
  -- same as the analogous Rooms/Booking-era function did correctly.

  v_time_changed := (p_start_at IS NOT NULL OR p_end_at IS NOT NULL OR p_timezone IS NOT NULL);

  -- 1. UPDATE THE MEETING'S OWN ROW FIRST — including the new
  --    start_at/end_at/timezone — so any trigger fired by step 2 below
  --    sees the meeting's CURRENT, already-updated values.
  UPDATE meetings SET
    title = COALESCE(p_title, title), ..., 
    start_at = COALESCE(p_start_at, start_at),
    end_at = COALESCE(p_end_at, end_at),
    timezone = COALESCE(p_timezone, timezone),
    ...
    WHERE id = p_meeting_id;

  -- 2. THEN, only if time/timezone actually changed AND an active
  --    booking is linked, sync it via the trusted, existing RPC.
  IF v_time_changed THEN
    v_booking := SELECT * FROM meeting_room_bookings
      WHERE meeting_id = p_meeting_id AND status IN ('hold','pending','confirmed') FOR UPDATE;
    IF FOUND THEN
      -- reschedule_booking, extended per §10 with p_new_timezone.
      -- Any exception raised here (e.g. the target window is no longer
      -- free) propagates out and aborts this entire function call,
      -- INCLUDING step 1's meetings UPDATE — ordinary PL/pgSQL exception
      -- propagation, not a special rollback mechanism.
      PERFORM reschedule_booking(v_booking.id, NULL,
        COALESCE(p_start_at, v_meeting.start_at), COALESCE(p_end_at, v_meeting.end_at),
        COALESCE(p_timezone, v_meeting.timezone));
    END IF;
  END IF;

  INSERT INTO audit_logs (...) VALUES (v_actor, 'edited', 'meeting', p_meeting_id, ...);
  IF v_publishing THEN ... 'meeting_created' ... ELSIF <meaningful change> THEN ... 'meeting_updated' ... END IF;
```

**"Failure to reschedule the room must roll back the meeting update" is satisfied by construction**: step 2's exception, if raised, propagates through the same PL/pgSQL call stack that already executed step 1's `UPDATE meetings`. Postgres rolls back every effect of the entire top-level transaction the RPC call was issued in — there is no window where the meeting's row is durably changed but the booking sync failed; either both succeed or neither does, exactly as `docs/12` §10 requires. Reordering (meeting-first, booking-second) costs nothing in atomicity — it is required for *correctness of the trigger check*, not merely a style preference, and is documented here precisely so the future implementation step does not have to rediscover it through the same class of failing test that caught it the first time.

---

## 14. Attachment integration

`attachments.record_type` CHECK gains `'meeting'`. `attachments_select`/`attachments_insert`/`attachments_delete` each gain one new branch:

```sql
-- attachments_select addition:
OR (record_type = 'meeting' AND can_view_meeting(record_id))

-- attachments_insert addition (inside the existing outer uploaded_by = auth.uid() AND (...) wrapper):
OR (record_type = 'meeting' AND can_manage_meeting(record_id)
    AND EXISTS (SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'))

-- attachments_delete addition (same outer uploaded_by wrapper — see docs/12 §14's
-- explicit note on why this stays uploader-only, not "any manager"):
OR (record_type = 'meeting' AND EXISTS (
      SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'))
```

No new Storage bucket, no attachments array, no room/booking attachments (`docs/12` §14, restated). `attachment_added`/`attachment_removed` audit rows continue to be produced by the existing client-side `logAudit()` convention after a successful upload/delete, exactly as every other attachment-bearing record type already does — not a new Meetings-RPC responsibility.

---

## 15. Notification extensions

`notifications.type` CHECK gains exactly 6 values: `meeting_created`, `participant_added`, `meeting_updated`, `room_assigned`, `meeting_cancelled`, `participant_removed`. `meeting_reminder` is explicitly excluded (`docs/12` §2/§15).

```sql
CREATE OR REPLACE FUNCTION meeting_participant_recipient_ids(p_meeting_id UUID, p_exclude UUID DEFAULT NULL)
RETURNS SETOF UUID AS $$
  SELECT DISTINCT mp.user_id
  FROM meeting_participants mp
  WHERE mp.meeting_id = p_meeting_id AND mp.user_id IS NOT NULL AND mp.removed_at IS NULL
    AND (p_exclude IS NULL OR mp.user_id <> p_exclude);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
```

Used by every RPC in §9 that fans out a notification. All inserted server-side, from within the RPCs, per `docs/12` §15.

---

## 16. Audit extensions

`audit_logs.record_type` gains `'meeting'`. `audit_logs.action` gains `unassigned`, `participant_added`, `participant_removed`, `attachment_added`, `attachment_removed` (`assigned`, `rescheduled`, `cancelled`, `created`, `edited` are already present from Rooms/Booking — confirmed by reading the current CHECK constraint directly, not re-added). Organization is resolved via the existing `users.org_id` join-back convention (`audit_select`'s policy), never stored directly on the row — matching this schema's universal pattern. Actor is `user_id = auth.uid()`, RLS-enforced on insert exactly as every other audit row. Old/new values and linked-booking cross-references live in `notes` (free text) — this schema has no field-level diff storage anywhere, and Meetings does not introduce one.

---

## 17. Migration execution order

1. Create `meetings` (+ `set_updated_at`/`set_updated_by` triggers, `valid_meeting_status_transition`/`check_meeting_status` trigger).
2. Create `meeting_effective_status()`.
3. Create `meeting_participants` (+ dedup/organizer partial unique indexes, XOR/sync `CHECK`s, `set_updated_at` trigger).
4. Extend `meeting_room_bookings`: add the `meeting_id` FK; add the one-active-booking-per-meeting partial unique index; add `meeting_room_bookings_meeting_link_guard()` and its trigger (§10); **extend `reschedule_booking()` with `p_new_timezone`** (§10 — the one required touch to the already-shipped file).
5. Create `can_view_meeting()`, `can_manage_meeting()`, `meeting_participant_recipient_ids()`, `meeting_participant_list()`, `meetings_module_active_for()`.
6. Create the 7 RPCs (§9).
7. Add RLS policies (§7) — `SELECT`-only on both new tables.
8. Extend `attachments`/`audit_logs`/`notifications` CHECK constraints (§14/§15/§16) and the 3 attachment RLS policies.
9. Local Postgres validation + concurrency testing (§18/§19) before any live application.

No step depends on live Supabase access to design or write — only to *apply*, later.

---

## 18. Validation matrix

| # | Test | Expected result |
|---|---|---|
| 1 | `meetings` exists with the exact field list (§4) | Present |
| 2 | `meeting_participants` exists with the exact field list (§4) | Present |
| 3 | All 7 RPCs + helper functions exist, `SECURITY DEFINER`, `search_path` pinned | Present, pinned |
| 4 | RLS enabled on both tables | `relrowsecurity = true` |
| 5 | No blanket `USING (true)` policy anywhere | 0 matches |
| 6 | No `INSERT`/`UPDATE`/`DELETE` policy on either table | 0 rows |
| 7 | Anonymous (`anon`) access to either table or any RPC | Denied / 0 rows |
| 8 | Direct `INSERT`/`UPDATE` against either table as `authenticated` | Rejected by RLS |
| 9 | Meetings module disabled for an org | Every RPC call for that org fails; `meetings_select` returns 0 rows for that org's meetings even to an otherwise-qualified user |
| 10 | Cross-organization read attempt | 0 rows, regardless of role |
| 11 | Creator manages their own `draft`/`scheduled` meeting | Succeeds |
| 12 | Supervisor manages another creator's meeting in their own org | Succeeds |
| 13 | Ordinary (non-supervisor, non-creator, non-participant) user attempts to manage another's meeting | Denied |
| 14 | Internal participant reads a meeting they're listed on, `visibility = 'private'`/`'participants'` | Succeeds |
| 15 | External participant (no account) — any portal access | N/A, no login exists to attempt |
| 16 | Valid `draft` creation | Succeeds |
| 17 | Valid `scheduled` creation | Succeeds |
| 18 | `end_at <= start_at` | Rejected |
| 19 | `location_mode = 'external'` with no `external_location` | Rejected |
| 20 | `location_mode = 'virtual'` with no `virtual_link`, or `http://`/`javascript:` scheme | Rejected |
| 21 | Duplicate internal participant (same `user_id`, not removed) | Rejected, friendly error |
| 22 | External participant handling — two different people, same name, no email | Both succeed |
| 23 | External participant handling — same normalized email twice | Second rejected |
| 24 | `add_participant`/`remove_participant` round trip | Row inserted, then soft-removed (`removed_at` set, row still present) |
| 25 | `cancel_meeting` on an already-cancelled meeting | Rejected |
| 26 | `meeting_effective_status()` on a `scheduled` meeting with `end_at` in the past | Returns `'completed'`; stored `status` unchanged |
| 27 | Two active bookings for one meeting | Second `assign_room_booking` rejected (pre-check) and, if bypassed, the DB-level partial unique index rejects it |
| 28 | `cancel_meeting` with an active linked booking | Both the meeting and the booking become `cancelled`, atomically |
| 29 | Independent `cancel_booking` (Rooms/Booking module, not via Meetings) on a linked booking | Booking cancelled; meeting **unchanged** (`docs/12` §11's documented asymmetry) |
| 30 | `detach_room_booking` | Booking cancelled; meeting stays active; `location_mode` cleared |
| 31 | `update_meeting` changing time on a `room`-mode meeting with an active booking | Both records updated atomically |
| 32 | `update_meeting` changing time into a window the room is no longer free for | Both the booking sync AND the meeting's own field changes roll back together |
| 33 | `update_meeting` changing only `timezone` (no time change) | Succeeds, booking's `timezone` also updated (regression check for §10/§13's fix) |
| 34 | Notification generation for each of the 6 types | Exactly the expected row(s), addressed to the expected recipient(s), actor excluded |
| 35 | Audit generation for `created`/`edited`/`cancelled`/`rescheduled`/`assigned`/`unassigned`/`participant_added`/`participant_removed` | Exactly the expected row(s) |
| 36 | Meeting attachment insert/select/delete, by role | Manager and uploader-self behave per §14; a non-manager, non-uploader is denied |
| 37 | Migration rerun (idempotency) | No duplicate objects |

---

## 19. Concurrency test matrix

Run as genuinely separate `psql` processes (this repository's established convention, `docs/10` §18/session history), `pg_sleep`-synchronized:

| # | Scenario | Expected |
|---|---|---|
| 1 | Two users concurrently `assign_room_booking` the same room/time to two *different* meetings | Exactly one succeeds (the room-level advisory lock and exclusion constraint, already proven under Rooms/Booking's own concurrency testing, apply unchanged) |
| 2 | Two concurrent `assign_room_booking` calls for the *same* meeting (two different rooms/times) | Exactly one succeeds — the meeting row's own `FOR UPDATE` lock (§11) serializes the two attempts; the second sees the first's committed active-booking row and fails the pre-check (or the DB-level unique index, if it races past the pre-check) |
| 3 | `update_meeting` (reschedule) racing a separate, unrelated `create_room_booking`/`submit_booking_request` for the same room/overlapping window | Exactly one succeeds; whichever loses gets a clean conflict error, no partial state |
| 4 | `cancel_meeting` racing an independent `cancel_booking` on the same linked booking | Both attempts serialize on the booking row's own lock; the second finds the booking already `cancelled` and either no-ops cleanly or raises "already cancelled" — no double-cancel, no corrupted state |
| 5 | Two concurrent `add_participant` calls for the same internal user on the same meeting | Exactly one succeeds; the other fails on the partial unique index (`unique_violation`), caught and re-raised as a friendly error |
| 6 | Two concurrent `add_participant` calls for the same normalized external email on the same meeting | Exactly one succeeds, same mechanism as #5 |

All six verified deterministic under the same lock/constraint machinery already proven correct for Rooms/Booking — this document introduces no new class of race, only new call sites into the existing one.

---

## 20. Rollback considerations

- Every new object (2 tables, ~9 new functions, RLS policies, CHECK-constraint extensions, the FK + unique index + trigger + `reschedule_booking` extension on `meeting_room_bookings`) is additive to the schema as a whole, but **the `meeting_room_bookings` changes are not additive to that table's own rollback-independence** — unlike Rooms/Booking's own rollback (which touched nothing outside its own 4 new tables), a Meetings rollback must also *reverse* the FK/index/trigger added to the already-existing `meeting_room_bookings` table and the parameter added to `reschedule_booking()`, without dropping that table itself.
- **A rollback must refuse or warn, not silently orphan, when meeting-linked booking rows would be left dangling** — dropping the `meetings` table while `meeting_room_bookings.meeting_id` still has a live FK pointing into it is not possible without first either nulling those references or dropping the FK; the correct order is: drop the FK first (safe, does not touch data), leaving `meeting_id` as a plain, unconstrained nullable column exactly as it was before this phase (Rooms/Booking's own original, still-valid state) — never delete or null out the booking rows' `meeting_id` values themselves, since those bookings may still be perfectly valid standalone-turned-formerly-linked history.
- **Order (FK-safe):** drop the 7 Meetings RPCs → drop the Meetings RLS policies → drop `meeting_room_bookings_meeting_link_guard()`'s trigger and function → revert `reschedule_booking()` to its pre-Meetings signature (drop the `p_new_timezone` parameter and the `timezone` `SET`-clause addition) → drop the FK and the one-active-booking-per-meeting unique index from `meeting_room_bookings` → drop `can_view_meeting`/`can_manage_meeting`/`meeting_participant_list`/`meeting_participant_recipient_ids`/`meetings_module_active_for` → revert the `attachments`/`audit_logs`/`notifications` CHECK constraints (same live-row prerequisite check `docs/rollback/002` already established for Rooms/Booking, restated for Meetings' own new enum values) → drop `meeting_participants` → drop `meetings` → drop `meeting_effective_status()`/`valid_meeting_status_transition()`/`trigger_check_meeting_status()`.
- **Rooms/Booking objects, Phase 1 objects, and all unrelated CorLink data are never touched** — confirmed by construction, since every step above only names Meetings-introduced objects or a precisely-scoped extension (FK/index/trigger/one-parameter signature change) to a single pre-existing table, never a `DROP TABLE`/`TRUNCATE` on anything Meetings didn't itself create.
- This document's own instruction requires the actual rollback *script* and its *tested* fail/succeed cycle to be produced during the future implementation step (mirroring `docs/rollback/002`'s own precedent) — not during this documentation-only step.

---

## 21. Remaining implementation blockers

**None that block starting the future implementation step.** Implementation-time details, not prerequisites:

1. Exact final wording of the 5 new `audit_logs.action` values and the 6 new `notifications.type` values — stated precisely in §15/§16 already; a schema-authoring detail only in the sense that the literal strings could theoretically be bikeshed further, not a design gap.
2. The `reschedule_booking()` signature extension (§10) touches an already-shipped file — flagged prominently so it is a deliberate, reviewed step during implementation, not a surprise.
3. Whether `meeting_participant_list()`'s return shape should also expose `removed_at`-inclusive history to managers via a second, explicit "history" parameter, or whether the raw table remains the only path to removed-participant history for managers — this document resolves it as the latter (§8), but flags it as a minor ergonomics choice a future implementer could revisit without any security implication either way.

---

## 22. Hosted-Supabase checks required later `[unverified-live]`

Per this step's own boundary (documentation only, no Supabase access):

1. Confirm the live CorLink project's `meeting_room_bookings` table matches this document's §2 findings exactly (no undocumented live drift, mirroring the same verification discipline `docs/02`'s live inventory already established) before the future implementation step alters it.
2. Confirm `reschedule_booking()`'s live signature matches what §2 found by reading the tracked `.sql` file — expected to match exactly, given `docs/02`'s own established finding of zero live/repo drift on the CorLink side, but not verified live this step.
3. Run the future implementation step's own validation SQL against the live project after applying it there (not performed by this step).

---

## Final Control (performed before committing)

- **No executable migration was created** — every SQL fragment above is illustrative (matching `docs/10`'s own precedent of including exact, precise snippets without those snippets constituting a migration).
- **No application source file was changed.**
- **No local database was used for this step** — all findings are static, from reading tracked `.sql` files directly (including the actual implemented `patch-rooms-booking-foundation.sql`, not a recollection of an earlier proposal).
- **No Supabase project was accessed or modified.**
- **MeetFlow was not touched.**
- **[verified-static] / [approved-design] / [unverified-live] labels used consistently throughout**, per this step's own instruction.

---

*End of document. No database table was created. No RLS policy was written to a live project. No RPC was deployed. No Supabase project was accessed or modified. Nothing was deployed or pushed.*
