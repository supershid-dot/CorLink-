-- CAP-002 Phase 5.3A -- SLA timing architecture-conformance
-- correction, applied on top of patch-workflow-sla-escalation-
-- foundation.sql (commit 7cdc86e). This patch does not redesign
-- Phase 5.3; it corrects exactly the three items confirmed by a
-- read-only architecture-conformance review against docs/60 and
-- docs/73, and touches nothing else -- the seven-action allowlist,
-- clock state model, pause/resume semantics, deadline source
-- preservation, policy model, escalation-level ordering, RLS model,
-- authorization model, delegation/substitution integration, and every
-- other already-approved piece of this milestone is unchanged.
--
-- Correction 1 -- restart must not be a standalone authenticated
-- command. Docs/73's own "Open questions / deferred items" section
-- states verbatim: "Whether SLA clock 'restart' should ever be
-- triggerable by anything other than Reopen is left open; no other
-- trigger is approved by this document." The original patch granted
-- EXECUTE on restart_workflow_sla_clock to authenticated, making it a
-- directly callable command with no Reopen precondition -- providing
-- exactly the thing docs/73 declines to approve, not a narrow
-- concretization of an open detail. This patch revokes that grant.
-- The function's implementation (epoch handling, prior-epoch
-- snapshotting, deadline recomputation) is otherwise sound and is
-- preserved unchanged as a private primitive a future, separately
-- approved Reopen RPC can call once Reopen itself exists. No Reopen
-- RPC and no other trigger are invented here.
--
-- Correction 2 -- business_hours/business_days offsets (both warning
-- offsets and escalation-level offsets) must respect the pinned
-- business calendar (working days, working hours, timezone,
-- holidays, and the SPECIFIC calendar version pinned to the clock at
-- creation time -- never "whatever the calendar's current version
-- is"), exactly as docs/73 uses calendar-flavored language and
-- examples for both ("2 business days before due," "24 business
-- hours after breach") with no separate, simplified arithmetic rule
-- ever stated for offsets. The original patch's
-- workflow_sla_offset_interval treated business_hours/business_days
-- identically to plain hours/days (pure wall-clock arithmetic,
-- calendar-oblivious). This patch:
--   * adds workflow_calculate_calendar_offset_backward, mirroring the
--     exact bounded/timezone-aware/holiday-aware walking algorithm
--     workflow_calculate_calendar_deadline already uses for forward
--     deadline computation, walking backward instead -- the same
--     calendar engine, generalized to the other direction, not a
--     second engine;
--   * reuses workflow_calculate_calendar_deadline UNCHANGED for the
--     forward direction escalation offsets need (a level fires N
--     business hours/days after breach or the previous level) --
--     this is exactly what that function already computes;
--   * updates record_workflow_sla_warning, workflow_sla_clocks_due_
--     for_warning, and workflow_sla_clocks_due_for_escalation to call
--     the appropriate directional, calendar-version-pinned function
--     instead of the old calendar-oblivious interval helper;
--   * drops workflow_sla_offset_interval (no longer referenced
--     anywhere) and tightens create_workflow_sla_policy's own
--     validation so a policy can never be created with a calendar-
--     aware warning offset or a calendar-aware escalation-level
--     offset while carrying no calendar_id -- the exact combination
--     that would otherwise leave a business_* offset unevaluable at
--     due-detection time.
-- Plain hours/days offsets are untouched: both directional functions'
-- own plain-unit branch is unchanged wall-clock interval arithmetic.
-- Calendar-version pinning is unaffected -- every callsite still
-- reads calendar_version_id off the clock row exactly as before, so
-- a historical clock's timing is never recomputed against a newer
-- calendar version.
--
-- Correction 3 -- escalation evidence self-documentation. The six
-- evidence-only escalation actions were, and remain, correct
-- (docs/73's own architecture-phase scope statement excludes
-- notification delivery and module-adapter changes, and the
-- governing Phase 5.3 instruction explicitly forbade building them);
-- the review found only that the schema itself did not self-document
-- this distinction. This patch adds COMMENT ON TABLE/COLUMN making
-- the due/triggered-vs-performed distinction explicit for any future
-- reader of workflow_escalation_events, without adding a status
-- column or any other schema change.
\set ON_ERROR_STOP on
BEGIN;

-- ─── Correction 1: restart is no longer directly callable ──────────
REVOKE ALL ON FUNCTION restart_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) FROM authenticated;

-- ─── Correction 2: calendar-aware business-time offsets ────────────

-- Backward calendar walk -- the mirror image of workflow_calculate_
-- calendar_deadline's forward walk, used for "N business hours/days
-- BEFORE a given instant" (warning offsets). Same bounded iteration
-- count, same timezone/working-day/working-hours/holiday handling,
-- same plain-unit passthrough for 'hours'/'days'.
CREATE OR REPLACE FUNCTION workflow_calculate_calendar_offset_backward(
  p_end TIMESTAMPTZ,
  p_amount NUMERIC,
  p_unit TEXT,
  p_calendar_version_id UUID,
  p_timezone TEXT
) RETURNS TIMESTAMPTZ AS $$
DECLARE
  v_cal workflow_business_calendar_versions;
  v_remaining_minutes NUMERIC;
  v_local TIMESTAMP;
  v_day_start TIMESTAMP;
  v_day_end TIMESTAMP;
  v_available NUMERIC;
  v_iterations INTEGER := 0;
BEGIN
  IF p_amount < 0 THEN
    RAISE EXCEPTION 'Duration amount must be non-negative' USING ERRCODE = '22023';
  END IF;

  IF p_unit IN ('hours','days') THEN
    RETURN p_end - (p_amount || ' ' || p_unit)::INTERVAL;
  END IF;

  IF p_unit NOT IN ('business_hours','business_days') THEN
    RAISE EXCEPTION 'Unsupported duration unit: %', p_unit USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cal FROM workflow_business_calendar_versions WHERE id = p_calendar_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown business calendar version' USING ERRCODE = '22023';
  END IF;

  v_remaining_minutes := CASE
    WHEN p_unit = 'business_hours' THEN p_amount * 60
    ELSE p_amount * (EXTRACT(EPOCH FROM (v_cal.working_hours_end - v_cal.working_hours_start)) / 60)
  END;

  v_local := p_end AT TIME ZONE p_timezone;

  LOOP
    v_iterations := v_iterations + 1;
    IF v_iterations > 3660 THEN
      RAISE EXCEPTION 'Calendar offset calculation exceeded the defensive iteration bound' USING ERRCODE = '0A000';
    END IF;

    v_day_start := date_trunc('day', v_local) + v_cal.working_hours_start;
    v_day_end   := date_trunc('day', v_local) + v_cal.working_hours_end;

    IF EXTRACT(ISODOW FROM v_local)::INTEGER = ANY(v_cal.working_days)
       AND date_trunc('day', v_local)::DATE <> ALL(v_cal.holidays)
    THEN
      IF v_local > v_day_end THEN v_local := v_day_end; END IF;
      IF v_local > v_day_start THEN
        v_available := EXTRACT(EPOCH FROM (v_local - v_day_start)) / 60;
        IF v_available >= v_remaining_minutes THEN
          v_local := v_local - (v_remaining_minutes || ' minutes')::INTERVAL;
          v_remaining_minutes := 0;
        ELSE
          v_remaining_minutes := v_remaining_minutes - v_available;
          v_local := v_day_start;
        END IF;
      END IF;
    END IF;

    EXIT WHEN v_remaining_minutes <= 0;

    -- Continue walking backward from the end of the previous
    -- calendar day's working window (mirrors the forward function's
    -- "date_trunc('day', v_local) + INTERVAL '1 day'" step to the
    -- start of the next day).
    v_local := date_trunc('day', v_local) - INTERVAL '1 day' + v_cal.working_hours_end;
  END LOOP;

  RETURN v_local AT TIME ZONE p_timezone;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_calculate_calendar_offset_backward(TIMESTAMPTZ,NUMERIC,TEXT,UUID,TEXT) FROM PUBLIC, anon, authenticated;

-- create_workflow_sla_policy: unchanged except for the added
-- validation that a calendar_id is required whenever any warning
-- offset, or any level of the referenced escalation policy, uses a
-- calendar-aware unit -- otherwise such an offset could never be
-- evaluated (no calendar_version_id would ever be pinned to a clock
-- created from this policy).
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
      IF (v_offset ->> 'unit') IN ('business_hours','business_days') AND p_calendar_id IS NULL THEN
        RAISE EXCEPTION 'A calendar_id is required when any warning offset uses a calendar-aware unit' USING ERRCODE = '22023';
      END IF;
    END LOOP;
  END IF;
  IF p_escalation_policy_id IS NOT NULL AND p_calendar_id IS NULL AND EXISTS (
    SELECT 1 FROM workflow_escalation_levels lvl
    WHERE lvl.escalation_policy_id = p_escalation_policy_id AND lvl.offset_unit IN ('business_hours','business_days')
  ) THEN
    RAISE EXCEPTION 'A calendar_id is required when the referenced escalation policy has any calendar-aware level offset' USING ERRCODE = '22023';
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

-- create_workflow_sla_clock: identical except a calendar version is
-- now resolved and pinned whenever the policy carries a calendar_id
-- at all, not only when the clock's OWN deadline needs calendar
-- arithmetic. Without this, a plain-duration policy (e.g. "4 hours")
-- whose warning offsets or escalation levels are calendar-aware would
-- create a clock with calendar_version_id left NULL -- exactly the
-- combination create_workflow_sla_policy's new validation (above)
-- exists to prevent from ever silently going unevaluable, but the
-- clock itself must actually carry the pin for those offsets to be
-- computable at all.
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
    IF v_policy.duration_unit IN ('business_hours','business_days') OR v_policy.calendar_id IS NOT NULL THEN
      SELECT * INTO v_calendar FROM workflow_business_calendars WHERE id = v_policy.calendar_id;
      IF v_calendar.active_version_id IS NULL THEN
        RAISE EXCEPTION 'Calendar has no published version' USING ERRCODE = '0A000';
      END IF;
      IF v_policy.duration_unit IN ('business_hours','business_days') THEN
        v_deadline := workflow_calculate_calendar_deadline(
          v_now, v_policy.duration_amount, v_policy.duration_unit, v_calendar.active_version_id, v_policy.timezone
        );
      ELSE
        v_deadline := workflow_calculate_calendar_deadline(v_now, v_policy.duration_amount, v_policy.duration_unit, NULL, v_policy.timezone);
      END IF;
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

-- record_workflow_sla_warning: identical except the due_at
-- computation now calls the calendar-aware backward function
-- (calendar-version-pinned to the clock) instead of the old
-- calendar-oblivious interval helper.
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
  v_due_at := workflow_calculate_calendar_offset_backward(
    v_clock.effective_deadline_adjusted, (v_offset ->> 'amount')::NUMERIC, v_offset ->> 'unit',
    v_clock.calendar_version_id, v_clock.timezone
  );
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

-- workflow_sla_clocks_due_for_warning: identical shape, now calls the
-- calendar-aware backward function (still calendar-version-pinned to
-- each clock, never "the calendar's current version").
CREATE OR REPLACE FUNCTION workflow_sla_clocks_due_for_warning(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  clock_id UUID, instance_id UUID, warning_offset_index INTEGER,
  due_at TIMESTAMPTZ, effective_deadline_adjusted TIMESTAMPTZ
) AS $$
  SELECT c.id, c.instance_id, (c.warned_up_to_index + 1)::INTEGER, w.due_at, c.effective_deadline_adjusted
  FROM workflow_sla_clocks c
  CROSS JOIN LATERAL (
    SELECT workflow_calculate_calendar_offset_backward(
      c.effective_deadline_adjusted,
      (c.warning_offsets -> (c.warned_up_to_index + 1) ->> 'amount')::NUMERIC,
      c.warning_offsets -> (c.warned_up_to_index + 1) ->> 'unit',
      c.calendar_version_id, c.timezone
    ) AS due_at
  ) w
  WHERE c.state = 'running'
    AND c.warned_up_to_index + 1 < jsonb_array_length(c.warning_offsets)
    AND w.due_at <= clock_timestamp()
  ORDER BY w.due_at
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_clocks_due_for_warning(INTEGER) FROM PUBLIC, anon, authenticated;

-- workflow_sla_clocks_due_for_escalation: identical shape, now calls
-- workflow_calculate_calendar_deadline (the existing forward
-- calendar walk, unchanged) instead of the old calendar-oblivious
-- interval helper, still calendar-version-pinned to each clock.
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
      CASE WHEN (
        CASE
          WHEN lvl.offset_from = 'breach' THEN c.breached_at
          WHEN lvl.level_order = 1 THEN c.breached_at
          ELSE (SELECT e.occurred_at FROM workflow_escalation_events e
                WHERE e.clock_id = c.id AND e.level_order = lvl.level_order - 1)
        END
      ) IS NULL THEN NULL
      ELSE workflow_calculate_calendar_deadline(
        (CASE
          WHEN lvl.offset_from = 'breach' THEN c.breached_at
          WHEN lvl.level_order = 1 THEN c.breached_at
          ELSE (SELECT e.occurred_at FROM workflow_escalation_events e
                WHERE e.clock_id = c.id AND e.level_order = lvl.level_order - 1)
        END),
        lvl.offset_amount, lvl.offset_unit, c.calendar_version_id, c.timezone
      )
      END
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

-- workflow_sla_offset_interval is no longer referenced anywhere (its
-- three call sites above have all been updated to call the
-- appropriate directional, calendar-aware function instead) --
-- dropped rather than left as dead code.
DROP FUNCTION IF EXISTS workflow_sla_offset_interval(NUMERIC,TEXT);

-- ─── Correction 3: escalation-evidence self-documentation ──────────
COMMENT ON TABLE workflow_escalation_events IS
  'Append-only evidence: one row per escalation level that has fired. '
  'A row means the action became due/triggered and was recorded -- it '
  'does NOT prove an external effect (notification, module action, '
  'candidate change) was actually delivered or performed. The sole '
  'exception is action_code = ''mark_breached'', which also performs '
  'a real effect on the owning workflow_sla_clocks row (setting '
  'breached_at) in the same transaction as this evidence row. '
  'Notification delivery and every other action''s external/module '
  'side effect remain deferred to a later milestone.';

COMMENT ON COLUMN workflow_escalation_events.action_code IS
  'One of the seven closed escalation actions (docs/60/docs/73). '
  'Records that this action became due/triggered for this level -- '
  'only mark_breached is also actually performed by this schema; the '
  'other six are evidence of a due/requested action, not proof of '
  'external delivery or completion.';

COMMIT;
