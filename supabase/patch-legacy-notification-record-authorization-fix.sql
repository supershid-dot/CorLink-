-- ============================================================
-- CAP-003 Phase 1.0B — Legacy notification RECORD-authorization
-- correction.
--
-- Follow-up to Phase 1.0A (patch-legacy-notification-insert-rls-fix.sql).
-- 1.0A closed cross-organization notification spoofing but left a
-- same-organization gap: create_legacy_notification()'s "same
-- organization as the caller: always allowed" rule (1.0A's own
-- documented, intentional simplification -- see docs/79 "Limitations")
-- meant ANY authenticated user could fabricate a notification for ANY
-- other user in their own organization, with any valid type, any
-- record_type string, and a nonexistent record_id -- as long as the
-- recipient shared their organization. Reproduced directly against
-- disposable local Postgres at HEAD f7572193502ac51e70f23be4c5520ce1691b3ce7
-- before writing this patch: an authenticated User A created four
-- fabricated notifications for an unrelated same-org User B, using
-- record_type values ('task', 'meeting', 'external_correspondence',
-- 'internal_request') and entirely nonexistent record_ids.
--
-- Root cause: same-organization membership alone was treated as
-- sufficient authorization. It never is -- an organization can contain
-- many sections/cases a given user has no legitimate connection to.
--
-- Call-site inventory (full repository grep of every real, raw-client
-- NotificationsAPI.notify() call site: requests-api.js, prisoner-
-- letters-api.js, entry-api.js, internal-requests-api.js (via its own
-- parentRef() translation to the PARENT request/entry),
-- review-comments-api.js) proves exactly THREE record_type values are
-- ever used by real client code: 'request', 'external_correspondence',
-- 'prisoner_letter'. 'task', 'meeting', and 'internal_request' are
-- NEVER used as a top-level record_type by any real caller -- every
-- module-level SECURITY DEFINER RPC that notifies about a task/meeting
-- (Meetings, Rooms, Tasks, task-dependencies) inserts directly and is
-- structurally unaffected by this table's RLS regardless (per 1.0A's
-- own scope analysis), and internal_requests-api.js always resolves
-- its own record_type/record_id to the PARENT request/entry via
-- parentRef(), never 'internal_request' itself. Every recipient in
-- every real call site is derived, server-side-verifiably, from the
-- referenced record's OWN columns: its section columns (via
-- section_user_ids()-equivalent membership), its party organization(s)
-- (via org_supervisor_user_ids()-equivalent role membership), specific
-- individual reference columns (created_by/received_by/assigned_to/
-- entered_by/submitted_by), or a section looped in via an
-- internal_requests row anchored to that same parent record.
--
-- Correction: create_legacy_notification() becomes record-authoritative.
-- For each of the three supported record_type values, it now: (1) loads
-- the referenced row and rejects a nonexistent one outright; (2)
-- requires the CALLER to be legitimately connected to that specific
-- record (not merely same-org); (3) requires EVERY recipient to be
-- legitimately connected to that specific record too -- "same
-- organization" is no longer, by itself, ever sufficient; (4) requires
-- the (record_type, type) combination to appear in a closed allowlist
-- derived directly from the real call-site inventory above. The
-- previously-correct cross-organization path for 'request' and
-- 'prisoner_letter' (docs/79) is preserved exactly: it was already
-- record-derived (from/to org columns on the row itself), and is now
-- simply one branch of the same unified per-record "legitimately
-- connected" predicate rather than a separate special case.
--
-- "Legitimately connected to record R" reuses the exact recipient-
-- derivation helpers real call sites already call client-side --
-- section_user_ids()'s own membership rule (generalized here to an
-- explicit p_user parameter instead of auth.uid(), since the recipient
-- is never the caller) and org_supervisor_user_ids()'s own role set
-- (mcs_admin/authority_admin/supervisor at a genuine PARTY organization
-- of the record, not the caller's organization in general) -- plus R's
-- own individual reference columns, plus any section ever looped in via
-- an internal_requests row anchored to R (mirroring requests_select_
-- via_internal_collab / external_correspondence_select_via_internal_
-- collab, generalized the same way). No reusable helper in this
-- codebase already takes an explicit target-user parameter (every RLS
-- helper in rls.sql is auth.uid()-bound by design, since it only ever
-- needs to answer "can the CALLER see this row"), so the smallest
-- equivalent generalized helpers are added here, narrowly, for this
-- correction's own use -- they do not replace, modify, or duplicate any
-- existing RLS policy or helper, and are prefixed notif_ to make that
-- boundary explicit.
--
-- Out of scope, deliberately (unchanged from 1.0A, restated per this
-- milestone's own governing instruction): the notifications.type
-- 30-value closed enum, any new notification table/outbox/worker/
-- intent/retry/preference/email/push/SMS infrastructure, any Realtime
-- or frontend redesign, and CAP-003 Phase 1.1 in its entirety.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── Generalized, explicit-user predicate helpers ──────────────────
-- Every one of these takes an explicit p_user parameter rather than
-- reading auth.uid() -- they must be able to answer "is THIS OTHER
-- user legitimately connected", not just "is the caller". SECURITY
-- DEFINER so they can read user_assignments/users/sections regardless
-- of the invoking role's own RLS visibility, exactly like every other
-- STABLE SECURITY DEFINER predicate helper already in rls.sql.

CREATE OR REPLACE FUNCTION notif_user_org_id(p_user UUID)
RETURNS UUID AS $$
  SELECT org_id FROM users WHERE id = p_user;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Generalized my_section_ids() -- same command/department/division/
-- section expansion (scope_section_ids), for an explicit user rather
-- than auth.uid(). NULL p_section_id (e.g. an unrouted request's
-- to_section_id) never matches -- no active assignment ever resolves
-- to a NULL section id.
CREATE OR REPLACE FUNCTION notif_user_covers_section(p_user UUID, p_section_id UUID)
RETURNS BOOLEAN AS $$
  SELECT p_section_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM user_assignments ua
    CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
    WHERE ua.user_id = p_user AND ua.is_active = TRUE AND sid = p_section_id
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Generalized org_supervisor_user_ids() role set (mcs_admin/
-- authority_admin/supervisor), for an explicit user, WITHOUT the
-- org_id filter baked in -- callers combine this with their own
-- notif_user_org_id(p_user) = <a genuine party org of the record>
-- check, reproducing org_supervisor_user_ids(that org) exactly.
-- Deliberately excludes super_admin, same as org_supervisor_user_ids()
-- itself ("they administer the whole system, not any one org's
-- day-to-day workflow") -- no real call site's recipient/actor list
-- was ever built from a super_admin, so this cannot reject one.
CREATE OR REPLACE FUNCTION notif_user_has_notify_role(p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_assignments
    WHERE user_id = p_user AND is_active = TRUE
      AND role IN ('mcs_admin', 'authority_admin', 'supervisor')
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Generalized is_prisoner_letters_staff() flag check for an explicit
-- user -- reused (not duplicated logic) as an additional legitimacy
-- signal for prisoner_letters specifically, since prisoner_letters_
-- update's own RLS already lets ANY flagged staff member at a party
-- org route/update a letter regardless of supervisor role, and the
-- real prisoner-letters-api.js routing call sites are triggered by
-- exactly that population.
CREATE OR REPLACE FUNCTION notif_user_is_prisoner_letters_staff(p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT is_prisoner_letters_staff FROM users WHERE id = p_user), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── Per-record-type "legitimately connected" predicates ───────────
-- Each returns FALSE outright for a nonexistent record_id (callers
-- also check existence separately for a clearer rejection reason, but
-- these are safe to call standalone). Used identically for BOTH the
-- caller-authorization check and the per-recipient legitimacy check --
-- a single source of truth per record type, deliberately: triggering a
-- notification about a record and being a legitimate recipient of one
-- are the same underlying question, "are you a genuine party to this
-- record", for every real call site inventoried above.

CREATE OR REPLACE FUNCTION notif_request_legitimate_recipient(p_request_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM requests r
    WHERE r.id = p_request_id
      AND (
        p_user IN (r.created_by, r.received_by, r.assigned_to)
        OR notif_user_covers_section(p_user, r.from_section_id)
        OR notif_user_covers_section(p_user, r.to_section_id)
        OR notif_user_covers_section(p_user, r.previous_section_id)
        OR (notif_user_org_id(p_user) IN (r.from_org_id, r.to_org_id) AND notif_user_has_notify_role(p_user))
        -- Any section ever looped in on this case via "Loop in a
        -- Section" (internal_requests.parent_request_id) -- both the
        -- asking side (from_section_id/created_by) and the looped-in
        -- side (to_section_id), plus a re-routed-away predecessor
        -- (previous_section_id), mirroring requests_select_via_
        -- internal_collab generalized the same way. internal_requests-
        -- api.js's own notify() calls (create/reroute/returnToSender/
        -- assign/reply lifecycle) always target one of exactly these.
        OR EXISTS (
          SELECT 1 FROM internal_requests ir
          WHERE ir.parent_request_id = r.id
            AND (
              p_user = ir.created_by
              OR notif_user_covers_section(p_user, ir.from_section_id)
              OR notif_user_covers_section(p_user, ir.to_section_id)
              OR notif_user_covers_section(p_user, ir.previous_section_id)
            )
        )
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION notif_entry_legitimate_recipient(p_entry_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM external_correspondence e
    WHERE e.id = p_entry_id
      AND (
        p_user IN (e.entered_by, e.assigned_to)
        OR notif_user_covers_section(p_user, e.to_section_id)
        -- Entry staff for this org (mirrors is_entry_staff()'s primary
        -- branch: membership in one of the org's designated Entry
        -- sections) or an org-level supervisor/admin -- entry_sections
        -- is single-org, so no cross-organization branch exists here,
        -- matching external_correspondence's own schema (org_id only).
        OR (
          notif_user_org_id(p_user) = e.org_id
          AND (
            notif_user_has_notify_role(p_user)
            OR EXISTS (
              SELECT 1 FROM entry_sections es
              WHERE es.org_id = e.org_id AND notif_user_covers_section(p_user, es.section_id)
            )
          )
        )
        -- Any section looped in via an entry-anchored internal_requests
        -- row (parent_entry_id), mirroring external_correspondence_
        -- select_via_internal_collab generalized the same way.
        OR EXISTS (
          SELECT 1 FROM internal_requests ir
          WHERE ir.parent_entry_id = e.id
            AND (
              p_user = ir.created_by
              OR notif_user_covers_section(p_user, ir.from_section_id)
              OR notif_user_covers_section(p_user, ir.to_section_id)
              OR notif_user_covers_section(p_user, ir.previous_section_id)
            )
        )
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION notif_prisoner_letter_legitimate_recipient(p_letter_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM prisoner_letters pl
    WHERE pl.id = p_letter_id
      AND (
        p_user IN (pl.submitted_by, pl.assigned_to, pl.received_by)
        OR notif_user_covers_section(p_user, pl.to_section_id)
        -- Genuine party organization (from_prison_id/to_org_id, the
        -- same two-organization model 1.0A already validated) plus
        -- either the same notify-role set used everywhere else, or the
        -- prisoner-letters-staff flag specifically -- prisoner_letters_
        -- update's own RLS already lets any flagged staff member at a
        -- party org act on a letter regardless of supervisor role, and
        -- routeLetter()'s real caller population is exactly that.
        OR (
          notif_user_org_id(p_user) IN (pl.from_prison_id, pl.to_org_id)
          AND (notif_user_has_notify_role(p_user) OR notif_user_is_prisoner_letters_staff(p_user))
        )
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── Closed (record_type, type) allowlist ──────────────────────────
-- Derived directly from the call-site inventory above -- every
-- combination a real NotificationsAPI.notify() call site actually
-- sends, and nothing else. 'deadline_warning' is deliberately absent:
-- it is only ever inserted by check_deadlines(), a SECURITY DEFINER
-- function that writes directly to the table and never calls this RPC,
-- so it needs no allowance here.
CREATE OR REPLACE FUNCTION notif_type_allowed(p_record_type TEXT, p_type TEXT)
RETURNS BOOLEAN AS $$
  SELECT (p_record_type, p_type) IN (
    ('request', 'approval_requested'),
    ('request', 'new_request'),
    ('request', 'draft_returned'),
    ('request', 'new_response'),
    ('request', 'request_cancelled'),
    ('external_correspondence', 'new_external_correspondence'),
    ('external_correspondence', 'approval_requested'),
    ('external_correspondence', 'external_correspondence_replied'),
    ('external_correspondence', 'draft_returned'),
    ('external_correspondence', 'new_request'),
    ('external_correspondence', 'new_response'),
    ('prisoner_letter', 'new_prisoner_letter'),
    ('prisoner_letter', 'letter_replied')
  );
$$ LANGUAGE sql IMMUTABLE;

-- ─── create_legacy_notification — now record-authoritative ─────────
-- Same external signature/behavior as 1.0A (all-or-nothing: a single
-- invalid recipient rejects the whole call), so
-- js/data/notifications-api.js's notify() and every one of its ~30
-- existing callers need zero changes.
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
  v_record_exists BOOLEAN;
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

  -- Closed record_type allowlist -- 'task', 'meeting', 'internal_request',
  -- or any other string is rejected outright, before any record lookup.
  IF p_record_type NOT IN ('request', 'external_correspondence', 'prisoner_letter') THEN
    RAISE EXCEPTION 'Unsupported record_type: %', p_record_type USING ERRCODE = '42501';
  END IF;

  -- Closed (record_type, type) allowlist -- a valid notifications.type
  -- enum value paired with a record_type it was never legitimately
  -- paired with by any real caller is rejected outright.
  IF NOT notif_type_allowed(p_record_type, p_type) THEN
    RAISE EXCEPTION 'Notification type % is not allowed for record_type %', p_type, p_record_type USING ERRCODE = '42501';
  END IF;

  -- The referenced record must actually exist.
  IF p_record_type = 'request' THEN
    SELECT EXISTS (SELECT 1 FROM requests WHERE id = p_record_id) INTO v_record_exists;
  ELSIF p_record_type = 'external_correspondence' THEN
    SELECT EXISTS (SELECT 1 FROM external_correspondence WHERE id = p_record_id) INTO v_record_exists;
  ELSE -- 'prisoner_letter'
    SELECT EXISTS (SELECT 1 FROM prisoner_letters WHERE id = p_record_id) INTO v_record_exists;
  END IF;
  IF NOT v_record_exists THEN
    RAISE EXCEPTION 'record_id % does not reference an existing % row', p_record_id, p_record_type USING ERRCODE = '42501';
  END IF;

  -- The caller must themselves be a legitimate party to this specific
  -- record -- same organization membership alone is never sufficient.
  IF (p_record_type = 'request' AND NOT notif_request_legitimate_recipient(p_record_id, v_actor))
     OR (p_record_type = 'external_correspondence' AND NOT notif_entry_legitimate_recipient(p_record_id, v_actor))
     OR (p_record_type = 'prisoner_letter' AND NOT notif_prisoner_letter_legitimate_recipient(p_record_id, v_actor))
  THEN
    RAISE EXCEPTION 'Caller is not authorized to notify about this %', p_record_type USING ERRCODE = '42501';
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

    -- Record-derived legitimacy only -- same organization as the
    -- caller is no longer, by itself, ever accepted. This is the
    -- entire 1.0B correction: requested_users must be a SUBSET of the
    -- record's own legitimate-party set, never merely "same org".
    IF (p_record_type = 'request' AND notif_request_legitimate_recipient(p_record_id, v_recipient))
       OR (p_record_type = 'external_correspondence' AND notif_entry_legitimate_recipient(p_record_id, v_recipient))
       OR (p_record_type = 'prisoner_letter' AND notif_prisoner_letter_legitimate_recipient(p_record_id, v_recipient))
    THEN
      CONTINUE;
    END IF;

    RAISE EXCEPTION 'Recipient % is not legitimately connected to this %record % -- notification rejected',
      v_recipient, p_record_type || ' ', p_record_id USING ERRCODE = '42501';
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
