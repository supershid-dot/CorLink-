-- ─── Patch: Internal Collaboration for Entry (polymorphic parent) ──
-- Generalizes internal_requests/internal_request_replies to be
-- anchored to EITHER an external request (parent_request_id, as
-- before) OR an Entry case (new parent_entry_id, external_correspondence)
-- — the receiving section on an Entry item can now ask another section
-- for information while keeping ownership of the entry itself, exactly
-- like "Loop in a Section" already works for requests.
--
-- Two real bugs were caught and fixed here rather than shipped and
-- found later:
-- 1. internal_request_replies_insert/_update INNER JOINed requests —
--    once parent_request_id can be NULL (entry-anchored rows), that
--    join matches zero rows, silently blocking every reply to an
--    entry-anchored internal request. Fixed by routing the check
--    through internal_requests_parent_not_frozen() instead.
-- 2. A section looped in via an entry-anchored internal_requests row
--    had no RLS path to see the parent external_correspondence row
--    itself — the exact gap patch-internal-collab-request-visibility.sql
--    already fixed on the requests side. Mirrored here.
--
-- Idempotent — safe to run more than once.

BEGIN;

-- 1. Schema: nullable parent_request_id + new parent_entry_id + the
--    exactly-one-parent invariant.
ALTER TABLE internal_requests ALTER COLUMN parent_request_id DROP NOT NULL;
ALTER TABLE internal_requests ADD COLUMN IF NOT EXISTS parent_entry_id UUID REFERENCES external_correspondence(id);

ALTER TABLE internal_requests DROP CONSTRAINT IF EXISTS internal_requests_one_parent;
ALTER TABLE internal_requests ADD CONSTRAINT internal_requests_one_parent CHECK (
  (parent_request_id IS NOT NULL AND parent_entry_id IS NULL) OR
  (parent_request_id IS NULL AND parent_entry_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_internal_requests_parent_entry ON internal_requests(parent_entry_id) WHERE parent_entry_id IS NOT NULL;

DROP INDEX IF EXISTS idx_internal_requests_parent;
CREATE INDEX idx_internal_requests_parent ON internal_requests(parent_request_id) WHERE parent_request_id IS NOT NULL;

-- 2. Three helpers centralizing the parent-type branching.
CREATE OR REPLACE FUNCTION internal_requests_parent_startable(p_parent_request_id UUID, p_parent_entry_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (p_parent_request_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_parent_request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND r.status NOT IN ('cancelled', 'closed', 'responded')
    ))
    OR (p_parent_entry_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = p_parent_entry_id
        AND ec.org_id = get_my_org_id()
        AND ec.status NOT IN ('closed', 'responded')
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION internal_requests_parent_not_frozen(p_parent_request_id UUID, p_parent_entry_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (p_parent_request_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_parent_request_id AND r.status <> 'cancelled'
    ))
    OR (p_parent_entry_id IS NOT NULL);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION internal_requests_parent_deadline_ok(p_parent_request_id UUID, p_parent_entry_id UUID, p_deadline TIMESTAMPTZ)
RETURNS BOOLEAN AS $$
  SELECT
    p_deadline IS NULL
    OR (p_parent_request_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_parent_request_id
        AND r.deadline IS NOT NULL AND p_deadline > r.deadline
    ))
    OR (p_parent_entry_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = p_parent_entry_id
        AND ec.deadline IS NOT NULL AND p_deadline::date > ec.deadline
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 3. internal_requests_insert / internal_requests_update: route the
--    parent-status/deadline checks through the helpers above.
DROP POLICY IF EXISTS "internal_requests_insert" ON internal_requests;
CREATE POLICY "internal_requests_insert" ON internal_requests
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND (
      from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND scope_org_id('section', from_section_id) = get_my_org_id())
    )
    AND scope_org_id('section', to_section_id) = get_my_org_id()
    AND internal_requests_parent_startable(internal_requests.parent_request_id, internal_requests.parent_entry_id)
    AND internal_requests_parent_deadline_ok(internal_requests.parent_request_id, internal_requests.parent_entry_id, internal_requests.deadline)
  );

DROP POLICY IF EXISTS "internal_requests_update" ON internal_requests;
CREATE POLICY "internal_requests_update" ON internal_requests
  FOR UPDATE USING (
    (
      to_section_id IN (SELECT my_section_ids())
      OR from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
    )
    AND internal_requests_parent_not_frozen(internal_requests.parent_request_id, internal_requests.parent_entry_id)
  )
  WITH CHECK (
    (
      to_section_id IN (SELECT my_section_ids())
      OR from_section_id IN (SELECT my_section_ids())
      OR previous_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
    )
    AND internal_requests_parent_not_frozen(internal_requests.parent_request_id, internal_requests.parent_entry_id)
  );

-- 4. internal_request_replies_insert / _update: Bug #1 fix — replace
--    the inline JOIN to requests (which would match zero rows for an
--    entry-anchored parent) with the helper.
DROP POLICY IF EXISTS "internal_request_replies_insert" ON internal_request_replies;
CREATE POLICY "internal_request_replies_insert" ON internal_request_replies
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = internal_request_id
        AND ir.to_section_id IN (SELECT my_section_ids())
        AND internal_requests_parent_not_frozen(ir.parent_request_id, ir.parent_entry_id)
    )
  );

DROP POLICY IF EXISTS "internal_request_replies_update" ON internal_request_replies;
CREATE POLICY "internal_request_replies_update" ON internal_request_replies
  FOR UPDATE USING (
    (
      (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
      OR EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
          AND is_supervisor_or_above()
          AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      )
    )
    AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = internal_request_id
        AND internal_requests_parent_not_frozen(ir.parent_request_id, ir.parent_entry_id)
    )
  )
  WITH CHECK (
    (
      (created_by = auth.uid() AND status IN ('draft', 'pending_approval'))
      OR EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = internal_request_id
          AND is_supervisor_or_above()
          AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      )
    )
    AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = internal_request_id
        AND internal_requests_parent_not_frozen(ir.parent_request_id, ir.parent_entry_id)
    )
  );

-- 5. Bug #2 fix — a section looped in via an entry-anchored
--    internal_requests row can now see the parent external_correspondence
--    row (mirrors patch-internal-collab-request-visibility.sql on the
--    requests side exactly).
CREATE OR REPLACE FUNCTION looped_in_via_internal_collab_entry(p_entry_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.parent_entry_id = p_entry_id
      AND ir.to_section_id IN (SELECT my_section_ids())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "external_correspondence_select_via_internal_collab" ON external_correspondence;
CREATE POLICY "external_correspondence_select_via_internal_collab" ON external_correspondence
  FOR SELECT USING (looped_in_via_internal_collab_entry(external_correspondence.id));

COMMIT;
