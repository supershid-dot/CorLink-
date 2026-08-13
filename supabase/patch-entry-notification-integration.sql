-- ============================================================
-- CorLink — CAP-003 Phase 1.7B: Entry Notification Integration
-- ============================================================
-- Scope, precisely: integrates Entry / External Correspondence into
-- the CAP-003 outbox/notification pipeline (Phases 1.0-1.7A) by wiring
-- exactly FOUR real business events, each atomically enqueued inside
-- its own already-existing, server-authoritative Phase 1.7A mutation
-- RPC:
--
--   1. entry.routed.v1         -- route_entry(), when p_assigned_to IS NULL
--   2. entry.assigned.v1       -- route_entry(), when p_assigned_to IS NOT NULL,
--                                  AND assign_entry(), when p_user_id IS NOT NULL
--   3. entry.reply_sent.v1     -- approve_entry_reply()
--   4. entry.reply_returned.v1 -- return_entry_reply()
--
-- This is recipient-event integration, not a redesign of Entry. Every
-- modified RPC's own authorization, status-transition rules, audit_logs
-- writes, and existing legacy NotificationsAPI.notify() call sites
-- (js/data/entry-api.js, untouched by this patch) are preserved
-- byte-for-byte; the only SQL addition to each RPC is (a) `RETURNING id
-- INTO v_audit_id` appended to its existing audit_logs INSERT, (b) one
-- new DECLARE variable, and (c) one (or, for route_entry, one
-- conditional either/or) atomic platform_enqueue_outbox_event() call as
-- the final statement before RETURN -- exactly matching Phase 1.6B's
-- approve_request()/return_request()/route_request()/assign_request()/
-- approve_response() precedent.
--
-- ─── Candidate inventory (all 12 Phase 1.7A commands evaluated) ──────
-- create_entry / update_entry_draft -- DEFERRED. Draft-only; while
--   unrouted an entry is visible only to Entry staff/its own creator
--   (external_correspondence_select), and no legacy notification fires
--   for either (confirmed by direct inspection of js/data/entry-api.js
--   -- create()/updateDraft() never call NotificationsAPI.notify()).
-- route_entry -- IMPLEMENTED, conditionally, as entry.routed.v1 OR
--   entry.assigned.v1. entry-api.js's own route() legacy behavior is
--   itself an EITHER/OR: `if (assignedTo) notify([assignedTo],
--   'new_external_correspondence') else notify(sectionUserIds
--   (toSectionId), 'new_external_correspondence')` -- never both. This
--   patch mirrors that exact branching inside the single RPC: when
--   p_assigned_to IS NULL, enqueue entry.routed.v1 targeting
--   section(to_section_id); when p_assigned_to IS NOT NULL, enqueue
--   entry.assigned.v1 targeting specific_users(assigned_to) instead.
--   This differs from Requests' route_request (which never accepts an
--   assignee parameter at all -- assignment is always a separate later
--   step via assign_request) purely because Entry's own route_entry RPC
--   genuinely has this combined shape, evidenced directly by its own
--   Phase 1.7A signature and by entry-api.js's own pre-existing
--   either/or.
-- mark_entry_received -- DEFERRED. No legacy notification fires at all
--   (confirmed by direct inspection -- markReceived() only returns
--   `data`, no NotificationsAPI call). Implementing one here would
--   invent new recipient policy, which the governing instruction
--   prohibits. Exact same reasoning, same finding, as Requests'
--   mark_request_received in Phase 1.6B.
-- assign_entry -- IMPLEMENTED as entry.assigned.v1 (second producer of
--   the same event type as route_entry's own assignee branch -- see
--   above). Legacy recipients: [userId], conditional on userId being
--   non-null (an unassignment fires no legacy notification) -- mirrored
--   exactly, same conditional-enqueue shape as Requests' own
--   assign_request().
-- close_entry -- DEFERRED. No legacy notification fires at all
--   (confirmed by direct inspection -- close() only returns `data`).
-- draft_entry_reply / update_entry_reply_draft -- DEFERRED. Draft-only;
--   no legacy notification fires for either.
-- submit_entry_reply -- DEFERRED. Legacy recipients (approval_requested)
--   are either a single named approverId (informational routing only,
--   not an authorization boundary, mirroring submit_request's own
--   p_approver_id) or sectionUserIds(entry.to_section_id, ['mcs_admin',
--   'authority_admin','supervisor']) -- an internal, same-org,
--   pre-approval step. Exact same reasoning Requests' own
--   submit_request used to defer in Phase 1.6B: genuinely lower value,
--   not required to prove any of this milestone's architecture points,
--   and the 'section_leadership' target kind already exists for a
--   future milestone to wire it.
-- approve_entry_reply -- IMPLEMENTED as entry.reply_sent.v1. Sole RPC
--   that transitions a reply to status='sent' AND the parent entry to
--   status='responded' -- the real "sent" business event, matching
--   Requests' own requests.response_sent.v1 precedent (named after the
--   sub-object's own transition, not the RPC name). Legacy recipients:
--   [entry.entered_by] -- single specific_users target, mirrored
--   exactly. Sourced from the PARENT ENTRY (source_record_type=
--   'external_correspondence'), never a new reply source type -- see
--   below.
-- return_entry_reply -- IMPLEMENTED as entry.reply_returned.v1. Sole
--   RPC for returning a submitted reply draft. Legacy recipients:
--   [data.created_by] (the reply's own drafter) -- single specific_users
--   target, mirrored exactly. Also sourced from the parent entry.
-- mark_entry_reply_sent -- DEFERRED. No legacy notification fires at
--   all (confirmed by direct inspection -- markReplySent() only returns
--   `data`); it is a delivery-recording bookkeeping action (how the
--   already-approved reply physically reached the sender), not a
--   notify-worthy business transition.
--
-- ─── source_record_type: 'external_correspondence' added, no separate
--    reply source type ─────────────────────────────────────────────
-- Every legacy Entry notification call site in js/data/entry-api.js
-- uses `recordType: 'external_correspondence'` (never 'entry') --
-- confirmed by direct grep of entry-api.js's own NotificationsAPI.notify()
-- calls, and matching audit_logs.record_type/attachments.record_type's
-- own existing convention for this table (schema.sql) and shell.js's
-- own deep-link routes = { external_correspondence: 'entry-detail' }.
-- This is the actual, evidenced, existing repository convention --
-- 'entry' is used only as the RPC-name/route-name prefix, never as the
-- record-type string value anywhere in the current schema/frontend.
-- Per the governing instruction ("use existing routing/deep-link
-- terminology... do not choose from preference"), this milestone uses
-- source_record_type = 'external_correspondence', NOT 'entry'.
-- entry.reply_sent.v1/entry.reply_returned.v1 are both sourced from
-- the PARENT ENTRY (source_record_type='external_correspondence',
-- source_record_id=<entry.id>) -- never a new
-- 'external_correspondence_reply' source type -- because (a)
-- entry-detail.js already renders every reply inline within its
-- parent entry's own page, there is no separate reply detail route to
-- deep-link to, and (b) both events' only target candidates
-- (entry.entered_by, reply.created_by) are already covered by
-- intent_user_can_view_entry()'s own core-policy branches (entered_by/
-- to_section_id membership respectively), so a second adapter would
-- duplicate authorization the entry adapter already provides --
-- exactly the same reasoning Requests' own requests.response_sent.v1
-- used to avoid adding a 'response' source type in Phase 1.6B.
--
-- ─── intent_user_can_view_entry(): generalization source and a real,
--    evidenced divergence from the Requests precedent ────────────────
-- A candidate-parameterized mirror of external_correspondence_select's
-- own core USING clause (supabase/rls.sql) -- the same generalization
-- pattern Phase 1.2/1.4/1.4A/1.6B already used four times
-- (intent_user_can_view_workflow_instance/_task/_meeting/_request).
-- Entry visibility is spread across TWO SELECT policies
-- (external_correspondence_select, external_correspondence_select_
-- via_internal_collab) -- this adapter mirrors only the first, core
-- policy (org match, is_entry_staff()-equivalent, to_section_id
-- membership, assigned_to, entered_by), deliberately excluding the
-- additive Internal-Collaboration-loop-in policy -- same "core policy
-- only" scope decision Requests' own intent_user_can_view_request()
-- already made for its own three additive policies.
--
-- Unlike is_entry_staff()/my_section_ids() (both session-bound, always
-- evaluating against auth.uid() -- the WORKER's own identity when
-- called from inside resolve_notification_intent(), never the
-- candidate being authorized), this adapter re-implements the
-- equivalent check fully parameterized by p_user, directly against
-- user_assignments/scope_section_ids() -- exactly matching
-- intent_user_can_view_request()'s own technique for the identical
-- reason (my_section_ids() cannot safely be called here at all).
--
-- A genuine, evidenced divergence from the Requests precedent: Entry
-- RLS's own is_entry_staff() has NO admin/supervisor bypass --
-- schema.sql's own comment on is_entry_staff() explicitly documents
-- that a previous version DID have a blanket is_supervisor_or_above()
-- bypass and that this was REMOVED as a reported bug ("that let every
-- supervisor/admin org-wide see and manage every logged entry
-- regardless of section ... exactly the 'all entries visible to all
-- supervisors' bug this was reported as"). intent_user_can_view_request()
-- includes an intent_user_is_super_admin()/mcs_admin/authority_admin
-- bypass branch because requests_select itself grants org admins that
-- visibility; intent_user_can_view_entry() below deliberately does
-- NOT include any such bypass, because external_correspondence_select
-- itself grants none. Copying the Requests adapter's admin-bypass
-- branch here would silently WIDEN Entry visibility beyond what its
-- own real RLS grants -- exactly the class of mistake "prove it against
-- the real code, don't reconstruct from memory/a sibling precedent"
-- exists to catch.
--
-- ─── Target mapping (no new target kinds) ─────────────────────────
-- entry.routed.v1: section(to_section_id) [the just-routed-to section].
-- entry.assigned.v1: specific_users(assigned_to), conditional on
--   assigned_to being non-null.
-- entry.reply_sent.v1: specific_users(entry.entered_by).
-- entry.reply_returned.v1: specific_users(reply.created_by).
-- All four reuse target kinds and their existing resolution SQL
-- (section_user_ids(), already called unchanged by
-- resolve_notification_intent() since Phase 1.2) verbatim -- ZERO
-- changes to resolve_notification_intent()'s target-resolution CASE,
-- the target-shape CHECK constraint, or process_platform_outbox_batch().
-- create_notification_intent() and resolve_notification_intent() each
-- gain exactly ONE new line: an 'external_correspondence' entry added
-- to create_notification_intent()'s own source_record_type guard
-- (independent of the table CHECK constraint, same non-obvious finding
-- Phase 1.6B already documented and re-verified here by direct
-- end-to-end testing, not assumed) and resolve_notification_intent()'s
-- 'external_correspondence' -> intent_user_can_view_entry() dispatch
-- branch, following the identical pattern Phase 1.4A/1.6B added for
-- 'meeting'/'request'.
--
-- ─── Idempotency ───────────────────────────────────────────────────
-- Each event's idempotency_key is the fresh audit_logs.id captured via
-- `RETURNING id INTO v_audit_id` at the exact moment of the real
-- mutation -- never a timestamp, never invented. Each of the three
-- producer RPCs enqueues at most one outbox event per real invocation
-- (route_entry's own either/or is mutually exclusive within one call,
-- never both), so no deterministic-derivation (md5(...)) idempotency
-- key is needed; the raw audit_logs.id is used directly for all four
-- events, exactly as Phase 1.6B's own five events already do.
-- Legitimate repeated occurrences (e.g. route_entry() called again to
-- reroute, or assign_entry() called again to reassign) each produce
-- their own fresh audit_logs row and are therefore their own
-- legitimate, distinguishable occurrence.
--
-- ─── Correlation/causation ──────────────────────────────────────────
-- Each mutation generates one fresh gen_random_uuid() correlation_id
-- for its own single enqueue call. causation_id is NULL for all four
-- events, identical to every prior CAP-003 producer's own precedent --
-- no upstream CAP-003 event caused these.
--
-- ─── Safe payload ────────────────────────────────────────────────────
-- template_params carries only structural identifiers: entry_id,
-- reference_number (explicitly whitelisted by the governing instruction
-- as safe, same category as Requests' own reference_number), to_section_id,
-- assigned/actor user ids, reply_id. `subject` (the correspondence's own
-- title/summary line) is DELIBERATELY EXCLUDED from every payload --
-- docs/91 never affirmatively confirms subject as non-confidential
-- (Entry logs correspondence from the public, prisoners' families, and
-- prisoner complaints -- materially more sensitive in kind than
-- Requests' own internal inter-organization subject line), so per the
-- governing instruction's own explicit fallback this milestone treats
-- it conservatively as potentially sensitive and never copies it into
-- notification_intents/user_notifications. `body`, reply `body`,
-- sender_name, sender_contact, prisoner_name, and every free-text/
-- personal-data field are never read by any of the four new enqueue
-- call sites. Frontend templates render generic text using only
-- reference_number, never a fetched subject/body/sender identity.
--
-- ─── Legacy coexistence ──────────────────────────────────────────────
-- No legacy NotificationsAPI.notify() call site in js/data/entry-api.js
-- is removed, altered, or suppressed by this milestone (this is a
-- pure-SQL patch; the JS frontend change is dedup/routing/templates
-- only). For all four events, the CAP-003 target's own resolution SQL
-- is *the same function* the legacy call site already uses
-- (section_user_ids) or targets the exact same specific user id -- but
-- intent_user_can_view_entry()'s own narrower late-authorization (no
-- admin bypass, core-policy-only scope) means the two channels'
-- recipient sets are not proven byte-for-byte identical in every case,
-- so per the governing instruction every legacy write is retained
-- unconditionally for all four events.
--
-- ─── What this patch does NOT do ──────────────────────────────────
-- No cancel/return-to-previous-section/prisoner-transfer event (none of
-- those commands exist -- Phase 1.7A's own documented finding, unchanged).
-- No Internal Collaboration/Prisoner Letters integration. No CAP-002/SLA
-- producer. No new mutation RPC (all four events reuse Phase 1.7A's own
-- 12 RPCs). No Realtime cutover (Phase 1.5 already covers
-- user_notifications generically). No legacy-table migration, no
-- notification preferences, no email/push/SMS. No new target-descriptor
-- kind. No separate reply source_record_type. No change to Entry's
-- authorization, status-transition rules, RLS, or the audit_logs write
-- shape of any of the three modified RPCs -- every non-enqueue line of
-- each is byte-for-byte unchanged from its true Phase 1.7A production
-- body. No change to create_notification_intent()'s target-shape/
-- validation logic (only its source_record_type guard gains one entry)
-- or to process_platform_outbox_batch() at all -- every target kind
-- this milestone uses already existed since Phase 1.2.
--
-- Idempotent -- safe to re-run (none of the three modified functions'
-- own parameter lists change -- only their bodies gain new trailing
-- statements; CREATE OR REPLACE is sufficient, no DROP FUNCTION needed).
-- ============================================================

BEGIN;

-- ─── 1. Closed source_record_type allowlist: extended by exactly
--    'external_correspondence'. ─────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence'));

-- ─── 2. intent_user_can_view_entry(): candidate-generalized mirror of
--    external_correspondence_select's own core USING clause
--    (supabase/rls.sql) -- see header for the exact scope rationale
--    (core policy only, and deliberately NO admin/supervisor bypass,
--    matching is_entry_staff()'s own real, bug-fixed behavior rather
--    than Requests' adapter). Every branch reuses external_correspondence/
--    user_assignments/scope_section_ids() directly -- no parallel
--    permission system, and no session-bound helper
--    (is_entry_staff()/my_section_ids()) is called, since both are
--    auth.uid()-bound and would evaluate against the wrong identity
--    when invoked from inside resolve_notification_intent(). ─────────
CREATE OR REPLACE FUNCTION intent_user_can_view_entry(p_entry_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM external_correspondence ec
    WHERE ec.id = p_entry_id
      AND ec.org_id = (SELECT org_id FROM users WHERE id = p_user)
      AND (
        -- is_entry_staff-equivalent check, parameterized by p_user:
        -- entry_sections membership if any are configured for the org,
        -- else (zero entry_sections rows) any org member counts --
        -- already guaranteed by the outer org_id match above.
        EXISTS (
          SELECT 1 FROM entry_sections es
          WHERE es.org_id = ec.org_id AND es.section_id IN (
            SELECT sid FROM user_assignments ua
            CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
            WHERE ua.user_id = p_user AND ua.is_active = TRUE
          )
        )
        OR NOT EXISTS (SELECT 1 FROM entry_sections WHERE org_id = ec.org_id)
        OR ec.to_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR ec.assigned_to = p_user
        OR ec.entered_by = p_user
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION intent_user_can_view_entry(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ─── 3a. create_notification_intent(): its own independent
--    source_record_type guard (separate from the table CHECK
--    constraint updated in step 1) also needs 'external_correspondence'
--    added. Every other line is byte-for-byte identical to the true
--    latest Phase 1.6B body (patch-requests-notification-integration.sql);
--    the function's 13-argument signature is unchanged, so CREATE OR
--    REPLACE (no DROP FUNCTION) is sufficient. ──────────────────────
CREATE OR REPLACE FUNCTION create_notification_intent(
  p_outbox_event_id      UUID,
  p_notification_type    TEXT,
  p_title_template_key   TEXT,
  p_template_params      JSONB,
  p_priority              TEXT,
  p_target_type           TEXT,
  p_target_user_ids       UUID[],
  p_target_organization_id UUID,
  p_target_section_id     UUID,
  p_target_workflow_instance_id UUID,
  p_target_work_item_id   UUID,
  p_target_task_id        UUID,
  p_target_meeting_id     UUID
) RETURNS UUID AS $$
DECLARE
  v_event RECORD;
  v_target_key TEXT;
  v_id UUID;
  v_sorted_ids UUID[];
BEGIN
  IF p_outbox_event_id IS NULL OR p_notification_type IS NULL OR p_title_template_key IS NULL
     OR p_target_type IS NULL
  THEN
    RAISE EXCEPTION 'outbox_event_id, notification_type, title_template_key, and target_type are all required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_event FROM platform_outbox_events WHERE id = p_outbox_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox_event_id % does not reference an existing outbox event', p_outbox_event_id USING ERRCODE = '22023';
  END IF;

  -- Closed source_record_type allowlist (CAP-003 Phase 1.7B: extended
  -- with 'external_correspondence', see header). Structural, at
  -- creation time, never a silent fake at resolution time.
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence') THEN
    RAISE EXCEPTION 'source_record_type % has no generic authorization dispatch and remains deferred to a future module-adapter phase', v_event.source_record_type USING ERRCODE = '42501';
  END IF;

  CASE p_target_type
    WHEN 'specific_users' THEN
      IF p_target_user_ids IS NULL OR array_length(p_target_user_ids,1) IS NULL THEN
        RAISE EXCEPTION 'target_user_ids is required for target_type=specific_users' USING ERRCODE = '22023';
      END IF;
      SELECT array_agg(DISTINCT u ORDER BY u) INTO v_sorted_ids FROM unnest(p_target_user_ids) AS u;
      v_target_key := array_to_string(v_sorted_ids, ',');
    WHEN 'org_admins' THEN
      IF p_target_organization_id IS NULL THEN RAISE EXCEPTION 'target_organization_id is required for target_type=org_admins' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_organization_id::TEXT;
    WHEN 'section', 'section_leadership' THEN
      IF p_target_section_id IS NULL THEN RAISE EXCEPTION 'target_section_id is required for target_type=%', p_target_type USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_section_id::TEXT;
    WHEN 'workflow_participants' THEN
      IF p_target_workflow_instance_id IS NULL THEN RAISE EXCEPTION 'target_workflow_instance_id is required for target_type=workflow_participants' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_workflow_instance_id::TEXT;
    WHEN 'work_item_assignee' THEN
      IF p_target_work_item_id IS NULL THEN RAISE EXCEPTION 'target_work_item_id is required for target_type=work_item_assignee' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_work_item_id::TEXT;
    WHEN 'task_watchers' THEN
      IF p_target_task_id IS NULL THEN RAISE EXCEPTION 'target_task_id is required for target_type=task_watchers' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_task_id::TEXT;
    WHEN 'meeting_participants' THEN
      IF p_target_meeting_id IS NULL THEN RAISE EXCEPTION 'target_meeting_id is required for target_type=meeting_participants' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_meeting_id::TEXT;
    ELSE
      RAISE EXCEPTION 'Unsupported target_type: %', p_target_type USING ERRCODE = '22023';
  END CASE;

  INSERT INTO notification_intents (
    outbox_event_id, organization_id, notification_type, title_template_key, template_params,
    source_module, source_record_type, source_record_id, priority,
    target_type, target_user_ids, target_organization_id, target_section_id,
    target_workflow_instance_id, target_work_item_id, target_task_id, target_meeting_id, target_key
  ) VALUES (
    p_outbox_event_id, v_event.organization_id, p_notification_type, p_title_template_key,
    COALESCE(p_template_params, '{}'::JSONB),
    v_event.source_module, v_event.source_record_type, v_event.source_record_id,
    COALESCE(p_priority, 'normal'),
    p_target_type,
    CASE WHEN p_target_type = 'specific_users' THEN v_sorted_ids ELSE NULL END,
    CASE WHEN p_target_type = 'org_admins' THEN p_target_organization_id ELSE NULL END,
    CASE WHEN p_target_type IN ('section','section_leadership') THEN p_target_section_id ELSE NULL END,
    CASE WHEN p_target_type = 'workflow_participants' THEN p_target_workflow_instance_id ELSE NULL END,
    CASE WHEN p_target_type = 'work_item_assignee' THEN p_target_work_item_id ELSE NULL END,
    CASE WHEN p_target_type = 'task_watchers' THEN p_target_task_id ELSE NULL END,
    CASE WHEN p_target_type = 'meeting_participants' THEN p_target_meeting_id ELSE NULL END,
    v_target_key
  )
  ON CONFLICT (outbox_event_id, target_type, target_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT id INTO v_id FROM notification_intents
  WHERE outbox_event_id = p_outbox_event_id AND target_type = p_target_type AND target_key = v_target_key;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3b. resolve_notification_intent(): ONE new source-authorization
--    dispatch branch ('external_correspondence' ->
--    intent_user_can_view_entry()), following the identical pattern
--    Phase 1.4A/1.6B added for 'meeting'/'request'. Target-resolution
--    CASE is completely unchanged -- every target kind these four
--    events use ('specific_users', 'section') already existed since
--    Phase 1.2. Every other line is byte-for-byte identical to the
--    true latest Phase 1.6B body
--    (patch-requests-notification-integration.sql). ─────────────────
CREATE OR REPLACE FUNCTION resolve_notification_intent(p_intent_id UUID)
RETURNS TABLE(status TEXT, resolved_count INTEGER, skipped_count INTEGER) AS $$
DECLARE
  v_intent RECORD;
  v_candidate UUID;
  v_candidates UUID[];
  v_resolved INTEGER := 0;
  v_skipped INTEGER := 0;
  v_authorized BOOLEAN;
  v_final_status TEXT;
BEGIN
  IF p_intent_id IS NULL THEN
    RAISE EXCEPTION 'intent_id is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_intent FROM notification_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_id % does not reference an existing notification intent', p_intent_id USING ERRCODE = '22023';
  END IF;

  IF v_intent.status <> 'pending' THEN
    RETURN QUERY SELECT v_intent.status, v_intent.resolved_count, v_intent.skipped_count;
    RETURN;
  END IF;

  CASE v_intent.target_type
    WHEN 'specific_users' THEN
      v_candidates := v_intent.target_user_ids;
    WHEN 'org_admins' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates FROM org_supervisor_user_ids(v_intent.target_organization_id) AS u;
    WHEN 'section' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates FROM section_user_ids(v_intent.target_section_id, NULL::TEXT[]) AS u;
    WHEN 'section_leadership' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates
        FROM section_user_ids(v_intent.target_section_id, ARRAY['mcs_admin','authority_admin','supervisor']) AS u;
    WHEN 'workflow_participants' THEN
      SELECT array_agg(DISTINCT p.user_id) INTO v_candidates
        FROM workflow_participants p WHERE p.instance_id = v_intent.target_workflow_instance_id AND p.ended_at IS NULL;
    WHEN 'work_item_assignee' THEN
      SELECT array_agg(DISTINCT w.assigned_to) INTO v_candidates
        FROM workflow_work_items w WHERE w.id = v_intent.target_work_item_id AND w.assigned_to IS NOT NULL;
    WHEN 'task_watchers' THEN
      SELECT array_agg(DISTINCT tw.user_id) INTO v_candidates
        FROM task_watchers tw WHERE tw.task_id = v_intent.target_task_id;
    WHEN 'meeting_participants' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates
        FROM meeting_participant_recipient_ids(v_intent.target_meeting_id, NULL) AS u;
  END CASE;

  IF v_candidates IS NOT NULL THEN
    FOREACH v_candidate IN ARRAY v_candidates LOOP
      IF v_candidate IS NULL THEN CONTINUE; END IF;

      IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_candidate AND is_active = TRUE) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Processing-time authorization revalidation (docs/78 §8) --
      -- closed dispatcher, CAP-003 Phase 1.7B extends it with exactly
      -- one more branch ('external_correspondence') backed by
      -- intent_user_can_view_entry() above. No fallthrough/default
      -- branch that could silently authorize an unrecognized source
      -- type.
      IF v_intent.source_record_type = 'workflow_instance' THEN
        v_authorized := intent_user_can_view_workflow_instance(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'platform' THEN
        v_authorized := TRUE;
      ELSIF v_intent.source_record_type = 'task' THEN
        v_authorized := intent_user_can_view_task(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'meeting' THEN
        v_authorized := intent_user_can_view_meeting(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'request' THEN
        v_authorized := intent_user_can_view_request(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'external_correspondence' THEN
        v_authorized := intent_user_can_view_entry(v_intent.source_record_id, v_candidate);
      ELSE
        v_authorized := FALSE; -- structurally unreachable (create_notification_intent already rejects this), fails closed regardless.
      END IF;

      IF NOT v_authorized THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      PERFORM platform_create_user_notification(
        v_candidate, v_intent.organization_id, v_intent.notification_type, v_intent.title_template_key,
        v_intent.template_params, v_intent.source_module, v_intent.source_record_type, v_intent.source_record_id,
        v_intent.outbox_event_id, v_intent.priority, NULL, NULL, NULL
      );
      v_resolved := v_resolved + 1;
    END LOOP;
  END IF;

  v_final_status := CASE
    WHEN v_resolved > 0 AND v_skipped = 0 THEN 'resolved'
    WHEN v_resolved > 0 AND v_skipped > 0 THEN 'partially_resolved'
    ELSE 'failed'
  END;

  UPDATE notification_intents
  SET status = v_final_status, resolved_at = now(), resolved_count = v_resolved, skipped_count = v_skipped
  WHERE id = p_intent_id;

  RETURN QUERY SELECT v_final_status, v_resolved, v_skipped;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. Register the four implemented event types ───────────────────
INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES
  (
    'entry.routed.v1', 'entry', FALSE, FALSE,
    'An entry was routed to a receiving section with no specific assignee (route_entry(), p_assigned_to IS NULL). Recipients: section(to_section_id), mirroring the existing legacy new_external_correspondence notification''s own sectionUserIds(toSectionId) recipient set exactly. CAP-003 Phase 1.7B.',
    TRUE
  ),
  (
    'entry.assigned.v1', 'entry', FALSE, FALSE,
    'An entry was assigned to a specific staff member, either at routing time (route_entry(), p_assigned_to IS NOT NULL) or afterward by the receiving section (assign_entry(), conditional on a non-null assignee). Recipients: specific_users([assigned_to]), mirroring the existing legacy new_external_correspondence notification exactly. CAP-003 Phase 1.7B.',
    TRUE
  ),
  (
    'entry.reply_sent.v1', 'entry', FALSE, FALSE,
    'A reply to an entry was approved and marked ready to send back to the original sender (approve_entry_reply()), which also advances the parent entry to status=responded. Recipients: specific_users([entry.entered_by]), mirroring the existing legacy external_correspondence_replied notification exactly. Sourced from the PARENT ENTRY (source_record_type=external_correspondence), not a new reply source type -- see header. CAP-003 Phase 1.7B.',
    TRUE
  ),
  (
    'entry.reply_returned.v1', 'entry', FALSE, FALSE,
    'A submitted entry reply draft was returned to its drafter for changes (return_entry_reply()). Recipients: specific_users([reply.created_by]), mirroring the existing legacy draft_returned notification exactly. Sourced from the PARENT ENTRY. CAP-003 Phase 1.7B.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- ─── 5. route_entry(): atomic entry.routed.v1 OR entry.assigned.v1
--    enqueue, mutually exclusive within one call, mirroring
--    entry-api.js's own route() if(assignedTo)/else branching exactly.
--    Every non-enqueue line is byte-for-byte unchanged from the true
--    Phase 1.7A production body. ────────────────────────────────────
CREATE OR REPLACE FUNCTION route_entry(
  p_entry_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
  v_section_org UUID;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_entry requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT is_entry_staff(v_row.org_id) THEN
    RAISE EXCEPTION 'Not authorized to route this entry';
  END IF;

  SELECT org_id INTO v_section_org FROM sections WHERE id = p_to_section_id;
  IF v_section_org IS DISTINCT FROM v_row.org_id THEN
    RAISE EXCEPTION 'That section does not belong to this organization';
  END IF;

  IF p_assigned_to IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_assigned_to), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE external_correspondence SET
    to_section_id = p_to_section_id, status = 'routed', assigned_to = p_assigned_to
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'external_correspondence', p_entry_id,
    'Routed to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'a section'))
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.7B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Mutually exclusive either/or, mirroring the
  -- legacy notification's own if(assignedTo)/else branch exactly.
  IF p_assigned_to IS NOT NULL THEN
    PERFORM platform_enqueue_outbox_event(
      'entry.assigned.v1', 'entry', 'external_correspondence', p_entry_id, v_row.org_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'entry.assigned.v1',
        'title_template_key', 'entry.assigned',
        'template_params', jsonb_build_object('entry_id', p_entry_id, 'assigned_to', p_assigned_to, 'assigned_by', v_actor),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(p_assigned_to)
      ),
      v_audit_id
    );
  ELSE
    PERFORM platform_enqueue_outbox_event(
      'entry.routed.v1', 'entry', 'external_correspondence', p_entry_id, v_row.org_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'entry.routed.v1',
        'title_template_key', 'entry.routed',
        'template_params', jsonb_build_object('entry_id', p_entry_id, 'to_section_id', p_to_section_id, 'routed_by', v_actor),
        'priority', 'normal',
        'target_type', 'section',
        'target_section_id', p_to_section_id
      ),
      v_audit_id
    );
  END IF;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. assign_entry(): atomic entry.assigned.v1 enqueue ────────────
-- Conditional on p_user_id IS NOT NULL -- an unassignment fires no
-- event, mirroring the legacy `if (userId)` guard exactly. Second
-- producer of entry.assigned.v1 alongside route_entry() above.
CREATE OR REPLACE FUNCTION assign_entry(
  p_entry_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_deadline DATE DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_entry requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT (is_entry_staff(v_row.org_id) OR v_row.to_section_id IN (SELECT my_section_ids())) THEN
    RAISE EXCEPTION 'Not authorized to assign this entry';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE external_correspondence SET assigned_to = p_user_id, deadline = p_deadline
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'external_correspondence', p_entry_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END)
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.7B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Conditional on a real assignee, mirroring
  -- the legacy notification's own guard.
  IF p_user_id IS NOT NULL THEN
    PERFORM platform_enqueue_outbox_event(
      'entry.assigned.v1', 'entry', 'external_correspondence', p_entry_id, v_row.org_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'entry.assigned.v1',
        'title_template_key', 'entry.assigned',
        'template_params', jsonb_build_object('entry_id', p_entry_id, 'assigned_to', p_user_id, 'assigned_by', v_actor),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(p_user_id)
      ),
      v_audit_id
    );
  END IF;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. approve_entry_reply(): atomic entry.reply_sent.v1 enqueue ───
-- Sourced from the PARENT ENTRY (source_record_type=
-- 'external_correspondence', source_record_id=v_entry.id) -- see
-- header for why no separate reply source type is introduced.
CREATE OR REPLACE FUNCTION approve_entry_reply(
  p_reply_id UUID
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_entry_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (
    is_supervisor_or_above() AND v_entry.to_section_id IS NOT NULL
    AND get_my_org_id() = scope_org_id('section', v_entry.to_section_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to approve this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'sent', approved_by = v_actor, approved_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  UPDATE external_correspondence SET status = 'responded' WHERE id = v_entry.id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'external_correspondence', v_entry.id, 'Approved reply to external correspondence')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.7B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_type='external_correspondence'
  -- / source_record_id=v_entry.id -- the PARENT entry, not the reply.
  PERFORM platform_enqueue_outbox_event(
    'entry.reply_sent.v1', 'entry', 'external_correspondence', v_entry.id, v_entry.org_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'entry.reply_sent.v1',
      'title_template_key', 'entry.reply_sent',
      'template_params', jsonb_build_object(
        'entry_id', v_entry.id, 'reply_id', p_reply_id,
        'reference_number', v_entry.reference_number, 'approved_by', v_actor
      ),
      'priority', 'normal',
      'target_type', 'specific_users',
      'target_user_ids', jsonb_build_array(v_entry.entered_by)
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. return_entry_reply(): atomic entry.reply_returned.v1 enqueue ──
-- Sourced from the PARENT ENTRY, same reasoning as above.
CREATE OR REPLACE FUNCTION return_entry_reply(
  p_reply_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_entry_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (
    is_supervisor_or_above() AND v_entry.to_section_id IS NOT NULL
    AND get_my_org_id() = scope_org_id('section', v_entry.to_section_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to return this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'draft', pending_approval_by = NULL
  WHERE id = p_reply_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('external_correspondence_reply', p_reply_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'external_correspondence', v_entry.id, 'Returned reply for changes')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.7B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_type='external_correspondence'
  -- / source_record_id=v_entry.id -- the PARENT entry, not the reply.
  PERFORM platform_enqueue_outbox_event(
    'entry.reply_returned.v1', 'entry', 'external_correspondence', v_entry.id, v_entry.org_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'entry.reply_returned.v1',
      'title_template_key', 'entry.reply_returned',
      'template_params', jsonb_build_object('entry_id', v_entry.id, 'reply_id', p_reply_id, 'returned_by', v_actor),
      'priority', 'normal',
      'target_type', 'specific_users',
      'target_user_ids', jsonb_build_array(v_row.created_by)
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
