-- ============================================================
-- CAP-002 Phase 5.2 — Live Delegation & Substitution Integration
--
-- Integrates the approved Phase 5.1 delegation/substitution
-- persistence foundation into the two existing seams docs/73
-- (self-authored, Phase 5.0) already designed for this purpose. No
-- new persistence model, no new delegation model, no new
-- substitution model — Phase 5.1's four tables and ten RPCs are
-- reused completely, unmodified.
--
--   1. SUBSTITUTION plugs into the candidate-resolution seam
--      (workflow_resolve_approval_candidates) — it changes WHO
--      resolves for a selector, never selector syntax, node
--      validation, or classify-skip-proceed logic.
--   2. DELEGATION plugs into the work-item-authorization seam
--      (decide_workflow_work_item's assigned_to check) — it changes
--      WHO MAY ACT on a work item already offered to a specific
--      person, never candidate resolution, round policy, or quorum.
--
-- Two new private helper functions carry the actual matching logic,
-- each called from every site that needs it rather than duplicated
-- inline, mirroring the existing scope_org_id/scope_section_ids
-- precedent (each already called from both the main resolution CTE
-- and the duplicate-check subquery in this same function):
--
--   workflow_resolve_effective_candidate() — given an originally-
--   resolved candidate (user, or role+scope), returns the
--   substitution-effective user to actually place in the electorate.
--   Priority: an active planned_leave naming the person directly
--   outranks an active acting_appointment for their role, since a
--   named substitution is more specific than a role-wide one.
--
--   workflow_resolve_active_delegation() — given a work item's
--   original assignee and the actor attempting to act, returns the
--   matching active delegation id (if any) authorizing the actor to
--   decide in the assignee's place, checked against all four
--   delegation scope types (work_item, definition_step,
--   organization_role, section_role).
--
-- Both helpers compute LIVE effectiveness — status IN
-- ('scheduled','active') AND now() within [starts_at, effective end)
-- — rather than trusting the stored status literal alone, because
-- Phase 5.1 deliberately built no activation/expiry worker to flip
-- 'scheduled' to 'active' when a window's start time arrives. The
-- stored status only needs to mean "non-terminal, already past
-- pending_acceptance/rejected/revoked/expired/cancelled"; whether it
-- is in effect RIGHT NOW is always re-derived from the window at
-- query time. See docs/75 for the full reasoning and the two
-- documented interpretations (work-item semantics, delegation
-- non-exclusivity) this milestone makes explicit.
--
-- workflow_approval_positions.section_id — already part of the
-- Phase 2B.2 table shape but never populated by any prior phase — is
-- now populated for section_role positions, purely as a byproduct of
-- the same candidate-resolution/work-item-assignment/approval-round-
-- creation seams this milestone is already allowed to touch. This is
-- what lets decide_workflow_work_item later match a section_role-
-- scoped delegation against the exact section a position was
-- resolved under, without parsing free text or adding a new column.
--
-- Traceability reuses existing fields, per this milestone's own "no
-- new event type" discipline: decision_recorded gains one new,
-- always-present-but-usually-null metadata key (delegation_id);
-- workflow_decisions.authority_source (free text, already
-- unconstrained beyond non-empty) gains an appended
-- "|delegated_from:<uuid>|delegation_id:<uuid>" suffix only when the
-- deciding actor is a delegate, and workflow_approval_positions/
-- workflow_participants.authority_source (same free-text column,
-- same precedent) gains an appended
-- "|substituted_from:<uuid>|substitution_id:<uuid>" suffix only when
-- a candidate was substitution-resolved. workflow_decisions.actor_id
-- is already the deciding actor (delegate or original, whichever
-- acted) — no change needed there.
-- ============================================================

BEGIN;

-- ── 1. workflow_resolve_effective_candidate — private, substitution-
--    resolution seam. Returns the original user unchanged unless an
--    active planned_leave (represented_type='user') or, absent one,
--    an active acting_appointment for the given role+scope
--    (represented_type IN ('organization_role','section_role'))
--    currently applies. LATERAL-joined once per originally-resolved
--    row by workflow_resolve_approval_candidates below — the same
--    per-row-STABLE-SQL-function pattern scope_org_id/
--    scope_section_ids already use, chosen for the same inlining/
--    performance reasons Phase 5.1 documented for SECURITY DEFINER
--    plpgsql helpers in a hot path. ──────────────────────────────
CREATE OR REPLACE FUNCTION workflow_resolve_effective_candidate(
  p_user_id UUID,
  p_organization_id UUID,
  p_role TEXT,
  p_role_organization_id UUID,
  p_section_id UUID,
  p_now TIMESTAMPTZ
) RETURNS TABLE (
  effective_user_id UUID,
  substituted BOOLEAN,
  substitution_id UUID
) AS $$
  SELECT COALESCE(best.substitute_id, p_user_id), best.substitute_id IS NOT NULL, best.id
  FROM (SELECT 1) anchor
  LEFT JOIN LATERAL (
    SELECT s.id, s.substitute_id,
      CASE s.represented_type WHEN 'user' THEN 1 WHEN 'organization_role' THEN 2 ELSE 3 END AS priority
    FROM workflow_substitutions s
    WHERE s.organization_id = p_organization_id
      AND s.status IN ('scheduled','active')
      AND p_now >= s.starts_at AND p_now < s.ends_at
      AND (
        (s.represented_type = 'user' AND s.represented_user_id = p_user_id)
        OR (p_role IS NOT NULL AND p_role_organization_id IS NOT NULL
            AND s.represented_type = 'organization_role' AND s.represented_role = p_role
            AND s.represented_role_organization_id = p_role_organization_id)
        OR (p_role IS NOT NULL AND p_section_id IS NOT NULL
            AND s.represented_type = 'section_role' AND s.represented_role = p_role
            AND s.represented_section_id = p_section_id)
      )
    ORDER BY priority
    LIMIT 1
  ) best ON TRUE
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_resolve_effective_candidate(UUID,UUID,TEXT,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- ── 2. workflow_resolve_active_delegation — private, work-item-
--    authorization seam. Returns the matching active delegation id
--    (NULL if none) authorizing p_delegate_id to act in
--    p_delegator_id's place, checked against all four delegation
--    scope types. work_item/definition_step scopes match the
--    concrete work item/step directly (available regardless of which
--    selector type originally resolved the assignee);
--    organization_role/section_role scopes match only when the
--    caller supplies the role/scope that resolved the assignee as a
--    candidate in the first place (decide_workflow_work_item derives
--    this from the position's own stored authority_source/
--    organization_id/section_id, never re-running candidate
--    resolution). ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION workflow_resolve_active_delegation(
  p_delegator_id UUID,
  p_delegate_id UUID,
  p_organization_id UUID,
  p_work_item_id UUID,
  p_definition_id UUID,
  p_step_key TEXT,
  p_role TEXT,
  p_role_organization_id UUID,
  p_section_id UUID,
  p_now TIMESTAMPTZ
) RETURNS UUID AS $$
  SELECT d.id
  FROM workflow_delegations d
  WHERE d.delegator_id = p_delegator_id
    AND d.delegate_id = p_delegate_id
    AND d.organization_id = p_organization_id
    AND d.status IN ('scheduled','active')
    AND p_now >= d.starts_at AND p_now < d.effective_ends_at
    AND (
      (d.scope_type = 'work_item' AND d.scope_work_item_id = p_work_item_id)
      OR (d.scope_type = 'definition_step' AND d.scope_definition_id = p_definition_id AND d.scope_step_key = p_step_key)
      OR (p_role IS NOT NULL AND p_role_organization_id IS NOT NULL
          AND d.scope_type = 'organization_role' AND d.scope_role = p_role AND d.scope_role_organization_id = p_role_organization_id)
      OR (p_role IS NOT NULL AND p_section_id IS NOT NULL
          AND d.scope_type = 'section_role' AND d.scope_role = p_role AND d.scope_section_id = p_section_id)
    )
  ORDER BY d.starts_at DESC
  LIMIT 1
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_resolve_active_delegation(UUID,UUID,UUID,UUID,UUID,TEXT,TEXT,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- ── 3. workflow_resolve_approval_candidates — re-declared with the
--    substitution seam wired into both the main resolution CTE and
--    the duplicate-check subquery, so the two call sites can never
--    drift on substitution behavior. Selector syntax, node
--    validation, and self-approval/dedup/ordinal logic are otherwise
--    byte-for-byte unchanged; substitution transforms user_id
--    strictly BEFORE self-approval filtering/dedup/ordinal
--    assignment, so every downstream stage operates on the already-
--    effective user with no further changes. Signature, privileges,
--    and SECURITY DEFINER/search_path posture are unchanged. ───────
CREATE OR REPLACE FUNCTION workflow_resolve_approval_candidates(
  p_instance_id UUID,
  p_home_organization_id UUID,
  p_created_by UUID,
  p_config JSONB
) RETURNS JSONB AS $$
DECLARE
  v_allow_self_approval BOOLEAN := (p_config ->> 'allow_self_approval')::BOOLEAN;
  v_allow_multi_capacity BOOLEAN := (p_config ->> 'allow_multi_capacity')::BOOLEAN;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_candidates JSONB;
BEGIN
  WITH selectors AS (
    SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
    FROM jsonb_array_elements(p_config -> 'candidate_selectors') s
  ),
  raw AS (
    SELECT sel.selector_key, sel.sel_order, u.id AS user_id,
           'explicit_user:' || sel.selector_key AS authority_source,
           NULL::TEXT AS sel_role, NULL::UUID AS sel_role_org_id, NULL::UUID AS sel_section_id
    FROM selectors sel
    JOIN LATERAL jsonb_array_elements_text(sel.s -> 'user_ids') AS uid(v) ON TRUE
    JOIN users u ON u.id = uid.v::UUID AND u.is_active AND u.org_id = p_home_organization_id
    WHERE sel.sel_type = 'explicit_user'

    UNION ALL

    SELECT sel.selector_key, sel.sel_order, ua.user_id,
           'organization_role:' || (sel.s ->> 'role') AS authority_source,
           sel.s ->> 'role', p_home_organization_id, NULL::UUID
    FROM selectors sel
    JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
      AND scope_org_id(ua.scope_type, ua.scope_id) = p_home_organization_id
    JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
    WHERE sel.sel_type = 'organization_role'

    UNION ALL

    SELECT sel.selector_key, sel.sel_order, ua.user_id,
           'section_role:' || (sel.s ->> 'role') AS authority_source,
           sel.s ->> 'role', NULL::UUID, (sel.s ->> 'section_id')::UUID
    FROM selectors sel
    JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
      AND (sel.s ->> 'section_id')::UUID IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
    JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
    WHERE sel.sel_type = 'section_role'

    UNION ALL

    SELECT sel.selector_key, sel.sel_order, p.user_id,
           'instance_participant_role:' || (sel.s ->> 'participant_role') AS authority_source,
           NULL::TEXT, NULL::UUID, NULL::UUID
    FROM selectors sel
    JOIN workflow_participants p ON p.instance_id = p_instance_id
      AND p.participant_role = (sel.s ->> 'participant_role') AND p.ended_at IS NULL
    JOIN users u ON u.id = p.user_id AND u.is_active
    WHERE sel.sel_type = 'instance_participant_role'
  ),
  resolved AS (
    SELECT raw.selector_key, raw.sel_order, eff.effective_user_id AS user_id, raw.sel_section_id AS section_id,
           CASE WHEN eff.substituted
             THEN raw.authority_source || '|substituted_from:' || raw.user_id::TEXT || '|substitution_id:' || eff.substitution_id::TEXT
             ELSE raw.authority_source
           END AS authority_source
    FROM raw
    JOIN LATERAL workflow_resolve_effective_candidate(
      raw.user_id, p_home_organization_id, raw.sel_role, raw.sel_role_org_id, raw.sel_section_id, v_now
    ) eff ON TRUE
  ),
  filtered AS (
    SELECT * FROM resolved
    WHERE v_allow_self_approval OR user_id <> p_created_by
  ),
  deduped_check AS (
    SELECT user_id, count(*) AS n FROM filtered GROUP BY user_id HAVING count(*) > 1
  ),
  ordered AS (
    SELECT user_id, authority_source, selector_key, section_id,
           row_number() OVER (ORDER BY sel_order, selector_key, authority_source, user_id) AS ordinal
    FROM filtered
    WHERE v_allow_multi_capacity OR user_id NOT IN (SELECT user_id FROM deduped_check)
  )
  SELECT jsonb_agg(jsonb_build_object(
    'user_id', user_id, 'authority_source', authority_source, 'selector_key', selector_key,
    'section_id', section_id, 'ordinal', ordinal
  ) ORDER BY ordinal)
  INTO v_candidates
  FROM ordered;

  IF NOT v_allow_multi_capacity AND EXISTS (
    SELECT 1 FROM (
      SELECT eff.effective_user_id AS user_id, count(*) AS n FROM (
        SELECT sel.selector_key, sel.sel_order, u.id AS user_id,
               NULL::TEXT AS sel_role, NULL::UUID AS sel_role_org_id, NULL::UUID AS sel_section_id
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN LATERAL jsonb_array_elements_text(sel.s -> 'user_ids') AS uid(v) ON sel.sel_type = 'explicit_user'
        JOIN users u ON u.id = uid.v::UUID AND u.is_active AND u.org_id = p_home_organization_id
        UNION ALL
        SELECT sel.selector_key, sel.sel_order, ua.user_id,
               sel.s ->> 'role', p_home_organization_id, NULL::UUID
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
          AND scope_org_id(ua.scope_type, ua.scope_id) = p_home_organization_id AND sel.sel_type = 'organization_role'
        JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
        UNION ALL
        SELECT sel.selector_key, sel.sel_order, ua.user_id,
               sel.s ->> 'role', NULL::UUID, (sel.s ->> 'section_id')::UUID
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN user_assignments ua ON ua.role = (sel.s ->> 'role') AND ua.is_active
          AND (sel.s ->> 'section_id')::UUID IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id)) AND sel.sel_type = 'section_role'
        JOIN users u ON u.id = ua.user_id AND u.is_active AND u.org_id = p_home_organization_id
        UNION ALL
        SELECT sel.selector_key, sel.sel_order, p.user_id,
               NULL::TEXT, NULL::UUID, NULL::UUID
        FROM (SELECT s ->> 'key' AS selector_key, (s ->> 'order')::INT AS sel_order, s ->> 'type' AS sel_type, s
              FROM jsonb_array_elements(p_config -> 'candidate_selectors') s) sel
        JOIN workflow_participants p ON p.instance_id = p_instance_id AND p.participant_role = (sel.s ->> 'participant_role')
          AND p.ended_at IS NULL AND sel.sel_type = 'instance_participant_role'
        JOIN users u ON u.id = p.user_id AND u.is_active
      ) x
      JOIN LATERAL workflow_resolve_effective_candidate(
        x.user_id, p_home_organization_id, x.sel_role, x.sel_role_org_id, x.sel_section_id, v_now
      ) eff ON TRUE
      WHERE v_allow_self_approval OR eff.effective_user_id <> p_created_by
      GROUP BY eff.effective_user_id HAVING count(*) > 1
    ) dup
  ) THEN
    RAISE EXCEPTION 'Candidate resolution found a duplicate user across selectors and allow_multi_capacity is false' USING ERRCODE = '55000';
  END IF;

  RETURN v_candidates;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_resolve_approval_candidates(UUID,UUID,UUID,JSONB) FROM PUBLIC, anon, authenticated;

-- ── 4. workflow_enter_downstream_node — re-declared, based on the
--    true current (Phase 4.2 gateway-routing-execution) body, not
--    the superseded Phase 3.2 one — verified by direct extraction,
--    not memory, after the first draft of this patch was caught
--    regressing the gateway_exclusive branch added there. Only
--    change: the candidate JSON's new 'section_id' field is now
--    carried through into workflow_approval_positions.section_id (an
--    existing column, never populated by any prior phase). Every
--    other line — including the gateway_exclusive routing branch — is
--    byte-for-byte unchanged: same signature, same loop, same event
--    sequencing, same work-item/participant creation (already
--    correctly operating on the effective/possibly-substituted
--    user_id the candidate JSON now carries, with no change needed
--    there). ───────────────────────────────────────────────────────
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

    FOR v_pos IN SELECT * FROM jsonb_to_recordset(v_candidates) AS x(user_id UUID, authority_source TEXT, selector_key TEXT, section_id UUID, ordinal INT)
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
          organization_id, section_id, selector_key, state, work_item_id, offered_at
        ) VALUES (
          p_instance_id, v_round_id, v_target_step_id, 'position_' || v_pos.ordinal, v_pos.ordinal, v_pos.user_id, v_pos.authority_source,
          p_home_organization_id, v_pos.section_id, v_pos.selector_key, 'offered', v_work_item_id, v_now
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
          organization_id, section_id, selector_key, state
        ) VALUES (
          p_instance_id, v_round_id, v_target_step_id, 'position_' || v_pos.ordinal, v_pos.ordinal, v_pos.user_id, v_pos.authority_source,
          p_home_organization_id, v_pos.section_id, v_pos.selector_key, 'pending'
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

-- ── 5. decide_workflow_work_item — re-declared, based on the true
--    current (Phase 4.3 decision-replay-hardening) body, not the
--    superseded Phase 3.2/3.1 ones — verified by direct extraction,
--    not memory, after the first draft of this patch was caught
--    regressing the Phase 4.3 expected-lock-version replay
--    comparison. Only change beyond that: widen the single
--    assigned_to authorization check to also accept an authorized,
--    active, in-scope delegate (delegation's own integration point
--    per docs/73), and carry delegation traceability into
--    workflow_decisions.authority_source and the decision_recorded
--    event's metadata. Every other line — the Phase 4.3 replay
--    comparison, decision recording, outcome calculation, round
--    closure, sequential delivery, event emission, downstream entry —
--    is byte-for-byte unchanged. Delegation is treated as ADDITIVE,
--    not exclusive: docs/73 never states the original assignee loses
--    their own ability to act while a delegation is outstanding, so
--    both the original assignee and an authorized delegate may act,
--    whichever does so first closing the position — the existing
--    state guards (workflow_work_items.state /
--    workflow_approval_positions.state both required = 'offered')
--    already make this safe with no further change, since a second
--    attempt by either party after the first decision fails there,
--    before authorization is even reached. See docs/75 for the full
--    reasoning. ──────────────────────────────────────────────────
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
  v_delegation_id UUID;
  v_base_authority_source TEXT;
  v_decision_authority_source TEXT;
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
    SELECT * INTO v_existing_root_event FROM workflow_events we
    WHERE we.instance_id = v_instance.id AND we.idempotency_key = p_command_id;
    IF v_existing_decision.actor_id IS DISTINCT FROM v_actor
       OR v_existing_decision.work_item_id <> p_work_item_id
       OR v_existing_decision.decision_code <> p_decision_code
       OR v_existing_decision.comment IS DISTINCT FROM p_comment
       OR (v_existing_root_event.metadata ->> 'expected_instance_lock_version')::BIGINT <> p_expected_instance_lock_version
       OR (v_existing_root_event.metadata ->> 'expected_work_item_lock_version')::BIGINT <> p_expected_work_item_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input'
        USING ERRCODE = '22023';
    END IF;
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
  v_delegation_id := NULL;
  IF v_work_item.assigned_to IS DISTINCT FROM v_actor THEN
    v_base_authority_source := split_part(v_position.authority_source, '|', 1);
    v_delegation_id := workflow_resolve_active_delegation(
      v_work_item.assigned_to, v_actor, v_instance.home_organization_id, p_work_item_id,
      (SELECT dv.definition_id FROM workflow_definition_versions dv WHERE dv.id = v_instance.definition_version_id),
      v_step.definition_node_key,
      CASE WHEN v_base_authority_source LIKE 'organization_role:%' OR v_base_authority_source LIKE 'section_role:%'
        THEN split_part(v_base_authority_source, ':', 2) END,
      CASE WHEN v_base_authority_source LIKE 'organization_role:%' THEN v_position.organization_id END,
      CASE WHEN v_base_authority_source LIKE 'section_role:%' THEN v_position.section_id END,
      v_now
    );
    IF v_delegation_id IS NULL THEN
      RAISE EXCEPTION 'Workflow work item is not available for this action' USING ERRCODE = '42501';
    END IF;
  END IF;
  v_decision_authority_source := CASE
    WHEN v_delegation_id IS NOT NULL
      THEN v_position.authority_source || '|delegated_from:' || v_work_item.assigned_to::TEXT || '|delegation_id:' || v_delegation_id::TEXT
    ELSE v_position.authority_source
  END;

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
    p_decision_code, v_actor, v_decision_authority_source, p_comment, p_command_id, v_now
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
      'instance_lock_version', v_result_instance_lock_version,
      'expected_instance_lock_version', p_expected_instance_lock_version,
      'expected_work_item_lock_version', p_expected_work_item_lock_version,
      'delegation_id', v_delegation_id));
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
