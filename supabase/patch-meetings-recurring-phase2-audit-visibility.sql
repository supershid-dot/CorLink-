-- ─── Patch: Recurring Meetings Phase 2 — series audit visibility ──
-- fetchSeriesAuditTrail() (js/data/meetings-api.js) reads
-- record_type='meeting_series' rows written by update_entire_series()/
-- update_series_this_and_future()/cancel_entire_series()/cancel_series_
-- this_and_future() (supabase/patch-meetings-recurring-phase2-*.sql).
-- can_view_case_audit_record() — the function audit_select_own_records
-- relies on — had no branch at all for record_type = 'meeting_series',
-- so those rows were silently invisible to everyone except org admins
-- (the base admin-only audit_select policy), including the series'
-- own creator and the supervisor who manages it.
--
-- Deliberately NOT calling can_manage_series() (patch-meetings-
-- recurring-phase2-series-auth.sql) here: that function is PL/pgSQL
-- and RAISE EXCEPTIONs for an unauthenticated caller by design — its
-- own header comment documents itself as "not referenced by any RLS
-- policy" specifically so that a hard exception never breaks a policy
-- evaluation. can_view_case_audit_record() IS referenced by an RLS
-- policy (audit_select_own_records), so introducing that call here
-- would reintroduce exactly the hard-exception risk that comment warns
-- against. Instead, the same three-tier decision can_manage_series()
-- makes (super admin / series creator / same-org supervisor-or-above)
-- is inlined in the same exception-free plain-SQL shape
-- can_manage_meeting() already uses safely inside RLS-composable
-- functions. A fourth, additive branch extends visibility to anyone
-- who can already view at least one occurrence in the series under
-- can_view_meeting()'s existing, unmodified rules (creator, active
-- participant, org supervisor, or organization-wide visibility with
-- the module enabled) — the same audience that can see a meeting's own
-- page can also see what changed about its series.
--
-- Organization-scoped throughout: the supervisor branch requires
-- s.organization_id = get_my_org_id(); can_view_meeting() is itself
-- already org-scoped in every non-super-admin branch. No cross-
-- organization access is introduced.
--
-- Read-only visibility change. Does not touch audit insertion, audit
-- row structure, any recurring-series RPC, or the frontend.
--
-- Requires patch-meetings-recurring.sql (meeting_series exists) and
-- patch-meetings-foundation.sql (can_view_meeting() exists) already
-- applied.
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
    ))
    -- Mirrors external_correspondence_select's own visibility shape —
    -- entry-detail.js's timeline needs "routed to X by Y at [time]"
    -- visible to the same audience that can see the entry itself.
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
    ))
    -- New branch (this patch) — see header comment above for the full
    -- rationale, particularly why can_manage_series() is deliberately
    -- NOT called from here.
    OR (p_record_type = 'meeting_series' AND EXISTS (
      SELECT 1 FROM meeting_series s
      WHERE s.id = p_record_id
        AND (
          is_super_admin()
          OR s.created_by = auth.uid()
          OR (s.organization_id = get_my_org_id() AND is_supervisor_or_above())
          OR EXISTS (
            SELECT 1 FROM meetings m
            WHERE m.series_id = s.id AND can_view_meeting(m.id)
          )
        )
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

COMMIT;
