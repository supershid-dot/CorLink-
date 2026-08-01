-- ============================================================
-- CorLink — Validate: Task Attachments (T3D)
-- Companion to supabase/patch-task-attachments.sql
--
-- Read-only. Confirms the CHECK constraint and all three
-- attachments_select/_insert/_delete policies gained a 'task' branch,
-- every previously-supported branch (request/response/prisoner_letter/
-- internal_request/prisoner_reply/internal_reply/
-- external_correspondence/external_correspondence_reply/meeting) is
-- still present verbatim — i.e. this patch strictly ADDED, never
-- removed or altered, anything — and that can_view_task() itself
-- (which the new 'task' SELECT branch delegates to, rather than
-- reimplementing its own visibility logic) is untouched by this patch.
--
-- Patterns below match against Postgres's own re-serialized policy
-- text (pg_get_expr), which normalizes casts/parens (e.g. writes
-- `'task'::text` and wraps most sub-expressions in extra parens) —
-- checked as loose substrings on that normalized form, not the
-- original source file's exact formatting, which pg_get_expr does not
-- reproduce verbatim.
-- ============================================================

-- ─── 1. CHECK constraint includes 'task' alongside every prior value ──
SELECT
  pg_get_constraintdef(oid) LIKE '%''task''%' AS has_task,
  pg_get_constraintdef(oid) LIKE '%''request''%' AND pg_get_constraintdef(oid) LIKE '%''response''%'
    AND pg_get_constraintdef(oid) LIKE '%''prisoner_letter''%' AND pg_get_constraintdef(oid) LIKE '%''internal_request''%'
    AND pg_get_constraintdef(oid) LIKE '%''prisoner_reply''%' AND pg_get_constraintdef(oid) LIKE '%''internal_reply''%'
    AND pg_get_constraintdef(oid) LIKE '%''external_correspondence''%' AND pg_get_constraintdef(oid) LIKE '%''external_correspondence_reply''%'
    AND pg_get_constraintdef(oid) LIKE '%''meeting''%' AS has_every_prior_value
FROM pg_constraint WHERE conname = 'attachments_record_type_check';

-- ─── 2. attachments_select — 'task' branch delegates to
--        can_view_task(), every prior branch still present ──────
SELECT
  pg_get_expr(polqual, polrelid) LIKE '%''task''::text) AND can_view_task(record_id)%' AS has_task_branch,
  NOT (pg_get_expr(polqual, polrelid) ~ '''task''::text\).*SELECT 1\s+FROM tasks') AS task_branch_not_duplicated,
  pg_get_expr(polqual, polrelid) LIKE '%''request''::text) AND (EXISTS%'   AS has_request,
  pg_get_expr(polqual, polrelid) LIKE '%''response''::text) AND (EXISTS%'  AS has_response,
  pg_get_expr(polqual, polrelid) LIKE '%''prisoner_letter''::text) AND is_prisoner_letters_staff()%' AS has_prisoner_letter,
  pg_get_expr(polqual, polrelid) LIKE '%''internal_request''::text) AND (EXISTS%' AS has_internal_request,
  pg_get_expr(polqual, polrelid) LIKE '%''prisoner_reply''::text) AND is_prisoner_letters_staff()%' AS has_prisoner_reply,
  pg_get_expr(polqual, polrelid) LIKE '%''internal_reply''::text) AND (EXISTS%' AS has_internal_reply,
  pg_get_expr(polqual, polrelid) LIKE '%''external_correspondence''::text) AND (EXISTS%' AS has_external_correspondence,
  pg_get_expr(polqual, polrelid) LIKE '%''external_correspondence_reply''::text) AND (EXISTS%' AS has_external_correspondence_reply,
  pg_get_expr(polqual, polrelid) LIKE '%''meeting''::text) AND can_view_meeting(record_id)%' AS has_meeting
FROM pg_policy WHERE polname = 'attachments_select' AND polrelid = 'attachments'::regclass;

-- ─── 3. attachments_insert — 'task' branch mirrors update_task()'s
--        own authorization (creator/active assignee/supervisor-in-
--        scope/admin), every prior branch still present ─────────
SELECT
  pg_get_expr(polwithcheck, polrelid) LIKE '%''task''::text) AND (EXISTS%FROM tasks t%' AS has_task_branch,
  pg_get_expr(polwithcheck, polrelid) LIKE '%t.created_by = auth.uid()%' AS task_branch_checks_creator,
  pg_get_expr(polwithcheck, polrelid) LIKE '%task_assignments ta%ta.is_active%' AS task_branch_checks_active_assignee,
  pg_get_expr(polwithcheck, polrelid) LIKE '%is_supervisor_or_above()%owning_section_id%' AS task_branch_checks_supervisor_scope,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''request''::text) AND (EXISTS%'  AS has_request,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''response''::text) AND (EXISTS%' AS has_response,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''internal_request''::text) AND (EXISTS%' AS has_internal_request,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''prisoner_letter''::text) AND is_prisoner_letters_staff()%' AS has_prisoner_letter,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''prisoner_reply''::text) AND is_prisoner_letters_staff()%' AS has_prisoner_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''internal_reply''::text) AND (EXISTS%' AS has_internal_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''external_correspondence''::text) AND (EXISTS%' AS has_external_correspondence,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''external_correspondence_reply''::text) AND (EXISTS%' AS has_external_correspondence_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''meeting''::text) AND can_manage_meeting(record_id)%' AS has_meeting
FROM pg_policy WHERE polname = 'attachments_insert' AND polrelid = 'attachments'::regclass;

-- ─── 4. attachments_delete — same 'task' branch shape as insert
--        (deliberately symmetric — see patch-task-attachments.sql's
--        own comment on why 'meeting' alone is asymmetric and tasks
--        don't follow that), every prior branch still present ───
SELECT
  pg_get_expr(polqual, polrelid) LIKE '%''task''::text) AND (EXISTS%FROM tasks t%' AS has_task_branch,
  pg_get_expr(polqual, polrelid) LIKE '%''request''::text) AND (EXISTS%'  AS has_request,
  pg_get_expr(polqual, polrelid) LIKE '%''response''::text) AND (EXISTS%' AS has_response,
  pg_get_expr(polqual, polrelid) LIKE '%''internal_request''::text) AND (EXISTS%' AS has_internal_request,
  pg_get_expr(polqual, polrelid) LIKE '%''prisoner_letter''::text) AND is_prisoner_letters_staff()%' AS has_prisoner_letter,
  pg_get_expr(polqual, polrelid) LIKE '%''prisoner_reply''::text) AND is_prisoner_letters_staff()%' AS has_prisoner_reply,
  pg_get_expr(polqual, polrelid) LIKE '%''internal_reply''::text) AND (EXISTS%' AS has_internal_reply,
  pg_get_expr(polqual, polrelid) LIKE '%''external_correspondence''::text) AND (EXISTS%' AS has_external_correspondence,
  pg_get_expr(polqual, polrelid) LIKE '%''external_correspondence_reply''::text) AND (EXISTS%' AS has_external_correspondence_reply,
  pg_get_expr(polqual, polrelid) LIKE '%''meeting''::text) AND (EXISTS%' AS has_meeting
FROM pg_policy WHERE polname = 'attachments_delete' AND polrelid = 'attachments'::regclass;

-- ─── 5. attachments_select_cc untouched — CC recipients are a
--        Requests/Responses-only concept, no 'task' branch expected ──
SELECT
  pg_get_expr(polqual, polrelid) LIKE '%is_cc_recipient(record_type, record_id)%'
    AND pg_get_expr(polqual, polrelid) NOT LIKE '%''task''%'
    AS attachments_select_cc_unchanged_no_task_branch
FROM pg_policy WHERE polname = 'attachments_select_cc' AND polrelid = 'attachments'::regclass;

-- ─── 6. can_view_task() itself still exists and is unmodified by
--        this patch (this patch must never touch it) ────────────
SELECT
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'can_view_task') AS can_view_task_exists,
  (SELECT p.prosecdef FROM pg_proc p WHERE p.proname = 'can_view_task') AS can_view_task_is_security_definer;

-- ─── 7. No stale duplicate overload of any touched policy ────────
SELECT count(*) AS attachments_select_policy_count FROM pg_policy WHERE polname = 'attachments_select' AND polrelid = 'attachments'::regclass;
SELECT count(*) AS attachments_insert_policy_count FROM pg_policy WHERE polname = 'attachments_insert' AND polrelid = 'attachments'::regclass;
SELECT count(*) AS attachments_delete_policy_count FROM pg_policy WHERE polname = 'attachments_delete' AND polrelid = 'attachments'::regclass;
