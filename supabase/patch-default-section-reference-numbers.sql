-- ============================================================
-- CorLink — Patch: default receiving section, configurable
-- reference number format, response reference numbers
--
-- Run this INSTEAD of re-running the full schema.sql/rls.sql.
--
-- Part 1 — organizations.default_receiving_section_id
-- Incoming external requests still land in the org-wide unrouted pool
-- (requests.to_section_id stays NULL until routed, unchanged) — this
-- column narrows WHO can see/act on that pool from "any assigned_
-- receiver anywhere in the org" down to "an assigned_receiver
-- specifically in the org's designated front-desk section", once an
-- admin sets one. NULL (the default — nothing changes for an org that
-- doesn't touch this) falls back to the original org-wide behavior.
--
-- Part 2 — organizations.reference_number_format
-- Org-admin-configurable template (tokens {ORG}/{SECTION}/{YEAR}/{SEQ}),
-- defaulting to the original hardcoded shape so nothing changes for an
-- org that doesn't touch it.
--
-- Part 3 — responses.reference_number
-- Responses now get their own reference number, generated the same
-- way as requests but always "RES-" prefixed (so a request and its
-- response can never look like the same document) and tracked on its
-- own per-section-per-year sequence (reference_sequences.record_type).
--
-- Part 4 — generate_reference_number() signature change
-- Old: generate_reference_number(uuid). New: generate_reference_number
-- (uuid, text DEFAULT 'request'). These are different overloads to
-- Postgres, so the old one is explicitly DROPped first — otherwise
-- both would exist afterward and every existing call would fail with
-- "function ... is not unique".
--
-- Part 5 — orgs_update RLS widened
-- Previously super_admin-only; now also lets an org's own admin
-- (mcs_admin/authority_admin) update their own organization row, which
-- is what lets them set the two new columns above from js/views/admin.js.
--
-- Part 6 — assigned_receiver visibility scoped to the default section
-- requests_select_assigned_receiver / requests_update_assigned_receiver
-- now check is_default_section_receiver(to_org_id) instead of a bare
-- has_role('assigned_receiver') — see that function's comment below.
--
-- Part 7 — requests_select gains a received_by clause
-- Load-bearing, not just a nice-to-have: Postgres requires an UPDATE's
-- resulting row to remain visible under the table's SELECT policy for
-- every UPDATE, not only when RETURNING/.select() is used. A default-
-- section assigned_receiver who marks a request received and then
-- routes it to a DIFFERENT section they hold no assignment in would
-- otherwise have routeRequest() fail with "new row violates row-level
-- security policy" the moment to_section_id no longer matches their
-- own sections. Confirmed empirically against a real Postgres
-- instance. Also a reasonable feature on its own: whoever formally
-- received a request keeps permanent visibility into it, mirroring
-- the "Received by [Name]" read-receipt already shown in the UI.
-- ============================================================

BEGIN;

-- ── Part 1 ──────────────────────────────────────────────────
ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS default_receiving_section_id UUID REFERENCES sections(id);

-- ── Part 2 ──────────────────────────────────────────────────
ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS reference_number_format TEXT NOT NULL DEFAULT '{ORG}-{SECTION}-{YEAR}-{SEQ}';

-- ── Part 3 ──────────────────────────────────────────────────
ALTER TABLE responses
  ADD COLUMN IF NOT EXISTS reference_number TEXT UNIQUE;

ALTER TABLE reference_sequences
  ADD COLUMN IF NOT EXISTS record_type TEXT NOT NULL DEFAULT 'request' CHECK (record_type IN ('request', 'response'));

ALTER TABLE reference_sequences DROP CONSTRAINT IF EXISTS reference_sequences_section_id_year_key;

-- Postgres has no ADD CONSTRAINT IF NOT EXISTS — guard manually so this
-- patch stays safe to re-run, same as every ADD COLUMN IF NOT EXISTS above.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'reference_sequences_section_id_year_record_type_key'
  ) THEN
    ALTER TABLE reference_sequences ADD CONSTRAINT reference_sequences_section_id_year_record_type_key
      UNIQUE (section_id, year, record_type);
  END IF;
END $$;

-- ── Part 4 ──────────────────────────────────────────────────
DROP FUNCTION IF EXISTS generate_reference_number(UUID);

CREATE OR REPLACE FUNCTION generate_reference_number(p_section_id UUID, p_record_type TEXT DEFAULT 'request')
RETURNS TEXT AS $$
DECLARE
  v_year     INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq      INTEGER;
  v_org_code TEXT;
  v_sec_code TEXT;
  v_format   TEXT;
  v_result   TEXT;
BEGIN
  INSERT INTO reference_sequences (section_id, year, record_type, next_sequence)
  VALUES (p_section_id, v_year, p_record_type, 2)
  ON CONFLICT (section_id, year, record_type)
  DO UPDATE SET next_sequence = reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT o.code, s.code, o.reference_number_format
  INTO v_org_code, v_sec_code, v_format
  FROM sections s
  JOIN organizations o ON o.id = s.org_id
  WHERE s.id = p_section_id;

  v_result := replace(v_format, '{ORG}', v_org_code);
  v_result := replace(v_result, '{SECTION}', v_sec_code);
  v_result := replace(v_result, '{YEAR}', v_year::TEXT);
  v_result := replace(v_result, '{SEQ}', LPAD(v_seq::TEXT, 4, '0'));

  IF p_record_type = 'response' THEN
    v_result := 'RES-' || v_result;
  END IF;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── Part 5 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS "orgs_update" ON organizations;
CREATE POLICY "orgs_update" ON organizations
  FOR UPDATE USING (is_super_admin() OR (is_admin() AND id = get_my_org_id()))
  WITH CHECK (is_super_admin() OR (is_admin() AND id = get_my_org_id()));

-- ── Part 6 ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION is_default_section_receiver(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT CASE
    WHEN (SELECT default_receiving_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
      THEN has_role_in_section((SELECT default_receiving_section_id FROM organizations WHERE id = p_org_id), 'assigned_receiver')
    ELSE has_role('assigned_receiver')
  END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "requests_select_assigned_receiver" ON requests;
CREATE POLICY "requests_select_assigned_receiver" ON requests
  FOR SELECT USING (
    to_org_id = get_my_org_id() AND to_section_id IS NULL AND is_default_section_receiver(to_org_id)
  );

DROP POLICY IF EXISTS "requests_update_assigned_receiver" ON requests;
CREATE POLICY "requests_update_assigned_receiver" ON requests
  FOR UPDATE USING (
    to_org_id = get_my_org_id() AND to_section_id IS NULL AND is_default_section_receiver(to_org_id)
  )
  WITH CHECK (
    to_org_id = get_my_org_id() AND is_default_section_receiver(to_org_id)
  );

-- ── Part 7 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS "requests_select" ON requests;
CREATE POLICY "requests_select" ON requests
  FOR SELECT USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND (
      is_supervisor_or_above()
      OR from_section_id IN (SELECT my_section_ids())
      OR to_section_id   IN (SELECT my_section_ids())
      OR created_by      = auth.uid()
      OR received_by      = auth.uid()
    )
  );

COMMIT;
