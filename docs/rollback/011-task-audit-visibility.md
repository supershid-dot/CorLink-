# Rollback — 011: Task Audit Visibility Correction (T2C.1)

Companion to `supabase/patch-task-audit-visibility.sql`. Explains how
to undo it if it needs to be reversed after being applied.

## Rollback strategy

Same shape as `docs/rollback/004-security-search-path-hardening.md`:
this patch creates **no new tables, columns, indexes, constraints,
policies, or grants** — it only re-declares one already-existing
function, `can_view_case_audit_record()`, via `CREATE OR REPLACE
FUNCTION`, adding one new branch (`record_type = 'task'`, delegating to
`can_view_task()`) on top of its five existing branches
(`request`/`response`/`internal_request`/`external_correspondence`/
`meeting_series`). Nothing else — no other function, table, or
policy — is touched.

Because of that, rollback is a single `CREATE OR REPLACE FUNCTION`
restoring the exact pre-patch (5-branch, no `task`) definition. The SQL
below was captured verbatim via `pg_get_functiondef()` from a reference
database built by replaying the full migration chain up to and **not**
including `patch-task-audit-visibility.sql` — the same technique
`docs/rollback/004` and `docs/31` both used to build/verify their own
patches — not hand-transcribed from reading patch files, to eliminate
transcription-error risk.

```sql
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
    ))
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
$function$
;

COMMIT;
```

## Assumptions

- `can_view_case_audit_record()` is the only function this patch
  touched — cross-check with `git show
  supabase/patch-task-audit-visibility.sql` if there is ever doubt.
- No other patch was applied on top of this one that itself further
  modified `can_view_case_audit_record()` (e.g. a future patch adding
  the still-open `meeting`/`prisoner_letter` branches R9, docs/38,
  already flagged) — if one has, capture ITS pre-change state instead
  of reusing this document's SQL verbatim, same caveat
  `docs/rollback/004` makes for its own function set.
- Rolling back this patch does not require rolling back anything else
  first or after — it has no dependents (nothing calls a `'task'`
  branch of this function directly; the Task Detail Activity panel,
  docs/42, simply goes back to showing comments only, no lifecycle
  events, for ordinary non-admin viewers — a functional regression in
  the UI, not a broken migration) and wrote no data.

## Verification performed for this document

Run against a disposable local database with the full chain through
`patch-task-audit-visibility.sql` already applied (never against
staging or production):

1. Applied the rollback SQL above. Confirmed via
   `pg_get_functiondef()` that the `task` branch was gone and exactly
   the 5 prior branches remained.
2. Re-ran `supabase/test-task-audit-visibility.sql`'s TEST 1 (task
   creator) manually — confirmed it now sees **0** audit rows for its
   own task, i.e. rollback genuinely restores the original,
   pre-correction (broken) behavior, not just "a" different behavior.
3. Reapplied `supabase/patch-task-audit-visibility.sql`.
4. Re-ran `supabase/validate-task-audit-visibility.sql` — PASSED.
5. Re-ran the full `supabase/test-task-audit-visibility.sql` suite —
   all 11 scenarios PASSED, confirming reapplication fully restores
   the corrected behavior.
6. Captured `pg_get_functiondef()` for two unrelated dependency
   functions (`can_view_task()`, `is_supervisor_or_above()`) before the
   rollback and again after the reapply — byte-for-byte identical both
   times, confirming the rollback→reapply cycle touched nothing beyond
   `can_view_case_audit_record()` itself.

## After rollback

- `docs/42-task-comments-and-timeline.md`'s Activity panel reverts to
  showing comments only for ordinary (non-admin) task viewers — the
  exact pre-T2C.1 state, not a crash or error. `task_comments` itself
  is unaffected (it has its own, separate, correct RLS via
  `can_view_task()` directly, never routed through
  `can_view_case_audit_record()`).
- No frontend code change is required to roll back safely — the
  Activity panel already renders "No activity yet" gracefully when the
  audit read comes back empty, the same as it always did before T2C.1.
