-- ============================================================
-- CAP-002 Phase 2: generic workflow runtime state machine
--
-- Instance lifecycle only. This patch does not execute definition
-- graphs, steps, tokens, work items, approvals, routing, adapters,
-- timers, notifications, audit projections, or module mutations.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION workflow_transition_instance(
  p_instance_id UUID,
  p_command TEXT,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID,
  p_reason_code TEXT DEFAULT NULL,
  p_outcome_code TEXT DEFAULT NULL
) RETURNS TABLE (
  instance_id UUID,
  status TEXT,
  terminal_outcome TEXT,
  lock_version BIGINT,
  event_id UUID,
  event_sequence BIGINT,
  replayed BOOLEAN
) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_instance workflow_instances;
  v_existing_event workflow_events;
  v_event_id UUID;
  v_event_sequence BIGINT;
  v_event_type TEXT;
  v_target_state TEXT;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_result_lock_version BIGINT;
  v_result_outcome TEXT;
BEGIN
  IF NOT workflow_actor_is_active()
     OR NOT can_manage_workflow_instance(p_instance_id) THEN
    RAISE EXCEPTION 'Workflow instance is not available for this action'
      USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL
     OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required'
      USING ERRCODE = '22023';
  END IF;

  CASE p_command
    WHEN 'start' THEN
      v_target_state := 'active';
      v_event_type := 'instance_started';
      IF p_reason_code IS NOT NULL OR p_outcome_code IS NOT NULL THEN
        RAISE EXCEPTION 'Start does not accept a reason or outcome code' USING ERRCODE = '22023';
      END IF;
    WHEN 'suspend' THEN
      v_target_state := 'suspended';
      v_event_type := 'instance_suspended';
      IF p_reason_code IS NULL OR p_reason_code !~ '^[a-z][a-z0-9_]{0,62}$'
         OR p_outcome_code IS NOT NULL THEN
        RAISE EXCEPTION 'Suspend requires a safe reason code and no outcome code' USING ERRCODE = '22023';
      END IF;
    WHEN 'resume' THEN
      v_target_state := 'active';
      v_event_type := 'instance_resumed';
      IF p_reason_code IS NULL OR p_reason_code !~ '^[a-z][a-z0-9_]{0,62}$'
         OR p_outcome_code IS NOT NULL THEN
        RAISE EXCEPTION 'Resume requires a safe reason code and no outcome code' USING ERRCODE = '22023';
      END IF;
    WHEN 'cancel' THEN
      v_target_state := 'cancelled';
      v_event_type := 'instance_cancelled';
      IF p_reason_code IS NULL OR p_reason_code !~ '^[a-z][a-z0-9_]{0,62}$'
         OR p_outcome_code IS NOT NULL THEN
        RAISE EXCEPTION 'Cancel requires a safe reason code and no outcome code' USING ERRCODE = '22023';
      END IF;
    WHEN 'complete' THEN
      v_target_state := 'completed';
      v_event_type := 'instance_completed';
      IF p_outcome_code IS NULL OR p_outcome_code !~ '^[a-z][a-z0-9_]{0,62}$'
         OR p_reason_code IS NOT NULL THEN
        RAISE EXCEPTION 'Complete requires a safe outcome code and no reason code' USING ERRCODE = '22023';
      END IF;
    ELSE
      RAISE EXCEPTION 'Unsupported workflow runtime command' USING ERRCODE = '22023';
  END CASE;

  -- Caller/key serialization precedes the aggregate row lock. Distinct
  -- commands then serialize on the instance row in deterministic order.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'workflow_runtime:' || v_actor::TEXT || ':' || p_instance_id::TEXT || ':' ||
      p_idempotency_key::TEXT,
      0
    )
  );

  SELECT * INTO v_instance
  FROM workflow_instances
  WHERE id = p_instance_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow instance is not available for this action'
      USING ERRCODE = '42501';
  END IF;

  SELECT e.* INTO v_existing_event
  FROM workflow_events e
  WHERE e.instance_id = p_instance_id
    AND e.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_event.actor_id IS DISTINCT FROM v_actor
       OR v_existing_event.event_type <> v_event_type
       OR v_existing_event.metadata ->> 'command' <> p_command
       OR (v_existing_event.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version
       OR v_existing_event.metadata ->> 'reason_code' IS DISTINCT FROM p_reason_code
       OR v_existing_event.metadata ->> 'outcome_code' IS DISTINCT FROM p_outcome_code THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input'
        USING ERRCODE = '22023';
    END IF;

    RETURN QUERY SELECT
      p_instance_id,
      v_existing_event.metadata ->> 'new_status',
      NULLIF(v_existing_event.metadata ->> 'terminal_outcome', ''),
      (v_existing_event.metadata ->> 'result_lock_version')::BIGINT,
      v_existing_event.id,
      v_existing_event.event_sequence,
      TRUE;
    RETURN;
  END IF;

  IF v_instance.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow instance changed concurrently'
      USING ERRCODE = '40001';
  END IF;

  IF (p_command = 'start' AND v_instance.status <> 'pending')
     OR (p_command = 'suspend' AND v_instance.status <> 'active')
     OR (p_command = 'resume' AND v_instance.status <> 'suspended')
     OR (p_command = 'cancel' AND v_instance.status NOT IN ('pending','active','suspended'))
     OR (p_command = 'complete' AND v_instance.status <> 'active') THEN
    RAISE EXCEPTION 'Illegal workflow transition: command % is not valid from state %',
      p_command, v_instance.status USING ERRCODE = '55000';
  END IF;

  IF p_command = 'complete' AND (
    EXISTS (
      SELECT 1 FROM workflow_instance_steps s
      WHERE s.instance_id = p_instance_id
        AND s.state IN ('pending','ready','active','waiting','failed')
    ) OR EXISTS (
      SELECT 1 FROM workflow_tokens t
      WHERE t.instance_id = p_instance_id
        AND t.state IN ('active','waiting','failed')
    ) OR EXISTS (
      SELECT 1 FROM workflow_work_items w
      WHERE w.instance_id = p_instance_id
        AND w.state IN ('offered','claimed','failed')
    )
  ) THEN
    RAISE EXCEPTION 'Workflow instance cannot complete while runtime work remains open'
      USING ERRCODE = '55000';
  END IF;

  v_event_sequence := v_instance.next_event_sequence;
  v_result_lock_version := v_instance.lock_version + 1;
  v_result_outcome := CASE
    WHEN p_command = 'complete' THEN p_outcome_code
    WHEN p_command = 'cancel' THEN 'cancelled'
    ELSE NULL
  END;

  IF p_command = 'cancel' THEN
    UPDATE workflow_instance_steps s
    SET state = 'cancelled', ended_at = COALESCE(s.ended_at, v_now)
    WHERE s.instance_id = p_instance_id
      AND s.state IN ('pending','ready','active','waiting','failed');

    UPDATE workflow_tokens t
    SET state = 'cancelled'
    WHERE t.instance_id = p_instance_id
      AND t.state IN ('active','waiting','failed');

    UPDATE workflow_work_items w
    SET state = 'cancelled'
    WHERE w.instance_id = p_instance_id
      AND w.state IN ('offered','claimed','failed');
  END IF;

  UPDATE workflow_instances
  SET status = v_target_state,
      terminal_outcome = v_result_outcome,
      started_at = CASE
        WHEN p_command = 'start' THEN COALESCE(started_at, v_now)
        ELSE started_at
      END,
      ended_at = CASE
        WHEN p_command IN ('cancel','complete') THEN v_now
        ELSE NULL
      END,
      lock_version = v_result_lock_version,
      next_event_sequence = next_event_sequence + 1
  WHERE id = p_instance_id;

  INSERT INTO workflow_events (
    instance_id, event_sequence, event_type, actor_id,
    correlation_id, idempotency_key, metadata
  ) VALUES (
    p_instance_id, v_event_sequence, v_event_type, v_actor,
    v_instance.correlation_id, p_idempotency_key,
    jsonb_strip_nulls(jsonb_build_object(
      'command', p_command,
      'previous_status', v_instance.status,
      'new_status', v_target_state,
      'expected_lock_version', p_expected_lock_version,
      'result_lock_version', v_result_lock_version,
      'terminal_outcome', v_result_outcome,
      'reason_code', p_reason_code,
      'outcome_code', p_outcome_code
    ))
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT
    p_instance_id, v_target_state, v_result_outcome,
    v_result_lock_version, v_event_id, v_event_sequence, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION start_workflow_instance(
  p_instance_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS TABLE (
  instance_id UUID, status TEXT, terminal_outcome TEXT, lock_version BIGINT,
  event_id UUID, event_sequence BIGINT, replayed BOOLEAN
) AS $$
  SELECT * FROM workflow_transition_instance(
    p_instance_id, 'start', p_expected_lock_version, p_idempotency_key, NULL, NULL
  );
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION suspend_workflow_instance(
  p_instance_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID,
  p_reason_code TEXT
) RETURNS TABLE (
  instance_id UUID, status TEXT, terminal_outcome TEXT, lock_version BIGINT,
  event_id UUID, event_sequence BIGINT, replayed BOOLEAN
) AS $$
  SELECT * FROM workflow_transition_instance(
    p_instance_id, 'suspend', p_expected_lock_version, p_idempotency_key, p_reason_code, NULL
  );
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION resume_workflow_instance(
  p_instance_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID,
  p_reason_code TEXT
) RETURNS TABLE (
  instance_id UUID, status TEXT, terminal_outcome TEXT, lock_version BIGINT,
  event_id UUID, event_sequence BIGINT, replayed BOOLEAN
) AS $$
  SELECT * FROM workflow_transition_instance(
    p_instance_id, 'resume', p_expected_lock_version, p_idempotency_key, p_reason_code, NULL
  );
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION cancel_workflow_instance(
  p_instance_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID,
  p_reason_code TEXT
) RETURNS TABLE (
  instance_id UUID, status TEXT, terminal_outcome TEXT, lock_version BIGINT,
  event_id UUID, event_sequence BIGINT, replayed BOOLEAN
) AS $$
  SELECT * FROM workflow_transition_instance(
    p_instance_id, 'cancel', p_expected_lock_version, p_idempotency_key, p_reason_code, NULL
  );
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION complete_workflow_instance(
  p_instance_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID,
  p_outcome_code TEXT
) RETURNS TABLE (
  instance_id UUID, status TEXT, terminal_outcome TEXT, lock_version BIGINT,
  event_id UUID, event_sequence BIGINT, replayed BOOLEAN
) AS $$
  SELECT * FROM workflow_transition_instance(
    p_instance_id, 'complete', p_expected_lock_version, p_idempotency_key, NULL, p_outcome_code
  );
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION workflow_transition_instance(UUID,TEXT,BIGINT,UUID,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION start_workflow_instance(UUID,BIGINT,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION suspend_workflow_instance(UUID,BIGINT,UUID,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION resume_workflow_instance(UUID,BIGINT,UUID,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION cancel_workflow_instance(UUID,BIGINT,UUID,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION complete_workflow_instance(UUID,BIGINT,UUID,TEXT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION start_workflow_instance(UUID,BIGINT,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION suspend_workflow_instance(UUID,BIGINT,UUID,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION resume_workflow_instance(UUID,BIGINT,UUID,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_workflow_instance(UUID,BIGINT,UUID,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION complete_workflow_instance(UUID,BIGINT,UUID,TEXT) TO authenticated;

COMMIT;
