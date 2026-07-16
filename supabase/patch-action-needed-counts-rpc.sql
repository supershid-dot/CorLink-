-- ─── Patch: server-side "needs my action" counts ────────────────
-- New RPC, requests_action_needed_counts() — see its own comment in
-- rls.sql for the full rationale. Replaces fetching the (already-capped)
-- inbox/sent/info-request lists into the browser just to run a JS
-- predicate over every row and count matches, with a single COUNT()-based
-- query evaluated in Postgres. Powers the Requests nav badge (every
-- page) and the Requests page's own Inbox/Sent/Info tab badges.
--
-- Idempotent: CREATE OR REPLACE FUNCTION. No RLS policy changes, no
-- schema changes — this is purely additive.

CREATE OR REPLACE FUNCTION requests_action_needed_counts()
RETURNS TABLE(inbox_count BIGINT, sent_count BIGINT, info_count BIGINT) AS $$
  SELECT
    (
      SELECT COUNT(*) FROM requests r
      WHERE r.to_org_id = get_my_org_id()
        AND (
          (
            (is_supervisor_or_above() OR has_role('assigned_receiver'))
            AND r.to_section_id IS NULL AND r.status IN ('sent', 'received')
          )
          OR (
            r.status = 'in_progress' AND r.to_section_id IS NOT NULL AND r.assigned_to IS NULL
            AND (is_admin() OR r.to_section_id IN (SELECT my_supervised_section_ids()))
          )
          OR (
            r.status = 'in_progress' AND r.assigned_to = auth.uid()
            AND NOT EXISTS (SELECT 1 FROM responses resp WHERE resp.request_id = r.id AND resp.status <> 'sent')
          )
          OR EXISTS (SELECT 1 FROM responses resp WHERE resp.request_id = r.id AND resp.status = 'draft' AND resp.created_by = auth.uid())
          OR (is_supervisor_or_above() AND EXISTS (SELECT 1 FROM responses resp WHERE resp.request_id = r.id AND resp.status = 'pending_approval'))
        )
    ) AS inbox_count,
    (
      SELECT COUNT(*) FROM requests r
      WHERE r.from_org_id = get_my_org_id()
        AND (
          (r.status = 'draft' AND r.created_by = auth.uid())
          OR (is_supervisor_or_above() AND r.status = 'pending_approval')
          OR (
            (is_supervisor_or_above() OR has_role('assigned_receiver'))
            AND EXISTS (SELECT 1 FROM responses resp WHERE resp.request_id = r.id AND resp.status = 'sent' AND resp.received_at IS NULL)
          )
          OR (is_supervisor_or_above() AND r.status = 'responded')
        )
    ) AS sent_count,
    (
      SELECT COUNT(*) FROM internal_requests ir
      WHERE ir.to_section_id IN (SELECT my_section_ids())
        AND ir.status IN ('sent', 'received', 'in_progress')
    ) AS info_count;
$$ LANGUAGE sql STABLE;
