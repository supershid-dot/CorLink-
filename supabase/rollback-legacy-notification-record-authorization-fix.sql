-- CAP-003 Phase 1.0B -- legacy notification RECORD-authorization
-- correction rollback. Restores create_legacy_notification() to
-- EXACTLY its 1.0A-era definition (byte-identical to the function body
-- in patch-legacy-notification-insert-rls-fix.sql, at commit
-- f7572193502ac51e70f23be4c5520ce1691b3ce7) and drops every new object
-- this milestone introduced: the closed (record_type, type) allowlist,
-- the three per-record-type legitimacy predicates, and the four
-- generalized explicit-user helpers. No CASCADE is used anywhere.
--
-- This intentionally restores the 1.0A-era same-org-gap state -- it
-- exists for exact-rollback verification (byte-identical function
-- body, clean reapplication) during this milestone's own testing, not
-- as an operational recommendation to ever actually run it against a
-- real environment.
\set ON_ERROR_STOP on
BEGIN;

DROP FUNCTION IF EXISTS notif_request_legitimate_recipient(UUID, UUID);
DROP FUNCTION IF EXISTS notif_entry_legitimate_recipient(UUID, UUID);
DROP FUNCTION IF EXISTS notif_prisoner_letter_legitimate_recipient(UUID, UUID);
DROP FUNCTION IF EXISTS notif_type_allowed(TEXT, TEXT);
DROP FUNCTION IF EXISTS notif_user_org_id(UUID);
DROP FUNCTION IF EXISTS notif_user_covers_section(UUID, UUID);
DROP FUNCTION IF EXISTS notif_user_has_notify_role(UUID);
DROP FUNCTION IF EXISTS notif_user_is_prisoner_letters_staff(UUID);

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
