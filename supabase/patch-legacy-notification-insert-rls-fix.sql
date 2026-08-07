-- ============================================================
-- CAP-003 Phase 1.0A — Legacy notification INSERT-RLS correction.
--
-- Fixes a pre-existing defect identified during CAP-003 Phase 1.0
-- architecture review (docs/78 §2.3): the legacy `notifications` table's
-- INSERT policy,
--
--   CREATE POLICY "notif_insert" ON notifications
--     FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
--
-- checks only that the caller is authenticated -- never that `user_id`
-- is the caller, never that the caller has any relationship to
-- `record_type`/`record_id`, and never validates `message` content.
-- Reproduced directly against disposable local Postgres: an
-- authenticated user in one organization can insert an arbitrary,
-- fabricated notification for an arbitrary user in a different
-- organization, with an unrelated/nonexistent record reference.
--
-- Scope analysis (full repository grep of every `INSERT INTO
-- notifications` call site) found this defect affects exactly one real
-- code path: the client-side `NotificationsAPI.notify()` helper
-- (js/data/notifications-api.js), called from Entry, Requests, Prisoner
-- Letters, Internal Collaboration, and review-comments client code via
-- a raw `db.from('notifications').insert(rows)`. Every other
-- `INSERT INTO notifications` in this codebase (Meetings, Rooms, Tasks,
-- task-dependencies, check_deadlines()) lives inside its own
-- SECURITY DEFINER RPC, which already executes as the function owner
-- and is therefore never gated by this table's own RLS INSERT policy
-- regardless of what this patch changes -- those call sites are
-- structurally unaffected by this correction.
--
-- Repository evidence also proves `user_id = auth.uid()` alone is NOT
-- a sufficient replacement: `NotificationsAPI.notify()` is legitimately
-- called with recipients other than the caller in every module that
-- uses it (section supervisors, an assignee, a request's original
-- creator, etc.), including genuine cross-organization notification
-- (requests.to_org_id/from_org_id routing; prisoner_letters'
-- from_prison_id/to_org_id two-organization model -- external_
-- correspondence, by contrast, is single-org only, confirmed by its
-- own schema). A same-org-only rule would break both of these
-- evidenced, legitimate cross-organization flows.
--
-- Correction: replace the direct client INSERT path with one narrow,
-- SECURITY DEFINER RPC that resolves and validates every recipient
-- server-side before inserting -- a recipient must share the caller's
-- own organization, or the caller must supply a `record_type`/
-- `record_id` referencing a REAL `requests` or `prisoner_letters` row
-- whose own from/to organization columns place BOTH the caller and the
-- recipient as parties to that specific record. No other cross-
-- organization allowance exists. `js/data/notifications-api.js`'s
-- `notify()` is updated to call this RPC instead of the raw table
-- insert -- its own external signature/behavior is unchanged, so
-- every one of its ~30 existing call sites across Entry, Requests,
-- Prisoner Letters, Internal Collaboration, and review comments
-- continues to work unmodified.
--
-- Out of scope, deliberately: the 30-value `notifications.type` closed
-- enum (CAP-003's later migration/cutover concern, not this security
-- fix), any new durable notification architecture, any outbox/worker
-- infrastructure, and any change to `notif_select`/`notif_update`
-- (both already correctly scoped to `user_id = auth.uid()` and require
-- no change -- see docs/79).
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── The insecure policy is dropped outright, not narrowed. All
--    client-side notification creation now goes through
--    create_legacy_notification() below instead; no direct INSERT
--    grant/policy for authenticated or anon remains on this table. ───
DROP POLICY IF EXISTS "notif_insert" ON notifications;

-- ─── create_legacy_notification — the one new, narrow, server-
--    authoritative creation boundary. Every recipient is validated
--    before any row is inserted; a single invalid recipient rejects
--    the whole call (never a partial/silent-skip insert for this
--    security-boundary function, unlike CAP-003's own future
--    recipient-resolution design, which is explicitly not built here).
CREATE OR REPLACE FUNCTION create_legacy_notification(
  p_user_ids UUID[],
  p_type TEXT,
  p_record_type TEXT,
  p_record_id UUID,
  p_message TEXT
) RETURNS INTEGER AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_recipient UUID;
  v_recipient_org UUID;
  v_inserted INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_legacy_notification requires an authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_user_ids IS NULL OR array_length(p_user_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one recipient user id is required' USING ERRCODE = '22023';
  END IF;
  IF p_type IS NULL OR btrim(p_type) = '' OR p_record_type IS NULL OR btrim(p_record_type) = ''
     OR p_record_id IS NULL OR p_message IS NULL OR btrim(p_message) = '' THEN
    RAISE EXCEPTION 'type, record_type, record_id, and message are all required' USING ERRCODE = '22023';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller is not an active user' USING ERRCODE = '42501';
  END IF;

  -- Deduplicate the recipient list up front so a duplicate id can never
  -- be counted twice against the loop below or inserted twice.
  FOR v_recipient IN SELECT DISTINCT u FROM unnest(p_user_ids) AS u LOOP
    IF v_recipient IS NULL THEN
      RAISE EXCEPTION 'Recipient user id cannot be null' USING ERRCODE = '22023';
    END IF;

    SELECT org_id INTO v_recipient_org FROM users WHERE id = v_recipient AND is_active = TRUE;
    IF v_recipient_org IS NULL THEN
      RAISE EXCEPTION 'Recipient % is not an active user', v_recipient USING ERRCODE = '22023';
    END IF;

    -- Same organization as the caller: always allowed -- this is the
    -- overwhelming majority of legitimate NotificationsAPI.notify()
    -- call sites (section_user_ids()/org_supervisor_user_ids()-derived
    -- recipients, and same-org specific individuals such as an
    -- assignee or a request's creator).
    IF v_recipient_org = v_actor_org THEN
      CONTINUE;
    END IF;

    -- Cross-organization: allowed only when the referenced record is a
    -- REAL requests or prisoner_letters row (the only two tables with
    -- genuine cross-organization semantics -- external_correspondence,
    -- meetings, tasks, and room bookings are all single-organization
    -- constructs, confirmed by their own schemas) whose own from/to
    -- organization columns place BOTH the caller and this recipient as
    -- parties to that specific record. The recipient's organization is
    -- never taken from client input for this check -- only from the
    -- recipient's own `users` row and the record's own stored columns.
    IF p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = p_record_id
        AND v_actor_org IN (r.from_org_id, r.to_org_id)
        AND v_recipient_org IN (r.from_org_id, r.to_org_id)
    ) THEN
      CONTINUE;
    END IF;

    IF p_record_type = 'prisoner_letter' AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = p_record_id
        AND v_actor_org IN (pl.from_prison_id, pl.to_org_id)
        AND v_recipient_org IN (pl.from_prison_id, pl.to_org_id)
    ) THEN
      CONTINUE;
    END IF;

    RAISE EXCEPTION 'Recipient % is not authorized: not in the caller''s organization, and no cross-organization request/prisoner_letter relationship justifies this notification',
      v_recipient USING ERRCODE = '42501';
  END LOOP;

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT DISTINCT u, p_type, p_record_type, p_record_id, p_message
  FROM unnest(p_user_ids) AS u;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN v_inserted;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION create_legacy_notification(UUID[],TEXT,TEXT,UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_legacy_notification(UUID[],TEXT,TEXT,UUID,TEXT) TO authenticated;

COMMIT;
