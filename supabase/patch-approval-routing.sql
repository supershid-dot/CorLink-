-- ============================================================
-- CorLink — Patch: route submit-for-approval to a chosen supervisor
--
-- Run this INSTEAD of re-running the full schema.sql.
--
-- Staff submitting a request/response for approval now pick a
-- specific supervisor (from the section/department/command hierarchy
-- covering it) to send it to, instead of it just broadcasting to
-- every eligible supervisor. Purely informational routing/notification
-- target, NOT an exclusivity gate — no RLS changes needed here: the
-- existing requests_update/requests_update_supervisor (and the
-- response equivalents) already permit the creator to set this column
-- on submit, and any qualifying supervisor of that section can still
-- approve/return it regardless of who was chosen, same as assigned_to
-- never gating who can act on a request.
--
-- Safe to re-run (ADD COLUMN IF NOT EXISTS).
-- ============================================================

BEGIN;

ALTER TABLE requests
  ADD COLUMN IF NOT EXISTS pending_approval_by UUID REFERENCES users(id);

ALTER TABLE responses
  ADD COLUMN IF NOT EXISTS pending_approval_by UUID REFERENCES users(id);

COMMIT;
