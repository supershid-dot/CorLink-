-- ============================================================
-- CorLink — Demo data for the Requests workflow
--
-- NOT part of the migration chain (schema.sql/rls.sql/patch-*.sql) —
-- this is throwaway data to click through the UI and see every stage
-- of the workflow live: run it once against a project that already
-- has real orgs/sections/users set up, explore, then delete it (a
-- cleanup block is at the bottom, commented out).
--
-- Prerequisites (must already exist — this script only READS them,
-- never creates orgs/sections/users):
--   - At least one active 'mcs' organization and one active
--     'authority' organization
--   - At least one active section in EACH of those organizations
--     (Admin Portal → Structure tab)
--   - At least one active user in EACH of those organizations
--
-- Safe to re-run: each run's rows get a distinct DEMO-#### reference
-- number timestamp suffix, so re-running just adds another full set
-- rather than colliding.
-- ============================================================

DO $$
DECLARE
  v_mcs_org_id      UUID;
  v_auth_org_id     UUID;
  v_mcs_section_a   UUID;  -- primary MCS section (owns replies)
  v_mcs_section_b   UUID;  -- second MCS section (for internal collaboration)
  v_auth_section_id UUID;
  v_mcs_user_id     UUID;
  v_auth_user_id    UUID;
  v_suffix          TEXT := to_char(clock_timestamp(), 'HH24MISS');

  v_req_awaiting_receipt   UUID;
  v_req_received_unrouted  UUID;
  v_req_in_progress        UUID;
  v_req_assigned           UUID;
  v_resp_draft_id          UUID;
  v_req_awaiting_approval  UUID;
  v_resp_pending_id        UUID;
  v_req_awaiting_resp_rcpt UUID;
  v_resp_sent_id           UUID;
  v_req_responded          UUID;
  v_resp_received_id       UUID;
  v_req_root                UUID;
  v_resp_root_id             UUID;
  v_req_followup            UUID;
  v_internal_req_id        UUID;
BEGIN
  SELECT id INTO v_mcs_org_id  FROM organizations WHERE type = 'mcs'       AND is_active LIMIT 1;
  SELECT id INTO v_auth_org_id FROM organizations WHERE type = 'authority' AND is_active LIMIT 1;
  IF v_mcs_org_id IS NULL OR v_auth_org_id IS NULL THEN
    RAISE EXCEPTION 'Need at least one active MCS org and one active authority org first (Admin Portal → Organizations)';
  END IF;

  SELECT id INTO v_mcs_section_a FROM sections WHERE org_id = v_mcs_org_id AND is_active ORDER BY name LIMIT 1;
  SELECT id INTO v_mcs_section_b FROM sections WHERE org_id = v_mcs_org_id AND is_active AND id <> v_mcs_section_a ORDER BY name LIMIT 1;
  SELECT id INTO v_auth_section_id FROM sections WHERE org_id = v_auth_org_id AND is_active LIMIT 1;
  IF v_mcs_section_a IS NULL OR v_auth_section_id IS NULL THEN
    RAISE EXCEPTION 'Need at least one active section in both the MCS org and the authority org first (Admin Portal → Structure)';
  END IF;
  IF v_mcs_section_b IS NULL THEN
    RAISE NOTICE 'Only one active MCS section found — skipping the Internal Collaboration demo row (needs a second section to loop in)';
  END IF;

  SELECT id INTO v_mcs_user_id  FROM users WHERE org_id = v_mcs_org_id  AND is_active LIMIT 1;
  SELECT id INTO v_auth_user_id FROM users WHERE org_id = v_auth_org_id AND is_active LIMIT 1;
  IF v_mcs_user_id IS NULL OR v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Need at least one active user in both orgs first (Admin Portal → Users)';
  END IF;

  -- ── 1. Just arrived, nobody has acknowledged it yet ──────────
  -- Demonstrates: MCS Inbox shows "Mark Received" (needs
  -- supervisor/admin/assigned_receiver at MCS).
  v_req_awaiting_receipt := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status, reference_number, deadline)
  VALUES (v_req_awaiting_receipt, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_auth_user_id,
    'Scenario 1 — Awaiting receipt',
    '<p>Freshly sent, not yet acknowledged by MCS. Try the <b>Mark Received</b> button.</p>',
    'sent', 'DEMO-' || v_suffix || '-01', CURRENT_DATE + 14);

  -- ── 2. Received, not yet routed ──────────────────────────────
  -- Demonstrates: the "Received by [Name] — [time]" receipt line, and
  -- the "Route to Section" button.
  v_req_received_unrouted := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_received_unrouted, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_auth_user_id,
    'Scenario 2 — Received, awaiting routing',
    '<p>MCS has acknowledged receipt. Try the <b>Route to Section</b> button.</p>',
    'received', 'DEMO-' || v_suffix || '-02', CURRENT_DATE + 10, v_mcs_user_id, NOW() - INTERVAL '2 hours');

  -- ── 3. Routed, not yet assigned to a staff member ────────────
  -- Demonstrates: "Assign to Staff" button.
  v_req_in_progress := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_in_progress, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_mcs_section_a, v_auth_user_id,
    'Scenario 3 — Routed, unassigned',
    '<p>Routed to a section but nobody''s drafting the reply yet. Try <b>Assign to Staff</b>.</p>',
    'in_progress', 'DEMO-' || v_suffix || '-03', CURRENT_DATE + 7, v_mcs_user_id, NOW() - INTERVAL '1 day');

  -- ── 4. Routed + assigned, response still being drafted ───────
  -- Demonstrates: the compose-response form, and (if a second MCS
  -- section exists) the Internal Collaboration panel.
  v_req_assigned := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_assigned, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_mcs_section_a, v_mcs_user_id, v_auth_user_id,
    'Scenario 4 — Assigned, drafting reply',
    '<p>Assigned to a staff member. The <b>Draft a Response</b> form should be visible to them.</p>',
    'in_progress', 'DEMO-' || v_suffix || '-04', CURRENT_DATE + 5, v_mcs_user_id, NOW() - INTERVAL '2 days');

  IF v_mcs_section_b IS NOT NULL THEN
    v_internal_req_id := gen_random_uuid();
    INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status)
    VALUES (v_internal_req_id, v_req_assigned, v_mcs_section_a, v_mcs_section_b, v_mcs_user_id,
      'FYI: Scenario 4 case', '<p>Looping your section in for context — this is never visible to the authority org.</p>', 'sent');
    INSERT INTO internal_request_replies (internal_request_id, created_by, body)
    VALUES (v_internal_req_id, v_mcs_user_id, '<p>Acknowledged, will review.</p>');
    UPDATE internal_requests SET status = 'responded' WHERE id = v_internal_req_id;
  END IF;

  -- ── 5. Response drafted, submitted for approval ──────────────
  -- Demonstrates: the supervisor's Approve/Return buttons.
  v_req_awaiting_approval := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_awaiting_approval, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_mcs_section_a, v_mcs_user_id, v_auth_user_id,
    'Scenario 5 — Response pending approval',
    '<p>Draft response written, waiting on the MCS supervisor to approve or return it.</p>',
    'in_progress', 'DEMO-' || v_suffix || '-05', CURRENT_DATE + 3, v_mcs_user_id, NOW() - INTERVAL '3 days');
  v_resp_pending_id := gen_random_uuid();
  INSERT INTO responses (id, request_id, created_by, body, status)
  VALUES (v_resp_pending_id, v_req_awaiting_approval, v_mcs_user_id,
    '<p>Here is the requested information, ready for review.</p>', 'pending_approval');

  -- ── 6. Response sent, requester hasn't acknowledged it yet ───
  -- Demonstrates: "Received by" receipt on a RESPONSE, and the
  -- "Mark Received" button on the response for the requesting org.
  v_req_awaiting_resp_rcpt := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_awaiting_resp_rcpt, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_mcs_section_a, v_mcs_user_id, v_auth_user_id,
    'Scenario 6 — Response sent, awaiting receipt',
    '<p>MCS has approved and sent its response. The requesting org hasn''t acknowledged receiving it yet.</p>',
    'responded', 'DEMO-' || v_suffix || '-06', CURRENT_DATE - 1, v_mcs_user_id, NOW() - INTERVAL '4 days');
  v_resp_sent_id := gen_random_uuid();
  INSERT INTO responses (id, request_id, created_by, body, status, is_locked)
  VALUES (v_resp_sent_id, v_req_awaiting_resp_rcpt, v_mcs_user_id,
    '<p>Approved response, sent to the requesting authority.</p>', 'sent', TRUE);
  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('response', v_resp_sent_id, v_mcs_user_id, 'approved', 'Looks accurate, sending as-is.');

  -- ── 7. Fully closed out — response received and acknowledged ─
  -- Demonstrates: the "Mark Closed" button, and (once closed) "Send
  -- Further Information" to start a follow-up on the same case.
  v_req_responded := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_responded, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_mcs_section_a, v_mcs_user_id, v_auth_user_id,
    'Scenario 7 — Fully responded, ready to close',
    '<p>Response was received and acknowledged by the requesting org — MCS can now mark this closed.</p>',
    'responded', 'DEMO-' || v_suffix || '-07', CURRENT_DATE - 5, v_mcs_user_id, NOW() - INTERVAL '6 days');
  v_resp_received_id := gen_random_uuid();
  INSERT INTO responses (id, request_id, created_by, body, status, is_locked, received_by, received_at)
  VALUES (v_resp_received_id, v_req_responded, v_mcs_user_id,
    '<p>Final response, received and acknowledged.</p>', 'sent', TRUE, v_auth_user_id, NOW() - INTERVAL '5 days');
  INSERT INTO approvals (record_type, record_id, reviewed_by, decision)
  VALUES ('response', v_resp_received_id, v_mcs_user_id, 'approved');

  -- ── 8. Multi-round conversation — a closed case with a follow-up ─
  -- Demonstrates: conversation threading (getConversation()) rendering
  -- two request/response round-trips as one continuous thread.
  v_req_root := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, created_by, subject, body, status, reference_number, deadline, received_by, received_at)
  VALUES (v_req_root, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_mcs_section_a, v_mcs_user_id, v_auth_user_id,
    'Scenario 8 — Original case',
    '<p>First request in what will become a multi-round conversation.</p>',
    'closed', 'DEMO-' || v_suffix || '-08A', CURRENT_DATE - 20, v_mcs_user_id, NOW() - INTERVAL '20 days');
  v_resp_root_id := gen_random_uuid();
  INSERT INTO responses (id, request_id, created_by, body, status, is_locked, received_by, received_at)
  VALUES (v_resp_root_id, v_req_root, v_mcs_user_id,
    '<p>Initial response to the original case.</p>', 'sent', TRUE, v_auth_user_id, NOW() - INTERVAL '18 days');
  INSERT INTO approvals (record_type, record_id, reviewed_by, decision)
  VALUES ('response', v_resp_root_id, v_mcs_user_id, 'approved');

  v_req_followup := gen_random_uuid();
  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status, reference_number, deadline, parent_request_id)
  VALUES (v_req_followup, v_auth_org_id, v_mcs_org_id, v_auth_section_id, v_auth_user_id,
    'Re: Scenario 8 — Original case',
    '<p>Follow-up on the same case — open Scenario 8''s detail page and both requests should appear in one conversation thread.</p>',
    'sent', 'DEMO-' || v_suffix || '-08B', CURRENT_DATE + 7, v_req_root);

  RAISE NOTICE 'Demo data inserted with suffix %. Reference numbers: DEMO-%-01 through DEMO-%-08B', v_suffix, v_suffix, v_suffix;
END $$;

-- ── Cleanup ──────────────────────────────────────────────────────
-- Uncomment and run to remove every row this script has ever created
-- (matches on the DEMO- reference number prefix used above; internal
-- requests/responses/approvals cascade or are cleaned up alongside
-- their parent requests).
--
-- DELETE FROM internal_request_replies WHERE internal_request_id IN (
--   SELECT ir.id FROM internal_requests ir
--   JOIN requests r ON r.id = ir.parent_request_id
--   WHERE r.reference_number LIKE 'DEMO-%'
-- );
-- DELETE FROM internal_requests WHERE parent_request_id IN (SELECT id FROM requests WHERE reference_number LIKE 'DEMO-%');
-- DELETE FROM approvals WHERE record_type = 'response' AND record_id IN (
--   SELECT id FROM responses WHERE request_id IN (SELECT id FROM requests WHERE reference_number LIKE 'DEMO-%')
-- );
-- DELETE FROM responses WHERE request_id IN (SELECT id FROM requests WHERE reference_number LIKE 'DEMO-%');
-- DELETE FROM requests WHERE reference_number LIKE 'DEMO-%' OR reference_number LIKE 'Re: %';
-- DELETE FROM requests WHERE subject LIKE 'Re: Scenario 8%';
