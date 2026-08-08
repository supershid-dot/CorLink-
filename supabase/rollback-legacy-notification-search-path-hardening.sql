-- CAP-003 Phase 1.3A legacy notification SECURITY DEFINER search-path
-- hardening -- rollback. Reverses patch-legacy-notification-search-
-- path-hardening.sql exactly.
--
-- Non-destructive, non-refusing by design: this milestone creates no
-- table and stores no data of its own -- it only sets one attribute
-- (proconfig) on seven already-existing functions. Restoring the
-- pre-1.3A state means clearing that one attribute back to unset,
-- which ALTER FUNCTION ... RESET search_path does directly and
-- completely -- there is no data to lose and therefore no refusal
-- condition to evaluate, exactly mirroring how CAP-002 Phase 5.4's
-- own rollback needed no refusal path for its own purely-additive,
-- no-durable-evidence-of-its-own change.
\set ON_ERROR_STOP on
BEGIN;

ALTER FUNCTION notif_user_org_id(UUID) RESET search_path;
ALTER FUNCTION notif_user_covers_section(UUID, UUID) RESET search_path;
ALTER FUNCTION notif_user_has_notify_role(UUID) RESET search_path;
ALTER FUNCTION notif_user_is_prisoner_letters_staff(UUID) RESET search_path;
ALTER FUNCTION notif_request_legitimate_recipient(UUID, UUID) RESET search_path;
ALTER FUNCTION notif_entry_legitimate_recipient(UUID, UUID) RESET search_path;
ALTER FUNCTION notif_prisoner_letter_legitimate_recipient(UUID, UUID) RESET search_path;

COMMIT;
