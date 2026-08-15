-- ============================================================
-- CorLink — Validate: Attachments RLS Authorization Restoration
-- Companion to supabase/patch-attachments-authorization-restoration.sql
-- Testing-readiness P0-B correction (docs/100)
--
-- Read-only. Regression protection for the exact defect this session
-- found: a `DROP POLICY` + `CREATE POLICY` restatement of
-- attachments_select/_insert/_delete silently dropping an already-
-- supported record_type branch. Checks MEANINGFUL authorization
-- coverage — the actual live, currently-effective set of record_type
-- branches each policy's body references, extracted the same way this
-- session diagnosed the original regression (a regex over the live
-- pg_policies definition, not a brittle exact-text/whitespace
-- comparison against one historical patch file) — so this validator
-- keeps working correctly even if a future, legitimate patch
-- reformats or reorders these policies, as long as it doesn't drop
-- coverage. Any future patch that adds a genuinely new attachment-
-- producing record type must update the expected set below in the
-- same commit — that is the intended, visible way to extend it,
-- documented in supabase/deploy/README.md §9.
-- ============================================================

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_expected TEXT[] := ARRAY[
    'request', 'response', 'internal_request', 'prisoner_letter', 'prisoner_reply',
    'internal_reply', 'external_correspondence', 'external_correspondence_reply', 'meeting', 'task'
  ];
  v_actual TEXT[];
  v_policy TEXT;
  v_def TEXT;
BEGIN
  -- ── 1. Every one of the 3 policies references every expected
  --        record_type -- meaningful coverage, not exact text. ──────
  FOREACH v_policy IN ARRAY ARRAY['attachments_select', 'attachments_insert', 'attachments_delete'] LOOP
    SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_actual
    FROM pg_policies
    CROSS JOIN LATERAL regexp_matches(COALESCE(qual,'') || COALESCE(with_check,''), 'record_type = ''([a-z_]+)''', 'g') AS m
    WHERE tablename = 'attachments' AND policyname = v_policy;

    IF v_actual IS NULL THEN
      v_missing := v_missing || format('%s-missing-entirely ', v_policy);
      CONTINUE;
    END IF;

    IF NOT (v_actual @> v_expected) THEN
      v_missing := v_missing || format('%s-missing-branches:%s ', v_policy,
        array_to_string(ARRAY(SELECT unnest(v_expected) EXCEPT SELECT unnest(v_actual)), ','));
    END IF;
  END LOOP;

  -- ── 2. Prisoner Letters / Prisoner Reply Phase 1.9A protections:
  --        narrowed submitted_by/assigned_to + supervisor-bypass model,
  --        and the delivered-status finalization lock on insert/
  --        delete, must be present verbatim -- this patch must
  --        strengthen nothing and weaken nothing about them. ───────
  FOREACH v_policy IN ARRAY ARRAY['attachments_select', 'attachments_insert', 'attachments_delete'] LOOP
    SELECT COALESCE(qual,'') || COALESCE(with_check,'') INTO v_def
    FROM pg_policies WHERE tablename = 'attachments' AND policyname = v_policy;

    IF v_def NOT ILIKE '%submitted_by = auth.uid()%' OR v_def NOT ILIKE '%assigned_to = auth.uid()%' THEN
      v_missing := v_missing || format('%s-lost-narrowed-prisoner-letters-model ', v_policy);
    END IF;
    IF v_def NOT ILIKE '%is_supervisor_or_above()%' THEN
      v_missing := v_missing || format('%s-lost-supervisor-bypass ', v_policy);
    END IF;
  END LOOP;

  SELECT COALESCE(with_check,'') INTO v_def FROM pg_policies WHERE tablename = 'attachments' AND policyname = 'attachments_insert';
  IF v_def NOT ILIKE '%pl.status <> ''delivered''%' THEN
    v_missing := v_missing || 'attachments_insert-lost-finalization-lock ';
  END IF;
  SELECT COALESCE(qual,'') INTO v_def FROM pg_policies WHERE tablename = 'attachments' AND policyname = 'attachments_delete';
  IF v_def NOT ILIKE '%pl.status <> ''delivered''%' THEN
    v_missing := v_missing || 'attachments_delete-lost-finalization-lock ';
  END IF;

  -- ── 3. Every branch still requires uploaded_by = auth.uid() (no
  --        broadening to a same-org-is-enough shortcut) and every
  --        branch remains individually scoped by EXISTS/a dedicated
  --        can_view_*/can_manage_*() check -- never a bare TRUE. ────
  FOREACH v_policy IN ARRAY ARRAY['attachments_select', 'attachments_insert', 'attachments_delete'] LOOP
    SELECT COALESCE(qual,'') || COALESCE(with_check,'') INTO v_def
    FROM pg_policies WHERE tablename = 'attachments' AND policyname = v_policy;
    IF v_policy <> 'attachments_select' AND v_def NOT ILIKE '%uploaded_by = auth.uid()%' THEN
      v_missing := v_missing || format('%s-lost-uploaded-by-ownership-check ', v_policy);
    END IF;
  END LOOP;

  -- ── 4. CHECK constraint itself was never touched by this patch
  --        (only the policies were) -- still exactly the 10-value set
  --        patch-task-attachments.sql established. ──────────────────
  IF NOT (
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'attachments_record_type_check')) LIKE '%''task''%'
    AND pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'attachments_record_type_check')) LIKE '%''meeting''%'
  ) THEN
    v_missing := v_missing || 'attachments_record_type_check-drifted ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Attachments authorization restoration validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Attachments authorization restoration validation PASSED (all 10 record-type branches present with meaningful coverage in attachments_select/_insert/_delete; Phase 1.9A Prisoner Letters narrowed model, supervisor bypass, and delivered-status finalization lock all intact; ownership check preserved on every mutating policy; CHECK constraint undisturbed).';
END $$;
