-- Fix: audit_logs_action_check never allowed 'module_enabled'/
-- 'module_disabled', even though ModulesAPI.setModuleEnabled()
-- (js/data/modules-api.js) — the exact function behind Admin > Modules'
-- per-organization module toggle — has always inserted an audit_logs
-- row with one of those two action values immediately after upserting
-- organization_modules. Every call to that toggle has therefore been
-- throwing a check-constraint violation on its second statement (the
-- organization_modules write itself succeeds first, since the two are
-- separate awaited calls, not a single transaction) — discovered while
-- enabling the calendar module for org MCS-STG on CorLink Staging via
-- direct SQL mirroring that same function's upsert+audit-log shape.
--
-- True current latest predecessor: patch-task-relationship-authority-
-- and-activity-history.sql, the last file in canonical order to touch
-- audit_logs_action_check (adding 'task_relationship_added'/
-- 'task_relationship_removed'). Confirmed by re-checking every ALTER of
-- this constraint against canonical-migration-order.txt positions.
-- Adds exactly the two new codes; every previously-allowed value is
-- preserved verbatim.

BEGIN;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned', 'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden', 'unassigned',
    'participant_added', 'participant_removed', 'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked', 'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked', 'meeting_group_created', 'meeting_group_updated',
    'meeting_group_deleted', 'meeting_group_members_updated', 'meeting_series_created',
    'meeting_draft_deleted', 'meeting_series_updated', 'meeting_series_split', 'meeting_series_cancelled',
    'completed', 'commented', 'task_linked', 'task_unlinked',
    'task_dependency_added', 'task_dependency_removed', 'task_dependency_waived',
    'task_started', 'task_work_started',
    'task_relationship_added', 'task_relationship_removed',
    'module_enabled', 'module_disabled'
  ));

COMMIT;
