-- ============================================================
-- CAP-002 Phase 4.1: Workflow Routing Validation and Variable
-- Foundation
--
-- Implements docs/69-workflow-routing-gateway-contract.md's
-- capability-version-2 validation rules and its "workflow-variable
-- write/read foundation" dependency on top of the approved baseline
-- through Phase 3.2 (patch-workflow-approval-round-lifecycle.sql).
--
-- Scope boundary: this patch validates and canonicalizes
-- schema_version=2 payloads containing gateway_exclusive nodes, and
-- adds the one missing write path for workflow_variables. It does
-- NOT evaluate a single condition, does NOT touch
-- workflow_enter_downstream_node or any graph-advancement function,
-- does NOT add a route_selected event or any new event type, and
-- does NOT change legacy inert or schema-version-1 behavior in any
-- way. Every new check below is gated strictly on schema_version = 2
-- (definition validation) or is an entirely new, independently
-- callable command (workflow-variable write) that no existing
-- command path invokes.
--
-- Backward compatibility: every schema_version-1 payload takes
-- byte-for-byte the same validation path it already did. The only
-- structural change to canonicalize_workflow_definition_payload's
-- schema_version-1 branch is that it is now reached via an explicit
-- v_schema_version = 1 check instead of a hardcoded '1' literal, and
-- the returned canonical payload's 'schema_version' field is now
-- v_schema_version instead of a literal 1 (which evaluates to the
-- exact same value on every schema_version-1 payload, since
-- v_schema_version can only be 1 or 2 and this is the 1 branch).
--
-- Deliberate scope decision on variable-write idempotency (see
-- docs/70 "Limitations"): unlike every event-sourced command in this
-- engine, set_workflow_instance_variable has no event ledger to
-- replay from ("no execution events" is explicit out-of-scope for
-- this phase). Idempotent replay is instead implemented by storing
-- the most recent write's idempotency key directly on the variable
-- row and comparing against it — giving the same "same key + same
-- input replays; same key + different input fails with 22023"
-- contract docs/63 requires, without an event.
--
-- Deliberate scope decision on gateway inbound-edge cardinality: the
-- approval-node validator this file's Phase 2B.1 predecessor already
-- shipped enforces EXACTLY ONE inbound edge per approval node (not
-- the more permissive "one or more, prove one reachable path"
-- reading of docs/63's prose). docs/69 said gateway_exclusive nodes
-- "reuse exactly the same rule already applied to approval nodes" —
-- this patch honors that literally by requiring exactly one inbound
-- edge per gateway_exclusive node too, which in turn means
-- docs/69's "Merge behavior" reconvergence claim is fully available
-- only onto End nodes (which have no upper inbound-edge bound) in
-- this implementation, not onto a second approval/gateway node. This
-- is a faithful implementation of "reuse the same rule," not a
-- redesign; it is called out explicitly in docs/70 rather than
-- silently reconciled.
-- ============================================================

BEGIN;

-- ── 1. Workflow-variable write foundation: two purely additive
--    columns. workflow_variables has never had a writer (Phase 1
--    created the table read-only; no later phase added one), so no
--    existing row shape or data is at risk. ─────────────────────
ALTER TABLE workflow_variables
  ADD COLUMN IF NOT EXISTS lock_version BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS write_idempotency_key UUID;

-- ── 2. wf_condition_literal_matches_type — pure, deterministic type
--    check reused both by definition-validation (condition literal
--    values in a gateway edge's condition object) and by the new
--    variable-write command (declared value_type vs. actual value).
--    Not granted to any role — reachable only from the two callers
--    below, matching every other internal helper's boundary. ──────
CREATE OR REPLACE FUNCTION wf_condition_literal_matches_type(p_value JSONB, p_value_type TEXT)
RETURNS BOOLEAN AS $$
  SELECT CASE p_value_type
    WHEN 'boolean' THEN jsonb_typeof(p_value) = 'boolean'
    WHEN 'number' THEN jsonb_typeof(p_value) = 'number'
    WHEN 'string' THEN jsonb_typeof(p_value) = 'string'
    WHEN 'uuid' THEN jsonb_typeof(p_value) = 'string'
      AND (p_value #>> '{}') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    WHEN 'date' THEN jsonb_typeof(p_value) = 'string'
      AND (p_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
    WHEN 'timestamp' THEN jsonb_typeof(p_value) = 'string'
      AND (p_value #>> '{}') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
    ELSE FALSE
  END;
$$ LANGUAGE sql IMMUTABLE;

REVOKE ALL ON FUNCTION wf_condition_literal_matches_type(JSONB, TEXT) FROM PUBLIC, anon, authenticated;

-- ── 3. canonicalize_workflow_definition_payload — extended to accept
--    schema_version = 2 (gateway_exclusive nodes, condition-bearing
--    edges) alongside byte-for-byte-unchanged schema_version = 1
--    behavior. Every new branch below is reached only when
--    v_schema_version = 2; every schema_version = 1 payload takes
--    exactly the code paths it already did. ──────────────────────
CREATE OR REPLACE FUNCTION canonicalize_workflow_definition_payload(
  p_payload JSONB,
  p_organization_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_schema_version INTEGER;
  v_entry_node TEXT;
  v_node_count INTEGER;
  v_edge_count INTEGER;
  v_node_keys TEXT[] := ARRAY[]::TEXT[];
  v_start_keys TEXT[] := ARRAY[]::TEXT[];
  v_end_keys TEXT[] := ARRAY[]::TEXT[];
  v_node_type_map JSONB := '{}'::JSONB;
  v_node JSONB;
  v_edge JSONB;
  v_selector JSONB;
  v_keys TEXT[];
  v_type TEXT;
  v_label TEXT;
  v_config JSONB;
  v_requirement TEXT;
  v_decision_rule TEXT;
  v_selector_count INTEGER;
  v_outbound_total INTEGER;
  v_inbound_total INTEGER;
  v_reachable_count INTEGER;
  v_can_reach_end_count INTEGER;
  v_remaining TEXT[];
  v_indegree JSONB := '{}'::JSONB;
  v_zero_queue TEXT[];
  v_processed INTEGER := 0;
  v_current TEXT;
  v_neighbor TEXT;
  v_canonical_nodes JSONB;
  v_canonical_edges JSONB;
  v_source_type TEXT;
  v_condition JSONB;
  v_operator TEXT;
  v_value_type TEXT;
  v_gateway_default_count INTEGER;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'wf_def_validation: rule=payload_not_object node=NULL' USING ERRCODE = '22023';
  END IF;

  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_payload) k)
     IS DISTINCT FROM ARRAY['edges','entry_node','nodes','schema_version'] THEN
    RAISE EXCEPTION 'wf_def_validation: rule=unknown_or_missing_top_level_field node=NULL' USING ERRCODE = '22023';
  END IF;

  IF NOT (jsonb_typeof(p_payload -> 'schema_version') = 'number'
          AND (p_payload -> 'schema_version')::TEXT IN ('1', '2')) THEN
    RAISE EXCEPTION 'wf_def_validation: rule=unsupported_schema_version node=NULL' USING ERRCODE = '22023';
  END IF;
  v_schema_version := (p_payload -> 'schema_version')::TEXT::INTEGER;

  v_entry_node := p_payload ->> 'entry_node';
  IF v_entry_node IS NULL OR v_entry_node !~ '^[a-z][a-z0-9_]{0,62}$' THEN
    RAISE EXCEPTION 'wf_def_validation: rule=invalid_entry_node node=NULL' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(p_payload -> 'nodes') <> 'array' THEN
    RAISE EXCEPTION 'wf_def_validation: rule=nodes_not_array node=NULL' USING ERRCODE = '22023';
  END IF;
  v_node_count := jsonb_array_length(p_payload -> 'nodes');
  IF v_node_count < 2 OR v_node_count > 200 THEN
    RAISE EXCEPTION 'wf_def_validation: rule=node_count_out_of_bounds node=NULL' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(p_payload -> 'edges') <> 'array' THEN
    RAISE EXCEPTION 'wf_def_validation: rule=edges_not_array node=NULL' USING ERRCODE = '22023';
  END IF;
  v_edge_count := jsonb_array_length(p_payload -> 'edges');
  IF v_edge_count < 1 OR v_edge_count > 400 THEN
    RAISE EXCEPTION 'wf_def_validation: rule=edge_count_out_of_bounds node=NULL' USING ERRCODE = '22023';
  END IF;

  IF (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'nodes')) <>
     (SELECT count(DISTINCT n ->> 'key') FROM jsonb_array_elements(p_payload -> 'nodes') n) THEN
    RAISE EXCEPTION 'wf_def_validation: rule=duplicate_node_key node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Per-node structural + config validation ──────────────────
  FOR v_node IN SELECT * FROM jsonb_array_elements(p_payload -> 'nodes') LOOP
    v_keys := (SELECT array_agg(k) FROM jsonb_object_keys(v_node) k);
    IF NOT (v_keys <@ ARRAY['key','type','label','config'] AND v_keys @> ARRAY['key','type','config']) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=node_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;
    IF v_node ->> 'key' IS NULL OR (v_node ->> 'key') !~ '^[a-z][a-z0-9_]{0,62}$' THEN
      RAISE EXCEPTION 'wf_def_validation: rule=invalid_node_key_format node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;

    v_type := COALESCE(v_node ->> 'type', '');
    IF (v_schema_version = 1 AND v_type NOT IN ('start','approval','end'))
       OR (v_schema_version = 2 AND v_type NOT IN ('start','approval','end','gateway_exclusive')) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=invalid_node_type node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;
    v_node_type_map := v_node_type_map || jsonb_build_object(v_node ->> 'key', v_type);

    IF v_node ? 'label' THEN
      IF jsonb_typeof(v_node -> 'label') <> 'string' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=invalid_node_label node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      v_label := btrim(v_node ->> 'label');
      IF char_length(v_label) < 1 OR char_length(v_label) > 120 THEN
        RAISE EXCEPTION 'wf_def_validation: rule=invalid_node_label node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
    END IF;

    IF jsonb_typeof(v_node -> 'config') <> 'object' THEN
      RAISE EXCEPTION 'wf_def_validation: rule=node_config_not_object node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;
    v_config := v_node -> 'config';

    IF v_type = 'start' THEN
      v_start_keys := v_start_keys || (v_node ->> 'key');
      IF v_config <> '{}'::JSONB THEN
        RAISE EXCEPTION 'wf_def_validation: rule=start_config_not_empty node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

    ELSIF v_type = 'end' THEN
      v_end_keys := v_end_keys || (v_node ->> 'key');
      v_keys := (SELECT array_agg(k) FROM jsonb_object_keys(v_config) k);
      IF v_keys IS DISTINCT FROM ARRAY['outcome_code']
         OR jsonb_typeof(v_config -> 'outcome_code') <> 'string'
         OR (v_config ->> 'outcome_code') !~ '^[a-z][a-z0-9_]{0,62}$' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=end_config_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

    ELSIF v_type = 'gateway_exclusive' THEN
      IF v_config <> '{}'::JSONB THEN
        RAISE EXCEPTION 'wf_def_validation: rule=gateway_config_not_empty node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

    ELSE -- approval
      v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_config) k);
      IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY[
        'delivery_mode','decision_rule','minimum_approvals','requirement','optional_policy',
        'allow_abstain','reject_behavior','allow_self_approval','allow_multi_capacity',
        'minimum_candidates','candidate_selectors','comment_policy'
      ]) k) THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_config_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      IF COALESCE(v_config ->> 'delivery_mode', '') NOT IN ('sequential','parallel') THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_delivery_mode_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      v_decision_rule := COALESCE(v_config ->> 'decision_rule', '');
      IF v_decision_rule NOT IN ('unanimous','majority') THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_decision_rule_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      IF jsonb_typeof(v_config -> 'minimum_approvals') = 'null' THEN
        NULL;
      ELSIF v_decision_rule <> 'majority'
            OR jsonb_typeof(v_config -> 'minimum_approvals') <> 'number'
            OR (v_config -> 'minimum_approvals')::TEXT !~ '^[0-9]+$'
            OR (v_config ->> 'minimum_approvals')::INT NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_minimum_approvals_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      v_requirement := COALESCE(v_config ->> 'requirement', '');
      IF v_requirement NOT IN ('required','optional') THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_requirement_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      IF v_requirement = 'required' THEN
        IF jsonb_typeof(v_config -> 'optional_policy') <> 'null' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=approval_optional_policy_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
        END IF;
      ELSE
        IF v_config ->> 'optional_policy' IS DISTINCT FROM 'skip_if_no_candidates' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=approval_optional_policy_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
        END IF;
      END IF;

      IF jsonb_typeof(v_config -> 'allow_abstain') <> 'boolean' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_allow_abstain_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      IF COALESCE(v_config ->> 'reject_behavior', '') NOT IN ('immediate','when_approval_impossible') THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_reject_behavior_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_config -> 'allow_self_approval') <> 'boolean' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_allow_self_approval_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_config -> 'allow_multi_capacity') <> 'boolean' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_allow_multi_capacity_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      IF jsonb_typeof(v_config -> 'minimum_candidates') <> 'number'
         OR (v_config -> 'minimum_candidates')::TEXT !~ '^[0-9]+$'
         OR (v_config ->> 'minimum_candidates')::INT NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_minimum_candidates_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      IF jsonb_typeof(v_config -> 'comment_policy') <> 'object'
         OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_config -> 'comment_policy') k)
             IS DISTINCT FROM ARRAY['abstain','approve','reject']
         OR COALESCE(v_config -> 'comment_policy' ->> 'approve', '') NOT IN ('required','optional','forbidden')
         OR COALESCE(v_config -> 'comment_policy' ->> 'reject', '') NOT IN ('required','optional','forbidden')
         OR COALESCE(v_config -> 'comment_policy' ->> 'abstain', '') NOT IN ('required','optional','forbidden') THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_comment_policy_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      IF (v_config -> 'allow_abstain')::TEXT = 'false'
         AND (v_config -> 'comment_policy' ->> 'abstain') <> 'forbidden' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_comment_policy_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      IF jsonb_typeof(v_config -> 'candidate_selectors') <> 'array' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_selectors_count_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      v_selector_count := jsonb_array_length(v_config -> 'candidate_selectors');
      IF v_selector_count < 1 OR v_selector_count > 16 THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_selectors_count_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
      IF (SELECT count(DISTINCT s ->> 'order') FROM jsonb_array_elements(v_config -> 'candidate_selectors') s) <> v_selector_count
         OR (SELECT count(DISTINCT s ->> 'key') FROM jsonb_array_elements(v_config -> 'candidate_selectors') s) <> v_selector_count THEN
        RAISE EXCEPTION 'wf_def_validation: rule=duplicate_selector_order_or_key node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;

      FOR v_selector IN SELECT * FROM jsonb_array_elements(v_config -> 'candidate_selectors') LOOP
        IF v_selector ->> 'key' IS NULL OR (v_selector ->> 'key') !~ '^[a-z][a-z0-9_]{0,62}$' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=selector_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
        END IF;
        IF jsonb_typeof(v_selector -> 'order') <> 'number'
           OR (v_selector -> 'order')::TEXT !~ '^[0-9]+$'
           OR (v_selector ->> 'order')::INT NOT BETWEEN 1 AND 16 THEN
          RAISE EXCEPTION 'wf_def_validation: rule=selector_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
        END IF;

        IF v_selector ->> 'type' = 'explicit_user' THEN
          v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_selector) k);
          IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['key','order','type','user_ids']) k) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF p_organization_id IS NULL THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_platform_scope_violation node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF jsonb_typeof(v_selector -> 'user_ids') <> 'array' OR jsonb_array_length(v_selector -> 'user_ids') < 1 THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_explicit_user_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(v_selector -> 'user_ids') u
            WHERE u !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          ) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_explicit_user_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;

        ELSIF v_selector ->> 'type' = 'organization_role' THEN
          v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_selector) k);
          IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['key','order','organization','role','type']) k) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF COALESCE(v_selector ->> 'organization', '') <> 'home'
             OR COALESCE(v_selector ->> 'role', '') NOT IN ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff') THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_organization_role_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;

        ELSIF v_selector ->> 'type' = 'section_role' THEN
          v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_selector) k);
          IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['key','order','role','section_id','type']) k) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF p_organization_id IS NULL THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_platform_scope_violation node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF COALESCE(v_selector ->> 'role', '') NOT IN ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff')
             OR COALESCE(v_selector ->> 'section_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_section_role_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF NOT EXISTS (
            SELECT 1 FROM sections s
            WHERE s.id = (v_selector ->> 'section_id')::UUID
              AND s.is_active = TRUE
              AND s.org_id = p_organization_id
          ) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_section_role_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;

        ELSIF v_selector ->> 'type' = 'instance_participant_role' THEN
          v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_selector) k);
          IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['key','order','participant_role','type']) k) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_unknown_or_missing_field node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;
          IF COALESCE(v_selector ->> 'participant_role', '') NOT IN ('owner','manager') THEN
            RAISE EXCEPTION 'wf_def_validation: rule=selector_instance_participant_role_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
          END IF;

        ELSE
          RAISE EXCEPTION 'wf_def_validation: rule=selector_type_unsupported node=%', (v_node ->> 'key') USING ERRCODE = '22023';
        END IF;
      END LOOP;
    END IF;

    v_node_keys := v_node_keys || (v_node ->> 'key');
  END LOOP;

  IF array_length(v_start_keys, 1) <> 1 THEN
    RAISE EXCEPTION 'wf_def_validation: rule=start_node_cardinality node=NULL' USING ERRCODE = '22023';
  END IF;
  IF v_start_keys[1] <> v_entry_node THEN
    RAISE EXCEPTION 'wf_def_validation: rule=entry_node_mismatch node=NULL' USING ERRCODE = '22023';
  END IF;
  IF array_length(v_end_keys, 1) IS NULL OR array_length(v_end_keys, 1) < 1 THEN
    RAISE EXCEPTION 'wf_def_validation: rule=end_node_missing node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Per-edge structural validation. Field-set and priority/default
  --    rules branch on the source node's type: gateway_exclusive
  --    edges use the new condition-bearing shape (docs/69), every
  --    other source type keeps the exact schema_version-1 shape and
  --    rules unchanged. ─────────────────────────────────────────
  FOR v_edge IN SELECT * FROM jsonb_array_elements(p_payload -> 'edges') LOOP
    IF v_edge ->> 'source' IS NULL OR NOT (v_edge ->> 'source' = ANY(v_node_keys)) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_endpoint_missing node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
    END IF;
    IF v_edge ->> 'target' IS NULL OR NOT (v_edge ->> 'target' = ANY(v_node_keys)) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_endpoint_missing node=%', (v_edge ->> 'target') USING ERRCODE = '22023';
    END IF;
    IF v_edge ->> 'source' = v_edge ->> 'target' THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_self_loop node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
    END IF;

    v_source_type := v_node_type_map ->> (v_edge ->> 'source');

    IF v_source_type = 'gateway_exclusive' THEN
      v_keys := (SELECT array_agg(k) FROM jsonb_object_keys(v_edge) k);
      IF NOT (v_keys <@ ARRAY['condition','default','outcome','priority','source','target']
              AND v_keys @> ARRAY['default','outcome','priority','source','target']) THEN
        RAISE EXCEPTION 'wf_def_validation: rule=gateway_edge_unknown_or_missing_field node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;
      IF COALESCE(v_edge ->> 'outcome', '') <> 'routed' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=gateway_edge_outcome_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_edge -> 'priority') <> 'number'
         OR (v_edge -> 'priority')::TEXT !~ '^[0-9]+$'
         OR (v_edge ->> 'priority')::INT NOT BETWEEN 0 AND 1000 THEN
        RAISE EXCEPTION 'wf_def_validation: rule=gateway_edge_priority_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_edge -> 'default') <> 'boolean' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=gateway_edge_default_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;

      IF (v_edge -> 'default')::TEXT = 'true' THEN
        IF v_edge ? 'condition' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=gateway_default_edge_has_condition node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
        END IF;
      ELSE
        IF NOT (v_edge ? 'condition') OR jsonb_typeof(v_edge -> 'condition') <> 'object' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_missing node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
        END IF;
        v_condition := v_edge -> 'condition';
        v_operator := v_condition ->> 'operator';

        IF v_operator IN ('is_null','is_not_null') THEN
          v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_condition) k);
          IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['operator','source','variable_name']) k) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_unknown_or_missing_field node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
          END IF;
        ELSIF v_operator IN ('equals','not_equals','in','not_in','greater_than','greater_than_or_equal','less_than','less_than_or_equal') THEN
          v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_condition) k);
          IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['operator','source','value','value_type','variable_name']) k) THEN
            RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_unknown_or_missing_field node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
          END IF;
        ELSE
          RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_operator_unsupported node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
        END IF;

        IF COALESCE(v_condition ->> 'source', '') <> 'instance_variable' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_source_unsupported node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
        END IF;
        IF v_condition ->> 'variable_name' IS NULL OR (v_condition ->> 'variable_name') !~ '^[a-z][a-z0-9_]{0,62}$' THEN
          RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_variable_name_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
        END IF;

        IF v_operator NOT IN ('is_null','is_not_null') THEN
          v_value_type := v_condition ->> 'value_type';
          IF v_value_type NOT IN ('boolean','number','string','date','timestamp','uuid') THEN
            RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_value_type_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
          END IF;
          IF v_operator IN ('in','not_in') AND v_value_type NOT IN ('number','string','uuid') THEN
            RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_operator_type_mismatch node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
          END IF;
          IF v_operator IN ('greater_than','greater_than_or_equal','less_than','less_than_or_equal')
             AND v_value_type NOT IN ('number','date','timestamp') THEN
            RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_operator_type_mismatch node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
          END IF;

          IF v_operator IN ('in','not_in') THEN
            IF jsonb_typeof(v_condition -> 'value') <> 'array'
               OR jsonb_array_length(v_condition -> 'value') < 1
               OR jsonb_array_length(v_condition -> 'value') > 20 THEN
              RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_value_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
            END IF;
            IF EXISTS (
              SELECT 1 FROM jsonb_array_elements(v_condition -> 'value') e
              WHERE NOT wf_condition_literal_matches_type(e, v_value_type)
            ) THEN
              RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_value_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
            END IF;
          ELSE
            IF NOT wf_condition_literal_matches_type(v_condition -> 'value', v_value_type) THEN
              RAISE EXCEPTION 'wf_def_validation: rule=gateway_condition_value_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
            END IF;
          END IF;
        END IF;
      END IF;

    ELSE
      v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_edge) k);
      IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['default','outcome','priority','source','target']) k) THEN
        RAISE EXCEPTION 'wf_def_validation: rule=edge_unknown_or_missing_field node=NULL' USING ERRCODE = '22023';
      END IF;
      IF COALESCE(v_edge ->> 'outcome', '') !~ '^[a-z][a-z0-9_]{0,62}$' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=edge_outcome_format_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_edge -> 'priority') <> 'number' OR (v_edge -> 'priority')::TEXT <> '0' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=edge_priority_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_edge -> 'default') <> 'boolean' OR (v_edge -> 'default')::TEXT <> 'false' THEN
        RAISE EXCEPTION 'wf_def_validation: rule=edge_default_invalid node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
      END IF;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges')) <>
     (SELECT count(DISTINCT (e ->> 'source', e ->> 'outcome', e ->> 'priority', e ->> 'target'))
      FROM jsonb_array_elements(p_payload -> 'edges') e) THEN
    RAISE EXCEPTION 'wf_def_validation: rule=duplicate_edge_tuple node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Start/approval/end/gateway outbound + inbound edge-coverage
  --    rules ─────────────────────────────────────────────────────
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'target' = v_entry_node) THEN
    RAISE EXCEPTION 'wf_def_validation: rule=start_node_has_inbound_edge node=%', v_entry_node USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_entry_node) <> 1
     OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_payload -> 'edges') e
       WHERE e ->> 'source' = v_entry_node AND e ->> 'outcome' = 'started'
     ) THEN
    RAISE EXCEPTION 'wf_def_validation: rule=start_node_outbound_invalid node=%', v_entry_node USING ERRCODE = '22023';
  END IF;

  FOR v_node IN SELECT n FROM jsonb_array_elements(p_payload -> 'nodes') n WHERE (n ->> 'type') = 'end' LOOP
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key') THEN
      RAISE EXCEPTION 'wf_def_validation: rule=end_node_has_outbound_edge node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'target' = v_node ->> 'key') THEN
      RAISE EXCEPTION 'wf_def_validation: rule=end_node_no_inbound_edge node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;
  END LOOP;

  FOR v_node IN SELECT n FROM jsonb_array_elements(p_payload -> 'nodes') n WHERE (n ->> 'type') = 'approval' LOOP
    v_inbound_total := (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'target' = v_node ->> 'key');
    IF v_inbound_total <> 1 THEN
      RAISE EXCEPTION 'wf_def_validation: rule=approval_inbound_edges_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;

    v_outbound_total := (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key');
    v_requirement := v_node -> 'config' ->> 'requirement';
    IF v_requirement = 'required' THEN
      IF v_outbound_total <> 2
         OR (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key' AND e ->> 'outcome' = 'approved') <> 1
         OR (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key' AND e ->> 'outcome' = 'rejected') <> 1
      THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_outbound_edges_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
    ELSE -- optional
      IF v_outbound_total <> 3
         OR (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key' AND e ->> 'outcome' = 'approved') <> 1
         OR (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key' AND e ->> 'outcome' = 'rejected') <> 1
         OR (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key' AND e ->> 'outcome' = 'skipped') <> 1
      THEN
        RAISE EXCEPTION 'wf_def_validation: rule=approval_outbound_edges_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
      END IF;
    END IF;
  END LOOP;

  -- Gateway nodes: exactly one inbound edge (reusing the exact same
  -- rule already applied to approval nodes above — see docs/69
  -- "Merge behavior" and this file's header comment), 2-16 outbound
  -- edges, exactly one default edge, and pairwise-unique priorities
  -- among the node's own outbound edges.
  FOR v_node IN SELECT n FROM jsonb_array_elements(p_payload -> 'nodes') n WHERE (n ->> 'type') = 'gateway_exclusive' LOOP
    v_inbound_total := (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'target' = v_node ->> 'key');
    IF v_inbound_total <> 1 THEN
      RAISE EXCEPTION 'wf_def_validation: rule=gateway_inbound_edges_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;

    v_outbound_total := (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key');
    IF v_outbound_total < 2 OR v_outbound_total > 16 THEN
      RAISE EXCEPTION 'wf_def_validation: rule=gateway_outbound_edges_count_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;

    v_gateway_default_count := (
      SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e
      WHERE e ->> 'source' = v_node ->> 'key' AND (e -> 'default')::TEXT = 'true'
    );
    IF v_gateway_default_count <> 1 THEN
      RAISE EXCEPTION 'wf_def_validation: rule=gateway_default_edge_invalid node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;

    IF v_outbound_total <>
       (SELECT count(DISTINCT (e ->> 'priority')) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_node ->> 'key')
    THEN
      RAISE EXCEPTION 'wf_def_validation: rule=gateway_duplicate_priority node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- ── Reachability: every node reachable from start ────────────
  WITH RECURSIVE reach AS (
    SELECT v_entry_node AS node_key
    UNION
    SELECT e ->> 'target'
    FROM reach r, jsonb_array_elements(p_payload -> 'edges') e
    WHERE e ->> 'source' = r.node_key
  )
  SELECT count(DISTINCT node_key) INTO v_reachable_count FROM reach;
  IF v_reachable_count <> v_node_count THEN
    RAISE EXCEPTION 'wf_def_validation: rule=unreachable_node node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Every node can reach an end (backward reachability from
  --    the full end-node set) ───────────────────────────────────
  WITH RECURSIVE canreach AS (
    SELECT unnest(v_end_keys) AS node_key
    UNION
    SELECT e ->> 'source'
    FROM canreach c, jsonb_array_elements(p_payload -> 'edges') e
    WHERE e ->> 'target' = c.node_key
  )
  SELECT count(DISTINCT node_key) INTO v_can_reach_end_count FROM canreach;
  IF v_can_reach_end_count <> v_node_count THEN
    RAISE EXCEPTION 'wf_def_validation: rule=node_cannot_reach_end node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Acyclic (Kahn's algorithm, bounded by node/edge caps) ────
  v_remaining := v_node_keys;
  FOREACH v_current IN ARRAY v_node_keys LOOP
    v_indegree := v_indegree || jsonb_build_object(
      v_current,
      (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'target' = v_current)
    );
  END LOOP;
  v_zero_queue := ARRAY(SELECT k FROM unnest(v_node_keys) k WHERE (v_indegree ->> k)::INT = 0);
  WHILE array_length(v_zero_queue, 1) IS NOT NULL AND array_length(v_zero_queue, 1) > 0 LOOP
    v_current := v_zero_queue[1];
    v_zero_queue := v_zero_queue[2:array_length(v_zero_queue, 1)];
    v_processed := v_processed + 1;
    FOR v_neighbor IN
      SELECT e ->> 'target' FROM jsonb_array_elements(p_payload -> 'edges') e WHERE e ->> 'source' = v_current
    LOOP
      v_indegree := jsonb_set(v_indegree, ARRAY[v_neighbor], to_jsonb((v_indegree ->> v_neighbor)::INT - 1));
      IF (v_indegree ->> v_neighbor)::INT = 0 THEN
        v_zero_queue := v_zero_queue || v_neighbor;
      END IF;
    END LOOP;
  END LOOP;
  IF v_processed <> v_node_count THEN
    RAISE EXCEPTION 'wf_def_validation: rule=cycle_detected node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Canonical reconstruction ──────────────────────────────────
  v_canonical_nodes := (
    SELECT jsonb_agg(
      (CASE WHEN n ? 'label'
         THEN jsonb_build_object('key', n -> 'key', 'type', n -> 'type', 'label', to_jsonb(btrim(n ->> 'label')), 'config', n -> 'config')
         ELSE jsonb_build_object('key', n -> 'key', 'type', n -> 'type', 'config', n -> 'config')
       END)
      || CASE WHEN (n ->> 'type') = 'approval' THEN jsonb_build_object(
           'config',
           (n -> 'config') || jsonb_build_object(
             'candidate_selectors',
             (SELECT jsonb_agg(
                (CASE WHEN s ->> 'type' = 'explicit_user'
                   THEN s || jsonb_build_object(
                          'user_ids',
                          (SELECT jsonb_agg(DISTINCT u ORDER BY u)
                           FROM jsonb_array_elements_text(s -> 'user_ids') u)
                        )
                   ELSE s
                 END)
                ORDER BY (s ->> 'order')::INT, (s ->> 'key') COLLATE "C"
              )
              FROM jsonb_array_elements(n -> 'config' -> 'candidate_selectors') s)
           )
         ) ELSE '{}'::JSONB END
      ORDER BY (n ->> 'key') COLLATE "C"
    )
    FROM jsonb_array_elements(p_payload -> 'nodes') n
  );

  v_canonical_edges := (
    SELECT jsonb_agg(
      (jsonb_build_object(
        'source', e -> 'source', 'target', e -> 'target', 'outcome', e -> 'outcome',
        'priority', e -> 'priority', 'default', e -> 'default'
      ) || CASE WHEN e ? 'condition' THEN jsonb_build_object('condition', e -> 'condition') ELSE '{}'::JSONB END)
      ORDER BY (e ->> 'source') COLLATE "C", (e ->> 'outcome') COLLATE "C",
               (e ->> 'priority')::INT, (e ->> 'target') COLLATE "C"
    )
    FROM jsonb_array_elements(p_payload -> 'edges') e
  );

  RETURN jsonb_build_object(
    'schema_version', v_schema_version,
    'entry_node', v_entry_node,
    'nodes', v_canonical_nodes,
    'edges', v_canonical_edges
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 4. create_workflow_definition — signature unchanged; now
--    computes and stores capability_version from the canonicalized
--    payload's schema_version instead of relying solely on the
--    column DEFAULT 1, so a schema_version=2 payload is stored with
--    capability_version=2. Legacy inert payloads (no 'schema_version'
--    key) are untouched and keep capability_version=1 via the
--    existing column DEFAULT. ─────────────────────────────────────
CREATE OR REPLACE FUNCTION create_workflow_definition(
  p_organization_id UUID,
  p_definition_key TEXT,
  p_name TEXT,
  p_subject_type TEXT,
  p_definition_payload JSONB,
  p_idempotency_key UUID
) RETURNS TABLE (definition_id UUID, version_id UUID, version_number INTEGER) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_existing workflow_definitions;
  v_definition_id UUID;
  v_version_id UUID;
  v_payload JSONB;
  v_capability_version INTEGER := 1;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow definition creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_organization_id IS NULL THEN
    IF NOT is_super_admin() THEN
      RAISE EXCEPTION 'Only a super administrator may create a platform workflow definition' USING ERRCODE = '42501';
    END IF;
  ELSIF p_organization_id <> get_my_org_id() OR NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized to create a workflow definition for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_definition_key IS NULL OR p_definition_key !~ '^[a-z][a-z0-9_]{0,62}$'
     OR p_subject_type IS NULL OR p_subject_type !~ '^[a-z][a-z0-9_]{0,62}$'
     OR p_name IS NULL OR btrim(p_name) = ''
     OR p_definition_payload IS NULL OR jsonb_typeof(p_definition_payload) <> 'object'
     OR octet_length(p_definition_payload::TEXT) > 1048576 THEN
    RAISE EXCEPTION 'Invalid workflow definition input' USING ERRCODE = '22023';
  END IF;

  IF p_definition_payload ? 'schema_version' THEN
    v_payload := canonicalize_workflow_definition_payload(p_definition_payload, p_organization_id);
    v_capability_version := (v_payload ->> 'schema_version')::INTEGER;
  ELSE
    v_payload := p_definition_payload;
  END IF;

  -- Serialize retries for one caller/key before consulting the idempotency row.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('workflow_definition_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing
  FROM workflow_definitions
  WHERE created_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.organization_id IS DISTINCT FROM p_organization_id
       OR v_existing.definition_key <> p_definition_key
       OR v_existing.name <> btrim(p_name)
       OR v_existing.subject_type <> p_subject_type
       OR NOT EXISTS (
         SELECT 1 FROM workflow_definition_versions v
         WHERE v.definition_id = v_existing.id
           AND v.version_number = 1
           AND v.definition_payload = v_payload
       ) THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT v_existing.id, v.id, v.version_number
      FROM workflow_definition_versions v
      WHERE v.definition_id = v_existing.id AND v.version_number = 1;
    RETURN;
  END IF;

  INSERT INTO workflow_definitions (
    organization_id, definition_key, name, subject_type,
    created_by, updated_by, create_idempotency_key
  ) VALUES (
    p_organization_id, p_definition_key, btrim(p_name), p_subject_type,
    v_actor, v_actor, p_idempotency_key
  ) RETURNING id INTO v_definition_id;

  INSERT INTO workflow_definition_versions (
    definition_id, version_number, capability_version, definition_payload, content_hash,
    created_by, create_idempotency_key
  ) VALUES (
    v_definition_id, 1, v_capability_version, v_payload,
    encode(digest(convert_to(v_payload::TEXT, 'UTF8'), 'sha256'), 'hex'),
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_version_id;

  RETURN QUERY SELECT v_definition_id, v_version_id, 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 5. create_workflow_definition_version — same capability_version
--    computation and storage, signature unchanged. ────────────────
CREATE OR REPLACE FUNCTION create_workflow_definition_version(
  p_definition_id UUID,
  p_definition_payload JSONB,
  p_idempotency_key UUID
) RETURNS TABLE (version_id UUID, version_number INTEGER) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_definition workflow_definitions;
  v_existing workflow_definition_versions;
  v_number INTEGER;
  v_id UUID;
  v_org_id UUID;
  v_payload JSONB;
  v_capability_version INTEGER := 1;
BEGIN
  IF NOT workflow_actor_is_active() OR NOT can_manage_workflow_definition(p_definition_id) THEN
    RAISE EXCEPTION 'Not authorized to version this workflow definition' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_definition_payload IS NULL
     OR jsonb_typeof(p_definition_payload) <> 'object'
     OR octet_length(p_definition_payload::TEXT) > 1048576 THEN
    RAISE EXCEPTION 'Invalid workflow definition version input' USING ERRCODE = '22023';
  END IF;

  SELECT organization_id INTO v_org_id FROM workflow_definitions WHERE id = p_definition_id;

  IF p_definition_payload ? 'schema_version' THEN
    v_payload := canonicalize_workflow_definition_payload(p_definition_payload, v_org_id);
    v_capability_version := (v_payload ->> 'schema_version')::INTEGER;
  ELSE
    v_payload := p_definition_payload;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('workflow_definition_version:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing
  FROM workflow_definition_versions
  WHERE created_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.definition_id <> p_definition_id
       OR v_existing.definition_payload <> v_payload THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.version_number;
    RETURN;
  END IF;

  SELECT * INTO v_definition FROM workflow_definitions
  WHERE id = p_definition_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow definition not found' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (
    SELECT 1 FROM workflow_definition_versions
    WHERE definition_id = p_definition_id AND status = 'draft'
  ) THEN
    RAISE EXCEPTION 'This workflow definition already has a draft version' USING ERRCODE = '55000';
  END IF;

  SELECT COALESCE(MAX(v.version_number), 0) + 1 INTO v_number
  FROM workflow_definition_versions v WHERE v.definition_id = p_definition_id;

  INSERT INTO workflow_definition_versions (
    definition_id, version_number, capability_version, definition_payload, content_hash,
    created_by, create_idempotency_key
  ) VALUES (
    p_definition_id, v_number, v_capability_version, v_payload,
    encode(digest(convert_to(v_payload::TEXT, 'UTF8'), 'sha256'), 'hex'),
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id, v_number;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 6. publish_workflow_definition_version — the capability_version
--    equality check now compares against the payload's own
--    schema_version rather than a hardcoded 1, so it validates
--    1-with-1 and 2-with-2 alike. Every other line is byte-for-byte
--    unchanged, including the untouched legacy-inert branch. ──────
CREATE OR REPLACE FUNCTION publish_workflow_definition_version(
  p_version_id UUID,
  p_expected_definition_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_version workflow_definition_versions;
  v_definition workflow_definitions;
  v_recanonical JSONB;
BEGIN
  IF NOT workflow_actor_is_active() OR p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Publishing requires an active authenticated caller and idempotency key' USING ERRCODE = '42501';
  END IF;

  SELECT d.* INTO v_definition
  FROM workflow_definitions d
  JOIN workflow_definition_versions v ON v.definition_id = d.id
  WHERE v.id = p_version_id
  FOR UPDATE OF d;
  IF NOT FOUND OR NOT can_manage_workflow_definition(v_definition.id) THEN
    RAISE EXCEPTION 'Workflow definition version not found or not manageable' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_version FROM workflow_definition_versions
  WHERE id = p_version_id FOR UPDATE;

  IF v_version.status = 'published'
     AND v_version.publish_idempotency_key = p_idempotency_key
     AND v_version.published_by = v_actor THEN
    RETURN v_version.id;
  END IF;
  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'Only a draft workflow definition version may be published' USING ERRCODE = '55000';
  END IF;
  IF v_definition.lock_version <> p_expected_definition_lock_version THEN
    RAISE EXCEPTION 'Workflow definition changed concurrently' USING ERRCODE = '40001';
  END IF;

  IF v_version.definition_payload ? 'schema_version' THEN
    IF v_version.capability_version <> (v_version.definition_payload ->> 'schema_version')::INTEGER THEN
      RAISE EXCEPTION 'wf_def_validation: rule=capability_version_mismatch node=NULL' USING ERRCODE = '0A000';
    END IF;
    v_recanonical := canonicalize_workflow_definition_payload(v_version.definition_payload, v_definition.organization_id);
    IF v_recanonical <> v_version.definition_payload THEN
      RAISE EXCEPTION 'wf_def_validation: rule=content_hash_mismatch node=NULL' USING ERRCODE = '0A000';
    END IF;
    IF encode(digest(convert_to(v_recanonical::TEXT, 'UTF8'), 'sha256'), 'hex') <> v_version.content_hash THEN
      RAISE EXCEPTION 'wf_def_validation: rule=content_hash_mismatch node=NULL' USING ERRCODE = '0A000';
    END IF;
  ELSE
    -- Phase 1 definitions are intentionally inert. Byte-for-byte the
    -- original Phase 1 rule, unchanged by this patch.
    IF jsonb_typeof(v_version.definition_payload -> 'nodes') <> 'array'
       OR jsonb_typeof(v_version.definition_payload -> 'edges') <> 'array'
       OR jsonb_array_length(v_version.definition_payload -> 'nodes') <> 0
       OR jsonb_array_length(v_version.definition_payload -> 'edges') <> 0 THEN
      RAISE EXCEPTION 'Phase 1 may publish only an inert workflow definition' USING ERRCODE = '0A000';
    END IF;
  END IF;

  UPDATE workflow_definition_versions
  SET status = 'retired'
  WHERE definition_id = v_definition.id AND status = 'published';

  UPDATE workflow_definition_versions
  SET status = 'published', published_by = v_actor, published_at = NOW(),
      publish_idempotency_key = p_idempotency_key
  WHERE id = p_version_id;

  UPDATE workflow_definitions
  SET status = 'active', active_version_id = p_version_id,
      updated_by = v_actor, lock_version = lock_version + 1
  WHERE id = v_definition.id;

  RETURN p_version_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 7. set_workflow_instance_variable — the one new command this
--    phase adds. Reuses can_manage_workflow_instance() (no new
--    permission model); reuses the existing global lock order,
--    inserting the workflow_variables row lock immediately after the
--    instance row and before any step/token/round/position/work-item
--    lock, since a variable has no relation to graph-execution rows
--    (docs/69's own reasoning: variables are a purely instance-scoped
--    attribute). Emits no event of any kind — "no execution events"
--    is explicit out-of-scope for this phase; the append-only event
--    ledger is not the mechanism used here. Idempotent replay is
--    implemented via the new write_idempotency_key column instead
--    (see header comment). Supports only the one approved source
--    docs/69 defines for the future condition system to read
--    (instance-scoped workflow_variables); it implements no module
--    adapter and invents no module-variable source. ────────────────
CREATE OR REPLACE FUNCTION set_workflow_instance_variable(
  p_instance_id UUID,
  p_variable_name TEXT,
  p_value_type TEXT,
  p_variable_value JSONB,
  p_classification TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (variable_id UUID, lock_version BIGINT) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_instance workflow_instances;
  v_existing workflow_variables;
  v_id UUID;
  v_lock_version BIGINT;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Setting a workflow instance variable requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_variable_name IS NULL OR p_variable_name !~ '^[a-z][a-z0-9_]{0,62}$' THEN
    RAISE EXCEPTION 'Invalid workflow variable name' USING ERRCODE = '22023';
  END IF;
  IF p_value_type IS NULL OR p_value_type NOT IN ('null','boolean','number','string','date','timestamp','uuid','json') THEN
    RAISE EXCEPTION 'Invalid workflow variable value type' USING ERRCODE = '22023';
  END IF;
  IF p_classification IS NULL OR p_classification NOT IN ('public','restricted') THEN
    RAISE EXCEPTION 'Invalid workflow variable classification' USING ERRCODE = '22023';
  END IF;
  IF p_variable_value IS NULL THEN
    RAISE EXCEPTION 'A workflow variable value is required (use value_type ''null'' for an explicit null)' USING ERRCODE = '22023';
  END IF;

  IF p_value_type = 'null' THEN
    IF jsonb_typeof(p_variable_value) <> 'null' THEN
      RAISE EXCEPTION 'Workflow variable value does not match its declared type' USING ERRCODE = '22023';
    END IF;
  ELSIF p_value_type = 'json' THEN
    NULL; -- any well-formed JSONB is accepted for the 'json' type; never usable as a condition operand (docs/69)
  ELSE
    IF NOT wf_condition_literal_matches_type(p_variable_value, p_value_type) THEN
      RAISE EXCEPTION 'Workflow variable value does not match its declared type' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Global lock order: caller/idempotency advisory lock, then the
  -- instance row, then (new) the variable row — unchanged for every
  -- other command.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('workflow_variable_write:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_instance FROM workflow_instances WHERE id = p_instance_id FOR UPDATE;
  IF NOT FOUND OR NOT can_manage_workflow_instance(p_instance_id) THEN
    RAISE EXCEPTION 'Workflow instance not found or not manageable' USING ERRCODE = '42501';
  END IF;
  IF v_instance.status NOT IN ('pending','active') THEN
    RAISE EXCEPTION 'Workflow instance variables can only be set while the instance is pending or active' USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_existing FROM workflow_variables
  WHERE instance_id = p_instance_id AND variable_name = p_variable_name
  FOR UPDATE;

  IF FOUND AND v_existing.write_idempotency_key = p_idempotency_key THEN
    IF v_existing.value_type IS DISTINCT FROM p_value_type
       OR v_existing.variable_value IS DISTINCT FROM p_variable_value
       OR v_existing.classification IS DISTINCT FROM p_classification THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.lock_version;
    RETURN;
  END IF;

  IF FOUND THEN
    UPDATE workflow_variables
    SET value_type = p_value_type,
        variable_value = p_variable_value,
        classification = p_classification,
        write_idempotency_key = p_idempotency_key,
        lock_version = v_existing.lock_version + 1,
        updated_by = v_actor
    WHERE id = v_existing.id
    RETURNING id, workflow_variables.lock_version INTO v_id, v_lock_version;
  ELSE
    INSERT INTO workflow_variables (
      instance_id, variable_name, value_type, variable_value, classification,
      write_idempotency_key, lock_version, created_by, updated_by
    ) VALUES (
      p_instance_id, p_variable_name, p_value_type, p_variable_value, p_classification,
      p_idempotency_key, 1, v_actor, v_actor
    ) RETURNING id, workflow_variables.lock_version INTO v_id, v_lock_version;
  END IF;

  RETURN QUERY SELECT v_id, v_lock_version;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 8. Grants ────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION canonicalize_workflow_definition_payload(JSONB, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION set_workflow_instance_variable(UUID, TEXT, TEXT, JSONB, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_workflow_instance_variable(UUID, TEXT, TEXT, JSONB, TEXT, UUID) TO authenticated;

-- Signatures of create_workflow_definition/create_workflow_definition_version/
-- publish_workflow_definition_version are unchanged, so existing grants
-- remain in effect without a REGRANT — CREATE OR REPLACE FUNCTION
-- preserves prior grants for an identical signature.

COMMIT;
