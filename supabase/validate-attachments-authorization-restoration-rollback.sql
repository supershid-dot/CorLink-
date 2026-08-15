-- ============================================================
-- CorLink — Validate: Attachments RLS Authorization Restoration ROLLBACK
-- Confirms rollback-attachments-authorization-restoration.sql restored
-- the exact pre-correction (Phase 1.9A) state.
-- ============================================================

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_actual TEXT[];
  v_policy TEXT;
BEGIN
  -- Exactly the 6-branch pre-correction set on attachments_select/
  -- _insert; the 8-branch pre-correction set on attachments_delete
  -- (it already had external_correspondence/external_correspondence_
  -- reply before this correction -- only meeting/task were missing
  -- there).
  FOREACH v_policy IN ARRAY ARRAY['attachments_select', 'attachments_insert'] LOOP
    SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_actual
    FROM pg_policies
    CROSS JOIN LATERAL regexp_matches(COALESCE(qual,'') || COALESCE(with_check,''), 'record_type = ''([a-z_]+)''', 'g') AS m
    WHERE tablename = 'attachments' AND policyname = v_policy;
    IF v_actual IS DISTINCT FROM ARRAY['internal_reply','internal_request','prisoner_letter','prisoner_reply','request','response'] THEN
      v_missing := v_missing || format('%s-not-restored-to-pre-correction-6-branch-set(got:%s) ', v_policy, array_to_string(v_actual, ','));
    END IF;
  END LOOP;

  SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_actual
  FROM pg_policies
  CROSS JOIN LATERAL regexp_matches(COALESCE(qual,'') || COALESCE(with_check,''), 'record_type = ''([a-z_]+)''', 'g') AS m
  WHERE tablename = 'attachments' AND policyname = 'attachments_delete';
  IF v_actual IS DISTINCT FROM ARRAY['external_correspondence','external_correspondence_reply','internal_reply','internal_request','prisoner_letter','prisoner_reply','request','response'] THEN
    v_missing := v_missing || format('attachments_delete-not-restored-to-pre-correction-8-branch-set(got:%s) ', array_to_string(v_actual, ','));
  END IF;

  -- Prisoner Letters Phase 1.9A model/finalization lock must still be
  -- present -- this rollback only removes what the correction added,
  -- it never touches Phase 1.9A's own contribution.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'attachments' AND policyname = 'attachments_insert'
      AND with_check ILIKE '%pl.status <> ''delivered''%'
  ) THEN
    v_missing := v_missing || 'phase-1.9a-finalization-lock-lost ';
  END IF;

  -- The correction's own regression validator must now correctly
  -- report the rollback state as failing (proving it, not just the
  -- rollback, is doing its job) -- checked by absence of the 'meeting'
  -- branch specifically, already covered above.

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Attachments authorization restoration ROLLBACK validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Attachments authorization restoration ROLLBACK validation PASSED (attachments_select/_insert/_delete restored to the exact pre-correction Phase 1.9A state; finalization lock and narrowed prisoner_letter/prisoner_reply model intact).';
END $$;
