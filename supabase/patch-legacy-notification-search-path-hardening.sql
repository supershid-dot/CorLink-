-- ============================================================
-- CAP-003 Phase 1.3A -- Legacy Notification SECURITY DEFINER
-- Search-Path Hardening.
--
-- Corrects a protected-baseline defect discovered while reviewing
-- CAP-003 Phase 1.3: seven SECURITY DEFINER helper functions
-- introduced by patch-legacy-notification-record-authorization-fix.sql
-- (CAP-003 Phase 1.0B, docs/80) never pinned an explicit search_path --
-- notif_user_org_id, notif_user_covers_section,
-- notif_user_has_notify_role, notif_user_is_prisoner_letters_staff,
-- notif_request_legitimate_recipient, notif_entry_legitimate_recipient,
-- notif_prisoner_letter_legitimate_recipient. This predates and is
-- unrelated to Phase 1.3's own outbox worker; it exists only because
-- 1.0B (Aug 8) was written after patch-security-definer-search-path-
-- hardening.sql (Jul 31) and was never itself covered by that earlier
-- sweep. Verified directly against the true, unmodified patch chain
-- (see docs/84) -- not against the disposable Phase 1.3 test harness,
-- which never applies the Jul 31 hardening patch at all and therefore
-- produces unrelated false positives for ~37 OTHER, already-correctly-
-- hardened functions.
--
-- ─── Method: ALTER FUNCTION, not CREATE OR REPLACE ─────────────────
-- patch-security-definer-search-path-hardening.sql itself used
-- CREATE OR REPLACE FUNCTION (re-declaring each function's full body
-- verbatim, generated from pg_get_functiondef() output). This patch
-- instead uses ALTER FUNCTION ... SET search_path, per this
-- milestone's own explicit preference for "the method with the
-- smallest semantic surface": ALTER FUNCTION touches only the
-- function's proconfig attribute -- it cannot alter the body, return
-- type, volatility, strictness, parallel-safety, ownership, or ACL by
-- construction, eliminating any possibility of a body-transcription
-- mismatch entirely (verified directly: pg_get_functiondef() before
-- and after differs by exactly one added "SET search_path TO 'public',
-- 'pg_temp'" line, nothing else -- see
-- validate-legacy-notification-search-path-hardening.sql).
--
-- ─── Scope discipline ────────────────────────────────────────────
-- No business logic, authorization semantics, grants, or signatures
-- change. No other function is touched. No new table, no RLS change,
-- no module integration, no CAP-003 Phase 1.4 work.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

ALTER FUNCTION notif_user_org_id(UUID) SET search_path = public, pg_temp;
ALTER FUNCTION notif_user_covers_section(UUID, UUID) SET search_path = public, pg_temp;
ALTER FUNCTION notif_user_has_notify_role(UUID) SET search_path = public, pg_temp;
ALTER FUNCTION notif_user_is_prisoner_letters_staff(UUID) SET search_path = public, pg_temp;
ALTER FUNCTION notif_request_legitimate_recipient(UUID, UUID) SET search_path = public, pg_temp;
ALTER FUNCTION notif_entry_legitimate_recipient(UUID, UUID) SET search_path = public, pg_temp;
ALTER FUNCTION notif_prisoner_letter_legitimate_recipient(UUID, UUID) SET search_path = public, pg_temp;

COMMIT;
