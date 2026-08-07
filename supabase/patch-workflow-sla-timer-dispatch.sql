-- ============================================================
-- CAP-002 Phase 5.4 — SLA Timer Dispatch & Worker Foundation.
--
-- Implements the bounded, concurrency-safe, idempotent worker/
-- dispatcher mechanism docs/60's "Timer execution" and docs/73's
-- "Queue model" anticipate but explicitly defer: "A future dispatcher
-- should claim due timers in bounded batches, use skip-locked
-- semantics, write a unique timer-fired event... Repeated dispatch is
-- safe because the causal key is unique." Phase 5.3/5.3A already
-- built every synchronous primitive and the three private due-
-- detection functions this phase consumes
-- (workflow_sla_clocks_due_for_warning/_breach/_escalation). Nothing
-- in Phase 5.3/5.3A ever called them on a schedule. This phase adds
-- the batch-claiming loop that does, and nothing else.
--
-- Per docs/73 design decision 1 (an additive layer, not a rewrite),
-- this patch is PURELY ADDITIVE: it creates only new functions. It
-- does not modify, replace, or touch a single byte of any function
-- from Phase 1 through 5.3A — not workflow_sla_clocks_due_for_warning/
-- _breach/_escalation, not record_workflow_sla_warning/
-- record_workflow_sla_breach/trigger_workflow_sla_escalation, not any
-- graph/approval/routing/delegation function. Every existing structural
-- validator's "prior-phase baseline intact" assertion continues to
-- hold unchanged.
--
-- ─── Why this phase does NOT call the existing manual RPCs ─────────
-- record_workflow_sla_warning, record_workflow_sla_breach, and
-- trigger_workflow_sla_escalation each require
-- workflow_actor_is_active() (auth.uid() must resolve to a real,
-- active human user) and can_manage_workflow_sla_clock() (instance
-- owner/manager or the work item's own assignee). Both checks are
-- correct and load-bearing for a HUMAN-initiated action — exactly
-- docs/73's "Manual escalation... An authorized actor... may trigger
-- the next configured escalation level early." A system dispatcher has
-- no such actor: it is not the current work item's holder, not a
-- supervisor, not an administrator "with authority over the instance"
-- in the human sense docs/73 means. Calling the manual RPCs would
-- require either inventing a synthetic "system user" identity (a new,
-- unapproved identity/permission concept the governing instruction
-- forbids: "Do not create a new business permission model") or
-- weakening those RPCs' actor checks to also accept no-actor calls
-- (which would silently loosen the exact authorization boundary that
-- protects every HUMAN-invoked manual escalation, an unacceptable risk
-- to already-verified, already-pushed Phase 5.3A protected code).
--
-- This phase instead adds three new, small, narrowly-scoped
-- "automatic" processing functions
-- (workflow_sla_process_due_warnings/_breaches/_escalations) that
-- perform EXACTLY the same state transition, the same evidence shape,
-- and the same ordering/terminal/pause guards as their manual
-- counterparts, reusing docs/73's own due-detection helpers and the
-- exact calendar-aware offset functions Phase 5.3A already built
-- (workflow_calculate_calendar_offset_backward,
-- workflow_calculate_calendar_deadline) — but gated by the row's own
-- claimed FOR UPDATE SKIP LOCKED lock and business state instead of a
-- human actor check, and recording actor_id = NULL /
-- triggered_by = 'automatic' (a value workflow_escalation_events'
-- own CHECK constraint already anticipated in Phase 5.3, unused until
-- now). This is "reuse the Phase 5.3 warning/breach/escalation
-- primitive's semantics" in the sense the governing instruction means
-- (same rules, same evidence contract, same idempotent replay
-- guarantee) without either inventing a system identity or touching
-- the protected human-actor RPCs. See docs/77 for the full reasoning.
--
-- ─── Batch size ──────────────────────────────────────────────────
-- Docs/60/73 approve "bounded batches" but fix no numeric value
-- ("Choose the exact initial bound only after inspecting docs/60/73/76
-- for an approved value. If no numeric value is approved, choose a
-- conservative implementation constant and document it clearly as an
-- operational limit"). This patch's operational constant: the caller
-- may request up to 25 due items per category (warning/breach/
-- escalation) by default, hard-capped at 200 per category regardless
-- of what a caller requests (LEAST/GREATEST clamp inside
-- process_workflow_sla_due_batch) — worst case 600 items across all
-- three categories in a single call. This is an operational tuning
-- constant, not a business rule, and may be revisited by a future
-- milestone without any architecture change.
--
-- ─── What this phase does NOT do ────────────────────────────────
-- No pg_cron schedule, no external scheduler wiring, no notification
-- delivery (remind_actor/notify_supervisor/create_exception_work_item/
-- route_higher_scope/add_replace_candidates/follow_branch remain
-- evidence-only, exactly as Phase 5.3 left them — only mark_breached
-- performs a real effect, exactly as before), no outbox table or
-- enqueue call (no outbox infrastructure exists anywhere in this
-- codebase yet — see docs/77 "Deferred: outbox integration"), no
-- module adapters, no frontend, no new workflow node types, no
-- automatic workflow approval/rejection/cancellation/completion, and
-- no change to restart_workflow_sla_clock's Phase 5.3A-corrected
-- private/ungranted status.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── 1. Deterministic idempotency key for automatically-fired
--    evidence. A pure function of (clock_id, discriminator) so a
--    repeated dispatcher call against the same due item always derives
--    the identical key -- forensic traceability only; safety against
--    double-processing itself comes from the FOR UPDATE SKIP LOCKED
--    claim plus the business-state re-check under that lock (see
--    each processor below), not from idempotency-key comparison (the
--    replay-with-different-input protection the manual RPCs need
--    exists because a CLIENT supplies their key; this key is always
--    server-derived, so that failure mode cannot occur). Uses
--    pgcrypto's md5()::uuid, the exact deterministic-UUID idiom this
--    codebase's own performance fixtures already use (e.g.
--    test-workflow-backend-foundation-performance.sql) -- no new
--    extension dependency introduced. ─────────────────────────────
CREATE OR REPLACE FUNCTION workflow_sla_automatic_idempotency_key(p_clock_id UUID, p_discriminator TEXT)
RETURNS UUID AS $$
  SELECT md5('wf_sla_auto_dispatch:' || p_clock_id::TEXT || ':' || p_discriminator)::UUID;
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_automatic_idempotency_key(UUID,TEXT) FROM PUBLIC, anon, authenticated;

-- ─── 2. workflow_sla_process_due_warnings — automatic counterpart of
--    record_workflow_sla_warning. Claims each candidate clock's row
--    with FOR UPDATE SKIP LOCKED (never blocks; a concurrently locked
--    row is reported skipped_locked and left for the next batch), then
--    re-derives state/order/due-ness from the LOCKED row (never trusts
--    the earlier non-locking due-detection snapshot), exactly
--    mirroring record_workflow_sla_warning's own re-check-after-lock
--    discipline. Never advances warned_up_to_index out of order, never
--    fires a warning for a paused/terminal clock, never double-fires
--    (idx_workflow_sla_clock_events_warning_once is the same hard
--    database backstop the manual path already relies on). One
--    BEGIN/EXCEPTION block per candidate isolates a single item's
--    failure from the rest of the batch -- a failure rolls back only
--    that item's own effects (plpgsql's implicit savepoint), never the
--    batch's already-processed items. ─────────────────────────────
CREATE OR REPLACE FUNCTION workflow_sla_process_due_warnings(p_limit INTEGER)
RETURNS TABLE (clock_id UUID, instance_id UUID, warning_offset_index INTEGER, outcome TEXT, evidence_id UUID)
AS $$
DECLARE
  rec RECORD;
  v_clock workflow_sla_clocks;
  v_offset JSONB;
  v_due_at TIMESTAMPTZ;
  v_idem UUID;
  v_evidence_id UUID;
  v_outcome TEXT;
BEGIN
  FOR rec IN SELECT * FROM workflow_sla_clocks_due_for_warning(p_limit) LOOP
    v_evidence_id := NULL;
    BEGIN
      SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = rec.clock_id FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        v_outcome := 'skipped_locked';
      ELSIF v_clock.state <> 'running' THEN
        v_outcome := 'skipped_not_running';
      ELSIF rec.warning_offset_index <= v_clock.warned_up_to_index THEN
        v_outcome := 'already_processed';
      ELSIF rec.warning_offset_index <> v_clock.warned_up_to_index + 1 THEN
        v_outcome := 'skipped_out_of_order';
      ELSE
        v_offset := v_clock.warning_offsets -> rec.warning_offset_index;
        v_due_at := workflow_calculate_calendar_offset_backward(
          v_clock.effective_deadline_adjusted, (v_offset ->> 'amount')::NUMERIC, v_offset ->> 'unit',
          v_clock.calendar_version_id, v_clock.timezone
        );
        IF clock_timestamp() < v_due_at THEN
          v_outcome := 'skipped_not_due';
        ELSE
          v_idem := workflow_sla_automatic_idempotency_key(rec.clock_id, 'warning:' || rec.warning_offset_index::TEXT);

          UPDATE workflow_sla_clocks
          SET warned_up_to_index = rec.warning_offset_index, lock_version = workflow_sla_clocks.lock_version + 1
          WHERE id = rec.clock_id;

          INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
          VALUES (rec.clock_id, v_clock.instance_id, 'warning_fired', NULL, v_idem,
            jsonb_build_object('warning_offset_index', rec.warning_offset_index, 'source', 'automatic_dispatch'))
          RETURNING id INTO v_evidence_id;

          v_outcome := 'processed';
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_outcome := 'failed: ' || SQLERRM;
      v_evidence_id := NULL;
    END;

    clock_id := rec.clock_id;
    instance_id := rec.instance_id;
    warning_offset_index := rec.warning_offset_index;
    outcome := v_outcome;
    evidence_id := v_evidence_id;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_process_due_warnings(INTEGER) FROM PUBLIC, anon, authenticated;

-- ─── 3. workflow_sla_process_due_breaches — automatic counterpart of
--    record_workflow_sla_breach. breached_at is set at most once
--    (idx_workflow_sla_clock_events_breach_once backstops this
--    exactly as it already does for the manual/mark_breached paths);
--    an already-breached clock is a safe no-op, never an error, mirror-
--    ing record_workflow_sla_breach's own "two independent paths can
--    legitimately reach the same breach fact" precedent. ───────────
CREATE OR REPLACE FUNCTION workflow_sla_process_due_breaches(p_limit INTEGER)
RETURNS TABLE (clock_id UUID, instance_id UUID, outcome TEXT, evidence_id UUID)
AS $$
DECLARE
  rec RECORD;
  v_clock workflow_sla_clocks;
  v_idem UUID;
  v_evidence_id UUID;
  v_outcome TEXT;
BEGIN
  FOR rec IN SELECT * FROM workflow_sla_clocks_due_for_breach(p_limit) LOOP
    v_evidence_id := NULL;
    BEGIN
      SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = rec.clock_id FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        v_outcome := 'skipped_locked';
      ELSIF v_clock.state <> 'running' THEN
        v_outcome := 'skipped_not_running';
      ELSIF v_clock.breached_at IS NOT NULL THEN
        v_outcome := 'already_processed';
      ELSIF clock_timestamp() < v_clock.effective_deadline_adjusted THEN
        v_outcome := 'skipped_not_due';
      ELSE
        v_idem := workflow_sla_automatic_idempotency_key(rec.clock_id, 'breach');

        UPDATE workflow_sla_clocks
        SET breached_at = clock_timestamp(), lock_version = workflow_sla_clocks.lock_version + 1
        WHERE id = rec.clock_id;

        INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
        VALUES (rec.clock_id, v_clock.instance_id, 'breached', NULL, v_idem,
          jsonb_build_object('source', 'automatic_dispatch'))
        RETURNING id INTO v_evidence_id;

        v_outcome := 'processed';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_outcome := 'failed: ' || SQLERRM;
      v_evidence_id := NULL;
    END;

    clock_id := rec.clock_id;
    instance_id := rec.instance_id;
    outcome := v_outcome;
    evidence_id := v_evidence_id;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_process_due_breaches(INTEGER) FROM PUBLIC, anon, authenticated;

-- ─── 4. workflow_sla_process_due_escalations — automatic counterpart
--    of trigger_workflow_sla_escalation. Advances at most one level
--    per due candidate (current_escalation_level + 1, re-verified
--    under the row lock -- never skips, never re-fires
--    workflow_escalation_events_no_duplicate_level's UNIQUE(clock_id,
--    escalation_level_id) backstop). Records triggered_by =
--    'automatic', triggering_actor_id = NULL -- the exact combination
--    workflow_escalation_events_manual_actor_check's own CHECK
--    constraint already allowed since Phase 5.3, unused until this
--    phase. mark_breached is the sole action with a real, self-
--    contained effect (sets breached_at idempotently, exactly as the
--    manual path does); the other six of the closed seven-action
--    allowlist are recorded as evidence only -- no notification is
--    sent, no candidate is added to a live round, no graph branch is
--    followed, no external work item is created, per docs/60's
--    unconditional prohibition on automatic approval/rejection/
--    cancellation/closure and Phase 5.3's own narrow evidence-only
--    resolution of the same six actions. ───────────────────────────
CREATE OR REPLACE FUNCTION workflow_sla_process_due_escalations(p_limit INTEGER)
RETURNS TABLE (
  clock_id UUID, instance_id UUID, escalation_level_id UUID,
  level_order INTEGER, action_code TEXT, outcome TEXT, evidence_id UUID
)
AS $$
DECLARE
  rec RECORD;
  v_clock workflow_sla_clocks;
  v_level workflow_escalation_levels;
  v_idem UUID;
  v_evidence_id UUID;
  v_outcome TEXT;
  v_new_lock_version BIGINT;
BEGIN
  FOR rec IN SELECT * FROM workflow_sla_clocks_due_for_escalation(p_limit) LOOP
    v_evidence_id := NULL;
    BEGIN
      SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = rec.clock_id FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        v_outcome := 'skipped_locked';
      ELSIF v_clock.state <> 'running' THEN
        v_outcome := 'skipped_not_running';
      ELSIF v_clock.escalation_policy_id IS NULL THEN
        v_outcome := 'skipped_no_policy';
      ELSIF EXISTS (
        SELECT 1 FROM workflow_escalation_events e
        WHERE e.clock_id = rec.clock_id AND e.escalation_level_id = rec.escalation_level_id
      ) THEN
        v_outcome := 'already_processed';
      ELSIF v_clock.current_escalation_level + 1 <> rec.level_order THEN
        IF v_clock.current_escalation_level >= rec.level_order THEN
          v_outcome := 'already_processed';
        ELSE
          v_outcome := 'skipped_out_of_order';
        END IF;
      ELSE
        SELECT * INTO v_level FROM workflow_escalation_levels WHERE id = rec.escalation_level_id;
        v_idem := workflow_sla_automatic_idempotency_key(rec.clock_id, 'escalation:' || rec.level_order::TEXT);

        IF v_level.action_code = 'mark_breached' THEN
          UPDATE workflow_sla_clocks
          SET breached_at = COALESCE(breached_at, clock_timestamp()),
              current_escalation_level = rec.level_order,
              lock_version = workflow_sla_clocks.lock_version + 1
          WHERE id = rec.clock_id
          RETURNING workflow_sla_clocks.lock_version INTO v_new_lock_version;
        ELSE
          UPDATE workflow_sla_clocks
          SET current_escalation_level = rec.level_order, lock_version = workflow_sla_clocks.lock_version + 1
          WHERE id = rec.clock_id
          RETURNING workflow_sla_clocks.lock_version INTO v_new_lock_version;
        END IF;

        INSERT INTO workflow_escalation_events (
          clock_id, instance_id, escalation_level_id, level_order, action_code,
          triggered_by, triggering_actor_id, idempotency_key, metadata
        ) VALUES (
          rec.clock_id, v_clock.instance_id, rec.escalation_level_id, rec.level_order, rec.action_code,
          'automatic', NULL, v_idem,
          jsonb_build_object('source', 'automatic_dispatch', 'result_lock_version', v_new_lock_version, 'action_config', v_level.action_config)
        ) RETURNING id INTO v_evidence_id;

        v_outcome := 'processed';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_outcome := 'failed: ' || SQLERRM;
      v_evidence_id := NULL;
    END;

    clock_id := rec.clock_id;
    instance_id := rec.instance_id;
    escalation_level_id := rec.escalation_level_id;
    level_order := rec.level_order;
    action_code := rec.action_code;
    outcome := v_outcome;
    evidence_id := v_evidence_id;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_process_due_escalations(INTEGER) FROM PUBLIC, anon, authenticated;

-- ─── 5. process_workflow_sla_due_batch — the single worker-facing
--    entry point. Runs all three categories in one call (warning,
--    breach, escalation are independently due -- a clock can
--    legitimately have more than one kind of due action pending) and
--    returns one row of evidence per candidate examined, whether
--    processed, skipped, or failed, so the caller (a future Edge
--    Function or scheduler) can log/observe without a redundant
--    worker-log table -- the real evidence stays in
--    workflow_sla_clock_events/workflow_escalation_events, exactly as
--    the governing instruction requires ("reuse existing evidence
--    wherever sufficient"). p_limit is clamped to [1,200] regardless
--    of caller input -- the dispatcher can never be asked to run an
--    unbounded scan. Granted ONLY to service_role: this is a
--    worker/system execution path, never exposed to ordinary
--    authenticated users or anon (see docs/77 "Authorization and
--    execution boundary" for why this is a stricter posture than the
--    older, pre-CAP-002 check_deadlines()/pg_cron precedent, and why
--    that precedent is not touched by this phase). ─────────────────
CREATE OR REPLACE FUNCTION process_workflow_sla_due_batch(p_limit INTEGER DEFAULT 25)
RETURNS TABLE (
  due_category TEXT, clock_id UUID, instance_id UUID, sequence_index INTEGER,
  action_code TEXT, outcome TEXT, evidence_id UUID
) AS $$
DECLARE
  v_limit INTEGER;
BEGIN
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 200);

  RETURN QUERY
    SELECT 'warning'::TEXT, w.clock_id, w.instance_id, w.warning_offset_index, NULL::TEXT, w.outcome, w.evidence_id
    FROM workflow_sla_process_due_warnings(v_limit) w;

  RETURN QUERY
    SELECT 'breach'::TEXT, b.clock_id, b.instance_id, NULL::INTEGER, NULL::TEXT, b.outcome, b.evidence_id
    FROM workflow_sla_process_due_breaches(v_limit) b;

  RETURN QUERY
    SELECT 'escalation'::TEXT, e.clock_id, e.instance_id, e.level_order, e.action_code, e.outcome, e.evidence_id
    FROM workflow_sla_process_due_escalations(v_limit) e;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION process_workflow_sla_due_batch(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION process_workflow_sla_due_batch(INTEGER) TO service_role;

COMMIT;
