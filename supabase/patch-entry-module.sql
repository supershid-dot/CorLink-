-- ─── Patch: Entry Module (External Correspondence) ──────────────
-- New module for requests/letters/complaints that arrive from OUTSIDE
-- the CorLink network entirely: the general public and prisoners'
-- families writing to info@corrections.gov.mv or by post, other
-- government offices that are NOT registered CorLink organizations,
-- and written complaints prisoners hand in directly to an internal
-- section. None of these senders have a CorLink organization/account,
-- so unlike `requests` (which assumes both sides ARE registered orgs)
-- this is its own table. A staff member in the org's designated Entry
-- section logs what arrived, then routes it to whichever internal
-- section is responsible for responding.
--
-- Idempotent — safe to run more than once.

BEGIN;

-- 1. Org-level designation: which section (if any) logs external
--    correspondence, same never-breaks-on-upgrade shape as
--    default_receiving_section_id / prisoner_registry_section_id.
ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS entry_section_id UUID REFERENCES sections(id);

CREATE OR REPLACE FUNCTION is_entry_staff(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (get_my_org_id() = p_org_id AND is_supervisor_or_above())
    OR CASE
      WHEN (SELECT entry_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
        THEN (SELECT entry_section_id FROM organizations WHERE id = p_org_id) IN (SELECT my_section_ids())
      ELSE get_my_org_id() = p_org_id
    END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Let an org's own admin configure entry_section_id through the same
-- RPC used for default_receiving_section_id / prisoner_registry_section_id.
-- Must DROP the old 4-arg signature first — CREATE OR REPLACE cannot
-- add a parameter to an existing function, it would just create a
-- second overload and leave the old one callable.
DROP FUNCTION IF EXISTS update_org_workflow_settings(UUID, UUID, TEXT, UUID);

CREATE OR REPLACE FUNCTION update_org_workflow_settings(
  p_org_id UUID,
  p_default_receiving_section_id UUID,
  p_reference_number_format TEXT,
  p_prisoner_registry_section_id UUID DEFAULT NULL,
  p_entry_section_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  IF NOT (is_super_admin() OR (is_admin() AND p_org_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to update this organization';
  END IF;

  IF p_default_receiving_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_default_receiving_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'default_receiving_section_id must belong to the target organization';
  END IF;

  IF p_prisoner_registry_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_prisoner_registry_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'prisoner_registry_section_id must belong to the target organization';
  END IF;

  IF p_entry_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_entry_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'entry_section_id must belong to the target organization';
  END IF;

  IF p_reference_number_format IS NULL OR trim(p_reference_number_format) = ''
     OR p_reference_number_format NOT LIKE '%{SEQ}%' THEN
    RAISE EXCEPTION 'reference_number_format must be non-empty and include the {SEQ} token';
  END IF;

  UPDATE organizations
  SET default_receiving_section_id = p_default_receiving_section_id,
      reference_number_format = p_reference_number_format,
      prisoner_registry_section_id = p_prisoner_registry_section_id,
      entry_section_id = p_entry_section_id
  WHERE id = p_org_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Core tables.
CREATE TABLE IF NOT EXISTS external_correspondence (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            UUID        NOT NULL REFERENCES organizations(id),
  source_channel    TEXT        NOT NULL CHECK (source_channel IN ('email', 'letter', 'in_person', 'phone', 'other')),
  sender_category   TEXT        NOT NULL CHECK (sender_category IN ('public', 'prisoner_family', 'external_office', 'prisoner_complaint')),
  sender_name       TEXT        NOT NULL,
  sender_contact    TEXT,
  external_office_name TEXT,
  prisoner_ref      UUID        REFERENCES prisoners(id),
  prisoner_name     TEXT,
  subject           TEXT        NOT NULL,
  subject_language  TEXT        NOT NULL DEFAULT 'en' CHECK (subject_language IN ('en', 'dv')),
  body              TEXT        NOT NULL,
  language          TEXT        NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  received_date     DATE        NOT NULL DEFAULT CURRENT_DATE,
  entered_by        UUID        NOT NULL REFERENCES users(id),
  to_section_id     UUID        REFERENCES sections(id),
  assigned_to       UUID        REFERENCES users(id),
  status            TEXT        NOT NULL DEFAULT 'logged' CHECK (status IN ('logged', 'routed', 'responded', 'closed')),
  deadline          DATE,
  reference_number  TEXT        UNIQUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS external_correspondence_replies (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id            UUID        NOT NULL REFERENCES external_correspondence(id),
  body                TEXT        NOT NULL,
  language            TEXT        NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status              TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'sent')),
  pending_approval_by UUID        REFERENCES users(id),
  approved_by         UUID        REFERENCES users(id),
  approved_at         TIMESTAMPTZ,
  delivery_method     TEXT        CHECK (delivery_method IN ('email', 'letter', 'in_person', 'phone', 'other')),
  sent_at             TIMESTAMPTZ,
  created_by          UUID        NOT NULL REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS entry_reference_sequences (
  org_id        UUID    NOT NULL REFERENCES organizations(id),
  year          INTEGER NOT NULL,
  next_sequence INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (org_id, year)
);

CREATE OR REPLACE FUNCTION generate_entry_reference(p_org_id UUID)
RETURNS TEXT AS $$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq  INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO entry_reference_sequences (org_id, year, next_sequence)
  VALUES (p_org_id, v_year, 2)
  ON CONFLICT (org_id, year)
  DO UPDATE SET next_sequence = entry_reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT code INTO v_code FROM organizations WHERE id = p_org_id;
  RETURN 'ENT-' || COALESCE(v_code, 'ORG') || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE INDEX IF NOT EXISTS idx_external_correspondence_org      ON external_correspondence(org_id);
CREATE INDEX IF NOT EXISTS idx_external_correspondence_section  ON external_correspondence(to_section_id) WHERE to_section_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_external_correspondence_status   ON external_correspondence(status);
CREATE INDEX IF NOT EXISTS idx_ec_replies_entry       ON external_correspondence_replies(entry_id);

DROP TRIGGER IF EXISTS set_updated_at ON external_correspondence;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON external_correspondence
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- 3. Server-side workflow transition enforcement, same pattern as
--    patch-workflow-transitions.sql.
CREATE OR REPLACE FUNCTION valid_entry_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('logged', 'routed'),
    ('routed', 'responded'),
    ('responded', 'closed')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_entry_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_entry_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid external_correspondence status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_entry_status ON external_correspondence;
CREATE TRIGGER check_entry_status BEFORE UPDATE OF status ON external_correspondence
  FOR EACH ROW EXECUTE FUNCTION trigger_check_entry_status();

CREATE OR REPLACE FUNCTION valid_entry_reply_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('draft', 'pending_approval'),
    ('pending_approval', 'sent'),
    ('pending_approval', 'draft')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_entry_reply_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_entry_reply_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid external_correspondence_replies status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_entry_reply_status ON external_correspondence_replies;
CREATE TRIGGER check_entry_reply_status BEFORE UPDATE OF status ON external_correspondence_replies
  FOR EACH ROW EXECUTE FUNCTION trigger_check_entry_reply_status();

-- 4. RLS.
ALTER TABLE entry_reference_sequences        ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_correspondence          ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_correspondence_replies  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "entry_refseq_select" ON entry_reference_sequences;
CREATE POLICY "entry_refseq_select" ON entry_reference_sequences
  FOR SELECT USING (is_admin());

DROP POLICY IF EXISTS "external_correspondence_select" ON external_correspondence;
CREATE POLICY "external_correspondence_select" ON external_correspondence
  FOR SELECT USING (
    org_id = get_my_org_id()
    AND (
      is_entry_staff(org_id)
      OR to_section_id IN (SELECT my_section_ids())
      OR assigned_to = auth.uid()
      OR entered_by  = auth.uid()
    )
  );

DROP POLICY IF EXISTS "external_correspondence_insert" ON external_correspondence;
CREATE POLICY "external_correspondence_insert" ON external_correspondence
  FOR INSERT WITH CHECK (
    entered_by = auth.uid()
    AND org_id = get_my_org_id()
    AND is_entry_staff(org_id)
  );

DROP POLICY IF EXISTS "external_correspondence_update_entry" ON external_correspondence;
CREATE POLICY "external_correspondence_update_entry" ON external_correspondence
  FOR UPDATE USING (org_id = get_my_org_id() AND is_entry_staff(org_id))
  WITH CHECK (org_id = get_my_org_id() AND is_entry_staff(org_id));

DROP POLICY IF EXISTS "external_correspondence_update_section" ON external_correspondence;
CREATE POLICY "external_correspondence_update_section" ON external_correspondence
  FOR UPDATE USING (to_section_id IN (SELECT my_section_ids()))
  WITH CHECK (to_section_id IN (SELECT my_section_ids()));

DROP POLICY IF EXISTS "external_correspondence_replies_select" ON external_correspondence_replies;
CREATE POLICY "external_correspondence_replies_select" ON external_correspondence_replies
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = entry_id
        AND (
          ec.to_section_id IN (SELECT my_section_ids())
          OR external_correspondence_replies.created_by = auth.uid()
          OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id))
          OR (
            external_correspondence_replies.status = 'sent'
            AND (is_entry_staff(ec.org_id) OR ec.entered_by = auth.uid())
          )
        )
    )
  );

DROP POLICY IF EXISTS "external_correspondence_replies_insert" ON external_correspondence_replies;
CREATE POLICY "external_correspondence_replies_insert" ON external_correspondence_replies
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = entry_id
        AND ec.to_section_id IN (SELECT my_section_ids())
    )
  );

DROP POLICY IF EXISTS "external_correspondence_replies_update" ON external_correspondence_replies;
CREATE POLICY "external_correspondence_replies_update" ON external_correspondence_replies
  FOR UPDATE USING (
    (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
    OR EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = entry_id
        AND is_supervisor_or_above()
        AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id)
    )
    OR (status = 'sent' AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = entry_id AND is_entry_staff(ec.org_id)
    ))
  )
  WITH CHECK (
    (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
    OR EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = entry_id
        AND is_supervisor_or_above()
        AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id)
    )
    OR (status = 'sent' AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = entry_id AND is_entry_staff(ec.org_id)
    ))
  );

-- 5. Extend can_view_case_audit_record so entry-detail.js's timeline
--    can show "routed to X by Y at [time]" to the same audience that
--    can see the entry itself (not just org admins).
CREATE OR REPLACE FUNCTION can_view_case_audit_record(p_record_type TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (p_record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp
      JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR resp.created_by   = auth.uid()
          OR resp.received_by  = auth.uid()
        )
    ))
    OR (p_record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = p_record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (p_record_type = 'external_correspondence' AND EXISTS (
      SELECT 1 FROM external_correspondence ec
      WHERE ec.id = p_record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_entry_staff(ec.org_id)
          OR ec.to_section_id IN (SELECT my_section_ids())
          OR ec.assigned_to = auth.uid()
          OR ec.entered_by  = auth.uid()
        )
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 6. Extend attachments / audit_logs / notifications CHECK constraints
--    and the attachments RLS branches for the two new record_types.
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN ('request', 'response', 'prisoner_letter', 'internal_request', 'prisoner_reply', 'internal_reply', 'external_correspondence', 'external_correspondence_reply'));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN ('request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension', 'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence'));

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN ('new_request', 'new_response', 'approval_requested', 'draft_returned', 'deadline_warning', 'extension_requested', 'extension_decided', 'new_prisoner_letter', 'letter_replied', 'new_external_correspondence', 'external_correspondence_replied'));

DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
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
          OR is_admin()
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
    OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr
      JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR irr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            irr.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    ))
    OR (record_type = 'external_correspondence' AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_entry_staff(ec.org_id)
          OR ec.to_section_id IN (SELECT my_section_ids())
          OR ec.assigned_to = auth.uid()
          OR ec.entered_by  = auth.uid()
        )
    ))
    OR (record_type = 'external_correspondence_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr
      JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND (
          ec.to_section_id IN (SELECT my_section_ids())
          OR ecr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id))
          OR (ecr.status = 'sent' AND (is_entry_staff(ec.org_id) OR ec.entered_by = auth.uid()))
        )
    ))
  );

DROP POLICY IF EXISTS "attachments_select_cc" ON attachments;
CREATE POLICY "attachments_select_cc" ON attachments
  FOR SELECT USING (
    record_type IN ('request', 'response') AND is_cc_recipient(record_type, record_id)
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
      OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
    )
  );

-- 7. Storage bucket folder allowlist (run supabase/storage-policies.sql
--    again, or apply just this INSERT policy change directly).
DROP POLICY IF EXISTS "attachments_storage_insert" ON storage.objects;
CREATE POLICY "attachments_storage_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attachments'
    AND owner = auth.uid()
    AND (storage.foldername(name))[1] IN ('request', 'response', 'internal_request', 'prisoner_letter', 'prisoner_reply', 'internal_reply', 'external_correspondence', 'external_correspondence_reply')
  );

COMMIT;
