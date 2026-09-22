-- Rollback for patch-audit-logs-module-actions.sql.
-- Restores audit_logs_action_check to its pre-this-patch shape (the
-- version patch-task-relationship-authority-and-activity-history.sql
-- left it in), dropping 'module_enabled'/'module_disabled'.
--
-- WARNING: if any audit_logs row with action IN ('module_enabled',
-- 'module_disabled') has been inserted since the patch was applied,
-- this ADD CONSTRAINT will fail validation against existing data.
-- Delete or reclassify those rows first if that's the case.

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
    'task_relationship_added', 'task_relationship_removed'
  ));

COMMIT;
