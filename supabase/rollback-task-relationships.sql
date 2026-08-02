-- CorLink — rollback T3E/T3E.1 to the exact T3D.1 database surface.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.task_relationships') IS NOT NULL
     AND EXISTS (SELECT 1 FROM task_relationships) THEN
    RAISE EXCEPTION 'ROLLBACK REFUSED: task_relationships contains business history. Export it and explicitly delete those rows before abandoning T3E; rollback never deletes relationship data silently.';
  END IF;
END $$;

BEGIN;
DROP POLICY IF EXISTS "audit_select_task_relationships" ON audit_logs;
DROP FUNCTION IF EXISTS create_task_relationship(UUID, UUID, TEXT);
DROP FUNCTION IF EXISTS remove_task_relationship(UUID);
DROP FUNCTION IF EXISTS list_related_tasks(UUID);
DROP FUNCTION IF EXISTS get_task_relationship_capabilities(UUID);
DROP FUNCTION IF EXISTS can_view_task_relationship(UUID);
DROP TABLE IF EXISTS task_relationships;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group', 'meeting_series',
    'task'
  ));
COMMIT;
