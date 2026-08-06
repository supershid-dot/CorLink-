-- ============================================================
-- CAP-002 Phase 4.2: Exclusive Gateway Routing Execution
--
-- Implements docs/69-workflow-routing-gateway-contract.md's
-- "Routing execution model" and docs/70's variable-read side on top
-- of the approved baseline through Phase 4.1A
-- (patch-workflow-routing-validation-foundation.sql).
--
-- Scope boundary: this patch adds the ability for the shared
-- graph-advancement authority (workflow_enter_downstream_node) to
-- execute a gateway_exclusive node it encounters — evaluate its
-- outbound edges' conditions in ascending priority order, select the
-- first matching edge or the mandatory default, emit route_selected,
-- and continue the bounded loop into the selected target. It adds no
-- new node type, no new command, no new permission model, and no
-- split/join/parallel-token capability. Every schema_version=1
-- payload and every payload without a gateway_exclusive node
-- continues to execute through byte-for-byte the same code paths
-- Phase 3.2 already established.
--
-- Structural approach: exactly the same "new branch inside the
-- existing bounded loop" shape Phase 3.2 already used for the
-- empty-electorate skip case, generalized from "one deferred case" to
-- a second synchronous, no-human-decision node type. No signature of
-- workflow_transition_instance, workflow_advance_graph_step, or
-- decide_workflow_work_item changes — none of the three outer callers
-- need to know a gateway node exists at all, because the peek-before-
-- write helper (workflow_peek_final_graph_target) and the real
-- graph-advancement helper (workflow_enter_downstream_node) are the
-- only two functions that need to learn about gateway_exclusive, and
-- both already receive the canonical payload and instance id they
-- need. The only other change is widening two pre-existing immediate-
-- target-type guard checks (in workflow_transition_instance's 'start'
-- branch and workflow_advance_graph_step's own glue) from
-- ('approval','end') to ('approval','end','gateway_exclusive'), since
-- a graph's very first or very next node can itself be a gateway.
-- decide_workflow_work_item needs no such widening — it already
-- routes exclusively through the peek helper and the shared entry
-- helper with no inline type check of its own.
--
-- Condition evaluation: a new, shared, STABLE, SECURITY DEFINER
-- helper (workflow_evaluate_gateway_condition) implements exactly the
-- closed operator/type allowlist docs/69 defines — equals, not_equals,
-- in, not_in, greater_than(_or_equal), less_than(_or_equal), is_null,
-- is_not_null over boolean/number/string/date/timestamp/uuid — reading
-- only workflow_variables for the instance being routed, under the
-- instance row lock the bounded loop's caller already holds (no new
-- lock tier). No arbitrary SQL, no dynamic expressions, no
-- user-defined functions, no adapters: the operator/value_type
-- allowlist is a closed PL/pgSQL CASE, not a string eval.
--
-- Undefined/type-mismatched variable handling (docs/69 "Undefined
-- variable handling", resolved precisely per that section's own
-- worked example): for is_null/is_not_null, a missing variable (or
-- one whose value_type is 'null', or whose variable_value is JSON
-- null) is treated as null — is_null returns true, is_not_null
-- returns false. This is a deliberate, necessary carve-out from the
-- blanket "undefined evaluates to false" rule: is_null/is_not_null's
-- entire purpose is to test for absence, and docs/69 itself describes
-- exercising the undefined-variable path specifically via is_null/
-- is_not_null (see its "load-bearing open dependency" section) — a
-- rule that returned false unconditionally for is_null would make
-- that description meaningless. Every other operator returns false
-- (never matches, never raises) when the variable is missing, is
-- explicitly null, or its stored value_type does not match the
-- condition's declared value_type — matching docs/69's literal text
-- for the comparison operators exactly.
--
-- Branch selection: a new, shared helper
-- (workflow_resolve_gateway_target) evaluates a gateway node's
-- non-default outbound edges in ascending priority order, stops at
-- the first match, and falls back to the mandatory default edge if
-- none match — reused identically by both workflow_enter_downstream_
-- node's real entry pass and workflow_peek_final_graph_target's
-- pre-computation pass, so the two can never disagree, matching the
-- exact discipline Phase 3.2 already established for the shared
-- approval-candidate-resolution helper.
--
-- Events: one new event type, route_selected (already reserved by
-- docs/69's event contract, unused until now), closing the gateway's
-- own step in the same structural position step_skipped already
-- occupies for the skip branch — a single dedicated closing event,
-- not step_skipped plus a redundant generic step_completed.
-- ============================================================

BEGIN;

-- ── 1. workflow_evaluate_gateway_condition — the closed condition
--    registry. Not granted to any role. ────────────────────────────
CREATE OR REPLACE FUNCTION workflow_evaluate_gateway_condition(
  p_instance_id UUID,
  p_condition JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_operator TEXT := p_condition ->> 'operator';
  v_variable_name TEXT := p_condition ->> 'variable_name';
  v_declared_type TEXT := p_condition ->> 'value_type';
  v_var workflow_variables;
  v_found BOOLEAN;
  v_value JSONB := p_condition -> 'value';
BEGIN
  SELECT * INTO v_var FROM workflow_variables
  WHERE instance_id = p_instance_id AND variable_name = v_variable_name;
  v_found := FOUND;

  -- is_null/is_not_null test for absence directly — the one
  -- deliberate carve-out from the "undefined evaluates to false"
  -- rule below (see this file's header comment).
  IF v_operator = 'is_null' THEN
    RETURN (NOT v_found) OR v_var.value_type = 'null' OR jsonb_typeof(v_var.variable_value) = 'null';
  ELSIF v_operator = 'is_not_null' THEN
    RETURN v_found AND v_var.value_type <> 'null' AND jsonb_typeof(v_var.variable_value) <> 'null';
  END IF;

  -- Every other operator: an undefined, explicitly null, or
  -- type-mismatched variable never matches. Deterministic false,
  -- never an exception, never NULL propagation — docs/69's own rule,
  -- applied literally.
  IF NOT v_found OR v_var.value_type = 'null' OR v_var.value_type <> v_declared_type THEN
    RETURN FALSE;
  END IF;

  CASE v_declared_type
    WHEN 'boolean' THEN
      CASE v_operator
        WHEN 'equals' THEN RETURN v_var.variable_value = v_value;
        WHEN 'not_equals' THEN RETURN v_var.variable_value <> v_value;
        ELSE RETURN FALSE;
      END CASE;
    WHEN 'number' THEN
      CASE v_operator
        WHEN 'equals' THEN RETURN (v_var.variable_value #>> '{}')::NUMERIC = (v_value #>> '{}')::NUMERIC;
        WHEN 'not_equals' THEN RETURN (v_var.variable_value #>> '{}')::NUMERIC <> (v_value #>> '{}')::NUMERIC;
        WHEN 'greater_than' THEN RETURN (v_var.variable_value #>> '{}')::NUMERIC > (v_value #>> '{}')::NUMERIC;
        WHEN 'greater_than_or_equal' THEN RETURN (v_var.variable_value #>> '{}')::NUMERIC >= (v_value #>> '{}')::NUMERIC;
        WHEN 'less_than' THEN RETURN (v_var.variable_value #>> '{}')::NUMERIC < (v_value #>> '{}')::NUMERIC;
        WHEN 'less_than_or_equal' THEN RETURN (v_var.variable_value #>> '{}')::NUMERIC <= (v_value #>> '{}')::NUMERIC;
        WHEN 'in' THEN RETURN EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_value) e WHERE (e #>> '{}')::NUMERIC = (v_var.variable_value #>> '{}')::NUMERIC
        );
        WHEN 'not_in' THEN RETURN NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_value) e WHERE (e #>> '{}')::NUMERIC = (v_var.variable_value #>> '{}')::NUMERIC
        );
        ELSE RETURN FALSE;
      END CASE;
    WHEN 'string' THEN
      CASE v_operator
        WHEN 'equals' THEN RETURN (v_var.variable_value #>> '{}') = (v_value #>> '{}');
        WHEN 'not_equals' THEN RETURN (v_var.variable_value #>> '{}') <> (v_value #>> '{}');
        WHEN 'in' THEN RETURN EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_value) e WHERE e = (v_var.variable_value #>> '{}'));
        WHEN 'not_in' THEN RETURN NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_value) e WHERE e = (v_var.variable_value #>> '{}'));
        ELSE RETURN FALSE;
      END CASE;
    WHEN 'uuid' THEN
      CASE v_operator
        WHEN 'equals' THEN RETURN (v_var.variable_value #>> '{}') = (v_value #>> '{}');
        WHEN 'not_equals' THEN RETURN (v_var.variable_value #>> '{}') <> (v_value #>> '{}');
        WHEN 'in' THEN RETURN EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_value) e WHERE e = (v_var.variable_value #>> '{}'));
        WHEN 'not_in' THEN RETURN NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_value) e WHERE e = (v_var.variable_value #>> '{}'));
        ELSE RETURN FALSE;
      END CASE;
    WHEN 'date' THEN
      CASE v_operator
        WHEN 'equals' THEN RETURN (v_var.variable_value #>> '{}')::DATE = (v_value #>> '{}')::DATE;
        WHEN 'not_equals' THEN RETURN (v_var.variable_value #>> '{}')::DATE <> (v_value #>> '{}')::DATE;
        WHEN 'greater_than' THEN RETURN (v_var.variable_value #>> '{}')::DATE > (v_value #>> '{}')::DATE;
        WHEN 'greater_than_or_equal' THEN RETURN (v_var.variable_value #>> '{}')::DATE >= (v_value #>> '{}')::DATE;
        WHEN 'less_than' THEN RETURN (v_var.variable_value #>> '{}')::DATE < (v_value #>> '{}')::DATE;
        WHEN 'less_than_or_equal' THEN RETURN (v_var.variable_value #>> '{}')::DATE <= (v_value #>> '{}')::DATE;
        ELSE RETURN FALSE;
      END CASE;
    WHEN 'timestamp' THEN
      CASE v_operator
        WHEN 'equals' THEN RETURN (v_var.variable_value #>> '{}')::TIMESTAMPTZ = (v_value #>> '{}')::TIMESTAMPTZ;
        WHEN 'not_equals' THEN RETURN (v_var.variable_value #>> '{}')::TIMESTAMPTZ <> (v_value #>> '{}')::TIMESTAMPTZ;
        WHEN 'greater_than' THEN RETURN (v_var.variable_value #>> '{}')::TIMESTAMPTZ > (v_value #>> '{}')::TIMESTAMPTZ;
        WHEN 'greater_than_or_equal' THEN RETURN (v_var.variable_value #>> '{}')::TIMESTAMPTZ >= (v_value #>> '{}')::TIMESTAMPTZ;
        WHEN 'less_than' THEN RETURN (v_var.variable_value #>> '{}')::TIMESTAMPTZ < (v_value #>> '{}')::TIMESTAMPTZ;
        WHEN 'less_than_or_equal' THEN RETURN (v_var.variable_value #>> '{}')::TIMESTAMPTZ <= (v_value #>> '{}')::TIMESTAMPTZ;
        ELSE RETURN FALSE;
      END CASE;
    ELSE
      RETURN FALSE;
  END CASE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_evaluate_gateway_condition(UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- ── 2. workflow_resolve_gateway_target — deterministic branch
--    selection (ascending priority, first match wins, else the
--    mandatory default), shared by the real entry pass and the peek
--    pass so they can never disagree. Not granted to any role. ─────
CREATE OR REPLACE FUNCTION workflow_resolve_gateway_target(
  p_instance_id UUID,
  p_canonical JSONB,
  p_node_key TEXT
) RETURNS TABLE (
  target_node_key TEXT,
  target_node JSONB,
  used_default BOOLEAN,
  evaluated_conditions JSONB
) AS $$
DECLARE
  v_edge JSONB;
  v_default_edge JSONB;
  v_results JSONB := '[]'::JSONB;
  v_result BOOLEAN;
  v_target_key TEXT;
  v_target_node JSONB;
BEGIN
  FOR v_edge IN
    SELECT e FROM jsonb_array_elements(p_canonical -> 'edges') e
    WHERE e ->> 'source' = p_node_key AND (e -> 'default')::TEXT = 'false'
    ORDER BY (e ->> 'priority')::INT
  LOOP
    v_result := workflow_evaluate_gateway_condition(p_instance_id, v_edge -> 'condition');
    v_results := v_results || jsonb_build_object('priority', (v_edge ->> 'priority')::INT, 'matched', v_result);
    IF v_result THEN
      v_target_key := v_edge ->> 'target';
      SELECT n INTO v_target_node FROM jsonb_array_elements(p_canonical -> 'nodes') n WHERE n ->> 'key' = v_target_key;
      RETURN QUERY SELECT v_target_key, v_target_node, FALSE, v_results;
      RETURN;
    END IF;
  END LOOP;

  SELECT e INTO v_default_edge FROM jsonb_array_elements(p_canonical -> 'edges') e
  WHERE e ->> 'source' = p_node_key AND (e -> 'default')::TEXT = 'true';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No default edge found for gateway node %', p_node_key USING ERRCODE = '0A000';
  END IF;
  v_target_key := v_default_edge ->> 'target';
  SELECT n INTO v_target_node FROM jsonb_array_elements(p_canonical -> 'nodes') n WHERE n ->> 'key' = v_target_key;
  RETURN QUERY SELECT v_target_key, v_target_node, TRUE, v_results;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_resolve_gateway_target(UUID, JSONB, TEXT) FROM PUBLIC, anon, authenticated;

-- ── 3. workflow_peek_final_graph_target — extended with a
--    gateway_exclusive branch reusing workflow_resolve_gateway_target,
--    so a routing hop is correctly accounted for in the existing
--    replay-metadata discipline exactly as skip hops already are.
--    Signature unchanged. ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION workflow_peek_final_graph_target(
  p_canonical JSONB,
  p_instance_id UUID,
  p_home_organization_id UUID,
  p_created_by UUID,
  p_start_node_key TEXT,
  p_start_node JSONB
) RETURNS TABLE (
  final_node_key TEXT,
  final_node JSONB,
  final_type TEXT,
  final_status TEXT,
  final_outcome_code TEXT
) AS $$
DECLARE
  v_hops INTEGER := 0;
  v_node_key TEXT := p_start_node_key;
  v_node JSONB := p_start_node;
  v_type TEXT;
  v_config JSONB;
  v_candidates JSONB;
  v_electorate_count INTEGER;
  v_classification TEXT;
  v_edge JSONB;
BEGIN
  LOOP
    v_hops := v_hops + 1;
    IF v_hops > 32 THEN
      RAISE EXCEPTION 'Graph advancement exceeded the defensive maximum of 32 immediate node entries in one command'
        USING ERRCODE = '0A000';
    END IF;

    v_type := v_node ->> 'type';
    IF v_type NOT IN ('approval','end','gateway_exclusive') THEN
      RAISE EXCEPTION 'Unsupported graph node type: %', v_type USING ERRCODE = '0A000';
    END IF;

    IF v_type = 'end' THEN
      RETURN QUERY SELECT v_node_key, v_node, 'end'::TEXT, 'completed'::TEXT, v_node -> 'config' ->> 'outcome_code';
      RETURN;
    END IF;

    IF v_type = 'gateway_exclusive' THEN
      SELECT g.target_node_key, g.target_node INTO v_node_key, v_node
      FROM workflow_resolve_gateway_target(p_instance_id, p_canonical, v_node_key) g;
      CONTINUE;
    END IF;

    v_config := v_node -> 'config';
    v_candidates := workflow_resolve_approval_candidates(p_instance_id, p_home_organization_id, p_created_by, v_config);
    v_electorate_count := COALESCE(jsonb_array_length(v_candidates), 0);
    v_classification := workflow_classify_approval_electorate(
      v_config ->> 'requirement', v_electorate_count, (v_config ->> 'minimum_candidates')::INT
    );

    IF v_classification = 'insufficient' THEN
      RAISE EXCEPTION 'Resolved candidate count % does not satisfy node % configuration', v_electorate_count, v_node_key
        USING ERRCODE = '55000';
    END IF;

    IF v_classification = 'skip' THEN
      SELECT e INTO v_edge FROM jsonb_array_elements(p_canonical -> 'edges') e
      WHERE e ->> 'source' = v_node_key AND e ->> 'outcome' = 'skipped';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'No skipped edge found for optional node %', v_node_key USING ERRCODE = '0A000';
      END IF;
      v_node_key := v_edge ->> 'target';
      SELECT n INTO v_node FROM jsonb_array_elements(p_canonical -> 'nodes') n WHERE n ->> 'key' = v_node_key;
      CONTINUE;
    END IF;

    RETURN QUERY SELECT v_node_key, v_node, 'approval'::TEXT, 'active'::TEXT, NULL::TEXT;
    RETURN;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 4. workflow_enter_downstream_node — extended with a
--    gateway_exclusive branch, structurally identical in shape to
--    the existing skip branch: evaluate, emit route_selected, close
--    this node's own step, CONTINUE into the selected target.
--    Signature unchanged (still 14 args). ───────────────────────────
CREATE OR REPLACE FUNCTION workflow_enter_downstream_node(
  p_instance_id UUID,
  p_actor UUID,
  p_correlation_id UUID,
  p_home_organization_id UUID,
  p_created_by UUID,
  p_execution_epoch INTEGER,
  p_root_event_id UUID,
  p_seq BIGINT,
  p_result_lock_version BIGINT,
  p_token_id UUID,
  p_from_node_key TEXT,
  p_target_node_key TEXT,
  p_target_node JSONB,
  p_canonical JSONB
) RETURNS TABLE (
  final_status TEXT,
  final_outcome TEXT,
  next_event_sequence BIGINT,
  target_step_id UUID
) AS $$
DECLARE
  v_now TIMESTAMPTZ := clock_timestamp();
  v_seq BIGINT := p_seq;
  v_hops INTEGER := 0;
  v_from_key TEXT := p_from_node_key;
  v_target_key TEXT := p_target_node_key;
  v_target_node JSONB := p_target_node;
  v_target_type TEXT;
  v_target_step_id UUID;
  v_target_outcome_code TEXT;
  v_edge JSONB;
  v_loop_final_type TEXT;
  v_loop_outcome_code TEXT;

  -- Gateway-node entry working state.
  v_gw_node_key TEXT;
  v_gw_used_default BOOLEAN;
  v_gw_evaluated JSONB;

  -- Approval-node entry working state.
  v_config JSONB;
  v_requirement TEXT;
  v_delivery_mode TEXT;
  v_decision_rule TEXT;
  v_minimum_candidates INTEGER;
  v_minimum_approvals INTEGER;
  v_reject_behavior TEXT;
  v_allow_abstain BOOLEAN;
  v_comment_policy JSONB;
  v_candidates JSONB;
  v_electorate_count INTEGER;
  v_classification TEXT;
  v_threshold INTEGER;
  v_round_id UUID;
  v_pos RECORD;
  v_work_item_id UUID;
BEGIN
  LOOP
    v_hops := v_hops + 1;
    IF v_hops > 32 THEN
      RAISE EXCEPTION 'Graph advancement exceeded the defensive maximum of 32 immediate node entries in one command'
        USING ERRCODE = '0A000';
    END IF;

    -- Version-2 node universe is start/approval/end/gateway_exclusive.
    -- 'start' can never be a legal downstream target (zero inbound
    -- edges is enforced at publication) — unreachable through the
    -- public surface, verified by inspection, rejected here purely as
    -- defense-in-depth.
    v_target_type := v_target_node ->> 'type';
    IF v_target_type NOT IN ('approval','end','gateway_exclusive') THEN
      RAISE EXCEPTION 'Unsupported graph node type: %', v_target_type
        USING ERRCODE = '0A000';
    END IF;

    INSERT INTO workflow_instance_steps (instance_id, definition_node_key, run_number, state, activated_at)
    VALUES (p_instance_id, v_target_key,
      (SELECT COALESCE(MAX(s.run_number),0)+1 FROM workflow_instance_steps s
         WHERE s.instance_id = p_instance_id AND s.definition_node_key = v_target_key),
      CASE WHEN v_target_type = 'end' THEN 'completed' ELSE 'waiting' END, v_now)
    RETURNING id INTO v_target_step_id;

    UPDATE workflow_tokens SET step_id = v_target_step_id WHERE id = p_token_id;

    -- token_moved
    INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
    VALUES (p_instance_id, v_seq, 'token_moved', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
      jsonb_build_object('token_id',p_token_id,'from_node_key',v_from_key,'to_node_key',v_target_key));
    v_seq := v_seq + 1;
    -- step_entered (target)
    INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
    VALUES (p_instance_id, v_seq, 'step_entered', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
      jsonb_build_object('node_key',v_target_key,'node_type',v_target_type));
    v_seq := v_seq + 1;

    IF v_target_type = 'end' THEN
      -- Explicit, bounded docs/63 special case: reaching End with no
      -- further active token/step/round/work item consumes the token
      -- and completes the instance.
      v_target_outcome_code := v_target_node -> 'config' ->> 'outcome_code';

      UPDATE workflow_instance_steps SET state = 'completed', result_code = v_target_outcome_code, ended_at = v_now
      WHERE id = v_target_step_id;
      UPDATE workflow_tokens SET state = 'consumed', consumed_at = v_now WHERE id = p_token_id;

      -- step_completed (end)
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'step_completed', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_target_key,'result_code',v_target_outcome_code));
      v_seq := v_seq + 1;
      -- instance_completed
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'instance_completed', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
        jsonb_build_object('previous_status','active','new_status','completed','terminal_outcome',v_target_outcome_code));
      v_seq := v_seq + 1;

      v_loop_final_type := 'end';
      v_loop_outcome_code := v_target_outcome_code;
      EXIT;
    END IF;

    IF v_target_type = 'gateway_exclusive' THEN
      -- Synchronous, no-human-decision node — the same "evaluate,
      -- close this step, CONTINUE" shape the skip branch already
      -- established, generalized to a second case.
      v_gw_node_key := v_target_key;

      SELECT g.target_node_key, g.target_node, g.used_default, g.evaluated_conditions
      INTO v_target_key, v_target_node, v_gw_used_default, v_gw_evaluated
      FROM workflow_resolve_gateway_target(p_instance_id, p_canonical, v_gw_node_key) g;

      UPDATE workflow_instance_steps SET state = 'completed', result_code = 'routed', ended_at = v_now
      WHERE id = v_target_step_id;

      -- route_selected — the gateway's own step-closing event,
      -- occupying the same structural position step_skipped already
      -- occupies for the skip branch (one dedicated closing event,
      -- not a redundant generic step_completed alongside it).
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'route_selected', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
        jsonb_build_object(
          'node_key', v_gw_node_key, 'target_node_key', v_target_key,
          'used_default', v_gw_used_default, 'evaluated_conditions', v_gw_evaluated
        ));
      v_seq := v_seq + 1;

      v_from_key := v_gw_node_key;
      CONTINUE;
    END IF;

    -- approval — resolve candidates and either open a real round
    -- (stop, waiting) or skip a zero-candidate optional node
    -- (continue synchronously to its 'skipped' edge).
    v_config := v_target_node -> 'config';
    v_requirement := v_config ->> 'requirement';
    v_delivery_mode := v_config ->> 'delivery_mode';
    v_decision_rule := v_config ->> 'decision_rule';
    v_minimum_candidates := (v_config ->> 'minimum_candidates')::INT;
    v_minimum_approvals := NULLIF(v_config ->> 'minimum_approvals', '')::INT;
    v_reject_behavior := v_config ->> 'reject_behavior';
    v_allow_abstain := (v_config ->> 'allow_abstain')::BOOLEAN;
    v_comment_policy := v_config -> 'comment_policy';

    v_candidates := workflow_resolve_approval_candidates(p_instance_id, p_home_organization_id, p_created_by, v_config);
    v_electorate_count := COALESCE(jsonb_array_length(v_candidates), 0);
    v_classification := workflow_classify_approval_electorate(v_requirement, v_electorate_count, v_minimum_candidates);

    IF v_classification = 'insufficient' THEN
      RAISE EXCEPTION 'Resolved candidate count % does not satisfy node % configuration', v_electorate_count, v_target_key
        USING ERRCODE = '55000';
    END IF;

    IF v_classification = 'skip' THEN
      -- docs/63: "Zero resolved positions creates a skipped round/
      -- step history, creates no work item, emits the skip events,
      -- and follows skipped." approval_threshold is explicitly zero
      -- only for this case (docs/63's own persisted-field contract).
      INSERT INTO workflow_approval_rounds (
        instance_id, step_id, token_id, execution_epoch, delivery_mode, decision_rule, requirement,
        optional_policy, minimum_candidates, electorate_count, approval_threshold, reject_behavior,
        allow_abstain, comment_policy, state, outcome_code, opened_by, causation_event_id, opened_at, completed_at
      ) VALUES (
        p_instance_id, v_target_step_id, p_token_id, p_execution_epoch, v_delivery_mode, v_decision_rule, v_requirement,
        v_config ->> 'optional_policy', v_minimum_candidates, 0, 0, v_reject_behavior,
        v_allow_abstain, v_comment_policy, 'completed', 'skipped', p_actor, p_root_event_id, v_now, v_now
      ) RETURNING id INTO v_round_id;

      -- approval_round_opened
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'approval_round_opened', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
        jsonb_build_object('round_id',v_round_id,'electorate_count',0,'approval_threshold',0,
          'delivery_mode',v_delivery_mode,'decision_rule',v_decision_rule));
      v_seq := v_seq + 1;
      -- approval_round_completed
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'approval_round_completed', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
        jsonb_build_object('round_id',v_round_id,'outcome_code','skipped','electorate_count',0,
          'approved_count',0,'rejected_count',0,'abstained_count',0));
      v_seq := v_seq + 1;

      UPDATE workflow_instance_steps SET state = 'completed', result_code = 'skipped', ended_at = v_now
      WHERE id = v_target_step_id;
      -- step_skipped (distinct from step_completed, per docs/63's
      -- event contract minimum graph-event vocabulary)
      INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
      VALUES (p_instance_id, v_seq, 'step_skipped', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
        jsonb_build_object('node_key',v_target_key,'result_code','skipped'));
      v_seq := v_seq + 1;

      SELECT e INTO v_edge FROM jsonb_array_elements(p_canonical -> 'edges') e
      WHERE e ->> 'source' = v_target_key AND e ->> 'outcome' = 'skipped';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'No skipped edge found for optional node %', v_target_key USING ERRCODE = '0A000';
      END IF;
      v_from_key := v_target_key;
      v_target_key := v_edge ->> 'target';
      SELECT n INTO v_target_node FROM jsonb_array_elements(p_canonical -> 'nodes') n WHERE n ->> 'key' = v_target_key;
      CONTINUE;
    END IF;

    -- proceed — a genuine round with 1+ candidates. Identical
    -- mechanics to Phase 2B.2/2C.1's original single-entry logic.
    v_threshold := CASE
      WHEN v_decision_rule = 'unanimous' THEN v_electorate_count
      ELSE GREATEST(FLOOR(v_electorate_count / 2.0)::INT + 1, COALESCE(v_minimum_approvals, 0))
    END;

    INSERT INTO workflow_approval_rounds (
      instance_id, step_id, token_id, execution_epoch, delivery_mode, decision_rule, requirement,
      optional_policy, minimum_candidates, electorate_count, approval_threshold, reject_behavior,
      allow_abstain, comment_policy, state, opened_by, causation_event_id, opened_at
    ) VALUES (
      p_instance_id, v_target_step_id, p_token_id, p_execution_epoch, v_delivery_mode, v_decision_rule, v_requirement,
      v_config ->> 'optional_policy', v_minimum_candidates, v_electorate_count, v_threshold, v_reject_behavior,
      v_allow_abstain, v_comment_policy, 'open', p_actor, p_root_event_id, v_now
    ) RETURNING id INTO v_round_id;
    -- approval_round_opened
    INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, causation_id, idempotency_key, metadata)
    VALUES (p_instance_id, v_seq, 'approval_round_opened', p_actor, v_target_step_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
      jsonb_build_object('round_id',v_round_id,'electorate_count',v_electorate_count,'approval_threshold',v_threshold,
        'delivery_mode',v_delivery_mode,'decision_rule',v_decision_rule));
    v_seq := v_seq + 1;

    FOR v_pos IN SELECT * FROM jsonb_to_recordset(v_candidates) AS x(user_id UUID, authority_source TEXT, selector_key TEXT, ordinal INT)
      ORDER BY ordinal
    LOOP
      IF v_delivery_mode = 'parallel' OR v_pos.ordinal = 1 THEN
        INSERT INTO workflow_work_items (
          instance_id, step_id, token_id, work_item_type, state, organization_id, assigned_to, offered_at
        ) VALUES (
          p_instance_id, v_target_step_id, p_token_id, 'approval', 'offered',
          p_home_organization_id, v_pos.user_id, v_now
        ) RETURNING id INTO v_work_item_id;

        INSERT INTO workflow_approval_positions (
          instance_id, round_id, step_id, position_key, ordinal, user_id, authority_source,
          organization_id, selector_key, state, work_item_id, offered_at
        ) VALUES (
          p_instance_id, v_round_id, v_target_step_id, 'position_' || v_pos.ordinal, v_pos.ordinal, v_pos.user_id, v_pos.authority_source,
          p_home_organization_id, v_pos.selector_key, 'offered', v_work_item_id, v_now
        );

        INSERT INTO workflow_participants (instance_id, work_item_id, user_id, participant_role, authority_source, created_by)
        VALUES (p_instance_id, v_work_item_id, v_pos.user_id, 'candidate', v_pos.authority_source, p_actor);

        -- work_item_created
        INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, work_item_id, correlation_id, causation_id, idempotency_key, metadata)
        VALUES (p_instance_id, v_seq, 'work_item_created', p_actor, v_target_step_id, v_work_item_id, p_correlation_id, p_root_event_id, gen_random_uuid(),
          jsonb_build_object('round_id',v_round_id,'ordinal',v_pos.ordinal));
        v_seq := v_seq + 1;
      ELSE
        INSERT INTO workflow_approval_positions (
          instance_id, round_id, step_id, position_key, ordinal, user_id, authority_source,
          organization_id, selector_key, state
        ) VALUES (
          p_instance_id, v_round_id, v_target_step_id, 'position_' || v_pos.ordinal, v_pos.ordinal, v_pos.user_id, v_pos.authority_source,
          p_home_organization_id, v_pos.selector_key, 'pending'
        );

        INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
        VALUES (p_instance_id, v_pos.user_id, 'candidate', v_pos.authority_source, p_actor);
      END IF;
    END LOOP;

    v_loop_final_type := 'approval_wait';
    EXIT;
  END LOOP;

  -- Single, final instance UPDATE — happens exactly once, after the
  -- loop concludes, using the actual v_seq every real event insert
  -- above already advanced (never a pre-computed formula). This
  -- structurally cannot suffer the class of arithmetic-sequencing
  -- bug Phase 2B.2A had to fix, whether the loop took one hop or
  -- several.
  IF v_loop_final_type = 'end' THEN
    UPDATE workflow_instances
    SET status = 'completed', terminal_outcome = v_loop_outcome_code,
        started_at = COALESCE(started_at, v_now), ended_at = v_now,
        lock_version = p_result_lock_version, next_event_sequence = v_seq
    WHERE id = p_instance_id;
    RETURN QUERY SELECT 'completed'::TEXT, v_loop_outcome_code, v_seq, v_target_step_id;
  ELSE
    UPDATE workflow_instances
    SET status = 'active', started_at = COALESCE(started_at, v_now),
        lock_version = p_result_lock_version, next_event_sequence = v_seq
    WHERE id = p_instance_id;
    RETURN QUERY SELECT 'active'::TEXT, NULL::TEXT, v_seq, v_target_step_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 5. workflow_transition_instance — the only change is widening
--    the 'start' command's own immediate-target-type guard from
--    ('approval','end') to ('approval','end','gateway_exclusive'),
--    since the graph's very first node can itself be a gateway.
--    Every other line is byte-for-byte unchanged. ──────────────────
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
  v_token_id UUID;
  v_seq BIGINT;
  v_root_event_id UUID;
  v_peek_status TEXT;
  v_peek_outcome TEXT;
  v_enter_status TEXT;
  v_enter_outcome TEXT;
  v_enter_next_seq BIGINT;
  v_enter_step_id UUID;
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

  IF p_command = 'start' THEN
    SELECT * INTO v_version FROM workflow_definition_versions WHERE id = v_instance.definition_version_id;
    v_is_executable := FOUND AND (v_version.definition_payload ? 'schema_version');
  END IF;

  IF v_is_executable THEN
    SELECT * INTO v_definition FROM workflow_definitions WHERE id = v_version.definition_id;

    IF v_version.status <> 'published' THEN
      RAISE EXCEPTION 'Workflow definition version is not published' USING ERRCODE = '55000';
    END IF;

    v_canonical := canonicalize_workflow_definition_payload(v_version.definition_payload, v_definition.organization_id);
    IF v_canonical <> v_version.definition_payload
       OR encode(digest(convert_to(v_canonical::TEXT, 'UTF8'), 'sha256'), 'hex') <> v_version.content_hash THEN
      RAISE EXCEPTION 'Workflow definition version failed publication integrity re-verification' USING ERRCODE = '0A000';
    END IF;

    v_entry_node_key := v_canonical ->> 'entry_node';

    SELECT e INTO v_edge
    FROM jsonb_array_elements(v_canonical -> 'edges') e
    WHERE e ->> 'source' = v_entry_node_key AND e ->> 'outcome' = 'started';
    v_target_node_key := v_edge ->> 'target';

    SELECT n INTO v_target_node
    FROM jsonb_array_elements(v_canonical -> 'nodes') n
    WHERE n ->> 'key' = v_target_node_key;
    v_target_type := v_target_node ->> 'type';

    IF v_target_type NOT IN ('approval','end','gateway_exclusive') THEN
      RAISE EXCEPTION 'Unsupported first executable node type: %', v_target_type USING ERRCODE = '0A000';
    END IF;

    v_result_lock_version := v_instance.lock_version + 1;
    v_seq := v_instance.next_event_sequence;

    -- 1. Start step: entered and completed atomically.
    INSERT INTO workflow_instance_steps (instance_id, definition_node_key, run_number, state, result_code, activated_at, ended_at)
    VALUES (p_instance_id, v_entry_node_key, 1, 'completed', 'started', v_now, v_now)
    RETURNING id INTO v_start_step_id;

    -- 2. One initial token, created at the Start step, then moved by
    --    the shared downstream-entry helper below.
    INSERT INTO workflow_tokens (instance_id, step_id, token_key, state)
    VALUES (p_instance_id, v_start_step_id, 'epoch_' || v_instance.execution_epoch || '_token_1', 'active')
    RETURNING id INTO v_token_id;

    -- Peek through any zero-candidate-optional skip chain beyond the
    -- first executable node, so instance_started's own metadata
    -- carries the TRUE final new_status/terminal_outcome — this
    -- event is append-only and the shared replay path reads these
    -- exact fields back from it on retry.
    SELECT peek.final_status, peek.final_outcome_code
    INTO v_peek_status, v_peek_outcome
    FROM workflow_peek_final_graph_target(
      v_canonical, p_instance_id, v_instance.home_organization_id, v_instance.created_by,
      v_target_node_key, v_target_node
    ) peek;

    INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, idempotency_key, metadata)
    VALUES (p_instance_id, v_seq, 'instance_started', v_actor, v_start_step_id, v_instance.correlation_id, p_idempotency_key,
      jsonb_build_object('command','start','previous_status',v_instance.status,
        'new_status', v_peek_status,
        'expected_lock_version',p_expected_lock_version,'result_lock_version',v_result_lock_version,
        'terminal_outcome',v_peek_outcome,
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

    -- 3. Enter the first executable node via the shared helper.
    SELECT ed.final_status, ed.final_outcome, ed.next_event_sequence, ed.target_step_id
    INTO v_enter_status, v_enter_outcome, v_enter_next_seq, v_enter_step_id
    FROM workflow_enter_downstream_node(
      p_instance_id, v_actor, v_instance.correlation_id, v_instance.home_organization_id,
      v_instance.created_by, v_instance.execution_epoch, v_root_event_id, v_seq+4,
      v_result_lock_version, v_token_id, v_entry_node_key, v_target_node_key, v_target_node, v_canonical
    ) ed;

    RETURN QUERY SELECT p_instance_id, v_enter_status, v_enter_outcome, v_result_lock_version, v_root_event_id, v_seq, FALSE;
    RETURN;
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

-- ── 6. workflow_advance_graph_step — the only change is widening its
--    own immediate-target-type guard the same way. Every other line
--    is byte-for-byte unchanged. ────────────────────────────────────
CREATE OR REPLACE FUNCTION workflow_advance_graph_step(
  p_instance_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
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
  v_version workflow_definition_versions;
  v_definition workflow_definitions;
  v_canonical JSONB;
  v_token workflow_tokens;
  v_source_step workflow_instance_steps;
  v_edge JSONB;
  v_target_node_key TEXT;
  v_target_node JSONB;
  v_target_type TEXT;
  v_result_lock_version BIGINT;
  v_seq BIGINT;
  v_root_event_id UUID;
  v_final_status TEXT;
  v_final_outcome TEXT;
  v_enter_status TEXT;
  v_enter_outcome TEXT;
  v_enter_next_seq BIGINT;
  v_enter_step_id UUID;
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

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'workflow_advance:' || v_actor::TEXT || ':' || p_instance_id::TEXT || ':' ||
      p_idempotency_key::TEXT,
      0
    )
  );

  SELECT * INTO v_instance FROM workflow_instances WHERE id = p_instance_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow instance is not available for this action'
      USING ERRCODE = '42501';
  END IF;

  SELECT e.* INTO v_existing_event
  FROM workflow_events e
  WHERE e.instance_id = p_instance_id AND e.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_event.actor_id IS DISTINCT FROM v_actor
       OR v_existing_event.event_type <> 'step_completed'
       OR (v_existing_event.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
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

  IF v_instance.status <> 'active' THEN
    RAISE EXCEPTION 'Graph advancement requires an active instance'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_version FROM workflow_definition_versions WHERE id = v_instance.definition_version_id;
  IF NOT FOUND OR NOT (v_version.definition_payload ? 'schema_version') THEN
    RAISE EXCEPTION 'Graph advancement requires an executable-v1 instance'
      USING ERRCODE = '0A000';
  END IF;
  SELECT * INTO v_definition FROM workflow_definitions WHERE id = v_version.definition_id;
  v_canonical := canonicalize_workflow_definition_payload(v_version.definition_payload, v_definition.organization_id);
  IF v_canonical <> v_version.definition_payload
     OR encode(digest(convert_to(v_canonical::TEXT, 'UTF8'), 'sha256'), 'hex') <> v_version.content_hash THEN
    RAISE EXCEPTION 'Workflow definition version failed publication integrity re-verification'
      USING ERRCODE = '0A000';
  END IF;

  SELECT * INTO v_token FROM workflow_tokens t
  WHERE t.instance_id = p_instance_id AND t.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active token to advance'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_source_step FROM workflow_instance_steps
  WHERE id = v_token.step_id FOR UPDATE;
  IF NOT FOUND OR v_source_step.state <> 'completed' OR v_source_step.result_code IS NULL THEN
    RAISE EXCEPTION 'Current step does not have exactly one terminal result'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_token FROM workflow_tokens WHERE id = v_token.id FOR UPDATE;

  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_canonical -> 'nodes') n
    WHERE n ->> 'key' = v_source_step.definition_node_key
  ) THEN
    RAISE EXCEPTION 'Current step node no longer exists in the pinned definition'
      USING ERRCODE = '0A000';
  END IF;

  SELECT e INTO v_edge FROM jsonb_array_elements(v_canonical -> 'edges') e
  WHERE e ->> 'source' = v_source_step.definition_node_key AND e ->> 'outcome' = v_source_step.result_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No outgoing edge matches the current step result'
      USING ERRCODE = '0A000';
  END IF;
  v_target_node_key := v_edge ->> 'target';

  SELECT n INTO v_target_node FROM jsonb_array_elements(v_canonical -> 'nodes') n
  WHERE n ->> 'key' = v_target_node_key;
  v_target_type := v_target_node ->> 'type';

  IF v_target_type NOT IN ('approval','end','gateway_exclusive') THEN
    RAISE EXCEPTION 'Unsupported graph-advancement target node type: %', v_target_type
      USING ERRCODE = '0A000';
  END IF;

  v_result_lock_version := v_instance.lock_version + 1;
  v_seq := v_instance.next_event_sequence;

  -- Peek through any zero-candidate-optional skip chain beyond the
  -- immediate target so this command's own root event carries the
  -- TRUE final new_status/terminal_outcome at insert time.
  SELECT peek.final_status, peek.final_outcome_code
  INTO v_final_status, v_final_outcome
  FROM workflow_peek_final_graph_target(
    v_canonical, p_instance_id, v_instance.home_organization_id, v_instance.created_by,
    v_target_node_key, v_target_node
  ) peek;

  -- step_completed (source) — this command's root/canonical event.
  INSERT INTO workflow_events (instance_id, event_sequence, event_type, actor_id, step_id, correlation_id, idempotency_key, metadata)
  VALUES (p_instance_id, v_seq, 'step_completed', v_actor, v_source_step.id, v_instance.correlation_id, p_idempotency_key,
    jsonb_build_object('node_key', v_source_step.definition_node_key, 'result_code', v_source_step.result_code,
      'expected_lock_version', p_expected_lock_version, 'result_lock_version', v_result_lock_version,
      'new_status', v_final_status, 'terminal_outcome', v_final_outcome))
  RETURNING id INTO v_root_event_id;

  SELECT ed.final_status, ed.final_outcome, ed.next_event_sequence, ed.target_step_id
  INTO v_enter_status, v_enter_outcome, v_enter_next_seq, v_enter_step_id
  FROM workflow_enter_downstream_node(
    p_instance_id, v_actor, v_instance.correlation_id, v_instance.home_organization_id,
    v_instance.created_by, v_instance.execution_epoch, v_root_event_id, v_seq+1,
    v_result_lock_version, v_token.id, v_source_step.definition_node_key, v_target_node_key, v_target_node, v_canonical
  ) ed;

  RETURN QUERY SELECT p_instance_id, v_enter_status, v_enter_outcome, v_result_lock_version, v_root_event_id, v_seq, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 7. Grants ────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION workflow_peek_final_graph_target(JSONB,UUID,UUID,UUID,TEXT,JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION workflow_enter_downstream_node(UUID,UUID,UUID,UUID,UUID,INTEGER,UUID,BIGINT,BIGINT,UUID,TEXT,TEXT,JSONB,JSONB) FROM PUBLIC, anon, authenticated;

-- Signatures of workflow_transition_instance/workflow_advance_graph_step
-- are unchanged, so existing grants remain in effect without a
-- REGRANT — CREATE OR REPLACE FUNCTION preserves prior grants for an
-- identical signature. decide_workflow_work_item is untouched by this
-- patch entirely.

COMMIT;
