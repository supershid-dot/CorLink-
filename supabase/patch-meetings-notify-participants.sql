-- 144: Manual "Notify Participants" panel (MeetFlow parity) — lets a
-- meeting's organizer/admin explicitly (re)send a Telegram notification
-- to selected participants: the original Schedule/invitation message
-- (with RSVP buttons), a Reminder ping, or a free-text Message — on
-- demand, rather than only via the automatic create/update/cancel/
-- 30-min-reminder pipeline already shipped (docs/126-132,
-- patch-meetings-notification-completion.sql).
--
-- UAT: four MeetFlow screenshots of its own meeting detail "NOTIFY
-- PARTICIPANTS" panel (recipient checkboxes + Schedule/Reminder/Message
-- tabs, a Telegram-linked indicator per recipient, "no TG" otherwise) —
-- "add this part to corlink as like in meetflow, this is telegram
-- notification."

-- get_meeting_telegram_recipients(): lets the panel show, for each
-- active internal participant, whether they have a linked Telegram
-- chat (a boolean only — never the chat id itself, which stays
-- server-side per docs/127's own privacy posture). Gated behind
-- can_manage_meeting() — the same population who can already Edit/
-- Cancel this meeting — since sending an ad-hoc message to other staff
-- members' Telegram is a management action, not something every
-- participant should be able to trigger for everyone else. External
-- (non-CorLink-user) participants are excluded — they carry no
-- telegram_chat_id concept in this schema.
CREATE OR REPLACE FUNCTION get_meeting_telegram_recipients(p_meeting_id UUID)
RETURNS TABLE(participant_id UUID, user_id UUID, full_name TEXT, has_telegram BOOLEAN) AS $$
BEGIN
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to view Telegram recipients for this meeting';
  END IF;

  RETURN QUERY
    SELECT mp.id, mp.user_id, u.full_name, (u.telegram_chat_id IS NOT NULL)
    FROM meeting_participants mp
    JOIN users u ON u.id = mp.user_id
    WHERE mp.meeting_id = p_meeting_id AND mp.removed_at IS NULL AND mp.user_id IS NOT NULL
    ORDER BY u.full_name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION get_meeting_telegram_recipients(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_meeting_telegram_recipients(UUID) TO authenticated;

-- Audit action vocabulary: adds 'meeting_notification_sent', the one
-- new code send-meeting-telegram-notification's audit_logs insert
-- writes. True current latest predecessor: patch-audit-logs-module-
-- actions.sql (adding 'module_enabled'/'module_disabled') — the most
-- recent file to touch audit_logs_action_check. Every previously-
-- allowed value is preserved verbatim.
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
