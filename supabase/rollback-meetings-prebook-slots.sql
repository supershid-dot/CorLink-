-- Rollback for supabase/patch-meetings-prebook-slots.sql.
-- Drops the new RPC and restores audit_logs_action_check to its exact
-- prior list (the one patch-meetings-notify-participants.sql left in
-- place, verbatim, minus 'meeting_prebook_slots_created').

DROP FUNCTION IF EXISTS create_prebooked_meeting_slots(TEXT, UUID, DATE, DATE, INTEGER[], TIME, TIME, UUID, TEXT);

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
    'module_enabled', 'module_disabled',
    'meeting_notification_sent'
  ));

-- Note: any draft meetings/room bookings already created via
-- create_prebooked_meeting_slots() before this rollback are left in
-- place untouched — they are ordinary draft meetings/confirmed
-- bookings indistinguishable from ones created any other way, and
-- this rollback only removes the bulk-creation capability itself.
