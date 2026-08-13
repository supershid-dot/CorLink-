-- CAP-003 Phase 1.7A rollback. Reverses patch-entry-server-
-- mutation-foundation.sql exactly.
--
-- ─── What this rollback restores ────────────────────────────────
-- Drops all 12 new business-command RPCs this milestone introduced,
-- and restores direct client INSERT/UPDATE on external_correspondence/
-- external_correspondence_replies to `authenticated` (the exact
-- pre-1.7A grant posture — RLS on both tables was never touched by the
-- patch and is therefore already exactly correct without any action
-- here). No RLS policy is created, altered, or dropped by this
-- rollback, because the patch never touched one. No table, column, or
-- constraint was added by the patch either, so there is nothing to
-- DROP TABLE/DROP COLUMN here and no CASCADE risk -- the "refuse if a
-- new schema field holds real state" case this milestone's own
-- instructions warn about does not arise, because no new schema field
-- was ever introduced (including no facility/prison column -- the
-- prisoner-transfer architecture gap documented in the patch's own
-- header was deliberately left as a documented gap, not a schema
-- change, so there is nothing schema-level to unwind for it either).
--
-- ─── What this rollback does NOT touch ──────────────────────────
-- Every external_correspondence/external_correspondence_replies/
-- approvals/audit_logs row this milestone's RPCs ever wrote remains
-- exactly as committed -- rollback removes the MUTATION BOUNDARY, never
-- the business data or history it already produced. CAP-003
-- infrastructure (user_notifications, platform_outbox_events,
-- notification_intents, and everything from Phase 1.1-1.6B) is
-- untouched, since this milestone never created any CAP-003 object for
-- Entry in the first place. Requests (Phase 1.6A/1.6B) is completely
-- untouched.
--
-- ─── Frontend rollback ───────────────────────────────────────────
-- js/data/entry-api.js is reverted via a plain git revert of this
-- milestone's commit (this repository has no frontend migration/
-- versioning system, same convention as every prior CAP-003 phase's
-- rollback) -- independent of whether this SQL rollback is also
-- applied. No view file (js/views/entry-detail.js, js/views/entry.js)
-- needs reverting -- this migration required zero call-site changes.
-- Reverting the frontend WITHOUT running this SQL rollback would
-- simply mean the (now unused) RPCs remain granted and direct table
-- writes remain revoked, which breaks the reverted frontend's direct-
-- write calls -- the two rollbacks are meant to be applied together,
-- exactly like the forward migration was.
\set ON_ERROR_STOP on
BEGIN;

GRANT INSERT, UPDATE ON TABLE external_correspondence, external_correspondence_replies TO authenticated;

DROP FUNCTION IF EXISTS create_entry(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,DATE,DATE);
DROP FUNCTION IF EXISTS update_entry_draft(UUID,TEXT,TEXT,TEXT,TEXT,DATE);
DROP FUNCTION IF EXISTS route_entry(UUID,UUID,UUID);
DROP FUNCTION IF EXISTS mark_entry_received(UUID);
DROP FUNCTION IF EXISTS assign_entry(UUID,UUID,DATE);
DROP FUNCTION IF EXISTS close_entry(UUID);
DROP FUNCTION IF EXISTS draft_entry_reply(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS update_entry_reply_draft(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS submit_entry_reply(UUID,UUID);
DROP FUNCTION IF EXISTS approve_entry_reply(UUID);
DROP FUNCTION IF EXISTS return_entry_reply(UUID,TEXT);
DROP FUNCTION IF EXISTS mark_entry_reply_sent(UUID,TEXT);

COMMIT;
