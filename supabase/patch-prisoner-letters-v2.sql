-- ─── Patch: Prisoner Letters v2 ─────────────────────────────────
-- Prisoner registry (searchable dropdown source), read receipts,
-- per-letter reference numbers, and file attachments on replies.
-- Idempotent — safe to run more than once.

BEGIN;

-- 1. Prisoner registry. Letters keep their legacy prisoner_id/
--    prisoner_name TEXT columns for old rows; new letters also link
--    prisoner_ref -> prisoners(id).
CREATE TABLE IF NOT EXISTS prisoners (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          UUID        NOT NULL REFERENCES organizations(id),
  file_number     TEXT        NOT NULL,          -- e.g. 1-2026
  id_card_number  TEXT        NOT NULL,          -- e.g. A000000
  full_name       TEXT        NOT NULL,
  address         TEXT        NOT NULL,
  prison          TEXT        NOT NULL CHECK (prison IN (
                    'Maafushi Prison', 'Asseyri Prison', 'Hulhumale Prison'
                  )),
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, file_number)
);

ALTER TABLE prisoners ENABLE ROW LEVEL SECURITY;

-- The registry belongs to MCS: only members of the owning org see or
-- manage it. The counterpart authority never needs the registry — the
-- letter row itself carries the prisoner's name/details.
DROP POLICY IF EXISTS "prisoners_select" ON prisoners;
CREATE POLICY "prisoners_select" ON prisoners
  FOR SELECT USING (org_id = get_my_org_id());

DROP POLICY IF EXISTS "prisoners_insert" ON prisoners;
CREATE POLICY "prisoners_insert" ON prisoners
  FOR INSERT WITH CHECK (org_id = get_my_org_id());

DROP POLICY IF EXISTS "prisoners_update" ON prisoners;
CREATE POLICY "prisoners_update" ON prisoners
  FOR UPDATE USING (org_id = get_my_org_id())
  WITH CHECK (org_id = get_my_org_id());

-- 2. Letters: prisoner link + read receipt (same received_by/received_at
--    pattern as requests/responses).
ALTER TABLE prisoner_letters ADD COLUMN IF NOT EXISTS prisoner_ref UUID REFERENCES prisoners(id);
ALTER TABLE prisoner_letters ADD COLUMN IF NOT EXISTS received_by  UUID REFERENCES users(id);
ALTER TABLE prisoner_letters ADD COLUMN IF NOT EXISTS received_at  TIMESTAMPTZ;

-- 3. Per-letter reference numbers: PL-{ORG}-{YEAR}-{SEQ}, own per-org
--    per-year counter (letters have no from-section, so the section-
--    keyed reference_sequences table doesn't fit them).
CREATE TABLE IF NOT EXISTS letter_reference_sequences (
  org_id        UUID    NOT NULL REFERENCES organizations(id),
  year          INTEGER NOT NULL,
  next_sequence INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (org_id, year)
);
ALTER TABLE letter_reference_sequences ENABLE ROW LEVEL SECURITY;
-- No direct policies: only the SECURITY DEFINER function below touches it.

CREATE OR REPLACE FUNCTION generate_prisoner_letter_reference(p_org_id UUID)
RETURNS TEXT AS $$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq  INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO letter_reference_sequences (org_id, year, next_sequence)
  VALUES (p_org_id, v_year, 2)
  ON CONFLICT (org_id, year)
  DO UPDATE SET next_sequence = letter_reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT code INTO v_code FROM organizations WHERE id = p_org_id;
  RETURN 'PL-' || COALESCE(v_code, 'ORG') || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Attachments on replies too (letters were already in the CHECK).
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN ('request', 'response', 'prisoner_letter', 'internal_request', 'prisoner_reply'));

-- 5. attachments_select/insert previously had NO prisoner_letter/
--    prisoner_reply branches — letter attachments were only visible to
--    their uploader or supervisors. New branches mirror
--    prisoner_letters_select's own access shape.
DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR is_supervisor_or_above()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (record_type = 'prisoner_letter' AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
             OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
             OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
  );

DROP POLICY IF EXISTS "attachments_insert" ON attachments;
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
               OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pr.replied_by = auth.uid() OR pl.to_org_id = get_my_org_id())
      ))
    )
  );

-- 6. Storage: allow the two new upload folder prefixes.
DROP POLICY IF EXISTS "attachments_storage_insert" ON storage.objects;
CREATE POLICY "attachments_storage_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attachments'
    AND owner = auth.uid()
    AND (storage.foldername(name))[1] IN ('request', 'response', 'internal_request', 'prisoner_letter', 'prisoner_reply')
  );

COMMIT;
