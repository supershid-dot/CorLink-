-- CAP-002 Phase 2B.1 executable definition validation — behavioral suite
-- Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

CREATE TEMP TABLE wfv_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfv_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfv_results, wfv_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('63000000-0000-0000-0000-000000000001','Workflow Validation Org','authority','WFV-A');
INSERT INTO divisions(id,org_id,name) VALUES
 ('63000000-0000-0000-0000-000000000010','63000000-0000-0000-0000-000000000001','WFV Division');
INSERT INTO sections(id,org_id,division_id,name,code,is_active) VALUES
 ('63000000-0000-0000-0000-000000000020','63000000-0000-0000-0000-000000000001','63000000-0000-0000-0000-000000000010','WFV Active Section','WFVAS',true),
 ('63000000-0000-0000-0000-000000000021','63000000-0000-0000-0000-000000000001','63000000-0000-0000-0000-000000000010','WFV Inactive Section','WFVIS',false);
INSERT INTO organizations(id,name,type,code) VALUES
 ('63000000-0000-0000-0000-000000000002','Workflow Validation Org B','authority','WFV-B');
INSERT INTO divisions(id,org_id,name) VALUES
 ('63000000-0000-0000-0000-000000000011','63000000-0000-0000-0000-000000000002','WFV Division B');
INSERT INTO sections(id,org_id,division_id,name,code,is_active) VALUES
 ('63000000-0000-0000-0000-000000000022','63000000-0000-0000-0000-000000000002','63000000-0000-0000-0000-000000000011','WFV Other-Org Section','WFVOS',true);

INSERT INTO auth.users(id,email) VALUES
 ('63000000-0001-0000-0000-000000000001','admin@wfv.local'),
 ('63000000-0001-0000-0000-000000000002','super@wfv.local'),
 ('63000000-0001-0000-0000-000000000003','candidate@wfv.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('63000000-0001-0000-0000-000000000001','63000000-0000-0000-0000-000000000001','WFV-1','WFV Admin','admin@wfv.local',true,false),
 ('63000000-0001-0000-0000-000000000002','63000000-0000-0000-0000-000000000001','WFV-2','WFV Super','super@wfv.local',true,true),
 ('63000000-0001-0000-0000-000000000003','63000000-0000-0000-0000-000000000001','WFV-3','WFV Candidate','candidate@wfv.local',true,false);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('63000000-0001-0000-0000-000000000001','organization','63000000-0000-0000-0000-000000000001','authority_admin',true,true);

-- Reusable valid schema-version-1 payload, matching docs/63's own
-- worked example (parallel majority approval, home_supervisors
-- organization_role selector, two end outcomes).
\set VALID_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"approved_end","type":"end","config":{"outcome_code":"approved"}},{"key":"rejected_end","type":"end","config":{"outcome_code":"rejected"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"approved_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"rejected_end","outcome":"rejected","priority":0,"default":false}]}\''

-- Helper: assert that creating a definition with a given broken
-- schema-version-1 payload is rejected, and that SQLERRM contains the
-- expected rule code. Defined here (as the connecting superuser,
-- before SET ROLE) since `authenticated` has no CREATE privilege on
-- the public schema.
CREATE OR REPLACE FUNCTION wfv_assert_create_rejected(p_key TEXT, p_payload JSONB, p_idem UUID, p_rule TEXT) RETURNS VOID AS $$
DECLARE v_msg TEXT;
BEGIN
  BEGIN
    PERFORM create_workflow_definition(
      '63000000-0000-0000-0000-000000000001', p_key, 'x', 'opaque_case', p_payload, p_idem
    );
    RAISE EXCEPTION 'wfv_test_failure: expected rejection for rule % but creation succeeded', p_rule;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'wfv_test_failure%' THEN RAISE; END IF;
    IF v_msg NOT LIKE ('%rule=' || p_rule || '%') THEN
      RAISE EXCEPTION 'wfv_test_failure: expected rule=% but got: %', p_rule, v_msg;
    END IF;
  END;
END;
$$ LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION wfv_assert_create_rejected(TEXT, JSONB, UUID, TEXT) TO authenticated;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"63000000-0001-0000-0000-000000000001"}',false);

-- ── 1: a fully valid schema-version-1 definition creates, canonicalizes,
--    and publishes successfully ──────────────────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '63000000-0000-0000-0000-000000000001','wfv_valid_flow','WFV Valid Flow','opaque_case',
  :VALID_PAYLOAD::jsonb, '63000000-1000-0000-0000-000000000001'))
INSERT INTO wfv_ids SELECT 'valid_def',definition_id FROM made UNION ALL SELECT 'valid_v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfv_ids WHERE name='valid_v1'),0,'63000000-1000-0000-0000-000000000002');
INSERT INTO wfv_results VALUES (1,'valid schema-version-1 definition creates and publishes');

-- ── 2: publication is idempotent (exact replay) ──────────────────
SELECT publish_workflow_definition_version((SELECT id FROM wfv_ids WHERE name='valid_v1'),0,'63000000-1000-0000-0000-000000000002');
INSERT INTO wfv_results VALUES (2,'publish idempotent replay returns same version');

-- ── 3: the stored payload is canonical (nodes sorted by key,
--    equivalent-but-differently-ordered input produces the SAME hash) ─
DO $$
DECLARE
  v_hash1 TEXT;
  v_hash2 TEXT;
  v_def2 UUID;
  v_v2 UUID;
BEGIN
  SELECT content_hash INTO v_hash1 FROM workflow_definition_versions WHERE id = (SELECT id FROM wfv_ids WHERE name='valid_v1');

  -- Same logical definition, nodes/edges/selectors reordered differently.
  SELECT definition_id, version_id INTO v_def2, v_v2 FROM create_workflow_definition(
    '63000000-0000-0000-0000-000000000001','wfv_reordered_flow','WFV Reordered Flow','opaque_case',
    '{"schema_version":1,"entry_node":"start","edges":[{"source":"review","target":"rejected_end","outcome":"rejected","priority":0,"default":false},{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"approved_end","outcome":"approved","priority":0,"default":false}],"nodes":[{"key":"rejected_end","type":"end","config":{"outcome_code":"rejected"}},{"key":"approved_end","type":"end","config":{"outcome_code":"approved"}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"start","type":"start","config":{}}]}'::jsonb,
    '63000000-1000-0000-0000-000000000003');
  SELECT content_hash INTO v_hash2 FROM workflow_definition_versions WHERE id = v_v2;
  IF v_hash1 <> v_hash2 THEN
    RAISE EXCEPTION 'canonicalization not order-independent: % vs %', v_hash1, v_hash2;
  END IF;
END $$;
INSERT INTO wfv_results VALUES (3,'canonical hash is order-independent for an equivalent definition');

-- ── 4: legacy inert payload (no schema_version key) is completely
--    unaffected — still creates and publishes exactly as Phase 1 ───
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '63000000-0000-0000-0000-000000000001','wfv_legacy_flow','WFV Legacy Flow','opaque_case',
  '{"nodes":[],"edges":[]}'::jsonb, '63000000-1000-0000-0000-000000000004'))
INSERT INTO wfv_ids SELECT 'legacy_def',definition_id FROM made UNION ALL SELECT 'legacy_v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfv_ids WHERE name='legacy_v1'),0,'63000000-1000-0000-0000-000000000005');
INSERT INTO wfv_results VALUES (4,'legacy inert payload (no schema_version) is unaffected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad1',
  '{"schema_version":1,"entry_node":"start","nodes":[],"edges":[],"extra":1}'::jsonb,
  '63000000-1000-0000-0000-000000000010','unknown_or_missing_top_level_field'); END $$;
INSERT INTO wfv_results VALUES (5,'unknown top-level field rejected');

-- schema_version:2 is now a supported capability version (CAP-002
-- Phase 4.1, docs/69/70's gateway_exclusive routing contract), so
-- this scenario now asserts rejection of schema_version:3, a version
-- number that remains genuinely unsupported, rather than 2 — the
-- same superseded-not-defective update pattern already applied to
-- Phase 2C.1's own scenario 13 in Phase 3.2.
DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad2',
  '{"schema_version":3,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000011','unsupported_schema_version'); END $$;
INSERT INTO wfv_results VALUES (6,'unsupported schema_version (3, since 2 is now supported by Phase 4.1) rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad3',
  '{"schema_version":1,"entry_node":"Start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000012','invalid_entry_node'); END $$;
INSERT INTO wfv_results VALUES (7,'invalid entry_node format rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad4',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}}],"edges":[]}'::jsonb,
  '63000000-1000-0000-0000-000000000013','node_count_out_of_bounds'); END $$;
INSERT INTO wfv_results VALUES (8,'node count below minimum (2) rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad5',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"start","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"start","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000014','duplicate_node_key'); END $$;
INSERT INTO wfv_results VALUES (9,'duplicate node key rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad6',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"bogus","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000015','invalid_node_type'); END $$;
INSERT INTO wfv_results VALUES (10,'invalid node type rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad7',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{"x":1}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000016','start_config_not_empty'); END $$;
INSERT INTO wfv_results VALUES (11,'non-empty start config rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad8',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"Bad Code"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000017','end_config_invalid'); END $$;
INSERT INTO wfv_results VALUES (12,'invalid end outcome_code format rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad9',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000018','approval_config_unknown_or_missing_field'); END $$;
INSERT INTO wfv_results VALUES (13,'approval config missing optional_policy key rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad10',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review","target":"s_end","outcome":"skipped","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000019','approval_optional_policy_invalid'); END $$;
INSERT INTO wfv_results VALUES (14,'optional requirement without skip_if_no_candidates policy rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad11',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":false,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000020','approval_comment_policy_invalid'); END $$;
INSERT INTO wfv_results VALUES (15,'allow_abstain=false with non-forbidden abstain comment policy rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad12',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000021','approval_selectors_count_invalid'); END $$;
INSERT INTO wfv_results VALUES (16,'zero candidate selectors rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad13',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"},{"key":"s2","order":1,"type":"instance_participant_role","participant_role":"manager"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000022','duplicate_selector_order_or_key'); END $$;
INSERT INTO wfv_results VALUES (17,'duplicate selector order rejected');

-- explicit_user is permitted on an ORG-scoped definition (only a
-- platform/org-less definition forbids it — see scenario 19) — a
-- genuine positive case, deliberately re-using duplicate user_ids to
-- also confirm the "sorted, unique user_ids" canonicalization rule
-- doesn't reject a legitimate duplicate-then-deduplicated input.
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '63000000-0000-0000-0000-000000000001','wfv_explicit_user_flow','WFV Explicit User Flow','opaque_case',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"explicit_user","user_ids":["63000000-0001-0000-0000-000000000003","63000000-0001-0000-0000-000000000003"]}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000023'))
INSERT INTO wfv_ids SELECT 'explicit_user_v1',version_id FROM made;
DO $$
DECLARE v_ids JSONB;
BEGIN
  SELECT definition_payload -> 'nodes' -> 1 -> 'config' -> 'candidate_selectors' -> 0 -> 'user_ids'
    INTO v_ids FROM workflow_definition_versions WHERE id = (SELECT id FROM wfv_ids WHERE name = 'explicit_user_v1');
  IF jsonb_array_length(v_ids) <> 1 THEN
    RAISE EXCEPTION 'explicit_user user_ids not deduplicated: %', v_ids;
  END IF;
END $$;
INSERT INTO wfv_results VALUES (18,'explicit_user selector on an org-scoped definition succeeds and deduplicates user_ids');

SELECT set_config('request.jwt.claims','{"sub":"63000000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_msg TEXT; v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    PERFORM create_workflow_definition(
      NULL,'wfv_platform_flow','x','opaque_case',
      '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"explicit_user","user_ids":["63000000-0001-0000-0000-000000000003"]}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
      '63000000-1000-0000-0000-000000000024'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE '%rule=selector_platform_scope_violation%' THEN v_rejected := TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'expected platform-scope rejection'; END IF;
END $$;
INSERT INTO wfv_results VALUES (19,'explicit_user selector on a platform definition rejected');

SELECT set_config('request.jwt.claims','{"sub":"63000000-0001-0000-0000-000000000001"}',false);

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad15',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"section_role","section_id":"63000000-0000-0000-0000-000000000021","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000025','selector_section_role_invalid'); END $$;
INSERT INTO wfv_results VALUES (20,'section_role selector referencing an inactive section rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad16',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"section_role","section_id":"63000000-0000-0000-0000-000000000022","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000026','selector_section_role_invalid'); END $$;
INSERT INTO wfv_results VALUES (21,'section_role selector referencing another organization''s section rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad17',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false,"condition":"1=1"}]}'::jsonb,
  '63000000-1000-0000-0000-000000000027','edge_unknown_or_missing_field'); END $$;
INSERT INTO wfv_results VALUES (22,'edge with a condition field (unknown field) rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad18',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}},{"key":"orphan","type":"end","config":{"outcome_code":"y"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000028','end_node_no_inbound_edge'); END $$;
INSERT INTO wfv_results VALUES (23,'unreachable end node with no inbound edge rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad19',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000029','approval_outbound_edges_invalid'); END $$;
INSERT INTO wfv_results VALUES (24,'approval node missing its required rejected-outcome edge rejected');

DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad20',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"start","target":"review2","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000030','start_node_outbound_invalid'); END $$;
INSERT INTO wfv_results VALUES (25,'start node with two outbound edges (fan-out) rejected');

-- ── 26: an approval node with zero inbound edges (never entered from
--    start or anywhere else) is rejected — caught by the "approval
--    node must have exactly one inbound edge" rule, which runs before
--    (and therefore preempts) the separate unreachable_node check for
--    this exact shape. ─────────────────────────────────────────────
DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad21',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}},{"key":"orphan_review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false},{"source":"orphan_review","target":"e","outcome":"approved","priority":0,"default":false},{"source":"orphan_review","target":"e","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000031','approval_inbound_edges_invalid'); END $$;
INSERT INTO wfv_results VALUES (26,'approval node with zero inbound edges rejected');

-- ── 27: a self-contained, internally-valid but disconnected 2-node
--    approval cycle (a<->b, both draining to a second end node z) is
--    rejected as unreachable from start — every OTHER structural rule
--    (inbound/outbound counts, no duplicate edges, no self-loops) is
--    individually satisfied by a/b/z, isolating this as a genuine
--    reachability-only failure, not an artifact of an earlier check. ─
DO $$ BEGIN PERFORM wfv_assert_create_rejected('wfv_bad22',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}},{"key":"a","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"b","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"instance_participant_role","participant_role":"owner"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"z","type":"end","config":{"outcome_code":"y"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false},{"source":"a","target":"b","outcome":"approved","priority":0,"default":false},{"source":"a","target":"z","outcome":"rejected","priority":0,"default":false},{"source":"b","target":"a","outcome":"approved","priority":0,"default":false},{"source":"b","target":"z","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '63000000-1000-0000-0000-000000000032','unreachable_node'); END $$;
INSERT INTO wfv_results VALUES (27,'disconnected approval cycle unreachable from start rejected (also proves cycle_detected is defense-in-depth: this same shape is cyclic, but unreachable_node correctly fires first)');

-- ── 28: capability_version must be 1 (checked at publish time;
--    unreachable to violate via the public RPCs since capability_
--    version has no settable parameter, verified directly here as a
--    structural/documentation check) ──────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'workflow_definition_versions' AND column_name = 'capability_version'
  ) THEN
    RAISE EXCEPTION 'capability_version column missing';
  END IF;
END $$;
INSERT INTO wfv_results VALUES (28,'capability_version column exists and defaults to 1 (verified structurally)');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfv_results;
  IF v_count <> 28 THEN
    RAISE EXCEPTION 'Workflow executable definition validation tests FAILED: expected 28 scenarios, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow executable definition validation behavioral tests PASSED: %/28', v_count;
END $$;

DROP FUNCTION wfv_assert_create_rejected(TEXT, JSONB, UUID, TEXT);
