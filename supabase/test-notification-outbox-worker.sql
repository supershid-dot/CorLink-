-- CAP-003 Phase 1.3 notification outbox worker -- focused behavioral
-- suite (20 required scenarios). Disposable local PostgreSQL only.
-- Runs in one transaction and leaves no fixtures (rolled back at the
-- end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf83_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf83_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf83_results, wf83_ids TO authenticated, service_role;

-- ── Fixtures ─────────────────────────────────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('83000000-0000-0000-0000-000000000001','WF83 Org','authority','WF83');
INSERT INTO auth.users(id,email) VALUES
 ('83000000-0001-0000-0000-000000000001','active@wf83t.local'),
 ('83000000-0001-0000-0000-000000000002','inactive@wf83t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('83000000-0001-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','WF83-1','Active User','active@wf83t.local',true),
 ('83000000-0001-0000-0000-000000000002','83000000-0000-0000-0000-000000000001','WF83-2','Inactive User','inactive@wf83t.local',false);

SET ROLE service_role;

-- ── 1: A pending valid (supported-shape) event processes successfully ──
DO $$
DECLARE v_outbox UUID; v_row RECORD; v_notif_before INTEGER; v_notif_after INTEGER;
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    jsonb_build_object(
      'notification_type','platform.wf83_test.v1','title_template_key','wf83.title',
      'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('83000000-0001-0000-0000-000000000001')
    ), gen_random_uuid());
  INSERT INTO wf83_ids VALUES ('ev_ok', v_outbox);

  SELECT count(*) INTO v_notif_before FROM user_notifications;
  SELECT * INTO v_row FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  SELECT count(*) INTO v_notif_after FROM user_notifications;

  IF v_row.outcome <> 'processed' OR v_row.final_status <> 'completed' OR v_row.intent_id IS NULL
     OR v_notif_after <> v_notif_before + 1
  THEN RAISE EXCEPTION 'scenario 1 failed: outcome=%, final_status=%, intent_id=%, notif before/after=%/%',
    v_row.outcome, v_row.final_status, v_row.intent_id, v_notif_before, v_notif_after;
  END IF;
  IF (SELECT status FROM platform_outbox_events WHERE id = v_outbox) <> 'completed'
     OR (SELECT processed_at FROM platform_outbox_events WHERE id = v_outbox) IS NULL
  THEN RAISE EXCEPTION 'scenario 1 failed: outbox event not marked completed with processed_at'; END IF;
END $$;
INSERT INTO wf83_results VALUES (1,'A pending valid (supported-shape) event processes successfully: intent created, notification materialized, outbox event marked completed with processed_at set');

-- ── 2: A processed event is not processed again ──
DO $$
DECLARE v_outbox UUID; v_count INTEGER; v_attempt_before INTEGER;
BEGIN
  SELECT id INTO v_outbox FROM wf83_ids WHERE name = 'ev_ok';
  SELECT attempt_count INTO v_attempt_before FROM platform_outbox_events WHERE id = v_outbox;
  SELECT count(*) INTO v_count FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_count <> 0 THEN RAISE EXCEPTION 'scenario 2 failed: completed event was re-selected by the worker, count=%', v_count; END IF;
  IF (SELECT attempt_count FROM platform_outbox_events WHERE id = v_outbox) <> v_attempt_before THEN
    RAISE EXCEPTION 'scenario 2 failed: attempt_count changed on an already-completed event';
  END IF;
  IF (SELECT count(*) FROM user_notifications WHERE outbox_event_id = v_outbox) <> 1 THEN
    RAISE EXCEPTION 'scenario 2 failed: duplicate notification exists for an already-completed event';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (2,'A processed (status=completed) event is never re-selected by platform_outbox_events_due_for_processing -- calling the worker again is a safe no-op');

-- ── 3: An empty batch (no eligible work) returns safely ──
-- The worker's own candidate pool is intentionally global, not scoped
-- to this suite's own fixtures (a real production worker must claim
-- ALL due work regardless of which module enqueued it) -- so when
-- this suite runs as part of a larger cumulative regression sweep,
-- other phases' own disposable performance-suite fixtures (e.g. Phase
-- 1.1's own deliberately-left 2,000 genuinely-pending rows, dated
-- deliberately far in the past to exercise its own claim-query
-- performance test) may still be sitting in the pending queue. A bare
-- single call therefore cannot safely assert zero rows in that
-- context. Proving "empty batch returns safely, without error" only
-- requires draining whatever is currently eligible (harmless,
-- idempotent, disposable fixture data regardless of origin) and then
-- confirming one further call is genuinely empty -- a stronger,
-- order-independent proof of the same property.
DO $$
DECLARE v_count INTEGER; v_i INTEGER := 0;
BEGIN
  LOOP
    SELECT count(*) INTO v_count FROM process_platform_outbox_batch(200,'wf83-worker');
    v_i := v_i + 1;
    EXIT WHEN v_count = 0 OR v_i > 100;
  END LOOP;
  IF v_i > 100 THEN RAISE EXCEPTION 'scenario 3 setup failed: pending queue never drained after 100 batch calls'; END IF;

  SELECT count(*) INTO v_count FROM process_platform_outbox_batch(25,'wf83-worker');
  IF v_count <> 0 THEN RAISE EXCEPTION 'scenario 3 failed: expected zero rows from a genuinely empty batch, got %', v_count; END IF;
END $$;
INSERT INTO wf83_results VALUES (3,'Calling process_platform_outbox_batch with zero eligible pending work returns an empty result set safely, without error');

-- ── 4: Batch limit enforced ──
DO $$
DECLARE v_id UUID; v_i INTEGER; v_count INTEGER;
BEGIN
  FOR v_i IN 1..5 LOOP
    v_id := platform_enqueue_outbox_event(
      'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
      '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
      jsonb_build_object('notification_type','platform.wf83_batch.v1','title_template_key','wf83.title',
        'target_type','specific_users','target_user_ids', jsonb_build_array('83000000-0001-0000-0000-000000000001')),
      gen_random_uuid());
    INSERT INTO wf83_ids VALUES ('ev_batch_' || v_i, v_id);
  END LOOP;

  SELECT count(*) INTO v_count FROM process_platform_outbox_batch(2,'wf83-worker');
  IF v_count <> 2 THEN RAISE EXCEPTION 'scenario 4 failed: expected exactly 2 rows processed with p_limit=2, got %', v_count; END IF;
  IF (SELECT count(*) FROM platform_outbox_events WHERE event_type='platform.generic_notification_request.v1' AND status='pending'
        AND id IN (SELECT id FROM wf83_ids WHERE name LIKE 'ev_batch_%')) <> 3
  THEN RAISE EXCEPTION 'scenario 4 failed: expected 3 of 5 fixture events to remain pending after a limit-2 call'; END IF;

  -- Drain the remaining 3 so they don't interfere with later scenarios.
  PERFORM * FROM process_platform_outbox_batch(25,'wf83-worker');
END $$;
INSERT INTO wf83_results VALUES (4,'process_platform_outbox_batch(p_limit) processes at most p_limit events per call regardless of how many more are eligible -- the batch bound is real, not advisory');

-- ── 5: Unsupported event/version handled correctly ──
DO $$
DECLARE v_outbox UUID; v_row RECORD;
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.some_unrecognized_shape.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    '{}'::JSONB, gen_random_uuid());
  INSERT INTO wf83_ids VALUES ('ev_unsupported', v_outbox);

  SELECT * INTO v_row FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_row.outcome <> 'retry_scheduled' OR v_row.final_status <> 'pending' OR v_row.attempt_count <> 1 THEN
    RAISE EXCEPTION 'scenario 5 failed: outcome=%, final_status=%, attempt_count=%', v_row.outcome, v_row.final_status, v_row.attempt_count;
  END IF;
  IF (SELECT last_error FROM platform_outbox_events WHERE id = v_outbox) NOT ILIKE '%unsupported_event_type%' THEN
    RAISE EXCEPTION 'scenario 5 failed: last_error does not classify the failure as an unsupported event type';
  END IF;
  IF (SELECT count(*) FROM notification_intents WHERE outbox_event_id = v_outbox) <> 0 THEN
    RAISE EXCEPTION 'scenario 5 failed: an intent was fabricated for an unsupported event type';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (5,'An event_type this worker does not recognize is rejected deterministically (no fabricated intent, no crash) and routed through the same bounded retry/dead-letter machinery as any other failure, with a safe error classification recorded');

-- ── 6: Legitimate zero-recipient outcome handled correctly (never a
-- retryable failure) ──
DO $$
DECLARE v_outbox UUID; v_row RECORD;
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    jsonb_build_object('notification_type','platform.wf83_zero.v1','title_template_key','wf83.title',
      'target_type','specific_users',
      'target_user_ids', jsonb_build_array('83000000-0001-0000-0000-000000000002')),  -- inactive user only
    gen_random_uuid());
  INSERT INTO wf83_ids VALUES ('ev_zero_recipients', v_outbox);

  SELECT * INTO v_row FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_row.outcome <> 'processed_zero_recipients' OR v_row.final_status <> 'completed' THEN
    RAISE EXCEPTION 'scenario 6 failed: a legitimate zero-recipient outcome was treated as a failure -- outcome=%, final_status=%', v_row.outcome, v_row.final_status;
  END IF;
  IF (SELECT status FROM platform_outbox_events WHERE id = v_outbox) <> 'completed' THEN
    RAISE EXCEPTION 'scenario 6 failed: outbox event not marked completed for a legitimate zero-recipient decision';
  END IF;
  IF (SELECT count(*) FROM user_notifications WHERE outbox_event_id = v_outbox) <> 0 THEN
    RAISE EXCEPTION 'scenario 6 failed: a notification was created for zero authorized recipients';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (6,'An event whose only targeted candidate is legitimately unauthorized (inactive user) resolves to zero recipients and is marked completed, never retried or dead-lettered -- docs/78 SS8: a candidate failing revalidation is skipped silently, never a batch failure');

-- ── 7 & 8: Retryable error increments attempts; next_attempt_at moves
-- forward (deterministic exponential backoff) ──
DO $$
DECLARE v_outbox UUID; v_na1 TIMESTAMPTZ; v_na2 TIMESTAMPTZ; v_attempt2 INTEGER;
BEGIN
  SELECT id INTO v_outbox FROM wf83_ids WHERE name = 'ev_unsupported';
  SELECT next_attempt_at INTO v_na1 FROM platform_outbox_events WHERE id = v_outbox;

  -- Force immediate re-eligibility (bypassing the real clock wait) so
  -- the test can observe the SECOND attempt deterministically.
  UPDATE platform_outbox_events SET next_attempt_at = now() WHERE id = v_outbox;
  PERFORM * FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;

  SELECT attempt_count, next_attempt_at INTO v_attempt2, v_na2 FROM platform_outbox_events WHERE id = v_outbox;
  IF v_attempt2 <> 2 THEN RAISE EXCEPTION 'scenario 7 failed: expected attempt_count=2, got %', v_attempt2; END IF;
  IF v_na2 <= now() + INTERVAL '90 seconds' THEN
    RAISE EXCEPTION 'scenario 8 failed: second-attempt backoff did not advance further than the first (na2=%)', v_na2;
  END IF;
END $$;
INSERT INTO wf83_results VALUES (7,'A retryable failure increments attempt_count by exactly 1 per attempt');
INSERT INTO wf83_results VALUES (8,'next_attempt_at is pushed further into the future on each successive failed attempt (deterministic exponential backoff, no busy-loop retry)');

-- ── 9: A not-yet-due retry is skipped ──
DO $$
DECLARE v_outbox UUID; v_attempt_before INTEGER; v_count INTEGER;
BEGIN
  SELECT id INTO v_outbox FROM wf83_ids WHERE name = 'ev_unsupported';
  SELECT attempt_count INTO v_attempt_before FROM platform_outbox_events WHERE id = v_outbox;
  -- next_attempt_at is still in the future from scenario 7/8 -- do NOT reset it.
  SELECT count(*) INTO v_count FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_count <> 0 THEN RAISE EXCEPTION 'scenario 9 failed: a not-yet-due retryable event was processed anyway'; END IF;
  IF (SELECT attempt_count FROM platform_outbox_events WHERE id = v_outbox) <> v_attempt_before THEN
    RAISE EXCEPTION 'scenario 9 failed: attempt_count changed for an event that was not due';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (9,'An event whose next_attempt_at has not yet elapsed is correctly excluded from the eligible-candidate set and left completely untouched');

-- ── 10: A successful retry completes (the underlying transient
-- condition resolves between attempts) ──
DO $$
DECLARE v_outbox UUID; v_missing_org UUID := gen_random_uuid(); v_row RECORD;
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    jsonb_build_object('notification_type','platform.wf83_retry_ok.v1','title_template_key','wf83.title',
      'target_type','org_admins','target_organization_id', v_missing_org::TEXT),
    gen_random_uuid());
  INSERT INTO wf83_ids VALUES ('ev_retry_success', v_outbox);

  -- First attempt: target_organization_id references an organization
  -- that does not exist yet -- notification_intents' own FK constraint
  -- makes this a genuine, retryable failure (a realistic "referenced
  -- dependency not yet available" condition, distinct from a
  -- permanently-invalid unsupported event type).
  SELECT * INTO v_row FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_row.outcome <> 'retry_scheduled' OR v_row.attempt_count <> 1 THEN
    RAISE EXCEPTION 'scenario 10 setup failed: expected first attempt to fail retryably, outcome=%, attempt_count=%', v_row.outcome, v_row.attempt_count;
  END IF;

  -- The dependency now becomes available.
  INSERT INTO organizations(id,name,type,code) VALUES (v_missing_org,'WF83 Late Org','authority','WF83L');
  INSERT INTO auth.users(id,email) VALUES ('83000000-0001-0000-0000-000000000003','lateadmin@wf83t.local');
  INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
    ('83000000-0001-0000-0000-000000000003', v_missing_org,'WF83-3','Late Org Admin','lateadmin@wf83t.local',true);
  INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
    ('83000000-0001-0000-0000-000000000003','organization', v_missing_org,'authority_admin',true,true);

  UPDATE platform_outbox_events SET next_attempt_at = now() WHERE id = v_outbox;
  SELECT * INTO v_row FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_row.outcome <> 'processed' OR v_row.final_status <> 'completed' OR v_row.attempt_count <> 1 THEN
    RAISE EXCEPTION 'scenario 10 failed: retry did not complete successfully -- outcome=%, final_status=%, attempt_count=%', v_row.outcome, v_row.final_status, v_row.attempt_count;
  END IF;
  IF (SELECT count(*) FROM user_notifications WHERE outbox_event_id = v_outbox) <> 1 THEN
    RAISE EXCEPTION 'scenario 10 failed: expected exactly one notification for the newly-available org admin';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (10,'A retryable failure (target reference not yet available) succeeds on a later attempt once the underlying condition resolves, with attempt_count left at its already-incremented value from the earlier failed attempt, never reset');

-- ── 11 & 12: A poison event eventually dead-letters; a dead-lettered
-- event is never retried automatically ──
DO $$
DECLARE v_outbox UUID; v_i INTEGER; v_row RECORD; v_attempt_at_dl INTEGER;
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.wf83_poison.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    '{}'::JSONB, gen_random_uuid());
  INSERT INTO wf83_ids VALUES ('ev_poison', v_outbox);

  FOR v_i IN 1..5 LOOP
    UPDATE platform_outbox_events SET next_attempt_at = now() WHERE id = v_outbox AND status = 'pending';
    PERFORM * FROM process_platform_outbox_batch(25,'wf83-worker');
  END LOOP;

  IF (SELECT status FROM platform_outbox_events WHERE id = v_outbox) <> 'dead_letter' THEN
    RAISE EXCEPTION 'scenario 11 failed: poison event never reached dead_letter after 5 attempts, status=%', (SELECT status FROM platform_outbox_events WHERE id = v_outbox);
  END IF;
  IF (SELECT attempt_count FROM platform_outbox_events WHERE id = v_outbox) <> 5 THEN
    RAISE EXCEPTION 'scenario 11 failed: expected attempt_count=5 at dead-letter, got %', (SELECT attempt_count FROM platform_outbox_events WHERE id = v_outbox);
  END IF;
  v_attempt_at_dl := (SELECT attempt_count FROM platform_outbox_events WHERE id = v_outbox);

  -- Even if next_attempt_at is forced to "now" and it would otherwise
  -- be index-eligible, status='dead_letter' excludes it from
  -- platform_outbox_events_due_for_processing entirely.
  UPDATE platform_outbox_events SET next_attempt_at = now() WHERE id = v_outbox;
  SELECT count(*) INTO v_i FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;
  IF v_i <> 0 THEN RAISE EXCEPTION 'scenario 12 failed: a dead_letter event was re-selected by the worker'; END IF;
  IF (SELECT attempt_count FROM platform_outbox_events WHERE id = v_outbox) <> v_attempt_at_dl THEN
    RAISE EXCEPTION 'scenario 12 failed: attempt_count changed for a dead-lettered event without an explicit replay';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (11,'A poison event (deterministically, permanently invalid) exhausts the bounded attempt cap and transitions to dead_letter -- it stops consuming worker capacity rather than retrying forever');
INSERT INTO wf83_results VALUES (12,'A dead-lettered event is never automatically re-selected for processing regardless of next_attempt_at -- only an explicit replay (scenario below / replay_dead_lettered_outbox_event) can return it to pending');

-- ── 13 & 14: Duplicate/replayed processing produces no duplicate
-- intent and no duplicate notification ──
DO $$
DECLARE v_outbox UUID; v_intent_count_before INTEGER; v_notif_count_before INTEGER; v_row RECORD;
BEGIN
  SELECT id INTO v_outbox FROM wf83_ids WHERE name = 'ev_ok';
  SELECT count(*) INTO v_intent_count_before FROM notification_intents WHERE outbox_event_id = v_outbox;
  SELECT count(*) INTO v_notif_count_before FROM user_notifications WHERE outbox_event_id = v_outbox;
  IF v_intent_count_before <> 1 OR v_notif_count_before <> 1 THEN
    RAISE EXCEPTION 'scenario 13/14 setup invariant violated: expected exactly one prior intent/notification, got %/%', v_intent_count_before, v_notif_count_before;
  END IF;

  -- Simulate a duplicate claim / operator replay of an
  -- already-completed event by forcing it back to pending (the exact
  -- mechanism replay_dead_lettered_outbox_event uses for a genuine
  -- dead-letter, exercised here directly against a completed row to
  -- prove replay-safety independent of that RPC's own dead_letter-only
  -- guard).
  UPDATE platform_outbox_events SET status = 'pending', next_attempt_at = NULL WHERE id = v_outbox;
  SELECT * INTO v_row FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;

  IF v_row.outcome NOT IN ('processed') OR v_row.intent_id IS NULL THEN
    RAISE EXCEPTION 'scenario 13/14 failed: replay did not complete, outcome=%', v_row.outcome;
  END IF;
  IF (SELECT count(*) FROM notification_intents WHERE outbox_event_id = v_outbox) <> 1 THEN
    RAISE EXCEPTION 'scenario 13 failed: duplicate intent row created on replay';
  END IF;
  IF (SELECT count(*) FROM user_notifications WHERE outbox_event_id = v_outbox) <> 1 THEN
    RAISE EXCEPTION 'scenario 14 failed: duplicate notification row created on replay';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (13,'Reprocessing an already-completed event (forced back to pending, simulating a duplicate claim or replay) creates no duplicate notification_intents row -- create_notification_intent''s own ON CONFLICT returns the existing id');
INSERT INTO wf83_results VALUES (14,'The same replay creates no duplicate user_notifications row -- platform_create_user_notification''s own ON CONFLICT (outbox_event_id, recipient_user_id) is the final backstop regardless of how many times the worker reprocesses the same event');

-- ── 15: Mixed batch isolates failure (one bad event never aborts a
-- good event in the same batch call) ──
DO $$
DECLARE v_good UUID; v_bad UUID; v_row RECORD; v_good_row RECORD; v_bad_row RECORD;
BEGIN
  v_good := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    jsonb_build_object('notification_type','platform.wf83_mixed_good.v1','title_template_key','wf83.title',
      'target_type','specific_users','target_user_ids', jsonb_build_array('83000000-0001-0000-0000-000000000001')),
    gen_random_uuid());
  v_bad := platform_enqueue_outbox_event(
    'platform.wf83_mixed_bad.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    '{}'::JSONB, gen_random_uuid());
  INSERT INTO wf83_ids VALUES ('ev_mixed_good', v_good);
  INSERT INTO wf83_ids VALUES ('ev_mixed_bad', v_bad);

  FOR v_row IN SELECT * FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id IN (v_good, v_bad) LOOP
    IF v_row.event_id = v_good THEN v_good_row := v_row; END IF;
    IF v_row.event_id = v_bad THEN v_bad_row := v_row; END IF;
  END LOOP;

  IF v_good_row.outcome <> 'processed' OR v_good_row.final_status <> 'completed' THEN
    RAISE EXCEPTION 'scenario 15 failed: the good event in a mixed batch did not complete -- outcome=%', v_good_row.outcome;
  END IF;
  IF v_bad_row.outcome <> 'retry_scheduled' THEN
    RAISE EXCEPTION 'scenario 15 failed: the bad event in a mixed batch did not fail as expected -- outcome=%', v_bad_row.outcome;
  END IF;
  IF (SELECT count(*) FROM notification_intents WHERE outbox_event_id = v_good) <> 1 THEN
    RAISE EXCEPTION 'scenario 15 failed: the good event''s intent was rolled back by the bad event''s failure';
  END IF;
END $$;
INSERT INTO wf83_results VALUES (15,'A single poison event in a batch never aborts or rolls back a different, valid event processed earlier or later in the same batch call -- per-item BEGIN/EXCEPTION isolation holds');

-- ── 16: correlation/causation preserved ──
DO $$
DECLARE v_outbox UUID; v_corr UUID := gen_random_uuid(); v_caus UUID := gen_random_uuid();
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, v_corr, v_caus, now(),
    jsonb_build_object('notification_type','platform.wf83_corr.v1','title_template_key','wf83.title',
      'target_type','specific_users','target_user_ids', jsonb_build_array('83000000-0001-0000-0000-000000000001')),
    gen_random_uuid());
  PERFORM * FROM process_platform_outbox_batch(25,'wf83-worker') WHERE event_id = v_outbox;

  IF (SELECT correlation_id FROM platform_outbox_events WHERE id = v_outbox) <> v_corr
     OR (SELECT causation_id FROM platform_outbox_events WHERE id = v_outbox) <> v_caus
  THEN RAISE EXCEPTION 'scenario 16 failed: correlation_id/causation_id changed by worker processing'; END IF;
END $$;
INSERT INTO wf83_results VALUES (16,'correlation_id/causation_id survive worker processing unchanged (protected by Phase 1.1''s own outbox immutability trigger, which this worker never attempts to bypass)');

-- ── 17: Safe error metadata is bounded ──
DO $$
DECLARE v_outbox UUID; v_err TEXT;
BEGIN
  SELECT id INTO v_outbox FROM wf83_ids WHERE name = 'ev_poison';
  SELECT last_error INTO v_err FROM platform_outbox_events WHERE id = v_outbox;
  IF v_err IS NULL THEN RAISE EXCEPTION 'scenario 17 failed: expected a recorded error classification on the dead-lettered poison event'; END IF;
  IF length(v_err) > 500 THEN RAISE EXCEPTION 'scenario 17 failed: last_error exceeds the 500-character bound (%)', length(v_err); END IF;
END $$;
INSERT INTO wf83_results VALUES (17,'last_error is always a bounded (<=500 char), safe technical classification -- never an unbounded stack trace or raw payload dump');

-- ── 18: No delivery claim/status is ever written ──
DO $$
DECLARE v_outbox UUID; v_count INTEGER;
BEGIN
  SELECT id INTO v_outbox FROM wf83_ids WHERE name = 'ev_ok';
  SELECT count(*) INTO v_count FROM user_notifications
  WHERE outbox_event_id = v_outbox AND (read_at IS NOT NULL OR acknowledged_at IS NOT NULL OR archived_at IS NOT NULL);
  IF v_count <> 0 THEN RAISE EXCEPTION 'scenario 18 failed: worker processing wrote a read/ack/archive state, implying delivery -- CAP-003 materialization is not delivery'; END IF;
END $$;
INSERT INTO wf83_results VALUES (18,'"Processed" never implies delivery: worker-created user_notifications rows always have read_at/acknowledged_at/archived_at NULL -- the worker has no notion of whether/when a recipient actually saw anything');

-- ── 19: No legacy notification row is ever created ──
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notifications WHERE user_id IN
    ('83000000-0001-0000-0000-000000000001','83000000-0001-0000-0000-000000000002','83000000-0001-0000-0000-000000000003');
  IF v_count <> 0 THEN RAISE EXCEPTION 'scenario 19 failed: the outbox worker wrote to the legacy notifications table, count=%', v_count; END IF;
END $$;
INSERT INTO wf83_results VALUES (19,'The legacy notifications table is completely untouched by any outbox worker activity in this suite -- CAP-003 Phase 1.3 remains purely additive');

-- ── 20: Phase 1.2 behavior unchanged (direct, non-worker call sites
-- still function exactly as before) ──
DO $$
DECLARE v_outbox UUID; v_intent_id UUID; v_status TEXT; v_resolved INTEGER; v_skipped INTEGER;
BEGIN
  v_outbox := platform_enqueue_outbox_event(
    'platform.wf83_direct.v1','platform','platform',gen_random_uuid(),
    '83000000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
    '{}'::JSONB, gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox, 'platform.wf83_direct_notif.v1','wf83.direct.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['83000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  SELECT status, resolved_count, skipped_count INTO v_status, v_resolved, v_skipped FROM resolve_notification_intent(v_intent_id);
  IF v_status <> 'resolved' OR v_resolved <> 1 OR v_skipped <> 0 THEN
    RAISE EXCEPTION 'scenario 20 failed: direct create_notification_intent/resolve_notification_intent call site no longer behaves as Phase 1.2 established -- status=%, resolved=%, skipped=%', v_status, v_resolved, v_skipped;
  END IF;
END $$;
INSERT INTO wf83_results VALUES (20,'create_notification_intent/resolve_notification_intent called directly (outside the worker, exactly as Phase 1.2''s own suite exercises them) behave identically to before Phase 1.3 -- the worker adds a new caller, it does not modify the primitives themselves');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf83_results;
  IF v_count <> 20 THEN
    RAISE EXCEPTION 'Expected 20 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification outbox worker behavioral tests PASSED: %/20', v_count;
END $$;

ROLLBACK;
