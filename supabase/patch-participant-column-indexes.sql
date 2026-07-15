-- ─── Patch: index the participant columns RLS resolves users by ──
-- Third and (measured) final root cause behind the recurring
-- "Couldn't load this request: canceling statement due to statement
-- timeout" on the request-detail page.
--
-- The two earlier timeout patches (patch-missing-indexes.sql,
-- patch-rls-scope-indexes.sql) narrowed candidate rows and sped up the
-- section-hierarchy expansion inside the RLS helpers. This one fixes a
-- different, dominant cost that scales linearly with total data volume
-- (exactly why the timeout kept returning as the app accumulated
-- history):
--
-- The request-detail load resolves a lot of user names via embedded
-- PostgREST joins — created_by/assigned_to/received_by/
-- pending_approval_by/cancelled_by on every request, created_by/
-- received_by on every response, the audit-trail actor on every logged
-- action, etc. Each embedded users(...) resolution makes Postgres apply
-- the users table's SELECT policies to that user row, and the main one,
-- users_select_correspondence, has this shape (per record type):
--
--     EXISTS (SELECT 1 FROM requests r
--             WHERE (r.created_by = users.id OR r.assigned_to = users.id
--                    OR r.received_by = users.id)
--               AND <visibility>)
--
-- with the same OR-of-participant-columns pattern against responses,
-- approvals, prisoner_letters and prisoner_replies. None of those
-- participant columns were indexed, so each EXISTS was a SEQUENTIAL SCAN
-- of the whole table — re-run once per user being resolved, and getting
-- more expensive every time the table grows. On a case-heavy database
-- that multiplies across a page's worth of user resolutions until it
-- crosses statement_timeout.
--
-- Separate single-column indexes let Postgres combine the OR branches
-- with a BitmapOr of index scans instead of scanning the table.
-- Verified against a 5,000-request / 30,000-audit_logs local dataset:
-- resolving one cross-org user dropped that requests EXISTS from a
-- 12,973-cost sequential scan to a 424-cost bitmap index scan, and the
-- latent responses branch from a 251,269-cost scan to 5,118.
--
-- Indexes only — no behavior change. Idempotent (IF NOT EXISTS), and
-- safe to run on a live database (CREATE INDEX briefly locks writes on
-- each table; run during a quiet window, or switch to CREATE INDEX
-- CONCURRENTLY — which cannot run inside this transaction block — if
-- that matters for your deployment).

BEGIN;

CREATE INDEX IF NOT EXISTS idx_requests_created_by     ON requests(created_by);
CREATE INDEX IF NOT EXISTS idx_requests_assigned_to    ON requests(assigned_to);
CREATE INDEX IF NOT EXISTS idx_requests_received_by    ON requests(received_by);
CREATE INDEX IF NOT EXISTS idx_responses_created_by    ON responses(created_by);
CREATE INDEX IF NOT EXISTS idx_responses_received_by   ON responses(received_by);
CREATE INDEX IF NOT EXISTS idx_approvals_reviewed_by   ON approvals(reviewed_by);
CREATE INDEX IF NOT EXISTS idx_prisoner_letters_submitted_by ON prisoner_letters(submitted_by);
CREATE INDEX IF NOT EXISTS idx_prisoner_letters_assigned_to  ON prisoner_letters(assigned_to);
CREATE INDEX IF NOT EXISTS idx_prisoner_replies_replied_by   ON prisoner_replies(replied_by);

COMMIT;
