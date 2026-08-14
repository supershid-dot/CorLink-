-- ============================================================
-- CorLink — CAP-003 Prisoner Letters Notification Integration
-- (Phase 1.9B)
-- ============================================================
-- Wires exactly FOUR real business events, each atomically enqueued
-- inside its own already-existing, server-authoritative Phase 1.9A
-- mutation RPC (patch-prisoner-letters-server-mutation-foundation.sql):
--
--   1. prisoner_letter.sent.v1     -- create_prisoner_letter()
--   2. prisoner_letter.routed.v1   -- route_prisoner_letter() (no assignee)
--   3. prisoner_letter.assigned.v1 -- route_prisoner_letter() (with assignee)
--   4. prisoner_letter.reply_sent.v1 -- create_prisoner_letter_reply()
--
-- This is recipient-event integration, not a redesign of Prisoner
-- Letters. Phase 1.9A's mutation foundation (the narrowed access model,
-- state-transition rules, audit_logs writes, existing legacy
-- NotificationsAPI.notify() call sites in js/data/prisoner-letters-
-- api.js, untouched by this patch) is preserved byte-for-byte; the only
-- addition to each modified RPC is (a) `RETURNING id INTO v_audit_id`
-- appended to its existing audit_logs INSERT, (b) one new DECLARE
-- variable, and (c) one atomic platform_enqueue_outbox_event() call
-- (conditional, for route_prisoner_letter) as the final statement
-- before RETURN. No digital signature, no CAP-003 Phase 2, no email/
-- push/SMS, no new Prisoner Letters lifecycle state, no new target-
-- descriptor kind.
--
-- ─── CONFIDENTIALITY — ABSOLUTE ─────────────────────────────────────
-- Zero prisoner-identifying or correspondence-content field is ever
-- written into any outbox payload, notification_intents row, or
-- user_notifications row by this patch: no prisoner_id, no prisoner_
-- name, no letter/reply body, no attachment filename/path, no
-- reference_number (docs/95 §16 classifies reference_number as safe,
-- but per this milestone's own governing instruction — "default to
-- omitting it" unless proven both non-confidential AND actually
-- necessary — it is left out; the notification's structural identifier
-- (prisoner_letter_id) is enough for the destination view, which
-- re-fetches everything itself under RLS). template_params below
-- carries only: prisoner_letter_id, to_org_id/to_section_id/
-- assigned_to (structural routing identifiers, not prisoner identity),
-- and actor ids. All four NOTIFICATION_TEMPLATES entries render fully
-- generic, prisoner-content-free text (see js/data/notifications-api.js
-- changes), matching the governing example wording exactly.
--
-- ─── Candidate inventory (all 6 Phase 1.9A commands re-evaluated) ────
-- create_prisoner_letter -- IMPLEMENTED as prisoner_letter.sent.v1.
--   submitLetter()'s own legacy behavior notifies orgSupervisorUserIds
--   (toOrgId) with type 'new_prisoner_letter' — the destination org's
--   supervisors/admins, exactly matching the existing 'org_admins'
--   target kind's own resolution (org_supervisor_user_ids()). Target:
--   org_admins(to_org_id).
-- mark_prisoner_letter_received -- DEFERRED. No legacy notification
--   fires (markReceived() in prisoner-letters-api.js only returns
--   `data`, no NotificationsAPI call — confirmed by direct inspection
--   of both the pre- and post-1.9A frontend). Implementing one here
--   would invent new recipient policy.
-- route_prisoner_letter -- IMPLEMENTED as TWO events, mirroring
--   routeLetter()'s own exclusive if/else legacy branching exactly (a
--   letter is either routed to a section with no named assignee, or
--   routed AND assigned in the same call — never both notifications
--   for one call):
--     - No assignee (p_assigned_to IS NULL): prisoner_letter.routed.v1,
--       recipients sectionUserIds(toSectionId, ['mcs_admin',
--       'authority_admin','supervisor']) in the legacy code — exactly
--       the existing 'section_leadership' target kind's own resolution.
--       Target: section_leadership(to_section_id).
--     - Assignee present: prisoner_letter.assigned.v1, recipients
--       [assignedTo] in the legacy code. Target:
--       specific_users([assigned_to]).
-- mark_prisoner_letter_slip_generated -- DEFERRED. No legacy
--   notification fires (markSlipGenerated() only returns; confirmed by
--   direct inspection) — an internal MCS-side operational action
--   (printing a hand-over slip), not a cross-party event with any
--   evidenced recipient.
-- create_prisoner_letter_reply -- IMPLEMENTED as prisoner_letter.
--   reply_sent.v1. createReply()'s own legacy behavior notifies
--   [letterData.submitted_by] with type 'letter_replied' — the
--   original MCS submitter. Target: specific_users([submitted_by]).
-- mark_prisoner_letter_delivered -- DEFERRED. No legacy notification
--   fires (markDelivered() only returns; confirmed by direct
--   inspection). The only plausible recipient (the authority-side
--   assignee, confirming their reply was delivered) has no legacy
--   precedent — implementing one would invent new recipient policy,
--   exactly the reasoning docs/94 already used for internal
--   collaboration's own no-legacy-notification RPCs.
--
-- ─── source_record_type: 'prisoner_letter', the letter's OWN id ──────
-- Unlike Internal Collaboration (Phase 1.8B), where the thread's own id
-- and the legacy notification's parent-record id lived in disjoint id
-- spaces, Prisoner Letters' legacy NotificationsAPI.notify() calls
-- already carry recordType:'prisoner_letter', recordId:<the letter's
-- own id> (submitLetter/routeLetter/createReply, all three — confirmed
-- by direct inspection of js/data/prisoner-letters-api.js). This
-- CAP-003 integration sources every event from that SAME id
-- (prisoner_letters.id), so — unlike 1.8B — a genuine structural dedup
-- against the legacy 'new_prisoner_letter'/'letter_replied' rows is
-- possible and implemented (see the notifications-api.js changes
-- below), entirely on (type, record type, record id, time-window) —
-- never on message text or prisoner name.
--
-- Prisoner Letters has no dedicated reply detail route (prisoner-
-- letter-detail.js renders every reply inline on the letter's own
-- page), so prisoner_letter.reply_sent.v1 is sourced from the PARENT
-- LETTER, never a new 'prisoner_reply' source type — the same decision
-- Requests/Entry/Internal Collaboration each already made for their own
-- reply-shaped events, and exactly what docs/95 §18 itself anticipated.
--
-- ─── intent_user_can_view_prisoner_letter(): mirrors the NEW (Phase
--    1.9A / docs/96) prisoner_letters_select predicate, NOT docs/95
--    §18's stale contract description ──────────────────────────────
-- docs/95 §18 (written BEFORE Phase 1.9A existed) described a future
-- adapter contract that mirrors the OLD, broader prisoner_letters_
-- select ("any is_prisoner_letters_staff-flagged member of either
-- party org", explicitly "must NOT narrow to assigned_to/submitted_by").
-- That RLS no longer exists — Phase 1.9A's own Product Decision A
-- replaced it with a narrower model (MCS side: submitted_by+flag OR
-- supervisor; authority side: assigned_to+flag OR supervisor; see
-- docs/96 §4/§15), and prisoner_letters_select itself was rewritten to
-- match. Per this milestone's own governing instruction ("Derive its
-- semantics from the NEW narrowed Prisoner Letters authorization model
-- in Phase 1.9A/docs/96. Do not copy old broad RLS behavior."), the
-- adapter below is a complete, candidate-parameterized mirror of the
-- CURRENT live prisoner_letters_select — not docs/95 §18's now-obsolete
-- description. is_prisoner_letters_staff()/is_supervisor_or_above() are
-- both auth.uid()-bound, so each is expanded into its own parameterized
-- form here (users.is_prisoner_letters_staff for the CANDIDATE user;
-- is_supervisor_or_above() = is_super_admin() OR role IN ('mcs_admin',
-- 'authority_admin','supervisor'), read directly from supabase/rls.sql
-- and reproduced the identical way intent_user_can_view_internal_
-- request()'s own admin/supervisor-bypass branch already does) — never
-- calling a session-bound helper, for the same reason every prior
-- CAP-003 adapter in this codebase avoids them (the worker's own
-- identity, not the candidate's, would otherwise be checked).
--
-- ─── Target mapping (no new target kinds) ─────────────────────────
-- prisoner_letter.sent.v1: org_admins(to_org_id).
-- prisoner_letter.routed.v1: section_leadership(to_section_id).
-- prisoner_letter.assigned.v1: specific_users([assigned_to]).
-- prisoner_letter.reply_sent.v1: specific_users([submitted_by]).
-- All reuse existing target kinds ('org_admins', 'section_leadership',
-- 'specific_users') and their existing resolution SQL verbatim — ZERO
-- changes to resolve_notification_intent()'s target-resolution CASE,
-- the target-shape CHECK constraint, or process_platform_outbox_
-- batch(). create_notification_intent() and resolve_notification_
-- intent() each gain exactly ONE new source_record_type entry/dispatch
-- branch, the identical minimal-extension pattern already used four
-- times before (Phase 1.4A/1.6B/1.7B/1.8B).
--
-- ─── Idempotency/correlation ───────────────────────────────────────
-- Each event's idempotency_key is the fresh audit_logs.id captured via
-- `RETURNING id INTO v_audit_id` at the exact moment of the real
-- mutation. No two-descriptor fan-out is needed here — route_prisoner_
-- letter()'s two possible events are mutually exclusive per call (the
-- legacy if/else branching this mirrors never fires both), so each is
-- a single enqueue with its own fresh gen_random_uuid() correlation_id,
-- causation_id NULL (no upstream CAP-003 event caused any of these) —
-- identical shape to every single-descriptor producer already in this
-- codebase.
--
-- ─── Safe payload ──────────────────────────────────────────────────
-- template_params carries only structural identifiers: prisoner_
-- letter_id, to_org_id/to_section_id/assigned_to, and actor ids. No
-- prisoner_id, prisoner_name, body (letter or reply), reference_number,
-- or attachment reference is ever read by any of the three enqueue call
-- sites — this is the strictest payload of any CAP-003 module
-- integrated so far, matching this milestone's own "smaller than for
-- other modules" directive and docs/95 §17's classification (prisoner
-- identity/body/attachment fields are all Class C — highly
-- confidential).
--
-- ─── Legacy coexistence / dedup ──────────────────────────────────────
-- No legacy NotificationsAPI.notify() call site in js/data/prisoner-
-- letters-api.js is removed, altered, or suppressed. Genuine structural
-- dedup IS added (unlike Phase 1.8B) since legacy and CAP-003 events
-- for this module share the SAME id space (prisoner_letters.id) — see
-- notifications-api.js's own MIGRATED_EVENT_MAP additions below. This
-- reduces (does not eliminate — the legacy row itself still persists
-- with the prisoner's name in it, unavoidable without touching legacy
-- code, out of scope here) the DISPLAYED confidentiality exposure: once
-- a safe CAP-003 counterpart exists, the name-bearing legacy row is
-- hidden from the merged feed and the safe, generic CAP-003 text is
-- shown instead. Purely structural — never message-text matching.
--
-- ─── What this patch does NOT do ──────────────────────────────────
-- No digital signature, no signature placeholder in any payload. No
-- CAP-003 Phase 2 work. No email/push/SMS delivery, no notification
-- preferences/digest. No new Prisoner Letters lifecycle state. No new
-- target-descriptor kind. No change to Prisoner Letters' narrowed
-- access model, RLS, direct-write closure, attachment finalization
-- lock, or reply immutability (Phase 1.9A, completely untouched beyond
-- the three RPCs' own new trailing enqueue statements). No change to
-- process_platform_outbox_batch() (worker remains fully generic — no
-- source/module branching added).
--
-- Idempotent -- safe to re-run (the three modified functions' own
-- parameter lists don't change -- only their bodies gain new trailing
-- statements; CREATE OR REPLACE is sufficient, no DROP FUNCTION
-- needed).
-- ============================================================

BEGIN;

-- ─── 1. Closed source_record_type allowlist: extended by exactly
--    'prisoner_letter'. ─────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence', 'internal_request', 'prisoner_letter'));

-- ─── 2. intent_user_can_view_prisoner_letter(): complete,
--    candidate-parameterized mirror of the CURRENT (Phase 1.9A)
--    prisoner_letters_select's own USING clause -- see header for why
--    this deliberately diverges from docs/95 §18's now-stale contract
--    description. ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION intent_user_can_view_prisoner_letter(p_letter_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM prisoner_letters pl
    WHERE pl.id = p_letter_id
      AND (
        (
          pl.from_prison_id = (SELECT org_id FROM users WHERE id = p_user)
          AND (
            (
              COALESCE((SELECT is_prisoner_letters_staff FROM users WHERE id = p_user), FALSE)
              AND pl.submitted_by = p_user
            )
            OR (
              COALESCE((SELECT is_super_admin FROM users WHERE id = p_user), FALSE)
              OR EXISTS (
                SELECT 1 FROM user_assignments ua
                WHERE ua.user_id = p_user AND ua.is_active = TRUE
                  AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
              )
            )
          )
        )
        OR (
          pl.to_org_id = (SELECT org_id FROM users WHERE id = p_user)
          AND (
            (
              COALESCE((SELECT is_prisoner_letters_staff FROM users WHERE id = p_user), FALSE)
              AND pl.assigned_to = p_user
            )
            OR (
              COALESCE((SELECT is_super_admin FROM users WHERE id = p_user), FALSE)
              OR EXISTS (
                SELECT 1 FROM user_assignments ua
                WHERE ua.user_id = p_user AND ua.is_active = TRUE
                  AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
              )
            )
          )
        )
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION intent_user_can_view_prisoner_letter(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ─── 3a. create_notification_intent(): its own independent
--    source_record_type guard also needs 'prisoner_letter' added.
--    Every other line is byte-for-byte identical to the true latest
--    Phase 1.8B body. ─────────────────────────────────────────────
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

  -- Closed source_record_type allowlist (CAP-003 Phase 1.9B: extended
  -- with 'prisoner_letter', see header). Structural, at creation time,
  -- never a silent fake at resolution time.
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence', 'internal_request', 'prisoner_letter') THEN
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
--    dispatch branch ('prisoner_letter' -> intent_user_can_view_
--    prisoner_letter()), following the identical pattern Phase
--    1.4A/1.6B/1.7B/1.8B added for 'meeting'/'request'/'external_
--    correspondence'/'internal_request'. Target-resolution CASE is
--    completely unchanged. Every other line is byte-for-byte identical
--    to the true latest Phase 1.8B body. ─────────────────────────────
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
      -- closed dispatcher, CAP-003 Phase 1.9B extends it with exactly
      -- one more branch ('prisoner_letter') backed by intent_user_can_
      -- view_prisoner_letter() above. No fallthrough/default branch
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
      ELSIF v_intent.source_record_type = 'prisoner_letter' THEN
        v_authorized := intent_user_can_view_prisoner_letter(v_intent.source_record_id, v_candidate);
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
    'prisoner_letter.sent.v1', 'prisoner_letters', FALSE, FALSE,
    'A prisoner letter was submitted to a destination authority organization (create_prisoner_letter()). Recipients: org_admins(to_org_id), mirroring the existing legacy new_prisoner_letter notification''s own orgSupervisorUserIds(toOrgId) recipient set exactly. No prisoner identity or letter content in payload. CAP-003 Phase 1.9B.',
    TRUE
  ),
  (
    'prisoner_letter.routed.v1', 'prisoner_letters', FALSE, FALSE,
    'A prisoner letter was routed to a section with no named assignee (route_prisoner_letter(), unassigned branch). Recipients: section_leadership(to_section_id), mirroring the existing legacy new_prisoner_letter notification exactly. No prisoner identity or letter content in payload. CAP-003 Phase 1.9B.',
    TRUE
  ),
  (
    'prisoner_letter.assigned.v1', 'prisoner_letters', FALSE, FALSE,
    'A prisoner letter was routed and assigned to a specific staff member (route_prisoner_letter(), assigned branch). Recipients: specific_users([assigned_to]), mirroring the existing legacy new_prisoner_letter notification exactly. No prisoner identity or letter content in payload. CAP-003 Phase 1.9B.',
    TRUE
  ),
  (
    'prisoner_letter.reply_sent.v1', 'prisoner_letters', FALSE, FALSE,
    'An authority reply to a prisoner letter was sent (create_prisoner_letter_reply()). Recipients: specific_users([submitted_by]), mirroring the existing legacy letter_replied notification exactly. Sourced from the PARENT LETTER, not a new reply source type. No prisoner identity or reply content in payload. CAP-003 Phase 1.9B.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- ─── 5. create_prisoner_letter(): atomic prisoner_letter.sent.v1
--    enqueue. Every non-enqueue line is byte-for-byte unchanged from
--    the true Phase 1.9A production body. ───────────────────────────
CREATE OR REPLACE FUNCTION create_prisoner_letter(
  p_prisoner_ref UUID,
  p_from_prison_id UUID,
  p_to_org_id UUID,
  p_body TEXT
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
  v_prisoner prisoners;
  v_ref   TEXT;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;
  IF p_prisoner_ref IS NULL THEN
    RAISE EXCEPTION 'prisoner_ref is required';
  END IF;

  IF NOT is_prisoner_letters_staff() THEN
    RAISE EXCEPTION 'Not authorized to submit prisoner letters';
  END IF;
  IF p_from_prison_id IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'You may only submit prisoner letters on behalf of your own organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_from_prison_id AND o.type = 'mcs') THEN
    RAISE EXCEPTION 'The sending organization must be an MCS organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_to_org_id AND o.type = 'authority') THEN
    RAISE EXCEPTION 'The destination organization must be an authority organization';
  END IF;

  SELECT * INTO v_prisoner FROM prisoners WHERE id = p_prisoner_ref AND org_id = p_from_prison_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner not found in your organization''s registry';
  END IF;

  v_ref := generate_prisoner_letter_reference(p_from_prison_id);

  INSERT INTO prisoner_letters (
    prisoner_ref, prisoner_id, prisoner_name, from_prison_id, to_org_id, body,
    submitted_by, status, reference_number, slip_generated
  ) VALUES (
    p_prisoner_ref, v_prisoner.id_card_number, v_prisoner.full_name, p_from_prison_id, p_to_org_id, p_body,
    v_actor, 'submitted', v_ref, FALSE
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'prisoner_letter', v_row.id, 'Submitted prisoner letter for ' || v_prisoner.full_name)
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.9B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_type='prisoner_letter' /
  -- source_record_id=v_row.id (the letter's own id). No prisoner
  -- identity/content in the payload.
  PERFORM platform_enqueue_outbox_event(
    'prisoner_letter.sent.v1', 'prisoner_letters', 'prisoner_letter', v_row.id, get_my_org_id(), v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'prisoner_letter.sent.v1',
      'title_template_key', 'prisoner_letter.sent',
      'template_params', jsonb_build_object('prisoner_letter_id', v_row.id, 'to_org_id', p_to_org_id, 'sent_by', v_actor),
      'priority', 'normal',
      'target_type', 'org_admins',
      'target_organization_id', p_to_org_id
    ),
    v_audit_id
  );

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. route_prisoner_letter(): atomic TWO-EVENT (mutually exclusive
--    per call) enqueue, mirroring routeLetter()'s own if/else legacy
--    branching. Every non-enqueue line is byte-for-byte unchanged from
--    the true Phase 1.9A production body. ───────────────────────────
CREATE OR REPLACE FUNCTION route_prisoner_letter(
  p_letter_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_prisoner_letter requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF v_row.status = 'delivered' THEN
    RAISE EXCEPTION 'This prisoner letter has already been delivered and can no longer be routed';
  END IF;
  IF NOT (v_row.to_org_id = get_my_org_id() AND is_supervisor_or_above()) THEN
    RAISE EXCEPTION 'Not authorized to route this prisoner letter';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM v_row.to_org_id THEN
    RAISE EXCEPTION 'That section does not belong to the destination organization';
  END IF;
  IF p_assigned_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM users u WHERE u.id = p_assigned_to
      AND u.is_active AND u.org_id = v_row.to_org_id AND u.is_prisoner_letters_staff
  ) THEN
    RAISE EXCEPTION 'Cannot assign to a user who is inactive, in a different organization, or not designated for Prisoner Letters duty';
  END IF;

  UPDATE prisoner_letters SET to_section_id = p_to_section_id, assigned_to = p_assigned_to
  WHERE id = p_letter_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'prisoner_letter', p_letter_id, 'Routed prisoner letter to section')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.9B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Exactly one of the two events below fires
  -- per call, mirroring routeLetter()'s own exclusive if(assignedTo)/
  -- else legacy branching -- never both for one invocation.
  IF p_assigned_to IS NOT NULL THEN
    PERFORM platform_enqueue_outbox_event(
      'prisoner_letter.assigned.v1', 'prisoner_letters', 'prisoner_letter', p_letter_id, get_my_org_id(), v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'prisoner_letter.assigned.v1',
        'title_template_key', 'prisoner_letter.assigned',
        'template_params', jsonb_build_object('prisoner_letter_id', p_letter_id, 'assigned_to', p_assigned_to, 'assigned_by', v_actor),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(p_assigned_to)
      ),
      v_audit_id
    );
  ELSE
    PERFORM platform_enqueue_outbox_event(
      'prisoner_letter.routed.v1', 'prisoner_letters', 'prisoner_letter', p_letter_id, get_my_org_id(), v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'prisoner_letter.routed.v1',
        'title_template_key', 'prisoner_letter.routed',
        'template_params', jsonb_build_object('prisoner_letter_id', p_letter_id, 'to_section_id', p_to_section_id, 'routed_by', v_actor),
        'priority', 'normal',
        'target_type', 'section_leadership',
        'target_section_id', p_to_section_id
      ),
      v_audit_id
    );
  END IF;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. create_prisoner_letter_reply(): atomic prisoner_letter.
--    reply_sent.v1 enqueue. Sourced from the PARENT LETTER. Every
--    non-enqueue line is byte-for-byte unchanged from the true Phase
--    1.9A production body. ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_prisoner_letter_reply(
  p_letter_id UUID,
  p_body TEXT
) RETURNS SETOF prisoner_replies AS $$
DECLARE
  v_actor  UUID := auth.uid();
  v_letter prisoner_letters;
  v_reply  prisoner_replies;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter_reply requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  SELECT * INTO v_letter FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF NOT (
    v_letter.to_org_id = get_my_org_id()
    AND ((is_prisoner_letters_staff() AND v_letter.assigned_to IS NOT NULL AND v_letter.assigned_to = v_actor) OR is_supervisor_or_above())
  ) THEN
    RAISE EXCEPTION 'Not authorized to reply to this prisoner letter';
  END IF;
  IF v_letter.status NOT IN ('submitted', 'received') THEN
    RAISE EXCEPTION 'This prisoner letter is not awaiting a reply. Refresh and try again.';
  END IF;

  INSERT INTO prisoner_replies (letter_id, body, replied_by)
  VALUES (p_letter_id, p_body, v_actor) RETURNING * INTO v_reply;

  UPDATE prisoner_letters SET status = 'replied' WHERE id = p_letter_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'prisoner_letter', p_letter_id, 'Replied to prisoner letter')
  RETURNING id INTO v_audit_id;

  -- CAP-003 Phase 1.9B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. source_record_id=p_letter_id -- the PARENT
  -- letter, not the reply.
  PERFORM platform_enqueue_outbox_event(
    'prisoner_letter.reply_sent.v1', 'prisoner_letters', 'prisoner_letter', p_letter_id, get_my_org_id(), v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'prisoner_letter.reply_sent.v1',
      'title_template_key', 'prisoner_letter.reply_sent',
      'template_params', jsonb_build_object('prisoner_letter_id', p_letter_id, 'replied_by', v_actor),
      'priority', 'normal',
      'target_type', 'specific_users',
      'target_user_ids', jsonb_build_array(v_letter.submitted_by)
    ),
    v_audit_id
  );

  RETURN NEXT v_reply;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
