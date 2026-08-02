-- CorLink — rollback T3F.1 to the exact T3F architecture checkpoint.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.task_dependencies') IS NOT NULL
     AND EXISTS (SELECT 1 FROM task_dependencies) THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED: task_dependencies contains business history. Export and explicitly delete it before abandoning T3F.1.';
  END IF;
  IF EXISTS (SELECT 1 FROM audit_logs WHERE record_type = 'task_dependency') THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED: dependency audit history exists. Export and explicitly delete it before abandoning T3F.1.';
  END IF;
END $$;

BEGIN;
DROP POLICY IF EXISTS "audit_select_task_dependencies" ON audit_logs;
DROP FUNCTION IF EXISTS create_task_dependency(UUID, UUID);
DROP FUNCTION IF EXISTS remove_task_dependency(UUID);
DROP FUNCTION IF EXISTS list_task_dependencies(UUID, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_task_dependency_capabilities(UUID);
DROP FUNCTION IF EXISTS search_tasks_for_dependency(UUID, TEXT, INTEGER);
DROP FUNCTION IF EXISTS get_task_dependency_state(UUID);
DROP FUNCTION IF EXISTS task_dependency_would_cycle(UUID, UUID);
DROP TABLE IF EXISTS task_dependency_waivers;
DROP TABLE IF EXISTS task_dependencies;
DROP FUNCTION IF EXISTS enforce_task_dependency_endpoints();
DROP INDEX IF EXISTS idx_tasks_dependency_picker_number;
DROP INDEX IF EXISTS idx_tasks_dependency_picker_title;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group', 'meeting_series',
    'task', 'task_relationship'
  ));

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
    'completed', 'commented', 'task_linked', 'task_unlinked'
  ));
COMMIT;
