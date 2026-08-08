-- ============================================================
-- CAP-003 Phase 1.4 -- Notification Module Integration Foundation.
--
-- Implements docs/78 §25's Phase 1.4 line item and docs/82's own
-- explicit forward reference ("Requests, Entry, Internal
-- Collaboration, Prisoner Letters, Tasks, and Meetings all remain
-- deferred to Phase 1.4's own module adapters") -- the first real
-- module producer wired atomically through the existing CAP-003
-- pipeline (platform_enqueue_outbox_event -> worker ->
-- create_notification_intent/resolve_notification_intent ->
-- user_notifications), with ZERO new business-event vocabulary
-- invented beyond what this milestone's own narrow, evidence-based
-- module inventory justifies.
--
-- ─── Module inventory summary (full reasoning: docs/85) ────────────
-- Every module was inspected for (a) a real server-authoritative
-- mutation RPC atomic enqueue could hook into, and (b) whether its
-- natural notification-worthy events fit Phase 1.2's already-
-- supported six target-descriptor kinds:
--   * Requests, Entry/External Correspondence, Internal Collaboration,
--     Prisoner Letters -- NO server-side mutation RPC at all; the
--     client performs a direct table INSERT (js/data/requests-api.js,
--     entry-api.js, internal-requests-api.js,
--     prisoner-letters-api.js). Atomic enqueue is not possible today
--     without first introducing a new server-side RPC -- a larger-
--     scope change than this milestone's own module-adapter mandate.
--     DEFERRED, per the governing instruction's own explicit
--     allowance for this exact situation.
--   * Meetings -- real server RPCs exist (create_meeting,
--     cancel_meeting, reschedule_booking), but every one of its
--     natural events fans out to the full participant set, which
--     requires a meeting_participants target-descriptor kind Phase
--     1.2 does not support (one of docs/82's eight explicitly
--     deferred target kinds). DEFERRED -- adding a new target kind is
--     Phase 1.2 authorization-surface work, not a module-adapter, and
--     is out of this milestone's scope per the governing instruction
--     ("If a module requires a target not supported by Phase 1.2:
--     STOP for that module. Report the missing target contract.").
--   * Tasks -- real server RPCs exist (create_task, assign_task,
--     complete_task, ...). task.completed's natural recipients
--     (creator + task_watchers) hit the SAME missing-target-kind
--     blocker as Meetings (task_watchers is also one of docs/82's
--     eight deferred kinds) -- DEFERRED. task.assigned, however, has
--     exactly ONE recipient (the newly assigned user, already
--     validated by assign_task itself as an active same-org user) --
--     this fits Phase 1.2's ALREADY-SUPPORTED specific_users target
--     kind with zero target-model changes required.
--
-- task.assigned via assign_task() is therefore the ONLY event in this
-- inventory that both (a) has a real atomic server-side mutation path
-- and (b) needs no Phase 1.2 target-descriptor extension -- the
-- single, narrowly-justified pilot integration for this milestone,
-- per the governing instruction's "do NOT integrate every module in
-- one milestone" directive.
--
-- ─── The one genuine extension this milestone DOES make: closed
-- source_record_type dispatch ─────────────────────────────────────
-- Phase 1.2's create_notification_intent/resolve_notification_intent
-- reject every source_record_type except 'workflow_instance' and
-- 'platform' -- and its own header comment names this closed set as
-- deliberately narrow "for this milestone", explicitly deferring
-- Requests/Entry/Internal Collaboration/Prisoner Letters/Tasks/
-- Meetings to "Phase 1.4's own module adapters". Extending it with
-- 'task' is therefore not a redesign of Phase 1.2's architecture but
-- the literal, explicitly-anticipated next step it named. The
-- extension is narrow and structural (one more allowed literal in a
-- CASE/IN-list, never dynamic SQL) and is backed by
-- intent_user_can_view_task(), a candidate-generalized mirror of the
-- existing can_view_task() RLS helper (patch-shared-task-foundation.
-- sql) -- exactly the same generalization pattern Phase 1.2 itself
-- used to derive intent_user_can_view_workflow_instance() from
-- can_view_workflow_instance(). No parallel permission system is
-- invented; every branch reuses tasks/task_assignments/task_watchers/
-- user_assignments/scope_section_ids() directly.
--
-- ─── Generic event->intent mapping, not a worker branch ────────────
-- The governing instruction is explicit: "Do not modify
-- process_platform_outbox_batch with module-specific branches if a
-- generic event->intent mapping layer can handle it." Phase 1.3's
-- worker currently hardcodes a single literal event_type string
-- ('platform.generic_notification_request.v1') as the only
-- "generic-envelope-shaped" event it will process. This migration
-- replaces that hardcoded literal with a registry-driven boolean
-- column (platform_event_type_registry.uses_generic_notification_
-- envelope) -- any event_type whose registry row is flagged TRUE is
-- processed via the exact same generic
-- create_notification_intent()-parameter-passthrough path, regardless
-- of which module owns it. This is data-driven configuration, not a
-- new code branch per module -- task.assigned.v1 is simply the second
-- registry row ever flagged this way; a future module's event_type
-- needs only its own registry row, no worker code change.
--
-- ─── Notification authorization stays owned by CAP-003 ─────────────
-- assign_task()'s own pre-existing authorization (who may assign whom
-- to what task) is completely unchanged and untouched by this patch.
-- The new outbox enqueue call merely records that a task.assigned.v1
-- event occurred; CAP-003's own resolve_notification_intent() late
-- revalidation (via intent_user_can_view_task(), added here) remains
-- the sole, final authority over whether the assignee actually
-- receives a notification. These two authorization decisions are
-- never merged.
--
-- ─── What this migration does NOT do ────────────────────────────
-- No Requests/Entry/Internal Collaboration/Prisoner Letters/Meetings
-- integration. No task.completed event (blocked on the task_watchers
-- target-kind gap -- a Phase 1.2 extension, not a module adapter). No
-- removal of assign_task's existing legacy INSERT INTO notifications
-- call (dual-write continues; legacy cutover is explicitly out of
-- scope). No change to process_platform_outbox_batch's retry/dead-
-- letter state machine, batch-claiming, or backoff logic. No new
-- target-descriptor kind.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── 1. Generic event->intent mapping: registry-driven, not a worker
--    code branch (see header) ──────────────────────────────────────
ALTER TABLE platform_event_type_registry
  ADD COLUMN IF NOT EXISTS uses_generic_notification_envelope BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN platform_event_type_registry.uses_generic_notification_envelope IS
  'CAP-003 Phase 1.4: TRUE means this event_type''s payload directly carries create_notification_intent()''s own parameters (notification_type, title_template_key, template_params, priority, target_type, target_*), and process_platform_outbox_batch() will route it through that generic passthrough path. Configuration data, not a code branch -- any module can opt an event_type into this shape by registering it with this flag set, with zero worker code changes.';

-- The Phase 1.3 generic test/validation envelope already behaves this
-- way (it defined the shape) -- mark it accordingly so behavior is
-- unchanged for every existing caller.
UPDATE platform_event_type_registry
SET uses_generic_notification_envelope = TRUE
WHERE event_type = 'platform.generic_notification_request.v1';

-- Register the one real business event this milestone introduces.
INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES (
  'task.assigned.v1', 'tasks', FALSE, FALSE,
  'A user was actively assigned to a task (assign_task()). Single-recipient event (the newly assigned user) -- fits Phase 1.2''s existing specific_users target kind with no target-model changes. CAP-003 Phase 1.4''s pilot module integration.',
  TRUE
)
ON CONFLICT (event_type) DO NOTHING;

-- ─── 2. process_platform_outbox_batch(): registry-driven dispatch
--    instead of one hardcoded event_type literal. Everything else
--    (claiming, retry/backoff, dead-letter, per-item exception
--    isolation) is byte-for-byte unchanged from Phase 1.3. ──────────
CREATE OR REPLACE FUNCTION process_platform_outbox_batch(p_limit INTEGER DEFAULT 25, p_worker_id TEXT DEFAULT NULL)
RETURNS TABLE (
  event_id        UUID,
  event_type      TEXT,
  outcome         TEXT,
  intent_id       UUID,
  attempt_count   INTEGER,
  next_attempt_at TIMESTAMPTZ,
  final_status    TEXT
) AS $$
DECLARE
  v_limit          INTEGER;
  v_worker_id      TEXT;
  rec              RECORD;
  v_event          platform_outbox_events;
  v_intent_id      UUID;
  v_resolve_status TEXT;
  v_resolve_count  INTEGER;
  v_skip_count     INTEGER;
  v_outcome        TEXT;
  v_new_attempt    INTEGER;
  v_next_attempt   TIMESTAMPTZ;
  v_final_status   TEXT;
  v_error_text     TEXT;
  v_ret_attempts   INTEGER;
BEGIN
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 200);
  v_worker_id := COALESCE(p_worker_id, 'pid:' || pg_backend_pid()::TEXT);

  FOR rec IN SELECT d.id FROM platform_outbox_events_due_for_processing(v_limit) d LOOP
    v_event := NULL;
    v_intent_id := NULL;
    v_outcome := NULL;
    v_next_attempt := NULL;
    v_final_status := NULL;
    v_error_text := NULL;
    v_ret_attempts := NULL;

    BEGIN
      -- Claim: never blocks. A row another in-flight batch already
      -- holds is simply skipped and left for the next call --
      -- identical guarantee CAP-002 Phase 5.4's own SKIP LOCKED claim
      -- already provides and this codebase's own concurrency suites
      -- already verify for that dispatcher.
      SELECT * INTO v_event FROM platform_outbox_events WHERE id = rec.id FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        v_outcome := 'skipped_locked';
      -- Re-derive eligibility from the LOCKED row -- never trust the
      -- earlier non-locking candidate snapshot (governing instruction;
      -- identical discipline to every workflow_sla_clocks_due_for_*
      -- consumer in this codebase). A concurrent batch, or an operator
      -- replay/dead-letter transition, may have changed this row's
      -- state since discovery.
      ELSIF v_event.status <> 'pending' THEN
        v_outcome := 'already_processed';
        v_ret_attempts := v_event.attempt_count;
      ELSIF v_event.next_attempt_at IS NOT NULL AND v_event.next_attempt_at > clock_timestamp() THEN
        v_outcome := 'skipped_not_due';
        v_ret_attempts := v_event.attempt_count;
      ELSE
        -- Generic event->intent mapping (CAP-003 Phase 1.4, see
        -- header): any event_type whose registry row is flagged
        -- uses_generic_notification_envelope is processed via the
        -- same passthrough path, regardless of owning module. Never
        -- dynamic SQL -- a plain EXISTS lookup against already-
        -- trusted, server-managed configuration data. Any other event_type
        -- is a deterministic, never-retriable-into-success condition; it
        -- is still routed through the SAME bounded retry/dead-letter
        -- machinery below (never a special-cased immediate dead-letter)
        -- so there is exactly one worker-state system.
        IF NOT EXISTS (
          SELECT 1 FROM platform_event_type_registry r
          WHERE r.event_type = v_event.event_type AND r.uses_generic_notification_envelope = TRUE
        ) THEN
          RAISE EXCEPTION 'unsupported_event_type: % (no platform_event_type_registry row with uses_generic_notification_envelope=TRUE; register the event type before enqueuing it)', v_event.event_type
            USING ERRCODE = 'P0001';
        END IF;

        -- create_notification_intent() derives organization_id/
        -- source_module/source_record_type/source_record_id FROM the
        -- outbox event row itself (Phase 1.2's own design) -- only the
        -- notification-shape/target-descriptor fields come from
        -- payload. Every field extracted here is validated by
        -- create_notification_intent()'s own existing required-field
        -- checks and by notification_intents' own CHECK constraints
        -- (target-shape, bounded array, closed target_type allowlist,
        -- versioned notification_type pattern) -- nothing here
        -- duplicates that validation; a malformed/out-of-range payload
        -- surfaces as a genuine exception from that reused primitive,
        -- caught by this same per-item handler.
        v_intent_id := create_notification_intent(
          v_event.id,
          v_event.payload ->> 'notification_type',
          v_event.payload ->> 'title_template_key',
          COALESCE(v_event.payload -> 'template_params', '{}'::JSONB),
          v_event.payload ->> 'priority',
          v_event.payload ->> 'target_type',
          CASE WHEN v_event.payload ? 'target_user_ids'
               THEN ARRAY(SELECT jsonb_array_elements_text(v_event.payload -> 'target_user_ids'))::UUID[]
               ELSE NULL END,
          NULLIF(v_event.payload ->> 'target_organization_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_section_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_workflow_instance_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_work_item_id', '')::UUID
        );

        -- resolve_notification_intent() (Phase 1.2, reused verbatim --
        -- never duplicated): candidate resolution + per-candidate
        -- authorization revalidation, idempotent (FOR UPDATE on the
        -- intent row -- a concurrent resolver, including a second
        -- worker batch that raced to the same intent, observes the
        -- already-recorded terminal status rather than double-
        -- processing). Zero-resolved-count is a legitimate outcome
        -- (see header) -- never itself raises, never itself a reason to
        -- retry/dead-letter this outbox event.
        SELECT r.status, r.resolved_count, r.skipped_count
          INTO v_resolve_status, v_resolve_count, v_skip_count
          FROM resolve_notification_intent(v_intent_id) r;

        UPDATE platform_outbox_events
        SET status = 'completed', processed_at = clock_timestamp(),
            claimed_by = v_worker_id, claimed_at = clock_timestamp(),
            last_error = NULL
        WHERE id = v_event.id;

        v_final_status := 'completed';
        v_outcome := CASE WHEN v_resolve_count = 0 THEN 'processed_zero_recipients' ELSE 'processed' END;
        v_ret_attempts := v_event.attempt_count;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      -- Failure isolation: this block's implicit savepoint rolls back
      -- only this item's own writes (e.g. a partially-inserted intent
      -- row that never committed) -- every other item in this batch,
      -- already processed earlier in the loop, is unaffected. Bounded,
      -- safe error text only -- never the raw payload, never a stack
      -- trace, truncated defensively regardless of source (governing
      -- instruction: "Do not persist... full confidential payload...
      -- secrets").
      v_error_text := LEFT(SQLERRM, 500);

      IF v_event.id IS NULL OR v_event.id IS DISTINCT FROM rec.id THEN
        -- The claim itself never completed (extremely rare -- the
        -- locking SELECT itself failed) -- we hold no lock and no
        -- known attempt_count for this row, so we make no further
        -- write against it; it remains 'pending' and will be
        -- reconsidered by a future batch call.
        v_outcome := 'failed_before_claim: ' || v_error_text;
      ELSE
        v_new_attempt := v_event.attempt_count + 1;
        v_ret_attempts := v_new_attempt;

        IF v_new_attempt >= 5 THEN
          UPDATE platform_outbox_events
          SET status = 'dead_letter', attempt_count = v_new_attempt,
              last_error = v_error_text,
              claimed_by = v_worker_id, claimed_at = clock_timestamp()
          WHERE id = v_event.id;
          v_final_status := 'dead_letter';
          v_outcome := 'dead_lettered';
        ELSE
          v_next_attempt := clock_timestamp() + platform_outbox_worker_backoff_interval(v_new_attempt);
          UPDATE platform_outbox_events
          SET status = 'pending', attempt_count = v_new_attempt, next_attempt_at = v_next_attempt,
              last_error = v_error_text,
              claimed_by = v_worker_id, claimed_at = clock_timestamp()
          WHERE id = v_event.id;
          v_final_status := 'pending';
          v_outcome := 'retry_scheduled';
        END IF;
      END IF;
    END;

    event_id := rec.id;
    event_type := v_event.event_type;
    outcome := v_outcome;
    intent_id := v_intent_id;
    attempt_count := v_ret_attempts;
    next_attempt_at := v_next_attempt;
    final_status := v_final_status;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION process_platform_outbox_batch(INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION process_platform_outbox_batch(INTEGER, TEXT) TO service_role;

-- ─── 3. intent_user_can_view_task(): candidate-generalized mirror of
--    can_view_task() (patch-shared-task-foundation.sql), exactly the
--    same generalization Phase 1.2 applied to derive
--    intent_user_can_view_workflow_instance() from
--    can_view_workflow_instance(). Every branch reuses the real
--    tables/helpers directly -- no parallel permission logic. ────────
CREATE OR REPLACE FUNCTION intent_user_can_view_task(p_task_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT intent_user_is_super_admin(p_user) OR EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.id = p_task_id
      AND t.organization_id = (SELECT org_id FROM users WHERE id = p_user)
      AND (
        t.created_by = p_user
        OR t.completed_by = p_user
        OR EXISTS (
          SELECT 1 FROM task_assignments ta
          WHERE ta.task_id = t.id AND ta.user_id = p_user AND ta.is_active
        )
        OR EXISTS (
          SELECT 1 FROM task_watchers tw
          WHERE tw.task_id = t.id AND tw.user_id = p_user
        )
        OR t.visibility = 'organization'
        OR (t.visibility = 'section' AND t.owning_section_id IN (
          SELECT sid FROM user_assignments ua
          CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
        ))
        OR (
          EXISTS (
            SELECT 1 FROM user_assignments ua
            WHERE ua.user_id = p_user AND ua.is_active = TRUE
              AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
          )
          AND (t.owning_section_id IS NULL OR t.owning_section_id IN (
            SELECT sid FROM user_assignments ua
            CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
            WHERE ua.user_id = p_user AND ua.is_active = TRUE
          ))
        )
        OR EXISTS (
          SELECT 1 FROM user_assignments ua
          WHERE ua.user_id = p_user AND ua.is_active = TRUE
            AND ua.role IN ('mcs_admin', 'authority_admin')
        )
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION intent_user_can_view_task(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ─── 4. Extend the closed source_record_type dispatch with 'task'
--    (see header for why this is the anticipated Phase 1.4 step, not
--    a redesign). Table CHECK constraint + both dispatch functions
--    updated together. ────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task'));

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
  p_target_work_item_id   UUID
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

  -- Closed source_record_type allowlist (CAP-003 Phase 1.4: extended
  -- with 'task', the one module adapter this milestone justifies --
  -- see header). Structural, at creation time, never a silent fake at
  -- resolution time.
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task') THEN
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
    ELSE
      RAISE EXCEPTION 'Unsupported target_type: %', p_target_type USING ERRCODE = '22023';
  END CASE;

  INSERT INTO notification_intents (
    outbox_event_id, organization_id, notification_type, title_template_key, template_params,
    source_module, source_record_type, source_record_id, priority,
    target_type, target_user_ids, target_organization_id, target_section_id,
    target_workflow_instance_id, target_work_item_id, target_key
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
  END CASE;

  IF v_candidates IS NOT NULL THEN
    FOREACH v_candidate IN ARRAY v_candidates LOOP
      IF v_candidate IS NULL THEN CONTINUE; END IF;

      IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_candidate AND is_active = TRUE) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Processing-time authorization revalidation (docs/78 §8) --
      -- closed dispatcher, CAP-003 Phase 1.4 extends it with exactly
      -- one more branch ('task') backed by intent_user_can_view_task()
      -- above. No fallthrough/default branch that could silently
      -- authorize an unrecognized source type.
      IF v_intent.source_record_type = 'workflow_instance' THEN
        v_authorized := intent_user_can_view_workflow_instance(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'platform' THEN
        v_authorized := TRUE;
      ELSIF v_intent.source_record_type = 'task' THEN
        v_authorized := intent_user_can_view_task(v_intent.source_record_id, v_candidate);
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

-- ─── 5. assign_task(): atomic outbox enqueue in the SAME transaction
--    as the task_assignments write (docs/78's own "same transaction
--    as the domain mutation" rule). Legacy INSERT INTO notifications
--    call is left completely unchanged (dual-write; legacy cutover is
--    explicitly out of scope). Idempotency key is the newly-created
--    task_assignments.id itself -- deterministic, already unique per
--    real assignment event, and the ON CONFLICT (task_id,user_id)
--    WHERE is_active DO NOTHING + early RETURN above already means
--    this code is reached at most once per genuine assignment. ─────
CREATE OR REPLACE FUNCTION assign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_assignment_id UUID;
  v_outbox_event_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to assign this task';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM users WHERE id = p_user_id AND org_id = v_task.organization_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Assignee must be an active user in the task''s organization';
  END IF;

  INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active)
  VALUES (p_task_id, p_user_id, v_actor, NOW(), TRUE)
  ON CONFLICT (task_id, user_id) WHERE is_active DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    RETURN; -- already actively assigned; idempotent no-op
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'task', p_task_id, 'Assigned task to user ' || p_user_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (p_user_id, 'task_assigned', 'task', p_task_id,
          'You were assigned to task "' || v_task.title || '"');

  -- CAP-003 Phase 1.4: atomic outbox enqueue, same transaction as the
  -- domain mutation above. p_target_user_ids is a single-element array
  -- since specific_users' target-shape CHECK requires the array form
  -- even for one recipient.
  v_outbox_event_id := platform_enqueue_outbox_event(
    'task.assigned.v1', 'tasks', 'task', p_task_id, v_task.organization_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'task.assigned.v1',
      'title_template_key', 'task.assigned',
      'template_params', jsonb_build_object('task_id', p_task_id, 'task_title', v_task.title, 'assigned_by', v_actor),
      'priority', 'normal',
      'target_type', 'specific_users',
      'target_user_ids', jsonb_build_array(p_user_id)
    ),
    v_assignment_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
