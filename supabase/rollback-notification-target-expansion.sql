-- CAP-003 Phase 1.4A notification target expansion -- rollback.
-- Reverses patch-notification-target-expansion.sql exactly, restoring
-- create_notification_intent(), resolve_notification_intent(), and
-- process_platform_outbox_batch() to their EXACT pre-1.4A (Phase 1.4)
-- bodies -- spliced in verbatim from pg_get_functiondef() captures
-- taken BEFORE this milestone's patch was ever written, not
-- reconstructed from memory (Phase 1.4 already caught one stale-
-- memory mistake; this rollback does not repeat it). Restores the
-- three CHECK constraints to their exact pre-1.4A forms, drops
-- intent_user_can_view_meeting(), and drops the two new target-
-- identifier columns entirely.
--
-- Refuses (raises, never silently discards data) if any persisted
-- notification_intents row still uses either new target kind --
-- restoring the narrower CHECK/column-free schema would otherwise
-- either violate the restored constraint or silently strand orphaned
-- data.
\set ON_ERROR_STOP on
BEGIN;

-- ─── 1. Refuse if any intent still depends on either new target kind ──
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notification_intents WHERE target_type IN ('task_watchers','meeting_participants');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % notification_intents row(s) use target_type IN (task_watchers, meeting_participants). Restoring the pre-1.4A schema would strand this data. Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
END $$;

-- ─── 2. create_notification_intent(): drop the 13-arg version, restore
--    the exact pre-1.4A 11-arg body verbatim. ──────────────────────
DROP FUNCTION create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid);

CREATE OR REPLACE FUNCTION create_notification_intent(p_outbox_event_id uuid, p_notification_type text, p_title_template_key text, p_template_params jsonb, p_priority text, p_target_type text, p_target_user_ids uuid[], p_target_organization_id uuid, p_target_section_id uuid, p_target_workflow_instance_id uuid, p_target_work_item_id uuid)
 RETURNS uuid AS $$
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

REVOKE ALL ON FUNCTION create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID) TO service_role;

-- ─── 3. resolve_notification_intent(): restore the exact pre-1.4A body. ──
CREATE OR REPLACE FUNCTION resolve_notification_intent(p_intent_id uuid)
 RETURNS TABLE(status text, resolved_count integer, skipped_count integer) AS $$
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

-- ─── 4. process_platform_outbox_batch(): restore the exact pre-1.4A body. ──
CREATE OR REPLACE FUNCTION process_platform_outbox_batch(p_limit integer DEFAULT 25, p_worker_id text DEFAULT NULL::text)
 RETURNS TABLE(event_id uuid, event_type text, outcome text, intent_id uuid, attempt_count integer, next_attempt_at timestamp with time zone, final_status text) AS $$
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

-- ─── 5. Drop intent_user_can_view_meeting() -- purely additive, no
--    other object depends on it once resolve_notification_intent()
--    above is restored. ────────────────────────────────────────────
DROP FUNCTION IF EXISTS intent_user_can_view_meeting(UUID, UUID);

-- ─── 6. Restore the three CHECK constraints to their exact pre-1.4A
--    (Phase 1.4) forms. ─────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task'));

ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_target_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_target_type_check
  CHECK (target_type IN (
    'specific_users', 'org_admins', 'section', 'section_leadership',
    'workflow_participants', 'work_item_assignee'
  ));

ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_target_shape_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_target_shape_check CHECK (
  (target_type = 'specific_users' AND target_user_ids IS NOT NULL AND array_length(target_user_ids,1) > 0
    AND target_organization_id IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL)
  OR (target_type = 'org_admins' AND target_organization_id IS NOT NULL
    AND target_user_ids IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL)
  OR (target_type IN ('section', 'section_leadership') AND target_section_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL)
  OR (target_type = 'workflow_participants' AND target_workflow_instance_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL AND target_work_item_id IS NULL)
  OR (target_type = 'work_item_assignee' AND target_work_item_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL)
);

-- ─── 7. Drop the two new target-identifier columns entirely. ────────
ALTER TABLE notification_intents DROP COLUMN IF EXISTS target_task_id;
ALTER TABLE notification_intents DROP COLUMN IF EXISTS target_meeting_id;

COMMIT;
