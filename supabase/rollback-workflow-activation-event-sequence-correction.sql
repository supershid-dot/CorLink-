-- CAP-002 Phase 2B.2A rollback.
--
-- Restores workflow_transition_instance() to its exact pre-correction
-- (original Phase 2B.2) body, reverting only the next_event_sequence
-- arithmetic in the Approval branch back to the defective formula —
-- copied verbatim from supabase/patch-workflow-executable-instance-
-- activation.sql (a file this patch never edited, so it remains the
-- authoritative pre-correction source, not hand-transcribed).
--
-- Unlike every other rollback in this milestone chain, this one never
-- refuses: it changes only which formula a function uses on FUTURE
-- calls. It drops no table, deletes no row, and does not alter any
-- already-stored next_event_sequence value on any existing instance
-- (those were already computed and persisted by whichever function
-- version was active at the time; rolling back the function body
-- cannot retroactively change data already written). There is
-- therefore nothing for a preflight check to protect.
\set ON_ERROR_STOP on
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

  -- Executable-activation-only working state.
  v_version workflow_definition_versions;
  v_definition workflow_definitions;
  v_canonical JSONB;
  v_is_executable BOOLEAN := FALSE;
  v_entry_node_key TEXT;
  v_edge JSONB;
  v_target_node_key TEXT;
  v_target_node JSONB;
  v_target_type TEXT;
  v_start_step_id UUID;
  v_target_step_id UUID;
  v_token_id UUID;
  v_seq BIGINT;
  v_events_emitted INTEGER := 0;
  v_root_event_id UUID;
  v_config JSONB;
  v_requirement TEXT;
  v_delivery_mode TEXT;
  v_decision_rule TEXT;
  v_minimum_candidates INTEGER;
  v_minimum_approvals INTEGER;
  v_allow_self_approval BOOLEAN;
  v_allow_multi_capacity BOOLEAN;
  v_reject_behavior TEXT;
  v_allow_abstain BOOLEAN;
  v_comment_policy JSONB;
  v_candidates JSONB;
  v_electorate_count INTEGER;
  v_threshold INTEGER;
  v_round_id UUID;
  v_pos RECORD;
  v_work_item_id UUID;
  v_target_outcome_code TEXT;
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

  -- ── Executable-v1 activation (schema_version-gated; a legacy
  --    inert instance's pinned version has no 'schema_version' key
  --    and falls straight through to the unchanged Phase 2 path). ──
  IF p_command = 'start' THEN
    SELECT * INTO v_version FROM workflow_definition_versions WHERE id = v_instance.definition_version_id;
    v_is_executable := FOUND AND (v_version.definition_payload ? 'schema_version');
  END IF;

  IF v_is_executable THEN
    SELECT * INTO v_definition FROM workflow_definitions WHERE id = v_version.definition_id;

    -- Never substitute the family's current active version — the
    -- instance stays pinned to workflow_instances.definition_version_id,
    -- the immutable FK set once at instance creation and never rewritten.
    IF v_version.status <> 'published' THEN
      RAISE EXCEPTION 'Workflow definition version is not published' USING ERRCODE = '55000';
    END IF;

    -- Recompute canonical content/hash integrity using the exact
    -- Phase 2B.1 validator (never rewrites the stored payload).
    v_canonical := canonicalize_workflow_definition_payload(v_version.definition_payload, v_definition.organization_id);
    IF v_canonical <> v_version.definition_payload
       OR encode(digest(convert_to(v_canonical::TEXT, 'UTF8'), 'sha256'), 'hex') <> v_version.content_hash THEN
      RAISE EXCEPTION 'Workflow definition version failed publication integrity re-verification' USING ERRCODE = '0A000';
    END IF;

    v_entry_node_key := v_canonical ->> 'entry_node';

    -- Exactly one 'started' edge out of the entry node — already
    -- structurally guaranteed by the Phase 2B.1 validator, re-derived
    -- (not re-validated) here.
    SELECT e INTO v_edge
    FROM jsonb_array_elements(v_canonical -> 'edges') e
    WHERE e ->> 'source' = v_entry_node_key AND e ->> 'outcome' = 'started';
    v_target_node_key := v_edge ->> 'target';

    SELECT n INTO v_target_node
    FROM jsonb_array_elements(v_canonical -> 'nodes') n
    WHERE n ->> 'key' = v_target_node_key;
    v_target_type := v_target_node ->> 'type';

    v_result_lock_version := v_instance.lock_version + 1;
    v_seq := v_instance.next_event_sequence;

    -- 1. Start step: entered and completed atomically.
    INSERT INTO workflow_instance_steps (instance_id, definition_node_key, run_number, state, result_code, activated_at, ended_at)
    VALUES (p_instance_id, v_entry_node_key, 1, 'completed', 'started', v_now, v_now)
    RETURNING id INTO v_start_step_id;

    -- 2. One initial token, created at the Start step, then moved.
    INSERT INTO workflow_tokens (instance_id, step_id, token_key, state)
    VALUES (p_instance_id, v_start_step_id, 'epoch_' || v_instance.execution_epoch || '_token_1', 'active')
    RETURNING id INTO v_token_id;

    -- 3. Enter the first executable node's step run.
    INSERT INTO workflow_instance_steps (instance_id, definition_node_key, run_number, state, activated_at)
    VALUES (p_instance_id, v_target_node_key, 1,
      CASE WHEN v_target_type = 'end' THEN 'completed' ELSE 'waiting' END,
      v_now)
    RETURNING id INTO v_target_step_id;

    UPDATE workflow_tokens SET step_id = v_target_step_id WHERE id = v_token_id;

    v_events_emitted := 0;

    IF v_target_type = 'end' THEN
      -- Explicit, bounded docs/63 special case: Start -> End completes
      -- the node and the instance atomically. Not graph advancement —
      -- there is nowhere further to go from a terminal node.
      v_target_outcome_code := v_target_node -> 'config' ->> 'outcome_code';

      UPDATE workflow_instance_steps SET state = 'completed', result_code = v_target_outcome_code, ended_at = v_now
      WHERE id = v_target_step_id;
      UPDATE workflow_tokens SET state = 'consumed', consumed_at = v_now WHERE id = v_token_id;

      UPDATE workflow_instances
      SET status = 'completed', terminal_outcome = v_target_outcome_code,
          started_at = COALESCE(started_at, v_now), ended_at = v_now,
          lock_version = v_result_lock_version,
          next_event_sequence = next_event_sequence + 8
      WHERE id = p_instance_id;

      -- instance_started. The idempotency-replay path (shared,
      -- unmodified code above) reads new_status/terminal_outcome back
      -- out of THIS event's own metadata on retry, so they must
      -- reflect the transaction's actual final outcome — 'completed'
      -- here, not the intermediate 'active' state — even though this
      -- is still the same instance_started event docs/63 requires as
      -- the sole canonical activation event.
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'instance_started', v_actor, v_start_step_id, v_instance.correlation_id, p_idempotency_key,
        jsonb_build_object('command','start','previous_status',v_instance.status,'new_status','completed',
          'expected_lock_version',p_expected_lock_version,'result_lock_version',v_result_lock_version,
          'terminal_outcome',v_target_outcome_code,
          'definition_version_id',v_instance.definition_version_id))
      RETURNING id INTO v_root_event_id;
      -- token_created
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+1, 'token_created', v_actor, v_start_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('token_id',v_token_id,'node_key',v_entry_node_key));
      -- step_entered (start)
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+2, 'step_entered', v_actor, v_start_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_entry_node_key,'node_type','start'));
      -- step_completed (start)
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+3, 'step_completed', v_actor, v_start_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_entry_node_key,'result_code','started'));
      -- token_moved
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+4, 'token_moved', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('token_id',v_token_id,'from_node_key',v_entry_node_key,'to_node_key',v_target_node_key));
      -- step_entered (end)
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+5, 'step_entered', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_target_node_key,'node_type','end'));
      -- step_completed (end)
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+6, 'step_completed', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_target_node_key,'result_code',v_target_outcome_code));
      -- instance_completed
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+7, 'instance_completed', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('previous_status','active','new_status','completed','terminal_outcome',v_target_outcome_code));

      RETURN QUERY SELECT p_instance_id, 'completed'::TEXT, v_target_outcome_code, v_result_lock_version, v_root_event_id, v_seq, FALSE;
      RETURN;

    ELSIF v_target_type = 'approval' THEN
      v_config := v_target_node -> 'config';
      v_requirement := v_config ->> 'requirement';
      v_delivery_mode := v_config ->> 'delivery_mode';
      v_decision_rule := v_config ->> 'decision_rule';
      v_minimum_candidates := (v_config ->> 'minimum_candidates')::INT;
      v_minimum_approvals := NULLIF(v_config ->> 'minimum_approvals', '')::INT;
      v_allow_self_approval := (v_config ->> 'allow_self_approval')::BOOLEAN;
      v_allow_multi_capacity := (v_config ->> 'allow_multi_capacity')::BOOLEAN;
      v_reject_behavior := v_config ->> 'reject_behavior';
      v_allow_abstain := (v_config ->> 'allow_abstain')::BOOLEAN;
      v_comment_policy := v_config -> 'comment_policy';

      -- Candidate resolution — private server boundary; clients never
      -- submit resolved candidates. Ordered by (selector order,
      -- selector key, authority source, user id) per docs/63.
      WITH selectors AS (
        SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
        FROM jsonb_array_elements(v_config -> 'candidate_selectors') s
      ),
      resolved AS (
        SELECT sel.selector_key, sel.sel_order, u.id AS user_id,
               'explicit_user:' || sel.selector_key AS authority_source
        FROM selectors sel
        JOIN LATERAL jsonb_array_elements_text(sel.s -> 'user_ids') AS uid(v) ON TRUE
        JOIN users u ON u.id = uid.v::UUID AND u.is_active AND u.org_id = v_instance.home_organization_id
        WHERE sel.sel_type = 'explicit_user'

        UNION ALL

        SELECT sel.selector_key, sel.sel_order, ua.user_id,
               'organization_role:' || (sel.s ->> 'role') AS authority_source
        FROM selectors sel
        JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
          AND scope_org_id(ua.scope_type, ua.scope_id) = v_instance.home_organization_id
        JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = v_instance.home_organization_id
        WHERE sel.sel_type = 'organization_role'

        UNION ALL

        SELECT sel.selector_key, sel.sel_order, ua.user_id,
               'section_role:' || (sel.s ->> 'role') AS authority_source
        FROM selectors sel
        JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
          AND (sel.s ->> 'section_id')::UUID IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
        JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = v_instance.home_organization_id
        WHERE sel.sel_type = 'section_role'

        UNION ALL

        SELECT sel.selector_key, sel.sel_order, p.user_id,
               'instance_participant_role:' || (sel.s ->> 'participant_role') AS authority_source
        FROM selectors sel
        JOIN workflow_participants p ON p.instance_id = p_instance_id
          AND p.participant_role = (sel.s ->> 'participant_role') AND p.ended_at IS NULL
        JOIN users u ON u.id = p.user_id AND u.is_active
        WHERE sel.sel_type = 'instance_participant_role'
      ),
      filtered AS (
        SELECT * FROM resolved
        WHERE v_allow_self_approval OR user_id <> v_instance.created_by
      ),
      deduped_check AS (
        SELECT user_id, count(*) AS n FROM filtered GROUP BY user_id HAVING count(*) > 1
      ),
      ordered AS (
        SELECT user_id, authority_source, selector_key,
               row_number() OVER (ORDER BY sel_order, selector_key, authority_source, user_id) AS ordinal
        FROM filtered
        WHERE v_allow_multi_capacity OR user_id NOT IN (SELECT user_id FROM deduped_check)
      )
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', user_id, 'authority_source', authority_source, 'selector_key', selector_key, 'ordinal', ordinal
      ) ORDER BY ordinal)
      INTO v_candidates
      FROM ordered;

      IF NOT v_allow_multi_capacity AND EXISTS (
        SELECT 1 FROM (
          SELECT user_id, count(*) AS n FROM (
            SELECT sel.selector_key, sel.sel_order, u.id AS user_id
            FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
                  FROM jsonb_array_elements(v_config -> 'candidate_selectors') s) sel
            JOIN LATERAL jsonb_array_elements_text(sel.s -> 'user_ids') AS uid(v) ON sel.sel_type = 'explicit_user'
            JOIN users u ON u.id = uid.v::UUID AND u.is_active AND u.org_id = v_instance.home_organization_id
            UNION ALL
            SELECT sel.selector_key, sel.sel_order, ua.user_id
            FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
                  FROM jsonb_array_elements(v_config -> 'candidate_selectors') s) sel
            JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
              AND scope_org_id(ua.scope_type, ua.scope_id) = v_instance.home_organization_id AND sel.sel_type = 'organization_role'
            JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = v_instance.home_organization_id
            UNION ALL
            SELECT sel.selector_key, sel.sel_order, ua.user_id
            FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
                  FROM jsonb_array_elements(v_config -> 'candidate_selectors') s) sel
            JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
              AND (sel.s ->> 'section_id')::UUID IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id)) AND sel.sel_type = 'section_role'
            JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = v_instance.home_organization_id
            UNION ALL
            SELECT sel.selector_key, sel.sel_order, p.user_id
            FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
                  FROM jsonb_array_elements(v_config -> 'candidate_selectors') s) sel
            JOIN workflow_participants p ON p.instance_id = p_instance_id AND p.participant_role = (sel.s ->> 'participant_role')
              AND p.ended_at IS NULL AND sel.sel_type = 'instance_participant_role'
            JOIN users u ON u.id = p.user_id AND u.is_active
          ) x
          WHERE v_allow_self_approval OR user_id <> v_instance.created_by
          GROUP BY user_id HAVING count(*) > 1
        ) dup
      ) THEN
        RAISE EXCEPTION 'Candidate resolution found a duplicate user across selectors and allow_multi_capacity is false' USING ERRCODE = '55000';
      END IF;

      v_electorate_count := COALESCE(jsonb_array_length(v_candidates), 0);

      IF v_requirement = 'required' AND v_electorate_count < v_minimum_candidates THEN
        RAISE EXCEPTION 'Resolved candidate count % is below the required minimum %', v_electorate_count, v_minimum_candidates
          USING ERRCODE = '55000';
      END IF;
      IF v_requirement = 'optional' AND v_electorate_count = 0 THEN
        -- docs/63: a zero-candidate optional round is skipped and the
        -- token follows the 'skipped' edge — that is graph advancement
        -- past the first executable node, explicitly out of Phase
        -- 2B.2's scope. Fail closed rather than silently advancing or
        -- silently leaving an ambiguous half-entered node.
        RAISE EXCEPTION 'Optional approval node % resolved zero candidates; skip-and-advance requires Phase 2C graph advancement, not implemented in Phase 2B.2', v_target_node_key
          USING ERRCODE = '0A000';
      END IF;
      IF v_requirement = 'optional' AND v_electorate_count > 0 AND v_electorate_count < v_minimum_candidates THEN
        RAISE EXCEPTION 'Resolved candidate count % is below the configured minimum % (nonzero undersized electorate is a configuration error, not a skip)', v_electorate_count, v_minimum_candidates
          USING ERRCODE = '55000';
      END IF;

      v_threshold := CASE
        WHEN v_decision_rule = 'unanimous' THEN v_electorate_count
        ELSE GREATEST(FLOOR(v_electorate_count / 2.0)::INT + 1, COALESCE(v_minimum_approvals, 0))
      END;

      UPDATE workflow_instances
      SET status = 'active', started_at = COALESCE(started_at, v_now),
          lock_version = v_result_lock_version,
          next_event_sequence = next_event_sequence + 5 + v_electorate_count + LEAST(v_electorate_count, CASE WHEN v_delivery_mode = 'parallel' THEN v_electorate_count ELSE 1 END)
      WHERE id = p_instance_id;

      -- instance_started
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'instance_started', v_actor, v_start_step_id, v_instance.correlation_id, p_idempotency_key,
        jsonb_build_object('command','start','previous_status',v_instance.status,'new_status','active',
          'expected_lock_version',p_expected_lock_version,'result_lock_version',v_result_lock_version,
          'definition_version_id',v_instance.definition_version_id))
      RETURNING id INTO v_root_event_id;
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+1, 'token_created', v_actor, v_start_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('token_id',v_token_id,'node_key',v_entry_node_key));
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+2, 'step_entered', v_actor, v_start_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_entry_node_key,'node_type','start'));
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+3, 'step_completed', v_actor, v_start_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_entry_node_key,'result_code','started'));
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq+4, 'token_moved', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('token_id',v_token_id,'from_node_key',v_entry_node_key,'to_node_key',v_target_node_key));
      v_seq := v_seq + 5;
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'step_entered', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_target_node_key,'node_type','approval'));
      v_seq := v_seq + 1;

      INSERT INTO workflow_approval_rounds (
        instance_id, step_id, token_id, execution_epoch, delivery_mode, decision_rule, requirement,
        optional_policy, minimum_candidates, electorate_count, approval_threshold, reject_behavior,
        allow_abstain, comment_policy, state, opened_by, causation_event_id, opened_at
      ) VALUES (
        p_instance_id, v_target_step_id, v_token_id, v_instance.execution_epoch, v_delivery_mode, v_decision_rule, v_requirement,
        v_config ->> 'optional_policy', v_minimum_candidates, v_electorate_count, v_threshold, v_reject_behavior,
        v_allow_abstain, v_comment_policy, 'open', v_actor, v_root_event_id, v_now
      ) RETURNING id INTO v_round_id;
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'approval_round_opened', v_actor, v_target_step_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
        jsonb_build_object('round_id',v_round_id,'electorate_count',v_electorate_count,'approval_threshold',v_threshold,
          'delivery_mode',v_delivery_mode,'decision_rule',v_decision_rule));
      v_seq := v_seq + 1;

      FOR v_pos IN SELECT * FROM jsonb_to_recordset(v_candidates) AS x(user_id UUID, authority_source TEXT, selector_key TEXT, ordinal INT)
      LOOP
        IF v_delivery_mode = 'parallel' OR v_pos.ordinal = 1 THEN
          INSERT INTO workflow_work_items (
            instance_id, step_id, token_id, work_item_type, state, organization_id, assigned_to, offered_at
          ) VALUES (
            p_instance_id, v_target_step_id, v_token_id, 'approval', 'offered',
            v_instance.home_organization_id, v_pos.user_id, v_now
          ) RETURNING id INTO v_work_item_id;

          INSERT INTO workflow_approval_positions (
            instance_id, round_id, step_id, position_key, ordinal, user_id, authority_source,
            organization_id, selector_key, state, work_item_id, offered_at
          ) VALUES (
            p_instance_id, v_round_id, v_target_step_id, 'position_' || v_pos.ordinal, v_pos.ordinal, v_pos.user_id, v_pos.authority_source,
            v_instance.home_organization_id, v_pos.selector_key, 'offered', v_work_item_id, v_now
          );

          INSERT INTO workflow_participants (instance_id, work_item_id, user_id, participant_role, authority_source, created_by)
          VALUES (p_instance_id, v_work_item_id, v_pos.user_id, 'candidate', v_pos.authority_source, v_actor);

          INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, work_item_id, correlation_id, causation_id, idempotency_key, metadata)
          VALUES (p_instance_id, v_seq, 'work_item_created', v_actor, v_target_step_id, v_work_item_id, v_instance.correlation_id, v_root_event_id, gen_random_uuid(),
            jsonb_build_object('round_id',v_round_id,'ordinal',v_pos.ordinal));
          v_seq := v_seq + 1;
        ELSE
          INSERT INTO workflow_approval_positions (
            instance_id, round_id, step_id, position_key, ordinal, user_id, authority_source,
            organization_id, selector_key, state
          ) VALUES (
            p_instance_id, v_round_id, v_target_step_id, 'position_' || v_pos.ordinal, v_pos.ordinal, v_pos.user_id, v_pos.authority_source,
            v_instance.home_organization_id, v_pos.selector_key, 'pending'
          );

          INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
          VALUES (p_instance_id, v_pos.user_id, 'candidate', v_pos.authority_source, v_actor);
        END IF;
      END LOOP;

      RETURN QUERY SELECT p_instance_id, 'active'::TEXT, NULL::TEXT, v_result_lock_version, v_root_event_id, v_instance.next_event_sequence, FALSE;
      RETURN;

    ELSE
      RAISE EXCEPTION 'Unsupported first executable node type: %', v_target_type USING ERRCODE = '0A000';
    END IF;
  END IF;

  -- ── Original Phase 2 behavior — legacy inert instances (any
  --    command), and non-'start' commands on any instance. Byte-for-
  --    byte unchanged. ────────────────────────────────────────────
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

    UPDATE workflow_approval_rounds r
    SET state = 'cancelled', outcome_code = 'cancelled', completed_at = v_now
    WHERE r.instance_id = p_instance_id AND r.state = 'open';

    UPDATE workflow_approval_positions p
    SET state = 'cancelled', cancelled_at = v_now
    WHERE p.instance_id = p_instance_id AND p.state IN ('pending','offered');
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

-- Signature unchanged; existing grants (revoked from PUBLIC/anon/
-- authenticated, callable only via the five narrow wrapper RPCs)
-- remain in effect without a REGRANT.

COMMIT;
