-- CAP-003 Phase 1.6A rollback. Reverses patch-requests-server-
-- mutation-foundation.sql exactly.
--
-- ─── What this rollback restores ────────────────────────────────
-- Drops all 19 new business-command RPCs this milestone introduced,
-- and restores direct client INSERT/UPDATE on requests/responses to
-- `authenticated` (the exact pre-1.6A grant posture — RLS on both
-- tables was never touched by the patch and is therefore already
-- exactly correct without any action here). No RLS policy is
-- created, altered, or dropped by this rollback, because the patch
-- never touched one. No table, column, or constraint was added by
-- the patch either, so there is nothing to DROP TABLE/DROP COLUMN
-- here and no CASCADE risk -- the "refuse if a new schema field holds
-- real state" case this milestone's own instructions warn about does
-- not arise, because no new schema field was ever introduced.
--
-- ─── What this rollback does NOT touch ──────────────────────────
-- Every requests/responses/approvals/audit_logs row this milestone's
-- RPCs ever wrote remains exactly as committed -- rollback removes the
-- MUTATION BOUNDARY, never the business data or history it already
-- produced. CAP-003 infrastructure (user_notifications,
-- platform_outbox_events, notification_intents, and everything from
-- Phase 1.1-1.5) is untouched, since this milestone never created any
-- CAP-003 object for Requests in the first place.
--
-- ─── Frontend rollback ───────────────────────────────────────────
-- js/data/requests-api.js and js/views/request-detail.js are reverted
-- via a plain git revert of this milestone's commit (this repository
-- has no frontend migration/versioning system, same convention as
-- Phase 1.5's rollback) -- independent of whether this SQL rollback is
-- also applied. Reverting the frontend WITHOUT running this SQL
-- rollback would simply mean the (now unused) RPCs remain granted and
-- direct table writes remain revoked, which breaks the reverted
-- frontend's direct-write calls -- the two rollbacks are meant to be
-- applied together, exactly like the forward migration was.
\set ON_ERROR_STOP on
BEGIN;

GRANT INSERT, UPDATE ON TABLE requests, responses TO authenticated;

DROP FUNCTION IF EXISTS create_request(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,UUID);
DROP FUNCTION IF EXISTS update_request_draft(UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ);
DROP FUNCTION IF EXISTS submit_request(UUID,UUID);
DROP FUNCTION IF EXISTS approve_request(UUID,TEXT);
DROP FUNCTION IF EXISTS return_request(UUID,TEXT);
DROP FUNCTION IF EXISTS mark_request_received(UUID);
DROP FUNCTION IF EXISTS route_request(UUID,UUID);
DROP FUNCTION IF EXISTS return_request_to_previous_section(UUID,TEXT);
DROP FUNCTION IF EXISTS assign_request(UUID,UUID);
DROP FUNCTION IF EXISTS receive_and_route_request(UUID,UUID,UUID);
DROP FUNCTION IF EXISTS close_request(UUID);
DROP FUNCTION IF EXISTS cancel_request(UUID,TEXT);
DROP FUNCTION IF EXISTS create_response(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS update_response_draft(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS submit_response(UUID,UUID);
DROP FUNCTION IF EXISTS approve_response(UUID,TEXT);
DROP FUNCTION IF EXISTS return_response(UUID,TEXT);
DROP FUNCTION IF EXISTS mark_response_received(UUID);
DROP FUNCTION IF EXISTS acknowledge_and_close(UUID,UUID);

COMMIT;
