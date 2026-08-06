-- CAP-002 Phase 4.3 rollback: decision-replay idempotency hardening.
--
-- Restores decide_workflow_work_item() to its exact pre-4.3 body
-- (byte-for-byte, extracted from the already-approved patch-workflow-
-- approval-round-lifecycle.sql), reverting the expected-lock-version
-- comparison and metadata fields this milestone added.
--
-- Never refuses. This is a pure function-body substitution — no
-- table, column, or new event type was added by the fix, so nothing
-- becomes orphaned or unsupported by rolling back. Existing
-- decision_recorded events that happen to carry the additional
-- expected_instance_lock_version/expected_work_item_lock_version
-- metadata keys remain exactly as they are (workflow_events is
-- append-only and immutable regardless of this function's current
-- body) — rolling back only changes what future calls compare and
-- record, matching the Phase 2C.1 "changes only function bodies, no
-- meaningful data at risk" precedent, not a data-protecting refusal.
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION decide_workflow_work_item(
  p_work_item_id UUID,
  p_decision_code TEXT,
  p_expected_instance_lock_version BIGINT,
  p_expected_work_item_lock_version BIGINT,
  p_command_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS TABLE (
  instance_id UUID,
  work_item_id UUID,
  decision_id UUID,
  position_state TEXT,
  round_state TEXT,
  round_outcome TEXT,
  instance_status TEXT,
  work_item_lock_version BIGINT,
  instance_lock_version BIGINT,
  event_id UUID,
  event_sequence BIGINT,
  replayed BOOLEAN
) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_work_item_lookup workflow_work_items;
  v_instance workflow_instances;
  v_existing_decision workflow_decisions;
  v_existing_root_event workflow_events;
  v_step workflow_instance_steps;
  v_round workflow_approval_rounds;
  v_position workflow_approval_positions;
  v_work_item workflow_work_items;
  v_version workflow_definition_versions;
  v_definition workflow_definitions;
  v_canonical JSONB;
  v_seq BIGINT;
  v_root_seq BIGINT;
  v_result_instance_lock_version BIGINT;
  v_result_work_item_lock_version BIGINT;
  v_decision_id UUID;
  v_root_event_id UUID;
  v_approved INTEGER;
  v_rejected INTEGER;
  v_abstained INTEGER;
  v_undecided INTEGER;
  v_terminal BOOLEAN;
  v_outcome TEXT;
  v_final_round_state TEXT;
  v_final_instance_status TEXT;
  v_final_terminal_outcome TEXT;
  v_edge JSONB;
  v_target_node_key TEXT;
  v_target_node JSONB;
  v_next_position workflow_approval_positions;
  v_next_work_item_id UUID;
  v_wi RECORD;
  v_enter_status TEXT;
  v_enter_outcome TEXT;
  v_enter_next_seq BIGINT;
  v_enter_step_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow work item is not available for this action'
      USING ERRCODE = '42501';
  END IF;
  IF p_command_id IS NULL OR p_expected_instance_lock_version IS NULL OR p_expected_instance_lock_version < 0
     OR p_expected_work_item_lock_version IS NULL OR p_expected_work_item_lock_version < 0
     OR p_decision_code NOT IN ('approve','reject','abstain') THEN
    RAISE EXCEPTION 'Expected versions, command id, and a valid decision code are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_work_item_lookup FROM workflow_work_items WHERE id = p_work_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow work item is not available for this action'
      USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'workflow_decision:' || v_actor::TEXT || ':' || v_work_item_lookup.instance_id::TEXT || ':' ||
      p_command_id::TEXT,
      0
    )
  );

  SELECT * INTO v_instance FROM workflow_instances WHERE id = v_work_item_lookup.instance_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow work item is not available for this action'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing_decision FROM workflow_decisions wd
  WHERE wd.instance_id = v_instance.id AND wd.command_id = p_command_id;
  IF FOUND THEN
    IF v_existing_decision.actor_id IS DISTINCT FROM v_actor
       OR v_existing_decision.work_item_id <> p_work_item_id
       OR v_existing_decision.decision_code <> p_decision_code
       OR v_existing_decision.comment IS DISTINCT FROM p_comment THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input'
        USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_existing_root_event FROM workflow_events we
    WHERE we.instance_id = v_instance.id AND we.idempotency_key = p_command_id;
    RETURN QUERY SELECT
      v_instance.id,
      p_work_item_id,
      v_existing_decision.id,
      v_existing_root_event.metadata ->> 'position_state',
      v_existing_root_event.metadata ->> 'round_state',
      NULLIF(v_existing_root_event.metadata ->> 'round_outcome', ''),
      v_existing_root_event.metadata ->> 'instance_status',
      (v_existing_root_event.metadata ->> 'work_item_lock_version')::BIGINT,
      (v_existing_root_event.metadata ->> 'instance_lock_version')::BIGINT,
      v_existing_root_event.id,
      v_existing_root_event.event_sequence,
      TRUE;
    RETURN;
  END IF;

  IF v_instance.lock_version <> p_expected_instance_lock_version THEN
    RAISE EXCEPTION 'Workflow instance changed concurrently'
      USING ERRCODE = '40001';
  END IF;
  IF v_instance.status <> 'active' THEN
    RAISE EXCEPTION 'Workflow instance is not active' USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_step FROM workflow_instance_steps WHERE id = v_work_item_lookup.step_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow work item is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_round FROM workflow_approval_rounds WHERE step_id = v_step.id FOR UPDATE;
  IF NOT FOUND OR v_round.state <> 'open' THEN
    RAISE EXCEPTION 'Approval round is not open' USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_position FROM workflow_approval_positions wap WHERE wap.work_item_id = p_work_item_id FOR UPDATE;
  IF NOT FOUND OR v_position.round_id <> v_round.id OR v_position.state <> 'offered' THEN
    RAISE EXCEPTION 'Voter position is not actionable' USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_work_item FROM workflow_work_items WHERE id = p_work_item_id FOR UPDATE;
  IF NOT FOUND OR v_work_item.state <> 'offered' THEN
    RAISE EXCEPTION 'Work item is not actionable' USING ERRCODE = '55000';
  END IF;
  IF v_work_item.assigned_to IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'Workflow work item is not available for this action' USING ERRCODE = '42501';
  END IF;
  IF v_work_item.lock_version <> p_expected_work_item_lock_version THEN
    RAISE EXCEPTION 'Work item changed concurrently' USING ERRCODE = '40001';
  END IF;

  IF p_decision_code = 'abstain' AND NOT v_round.allow_abstain THEN
    RAISE EXCEPTION 'This approval round does not allow abstention' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_round.comment_policy ->> p_decision_code, '') = 'required' AND p_comment IS NULL THEN
    RAISE EXCEPTION 'A comment is required for this decision' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_round.comment_policy ->> p_decision_code, '') = 'forbidden' AND p_comment IS NOT NULL THEN
    RAISE EXCEPTION 'A comment is not permitted for this decision' USING ERRCODE = '22023';
  END IF;

  v_result_instance_lock_version := v_instance.lock_version + 1;
  v_result_work_item_lock_version := v_work_item.lock_version + 1;
  v_seq := v_instance.next_event_sequence;

  INSERT INTO workflow_decisions (
    instance_id, step_id, work_item_id, round_id, position_id,
    decision_code, actor_id, authority_source, comment, command_id, decided_at
  ) VALUES (
    v_instance.id, v_step.id, p_work_item_id, v_round.id, v_position.id,
    p_decision_code, v_actor, v_position.authority_source, p_comment, p_command_id, v_now
  ) RETURNING id INTO v_decision_id;

  UPDATE workflow_work_items
  SET state = 'completed', completed_by = v_actor, completed_at = v_now, lock_version = v_result_work_item_lock_version
  WHERE id = p_work_item_id;

  UPDATE workflow_approval_positions
  SET state = 'decided', decided_at = v_now, decision_id = v_decision_id
  WHERE id = v_position.id;

  SELECT
    count(*) FILTER (WHERE d.decision_code = 'approve'),
    count(*) FILTER (WHERE d.decision_code = 'reject'),
    count(*) FILTER (WHERE d.decision_code = 'abstain')
  INTO v_approved, v_rejected, v_abstained
  FROM workflow_approval_positions p
  LEFT JOIN workflow_decisions d ON d.id = p.decision_id
  WHERE p.round_id = v_round.id;
  v_undecided := v_round.electorate_count - v_approved - v_rejected - v_abstained;

  IF v_round.reject_behavior = 'immediate' AND v_rejected >= 1 THEN
    v_outcome := 'rejected'; v_terminal := TRUE;
  ELSIF v_approved >= v_round.approval_threshold THEN
    v_outcome := 'approved'; v_terminal := TRUE;
  ELSIF (v_approved + v_undecided) < v_round.approval_threshold THEN
    v_outcome := 'rejected'; v_terminal := TRUE;
  ELSE
    v_outcome := NULL; v_terminal := FALSE;
  END IF;

  IF v_terminal THEN
    v_final_round_state := 'completed';

    SELECT * INTO v_version FROM workflow_definition_versions WHERE id = v_instance.definition_version_id;
    SELECT * INTO v_definition FROM workflow_definitions WHERE id = v_version.definition_id;
    v_canonical := canonicalize_workflow_definition_payload(v_version.definition_payload, v_definition.organization_id);
    IF v_canonical <> v_version.definition_payload
       OR encode(digest(convert_to(v_canonical::TEXT, 'UTF8'), 'sha256'), 'hex') <> v_version.content_hash THEN
      RAISE EXCEPTION 'Workflow definition version failed publication integrity re-verification'
        USING ERRCODE = '0A000';
    END IF;

    SELECT e INTO v_edge FROM jsonb_array_elements(v_canonical -> 'edges') e
    WHERE e ->> 'source' = v_step.definition_node_key AND e ->> 'outcome' = v_outcome;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No outgoing edge matches the round outcome' USING ERRCODE = '0A000';
    END IF;
    v_target_node_key := v_edge ->> 'target';

    SELECT n INTO v_target_node FROM jsonb_array_elements(v_canonical -> 'nodes') n
    WHERE n ->> 'key' = v_target_node_key;

    -- Peek through any zero-candidate-optional skip chain beyond the
    -- immediate target so this command's own root event carries the
    -- TRUE final instance_status/terminal_outcome at insert time
    -- (replaces the old single-hop target_type ternary — a skip
    -- chain can move the true final state past this immediate node).
    SELECT peek.final_status, peek.final_outcome_code
    INTO v_final_instance_status, v_final_terminal_outcome
    FROM workflow_peek_final_graph_target(
      v_canonical, v_instance.id, v_instance.home_organization_id, v_instance.created_by,
      v_target_node_key, v_target_node
    ) peek;
  ELSE
    v_final_round_state := 'open';
    v_final_instance_status := v_instance.status;
    v_final_terminal_outcome := NULL;
  END IF;

  v_root_seq := v_seq;
  v_root_event_id := gen_random_uuid();
  INSERT INTO workflow_events (id, instance_id, event_sequence, event_type, actor_id, step_id, work_item_id, correlation_id, idempotency_key, metadata)
  VALUES (v_root_event_id, v_instance.id, v_seq, 'decision_recorded', v_actor, v_step.id, p_work_item_id, v_instance.correlation_id, p_command_id,
    jsonb_build_object(
      'round_id', v_round.id, 'position_id', v_position.id, 'decision_code', p_decision_code,
      'position_state', 'decided', 'round_state', v_final_round_state, 'round_outcome', v_outcome,
      'instance_status', v_final_instance_status, 'work_item_lock_version', v_result_work_item_lock_version,
      'instance_lock_version', v_result_instance_lock_version));
  -- work_item_completed
  INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, work_item_id, correlation_id, causation_id, idempotency_key, metadata)
  VALUES (v_instance.id, v_seq+1, 'work_item_completed', v_actor, v_step.id, p_work_item_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
    jsonb_build_object('decision_code', p_decision_code));
  v_seq := v_seq + 2;

  IF NOT v_terminal THEN
    IF v_round.delivery_mode = 'sequential' THEN
      SELECT * INTO v_next_position FROM workflow_approval_positions
      WHERE round_id = v_round.id AND state = 'pending'
      ORDER BY ordinal ASC LIMIT 1 FOR UPDATE;
      IF FOUND THEN
        INSERT INTO workflow_work_items (instance_id, step_id, token_id, work_item_type, state, organization_id, assigned_to, offered_at)
        VALUES (v_instance.id, v_step.id, v_round.token_id, 'approval', 'offered', v_next_position.organization_id, v_next_position.user_id, v_now)
        RETURNING id INTO v_next_work_item_id;

        UPDATE workflow_approval_positions
        SET state = 'offered', offered_at = v_now, work_item_id = v_next_work_item_id
        WHERE id = v_next_position.id;

        INSERT INTO workflow_participants (instance_id, work_item_id, user_id, participant_role, authority_source, created_by)
        VALUES (v_instance.id, v_next_work_item_id, v_next_position.user_id, 'candidate', v_next_position.authority_source, v_actor);

        INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, work_item_id, correlation_id, causation_id, idempotency_key, metadata)
        VALUES (v_instance.id, v_seq, 'work_item_created', v_actor, v_step.id, v_next_work_item_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
          jsonb_build_object('round_id', v_round.id, 'ordinal', v_next_position.ordinal));
        v_seq := v_seq + 1;
      END IF;
    END IF;

    UPDATE workflow_approval_rounds SET lock_version = lock_version + 1, updated_at = v_now WHERE id = v_round.id;
    UPDATE workflow_instances SET lock_version = v_result_instance_lock_version, next_event_sequence = v_seq WHERE id = v_instance.id;

    RETURN QUERY SELECT v_instance.id, p_work_item_id, v_decision_id, 'decided'::TEXT, v_final_round_state, v_outcome, v_final_instance_status, v_result_work_item_lock_version, v_result_instance_lock_version, v_root_event_id, v_root_seq, FALSE;
    RETURN;
  END IF;

  UPDATE workflow_approval_rounds
  SET state = 'completed', outcome_code = v_outcome, completed_at = v_now, lock_version = lock_version + 1
  WHERE id = v_round.id;

  INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
  VALUES (v_instance.id, v_seq, 'approval_round_completed', v_actor, v_step.id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
    jsonb_build_object('round_id', v_round.id, 'outcome_code', v_outcome, 'electorate_count', v_round.electorate_count,
      'approved_count', v_approved, 'rejected_count', v_rejected, 'abstained_count', v_abstained));
  v_seq := v_seq + 1;

  FOR v_wi IN
    SELECT wi.id AS work_item_id
    FROM workflow_work_items wi
    JOIN workflow_approval_positions p ON p.work_item_id = wi.id
    WHERE p.round_id = v_round.id AND wi.state = 'offered'
  LOOP
    UPDATE workflow_work_items SET state = 'cancelled' WHERE id = v_wi.work_item_id;
    UPDATE workflow_approval_positions SET state = 'cancelled', cancelled_at = v_now WHERE workflow_approval_positions.work_item_id = v_wi.work_item_id;
    INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, work_item_id, correlation_id, causation_id, idempotency_key, metadata)
    VALUES (v_instance.id, v_seq, 'work_item_cancelled', v_actor, v_step.id, v_wi.work_item_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
      jsonb_build_object('round_id', v_round.id, 'reason_code', 'round_closed'));
    v_seq := v_seq + 1;
  END LOOP;

  UPDATE workflow_approval_positions SET state = 'cancelled', cancelled_at = v_now
  WHERE round_id = v_round.id AND state = 'pending';

  UPDATE workflow_instance_steps SET state = 'completed', result_code = v_outcome, ended_at = v_now WHERE id = v_step.id;
  INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
  VALUES (v_instance.id, v_seq, 'step_completed', v_actor, v_step.id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
    jsonb_build_object('node_key', v_step.definition_node_key, 'result_code', v_outcome));
  v_seq := v_seq + 1;

  SELECT ed.final_status, ed.final_outcome, ed.next_event_sequence, ed.target_step_id
  INTO v_enter_status, v_enter_outcome, v_enter_next_seq, v_enter_step_id
  FROM workflow_enter_downstream_node(
    v_instance.id, v_actor, v_instance.correlation_id, v_instance.home_organization_id,
    v_instance.created_by, v_instance.execution_epoch, v_root_event_id, v_seq,
    v_result_instance_lock_version, v_round.token_id, v_step.definition_node_key, v_target_node_key, v_target_node, v_canonical
  ) ed;

  RETURN QUERY SELECT v_instance.id, p_work_item_id, v_decision_id, 'decided'::TEXT, v_final_round_state, v_outcome, v_enter_status, v_result_work_item_lock_version, v_result_instance_lock_version, v_root_event_id, v_root_seq, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION decide_workflow_work_item(UUID,TEXT,BIGINT,BIGINT,UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION decide_workflow_work_item(UUID,TEXT,BIGINT,BIGINT,UUID,TEXT) TO authenticated;

COMMIT;
