-- ─── Patch: index the section-hierarchy lookups RLS depends on ──
-- Root cause behind "Couldn't load this request: canceling statement
-- due to statement timeout" recurring even after patch-missing-
-- indexes.sql: that patch narrowed the CANDIDATE ROWS a query has to
-- consider (e.g. which audit_logs rows match this case), but every
-- surviving row still pays the cost of Postgres re-evaluating the RLS
-- USING clause against it — and several of the RLS helper functions
-- (my_section_ids/my_supervised_section_ids/has_role_in_section, all
-- in supabase/rls.sql) ultimately call scope_section_ids() to expand a
-- command/department/division/organization-level assignment down to
-- its concrete active sections.
--
-- scope_section_ids() had no index to seek by department_id/
-- division_id/org_id, so any assignment NOT scoped directly at the
-- 'section' level (a supervisor over a whole department, or the very
-- common org-wide admin assignment — see update_org_workflow_settings's
-- comment on why admin grants are scoped at 'organization') forced a
-- sequential scan of the entire sections table. Because these RLS
-- helpers are SECURITY DEFINER (required to avoid RLS-recursion
-- against user_assignments/sections — see the comments above them),
-- Postgres treats each call as an opaque black box and cannot hoist or
-- cache the result across separate invocations, so that sequential
-- scan re-runs FRESH for every single row a query's RLS check touches.
-- A case with a long history (many audit_logs/requests/responses/
-- internal_requests rows) multiplies this badly enough to trip
-- statement_timeout on its own, independent of whether the earlier
-- missing-indexes patch has already been applied — exactly matching
-- reports that the timeout kept recurring after that first patch.
--
-- Also see the accompanying app-code fix (js/data/requests-api.js's
-- listCaseAuditTrail): it was fetching the full audit_logs history for
-- every action ever logged, RLS-evaluating all of it, then discarding
-- everything except a couple of specific actions client-side — the
-- indexes here reduce the COST of each RLS check; that fix reduces how
-- many rows have to pay it in the first place. Both matter.
--
-- Idempotent — safe to run more than once.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_sections_department ON sections(department_id) WHERE department_id IS NOT NULL AND is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_sections_division   ON sections(division_id) WHERE division_id IS NOT NULL AND is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_sections_org         ON sections(org_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_departments_command  ON departments(command_id) WHERE is_active = TRUE;

COMMIT;
