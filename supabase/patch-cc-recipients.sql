-- ─── Patch: CC / Loop-In Staff on Requests & Responses ─────────
-- Lets the staff member sending a request or drafting a response loop
-- in one or more colleagues (same org only) for read-only visibility —
-- like CC in email. A CC'd viewer can see the request/response body
-- and its attachments, but nothing else (no review comments, no
-- Internal Collaboration, no actions) — requests_update/responses_
-- update are untouched, so a CC'd viewer who isn't also the creator/
-- assignee/supervisor simply has no UPDATE policy that matches them.
--
-- Named cc_recipients (not "loop_ins") to avoid colliding with the
-- EXISTING, unrelated "looped in via Internal Collaboration" concept
-- already in this file (looped_in_via_internal_collab() — a whole
-- SECTION being routed extra info to gather, not an individual being
-- CC'd for visibility). Same idea as an email CC, different mechanism
-- from "Loop in a Section".
--
-- Idempotent — safe to run more than once.

BEGIN;

CREATE TABLE IF NOT EXISTS cc_recipients (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  record_type TEXT        NOT NULL CHECK (record_type IN ('request', 'response')),
  record_id   UUID        NOT NULL,
  user_id     UUID        NOT NULL REFERENCES users(id),
  added_by    UUID        NOT NULL REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (record_type, record_id, user_id)
);

ALTER TABLE cc_recipients ENABLE ROW LEVEL SECURITY;

-- Two SECURITY DEFINER helpers, same pattern as looped_in_via_
-- internal_collab() above — cc_recipients' own policies (below) need
-- to check the CC target's org and whether the caller can already see
-- the parent request/response, but requests_select_cc/responses_
-- select_cc (also below) query cc_recipients right back, and so does
-- users_select_correspondence (queried transitively via a plain
-- `SELECT org_id FROM users WHERE id = ...` subquery). Either one
-- inlined directly would run under the invoking role and re-trigger
-- those policies, which circle back to cc_recipients: "infinite
-- recursion detected in policy for relation cc_recipients", reproduced
-- twice (two distinct 2-table and 3-table cycles) against a real local
-- Postgres instance before adding these wrappers. Bypassing RLS here
-- is safe because every branch re-implements requests_select/
-- responses_select's own conditions as literal predicates rather than
-- trusting a policy re-evaluation.
CREATE OR REPLACE FUNCTION user_org_id(p_user_id UUID)
RETURNS UUID AS $$
  SELECT org_id FROM users WHERE id = p_user_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION can_view_request_or_response(p_record_type TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (p_record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
      WHERE re.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR re.created_by     = auth.uid()
          OR re.received_by    = auth.uid()
        )
    ));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "cc_recipients_select" ON cc_recipients;
CREATE POLICY "cc_recipients_select" ON cc_recipients
  FOR SELECT USING (
    user_id = auth.uid()
    OR added_by = auth.uid()
    OR (
      get_my_org_id() = user_org_id(cc_recipients.user_id)
      AND can_view_request_or_response(record_type, record_id)
    )
  );

-- Only same-org (CC never crosses the org boundary) and only someone
-- who can already see the parent record (section member, creator,
-- supervisor, or received_by) can add a CC to it — reuses the same
-- visibility check as cc_recipients_select above.
DROP POLICY IF EXISTS "cc_recipients_insert" ON cc_recipients;
CREATE POLICY "cc_recipients_insert" ON cc_recipients
  FOR INSERT WITH CHECK (
    added_by = auth.uid()
    AND get_my_org_id() = user_org_id(cc_recipients.user_id)
    AND can_view_request_or_response(record_type, record_id)
  );

DROP POLICY IF EXISTS "cc_recipients_delete" ON cc_recipients;
CREATE POLICY "cc_recipients_delete" ON cc_recipients
  FOR DELETE USING (
    added_by = auth.uid()
    OR (is_supervisor_or_above() AND get_my_org_id() = user_org_id(cc_recipients.user_id))
  );

-- Two more SECURITY DEFINER wrappers — requests_select_cc/responses_
-- select_cc (below) need to check cc_recipients, but a PLAIN subquery
-- there runs under the invoking role and re-triggers cc_recipients'
-- OWN policies (cc_recipients_select), which is exactly the cycle the
-- two functions above already guard against from the OTHER side —
-- this closes it from the requests/responses side too, since Postgres
-- evaluates EVERY permissive policy's boolean expression while
-- planning a query (not a short-circuited "first match wins"), so
-- cc_recipients_select's cheap `user_id = auth.uid()` branch matching
-- does NOT stop its other branches — or a JOIN's broader row scan —
-- from still being planned/evaluated for rows where it doesn't match.
-- Confirmed by reproducing this exact residual recursion against a
-- real local Postgres instance even after the two functions above.
CREATE OR REPLACE FUNCTION is_cc_recipient(p_record_type TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM cc_recipients cc
    WHERE cc.record_type = p_record_type AND cc.record_id = p_record_id AND cc.user_id = auth.uid()
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_cc_recipient_via_response(p_request_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM responses re
    JOIN cc_recipients cc ON cc.record_type = 'response' AND cc.record_id = re.id
    WHERE re.request_id = p_request_id AND cc.user_id = auth.uid()
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Additive grants on requests/responses (Postgres ORs all PERMISSIVE
-- policies together — this only ADDS visibility, never narrows the
-- rules above). A response CC also grants its PARENT request, since
-- request-detail.js always loads the whole conversation and someone
-- CC'd only on a reply still needs the thread it replies to to render;
-- the reverse (a request CC auto-seeing every response) is NOT
-- granted — CC is per-artifact, matching the two independent
-- "when sending a request or response" compose-time actions that
-- create these rows.
DROP POLICY IF EXISTS "requests_select_cc" ON requests;
CREATE POLICY "requests_select_cc" ON requests
  FOR SELECT USING (
    is_cc_recipient('request', requests.id)
    OR is_cc_recipient_via_response(requests.id)
  );

DROP POLICY IF EXISTS "responses_select_cc" ON responses;
CREATE POLICY "responses_select_cc" ON responses
  FOR SELECT USING (
    is_cc_recipient('response', responses.id)
  );

-- Additive: a CC'd viewer can see files attached to the specific
-- request/response they were CC'd on (cc_recipients, above) — same
-- shape as requests_select_cc/responses_select_cc.
DROP POLICY IF EXISTS "attachments_select_cc" ON attachments;
CREATE POLICY "attachments_select_cc" ON attachments
  FOR SELECT USING (
    record_type IN ('request', 'response') AND is_cc_recipient(record_type, record_id)
  );

COMMIT;
