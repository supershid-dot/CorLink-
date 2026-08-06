-- ============================================================
-- CAP-002 Phase 3.2: Approval Round Lifecycle
--
-- Completes the generic approval-round lifecycle docs/63 defines on
-- top of the inert Phase 1 foundation, the Phase 2 runtime lifecycle,
-- the Phase 2B.1 executable definition validator, the Phase 2B.2
-- instance activation checkpoint, the Phase 2B.2A event-sequencing
-- correction, the Phase 2C.1 graph advancement foundation, and the
-- Phase 3.1 approval decision engine.
--
-- Closes one explicitly documented gap: docs/63's "Optional
-- approval" section requires that a zero-candidate OPTIONAL Approval
-- node be skipped (immutable skipped round/step history, no work
-- item, follow the 'skipped' edge, continue advancing) rather than
-- fail closed. Phase 2C.1 deliberately deferred this ("skip-and-
-- advance requires a future graph-advancement extension, not
-- implemented in Phase 2C.1" — a second graph-advancement hop within
-- one command, which its bounded single-hop-per-command design did
-- not perform). This migration is that extension: the shared
-- workflow_enter_downstream_node() helper becomes a bounded
-- (defensive maximum 32 hops, per docs/63's generic graph-advancement
-- contract) synchronous loop that continues through any zero-
-- candidate optional skip exactly like it already continues through
-- immediate start/end behavior, stopping only when a real approval
-- round waits or the instance completes.
--
-- Because the shared helper's signature changes (it now needs the
-- full canonical definition payload to resolve a 'skipped' edge
-- itself, and its callers must know the TRUE final status/outcome —
-- which a skip chain can move past the immediately-resolved target —
-- before inserting their own root event, since workflow_events is
-- append-only), this migration also re-declares, via CREATE OR
-- REPLACE, the three existing callers: workflow_transition_instance
-- and workflow_advance_graph_step (Phase 2C.1), and
-- decide_workflow_work_item (Phase 3.1). Their own command logic is
-- otherwise unchanged; only the pre-existing single-hop status/
-- outcome guess is replaced with a call to a new, pure,
-- non-mutating peek helper (workflow_peek_final_graph_target) that
-- resolves the same skip chain the real entry pass will take, so
-- root-event metadata is always correct at insert time — the exact
-- discipline Phase 2B.2A/3.1 already established elsewhere.
--
-- Also adds: a manager-gated, identity-free "blocked/unavailable
-- voter count" read function (docs/63's "Candidate unavailability
-- after snapshot"); and database-enforced immutability triggers on
-- workflow_approval_rounds/workflow_approval_positions rejecting any
-- further mutation once a row has reached a terminal state (docs/63's
-- "immutable round completion"/"immutable round history"), matching
-- the same "database-enforced, not only private-function checks"
-- philosophy Phase 3.1 already applied to the composite instance_id
-- invariant.
--
-- No new decision model, no routing, no gateways, no conditional
-- branching beyond the single structurally-guaranteed edge per
-- outcome (unchanged from Phase 2C.1/3.1's precedent), no timers, no
-- notifications, no delegation, no escalation, no module adapters,
-- no frontend.
-- ============================================================

BEGIN;

-- ── 1. Immutability guards for round/position terminal states.
--    Rounds and positions are mutated in place throughout their
--    normal lifecycle (unlike workflow_decisions/workflow_events,
--    which are insert-once), so a blanket append-only trigger does
--    not fit; instead, any further UPDATE once a row's OLD state is
--    already terminal is rejected, and DELETE is always rejected.
--    The one-time transition INTO a terminal state (OLD.state is
--    still 'open'/'pending'/'offered') remains unaffected. ─────────
CREATE OR REPLACE FUNCTION workflow_reject_terminal_round_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Workflow approval round history is immutable and cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF OLD.state IN ('completed','cancelled','failed') THEN
    RAISE EXCEPTION 'Workflow approval round % has already reached a terminal state and cannot be modified', OLD.id
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_approval_rounds_immutable_after_terminal ON workflow_approval_rounds;
CREATE TRIGGER workflow_approval_rounds_immutable_after_terminal
  BEFORE UPDATE OR DELETE ON workflow_approval_rounds
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_terminal_round_mutation();

CREATE OR REPLACE FUNCTION workflow_reject_terminal_position_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Workflow approval position history is immutable and cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF OLD.state IN ('decided','cancelled','unavailable') THEN
    RAISE EXCEPTION 'Workflow approval position % has already reached a terminal state and cannot be modified', OLD.id
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_approval_positions_immutable_after_terminal ON workflow_approval_positions;
CREATE TRIGGER workflow_approval_positions_immutable_after_terminal
  BEFORE UPDATE OR DELETE ON workflow_approval_positions
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_terminal_position_mutation();

-- ── 2. workflow_resolve_approval_candidates — the candidate-
--    resolution query extracted verbatim (parameterized, not
--    rewritten) from Phase 2C.1's inline logic, so it can be reused
--    both by the real downstream-entry pass and by the new
--    non-mutating peek pass without maintaining two independently-
--    drifting copies of the selector/dedup/ordering logic. Pure
--    read: no INSERT/UPDATE, safe to call speculatively. ──────────
CREATE OR REPLACE FUNCTION workflow_resolve_approval_candidates(
  p_instance_id UUID,
  p_home_organization_id UUID,
  p_created_by UUID,
  p_config JSONB
) RETURNS JSONB AS $$
DECLARE
  v_allow_self_approval BOOLEAN := (p_config ->> 'allow_self_approval')::BOOLEAN;
  v_allow_multi_capacity BOOLEAN := (p_config ->> 'allow_multi_capacity')::BOOLEAN;
  v_candidates JSONB;
BEGIN
  WITH selectors AS (
    SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
    FROM jsonb_array_elements(p_config -> 'candidate_selectors') s
  ),
  resolved AS (
    SELECT sel.selector_key, sel.sel_order, u.id AS user_id,
           'explicit_user:' || sel.selector_key AS authority_source
    FROM selectors sel
    JOIN LATERAL jsonb_array_elements_text(sel.s -> 'user_ids') AS uid(v) ON TRUE
    JOIN users u ON u.id = uid.v::UUID AND u.is_active AND u.org_id = p_home_organization_id
    WHERE sel.sel_type = 'explicit_user'

    UNION ALL

    SELECT sel.selector_key, sel.sel_order, ua.user_id,
           'organization_role:' || (sel.s ->> 'role') AS authority_source
    FROM selectors sel
    JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
      AND scope_org_id(ua.scope_type, ua.scope_id) = p_home_organization_id
    JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
    WHERE sel.sel_type = 'organization_role'

    UNION ALL

    SELECT sel.selector_key, sel.sel_order, ua.user_id,
           'section_role:' || (sel.s ->> 'role') AS authority_source
    FROM selectors sel
    JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
      AND (sel.s ->> 'section_id')::UUID IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
    JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
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
    WHERE v_allow_self_approval OR user_id <> p_created_by
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
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN LATERAL jsonb_array_elements_text(sel.s -> 'user_ids') AS uid(v) ON sel.sel_type = 'explicit_user'
        JOIN users u ON u.id = uid.v::UUID AND u.is_active AND u.org_id = p_home_organization_id
        UNION ALL
        SELECT sel.selector_key, sel.sel_order, ua.user_id
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
          AND scope_org_id(ua.scope_type, ua.scope_id) = p_home_organization_id AND sel.sel_type = 'organization_role'
        JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
        UNION ALL
        SELECT sel.selector_key, sel.sel_order, ua.user_id
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
          AND (sel.s ->> 'section_id')::UUID IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id)) AND sel.sel_type = 'section_role'
        JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
        UNION ALL
        SELECT sel.selector_key, sel.sel_order, p.user_id
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN workflow_participants p ON p.instance_id = p_instance_id AND p.participant_role = (sel.s ->> 'participant_role')
          AND p.ended_at IS NULL AND sel.sel_type = 'instance_participant_role'
        JOIN users u ON u.id = p.user_id AND u.is_active
      ) x
      WHERE v_allow_self_approval OR user_id <> p_created_by
      GROUP BY user_id HAVING count(*) > 1
    ) dup
  ) THEN
    RAISE EXCEPTION 'Candidate resolution found a duplicate user across selectors and allow_multi_capacity is false' USING ERRCODE = '55000';
  END IF;

  RETURN v_candidates;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_resolve_approval_candidates(UUID,UUID,UUID,JSONB) FROM PUBLIC, anon, authenticated;

-- ── 3. workflow_classify_approval_electorate — the tiny branch
--    decision (insufficient / skip / proceed) extracted so the real
--    entry pass and the peek pass can never disagree on which
--    outcome a given electorate size produces. ─────────────────────
CREATE OR REPLACE FUNCTION workflow_classify_approval_electorate(
  p_requirement TEXT,
  p_electorate_count INTEGER,
  p_minimum_candidates INTEGER
) RETURNS TEXT AS $$
BEGIN
  IF p_requirement = 'required' AND p_electorate_count < p_minimum_candidates THEN
    RETURN 'insufficient';
  END IF;
  IF p_requirement = 'optional' AND p_electorate_count = 0 THEN
    RETURN 'skip';
  END IF;
  IF p_requirement = 'optional' AND p_electorate_count > 0 AND p_electorate_count < p_minimum_candidates THEN
    RETURN 'insufficient';
  END IF;
  RETURN 'proceed';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_classify_approval_electorate(TEXT,INTEGER,INTEGER) FROM PUBLIC, anon, authenticated;

-- ── 4. workflow_peek_final_graph_target — a pure, non-mutating walk
--    through any zero-candidate-optional skip chain (bounded 32 hops,
--    the same defensive maximum docs/63's generic graph-advancement
--    contract specifies), so a caller can learn the TRUE final
--    status/outcome BEFORE inserting its own root event. Required-
--    insufficient and duplicate-candidate errors surface here too —
--    identically to the real pass, since both call the same two
--    helpers above — which only fails a command earlier within the
--    same transaction, never differently. ──────────────────────────
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
    IF v_type NOT IN ('approval','end') THEN
      RAISE EXCEPTION 'Unsupported graph node type: %', v_type USING ERRCODE = '0A000';
    END IF;

    IF v_type = 'end' THEN
      RETURN QUERY SELECT v_node_key, v_node, 'end'::TEXT, 'completed'::TEXT, v_node -> 'config' ->> 'outcome_code';
      RETURN;
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
REVOKE ALL ON FUNCTION workflow_peek_final_graph_target(JSONB,UUID,UUID,UUID,TEXT,JSONB) FROM PUBLIC, anon, authenticated;

-- ── 5. workflow_enter_downstream_node — re-declared with a new
--    signature (adds p_canonical, needed to resolve a 'skipped' edge
--    itself) and a bounded synchronous loop in place of the old
--    single-entry body. The old 13-argument overload is dropped
--    first so exactly one signature exists — this remains the single
--    graph-advancement authority, not a second copy. Every existing
--    non-skip code path (End; Approval with a sufficient/nonzero
--    electorate) is unchanged in substance; the single instance
--    UPDATE that used to be duplicated per-branch with a pre-computed
--    next_event_sequence formula now happens exactly once, after the
--    loop, using the actual v_seq every real INSERT already advanced
--    — eliminating the entire class of arithmetic-formula bug Phase
--    2B.2A had to fix, not just avoiding a repeat of it. ───────────
DROP FUNCTION IF EXISTS workflow_enter_downstream_node(UUID,UUID,UUID,UUID,UUID,INTEGER,UUID,BIGINT,BIGINT,UUID,TEXT,TEXT,JSONB);

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

    -- Version-1 node universe is start/approval/end. 'start' can
    -- never be a legal downstream target (zero inbound edges is
    -- enforced at publication) — unreachable through the public
    -- surface, verified by inspection, rejected here purely as
    -- defense-in-depth.
    v_target_type := v_target_node ->> 'type';
    IF v_target_type NOT IN ('approval','end') THEN
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

REVOKE ALL ON FUNCTION workflow_enter_downstream_node(UUID,UUID,UUID,UUID,UUID,INTEGER,UUID,BIGINT,BIGINT,UUID,TEXT,TEXT,JSONB,JSONB) FROM PUBLIC, anon, authenticated;

-- ── 6. workflow_transition_instance — re-declared only to (a) peek
--    the true final status/outcome (which a downstream skip chain
--    can move past the first executable node) before inserting its
--    own root event, and (b) pass the canonical payload through to
--    the shared helper. Every other line of this function's command
--    logic — the 5-command CASE, advisory locking, idempotency
--    replay, the legacy Phase 2 path for non-'start' commands and
--    inert instances, cancellation's round/position closure — is
--    byte-for-byte unchanged from the approved Phase 2C.1 baseline. ─
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

    IF v_target_type NOT IN ('approval','end') THEN
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

-- Signature unchanged; existing grants (revoked from PUBLIC/anon/
-- authenticated, callable only via the five narrow wrapper RPCs)
-- remain in effect without a REGRANT.

-- ── 7. workflow_advance_graph_step — re-declared only to peek the
--    true final status/outcome before inserting its own root event
--    and to pass the canonical payload through to the shared helper.
--    Every other line is byte-for-byte unchanged from the approved
--    Phase 2C.1 baseline. ────────────────────────────────────────
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

  IF v_target_type NOT IN ('approval','end') THEN
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

REVOKE ALL ON FUNCTION workflow_advance_graph_step(UUID,BIGINT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION workflow_advance_graph_step(UUID,BIGINT,UUID) TO authenticated;

-- ── 8. decide_workflow_work_item — re-declared only to peek the
--    true final status/outcome (replacing the old single-hop
--    target_type ternary) before inserting its own root event, and
--    to pass the canonical payload through to the shared helper.
--    Every other line of decision recording, outcome calculation,
--    sequential/parallel progression, and round/work-item closure is
--    byte-for-byte unchanged from the approved Phase 3.1 baseline. ──
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

-- ── 9. get_workflow_approval_round_blocked_count — docs/63's
--    "Candidate unavailability after snapshot": the engine exposes a
--    safe blocked/unavailable count only to authorized workflow
--    managers, never identity details. Reuses can_manage_workflow_
--    instance() unchanged — no new permission model. Returns only an
--    integer count of currently-offered/pending positions whose
--    assigned user is no longer active; never selects or returns
--    user_id, email, or any other identity field. ──────────────────
CREATE OR REPLACE FUNCTION get_workflow_approval_round_blocked_count(p_round_id UUID)
RETURNS INTEGER AS $$
DECLARE
  v_instance_id UUID;
  v_count INTEGER;
BEGIN
  SELECT instance_id INTO v_instance_id FROM workflow_approval_rounds WHERE id = p_round_id;
  IF NOT FOUND OR NOT can_manage_workflow_instance(v_instance_id) THEN
    RAISE EXCEPTION 'Workflow approval round is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_count
  FROM workflow_approval_positions p
  JOIN users u ON u.id = p.user_id
  WHERE p.round_id = p_round_id AND p.state IN ('pending','offered') AND NOT u.is_active;

  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION get_workflow_approval_round_blocked_count(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_workflow_approval_round_blocked_count(UUID) TO authenticated;

COMMIT;
