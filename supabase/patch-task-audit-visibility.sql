-- ============================================================
-- CorLink — Patch: Task audit visibility correction (T2C.1)
--
-- can_view_case_audit_record(record_type, record_id) — the function
-- audit_logs' audit_select_own_records policy calls to decide whether
-- an ordinary (non-admin) user can see a given audit row — has never
-- had a branch for record_type = 'task', even though the Shared Task
-- Foundation program (R2-R9) has written task_number/'task' audit rows
-- since R3. Every other branch this function already has (request,
-- response, internal_request, external_correspondence, meeting_series)
-- re-derives that record's own visibility rules inline; the task
-- branch below does not re-derive anything — it delegates directly to
-- can_view_task(p_record_id) (supabase/patch-shared-task-
-- foundation.sql), the exact same SECURITY DEFINER function that
-- already gates tasks_select/task_assignments_select/
-- task_watchers_select/task_comments_select and every task-mutating
-- RPC's own authorization check. This is deliberate: can_view_task()
-- is already the single source of truth for "can this user see this
-- task" (its own header comment says so explicitly), so re-implementing
-- an equivalent EXISTS(...) clause here would be exactly the
-- "Task visibility logic duplicated inside this function" this patch
-- is required not to do — any future change to who can see a task
-- (a new bypass, a narrowed rule, anything) then only ever needs to
-- happen in one place.
--
-- Practical effect: js/views/task-detail.js's Activity panel (T2C,
-- docs/42) starts showing real lifecycle events (created/edited/
-- assigned/unassigned/completed/cancelled) to ordinary task viewers —
-- creator, active assignees, watchers, section/org-visibility members,
-- scoped supervisors — not just org admins. Comments were never
-- affected by this gap (task_comments carries its own correct RLS via
-- can_view_task() directly) and are unchanged by this patch.
--
-- Scope discipline: this patch adds ONLY the 'task' branch. It does
-- NOT touch the still-open 'meeting'/'prisoner_letter' gaps R9
-- (docs/38) already found and explicitly deferred — those remain
-- separately, deliberately out of scope here (see docs/42's own
-- updated Known Limitations). Every existing branch, the function's
-- signature, its SECURITY DEFINER status, and its pinned
-- SET search_path = public, pg_temp are preserved byte-for-byte
-- (verified against pg_get_functiondef() output from a freshly built
-- reference database replaying the full migration chain through R9,
-- before this patch, and again after — see
-- supabase/validate-task-audit-visibility.sql). No new table, index,
-- policy, role, or grant is introduced; no dynamic SQL is used.
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.can_view_case_audit_record(p_record_type text, p_record_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    -- meeting_series branch (patch-meetings-recurring-phase2-audit-
    -- visibility.sql) — see that patch's own header comment for why
    -- can_manage_series() is deliberately NOT called from here.
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
    ))
    -- New branch (this patch, T2C.1) — delegates entirely to
    -- can_view_task(), the single existing source of truth for task
    -- visibility (supabase/patch-shared-task-foundation.sql). No
    -- inline EXISTS(...) reproduction of its rules, deliberately: any
    -- future change to who can see a task only needs to happen once,
    -- there.
    OR (p_record_type = 'task' AND can_view_task(p_record_id));
$function$
;

COMMIT;
