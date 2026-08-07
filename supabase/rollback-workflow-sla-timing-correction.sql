-- CAP-002 Phase 5.3A -- SLA timing architecture-conformance
-- correction rollback. Reverses patch-workflow-sla-timing-
-- correction.sql exactly, restoring every touched function and grant
-- to byte-identical bodies with commit 7cdc86e ("feat(workflow):
-- implement SLA escalation foundation"). Does not touch anything
-- Phase 5.3's own rollback (rollback-workflow-sla-escalation-
-- foundation.sql) already owns -- running that rollback afterward
-- continues to behave exactly as it did before this correction
-- existed.
--
-- Refusal precedent: this correction touches only function bodies,
-- grants, and a table comment -- it creates no new table and inserts
-- no data of its own, so there is no data-loss risk analogous to
-- Phase 5.3's own table-level refusal. However, if any SLA clock has
-- been created since this correction was applied (via the corrected
-- create_workflow_sla_clock, which pins calendar_version_id more
-- broadly than the pre-correction version did), reverting create_
-- workflow_sla_clock's validation-tightening sibling (create_
-- workflow_sla_policy) could in principle allow a future policy to be
-- created without the calendar_id newer offsets require -- this does
-- not corrupt any existing row, so no refusal is necessary; existing
-- clocks and evidence remain completely unaffected regardless of
-- which version of these functions is active, since function bodies
-- only affect future calls, never already-stored rows.
\set ON_ERROR_STOP on
BEGIN;

-- ─── Correction 1 reversed: restart directly callable again ────────
GRANT EXECUTE ON FUNCTION restart_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) TO authenticated;

-- ─── Correction 3 reversed: drop the schema comments ────────────────
COMMENT ON COLUMN workflow_escalation_events.action_code IS NULL;
COMMENT ON TABLE workflow_escalation_events IS NULL;

-- ─── Correction 2 reversed: restore the pre-correction bodies ──────
DROP FUNCTION IF EXISTS workflow_calculate_calendar_offset_backward(TIMESTAMPTZ,NUMERIC,TEXT,UUID,TEXT);

-- restored: create_workflow_sla_policy
CREATE OR REPLACE FUNCTION create_workflow_sla_policy(
  p_organization_id UUID,
  p_policy_key TEXT,
  p_name TEXT,
  p_duration_amount NUMERIC,
  p_duration_unit TEXT,
  p_calendar_id UUID,
  p_timezone TEXT,
  p_warning_offsets JSONB,
  p_pause_eligible BOOLEAN,
  p_restart_eligible BOOLEAN,
  p_escalation_policy_id UUID,
  p_idempotency_key UUID
) RETURNS TABLE (sla_policy_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_policy_id UUID;
  v_existing workflow_sla_policies;
  v_offset JSONB;
BEGIN
  IF NOT can_manage_workflow_sla_config(p_organization_id) THEN
    RAISE EXCEPTION 'Not authorized to manage SLA policies for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_organization_id IS NULL OR p_policy_key IS NULL OR p_name IS NULL
     OR p_duration_amount IS NULL OR p_duration_unit IS NULL OR p_timezone IS NULL THEN
    RAISE EXCEPTION 'Missing required SLA policy fields' USING ERRCODE = '22023';
  END IF;
  IF p_duration_unit NOT IN ('hours','business_hours','days','business_days') THEN
    RAISE EXCEPTION 'Invalid duration_unit: %', p_duration_unit USING ERRCODE = '22023';
  END IF;
  IF p_duration_unit IN ('business_hours','business_days') AND p_calendar_id IS NULL THEN
    RAISE EXCEPTION 'A calendar_id is required for a calendar-aware duration unit' USING ERRCODE = '22023';
  END IF;
  IF p_calendar_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM workflow_business_calendars c WHERE c.id = p_calendar_id AND c.organization_id = p_organization_id AND c.is_active
  ) THEN
    RAISE EXCEPTION 'Calendar not found in this organization' USING ERRCODE = '22023';
  END IF;
  IF p_escalation_policy_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM workflow_escalation_policies p WHERE p.id = p_escalation_policy_id AND p.organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'Escalation policy not found in this organization' USING ERRCODE = '22023';
  END IF;
  IF p_warning_offsets IS NOT NULL AND jsonb_typeof(p_warning_offsets) <> 'array' THEN
    RAISE EXCEPTION 'warning_offsets must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF p_warning_offsets IS NOT NULL THEN
    FOR v_offset IN SELECT * FROM jsonb_array_elements(p_warning_offsets) LOOP
      IF (v_offset ->> 'amount') IS NULL OR (v_offset ->> 'unit') NOT IN ('hours','business_hours','days','business_days') THEN
        RAISE EXCEPTION 'Each warning offset requires a numeric amount and a valid unit' USING ERRCODE = '22023';
      END IF;
    END LOOP;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_policy_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_sla_policies
  WHERE organization_id = p_organization_id AND policy_key = p_policy_key AND created_by = v_actor;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.id, TRUE;
    RETURN;
  END IF;

  INSERT INTO workflow_sla_policies (
    organization_id, policy_key, name, duration_amount, duration_unit, calendar_id, timezone,
    warning_offsets, pause_eligible, restart_eligible, escalation_policy_id, created_by
  ) VALUES (
    p_organization_id, p_policy_key, p_name, p_duration_amount, p_duration_unit, p_calendar_id, p_timezone,
    COALESCE(p_warning_offsets, '[]'::JSONB), COALESCE(p_pause_eligible, FALSE), COALESCE(p_restart_eligible, FALSE),
    p_escalation_policy_id, v_actor
  ) RETURNING id INTO v_policy_id;

  RETURN QUERY SELECT v_policy_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION create_workflow_sla_policy(UUID,TEXT,TEXT,NUMERIC,TEXT,UUID,TEXT,JSONB,BOOLEAN,BOOLEAN,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_sla_policy(UUID,TEXT,TEXT,NUMERIC,TEXT,UUID,TEXT,JSONB,BOOLEAN,BOOLEAN,UUID,UUID) TO authenticated;

-- restored: create_workflow_sla_clock
CREATE OR REPLACE FUNCTION create_workflow_sla_clock(
  p_instance_id UUID,
  p_step_id UUID,
  p_work_item_id UUID,
  p_policy_id UUID,
  p_start_event_type TEXT,
  p_start_reference_event_id UUID,
  p_absolute_deadline TIMESTAMPTZ,
  p_absolute_deadline_timezone TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, effective_deadline TIMESTAMPTZ, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_instance workflow_instances;
  v_policy workflow_sla_policies;
  v_calendar workflow_business_calendars;
  v_existing workflow_sla_clocks;
  v_clock_id UUID;
  v_deadline TIMESTAMPTZ;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF NOT can_manage_workflow_instance(p_instance_id) THEN
    RAISE EXCEPTION 'Not authorized to configure an SLA clock for this instance' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_instance_id IS NULL OR p_start_event_type IS NULL THEN
    RAISE EXCEPTION 'Missing required SLA clock fields' USING ERRCODE = '22023';
  END IF;
  IF p_start_event_type NOT IN ('step_entered','work_item_created','approval_round_opened','manual') THEN
    RAISE EXCEPTION 'Invalid start_event_type: %', p_start_event_type USING ERRCODE = '22023';
  END IF;
  IF (p_policy_id IS NULL) = (p_absolute_deadline IS NULL) THEN
    RAISE EXCEPTION 'Exactly one of policy_id (duration-based) or absolute_deadline must be supplied' USING ERRCODE = '22023';
  END IF;
  IF p_absolute_deadline IS NOT NULL AND btrim(COALESCE(p_absolute_deadline_timezone, '')) = '' THEN
    RAISE EXCEPTION 'A timezone is required when supplying an absolute_deadline' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_instance FROM workflow_instances WHERE id = p_instance_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow instance not found' USING ERRCODE = '42501';
  END IF;
  IF p_step_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_instance_steps s WHERE s.id = p_step_id AND s.instance_id = p_instance_id) THEN
    RAISE EXCEPTION 'Step does not belong to this instance' USING ERRCODE = '22023';
  END IF;
  IF p_work_item_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_work_items w WHERE w.id = p_work_item_id AND w.instance_id = p_instance_id) THEN
    RAISE EXCEPTION 'Work item does not belong to this instance' USING ERRCODE = '22023';
  END IF;
  IF p_start_reference_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_events e WHERE e.id = p_start_reference_event_id AND e.instance_id = p_instance_id) THEN
    RAISE EXCEPTION 'Start reference event does not belong to this instance' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_sla_clocks
  WHERE created_by = v_actor AND id IN (
    SELECT e.clock_id FROM workflow_sla_clock_events e WHERE e.idempotency_key = p_idempotency_key AND e.event_type = 'started'
  );
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.id, v_existing.effective_deadline, TRUE;
    RETURN;
  END IF;

  IF p_policy_id IS NOT NULL THEN
    SELECT * INTO v_policy FROM workflow_sla_policies WHERE id = p_policy_id AND organization_id = v_instance.home_organization_id AND is_active;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'SLA policy not found in this organization' USING ERRCODE = '22023';
    END IF;

    v_clock_id := gen_random_uuid();
    IF v_policy.duration_unit IN ('business_hours','business_days') THEN
      SELECT * INTO v_calendar FROM workflow_business_calendars WHERE id = v_policy.calendar_id;
      IF v_calendar.active_version_id IS NULL THEN
        RAISE EXCEPTION 'Calendar has no published version' USING ERRCODE = '0A000';
      END IF;
      v_deadline := workflow_calculate_calendar_deadline(
        v_now, v_policy.duration_amount, v_policy.duration_unit, v_calendar.active_version_id, v_policy.timezone
      );
    ELSE
      v_deadline := workflow_calculate_calendar_deadline(v_now, v_policy.duration_amount, v_policy.duration_unit, NULL, v_policy.timezone);
    END IF;

    INSERT INTO workflow_sla_clocks (
      id, instance_id, step_id, work_item_id, organization_id, policy_id, deadline_rule_type,
      start_event_type, start_reference_event_id, started_at, configured_duration_amount,
      configured_duration_unit, calendar_id, calendar_version_id, timezone, effective_deadline,
      effective_deadline_adjusted, warning_offsets, escalation_policy_id, pause_eligible, restart_eligible, created_by
    ) VALUES (
      v_clock_id, p_instance_id, p_step_id, p_work_item_id, v_instance.home_organization_id, v_policy.id, 'duration',
      p_start_event_type, p_start_reference_event_id, v_now, v_policy.duration_amount,
      v_policy.duration_unit, v_policy.calendar_id, v_calendar.active_version_id, v_policy.timezone, v_deadline,
      v_deadline, v_policy.warning_offsets, v_policy.escalation_policy_id, v_policy.pause_eligible, v_policy.restart_eligible, v_actor
    );
  ELSE
    v_clock_id := gen_random_uuid();
    v_deadline := p_absolute_deadline;
    INSERT INTO workflow_sla_clocks (
      id, instance_id, step_id, work_item_id, organization_id, policy_id, deadline_rule_type,
      start_event_type, start_reference_event_id, started_at, timezone, effective_deadline,
      effective_deadline_adjusted, pause_eligible, restart_eligible, created_by
    ) VALUES (
      v_clock_id, p_instance_id, p_step_id, p_work_item_id, v_instance.home_organization_id, NULL, 'absolute',
      p_start_event_type, p_start_reference_event_id, v_now, p_absolute_deadline_timezone, v_deadline,
      v_deadline, FALSE, FALSE, v_actor
    );
  END IF;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (v_clock_id, p_instance_id, 'started', v_actor, p_idempotency_key,
    jsonb_build_object('effective_deadline', v_deadline, 'start_event_type', p_start_event_type));

  RETURN QUERY SELECT v_clock_id, v_deadline, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION create_workflow_sla_clock(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_sla_clock(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TEXT,UUID) TO authenticated;

-- restored: workflow_sla_offset_interval
CREATE OR REPLACE FUNCTION workflow_sla_offset_interval(p_amount NUMERIC, p_unit TEXT)
RETURNS INTERVAL AS $$
  SELECT CASE
    WHEN p_unit IN ('hours','business_hours') THEN (p_amount || ' hours')::INTERVAL
    WHEN p_unit IN ('days','business_days') THEN (p_amount || ' days')::INTERVAL
    ELSE NULL
  END;
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_offset_interval(NUMERIC,TEXT) FROM PUBLIC, anon, authenticated;

-- restored: workflow_sla_clocks_due_for_warning
CREATE OR REPLACE FUNCTION workflow_sla_clocks_due_for_warning(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  clock_id UUID, instance_id UUID, warning_offset_index INTEGER,
  due_at TIMESTAMPTZ, effective_deadline_adjusted TIMESTAMPTZ
) AS $$
  SELECT c.id, c.instance_id, (c.warned_up_to_index + 1)::INTEGER, w.due_at, c.effective_deadline_adjusted
  FROM workflow_sla_clocks c
  CROSS JOIN LATERAL (
    SELECT c.effective_deadline_adjusted - workflow_sla_offset_interval(
      (c.warning_offsets -> (c.warned_up_to_index + 1) ->> 'amount')::NUMERIC,
      c.warning_offsets -> (c.warned_up_to_index + 1) ->> 'unit'
    ) AS due_at
  ) w
  WHERE c.state = 'running'
    AND c.warned_up_to_index + 1 < jsonb_array_length(c.warning_offsets)
    AND w.due_at <= clock_timestamp()
  ORDER BY w.due_at
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_clocks_due_for_warning(INTEGER) FROM PUBLIC, anon, authenticated;

-- restored: workflow_sla_clocks_due_for_escalation
CREATE OR REPLACE FUNCTION workflow_sla_clocks_due_for_escalation(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  clock_id UUID, instance_id UUID, escalation_policy_id UUID,
  escalation_level_id UUID, level_order INTEGER, action_code TEXT, due_at TIMESTAMPTZ
) AS $$
  SELECT c.id, c.instance_id, c.escalation_policy_id, lvl.id, lvl.level_order, lvl.action_code, base.due_at
  FROM workflow_sla_clocks c
  JOIN workflow_escalation_levels lvl
    ON lvl.escalation_policy_id = c.escalation_policy_id AND lvl.level_order = c.current_escalation_level + 1
  CROSS JOIN LATERAL (
    SELECT (
      (CASE
        WHEN lvl.offset_from = 'breach' THEN c.breached_at
        WHEN lvl.level_order = 1 THEN c.breached_at
        ELSE (SELECT e.occurred_at FROM workflow_escalation_events e
              WHERE e.clock_id = c.id AND e.level_order = lvl.level_order - 1)
      END) + workflow_sla_offset_interval(lvl.offset_amount, lvl.offset_unit)
    ) AS due_at
  ) base
  WHERE c.state = 'running'
    AND c.escalation_policy_id IS NOT NULL
    AND base.due_at IS NOT NULL
    AND base.due_at <= clock_timestamp()
  ORDER BY base.due_at
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_clocks_due_for_escalation(INTEGER) FROM PUBLIC, anon, authenticated;

-- restored: record_workflow_sla_warning
CREATE OR REPLACE FUNCTION record_workflow_sla_warning(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_warning_offset_index INTEGER,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, warning_offset_index INTEGER, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
  v_offset JSONB;
  v_due_at TIMESTAMPTZ;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 OR p_warning_offset_index IS NULL THEN
    RAISE EXCEPTION 'Expected lock version, warning offset index, and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'warning_fired' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'warning_offset_index')::INTEGER <> p_warning_offset_index
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, p_warning_offset_index, (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state <> 'running' THEN
    RAISE EXCEPTION 'Workflow SLA clock is not running' USING ERRCODE = '55000';
  END IF;
  IF p_warning_offset_index < 0 OR p_warning_offset_index >= jsonb_array_length(v_clock.warning_offsets) THEN
    RAISE EXCEPTION 'Warning offset index out of range' USING ERRCODE = '22023';
  END IF;
  IF p_warning_offset_index <> v_clock.warned_up_to_index + 1 THEN
    RAISE EXCEPTION 'Warning offsets must be recorded in order, next expected index is %', v_clock.warned_up_to_index + 1 USING ERRCODE = '55000';
  END IF;

  v_offset := v_clock.warning_offsets -> p_warning_offset_index;
  v_due_at := v_clock.effective_deadline_adjusted - workflow_sla_offset_interval((v_offset ->> 'amount')::NUMERIC, v_offset ->> 'unit');
  IF clock_timestamp() < v_due_at THEN
    RAISE EXCEPTION 'Warning offset % is not yet due', p_warning_offset_index USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_sla_clocks
  SET warned_up_to_index = p_warning_offset_index, lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'warning_fired', v_actor, p_idempotency_key,
    jsonb_build_object('warning_offset_index', p_warning_offset_index, 'expected_lock_version', p_expected_lock_version,
                        'result_lock_version', v_clock.lock_version + 1));

  RETURN QUERY SELECT p_clock_id, p_warning_offset_index, v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION record_workflow_sla_warning(UUID,BIGINT,INTEGER,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_workflow_sla_warning(UUID,BIGINT,INTEGER,UUID) TO authenticated;

COMMIT;
