-- CAP-002 Phase 2B.1 disposable performance probe
-- Builds a maximal 200-node / ~395-edge executable definition (the
-- version-1 hard limits from docs/63) and times canonicalization +
-- validation + publication once, then rolls back.
--
-- Graph shape: start -> a1 -> a2 -> ... -> a197, each approval node's
-- 'approved' edge chaining to the next (the last to a shared
-- end_approved node) and every approval's 'rejected' edge draining to
-- a shared end_rejected node. This is a worst-case-sized sequential
-- chain for the bounded reachability/cycle-detection algorithms —
-- 200 nodes exactly, 395 edges (1 + 197*2), both at or near the
-- documented version-1 caps.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('63300000-0000-0000-0000-000000000001','WF Validation Performance','authority','WFVP');
INSERT INTO auth.users(id,email) VALUES ('63300000-0001-0000-0000-000000000001','perf@wfvp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('63300000-0001-0000-0000-000000000001','63300000-0000-0000-0000-000000000001','WFVP-1','WFVP Admin','perf@wfvp.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('63300000-0001-0000-0000-000000000001','organization','63300000-0000-0000-0000-000000000001','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"63300000-0001-0000-0000-000000000001"}',true);

DO $$
DECLARE
  v_nodes JSONB := '[]'::JSONB;
  v_edges JSONB := '[]'::JSONB;
  v_payload JSONB;
  v_g INTEGER;
  v_key TEXT;
  v_next TEXT;
  v_start_ts TIMESTAMPTZ;
  v_create_ms NUMERIC;
  v_publish_ms NUMERIC;
  v_def_id UUID;
  v_ver_id UUID;
BEGIN
  v_nodes := v_nodes || jsonb_build_object('key','start','type','start','config','{}'::jsonb);
  v_nodes := v_nodes || jsonb_build_object('key','end_approved','type','end','config',jsonb_build_object('outcome_code','approved'));
  v_nodes := v_nodes || jsonb_build_object('key','end_rejected','type','end','config',jsonb_build_object('outcome_code','rejected'));
  v_edges := v_edges || jsonb_build_object('source','start','target','a1','outcome','started','priority',0,'default',false);

  FOR v_g IN 1..197 LOOP
    v_key := 'a' || v_g;
    v_next := CASE WHEN v_g = 197 THEN 'end_approved' ELSE 'a' || (v_g + 1) END;
    v_nodes := v_nodes || jsonb_build_object(
      'key', v_key, 'type', 'approval', 'config', jsonb_build_object(
        'delivery_mode','parallel','decision_rule','majority','minimum_approvals',NULL,
        'requirement','required','optional_policy',NULL,'allow_abstain',true,
        'reject_behavior','when_approval_impossible','allow_self_approval',false,
        'allow_multi_capacity',false,'minimum_candidates',1,
        'candidate_selectors', jsonb_build_array(jsonb_build_object(
          'key','s1','order',1,'type','instance_participant_role','participant_role','owner'
        )),
        'comment_policy', jsonb_build_object('approve','optional','reject','required','abstain','optional')
      )
    );
    v_edges := v_edges || jsonb_build_object('source', v_key, 'target', v_next, 'outcome', 'approved', 'priority', 0, 'default', false);
    v_edges := v_edges || jsonb_build_object('source', v_key, 'target', 'end_rejected', 'outcome', 'rejected', 'priority', 0, 'default', false);
  END LOOP;

  IF jsonb_array_length(v_nodes) <> 200 THEN
    RAISE EXCEPTION 'fixture node count is not exactly 200: %', jsonb_array_length(v_nodes);
  END IF;
  IF jsonb_array_length(v_edges) <> 395 THEN
    RAISE EXCEPTION 'fixture edge count is not exactly 395: %', jsonb_array_length(v_edges);
  END IF;

  v_payload := jsonb_build_object('schema_version',1,'entry_node','start','nodes',v_nodes,'edges',v_edges);

  v_start_ts := clock_timestamp();
  SELECT definition_id, version_id INTO v_def_id, v_ver_id FROM create_workflow_definition(
    '63300000-0000-0000-0000-000000000001','wfvp_max_flow','WFVP Max Flow','opaque_case',
    v_payload, '63300000-1000-0000-0000-000000000001'
  );
  v_create_ms := extract(epoch FROM clock_timestamp() - v_start_ts) * 1000;

  v_start_ts := clock_timestamp();
  PERFORM publish_workflow_definition_version(v_ver_id, 0, '63300000-1000-0000-0000-000000000002');
  v_publish_ms := extract(epoch FROM clock_timestamp() - v_start_ts) * 1000;

  RAISE NOTICE 'Maximal (200-node/395-edge) definition: create+canonicalize % ms, publish (re-canonicalize+verify) % ms', round(v_create_ms,2), round(v_publish_ms,2);

  -- Bounded, not a tight production SLA: this is disposable local
  -- hardware, and the algorithms are O(V+E) at these tiny (<=200/
  -- <=400) caps — a multi-second result would indicate an accidental
  -- quadratic blow-up (e.g. a missed index-free nested loop), not
  -- normal variance.
  IF v_create_ms > 5000 OR v_publish_ms > 5000 THEN
    RAISE EXCEPTION 'validation performance regression: create=% ms publish=% ms', v_create_ms, v_publish_ms;
  END IF;
END $$;

RESET ROLE;
ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow executable definition validation performance probe PASSED'; END $$;
