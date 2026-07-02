-- ============================================================
-- CorLink — Patch: requests workflow overhaul
--
-- Run this INSTEAD of re-running the full schema.sql/rls.sql/
-- storage-policies.sql. Adds:
--   - Two-step receive-then-route with visible read receipts
--     ("received by [Name], [Designation] — [time]") on requests
--     and responses.
--   - assigned_to on requests (who's preparing the reply), mirroring
--     the existing prisoner_letters.assigned_to pattern.
--   - internal_requests / internal_request_replies — org-only
--     collaboration between sections (loop in extra sections, or
--     gather supporting info while drafting a reply) that the other
--     org in the conversation can never see.
--   - conversation_request_ids() RPC — walks parent_request_id both
--     directions so a multi-round-trip "case" renders as one thread.
--   - Finally gives the previously-decorative assigned_receiver role
--     real permissions: org-level assigned_receiver can act on their
--     org's unrouted inbox; section-level assigned_receiver (via the
--     previously-unreferenced has_role_in_section() helper) can set
--     assigned_to once a request is routed to their section.
--   - Fixes a pre-existing gap: responses_select had no section-
--     membership restriction at all (any org member could read every
--     response on a request, unlike requests_select).
--   - attachments storage bucket policies (the `attachments` TABLE
--     already had RLS from Phase 3, but the Storage bucket itself
--     never got any storage.objects policies, so uploads/downloads
--     were never actually usable until now).
-- ============================================================

BEGIN;

-- ── Schema ──────────────────────────────────────────────────────
ALTER TABLE requests  ADD COLUMN IF NOT EXISTS assigned_to  UUID REFERENCES users(id);
ALTER TABLE requests  ADD COLUMN IF NOT EXISTS received_by  UUID REFERENCES users(id);
ALTER TABLE requests  ADD COLUMN IF NOT EXISTS received_at  TIMESTAMPTZ;
ALTER TABLE responses ADD COLUMN IF NOT EXISTS received_by  UUID REFERENCES users(id);
ALTER TABLE responses ADD COLUMN IF NOT EXISTS received_at  TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS internal_requests (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_request_id UUID        NOT NULL REFERENCES requests(id),
  from_section_id   UUID        NOT NULL REFERENCES sections(id),
  to_section_id     UUID        NOT NULL REFERENCES sections(id),
  created_by        UUID        NOT NULL REFERENCES users(id),
  subject           TEXT        NOT NULL,
  body              TEXT        NOT NULL,
  language          TEXT        NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'dv')),
  status            TEXT        NOT NULL DEFAULT 'sent' CHECK (status IN (
                       'sent', 'received', 'responded', 'closed'
                     )),
  received_by       UUID        REFERENCES users(id),
  received_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS internal_request_replies (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  internal_request_id UUID        NOT NULL REFERENCES internal_requests(id),
  body                TEXT        NOT NULL,
  created_by          UUID        NOT NULL REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN ('request', 'response', 'prisoner_letter', 'internal_request'));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment'
  ));

ALTER TABLE internal_requests        ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal_request_replies ENABLE ROW LEVEL SECURITY;

-- ── RLS: fix pre-existing responses_select gap ──────────────────
DROP POLICY IF EXISTS "responses_select" ON responses;
CREATE POLICY "responses_select" ON responses
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR created_by        = auth.uid()
        )
    )
  );

-- ── RLS: assigned_receiver gets real permissions ────────────────
DROP POLICY IF EXISTS "requests_select_assigned_receiver" ON requests;
CREATE POLICY "requests_select_assigned_receiver" ON requests
  FOR SELECT USING (
    to_org_id = get_my_org_id() AND to_section_id IS NULL AND has_role('assigned_receiver')
  );

-- WITH CHECK is required on all three below, not optional hygiene:
-- without it Postgres reuses the USING expression against the
-- POST-update row, and the actual updates these policies exist to
-- allow (routing sets to_section_id; marking a response received sets
-- received_by) make the bare USING conditions false afterwards, so
-- every real call would self-reject.
DROP POLICY IF EXISTS "requests_update_assigned_receiver" ON requests;
CREATE POLICY "requests_update_assigned_receiver" ON requests
  FOR UPDATE USING (
    to_org_id = get_my_org_id() AND to_section_id IS NULL AND has_role('assigned_receiver')
  )
  WITH CHECK (
    to_org_id = get_my_org_id() AND has_role('assigned_receiver')
  );

DROP POLICY IF EXISTS "requests_update_section_receiver" ON requests;
CREATE POLICY "requests_update_section_receiver" ON requests
  FOR UPDATE USING (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  )
  WITH CHECK (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  );

DROP POLICY IF EXISTS "responses_update_assigned_receiver" ON responses;
CREATE POLICY "responses_update_assigned_receiver" ON responses
  FOR UPDATE USING (
    has_role('assigned_receiver') AND status = 'sent' AND received_by IS NULL
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = request_id AND r.from_org_id = get_my_org_id())
  )
  WITH CHECK (
    has_role('assigned_receiver')
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = request_id AND r.from_org_id = get_my_org_id())
  );

-- ── RLS: internal_requests / internal_request_replies ───────────
DROP POLICY IF EXISTS "internal_requests_select" ON internal_requests;
CREATE POLICY "internal_requests_select" ON internal_requests
  FOR SELECT USING (
    from_section_id IN (SELECT my_section_ids())
    OR to_section_id IN (SELECT my_section_ids())
    OR created_by = auth.uid()
    OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
  );

DROP POLICY IF EXISTS "internal_requests_insert" ON internal_requests;
CREATE POLICY "internal_requests_insert" ON internal_requests
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND (
      from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND scope_org_id('section', from_section_id) = get_my_org_id())
    )
    AND scope_org_id('section', to_section_id) = get_my_org_id()
    AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = parent_request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
  );

DROP POLICY IF EXISTS "internal_requests_update" ON internal_requests;
CREATE POLICY "internal_requests_update" ON internal_requests
  FOR UPDATE USING (
    to_section_id IN (SELECT my_section_ids())
    OR from_section_id IN (SELECT my_section_ids())
    OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
  );

DROP POLICY IF EXISTS "internal_request_replies_select" ON internal_request_replies;
CREATE POLICY "internal_request_replies_select" ON internal_request_replies
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    )
  );

DROP POLICY IF EXISTS "internal_request_replies_insert" ON internal_request_replies;
CREATE POLICY "internal_request_replies_insert" ON internal_request_replies
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
        AND ir.to_section_id IN (SELECT my_section_ids())
    )
  );

-- ── RLS: attachments — internal_request branch + delete policy ──
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
  );

DROP POLICY IF EXISTS "attachments_delete" ON attachments;
CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE USING (uploaded_by = auth.uid());

-- ── RPC: conversation threading ──────────────────────────────────
-- Deliberately NOT SECURITY DEFINER — see supabase/rls.sql for why.
-- visited arrays guard against a cyclic parent_request_id chain
-- spinning this CTE forever — see supabase/rls.sql for why.
CREATE OR REPLACE FUNCTION conversation_request_ids(p_request_id UUID)
RETURNS SETOF UUID AS $$
  WITH RECURSIVE ancestors AS (
    SELECT id, parent_request_id, 0 AS depth, ARRAY[id] AS visited FROM requests WHERE id = p_request_id
    UNION ALL
    SELECT r.id, r.parent_request_id, a.depth + 1, a.visited || r.id
    FROM requests r JOIN ancestors a ON r.id = a.parent_request_id
    WHERE NOT (r.id = ANY(a.visited))
  ),
  root AS (SELECT id FROM ancestors ORDER BY depth DESC LIMIT 1),
  descendants AS (
    SELECT id, ARRAY[id] AS visited FROM root
    UNION ALL
    SELECT r.id, d.visited || r.id
    FROM requests r JOIN descendants d ON r.parent_request_id = d.id
    WHERE NOT (r.id = ANY(d.visited))
  )
  SELECT id FROM descendants;
$$ LANGUAGE sql STABLE;

-- ── Storage: attachments bucket ──────────────────────────────────
-- Create the `attachments` bucket first via Supabase Dashboard ->
-- Storage -> New bucket (private) if it doesn't already exist.
DROP POLICY IF EXISTS "attachments_storage_select" ON storage.objects;
CREATE POLICY "attachments_storage_select" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'attachments'
    AND EXISTS (SELECT 1 FROM attachments a WHERE a.storage_path = storage.objects.name)
  );

DROP POLICY IF EXISTS "attachments_storage_insert" ON storage.objects;
CREATE POLICY "attachments_storage_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attachments'
    AND owner = auth.uid()
    AND (storage.foldername(name))[1] IN ('request', 'response', 'internal_request')
  );

DROP POLICY IF EXISTS "attachments_storage_delete" ON storage.objects;
CREATE POLICY "attachments_storage_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'attachments' AND owner = auth.uid());

COMMIT;
