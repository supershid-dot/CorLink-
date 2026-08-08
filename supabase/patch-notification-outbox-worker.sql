-- ============================================================
-- CAP-003 Phase 1.3 -- Outbox Worker, Retry & Dead-Letter
-- Processing.
--
-- Implements docs/78-notification-outbox-architecture.md §25's Phase
-- 1.3 line item: "Outbox worker: bounded-batch SKIP LOCKED claiming,
-- retry/backoff, dead-letter handling -- the direct architectural
-- sibling of CAP-002 Phase 5.4." Follows Phase 5.4's own
-- (process_workflow_sla_due_batch, docs/77) established worker shape
-- exactly: bounded per-call batch claiming via per-candidate
-- SELECT ... FOR UPDATE SKIP LOCKED, re-derivation of eligibility from
-- the LOCKED row (never the earlier non-locking candidate snapshot),
-- one BEGIN/EXCEPTION block per item so a single poison event never
-- aborts the batch, a hard-clamped batch-size ceiling independent of
-- caller input, and service_role-only execution granted to nothing
-- else. This patch is PURELY ADDITIVE: it creates only new functions
-- (plus one registry row for the generic event type it processes) and
-- touches zero bytes of any Phase 1.0A/1.0B/1.1/1.2 or CAP-002 object.
--
-- ─── Why no persisted 'claimed'/'processing' resting state ─────────
-- platform_outbox_events.status already allows 'claimed'/'processing'
-- (Phase 1.1's own CHECK constraint), but this milestone never leaves
-- a row durably in either state. Every candidate is claimed, processed
-- to a terminal outcome, and written back to a terminal value
-- ('pending' again with incremented attempt_count/pushed-out
-- next_attempt_at, 'completed', or 'dead_letter') within the SAME
-- per-item BEGIN/EXCEPTION block, inside the SAME outer transaction
-- that holds the row's FOR UPDATE lock. A row is therefore never
-- visible to any other transaction in a 'claimed'/'processing' state
-- at all -- there is no persistent claim/lease to go stale, so no
-- stale-claim recovery machinery is needed. This is the simplest
-- crash-safe design available given transaction-scoped locking already
-- provides the safety property lease machinery would otherwise exist
-- to provide (governing instruction: "If transaction-scoped row
-- locking makes persistent claim ownership unnecessary: do not invent
-- lease machinery. Prefer the simplest architecture that is
-- crash-safe."). claimed_by/claimed_at are still written on every
-- terminal outcome, purely as operational telemetry (who/when last
-- touched this row), never as a durable ownership token anything reads
-- to decide eligibility.
--
-- ─── Crash recovery reasoning ────────────────────────────────────
-- Because the whole batch call is one transaction, a crash at ANY
-- point before the top-level statement commits (before claim, after
-- claim, during intent creation, after intent creation but before
-- resolution, after notification materialization but before marking
-- the outbox event terminal) simply rolls back that item's writes
-- (implicit plpgsql savepoint on exception) or, in the catastrophic
-- whole-connection-dies case, the entire in-flight batch -- either way
-- every earlier "completed" event ALSO reverts to its pre-batch state
-- if the whole connection dies mid-batch. This is safe, not merely
-- tolerated: create_notification_intent's own ON CONFLICT (Phase 1.2)
-- and platform_create_user_notification's own ON CONFLICT (Phase 1.1)
-- both dedupe by durable business identity, so redoing an
-- already-safely-completed item on the next run produces zero
-- duplicate intents or notifications -- convergence is guaranteed by
-- those two independent uniqueness constraints, not by this worker's
-- own bookkeeping.
--
-- ─── Supported event shape (narrowed, within docs/78's own
-- discretion) ────────────────────────────────────────────────────
-- docs/78 §25 explicitly defers real per-module event-type mappings to
-- Phase 1.4 ("module integration foundation... adopted by one pilot
-- module"). Since no production module enqueues real business events
-- yet, this worker recognizes exactly ONE generic, worker-processable
-- event_type -- platform.generic_notification_request.v1 -- whose
-- payload directly carries the exact parameters
-- create_notification_intent() already needs (notification_type,
-- title_template_key, template_params, priority, target_type, and the
-- matching target_* field), narrowed to Phase 1.2's own six supported
-- target kinds. This is a generic passthrough envelope, not a
-- module-specific business-event mapping -- it invents no new
-- business-event vocabulary and duplicates no validation (malformed/
-- out-of-range fields are rejected by create_notification_intent's own
-- existing CHECK constraints and required-field checks, reused as-is).
-- Any other event_type is "not yet supported" by this worker and is
-- rejected deterministically (see retry/dead-letter model below) --
-- Phase 1.4's own module adapters will each register their own
-- concrete event_type and extend this worker's dispatch, not
-- broadened here merely to look more useful.
--
-- ─── Batch size (operational constant, not fixed by docs/78) ──────
-- docs/78 §5.7/§13/§26 explicitly leaves the exact numeric bound to
-- "the implementation phase," instructing exactly this milestone to
-- pick one. Reuses Phase 5.4's own already-established constant for
-- consistency across this codebase's two SKIP-LOCKED dispatchers:
-- default 25 events per call, hard-clamped to [1, 200] regardless of
-- caller input (process_platform_outbox_batch's own LEAST/GREATEST).
--
-- ─── Retry/backoff/dead-letter (operational constants) ────────────
-- Deterministic exponential backoff, no client-controlled or random
-- jitter (governing instruction: "Never use random client-controlled
-- retry values"; jitter itself is explicitly optional per docs/78 §15's
-- own "for example" phrasing and is left as a documented future
-- refinement, not a blocker): 1 minute * 2^(attempt_count-1), capped at
-- 30 minutes. Terminal dead-letter threshold: 5 attempts (a
-- conservative default matching common bounded-retry convention,
-- yielding roughly 15 minutes of wall-clock retry window before
-- termination). Both are operational tuning constants, not business
-- rules -- revisable by a future milestone without any architecture
-- change, exactly as docs/78 §26/§27.2 anticipates.
--
-- ─── Zero-recipient outcome (resolved via existing architecture,
-- not guesswork) ────────────────────────────────────────────────
-- docs/78 §8 is explicit: a candidate failing authorization revalidation
-- "receives nothing -- silently, not as a batch failure." Phase 1.2's
-- own resolve_notification_intent() already returns status='failed'
-- for zero resolved_count (whether zero candidates existed at all, or
-- every candidate was legitimately skipped) -- that is INTENT-level
-- vocabulary for "zero recipients," never WORKER-level vocabulary for
-- "processing malfunctioned." This worker therefore marks the outbox
-- event 'completed' whenever resolve_notification_intent() returns
-- without raising, REGARDLESS of resolved_count -- a correctly-reached
-- zero-recipient decision is a successful completion of CAP-003's own
-- job, never a retryable/dead-letterable failure. Retrying it would
-- never change a today's-zero-recipients-are-correct outcome, and
-- treating it as an error would violate §8's own "never a batch
-- failure" rule.
--
-- ─── What this phase does NOT do ────────────────────────────────
-- No real module event producers (Requests/Tasks/Meetings/Entry/
-- Prisoner Letters/CAP-002 -- Phase 1.4). No Realtime cutover, no
-- legacy notifications migration, no notification preferences, no
-- email/push/SMS, no frontend changes, no scheduler/cron deployment
-- (docs/78 §13 explicitly defers scheduling/deployment choice, exactly
-- as Phase 5.4 itself deferred it) -- this patch adds only the
-- worker-facing SQL entry point a future scheduler would call, never
-- the scheduler itself.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── Generic worker-processable event type (registry entry) ────────
-- Declares the one event_type this worker actually recognizes (see
-- header). Configuration data, not runtime logic -- exactly what
-- platform_event_type_registry (Phase 1.1) exists for. Not mandatory
-- (a generic validation/test envelope, not a business-critical type)
-- and does not require acknowledgement.
INSERT INTO platform_event_type_registry (event_type, owning_module, is_mandatory, requires_acknowledgement, description)
VALUES (
  'platform.generic_notification_request.v1', 'platform', FALSE, FALSE,
  'Generic worker-processable notification-request envelope (CAP-003 Phase 1.3). Payload carries create_notification_intent()''s own parameters directly (notification_type, title_template_key, template_params, priority, target_type, target_*). Used for platform-originated and test/validation events until Phase 1.4 registers real per-module event types.'
)
ON CONFLICT (event_type) DO NOTHING;

-- ─── 1. Candidate discovery -- private, read-only, mirrors
--    workflow_sla_clocks_due_for_warning's own shape (docs/78 §2.5,
--    docs/77). Plain STABLE SQL, no locking here -- claiming happens
--    per-candidate, under FOR UPDATE SKIP LOCKED, in the processing
--    loop below; this function never blocks and never itself decides
--    eligibility beyond the cheap index-backed pre-filter. Uses
--    idx_platform_outbox_events_pending (Phase 1.1's own partial index
--    on (next_attempt_at) WHERE status = 'pending') directly. ────────
CREATE OR REPLACE FUNCTION platform_outbox_events_due_for_processing(p_limit INTEGER DEFAULT 25)
RETURNS TABLE (id UUID) AS $$
  SELECT e.id
  FROM platform_outbox_events e
  WHERE e.status = 'pending'
    AND (e.next_attempt_at IS NULL OR e.next_attempt_at <= clock_timestamp())
  ORDER BY e.next_attempt_at NULLS FIRST, e.created_at
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION platform_outbox_events_due_for_processing(INTEGER) FROM PUBLIC, anon, authenticated;

-- ─── 2. Deterministic backoff -- pure function of attempt_count, no
--    randomness/jitter (see header). Exponential, capped. ───────────
CREATE OR REPLACE FUNCTION platform_outbox_worker_backoff_interval(p_attempt_count INTEGER)
RETURNS INTERVAL AS $$
  SELECT LEAST(
    INTERVAL '1 minute' * POWER(2, GREATEST(p_attempt_count, 1) - 1),
    INTERVAL '30 minutes'
  );
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION platform_outbox_worker_backoff_interval(INTEGER) FROM PUBLIC, anon, authenticated;

-- ─── 3. process_platform_outbox_batch -- the single worker-facing
--    entry point. p_limit hard-clamped to [1,200] regardless of caller
--    input (identical shape to process_workflow_sla_due_batch's own
--    clamp). p_worker_id is an opaque, caller-supplied label for
--    claimed_by telemetry only (defaults to the backend pid) -- never
--    an authorization input, never trusted for anything but
--    observability. Returns one row per candidate examined --
--    processed, skipped, retry-scheduled, or dead-lettered -- so the
--    caller (a future scheduler) can log/observe without a redundant
--    worker-log table; the real evidence stays on
--    platform_outbox_events' own already-existing processing-state
--    columns and, for intents, notification_intents itself (both
--    already durable, both already index-backed). Granted ONLY to
--    service_role -- a worker/system execution path, never exposed to
--    ordinary authenticated users or anon, identical posture to every
--    other CAP-002/CAP-003 dispatcher entry point in this codebase. ──
CREATE OR REPLACE FUNCTION process_platform_outbox_batch(p_limit INTEGER DEFAULT 25, p_worker_id TEXT DEFAULT NULL)
RETURNS TABLE (
  event_id        UUID,
  event_type      TEXT,
  outcome         TEXT,
  intent_id       UUID,
  attempt_count   INTEGER,
  next_attempt_at TIMESTAMPTZ,
  final_status    TEXT
) AS $$
DECLARE
  v_limit          INTEGER;
  v_worker_id      TEXT;
  rec              RECORD;
  v_event          platform_outbox_events;
  v_intent_id      UUID;
  v_resolve_status TEXT;
  v_resolve_count  INTEGER;
  v_skip_count     INTEGER;
  v_outcome        TEXT;
  v_new_attempt    INTEGER;
  v_next_attempt   TIMESTAMPTZ;
  v_final_status   TEXT;
  v_error_text     TEXT;
  v_ret_attempts   INTEGER;
BEGIN
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 200);
  v_worker_id := COALESCE(p_worker_id, 'pid:' || pg_backend_pid()::TEXT);

  FOR rec IN SELECT d.id FROM platform_outbox_events_due_for_processing(v_limit) d LOOP
    v_event := NULL;
    v_intent_id := NULL;
    v_outcome := NULL;
    v_next_attempt := NULL;
    v_final_status := NULL;
    v_error_text := NULL;
    v_ret_attempts := NULL;

    BEGIN
      -- Claim: never blocks. A row another in-flight batch already
      -- holds is simply skipped and left for the next call --
      -- identical guarantee CAP-002 Phase 5.4's own SKIP LOCKED claim
      -- already provides and this codebase's own concurrency suites
      -- already verify for that dispatcher.
      SELECT * INTO v_event FROM platform_outbox_events WHERE id = rec.id FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        v_outcome := 'skipped_locked';
      -- Re-derive eligibility from the LOCKED row -- never trust the
      -- earlier non-locking candidate snapshot (governing instruction;
      -- identical discipline to every workflow_sla_clocks_due_for_*
      -- consumer in this codebase). A concurrent batch, or an operator
      -- replay/dead-letter transition, may have changed this row's
      -- state since discovery.
      ELSIF v_event.status <> 'pending' THEN
        v_outcome := 'already_processed';
        v_ret_attempts := v_event.attempt_count;
      ELSIF v_event.next_attempt_at IS NOT NULL AND v_event.next_attempt_at > clock_timestamp() THEN
        v_outcome := 'skipped_not_due';
        v_ret_attempts := v_event.attempt_count;
      ELSE
        -- Supported-event-shape dispatch (see header) -- closed,
        -- structural, never dynamic SQL. Any other event_type is a
        -- deterministic, never-retriable-into-success condition; it is
        -- still routed through the SAME bounded retry/dead-letter
        -- machinery below (never a special-cased immediate
        -- dead-letter) so there is exactly one worker-state system, per
        -- the governing instruction -- "do not retry forever on
        -- deterministic invalid data" is satisfied by the shared
        -- attempt cap applying uniformly, not by a second state
        -- machine. The stored last_error classification (below) is
        -- what lets an operator distinguish this case from a genuine
        -- transient/infrastructure failure.
        IF v_event.event_type <> 'platform.generic_notification_request.v1' THEN
          RAISE EXCEPTION 'unsupported_event_type: % (Phase 1.3 recognizes only platform.generic_notification_request.v1; per-module event types are Phase 1.4''s own concern)', v_event.event_type
            USING ERRCODE = 'P0001';
        END IF;

        -- create_notification_intent() derives organization_id/
        -- source_module/source_record_type/source_record_id FROM the
        -- outbox event row itself (Phase 1.2's own design) -- only the
        -- notification-shape/target-descriptor fields come from
        -- payload. Every field extracted here is validated by
        -- create_notification_intent()'s own existing required-field
        -- checks and by notification_intents' own CHECK constraints
        -- (target-shape, bounded array, closed target_type allowlist,
        -- versioned notification_type pattern) -- nothing here
        -- duplicates that validation; a malformed/out-of-range payload
        -- surfaces as a genuine exception from that reused primitive,
        -- caught by this same per-item handler.
        v_intent_id := create_notification_intent(
          v_event.id,
          v_event.payload ->> 'notification_type',
          v_event.payload ->> 'title_template_key',
          COALESCE(v_event.payload -> 'template_params', '{}'::JSONB),
          v_event.payload ->> 'priority',
          v_event.payload ->> 'target_type',
          CASE WHEN v_event.payload ? 'target_user_ids'
               THEN ARRAY(SELECT jsonb_array_elements_text(v_event.payload -> 'target_user_ids'))::UUID[]
               ELSE NULL END,
          NULLIF(v_event.payload ->> 'target_organization_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_section_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_workflow_instance_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_work_item_id', '')::UUID
        );

        -- resolve_notification_intent() (Phase 1.2, reused verbatim --
        -- never duplicated): candidate resolution + per-candidate
        -- authorization revalidation, idempotent (FOR UPDATE on the
        -- intent row -- a concurrent resolver, including a second
        -- worker batch that raced to the same intent, observes the
        -- already-recorded terminal status rather than double-
        -- processing). Zero-resolved-count is a legitimate outcome
        -- (see header) -- never itself raises, never itself a reason to
        -- retry/dead-letter this outbox event.
        SELECT r.status, r.resolved_count, r.skipped_count
          INTO v_resolve_status, v_resolve_count, v_skip_count
          FROM resolve_notification_intent(v_intent_id) r;

        UPDATE platform_outbox_events
        SET status = 'completed', processed_at = clock_timestamp(),
            claimed_by = v_worker_id, claimed_at = clock_timestamp(),
            last_error = NULL
        WHERE id = v_event.id;

        v_final_status := 'completed';
        v_outcome := CASE WHEN v_resolve_count = 0 THEN 'processed_zero_recipients' ELSE 'processed' END;
        v_ret_attempts := v_event.attempt_count;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      -- Failure isolation: this block's implicit savepoint rolls back
      -- only this item's own writes (e.g. a partially-inserted intent
      -- row that never committed) -- every other item in this batch,
      -- already processed earlier in the loop, is unaffected. Bounded,
      -- safe error text only -- never the raw payload, never a stack
      -- trace, truncated defensively regardless of source (governing
      -- instruction: "Do not persist... full confidential payload...
      -- secrets").
      v_error_text := LEFT(SQLERRM, 500);

      IF v_event.id IS NULL OR v_event.id IS DISTINCT FROM rec.id THEN
        -- The claim itself never completed (extremely rare -- the
        -- locking SELECT itself failed) -- we hold no lock and no
        -- known attempt_count for this row, so we make no further
        -- write against it; it remains 'pending' and will be
        -- reconsidered by a future batch call.
        v_outcome := 'failed_before_claim: ' || v_error_text;
      ELSE
        v_new_attempt := v_event.attempt_count + 1;
        v_ret_attempts := v_new_attempt;

        IF v_new_attempt >= 5 THEN
          UPDATE platform_outbox_events
          SET status = 'dead_letter', attempt_count = v_new_attempt,
              last_error = v_error_text,
              claimed_by = v_worker_id, claimed_at = clock_timestamp()
          WHERE id = v_event.id;
          v_final_status := 'dead_letter';
          v_outcome := 'dead_lettered';
        ELSE
          v_next_attempt := clock_timestamp() + platform_outbox_worker_backoff_interval(v_new_attempt);
          UPDATE platform_outbox_events
          SET status = 'pending', attempt_count = v_new_attempt, next_attempt_at = v_next_attempt,
              last_error = v_error_text,
              claimed_by = v_worker_id, claimed_at = clock_timestamp()
          WHERE id = v_event.id;
          v_final_status := 'pending';
          v_outcome := 'retry_scheduled';
        END IF;
      END IF;
    END;

    event_id := rec.id;
    event_type := v_event.event_type;
    outcome := v_outcome;
    intent_id := v_intent_id;
    attempt_count := v_ret_attempts;
    next_attempt_at := v_next_attempt;
    final_status := v_final_status;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION process_platform_outbox_batch(INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION process_platform_outbox_batch(INTEGER, TEXT) TO service_role;

-- ─── 4. Dead-letter replay -- docs/78 §5.8's own explicit requirement
--    ("administrator-visible and explicitly re-playable... itself an
--    audited administrative act, not an automatic retry"). Only
--    resets a genuinely dead_letter row -- never touches a pending/
--    completed row, so this can never be used to bypass the retry
--    machinery for a still-in-flight event. service_role-only, same
--    posture as every other CAP-003 internal primitive -- no new
--    application permission invented; an operator invokes this via a
--    service-role administrative channel exactly as the worker itself
--    is already invoked. ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION replay_dead_lettered_outbox_event(p_event_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_updated INTEGER;
BEGIN
  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'event_id is required' USING ERRCODE = '22023';
  END IF;

  UPDATE platform_outbox_events
  SET status = 'pending', attempt_count = 0, next_attempt_at = NULL, last_error = NULL
  WHERE id = p_event_id AND status = 'dead_letter';

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION replay_dead_lettered_outbox_event(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION replay_dead_lettered_outbox_event(UUID) TO service_role;

COMMIT;
