-- ============================================================
-- CAP-002 Phase 2B.1: Executable Workflow Definition Validation
--
-- Implements docs/63-workflow-executable-definition-contract.md's
-- schema-version-1 canonicalization, validation, hashing, and
-- publication rules on top of the inert Phase 1 foundation
-- (patch-workflow-backend-foundation.sql) and the Phase 2 instance
-- lifecycle (patch-workflow-runtime.sql).
--
-- Scope boundary: this patch validates and publishes executable
-- definitions. It does NOT activate instances, create tokens, steps,
-- approval rounds, work items, or events; does NOT execute a graph;
-- and does NOT change create_workflow_instance or the Phase 2
-- runtime transition function. Those remain exactly as committed.
--
-- Backward compatibility: every new check is gated strictly on the
-- payload containing an explicit top-level 'schema_version' key. A
-- payload without that key is untouched "legacy inert" input and
-- receives byte-for-byte the same treatment Phase 1/2 already gave
-- it (create_workflow_definition/_version store it as-is; publish
-- still enforces only the original empty-nodes/empty-edges rule).
-- This preserves every existing Phase 1/2 behavioral scenario without
-- modification — see docs/64 "Compatibility and regression" for the
-- reasoning and the exact existing test scenarios re-verified.
--
-- Deliberately deferred (see docs/64 "Known limitations"): the
-- 'discarded' draft-replacement/cloning workflow docs/63 describes
-- under "Draft editing and cloning clarification". It is not required
-- for validation itself — canonicalization now runs at draft-creation
-- time (not just publication), so a structurally or graph-invalid
-- executable payload is rejected before any row is ever inserted,
-- meaning the "stuck with an unpublishable draft" scenario that
-- draft-replacement exists to solve cannot arise from a *rejected*
-- attempt. It remains a real gap only for a caller who wants to
-- revise an already-*valid* draft's content before publishing it,
-- which is a distinct, separately-scoped editing-workflow feature.
-- ============================================================

BEGIN;

-- ── 1. canonicalize_workflow_definition_payload ────────────────
-- Structural field validation, graph-shape validation (reachability,
-- acyclicity, edge-outcome coverage, start/end cardinality), approval
-- candidate-selector validation (including the one DB-dependent rule:
-- a section_role selector's section must exist, be active, and belong
-- to the owning definition's organization), and canonical JSONB
-- reconstruction, all in one pass. Raises with a stable
-- "wf_def_validation: rule=<code> node=<key|NULL>" message on the
-- first violation found; returns the canonical payload on success.
--
-- Canonicalization relies on two properties: (1) Postgres jsonb
-- storage already normalizes OBJECT key order independent of input
-- order, so only ARRAY order needs explicit control; (2) rebuilding
-- via jsonb_build_object/jsonb_agg with an explicit ORDER BY is
-- naturally idempotent (re-canonicalizing an already-canonical
-- payload reproduces it exactly), which is what lets publication
-- re-run this same function on the stored payload as a pure integrity
-- check without ever needing to rewrite it.
--
-- Not granted to PUBLIC, anon, or authenticated — reachable only from
-- the SECURITY DEFINER RPCs below, matching every other internal
-- workflow helper's execution-grant boundary (docs/63 "Database
-- boundaries").
CREATE OR REPLACE FUNCTION canonicalize_workflow_definition_payload(
  p_payload JSONB,
  p_organization_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_entry_node TEXT;
  v_node_count INTEGER;
  v_edge_count INTEGER;
  v_node_keys TEXT[] := ARRAY[]::TEXT[];
  v_start_keys TEXT[] := ARRAY[]::TEXT[];
  v_end_keys TEXT[] := ARRAY[]::TEXT[];
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
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'wf_def_validation: rule=payload_not_object node=NULL' USING ERRCODE = '22023';
  END IF;

  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_payload) k)
     IS DISTINCT FROM ARRAY['edges','entry_node','nodes','schema_version'] THEN
    RAISE EXCEPTION 'wf_def_validation: rule=unknown_or_missing_top_level_field node=NULL' USING ERRCODE = '22023';
  END IF;

  IF NOT (jsonb_typeof(p_payload -> 'schema_version') = 'number'
          AND (p_payload -> 'schema_version')::TEXT = '1') THEN
    RAISE EXCEPTION 'wf_def_validation: rule=unsupported_schema_version node=NULL' USING ERRCODE = '22023';
  END IF;

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
    IF v_type NOT IN ('start','approval','end') THEN
      RAISE EXCEPTION 'wf_def_validation: rule=invalid_node_type node=%', (v_node ->> 'key') USING ERRCODE = '22023';
    END IF;

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

  -- ── Per-edge structural validation ───────────────────────────
  FOR v_edge IN SELECT * FROM jsonb_array_elements(p_payload -> 'edges') LOOP
    v_keys := (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_edge) k);
    IF v_keys IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM unnest(ARRAY['default','outcome','priority','source','target']) k) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_unknown_or_missing_field node=NULL' USING ERRCODE = '22023';
    END IF;
    IF v_edge ->> 'source' IS NULL OR NOT (v_edge ->> 'source' = ANY(v_node_keys)) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_endpoint_missing node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
    END IF;
    IF v_edge ->> 'target' IS NULL OR NOT (v_edge ->> 'target' = ANY(v_node_keys)) THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_endpoint_missing node=%', (v_edge ->> 'target') USING ERRCODE = '22023';
    END IF;
    IF v_edge ->> 'source' = v_edge ->> 'target' THEN
      RAISE EXCEPTION 'wf_def_validation: rule=edge_self_loop node=%', (v_edge ->> 'source') USING ERRCODE = '22023';
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
  END LOOP;

  IF (SELECT count(*) FROM jsonb_array_elements(p_payload -> 'edges')) <>
     (SELECT count(DISTINCT (e ->> 'source', e ->> 'outcome', e ->> 'priority', e ->> 'target'))
      FROM jsonb_array_elements(p_payload -> 'edges') e) THEN
    RAISE EXCEPTION 'wf_def_validation: rule=duplicate_edge_tuple node=NULL' USING ERRCODE = '22023';
  END IF;

  -- ── Start/approval/end outbound + inbound edge-coverage rules ─
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
      jsonb_build_object(
        'source', e -> 'source', 'target', e -> 'target', 'outcome', e -> 'outcome',
        'priority', e -> 'priority', 'default', e -> 'default'
      )
      ORDER BY (e ->> 'source') COLLATE "C", (e ->> 'outcome') COLLATE "C",
               (e ->> 'priority')::INT, (e ->> 'target') COLLATE "C"
    )
    FROM jsonb_array_elements(p_payload -> 'edges') e
  );

  RETURN jsonb_build_object(
    'schema_version', 1,
    'entry_node', v_entry_node,
    'nodes', v_canonical_nodes,
    'edges', v_canonical_edges
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 2. create_workflow_definition — canonicalize schema_version-1
--    payloads before the version-1 row is ever inserted; legacy
--    payloads (no 'schema_version' key) are byte-for-byte untouched. ─
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

  v_payload := CASE
    WHEN p_definition_payload ? 'schema_version'
      THEN canonicalize_workflow_definition_payload(p_definition_payload, p_organization_id)
    ELSE p_definition_payload
  END;

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
    definition_id, version_number, definition_payload, content_hash,
    created_by, create_idempotency_key
  ) VALUES (
    v_definition_id, 1, v_payload,
    encode(digest(convert_to(v_payload::TEXT, 'UTF8'), 'sha256'), 'hex'),
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_version_id;

  RETURN QUERY SELECT v_definition_id, v_version_id, 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 3. create_workflow_definition_version — same canonicalization
--    gate; unchanged one-draft-per-definition rule. ─────────────
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

  v_payload := CASE
    WHEN p_definition_payload ? 'schema_version'
      THEN canonicalize_workflow_definition_payload(p_definition_payload, v_org_id)
    ELSE p_definition_payload
  END;

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
    definition_id, version_number, definition_payload, content_hash,
    created_by, create_idempotency_key
  ) VALUES (
    p_definition_id, v_number, v_payload,
    encode(digest(convert_to(v_payload::TEXT, 'UTF8'), 'sha256'), 'hex'),
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id, v_number;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ── 4. publish_workflow_definition_version — legacy inert branch
--    is byte-for-byte unchanged; a schema_version-1 payload now
--    re-verifies canonical content-hash integrity and requires
--    capability_version = 1 (recomputing canonicalize() is a pure,
--    idempotent re-validation of the already-canonical stored
--    payload — it never rewrites the row). ───────────────────────
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
    IF v_version.capability_version <> 1 THEN
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

-- ── 5. Grants ────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION canonicalize_workflow_definition_payload(JSONB, UUID) FROM PUBLIC, anon, authenticated;

-- Signatures are unchanged, so existing grants on create_workflow_definition/
-- create_workflow_definition_version/publish_workflow_definition_version
-- (patch-workflow-backend-foundation.sql) remain in effect without a
-- REGRANT — CREATE OR REPLACE FUNCTION preserves prior grants for an
-- identical signature.

COMMIT;
