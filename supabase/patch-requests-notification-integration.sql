-- ============================================================
-- CorLink — CAP-003 Phase 1.6B: Requests Notification Integration
-- ============================================================
-- Scope, precisely: integrates Requests into the CAP-003 outbox/
-- notification pipeline (Phases 1.0-1.5) by wiring exactly FIVE real
-- business events, each atomically enqueued inside its own already-
-- existing, server-authoritative Phase 1.6A mutation RPC:
--
--   1. requests.sent.v1           -- approve_request()
--   2. requests.returned.v1       -- return_request()
--   3. requests.routed.v1         -- route_request()
--   4. requests.assigned.v1       -- assign_request()
--   5. requests.response_sent.v1  -- approve_response()
--
-- This is recipient-event integration, not a redesign of Requests.
-- Every modified RPC's own authorization, status-transition rules,
-- approvals/audit_logs writes, and existing legacy
-- NotificationsAPI.notify() call sites (js/data/requests-api.js,
-- untouched by this patch) are preserved byte-for-byte; the only SQL
-- addition to each RPC is (a) `RETURNING id INTO v_audit_id` appended
-- to its existing audit_logs INSERT, (b) one new DECLARE variable, and
-- (c) one atomic platform_enqueue_outbox_event() call as the final
-- statement before RETURN — exactly matching Phase 1.4/1.4B's
-- assign_task()/complete_task()/update_meeting()/cancel_meeting()
-- precedent.
--
-- ─── Candidate inventory (all 19 Phase 1.6A commands evaluated) ──────
-- create_request / update_request_draft -- DEFERRED. Draft-only, never
--   visible to anyone but the creator (requests_select); no recipient
--   exists yet. No legacy notification fires either.
-- submit_request -- DEFERRED. Legacy recipients (approval_requested) are
--   either a single named approverId (informational routing only, not
--   an authorization boundary -- see docs/89) or
--   sectionUserIds(from_section_id, ['mcs_admin','authority_admin',
--   'supervisor']) -- same-section colleagues of the creator. This is
--   an internal, single-org, pre-send approval step; genuinely lower
--   value than the five implemented events and not required to prove
--   any of this milestone's architecture points (bidirectionality,
--   cross-org authorization, multi-target fan-out). Deferred for scope
--   discipline, not blocked -- the 'section_leadership' target kind
--   already exists and a future milestone could wire it the same way.
-- approve_request -- IMPLEMENTED as requests.sent.v1. Sole RPC that
--   transitions a request to status='sent' with a reference_number,
--   i.e. actually dispatches it to the receiving org -- the real
--   "sent" business event, matching the requests.status enum's own
--   vocabulary (deliberately NOT named after submit_request, which
--   only reaches 'pending_approval', an internal same-org state).
--   Legacy recipients: orgSupervisorUserIds(data.to_org_id) -- verified
--   by direct inspection to be the *exact same* SQL function
--   (org_supervisor_user_ids()) the existing 'org_admins' target kind
--   already calls inside resolve_notification_intent() (Phase 1.2).
-- return_request -- IMPLEMENTED as requests.returned.v1. Sole RPC for
--   returning a submitted draft. Legacy recipients: [data.created_by]
--   -- single specific_users target.
-- mark_request_received -- DEFERRED. No legacy notification fires at
--   all (confirmed by direct inspection of js/data/requests-api.js --
--   markRequestReceived() only returns `data`, no NotificationsAPI
--   call). Implementing one here would invent new recipient policy,
--   which the governing instruction prohibits.
-- route_request -- IMPLEMENTED as requests.routed.v1. Legacy
--   recipients: sectionUserIds(toSectionId) -- verified to be the
--   exact same SQL function (section_user_ids(section_id, NULL)) the
--   existing 'section' target kind already calls.
-- return_request_to_previous_section -- DEFERRED. Legacy recipients
--   (sectionUserIds(data.to_section_id)) are structurally the *same*
--   'section' target-kind shape as requests.routed.v1 above, but this
--   is a distinct RPC/lifecycle occurrence with its own distinct
--   business meaning (a rejection hand-back, not a forward route).
--   Deferred for scope discipline (already at 5 implemented events);
--   the section target kind and intent_user_can_view_request() adapter
--   this milestone ships already cover everything a future milestone
--   would need to wire requests.returned_to_sender.v1 the same way.
-- assign_request -- IMPLEMENTED as requests.assigned.v1. Legacy
--   recipients: [userId], conditional on userId being non-null (an
--   unassignment fires no legacy notification) -- mirrored exactly.
-- receive_and_route_request -- Not directly wired (it PERFORMs
--   mark_request_received/route_request/assign_request as nested calls
--   in the same transaction -- see docs/90 for the resulting fan-out
--   and its one documented, evidenced limitation).
-- close_request -- DEFERRED. Legacy recipients
--   (sectionUserIds(data.from_section_id) UNION created_by) target BOTH
--   a section AND a specific user in one notification concept -- the
--   task.completed.v1 multi-descriptor precedent would apply, but
--   close_request has no status-transition guard of its own in
--   application code at all (relies entirely on the pre-existing
--   check_request_status trigger) and is one of two RPCs
--   (acknowledge_and_close is the other) sharing the exact same
--   recipient shape as 'new_response' on final closure; both are
--   deferred together for scope discipline -- requests.response_sent.v1
--   (below) already demonstrates the response-to-parent-request
--   source-record-type + specific_users pattern this milestone commits
--   to, and a future milestone can extend it to the two closure RPCs
--   using the section+specific_users multi-descriptor pattern this
--   milestone's docs/90 documents but does not need to implement to
--   stay within ~3-5 events.
-- cancel_request -- DEFERRED. Legacy recipients are conditional and
--   branch on whether the request was ever routed
--   (sectionUserIds(to_section_id) OR orgSupervisorUserIds(to_org_id)),
--   AND further conditional on reference_number having ever been set.
--   Both existing target kinds this milestone would reuse ('section',
--   'org_admins') are already proven safe by requests.routed.v1/
--   requests.sent.v1 above; deferred purely for the ~3-5 event budget,
--   not for any architecture gap.
-- create_response / update_response_draft -- DEFERRED. Same reasoning
--   as create_request/update_request_draft -- draft-only, no recipient.
-- submit_response -- DEFERRED. Same reasoning as submit_request --
--   internal, single-org, pre-send approval step within the responding
--   section; lower value, deferred for scope discipline.
-- approve_response -- IMPLEMENTED as requests.response_sent.v1. Sole
--   RPC that transitions a response to status='sent' AND the parent
--   request to status='responded' -- the real, symmetric "sent" event
--   on the response side of the conversation, completing the
--   bidirectional pair with requests.sent.v1 (see Bidirectionality
--   below). Legacy recipients: [reqRow.created_by] -- single
--   specific_users target, exactly mirrored.
-- return_response -- DEFERRED. Legacy recipients ([data.created_by])
--   are the exact same specific_users shape as requests.returned.v1
--   above; deferred purely for the ~3-5 event budget.
-- mark_response_received -- DEFERRED. Same reasoning as
--   mark_request_received -- no legacy notification fires at all.
-- acknowledge_and_close -- DEFERRED, see close_request above (shares
--   its reasoning and its deferred multi-descriptor shape).
--
-- ─── source_record_type: 'request' added, 'response' NOT added ───────
-- requests.response_sent.v1 is sourced from approve_response(), a
-- responses-table mutation -- but its outbox event uses
-- source_record_type='request' / source_record_id=<the PARENT request's
-- id>, never a new 'response' source type. This is a deliberate design
-- choice, not an oversight: (a) request-detail.js already renders a
-- response inline within its parent request's own page -- there is no
-- separate response detail route to deep-link to, so routing the event
-- to the parent request is what the existing frontend architecture
-- already expects; (b) the only candidate for this event's target
-- (requests.created_by) is unconditionally covered by
-- intent_user_can_view_request()'s own `r.created_by = p_user` branch,
-- so a second adapter would duplicate authorization the request adapter
-- already provides for exactly this candidate, which the governing
-- instruction explicitly discourages ("prefer reuse of existing
-- request/response visibility helper logic; do not duplicate
-- authorization unnecessarily"). No 'response' source_record_type is
-- added to the closed dispatcher by this patch.
--
-- ─── intent_user_can_view_request(): generalization source ────────────
-- A candidate-parameterized mirror of requests_select's own USING
-- clause (supabase/rls.sql) -- the exact same generalization pattern
-- Phase 1.2/1.4/1.4A already used three times
-- (intent_user_can_view_workflow_instance/_task/_meeting). Requests
-- visibility is spread across FOUR additive SELECT policies
-- (requests_select, requests_select_via_internal_collab,
-- requests_select_assigned_receiver, requests_select_cc) -- this
-- adapter mirrors only the first, core policy (org-party check, plus
-- is_admin()/from_section_id/to_section_id/previous_section_id/
-- created_by/received_by), deliberately excluding the three additive
-- edge-visibility grants. This is NOT a new narrowing invented for this
-- milestone: it is the exact same scope decision the codebase's own
-- pre-existing can_view_request_or_response() helper (rls.sql, used by
-- cc_recipients' RLS policies) already makes -- that function mirrors
-- only the same core conditions, not the three additive policies
-- either. Every one of this milestone's five events' target candidates
-- (org_admins(to_org_id), section(to/previous_section_id),
-- specific_users(assigned_to/created_by)) is a subset of what the core
-- policy already authorizes in the ordinary case; the known, narrow gap
-- (a supervisor visible only via requests_select_assigned_receiver's
-- default-receiving-section carve-out, on a still-unrouted request)
-- fails CLOSED at CAP-003 resolution -- filtered from the new
-- user_notifications channel -- while the untouched legacy
-- `notifications` dual-write (js/data/requests-api.js, unmodified)
-- still reaches them exactly as it does today. Documented, not worked
-- around -- see docs/90.
--
-- ─── Bidirectionality ──────────────────────────────────────────────
-- requests.sent.v1 targets org_admins(v_row.to_org_id) -- the REQUEST
-- ROW's own to_org_id, never a hard-coded "always org A" / "always org
-- B" assumption. requests.response_sent.v1 targets
-- specific_users(v_req.created_by) -- the PARENT REQUEST's own creator,
-- who by requests_insert's own WITH CHECK always belongs to
-- v_req.from_org_id. Together, these two events flow correctly whether
-- Organization Alpha sends the original request to Beta (Alpha's own
-- staff created it, so requests.sent.v1 notifies Beta's org_admins;
-- Beta's own staff answer it, so requests.response_sent.v1 notifies
-- Alpha's creator) or Beta sends the original request to Alpha (exactly
-- symmetric, same code path, same functions, opposite party). No event
-- name, target mapping, or payload field encodes "sender" or "receiver"
-- as a fixed organization -- both are read live from the request row's
-- own from_org_id/to_org_id/created_by at the moment of the real
-- mutation. Proven for real in the behavioral suite (scenario set run
-- twice, Alpha->Beta and Beta->Alpha, asserting identical CAP-003
-- behavior with the two organizations' roles swapped).
--
-- ─── Target mapping (no new target kinds) ─────────────────────────
-- requests.sent.v1: org_admins(to_org_id).
-- requests.returned.v1: specific_users(created_by).
-- requests.routed.v1: section(to_section_id) [the just-routed-to
--   section, i.e. p_to_section_id / the post-UPDATE row's own value].
-- requests.assigned.v1: specific_users(assigned_to), conditional on
--   assigned_to being non-null (mirrors legacy's own `if (userId)`).
-- requests.response_sent.v1: specific_users(request.created_by).
-- All five reuse target kinds and their existing resolution SQL
-- (org_supervisor_user_ids/section_user_ids, both already called
-- unchanged by resolve_notification_intent() since Phase 1.2) verbatim
-- -- ZERO changes to resolve_notification_intent()'s target-resolution
-- CASE, the target-shape CHECK constraint, or
-- process_platform_outbox_batch(). create_notification_intent() and
-- resolve_notification_intent() each gain exactly ONE new line: a
-- 'request' entry added to create_notification_intent()'s own
-- source_record_type guard (independent of the table CHECK constraint,
-- found by direct end-to-end testing against the local harness -- not
-- assumed from memory) and resolve_notification_intent()'s
-- 'request' -> intent_user_can_view_request() dispatch branch,
-- following the identical pattern Phase 1.4A added for 'meeting' in
-- both places.
--
-- ─── Idempotency ───────────────────────────────────────────────────
-- Each event's idempotency_key is the fresh audit_logs.id captured via
-- `RETURNING id INTO v_audit_id` at the exact moment of the real
-- mutation -- never a timestamp, never invented. Each of the five RPCs
-- enqueues at most one outbox event per real invocation (no
-- multi-descriptor fan-out is needed for any of the five -- unlike
-- task.completed.v1, none of these five legacy notifications ever
-- targeted two DIFFERENT recipient groups from one call), so no
-- deterministic-derivation (md5(...)) idempotency key is needed here;
-- the raw audit_logs.id is used directly for all five, exactly as
-- task.assigned.v1/meetings.rescheduled.v1/meetings.cancelled.v1 (each
-- also single-descriptor) already do. Legitimate repeated occurrences
-- (e.g. assign_request() called again to reassign, or to unassign then
-- reassign) each produce their own fresh audit_logs row and are
-- therefore their own legitimate, distinguishable occurrence, exactly
-- Phase 1.4B's own complete_task() precedent.
--
-- ─── Correlation/causation ──────────────────────────────────────────
-- Each mutation generates one fresh gen_random_uuid() correlation_id
-- for its own single enqueue call. causation_id is NULL for all five
-- events, identical to every prior CAP-003 producer's own precedent
-- (task.assigned.v1, task.completed.v1, meetings.*.v1) -- no upstream
-- CAP-003 event caused these.
--
-- ─── Safe payload ────────────────────────────────────────────────────
-- template_params carries only structural identifiers: request_id,
-- reference_number (explicitly whitelisted by the governing
-- instruction as safe -- "request ID, request number/reference"),
-- from/to organization ids, from/to section ids, assigned/actor user
-- ids, response_id. `subject` is DELIBERATELY EXCLUDED from every
-- payload -- docs/89 (the Phase 1.6A source-of-truth for this table's
-- own confidentiality posture) never affirmatively confirms `subject`
-- as non-confidential, so per the governing instruction's own explicit
-- fallback ("if even the subject/title may be confidential, use a
-- generic template without it"), this milestone treats it
-- conservatively as potentially sensitive and never copies it into
-- notification_intents/user_notifications. `body`, response `body`,
-- and every free-text comment parameter (p_comment on
-- approve_request/return_request/return_request_to_previous_section/
-- approve_response) are never read by any of the five new enqueue call
-- sites. Frontend templates (see below) render a generic message using
-- only reference_number, never a fetched subject/body.
--
-- ─── Legacy coexistence ──────────────────────────────────────────────
-- No legacy `NotificationsAPI.notify()` call site in js/data/
-- requests-api.js is removed, altered, or suppressed by this patch (it
-- is a pure-SQL patch; the frontend file is untouched here). For
-- requests.sent.v1/requests.routed.v1, the CAP-003 target's own
-- resolution SQL is *the same function* the legacy call site already
-- uses (org_supervisor_user_ids/section_user_ids) -- but
-- intent_user_can_view_request()'s own narrower late-authorization
-- (see above) means the two channels' recipient sets are not proven
-- byte-for-byte identical in every case, so per the governing
-- instruction ("if exact equivalence is NOT proven, retain the legacy
-- write") every legacy write is retained unconditionally. Phase 1.5's
-- MIGRATED_EVENT_MAP dedup extension (js/data/notifications-api.js) is
-- addressed separately in the frontend patch for this milestone -- see
-- docs/90.
--
-- ─── What this patch does NOT do ──────────────────────────────────
-- No task.review_requested.v1-style invented events. No Entry/Internal
-- Collaboration/Prisoner Letters integration. No CAP-002/SLA producer.
-- No new mutation RPC (all five events reuse Phase 1.6A's own 19
-- RPCs). No Realtime cutover (Phase 1.5 already covers user_notifications
-- generically). No legacy-table migration, no notification preferences,
-- no email/push/SMS. No new target-descriptor kind. No 'response'
-- source_record_type. No change to Requests/Responses authorization,
-- status-transition rules, RLS, or the approvals/audit_logs write
-- shape of any of the five modified RPCs -- every non-enqueue line of
-- each is byte-for-byte unchanged from its true Phase 1.6A production
-- body. No change to create_notification_intent()'s target-shape/
-- validation logic (only its source_record_type guard gains one
-- entry) or to process_platform_outbox_batch() at all -- no new
-- NULLIF passthrough is needed (unlike Phase 1.4A), since every target
-- kind this milestone uses already existed since Phase 1.2.
--
-- Idempotent -- safe to re-run (none of the five modified functions'
-- own parameter lists change -- only their bodies gain new trailing
-- statements; CREATE OR REPLACE is sufficient, no DROP FUNCTION
-- needed).
-- ============================================================

BEGIN;

-- ─── 1. Closed source_record_type allowlist: extended by exactly
--    'request'. ─────────────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request'));

-- ─── 2. intent_user_can_view_request(): candidate-generalized mirror
--    of requests_select's own USING clause (supabase/rls.sql) -- see
--    header for the exact scope rationale (core policy only, matching
--    the codebase's own pre-existing can_view_request_or_response()
--    helper's identical scope decision). Every branch reuses
--    requests/user_assignments/scope_section_ids() directly -- no
--    parallel permission system. ────────────────────────────────────
CREATE OR REPLACE FUNCTION intent_user_can_view_request(p_request_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM requests r
    WHERE r.id = p_request_id
      AND (
        r.from_org_id = (SELECT org_id FROM users WHERE id = p_user)
        OR r.to_org_id = (SELECT org_id FROM users WHERE id = p_user)
      )
      AND (
        intent_user_is_super_admin(p_user)
        OR EXISTS (
          SELECT 1 FROM user_assignments ua
          WHERE ua.user_id = p_user AND ua.is_active = TRUE AND ua.role IN ('mcs_admin', 'authority_admin')
        )
        OR r.from_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR r.to_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR r.previous_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR r.created_by = p_user
        OR r.received_by = p_user
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION intent_user_can_view_request(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ─── 3a. create_notification_intent(): its own independent
--    source_record_type guard (separate from the table CHECK
--    constraint updated in step 1) also needs 'request' added -- found
--    by direct end-to-end testing against the local harness, not
--    assumed. Every other line is byte-for-byte identical to the true
--    latest Phase 1.4A body (patch-notification-target-expansion.sql);
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

  -- Closed source_record_type allowlist (CAP-003 Phase 1.6B: extended
  -- with 'request', see header). Structural, at creation time, never a
  -- silent fake at resolution time.
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request') THEN
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
--    dispatch branch ('request' -> intent_user_can_view_request()),
--    following the identical pattern Phase 1.4A added for 'meeting'.
--    Target-resolution CASE is completely unchanged -- every target
--    kind these five events use ('specific_users', 'org_admins',
--    'section') already existed since Phase 1.2. Every other line is
--    byte-for-byte identical to the true latest Phase 1.4A body
--    (patch-notification-target-expansion.sql). ─────────────────────
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
      -- closed dispatcher, CAP-003 Phase 1.6B extends it with exactly
      -- one more branch ('request') backed by
      -- intent_user_can_view_request() above. No fallthrough/default
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

-- ─── 4. Register the five implemented event types ──────────────────
INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES
  (
    'requests.sent.v1', 'requests', FALSE, FALSE,
    'A request was approved and sent to the receiving organization (approve_request()). Recipients: org_admins(to_org_id), mirroring the existing legacy new_request notification''s own orgSupervisorUserIds(to_org_id) recipient set exactly. CAP-003 Phase 1.6B.',
    TRUE
  ),
  (
    'requests.returned.v1', 'requests', FALSE, FALSE,
    'A submitted request draft was returned to its creator for changes (return_request()). Recipients: specific_users([created_by]), mirroring the existing legacy draft_returned notification exactly. CAP-003 Phase 1.6B.',
    TRUE
  ),
  (
    'requests.routed.v1', 'requests', FALSE, FALSE,
    'A request was routed to a receiving section (route_request()). Recipients: section(to_section_id), mirroring the existing legacy new_request notification''s own sectionUserIds(toSectionId) recipient set exactly. CAP-003 Phase 1.6B.',
    TRUE
  ),
  (
    'requests.assigned.v1', 'requests', FALSE, FALSE,
    'A request was assigned to a specific staff member (assign_request(), conditional on a non-null assignee). Recipients: specific_users([assigned_to]), mirroring the existing legacy new_request notification exactly. CAP-003 Phase 1.6B.',
    TRUE
  ),
  (
    'requests.response_sent.v1', 'requests', FALSE, FALSE,
    'A response was approved and sent back to the requesting organization (approve_response()), which also advances the parent request to status=responded. Recipients: specific_users([request.created_by]), mirroring the existing legacy new_response notification exactly. Sourced from the PARENT REQUEST (source_record_type=request), not a new response source type -- see header. CAP-003 Phase 1.6B.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- ─── 5. approve_request(): atomic requests.sent.v1 enqueue ─────────
CREATE OR REPLACE FUNCTION approve_request(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      requests;
  v_ref      TEXT;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to approve this request';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not awaiting approval. Refresh and try again.';
  END IF;

  v_ref := generate_reference_number(v_row.from_section_id, 'request');

  UPDATE requests SET status = 'sent', is_locked = TRUE, reference_number = v_ref
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('request', p_request_id, v_actor, 'approved', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'request', p_request_id, 'Approved and sent request')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.6B: atomic outbox enqueue, same transaction as the
  -- domain mutation above.
  PERFORM platform_enqueue_outbox_event(
    'requests.sent.v1', 'requests', 'request', p_request_id, v_row.to_org_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'requests.sent.v1',
      'title_template_key', 'requests.sent',
      'template_params', jsonb_build_object(
        'request_id', p_request_id, 'reference_number', v_row.reference_number,
        'from_org_id', v_row.from_org_id, 'to_org_id', v_row.to_org_id,
        'from_section_id', v_row.from_section_id, 'approved_by', v_actor
      ),
      'priority', 'normal',
      'target_type', 'org_admins',
      'target_organization_id', v_row.to_org_id
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. return_request(): atomic requests.returned.v1 enqueue ──────
CREATE OR REPLACE FUNCTION return_request(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      requests;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to return this request';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE requests SET status = 'draft' WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('request', p_request_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'request', p_request_id, 'Returned request for changes')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.6B: atomic outbox enqueue, same transaction as the
  -- domain mutation above.
  PERFORM platform_enqueue_outbox_event(
    'requests.returned.v1', 'requests', 'request', p_request_id, v_row.from_org_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'requests.returned.v1',
      'title_template_key', 'requests.returned',
      'template_params', jsonb_build_object('request_id', p_request_id, 'returned_by', v_actor),
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

-- ─── 7. route_request(): atomic requests.routed.v1 enqueue ─────────
-- Every non-enqueue line (including the Phase 1.6A org-consistency
-- deviation documented in docs/89) is unchanged.
CREATE OR REPLACE FUNCTION route_request(
  p_request_id UUID,
  p_to_section_id UUID
) RETURNS SETOF requests AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      requests;
  v_authorized BOOLEAN;
  v_section_org UUID;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_request requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  SELECT org_id INTO v_section_org FROM sections WHERE id = p_to_section_id;
  IF v_section_org IS DISTINCT FROM v_row.to_org_id THEN
    RAISE EXCEPTION 'That section does not belong to the receiving organization';
  END IF;

  v_authorized := (
    (v_row.to_org_id = get_my_org_id() AND v_row.to_section_id IS NULL AND is_default_section_receiver(v_row.to_org_id))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
    OR (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to route this request';
  END IF;

  UPDATE requests SET to_section_id = p_to_section_id, status = 'in_progress', assigned_to = NULL
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'request', p_request_id, 'Routed to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'a section'))
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.6B: atomic outbox enqueue, same transaction as the
  -- domain mutation above.
  PERFORM platform_enqueue_outbox_event(
    'requests.routed.v1', 'requests', 'request', p_request_id, v_row.to_org_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'requests.routed.v1',
      'title_template_key', 'requests.routed',
      'template_params', jsonb_build_object('request_id', p_request_id, 'to_section_id', p_to_section_id, 'routed_by', v_actor),
      'priority', 'normal',
      'target_type', 'section',
      'target_section_id', p_to_section_id
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. assign_request(): atomic requests.assigned.v1 enqueue ──────
-- Conditional on p_user_id IS NOT NULL -- an unassignment fires no
-- event, mirroring the legacy `if (userId)` guard exactly.
CREATE OR REPLACE FUNCTION assign_request(
  p_request_id UUID,
  p_user_id UUID DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      requests;
  v_authorized BOOLEAN;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  v_authorized := (
    (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to assign this request';
  END IF;

  UPDATE requests SET assigned_to = p_user_id WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'request', p_request_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END)
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.6B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Conditional on a real assignee, mirroring
  -- the legacy notification's own guard.
  IF p_user_id IS NOT NULL THEN
    PERFORM platform_enqueue_outbox_event(
      'requests.assigned.v1', 'requests', 'request', p_request_id, v_row.to_org_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'requests.assigned.v1',
        'title_template_key', 'requests.assigned',
        'template_params', jsonb_build_object('request_id', p_request_id, 'assigned_to', p_user_id, 'assigned_by', v_actor),
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

-- ─── 9. approve_response(): atomic requests.response_sent.v1 enqueue ──
-- Sourced from the PARENT REQUEST (source_record_type='request',
-- source_record_id=v_req.id) -- see header for why no 'response'
-- source type is introduced.
CREATE OR REPLACE FUNCTION approve_response(
  p_response_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF responses AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      responses;
  v_req      requests;
  v_ref      TEXT;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_response requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM responses WHERE id = p_response_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Response not found';
  END IF;
  SELECT * INTO v_req FROM requests WHERE id = v_row.request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent request not found';
  END IF;
  IF NOT (v_req.from_org_id = get_my_org_id() OR v_req.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() OR v_req.status = 'cancelled' THEN
    RAISE EXCEPTION 'Not authorized to approve this response';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This response is not awaiting approval. Refresh and try again.';
  END IF;

  v_ref := generate_reference_number(v_req.to_section_id, 'response');

  UPDATE responses SET status = 'sent', is_locked = TRUE, reference_number = v_ref
  WHERE id = p_response_id RETURNING * INTO v_row;

  UPDATE requests SET status = 'responded' WHERE id = v_req.id;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('response', p_response_id, v_actor, 'approved', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'response', p_response_id, 'Approved and sent response')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.6B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_type='request' /
  -- source_record_id=v_req.id -- the PARENT request, not the response.
  PERFORM platform_enqueue_outbox_event(
    'requests.response_sent.v1', 'requests', 'request', v_req.id, v_req.from_org_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'requests.response_sent.v1',
      'title_template_key', 'requests.response_sent',
      'template_params', jsonb_build_object(
        'request_id', v_req.id, 'response_id', p_response_id,
        'reference_number', v_row.reference_number, 'approved_by', v_actor
      ),
      'priority', 'normal',
      'target_type', 'specific_users',
      'target_user_ids', jsonb_build_array(v_req.created_by)
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
