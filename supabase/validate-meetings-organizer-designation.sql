-- ─── Validator: Meeting creator no longer forced into participant list ──
-- Run manually against a project AFTER
-- patch-meetings-organizer-designation.sql has been applied there.
-- Structural only (function-signature/body checks, no side effects) —
-- the actual create/add_participant/organizer-collision behavior is
-- already covered by the pre-existing meetings-frontend test suite
-- plus this session's own manual end-to-end pass on CorLink Staging.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- create_meeting() gained the trailing p_include_creator_as_participant
  -- parameter (default TRUE) and only inserts the creator as organizer
  -- when it's true.
  IF to_regprocedure('public.create_meeting(text,timestamptz,timestamptz,text,text,text,text,text,text,text,text,uuid,boolean,boolean)') IS NULL THEN
    v_missing := v_missing || 'create_meeting-new-signature-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_meeting(text,timestamptz,timestamptz,text,text,text,text,text,text,text,text,uuid,boolean,boolean)')) INTO v_def;
    IF v_def NOT ILIKE '%p_include_creator_as_participant boolean DEFAULT true%' THEN
      v_missing := v_missing || 'create_meeting-missing-default-true ';
    END IF;
    IF v_def NOT ILIKE '%IF p_include_creator_as_participant THEN%' THEN
      v_missing := v_missing || 'create_meeting-missing-conditional-guard ';
    END IF;
  END IF;

  -- create_recurring_meeting() gained the same trailing parameter and
  -- passes it straight through to its internal create_meeting() call.
  IF to_regprocedure('public.create_recurring_meeting(text,date,date,time without time zone,time without time zone,text,text,text,text,text,text,text,text,uuid,uuid,integer,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'create_recurring_meeting-new-signature-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_recurring_meeting(text,date,date,time without time zone,time without time zone,text,text,text,text,text,text,text,text,uuid,uuid,integer,uuid,boolean)')) INTO v_def;
    IF v_def NOT ILIKE '%p_include_creator_as_participant := p_include_creator_as_participant%' THEN
      v_missing := v_missing || 'create_recurring_meeting-does-not-pass-through ';
    END IF;
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-meetings-organizer-designation FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-meetings-organizer-designation: all checks passed';
END $$;
