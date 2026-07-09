-- ─── Patch: missing indexes on request-detail's hot query path ──
-- The request-detail conversation view (js/views/request-detail.js
-- _load()) fires one query per internal request for
-- internal_requests.parent_request_id, one per internal request for
-- internal_request_replies.internal_request_id, and one per request/
-- response/internal_reply for review_comments(record_type, record_id)
-- — none of those columns had an index, so each lookup was a full
-- table scan (made worse by RLS re-evaluating its policy subqueries
-- per scanned row). As those tables grew this started tripping
-- Postgres's statement_timeout ("Couldn't load this request:
-- canceling statement due to statement timeout").
--
-- Also indexes cc_recipients(user_id), used by the "Looped In" filter
-- chip's myLoopedInRequestIds() on every Requests-tab render — same
-- shape of gap, lower urgency but cheap to fix alongside the others.
--
-- Idempotent — safe to run more than once.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_internal_requests_parent    ON internal_requests(parent_request_id);
CREATE INDEX IF NOT EXISTS idx_internal_request_replies_ir ON internal_request_replies(internal_request_id);
CREATE INDEX IF NOT EXISTS idx_review_comments_record      ON review_comments(record_type, record_id);
CREATE INDEX IF NOT EXISTS idx_cc_recipients_user          ON cc_recipients(user_id);

COMMIT;
