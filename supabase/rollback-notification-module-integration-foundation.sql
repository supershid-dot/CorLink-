-- CAP-003 Phase 1.4 notification module integration foundation --
-- rollback. Reverses patch-notification-module-integration-foundation.sql
-- exactly, restoring process_platform_outbox_batch(), create_notification_
-- intent(), resolve_notification_intent(), notification_intents'
-- source_record_type CHECK constraint, and assign_task() to their
-- exact pre-1.4 (Phase 1.3 / Phase 1.2 / Phase 1.0-era) bodies, drops
-- the new intent_user_can_view_task() adapter and the new
-- platform_event_type_registry.uses_generic_notification_envelope
-- column, and removes the task.assigned.v1 registry row.
\set ON_ERROR_STOP on
BEGIN;

-- ─── 1. assign_task(): restore to its exact pre-1.4 body (no atomic
--    outbox enqueue; legacy INSERT INTO notifications unchanged). ────
CREATE OR REPLACE FUNCTION assign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_assignment_id UUID;
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
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. resolve_notification_intent(): restore to its exact pre-1.4
--    (Phase 1.2) two-branch dispatch. ─────────────────────────────
-- ─── resolve_notification_intent -- internal/service-only ──────────
-- The synchronous primitive a future Phase 1.3 worker will call, one
-- intent at a time -- NOT the worker itself. Deterministic: load,
-- validate state, resolve target descriptor to candidates,
-- revalidate current authorization per candidate against the closed
-- source-type dispatcher, deduplicate, create user_notifications
-- idempotently (reusing Phase 1.1's own platform_create_user_notification
-- primitive directly rather than duplicating its dedup logic), record
-- the outcome, return a bounded structural result. Never claims
-- delivery -- delivery is not a concept this function has any notion of.
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

  -- Row lock: a concurrent resolver blocks here until the first one
  -- commits, then sees the already-recorded terminal status below and
  -- returns it as a safe idempotent no-op rather than re-resolving.
  SELECT * INTO v_intent FROM notification_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_id % does not reference an existing notification intent', p_intent_id USING ERRCODE = '22023';
  END IF;

  IF v_intent.status <> 'pending' THEN
    RETURN QUERY SELECT v_intent.status, v_intent.resolved_count, v_intent.skipped_count;
    RETURN;
  END IF;

  -- Target-descriptor resolution (docs/78 §7.2-§7.3): produces
  -- candidates only, never itself an authorization decision. Every
  -- one of these six branches reuses an existing, already-safe
  -- resolution helper/table rather than duplicating membership logic.
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

      -- Recipient existence/active-status check.
      IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_candidate AND is_active = TRUE) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Processing-time authorization revalidation (docs/78 §8) --
      -- late, against the SOURCE record's own authoritative model,
      -- never cached from enqueue time, never inferred from "same
      -- organization" or from notification metadata itself. Closed
      -- dispatcher: exactly the two source_record_type values allowed
      -- at intent-creation time are handled here; there is no
      -- fallthrough/default branch that could silently authorize an
      -- unrecognized source type.
      IF v_intent.source_record_type = 'workflow_instance' THEN
        v_authorized := intent_user_can_view_workflow_instance(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'platform' THEN
        -- No confidential source record exists to revalidate against
        -- -- active-user status (already checked above) is the whole
        -- authorization requirement for a platform-wide notice.
        v_authorized := TRUE;
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

-- ─── 3. create_notification_intent(): restore to its exact pre-1.4
--    (Phase 1.2) closed two-value allowlist. ─────────────────────
-- ─── create_notification_intent -- internal/service-only ───────────
-- Every business-identity field (organization_id, source_module,
-- source_record_type, source_record_id) is DERIVED from the parent
-- outbox event, never re-supplied and trusted from the caller --
-- the source reference is therefore structurally valid by
-- construction, not merely validated after the fact.
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

  -- Closed source_record_type allowlist -- structural, at creation
  -- time, never a silent fake at resolution time (governing
  -- instruction: "Unsupported source types must fail closed or remain
  -- deferred").
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform') THEN
    RAISE EXCEPTION 'source_record_type % has no generic Phase 1.2 authorization dispatch and remains deferred to a future module-adapter phase', v_event.source_record_type USING ERRCODE = '42501';
  END IF;

  -- Derive the target_key deterministically per target_type.
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

-- ─── 4. Restore notification_intents' source_record_type CHECK to its
--    exact pre-1.4 (Phase 1.2) two-value form. Refuses if any row now
--    depends on the removed 'task' value -- matches every other
--    refusing rollback in this codebase (non-destructive by default,
--    never silently discards real data). ──────────────────────────
DO $$
DECLARE v_task_rows INTEGER;
BEGIN
  SELECT count(*) INTO v_task_rows FROM notification_intents WHERE source_record_type = 'task';
  IF v_task_rows > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % notification_intents row(s) have source_record_type=''task''. Restoring the two-value CHECK constraint would leave existing data violating it. Resolve/archive these rows first if you intend to proceed.', v_task_rows;
  END IF;
END $$;

ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform'));

-- ─── 5. Drop intent_user_can_view_task() -- purely additive, no other
--    object depends on it once resolve_notification_intent() above is
--    restored. ────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS intent_user_can_view_task(UUID, UUID);

-- ─── 6. process_platform_outbox_batch(): restore to its exact pre-1.4
--    (Phase 1.3) single-hardcoded-literal dispatch. ────────────────
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
        -- Supported-event-shape dispatch (see header) -- closed,
        -- structural, never dynamic SQL. Any other event_type is a
        -- deterministic, never-retriable-into-success condition; it is
        -- still routed through the SAME bounded retry/dead-letter
        -- machinery below (never a special-cased immediate
        -- dead-letter) so there is exactly one worker-state system, per
        -- the governing instruction -- "do not retry forever on
        -- deterministic invalid data" is satisfied by the shared
        -- attempt cap applying uniformly, not by a second state
        -- machine. The stored last_error classification (below) is
        -- what lets an operator distinguish this case from a genuine
        -- transient/infrastructure failure.
        IF v_event.event_type <> 'platform.generic_notification_request.v1' THEN
          RAISE EXCEPTION 'unsupported_event_type: % (Phase 1.3 recognizes only platform.generic_notification_request.v1; per-module event types are Phase 1.4''s own concern)', v_event.event_type
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

-- ─── 7. Remove the task.assigned.v1 registry row and the new
--    uses_generic_notification_envelope column entirely (purely
--    additive schema, no refusal condition -- nothing else references
--    this column once the functions above are restored). ──────────
DELETE FROM platform_event_type_registry WHERE event_type = 'task.assigned.v1';
ALTER TABLE platform_event_type_registry DROP COLUMN IF EXISTS uses_generic_notification_envelope;

COMMIT;
