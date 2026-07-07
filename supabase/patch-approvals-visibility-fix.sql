-- ─── Patch: approvals_select visibility fix ────────────────────
-- approvals_select previously only let the reviewer themselves, any
-- org's admin (unscoped — a bug in the OTHER direction), or the
-- record's literal creator see an approval row. That hid the
-- "approved by [Supervisor Name]" banner (request-detail.js's
-- _renderApprovalHistory) from everyone else who can otherwise see the
-- request/response itself — most importantly, the RECEIVING
-- organization's supervisors/section members, who are never the
-- request's own creator. Rewritten to mirror requests_select/
-- responses_select's exact visibility shape.
-- Idempotent — safe to run more than once.

BEGIN;

DROP POLICY IF EXISTS "approvals_select" ON approvals;
CREATE POLICY "approvals_select" ON approvals
  FOR SELECT USING (
    reviewed_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR re.created_by     = auth.uid()
          OR re.received_by    = auth.uid()
        )
    ))
  );

COMMIT;
