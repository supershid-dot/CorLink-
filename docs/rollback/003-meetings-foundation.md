# Rollback — 003: Meetings Database Foundation

Companion to `docs/14-meetings-database-foundation.md`. Explains how to undo this phase (`supabase/patch-meetings-foundation.sql`) if it needs to be reversed after being applied. As of this document's creation, the migration has **not** been applied to any Supabase project — it has only been applied to, and tested against, a local disposable PostgreSQL instance.

Unlike the Rooms and Booking rollback (`docs/rollback/002`), this rollback is **not** purely additive to a self-contained set of new tables — it must also *reverse* two small, deliberate extensions this phase made to the already-existing `meeting_room_bookings` table and to the already-shipped `reschedule_booking()` RPC, without dropping either the table or the function itself. This document is scoped to exactly that footprint: `meetings`, `meeting_participants`, the 7 Meetings RPCs, the Meetings-only helper functions, the `meeting_link_guard` trigger, the extension to `meeting_room_bookings` (FK + one-active-booking index), the extension to `reschedule_booking()`, the 3 attachment RLS policies' `'meeting'` branch, and the 4 extended CHECK constraints. It does not touch `organizations`, `users`, `requests`, `external_correspondence`, `meeting_rooms`, or any other pre-existing or Rooms/Booking-phase table or data.

---

## 1. Prerequisite checks (must pass before running §2)

### 1a. No live row uses a Meetings-introduced enum value

Same class of prerequisite as `docs/rollback/002` §1, restated for this phase's own new values. Before running §2, confirm this returns zero rows for all four:

```sql
SELECT id, type FROM notifications WHERE type IN (
  'meeting_created', 'participant_added', 'meeting_updated',
  'room_assigned', 'meeting_cancelled', 'participant_removed'
);
SELECT id, action FROM audit_logs WHERE action IN (
  'unassigned', 'participant_added', 'participant_removed',
  'attachment_added', 'attachment_removed'
);
SELECT id, record_type FROM audit_logs WHERE record_type = 'meeting';
SELECT id FROM attachments WHERE record_type = 'meeting';
```

If any rows are returned, either delete them (acceptable if this rollback is happening because the whole phase is being abandoned, since `meetings`/`meeting_participants` are about to be dropped anyway) or reconsider whether a full rollback is appropriate.

### 1b. Dangling `meeting_id` references — a real, tested finding, not a hypothetical

**This rollback deliberately does not touch `meeting_room_bookings` data** — per its own design principle, a booking's `meeting_id` value is preserved as history even after the FK constraint enforcing it is dropped (§2 step 5). This is correct for a rollback that is never followed by a reapply. **It is not automatically safe if Meetings is reapplied afterward**, because `meetings.id` values are `gen_random_uuid()` — a fresh `meetings` table can never regenerate the same UUIDs a dropped one had. Confirmed directly during this phase's own rollback-then-reapply testing: reapplying `patch-meetings-foundation.sql` failed at the `meeting_room_bookings_meeting_id_fkey` step with `insert or update on table "meeting_room_bookings" violates foreign key constraint ... Key (meeting_id)=(...) is not present in table "meetings"`, because 4 booking rows (3 already-cancelled/historical, 1 still-active `pending`) still carried `meeting_id` values from before the rollback.

**Required before reapplying Meetings after a rollback** (not required for the rollback itself — only for a subsequent reapply):

```sql
-- Null out any meeting_id values that no longer resolve to a real
-- meeting (safe: meeting_room_bookings.meeting_id is nullable, and a
-- booking with a stale reference to a since-removed meeting is more
-- correctly represented as a standalone booking than as a booking
-- linked to nothing).
UPDATE meeting_room_bookings SET meeting_id = NULL
WHERE meeting_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM meetings m WHERE m.id = meeting_room_bookings.meeting_id);
-- If `meetings` doesn't exist at all at this point (a full rollback
-- with no reapply attempted yet), every non-NULL meeting_id is
-- definitionally dangling:
-- UPDATE meeting_room_bookings SET meeting_id = NULL WHERE meeting_id IS NOT NULL;
```

## 2. Remove the new database objects safely

Run as a superuser/service-role connection, in this exact order. **Dependency-ordering note found during testing**: `attachments_select`/`attachments_insert`/`attachments_delete` reference `can_view_meeting()`/`can_manage_meeting()` (added by this phase's own extension of those policies) — those policies **must** be reverted to their pre-Meetings shape *before* the helper functions are dropped, not after. A first attempt at this rollback that dropped the helper functions first failed with `cannot drop function can_view_meeting(uuid) because other objects depend on it` — the transaction rolled back atomically (confirmed via an immediate re-query showing nothing had changed), and the corrected order below fixes it.

```sql
BEGIN;

-- 1. Drop the 7 Meetings RPCs.
DROP FUNCTION IF EXISTS create_meeting(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS update_meeting(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS cancel_meeting(UUID, TEXT);
DROP FUNCTION IF EXISTS add_participant(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS remove_participant(UUID, TEXT);
DROP FUNCTION IF EXISTS assign_room_booking(UUID, UUID);
DROP FUNCTION IF EXISTS detach_room_booking(UUID, TEXT);

-- 2. Drop the Meetings RLS policies.
DROP POLICY IF EXISTS "meetings_select" ON meetings;
DROP POLICY IF EXISTS "meeting_participants_select" ON meeting_participants;

-- 3. Drop the meeting-link-guard trigger and function.
DROP TRIGGER IF EXISTS meeting_link_guard ON meeting_room_bookings;
DROP FUNCTION IF EXISTS meeting_room_bookings_meeting_link_guard();

-- 4. Revert reschedule_booking() to its pre-Meetings (Rooms/Booking)
--    signature and body verbatim — the 5-parameter version is
--    dropped first (CREATE OR REPLACE alone would leave two
--    overloads, not replace one with the other), then the original
--    4-parameter version is restored so Rooms/Booking is left exactly
--    as patch-rooms-booking-foundation.sql shipped it.
DROP FUNCTION IF EXISTS reschedule_booking(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT);
CREATE OR REPLACE FUNCTION reschedule_booking(
  p_booking_id UUID,
  p_new_room_id UUID DEFAULT NULL,
  p_new_start_at TIMESTAMPTZ DEFAULT NULL,
  p_new_end_at TIMESTAMPTZ DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_booking meeting_room_bookings;
  v_new_room meeting_rooms;
  v_new_room_id UUID;
  v_new_start TIMESTAMPTZ;
  v_new_end TIMESTAMPTZ;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'reschedule_booking requires an authenticated caller';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  IF v_booking.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'Only a pending or confirmed booking can be rescheduled (status: %)', v_booking.status;
  END IF;
  IF NOT (v_booking.created_by = v_actor OR is_room_manager(v_booking.room_id, v_actor) OR is_admin()) THEN
    RAISE EXCEPTION 'Not authorized to reschedule this booking';
  END IF;

  v_new_room_id := COALESCE(p_new_room_id, v_booking.room_id);
  v_new_start := COALESCE(p_new_start_at, v_booking.start_at);
  v_new_end := COALESCE(p_new_end_at, v_booking.end_at);
  IF v_new_end <= v_new_start THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;

  IF v_new_room_id <> v_booking.room_id THEN
    SELECT * INTO v_new_room FROM meeting_rooms WHERE id = v_new_room_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Target room not found or inactive';
    END IF;
    IF v_new_room.org_id <> v_booking.org_id THEN
      RAISE EXCEPTION 'Cannot reschedule a booking to a room in a different organization';
    END IF;
  END IF;

  UPDATE meeting_room_bookings
    SET room_id = v_new_room_id, start_at = v_new_start, end_at = v_new_end
    WHERE id = p_booking_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'rescheduled', 'meeting_room_booking', p_booking_id);

  IF v_actor = v_booking.created_by THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'booking_changed', 'meeting_room_booking', p_booking_id,
      'A room booking has been rescheduled by its requester.'
    FROM room_manager_recipient_ids(v_new_room_id, v_actor) AS uid;
  ELSIF v_booking.created_by IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_booking.created_by, 'booking_changed', 'meeting_room_booking', p_booking_id,
      'Your room booking has been rescheduled.');
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 5. Drop the FK and the one-active-booking-per-meeting unique index
--    from meeting_room_bookings — restores meeting_id to a plain,
--    unconstrained nullable column exactly as Rooms/Booking shipped
--    it. Booking rows' meeting_id VALUES are never modified here
--    (see §1b for why a reapply afterward needs its own cleanup step).
ALTER TABLE meeting_room_bookings DROP CONSTRAINT IF EXISTS meeting_room_bookings_meeting_id_fkey;
DROP INDEX IF EXISTS meeting_room_bookings_one_active_per_meeting;

-- 6. Revert attachments_select/insert/delete to their pre-Meetings
--    shape (8 branches, no 'meeting' branch) — MUST happen before
--    step 8 drops can_view_meeting/can_manage_meeting, which these
--    policies reference.
DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
        )
    ))
    OR (record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr
      JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR irr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            irr.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    ))
    OR (record_type = 'external_correspondence' AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_entry_staff(ec.org_id)
          OR ec.to_section_id IN (SELECT my_section_ids())
          OR ec.assigned_to = auth.uid()
          OR ec.entered_by  = auth.uid()
        )
    ))
    OR (record_type = 'external_correspondence_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr
      JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND (
          ec.to_section_id IN (SELECT my_section_ids())
          OR ecr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id))
          OR (ecr.status = 'sent' AND (is_entry_staff(ec.org_id) OR ec.entered_by = auth.uid()))
        )
    ))
  );

DROP POLICY IF EXISTS "attachments_select_cc" ON attachments;
CREATE POLICY "attachments_select_cc" ON attachments
  FOR SELECT USING (
    record_type IN ('request', 'response') AND is_cc_recipient(record_type, record_id)
  );

DROP POLICY IF EXISTS "attachments_insert" ON attachments;
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
    )
  );

DROP POLICY IF EXISTS "attachments_delete" ON attachments;
CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE USING (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
    )
  );

-- 7. Revert the CHECK-constraint extensions to their pre-Meetings
--    (post-Rooms/Booking) definitions. Fails here if §1a was skipped
--    and a live row still uses a new value.
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'prisoner_letter', 'internal_request', 'prisoner_reply',
    'internal_reply', 'external_correspondence', 'external_correspondence_reply'
  ));

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned',
    'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking'
  ));

-- 8. NOW safe to drop the Meetings-only helper functions (no more
--    policy references them after step 6).
DROP FUNCTION IF EXISTS can_view_meeting(UUID);
DROP FUNCTION IF EXISTS can_manage_meeting(UUID);
DROP FUNCTION IF EXISTS meeting_participant_list(UUID);
DROP FUNCTION IF EXISTS meeting_participant_recipient_ids(UUID, UUID);
DROP FUNCTION IF EXISTS meetings_module_active_for(UUID);

-- 9. Drop the 2 new tables.
DROP TABLE IF EXISTS meeting_participants;
DROP TABLE IF EXISTS meetings;

-- 10. Drop the remaining standalone functions.
DROP FUNCTION IF EXISTS meeting_effective_status(TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS valid_meeting_status_transition(TEXT, TEXT);
DROP FUNCTION IF EXISTS trigger_check_meeting_status();
DROP FUNCTION IF EXISTS trigger_set_updated_by();

COMMIT;
```

**This is safe and non-destructive to Rooms/Booking, Phase 1, and all unrelated CorLink data**: every dropped object is exclusively new (or, for `reschedule_booking()`, restored to its exact pre-Meetings shipped state) and exclusively created by this phase. `meeting_room_bookings`, `meeting_rooms`, `meeting_room_managers`, `meeting_room_blocks`, and every one of the 9 original Rooms/Booking RPCs are never dropped — confirmed directly (§4).

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any pre-existing table, or anything wildcard-based) — the explicit list above is the entire footprint of this phase.

## 3. What was actually tested (this session, local Postgres only)

- **Dependency-ordering failure confirmed real and fixed**: the first rollback attempt (helper functions dropped before the attachments policies referencing them) failed with `cannot drop function can_view_meeting(uuid) because other objects depend on it`; the entire transaction rolled back atomically (confirmed unchanged via immediate re-query). The corrected order (§2, revert the policies first) succeeded.
- **Prerequisite-check failure confirmed real**: with live test rows present (4 notifications carrying new `meeting_*`/`participant_*`/`room_assigned` types, 27 audit rows carrying new record types/actions), the corrected rollback script still failed — this time at `notifications_type_check` — and again rolled back atomically with zero partial effect. Succeeded cleanly once those rows were deleted.
- **Dangling-reference reapply failure confirmed real** (§1b): reapplying `patch-meetings-foundation.sql` immediately after a successful rollback failed at the FK-recreation step, because 4 `meeting_room_bookings` rows still carried `meeting_id` values from meetings the rollback had just dropped. Resolved by nulling those dangling references first (§1b's exact statement), after which the reapply succeeded cleanly.
- **Clean removal confirmed**: `to_regclass()` for both tables returned `NULL`; all 7 RPCs, all 5 Meetings-only helper functions, and `trigger_set_updated_by` confirmed absent from `pg_proc`; `reschedule_booking()` confirmed restored to its exact original 4-parameter signature.
- **Rooms/Booking confirmed fully intact after rollback**: `supabase/validate-rooms-booking-foundation.sql` run immediately after the rollback passed with zero errors; `organizations` (2 rows), `users` (7 rows), `meeting_rooms` (3 rows), and `meeting_room_bookings` (5 rows) all matched their pre-rollback counts exactly.
- **Reapply-and-revalidate confirmed**: after the dangling-reference cleanup, reapplying `patch-meetings-foundation.sql` recreated all objects cleanly, and both `supabase/validate-rooms-booking-foundation.sql` and `supabase/validate-meetings-foundation.sql` passed with zero errors on the reapplied database.

## 4. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Requests, Entry, Prisoner Correspondence, and Administration are all reachable exactly as before this phase.
- Rooms/Booking continues to function exactly as `docs/11` shipped it — room CRUD, hold/pending/confirmed booking lifecycle, room blocks, and all 9 original RPCs, including `reschedule_booking()` under its restored original signature.
- `SELECT COUNT(*) FROM organizations;`, `SELECT COUNT(*) FROM users;`, `SELECT COUNT(*) FROM meeting_rooms;`, and `SELECT COUNT(*) FROM meeting_room_bookings;` match their pre-rollback values exactly.
- `supabase/validate-meetings-foundation.sql`'s queries against `meetings`/`meeting_participants` return "relation does not exist"-style errors after a full rollback — confirming clean removal.
