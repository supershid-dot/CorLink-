-- CAP-003 Phase 1.8A rollback. Reverses patch-internal-collaboration-
-- server-mutation-foundation.sql exactly.
--
-- ─── What this rollback restores ────────────────────────────────
-- Drops all 11 new business-command RPCs this milestone introduced,
-- and restores direct client INSERT/UPDATE on internal_requests/
-- internal_request_replies to `authenticated` (the exact pre-1.8A
-- grant posture -- RLS on both tables was never touched by the patch
-- and is therefore already exactly correct without any action here).
-- No RLS policy is created, altered, or dropped by this rollback,
-- because the patch never touched one. No table, column, or
-- constraint was added by the patch either, so there is nothing to
-- DROP TABLE/DROP COLUMN here and no CASCADE risk.
--
-- ─── What this rollback does NOT touch ──────────────────────────
-- Every internal_requests/internal_request_replies/audit_logs row
-- this milestone's RPCs ever wrote remains exactly as committed --
-- rollback removes the MUTATION BOUNDARY, never the business data or
-- history it already produced. Task integration (patch-internal-
-- collaboration-task-integration.sql, its own 6 RPCs) is completely
-- untouched -- this milestone never modified it. CAP-003
-- infrastructure (user_notifications, platform_outbox_events,
-- notification_intents, and everything from Phase 1.1-1.7B) is
-- untouched, since this milestone never created any CAP-003 object for
-- Internal Collaboration in the first place. Requests (Phase 1.6A/
-- 1.6B) and Entry (Phase 1.7A/1.7B) are completely untouched.
--
-- ─── Frontend rollback ───────────────────────────────────────────
-- js/data/internal-requests-api.js is reverted via a plain git revert
-- of this milestone's commit (this repository has no frontend
-- migration/versioning system, same convention as every prior CAP-003
-- phase's rollback) -- independent of whether this SQL rollback is
-- also applied. No view file (js/views/request-detail.js, js/views/
-- entry-detail.js) needs reverting -- this migration required zero
-- call-site changes. Reverting the frontend WITHOUT running this SQL
-- rollback would simply mean the (now unused) RPCs remain granted and
-- direct table writes remain revoked, which breaks the reverted
-- frontend's direct-write calls -- the two rollbacks are meant to be
-- applied together, exactly like the forward migration was.
\set ON_ERROR_STOP on
BEGIN;

GRANT INSERT, UPDATE ON TABLE internal_requests, internal_request_replies TO authenticated;

DROP FUNCTION IF EXISTS create_internal_request(UUID,UUID,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ);
DROP FUNCTION IF EXISTS mark_internal_request_received(UUID);
DROP FUNCTION IF EXISTS reroute_internal_request(UUID,UUID);
DROP FUNCTION IF EXISTS return_internal_request_to_sender(UUID,TEXT);
DROP FUNCTION IF EXISTS assign_internal_request(UUID,UUID);
DROP FUNCTION IF EXISTS close_internal_request(UUID);
DROP FUNCTION IF EXISTS draft_internal_request_reply(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS update_internal_request_reply_draft(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS submit_internal_request_reply(UUID,UUID);
DROP FUNCTION IF EXISTS approve_internal_request_reply(UUID);
DROP FUNCTION IF EXISTS return_internal_request_reply(UUID);

COMMIT;
