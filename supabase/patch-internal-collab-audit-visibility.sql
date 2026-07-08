-- ─── Patch: Internal Collaboration full routing history ────────
-- reroute() (js/data/internal-requests-api.js) fully resets one
-- internal_requests row's received_by/received_at/assigned_to on
-- every re-route ("exactly like a fresh arrival") — so after a
-- section passes a loop-in request on to another section, the
-- earlier section's own receipt is gone from the row's current
-- state. logAudit() already writes 'received'/'routed'/'assigned'
-- entries at every step, so the full history was never actually
-- lost — but can_view_case_audit_record() (the function
-- audit_select_own_records relies on) had no branch at all for
-- record_type = 'internal_request', so request-detail.js's new
-- internal-collaboration timeline query would have silently
-- returned ZERO rows for everyone, including the internal
-- request's own creator/section members.
--
-- Idempotent — safe to run more than once.

BEGIN;

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
    -- Mirrors internal_requests_select's own visibility conditions —
    -- reroute() (js/data/internal-requests-api.js) resets one row's
    -- received_by/received_at/assigned_to on every re-route, so the
    -- audit trail is the only place the full received-then-routed-
    -- then-received-again history survives; request-detail.js's
    -- internal collaboration panel needs it visible to the same
    -- audience that can already see the internal_request itself, not
    -- just org admins (the base audit_select policy above).
    OR (p_record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = p_record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

COMMIT;
