-- ============================================================
-- CorLink — CAP-003 Phase 1.8B: Internal Collaboration
-- Notification Integration
-- ============================================================
-- ─── Recovery context ────────────────────────────────────────────────
-- This milestone was independently implemented, tested, documented, and
-- committed TWICE previously in this environment (local commits
-- 4453a91... and 50dc11c7c5e970ab17816b49bf070fc3473e548d), and both
-- times the commit was lost to container reclamation before a separate
-- push-only checkpoint could push it. Per an explicit, permanent
-- workflow-change instruction from the governing task, this THIRD
-- implementation is committed AND pushed immediately upon completion,
-- with no separate checkpoint step. This file is a fresh, independent
-- re-derivation from the current repository (not a reconstruction from
-- memory of the lost commits' own source) that happens to reach the same
-- architecture both prior derivations reached, because the underlying
-- evidence (RLS, RPC bodies, legacy notify() call sites) is unchanged.
--
-- Wires exactly FIVE real business events, each atomically enqueued
-- inside its own already-existing, server-authoritative Phase 1.8A
-- mutation RPC (patch-internal-collaboration-server-mutation-
-- foundation.sql):
--
--   1. internal_collaboration.routed.v1   -- create_internal_request(),
--                                             reroute_internal_request()
--   2. internal_collaboration.returned.v1 -- return_internal_request_to_sender()
--   3. internal_collaboration.assigned.v1 -- assign_internal_request()
--   4. internal_collaboration.reply_sent.v1 -- approve_internal_request_reply()
--   5. internal_collaboration.reply_returned.v1 -- return_internal_request_reply()
--
-- This is recipient-event integration, not a redesign of Internal
-- Collaboration. Phase 1.8A's mutation foundation (authorization,
-- status-transition rules, audit_logs writes, existing legacy
-- NotificationsAPI.notify() call sites in js/data/internal-requests-
-- api.js, untouched by this patch) is preserved byte-for-byte; the only
-- addition to each modified RPC is (a) `RETURNING id INTO v_audit_id`
-- appended to its existing audit_logs INSERT, (b) one new DECLARE
-- variable, and (c) one (or, for approve_internal_request_reply, a
-- two-descriptor fan-out) atomic platform_enqueue_outbox_event() call as
-- the final statement before RETURN.
--
-- ─── Candidate inventory (all 11 Phase 1.8A commands re-evaluated) ────
-- create_internal_request -- IMPLEMENTED as internal_collaboration.
--   routed.v1. create()'s own legacy behavior notifies
--   sectionUserIds(toSectionId) with type 'new_request' — semantically
--   the thread being routed/sent to a section for the first time, the
--   same "routed" concept reroute_internal_request() below re-fires on
--   a later hop. Target: section(to_section_id).
-- mark_internal_request_received -- DEFERRED. No legacy notification
--   fires (markReceived() in internal-requests-api.js only returns
--   `data`, no NotificationsAPI call — confirmed by direct inspection).
--   Implementing one here would invent new recipient policy.
-- reroute_internal_request -- IMPLEMENTED, second producer of
--   internal_collaboration.routed.v1 alongside create_internal_request()
--   above. reroute()'s own legacy behavior notifies
--   sectionUserIds(toSectionId) with type 'new_request' — identical
--   recipient shape to create()'s own. Target: section(to_section_id).
-- return_internal_request_to_sender -- IMPLEMENTED as internal_
--   collaboration.returned.v1. returnToSender()'s own legacy behavior
--   notifies sectionUserIds(internalRequest.from_section_id) — the
--   ORIGIN section the thread is being sent back to, which after the
--   RPC's own UPDATE is the row's new to_section_id (from_section_id
--   is copied into to_section_id — see return_internal_request_to_
--   sender()'s own UPDATE). Target: section(v_row.to_section_id) (the
--   post-update value, i.e. the origin section).
-- assign_internal_request -- IMPLEMENTED as internal_collaboration.
--   assigned.v1. assign()'s own legacy behavior conditionally notifies
--   [userId] only when userId is non-null (an unassignment fires no
--   legacy notification) — mirrored exactly, same conditional-enqueue
--   shape as Requests'/Entry's own assign_request()/assign_entry().
--   Target: specific_users([assigned_to]), conditional.
-- close_internal_request -- DEFERRED. No legacy notification fires
--   (close() only returns `data` — confirmed by direct inspection).
-- draft_internal_request_reply -- DEFERRED. Draft-only; no legacy
--   notification fires (draftReply() only returns `data`).
-- update_internal_request_reply_draft -- DEFERRED. Same reasoning.
-- submit_internal_request_reply -- DEFERRED. Legacy recipients
--   ('approval_requested') are either a single named approverId
--   (informational routing only, not an authorization boundary) or
--   sectionUserIds(to_section_id, ['mcs_admin','authority_admin',
--   'supervisor']) — an internal, same-org, pre-approval step. Same
--   reasoning Requests'/Entry's own submit_request()/submit_entry_
--   reply() already used to defer in Phase 1.6B/1.7B: genuinely lower
--   value, not required to prove this milestone's architecture points,
--   and the 'section_leadership' target kind already exists for a
--   future milestone to wire it.
-- approve_internal_request_reply -- IMPLEMENTED as internal_
--   collaboration.reply_sent.v1. Sole RPC that atomically transitions a
--   reply to status='sent' AND the parent thread to status='responded'
--   — the real "sent" business event, matching Requests'/Entry's own
--   requests.response_sent.v1/entry.reply_sent.v1 precedent (named
--   after the sub-object's own transition, not the RPC name). Legacy
--   recipients: approveReply()'s own askingSide Set = sectionUserIds
--   (internalRequest.from_section_id) UNION {internalRequest.
--   created_by} — a genuine TWO-DESCRIPTOR fan-out (a section target
--   AND a specific individual who may not be a member of that section
--   any more), mirrored exactly using complete_task()'s own established
--   two-descriptor fan-out pattern (patch-task-meeting-notification-
--   events.sql): one shared correlation_id, two enqueue calls, the
--   second's idempotency_key deterministically derived via md5(...)
--   from the same audit_logs.id. Target: section(from_section_id) AND
--   specific_users([thread creator]).
-- return_internal_request_reply -- IMPLEMENTED as internal_
--   collaboration.reply_returned.v1. returnReply()'s own legacy
--   behavior notifies [data.created_by] — the reply's own drafter.
--   Target: specific_users([reply creator]).
--
-- ─── source_record_type: 'internal_request', not the parent Request/
--    Entry ──────────────────────────────────────────────────────────
-- internal_requests_select's own RLS (supabase/rls.sql) is a single,
-- non-additive USING clause:
--   from_section_id IN (my_section_ids()) OR to_section_id IN
--   (my_section_ids()) OR previous_section_id IN (my_section_ids()) OR
--   created_by = auth.uid() OR (is_supervisor_or_above() AND
--   get_my_org_id() = scope_org_id('section', to_section_id))
-- This is neither a superset nor a subset of intent_user_can_view_
-- request()'s or intent_user_can_view_entry()'s own branches (both
-- generalized from their OWN respective SELECT policies, not this
-- one), so reusing either existing adapter — or defaulting to the
-- parent's own source_record_type — would authorize (or deny) strictly
-- the wrong set of people for an Internal Collaboration thread. Using
-- the thread's OWN id (internal_requests.id) also structurally prevents
-- a dedup collision with Requests'/Entry's own legacy/CAP-003
-- notifications on the same parent record, since legacy Internal
-- Collaboration notifications always carry the PARENT's id (via
-- internal-requests-api.js's own parentRef() helper), never the
-- thread's own id — the two id spaces never overlap.
--
-- Reply events (reply_sent.v1/reply_returned.v1) are sourced from the
-- PARENT THREAD (source_record_type='internal_request', source_record_
-- id=<internal_requests.id>), never a separate 'internal_request_reply'
-- source type — internal_request_replies has no dedicated detail route
-- (request-detail.js/entry-detail.js both render every reply inline on
-- the thread's own page), and both events' only target candidates are
-- already covered by intent_user_can_view_internal_request()'s own
-- branches, so a second adapter would duplicate authorization the
-- thread adapter already provides.
--
-- ─── intent_user_can_view_internal_request(): complete mirror of
--    internal_requests_select, INCLUDING its admin/supervisor bypass ──
-- internal_requests_select has exactly ONE SELECT policy (unlike
-- Requests' 4 or Entry's 2), so this adapter mirrors it completely, not
-- just a "core" subset. Crucially, unlike Entry's own intent_user_can_
-- view_entry() (which deliberately has NO admin/supervisor bypass,
-- because is_entry_staff() itself has none — a previous bypass was
-- reported and removed as a bug), internal_requests_select DOES include
-- an unconditional `is_supervisor_or_above() AND get_my_org_id() =
-- scope_org_id('section', to_section_id)` branch. Copying Entry's own
-- no-bypass adapter here would silently UNDER-authorize relative to the
-- real table RLS; copying Requests' adapter mechanically would not
-- reproduce this exact single-policy shape either. Expanding is_
-- supervisor_or_above() = is_admin() OR has_role('supervisor'),
-- is_admin() = is_super_admin() OR has_role('mcs_admin') OR has_role
-- ('authority_admin'), has_role(p_role) = is_super_admin() OR EXISTS
-- (user_assignments WHERE role=p_role AND is_active) (all read directly
-- from supabase/rls.sql) gives the parameterized bypass condition below.
-- Like every prior adapter, this is fully parameterized by p_user and
-- never calls a session-bound helper (my_section_ids()/is_supervisor_
-- or_above()), since both are auth.uid()-bound and would evaluate
-- against the WORKER's own identity, never the candidate being
-- authorized, when invoked from inside resolve_notification_intent().
--
-- ─── Target mapping (no new target kinds) ─────────────────────────
-- internal_collaboration.routed.v1: section(to_section_id).
-- internal_collaboration.returned.v1: section(v_row.to_section_id)
--   (post-update — the origin section the thread was returned to).
-- internal_collaboration.assigned.v1: specific_users([assigned_to]),
--   conditional on a non-null assignee.
-- internal_collaboration.reply_sent.v1: section(from_section_id) AND
--   specific_users([thread creator]) — two-descriptor fan-out.
-- internal_collaboration.reply_returned.v1: specific_users([reply
--   creator]).
-- All reuse existing target kinds ('section', 'specific_users') and
-- their existing resolution SQL verbatim — ZERO changes to resolve_
-- notification_intent()'s target-resolution CASE, the target-shape
-- CHECK constraint, or process_platform_outbox_batch().
-- create_notification_intent() and resolve_notification_intent() each
-- gain exactly ONE new source_record_type entry/dispatch branch, same
-- pattern Phase 1.4A/1.6B/1.7B already used three times.
--
-- ─── Idempotency/correlation ───────────────────────────────────────
-- Each event's idempotency_key is the fresh audit_logs.id captured via
-- `RETURNING id INTO v_audit_id` at the exact moment of the real
-- mutation. For approve_internal_request_reply()'s two-descriptor
-- fan-out, one shared v_correlation_id := gen_random_uuid() across both
-- calls (mirroring complete_task()'s own task.completed.v1 precedent
-- exactly), first idempotency_key = raw v_audit_id, second =
-- md5(v_audit_id::TEXT || ':reply_sent_section')::UUID — deterministic,
-- never timestamp-derived. causation_id is NULL for every event
-- (no upstream CAP-003 event caused any of these).
--
-- ─── Safe payload ──────────────────────────────────────────────────
-- template_params carries only structural identifiers: internal_
-- request_id, reply_id, to_section_id/from_section_id, assigned/actor/
-- returned/routed-by user ids. subject and body (both the thread's own
-- and any reply's) are DELIBERATELY EXCLUDED from every payload —
-- Internal Collaboration threads may carry the same category of
-- sensitive operational content as the parent Request/Entry case they
-- support, and neither docs/89 nor docs/91 affirmatively confirms
-- subject/body as non-confidential for this module either, so the same
-- conservative fallback applies. No comment/attachment content is ever
-- read by any of the six enqueue call sites.
--
-- ─── Legacy coexistence / dedup ──────────────────────────────────────
-- No legacy NotificationsAPI.notify() call site in js/data/internal-
-- requests-api.js is removed, altered, or suppressed. These five events
-- are deliberately NOT added to MIGRATED_EVENT_MAP (js/data/
-- notifications-api.js): every legacy Internal Collaboration
-- notification carries the PARENT Request/Entry's own id (record_type
-- 'request'/'external_correspondence', via parentRef()), never the
-- internal_requests thread's own id — MIGRATED_EVENT_MAP's own
-- structural-identity match keys on (mapped type, record type, record
-- id), and since source_record_type='internal_request' with a THREAD id
-- can never equal a legacy row's own ('request'/'external_
-- correspondence', PARENT id), no dedup entry could ever match — adding
-- one would be dead code, not a real dedup path.
--
-- ─── What this patch does NOT do ──────────────────────────────────
-- No new target-descriptor kind. No change to process_platform_outbox_
-- batch() (worker remains fully generic — no source/module branching
-- added). No change to Internal Collaboration's authorization, status-
-- transition rules, RLS, or the audit_logs write shape of any of the
-- five modified RPCs — every non-enqueue line of each is byte-for-byte
-- unchanged from its true Phase 1.8A production body. No Prisoner
-- Letters integration, no CAP-003 Phase 2 work.
--
-- Idempotent -- safe to re-run (none of the five modified functions'
-- own parameter lists change -- only their bodies gain new trailing
-- statements; CREATE OR REPLACE is sufficient, no DROP FUNCTION needed).
-- ============================================================

BEGIN;

-- ─── 1. Closed source_record_type allowlist: extended by exactly
--    'internal_request'. ─────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence', 'internal_request'));

-- ─── 2. intent_user_can_view_internal_request(): complete,
--    candidate-parameterized mirror of internal_requests_select's own
--    single USING clause, INCLUDING its admin/supervisor bypass branch
--    -- see header for why this diverges from Entry's own no-bypass
--    adapter. ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION intent_user_can_view_internal_request(p_internal_request_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.id = p_internal_request_id
      AND (
        ir.from_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR ir.to_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR ir.previous_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        )
        OR ir.created_by = p_user
        OR (
          -- Admin/supervisor-bypass equivalent, parameterized by p_user:
          -- matches the real RLS helper chain's own expansion, each
          -- term reproduced directly as its own EXISTS(user_assignments)
          -- form rather than calling any session-bound function.
          (
            COALESCE((SELECT is_super_admin FROM users WHERE id = p_user), FALSE)
            OR EXISTS (
              SELECT 1 FROM user_assignments ua
              WHERE ua.user_id = p_user AND ua.is_active = TRUE
                AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
            )
          )
          AND (SELECT org_id FROM users WHERE id = p_user) = scope_org_id('section', ir.to_section_id)
        )
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION intent_user_can_view_internal_request(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ─── 3a. create_notification_intent(): its own independent
--    source_record_type guard also needs 'internal_request' added.
--    Every other line is byte-for-byte identical to the true latest
--    Phase 1.7B body. ─────────────────────────────────────────────
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

  -- Closed source_record_type allowlist (CAP-003 Phase 1.8B: extended
  -- with 'internal_request', see header). Structural, at creation time,
  -- never a silent fake at resolution time.
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence', 'internal_request') THEN
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
--    dispatch branch ('internal_request' -> intent_user_can_view_
--    internal_request()), following the identical pattern Phase
--    1.4A/1.6B/1.7B added for 'meeting'/'request'/'external_
--    correspondence'. Target-resolution CASE is completely unchanged.
--    Every other line is byte-for-byte identical to the true latest
--    Phase 1.7B body. ─────────────────────────────────────────────
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
      -- closed dispatcher, CAP-003 Phase 1.8B extends it with exactly
      -- one more branch ('internal_request') backed by intent_user_can_
      -- view_internal_request() above. No fallthrough/default branch
      -- that could silently authorize an unrecognized source type.
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
      ELSIF v_intent.source_record_type = 'internal_request' THEN
        v_authorized := intent_user_can_view_internal_request(v_intent.source_record_id, v_candidate);
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

-- ─── 4. Register the five implemented event types ───────────────────
INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES
  (
    'internal_collaboration.routed.v1', 'internal_collaboration', FALSE, FALSE,
    'An internal collaboration thread was sent or re-routed to a receiving section (create_internal_request(), reroute_internal_request()). Recipients: section(to_section_id), mirroring the existing legacy new_request notification''s own sectionUserIds(toSectionId) recipient set exactly. CAP-003 Phase 1.8B.',
    TRUE
  ),
  (
    'internal_collaboration.returned.v1', 'internal_collaboration', FALSE, FALSE,
    'An internal collaboration thread was sent back to its originating section (return_internal_request_to_sender()). Recipients: section(from_section_id), mirroring the existing legacy new_request notification exactly. CAP-003 Phase 1.8B.',
    TRUE
  ),
  (
    'internal_collaboration.assigned.v1', 'internal_collaboration', FALSE, FALSE,
    'An internal collaboration thread was assigned to a specific staff member (assign_internal_request(), conditional on a non-null assignee). Recipients: specific_users([assigned_to]), mirroring the existing legacy new_request notification exactly. CAP-003 Phase 1.8B.',
    TRUE
  ),
  (
    'internal_collaboration.reply_sent.v1', 'internal_collaboration', FALSE, FALSE,
    'A reply to an internal collaboration thread was approved and sent (approve_internal_request_reply()), which also advances the parent thread to status=responded. Recipients: section(from_section_id) AND specific_users([thread creator]), mirroring the existing legacy new_response notification''s own two-part askingSide recipient set exactly. Sourced from the PARENT THREAD (source_record_type=internal_request), not a new reply source type. CAP-003 Phase 1.8B.',
    TRUE
  ),
  (
    'internal_collaboration.reply_returned.v1', 'internal_collaboration', FALSE, FALSE,
    'A submitted internal collaboration reply draft was returned to its drafter for changes (return_internal_request_reply()). Recipients: specific_users([reply.created_by]), mirroring the existing legacy draft_returned notification exactly. Sourced from the PARENT THREAD. CAP-003 Phase 1.8B.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- ─── 5. create_internal_request(): atomic internal_collaboration.
--    routed.v1 enqueue. Every non-enqueue line is byte-for-byte
--    unchanged from the true Phase 1.8A production body. ─────────────
CREATE OR REPLACE FUNCTION create_internal_request(
  p_from_section_id UUID,
  p_to_section_id UUID,
  p_subject TEXT,
  p_body TEXT,
  p_parent_request_id UUID DEFAULT NULL,
  p_parent_entry_id UUID DEFAULT NULL,
  p_subject_language TEXT DEFAULT 'en',
  p_language TEXT DEFAULT 'en',
  p_deadline TIMESTAMPTZ DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_internal_request requires an authenticated caller';
  END IF;
  IF p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'subject and body are required';
  END IF;
  IF (p_parent_request_id IS NULL) = (p_parent_entry_id IS NULL) THEN
    RAISE EXCEPTION 'Exactly one of parent_request_id or parent_entry_id is required';
  END IF;

  IF NOT (
    p_from_section_id IN (SELECT my_section_ids())
    OR (is_supervisor_or_above() AND scope_org_id('section', p_from_section_id) = get_my_org_id())
  ) THEN
    RAISE EXCEPTION 'Not authorized to loop in a section on behalf of the sending section';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'That section does not belong to your organization';
  END IF;
  IF NOT internal_requests_parent_startable(p_parent_request_id, p_parent_entry_id) THEN
    RAISE EXCEPTION 'The parent case cannot accept a new internal collaboration thread right now';
  END IF;
  IF NOT internal_requests_parent_deadline_ok(p_parent_request_id, p_parent_entry_id, p_deadline) THEN
    RAISE EXCEPTION 'Deadline cannot be later than the parent case''s own deadline';
  END IF;

  INSERT INTO internal_requests (
    parent_request_id, parent_entry_id, from_section_id, to_section_id, created_by,
    subject, subject_language, body, language, deadline
  ) VALUES (
    p_parent_request_id, p_parent_entry_id, p_from_section_id, p_to_section_id, v_actor,
    p_subject, COALESCE(p_subject_language, 'en'), p_body, COALESCE(p_language, 'en'), p_deadline
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'internal_request', v_row.id, 'Created internal request "' || p_subject || '"')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.8B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_type='internal_request' /
  -- source_record_id=v_row.id (the thread's own id, not the parent).
  PERFORM platform_enqueue_outbox_event(
    'internal_collaboration.routed.v1', 'internal_collaboration', 'internal_request', v_row.id, get_my_org_id(), v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'internal_collaboration.routed.v1',
      'title_template_key', 'internal_collaboration.routed',
      'template_params', jsonb_build_object('internal_request_id', v_row.id, 'to_section_id', p_to_section_id, 'routed_by', v_actor),
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

-- ─── 6. reroute_internal_request(): second producer of internal_
--    collaboration.routed.v1, alongside create_internal_request() above.
CREATE OR REPLACE FUNCTION reroute_internal_request(
  p_internal_request_id UUID,
  p_to_section_id UUID
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'reroute_internal_request requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to reroute this internal request';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'That section does not belong to your organization';
  END IF;

  UPDATE internal_requests SET
    to_section_id = p_to_section_id, status = 'sent',
    received_by = NULL, received_at = NULL, assigned_to = NULL
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'internal_request', p_internal_request_id,
    'Re-routed internal request to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'another section'))
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.8B: atomic outbox enqueue, same transaction as the
  -- domain mutation above.
  PERFORM platform_enqueue_outbox_event(
    'internal_collaboration.routed.v1', 'internal_collaboration', 'internal_request', p_internal_request_id, get_my_org_id(), v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'internal_collaboration.routed.v1',
      'title_template_key', 'internal_collaboration.routed',
      'template_params', jsonb_build_object('internal_request_id', p_internal_request_id, 'to_section_id', p_to_section_id, 'routed_by', v_actor),
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

-- ─── 7. return_internal_request_to_sender(): atomic internal_
--    collaboration.returned.v1 enqueue. Target section is v_row.
--    to_section_id AFTER the UPDATE (the origin section the thread was
--    just sent back to), matching returnToSender()'s own legacy
--    sectionUserIds(internalRequest.from_section_id) recipient set
--    exactly, since from_section_id (pre-update) becomes to_section_id
--    (post-update) by this RPC's own UPDATE statement.
CREATE OR REPLACE FUNCTION return_internal_request_to_sender(
  p_internal_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
  v_note  TEXT;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_internal_request_to_sender requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    v_row.to_section_id IN (SELECT my_section_ids())
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to return this internal request to its sending section';
  END IF;
  IF v_row.status NOT IN ('sent', 'received', 'in_progress') THEN
    RAISE EXCEPTION 'This internal request can no longer be returned to its sending section. Refresh and try again.';
  END IF;

  UPDATE internal_requests SET
    to_section_id = v_row.from_section_id, status = 'sent',
    received_by = NULL, received_at = NULL, assigned_to = NULL
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  v_note := regexp_replace(COALESCE(p_comment, ''), '<[^>]+>', '', 'g');
  v_note := left(btrim(v_note), 200);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned_to_sender', 'internal_request', p_internal_request_id,
    'Sent back to originating section' || CASE WHEN v_note <> '' THEN ': ' || v_note ELSE '' END)
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.8B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Target is v_row.to_section_id AFTER the
  -- UPDATE above -- the origin section.
  PERFORM platform_enqueue_outbox_event(
    'internal_collaboration.returned.v1', 'internal_collaboration', 'internal_request', p_internal_request_id, get_my_org_id(), v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'internal_collaboration.returned.v1',
      'title_template_key', 'internal_collaboration.returned',
      'template_params', jsonb_build_object('internal_request_id', p_internal_request_id, 'to_section_id', v_row.to_section_id, 'returned_by', v_actor),
      'priority', 'normal',
      'target_type', 'section',
      'target_section_id', v_row.to_section_id
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. assign_internal_request(): atomic internal_collaboration.
--    assigned.v1 enqueue, conditional on a non-null assignee (an
--    unassignment fires no legacy notification, mirrored exactly). ────
CREATE OR REPLACE FUNCTION assign_internal_request(
  p_internal_request_id UUID,
  p_user_id UUID DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_internal_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to assign this internal request';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE internal_requests SET
    assigned_to = p_user_id, status = CASE WHEN p_user_id IS NOT NULL THEN 'in_progress' ELSE 'received' END
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'internal_request', p_internal_request_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END)
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.8B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Conditional on a real assignee, mirroring
  -- the legacy notification's own `if (userId)` guard.
  IF p_user_id IS NOT NULL THEN
    PERFORM platform_enqueue_outbox_event(
      'internal_collaboration.assigned.v1', 'internal_collaboration', 'internal_request', p_internal_request_id, get_my_org_id(), v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'internal_collaboration.assigned.v1',
        'title_template_key', 'internal_collaboration.assigned',
        'template_params', jsonb_build_object('internal_request_id', p_internal_request_id, 'assigned_to', p_user_id, 'assigned_by', v_actor),
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

-- ─── 9. approve_internal_request_reply(): atomic internal_
--    collaboration.reply_sent.v1 TWO-DESCRIPTOR fan-out (section(from_
--    section_id) AND specific_users([thread creator])), mirroring
--    complete_task()'s own task.completed.v1 fan-out pattern exactly --
--    one shared v_correlation_id, second idempotency_key deterministic
--    via md5(...). Sourced from the PARENT THREAD (source_record_type=
--    'internal_request', source_record_id=v_ir.id) -- see header for
--    why no separate reply source type is introduced. ────────────────
CREATE OR REPLACE FUNCTION approve_internal_request_reply(
  p_reply_id UUID
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
  v_ir    internal_requests;
  v_audit_id UUID;
  v_correlation_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_internal_request_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = v_row.internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent internal request not found';
  END IF;
  IF NOT (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_ir.to_section_id)) THEN
    RAISE EXCEPTION 'Not authorized to approve this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE internal_request_replies SET
    status = 'sent', approved_by = v_actor, approved_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  UPDATE internal_requests SET status = 'responded' WHERE id = v_ir.id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'internal_request', v_ir.id, 'Approved and sent internal reply')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.8B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Two descriptors -- section(from_section_id)
  -- is unconditional, specific_users([v_ir.created_by]) mirrors the
  -- legacy askingSide Set's explicit .add(internalRequest.created_by).
  -- The second descriptor is gated on the creator NOT currently being a
  -- from_section_id member -- the legacy recipient set is a Set (each
  -- person notified once even if they qualify both ways), and the
  -- thread creator is very commonly ALSO a from_section member (create_
  -- internal_request()'s own authorization requires it in the ordinary
  -- case), so firing both descriptors unconditionally would double-
  -- notify that common case, which the legacy Set-based code never
  -- does. Membership is evaluated at approval time here, matching the
  -- legacy code's own synchronous Set construction at the same moment
  -- (this narrows only which descriptors are ENQUEUED, not how either
  -- descriptor is later authorized -- section(from_section_id)'s own
  -- resolution at drain time remains fully dynamic/unsnapshotted).
  v_correlation_id := gen_random_uuid();

  PERFORM platform_enqueue_outbox_event(
    'internal_collaboration.reply_sent.v1', 'internal_collaboration', 'internal_request', v_ir.id, get_my_org_id(), v_actor,
    v_correlation_id, NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'internal_collaboration.reply_sent.v1',
      'title_template_key', 'internal_collaboration.reply_sent',
      'template_params', jsonb_build_object('internal_request_id', v_ir.id, 'reply_id', p_reply_id, 'approved_by', v_actor),
      'priority', 'normal',
      'target_type', 'section',
      'target_section_id', v_ir.from_section_id
    ),
    v_audit_id
  );

  IF v_ir.created_by IS NULL OR NOT EXISTS (
    SELECT 1 FROM user_assignments ua
    CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
    WHERE ua.user_id = v_ir.created_by AND ua.is_active = TRUE AND sid = v_ir.from_section_id
  ) THEN
    PERFORM platform_enqueue_outbox_event(
      'internal_collaboration.reply_sent.v1', 'internal_collaboration', 'internal_request', v_ir.id, get_my_org_id(), v_actor,
      v_correlation_id, NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'internal_collaboration.reply_sent.v1',
        'title_template_key', 'internal_collaboration.reply_sent',
        'template_params', jsonb_build_object('internal_request_id', v_ir.id, 'reply_id', p_reply_id, 'approved_by', v_actor),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(v_ir.created_by)
      ),
      md5(v_audit_id::TEXT || ':reply_sent_section')::UUID
    );
  END IF;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 10. return_internal_request_reply(): atomic internal_
--    collaboration.reply_returned.v1 enqueue. Sourced from the PARENT
--    THREAD, same reasoning as above. ─────────────────────────────────
CREATE OR REPLACE FUNCTION return_internal_request_reply(
  p_reply_id UUID
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
  v_ir    internal_requests;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_internal_request_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = v_row.internal_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent internal request not found';
  END IF;
  IF NOT (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_ir.to_section_id)) THEN
    RAISE EXCEPTION 'Not authorized to return this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE internal_request_replies SET
    status = 'draft', pending_approval_by = NULL
  WHERE id = p_reply_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'internal_request', v_ir.id, 'Returned internal reply for changes')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.8B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_id=v_ir.id -- the PARENT
  -- thread, not the reply.
  PERFORM platform_enqueue_outbox_event(
    'internal_collaboration.reply_returned.v1', 'internal_collaboration', 'internal_request', v_ir.id, get_my_org_id(), v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'internal_collaboration.reply_returned.v1',
      'title_template_key', 'internal_collaboration.reply_returned',
      'template_params', jsonb_build_object('internal_request_id', v_ir.id, 'reply_id', p_reply_id, 'returned_by', v_actor),
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
