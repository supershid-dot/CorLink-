-- ============================================================
-- CAP-002 Phase 5.3 — SLA & Escalation Persistence / Runtime
-- Foundation.
--
-- Implements the generic persistence and safe SYNCHRONOUS runtime
-- foundation for workflow SLA clocks, business calendars, escalation
-- policies, and manual escalation, per
-- docs/73-workflow-delegation-escalation-architecture.md's
-- "Escalation architecture" and "SLA architecture" sections and
-- docs/60's "SLA, deadlines, reminders, and escalation" section.
--
-- Per docs/73 design decision 3 (escalation/SLA is a third,
-- orthogonal seam — read-only observation plus explicitly bounded
-- exception actions) and design decision 1 (an additive layer, not a
-- rewrite), this patch creates only new, self-contained record types
-- that reference workflow_instances/workflow_instance_steps/
-- workflow_work_items/workflow_events by id. It does NOT modify
-- workflow_enter_downstream_node, workflow_resolve_approval_
-- candidates, decide_workflow_work_item, or any other existing
-- function — none of them are touched by this patch, byte-for-byte,
-- exactly as Phase 5.1/5.2 left them.
--
-- NO background worker, cron, pg_cron, scheduled Edge Function, or
-- automatic recurring timer execution exists or is created here.
-- Every mutation in this patch is a synchronous RPC an authorized
-- caller invokes explicitly. "Due-detection" helpers exist so a
-- FUTURE dispatcher can safely ask "what is due?", but nothing in
-- this patch schedules or repeatedly calls them.
--
-- Hard safety invariant, restated from docs/60 verbatim and enforced
-- structurally throughout this patch: escalation never grants
-- subject visibility, and never automatically approves, rejects,
-- cancels, completes, or closes a workflow business decision merely
-- because a deadline elapsed. No RPC in this patch calls
-- decide_workflow_work_item, mutates workflow_work_items.state,
-- workflow_approval_positions.state, or workflow_decisions in any
-- way. Only 'mark_breached' (which touches solely the SLA clock's
-- own row) is implemented as a complete action in this phase; the
-- other six docs/60-approved escalation actions
-- (remind_actor/notify_supervisor/add_replace_candidates/
-- route_higher_scope/create_exception_work_item/follow_branch) are
-- recorded as immutable EVIDENCE ONLY in this phase — the fact that
-- the action became due/was triggered is recorded, but no
-- notification is delivered, no candidate is added to a live round,
-- no graph branch is followed, and no external work item is created,
-- since each of those requires either notification delivery (a
-- future outbox milestone) or mutating the protected, already-
-- approved graph/round/candidate-resolution machinery this patch
-- must not touch. See docs/76 for the full reasoning.
--
-- Architecture decisions this patch makes as NARROW, documented
-- concretizations of open questions docs/73 deliberately left open
-- (see docs/76 "Deviations/clarifications" for the full reasoning
-- behind each):
--   1. Restart trigger: docs/73 approves only "Reopen" as a restart
--      trigger, and that lifecycle command does not exist yet in
--      this engine (workflow_instances.execution_epoch has never
--      been incremented by any existing function). This patch
--      implements restart as an explicitly authorized, manually
--      invoked administrative command (can_manage_workflow_instance-
--      gated) — never automatically wired to anything — so it exists
--      as the safe SLA-clock-level primitive a future Reopen
--      implementation would call, without approving any new
--      AUTOMATIC trigger docs/73 did not already approve.
--   2. Manual escalation authorization: docs/73 names "the current
--      work item's holder, their supervisor..., or an administrator
--      with authority over the instance." This patch reuses
--      can_manage_workflow_instance (whose 'manager' participant
--      role already represents supervisory authority over the
--      instance) plus a direct work-item-holder check, rather than
--      inventing a new selector-based supervisor resolver.
--   3. Business calendars are always organization-scoped (no cross-
--      organization "national calendar" concept) — a narrow
--      simplification consistent with the governing instruction's
--      "do not build a general enterprise calendar product."
--   4. SLA policies are always duration-based (reusable, named
--      templates); an absolute deadline is a per-clock override
--      supplied at clock-creation time, never a reusable named
--      policy concept — absolute deadlines are inherently one-off,
--      not templates.
-- ============================================================

BEGIN;

-- ─── 1. workflow_business_calendars / _versions ─────────────────────
-- Mirrors workflow_definitions/workflow_definition_versions' own
-- immutable-published-version pattern exactly: a calendar identity
-- row plus append-only, content-hashed versions. A clock pins to the
-- exact version active at clock-start time and is never affected by
-- a later edit — "a clock already running against one version is
-- unaffected by a later calendar edit" (docs/73).
CREATE TABLE IF NOT EXISTS workflow_business_calendars (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID        NOT NULL REFERENCES organizations(id),
  calendar_key      TEXT        NOT NULL CHECK (calendar_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  name              TEXT        NOT NULL CHECK (btrim(name) <> ''),
  is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
  active_version_id UUID,
  created_by        UUID        NOT NULL REFERENCES users(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_business_calendars_org_key_unique UNIQUE (organization_id, calendar_key)
);

CREATE TABLE IF NOT EXISTS workflow_business_calendar_versions (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_id         UUID        NOT NULL REFERENCES workflow_business_calendars(id),
  version_number      INTEGER     NOT NULL CHECK (version_number > 0),
  timezone            TEXT        NOT NULL CHECK (btrim(timezone) <> ''),
  working_days        INTEGER[]   NOT NULL,
  working_hours_start TIME        NOT NULL,
  working_hours_end   TIME        NOT NULL,
  holidays            DATE[]      NOT NULL DEFAULT '{}',
  content_hash        TEXT        NOT NULL,
  created_by          UUID        NOT NULL REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_business_calendar_versions_unique UNIQUE (calendar_id, version_number),
  CONSTRAINT workflow_business_calendar_versions_hours_check CHECK (working_hours_end > working_hours_start),
  CONSTRAINT workflow_business_calendar_versions_days_check CHECK (
    array_length(working_days, 1) BETWEEN 1 AND 7
    AND working_days <@ ARRAY[1,2,3,4,5,6,7]
  )
);

ALTER TABLE workflow_business_calendars
  ADD CONSTRAINT workflow_business_calendars_active_version_fkey
  FOREIGN KEY (active_version_id) REFERENCES workflow_business_calendar_versions(id);

CREATE INDEX IF NOT EXISTS idx_workflow_business_calendar_versions_calendar
  ON workflow_business_calendar_versions (calendar_id, version_number DESC);

CREATE OR REPLACE FUNCTION workflow_reject_calendar_version_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Workflow business calendar version history is immutable and cannot be modified or deleted' USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_business_calendar_versions_immutable ON workflow_business_calendar_versions;
CREATE TRIGGER workflow_business_calendar_versions_immutable
  BEFORE UPDATE OR DELETE ON workflow_business_calendar_versions
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_calendar_version_mutation();

-- ─── 2. workflow_escalation_policies / _levels ───────────────────────
-- Create-once, immutable — no update path exists at all (matching
-- this engine's "a correction is a new record, not an edit"
-- discipline used throughout docs/73). A named policy plus its
-- ordered levels are validated and inserted atomically by a single
-- RPC (see below), so a policy can never exist in a partially-defined
-- state.
CREATE TABLE IF NOT EXISTS workflow_escalation_policies (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID        NOT NULL REFERENCES organizations(id),
  policy_key      TEXT        NOT NULL CHECK (policy_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  name            TEXT        NOT NULL CHECK (btrim(name) <> ''),
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_by      UUID        NOT NULL REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_escalation_policies_org_key_unique UNIQUE (organization_id, policy_key)
);

-- Exactly the seven docs/60/docs/73-approved escalation actions —
-- this patch adds none.
CREATE TABLE IF NOT EXISTS workflow_escalation_levels (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  escalation_policy_id  UUID        NOT NULL REFERENCES workflow_escalation_policies(id),
  level_order           INTEGER     NOT NULL CHECK (level_order BETWEEN 1 AND 20),
  offset_from           TEXT        NOT NULL CHECK (offset_from IN ('breach','previous_level')),
  offset_amount         NUMERIC     NOT NULL CHECK (offset_amount >= 0),
  offset_unit           TEXT        NOT NULL CHECK (offset_unit IN ('hours','business_hours','days','business_days')),
  action_code           TEXT        NOT NULL CHECK (action_code IN (
                            'remind_actor','notify_supervisor','add_replace_candidates',
                            'route_higher_scope','create_exception_work_item','mark_breached','follow_branch'
                          )),
  action_config         JSONB       NOT NULL DEFAULT '{}'::JSONB,
  created_by            UUID        NOT NULL REFERENCES users(id),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_escalation_levels_policy_order_unique UNIQUE (escalation_policy_id, level_order)
);

CREATE INDEX IF NOT EXISTS idx_workflow_escalation_levels_policy
  ON workflow_escalation_levels (escalation_policy_id, level_order);

CREATE OR REPLACE FUNCTION workflow_reject_escalation_config_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is immutable once created and cannot be modified or deleted', TG_TABLE_NAME USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_escalation_policies_immutable ON workflow_escalation_policies;
CREATE TRIGGER workflow_escalation_policies_immutable
  BEFORE UPDATE OR DELETE ON workflow_escalation_policies
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_escalation_config_mutation();

DROP TRIGGER IF EXISTS workflow_escalation_levels_immutable ON workflow_escalation_levels;
CREATE TRIGGER workflow_escalation_levels_immutable
  BEFORE UPDATE OR DELETE ON workflow_escalation_levels
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_escalation_config_mutation();

-- ─── 3. workflow_sla_policies ─────────────────────────────────────────
-- Reusable, named, duration-based SLA configuration template. An
-- absolute deadline is never a reusable policy concept (it is
-- inherently one-off) — it is supplied directly at clock-creation
-- time instead (see create_workflow_sla_clock below). Create-once,
-- immutable, same discipline as escalation policies.
CREATE TABLE IF NOT EXISTS workflow_sla_policies (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id         UUID        NOT NULL REFERENCES organizations(id),
  policy_key              TEXT        NOT NULL CHECK (policy_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  name                    TEXT        NOT NULL CHECK (btrim(name) <> ''),
  duration_amount         NUMERIC     NOT NULL CHECK (duration_amount > 0),
  duration_unit           TEXT        NOT NULL CHECK (duration_unit IN ('hours','business_hours','days','business_days')),
  calendar_id             UUID        REFERENCES workflow_business_calendars(id),
  timezone                TEXT        NOT NULL CHECK (btrim(timezone) <> ''),
  warning_offsets         JSONB       NOT NULL DEFAULT '[]'::JSONB,
  pause_eligible          BOOLEAN     NOT NULL DEFAULT FALSE,
  restart_eligible        BOOLEAN     NOT NULL DEFAULT FALSE,
  escalation_policy_id    UUID        REFERENCES workflow_escalation_policies(id),
  is_active               BOOLEAN     NOT NULL DEFAULT TRUE,
  created_by              UUID        NOT NULL REFERENCES users(id),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_sla_policies_org_key_unique UNIQUE (organization_id, policy_key),
  CONSTRAINT workflow_sla_policies_calendar_required_check CHECK (
    (duration_unit IN ('business_hours','business_days') AND calendar_id IS NOT NULL)
    OR (duration_unit IN ('hours','days'))
  )
);

CREATE INDEX IF NOT EXISTS idx_workflow_sla_policies_org
  ON workflow_sla_policies (organization_id, policy_key);

DROP TRIGGER IF EXISTS workflow_sla_policies_immutable ON workflow_sla_policies;
CREATE TRIGGER workflow_sla_policies_immutable
  BEFORE UPDATE OR DELETE ON workflow_sla_policies
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_escalation_config_mutation();

-- ─── 4. workflow_sla_clocks ───────────────────────────────────────────
-- One row per live SLA clock instance. Preserves the full semantic
-- source of its deadline (start event, duration/absolute rule,
-- calendar version pinned at start, timezone) so "why was this
-- deadline this exact timestamp" is always answerable, per the
-- governing instruction. effective_deadline is the ORIGINAL
-- calculated instant and is never overwritten by pause/resume (see
-- effective_deadline_adjusted); restart recomputes it fresh (a new
-- timing epoch) with the prior value preserved in evidence, never
-- overwritten silently.
CREATE TABLE IF NOT EXISTS workflow_sla_clocks (
  id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id                 UUID        NOT NULL REFERENCES workflow_instances(id),
  step_id                     UUID        REFERENCES workflow_instance_steps(id),
  work_item_id                UUID        REFERENCES workflow_work_items(id),
  organization_id             UUID        NOT NULL REFERENCES organizations(id),
  policy_id                   UUID        REFERENCES workflow_sla_policies(id),
  deadline_rule_type          TEXT        NOT NULL CHECK (deadline_rule_type IN ('duration','absolute')),
  start_event_type            TEXT        NOT NULL CHECK (start_event_type IN
                                 ('step_entered','work_item_created','approval_round_opened','manual')),
  start_reference_event_id    UUID        REFERENCES workflow_events(id),
  started_at                  TIMESTAMPTZ NOT NULL,
  configured_duration_amount  NUMERIC,
  configured_duration_unit    TEXT        CHECK (configured_duration_unit IN ('hours','business_hours','days','business_days')),
  calendar_id                 UUID        REFERENCES workflow_business_calendars(id),
  calendar_version_id         UUID        REFERENCES workflow_business_calendar_versions(id),
  timezone                    TEXT        NOT NULL CHECK (btrim(timezone) <> ''),
  effective_deadline          TIMESTAMPTZ NOT NULL,
  warning_offsets             JSONB       NOT NULL DEFAULT '[]'::JSONB,
  warned_up_to_index          INTEGER     NOT NULL DEFAULT -1,
  escalation_policy_id        UUID        REFERENCES workflow_escalation_policies(id),
  state                       TEXT        NOT NULL DEFAULT 'running' CHECK (state IN ('running','paused','completed','cancelled')),
  accumulated_paused_duration INTERVAL    NOT NULL DEFAULT '0',
  current_pause_started_at    TIMESTAMPTZ,
  -- NOT a GENERATED column: Postgres' timestamptz + interval operator
  -- is STABLE, not IMMUTABLE (interval day/month components are not
  -- statically resolvable), so it cannot appear in a generation
  -- expression. Instead this column is explicitly maintained by every
  -- RPC that changes effective_deadline or accumulated_paused_duration
  -- (create/resume/restart) -- always set in the same statement as its
  -- inputs, so it can never drift out of sync with them.
  effective_deadline_adjusted TIMESTAMPTZ NOT NULL,
  current_escalation_level    INTEGER     NOT NULL DEFAULT 0,
  breached_at                 TIMESTAMPTZ,
  restart_epoch               INTEGER     NOT NULL DEFAULT 1 CHECK (restart_epoch > 0),
  pause_eligible               BOOLEAN     NOT NULL,
  restart_eligible             BOOLEAN     NOT NULL,
  completed_at                TIMESTAMPTZ,
  cancelled_at                TIMESTAMPTZ,
  lock_version                 BIGINT      NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  created_by                  UUID        NOT NULL REFERENCES users(id),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_sla_clocks_duration_check CHECK (
    (deadline_rule_type = 'duration' AND configured_duration_amount IS NOT NULL AND configured_duration_unit IS NOT NULL)
    OR (deadline_rule_type = 'absolute' AND configured_duration_amount IS NULL AND configured_duration_unit IS NULL)
  ),
  CONSTRAINT workflow_sla_clocks_pause_state_check CHECK (
    (state = 'paused' AND current_pause_started_at IS NOT NULL)
    OR (state <> 'paused' AND current_pause_started_at IS NULL)
  ),
  CONSTRAINT workflow_sla_clocks_completed_check CHECK (
    (state = 'completed' AND completed_at IS NOT NULL) OR (state <> 'completed' AND completed_at IS NULL)
  ),
  CONSTRAINT workflow_sla_clocks_cancelled_check CHECK (
    (state = 'cancelled' AND cancelled_at IS NOT NULL) OR (state <> 'cancelled' AND cancelled_at IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_workflow_sla_clocks_instance
  ON workflow_sla_clocks (instance_id, state);
CREATE INDEX IF NOT EXISTS idx_workflow_sla_clocks_step
  ON workflow_sla_clocks (step_id) WHERE step_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_workflow_sla_clocks_work_item
  ON workflow_sla_clocks (work_item_id) WHERE work_item_id IS NOT NULL;
-- Active-clock-by-deadline: the core "which clocks are due" access
-- path, partial on the non-terminal states only.
CREATE INDEX IF NOT EXISTS idx_workflow_sla_clocks_active_deadline
  ON workflow_sla_clocks (effective_deadline_adjusted)
  WHERE state = 'running';
CREATE INDEX IF NOT EXISTS idx_workflow_sla_clocks_breach_due
  ON workflow_sla_clocks (effective_deadline_adjusted)
  WHERE state = 'running' AND breached_at IS NULL;

CREATE OR REPLACE FUNCTION workflow_reject_terminal_sla_clock_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Workflow SLA clock history is immutable and cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF OLD.state IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'Workflow SLA clock % has already reached a terminal state and cannot be modified', OLD.id
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_sla_clocks_immutable_after_terminal ON workflow_sla_clocks;
CREATE TRIGGER workflow_sla_clocks_immutable_after_terminal
  BEFORE UPDATE OR DELETE ON workflow_sla_clocks
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_terminal_sla_clock_mutation();

DROP TRIGGER IF EXISTS set_updated_at ON workflow_sla_clocks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_sla_clocks
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 5. workflow_sla_clock_events (immutable evidence) ───────────────
-- Every clock lifecycle fact (started/paused/resumed/restarted/
-- warning_fired/breached/completed/cancelled) as one append-only
-- evidence stream. instance_id is denormalized directly onto the row
-- (matching workflow_events' own precedent) so RLS visibility never
-- requires a join through the clock.
CREATE TABLE IF NOT EXISTS workflow_sla_clock_events (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  clock_id        UUID        NOT NULL REFERENCES workflow_sla_clocks(id),
  instance_id     UUID        NOT NULL REFERENCES workflow_instances(id),
  event_type      TEXT        NOT NULL CHECK (event_type IN
                     ('started','paused','resumed','restarted','warning_fired','breached','completed','cancelled')),
  actor_id        UUID        REFERENCES users(id),
  reason          TEXT,
  idempotency_key UUID        NOT NULL,
  metadata        JSONB       NOT NULL DEFAULT '{}'::JSONB,
  occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_sla_clock_events_idempotency_unique UNIQUE (clock_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_workflow_sla_clock_events_clock
  ON workflow_sla_clock_events (clock_id, occurred_at, id);
CREATE INDEX IF NOT EXISTS idx_workflow_sla_clock_events_instance
  ON workflow_sla_clock_events (instance_id, occurred_at, id);
-- No duplicate warning fired for the exact same offset, and no
-- duplicate breach event — hard database-enforced backstop behind
-- the RPCs' own idempotent-replay logic.
CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_sla_clock_events_warning_once
  ON workflow_sla_clock_events (clock_id, (metadata ->> 'warning_offset_index'))
  WHERE event_type = 'warning_fired';
CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_sla_clock_events_breach_once
  ON workflow_sla_clock_events (clock_id)
  WHERE event_type = 'breached';

CREATE OR REPLACE FUNCTION workflow_reject_evidence_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_sla_clock_events_immutable ON workflow_sla_clock_events;
CREATE TRIGGER workflow_sla_clock_events_immutable
  BEFORE UPDATE OR DELETE ON workflow_sla_clock_events
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_evidence_mutation();

-- ─── 6. workflow_escalation_events (immutable evidence) ──────────────
-- One row per escalation action that fired (manual only, in this
-- phase — see header note). A hard UNIQUE(clock_id, escalation_level_
-- id) backstop guarantees a level can never fire twice for the same
-- clock, independent of the RPC's own idempotent-replay logic.
CREATE TABLE IF NOT EXISTS workflow_escalation_events (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  clock_id              UUID        NOT NULL REFERENCES workflow_sla_clocks(id),
  instance_id           UUID        NOT NULL REFERENCES workflow_instances(id),
  escalation_level_id   UUID        NOT NULL REFERENCES workflow_escalation_levels(id),
  level_order           INTEGER     NOT NULL,
  action_code           TEXT        NOT NULL,
  triggered_by          TEXT        NOT NULL CHECK (triggered_by IN ('manual','automatic')),
  triggering_actor_id   UUID        REFERENCES users(id),
  idempotency_key       UUID        NOT NULL,
  metadata              JSONB       NOT NULL DEFAULT '{}'::JSONB,
  occurred_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_escalation_events_no_duplicate_level UNIQUE (clock_id, escalation_level_id),
  CONSTRAINT workflow_escalation_events_idempotency_unique UNIQUE (clock_id, idempotency_key),
  CONSTRAINT workflow_escalation_events_manual_actor_check CHECK (
    (triggered_by = 'manual' AND triggering_actor_id IS NOT NULL)
    OR (triggered_by = 'automatic')
  )
);

CREATE INDEX IF NOT EXISTS idx_workflow_escalation_events_clock
  ON workflow_escalation_events (clock_id, level_order);
CREATE INDEX IF NOT EXISTS idx_workflow_escalation_events_instance
  ON workflow_escalation_events (instance_id, occurred_at, id);

DROP TRIGGER IF EXISTS workflow_escalation_events_immutable ON workflow_escalation_events;
CREATE TRIGGER workflow_escalation_events_immutable
  BEFORE UPDATE OR DELETE ON workflow_escalation_events
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_evidence_mutation();

-- ─── 7. Authorization helper ──────────────────────────────────────────
-- Reuses the exact same shape as can_manage_workflow_definition — no
-- parallel permission system. Gates administrative configuration
-- (calendars, SLA policies, escalation policies) to organization
-- admins/super-admins. GRANTED to authenticated (not just revoked from
-- PUBLIC/anon): both helpers below are used directly as RLS USING-
-- clause predicates (see section 8), and unlike a function called only
-- from within another SECURITY DEFINER function's body -- where the
-- effective privilege check runs as that outer function's owner --
-- an RLS policy expression is evaluated under the querying role's own
-- privileges, so the querying role (authenticated) genuinely needs
-- EXECUTE here. This mirrors can_manage_workflow_definition's and
-- can_manage_workflow_instance's own established grant shape exactly.
CREATE OR REPLACE FUNCTION can_manage_workflow_sla_config(p_organization_id UUID)
RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin()
    OR (p_organization_id = get_my_org_id() AND is_admin())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION can_manage_workflow_sla_config(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION can_manage_workflow_sla_config(UUID) TO authenticated;

-- Manual-escalation / clock-lifecycle authorization: the current
-- work item's holder, or can_manage_workflow_instance's existing
-- owner/manager boundary (which already represents the "administrator
-- with authority over the instance" and, via the manager role,
-- supervisory authority) — reusing existing primitives rather than
-- inventing a new selector-based supervisor resolver.
CREATE OR REPLACE FUNCTION can_manage_workflow_sla_clock(p_clock_id UUID)
RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    can_manage_workflow_instance(c.instance_id)
    OR EXISTS (
      SELECT 1 FROM workflow_work_items wi
      WHERE wi.id = c.work_item_id AND wi.assigned_to = auth.uid()
    )
  )
  FROM workflow_sla_clocks c WHERE c.id = p_clock_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION can_manage_workflow_sla_clock(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION can_manage_workflow_sla_clock(UUID) TO authenticated;

-- ─── 8. RLS ───────────────────────────────────────────────────────────
ALTER TABLE workflow_business_calendars         ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_business_calendar_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_escalation_policies        ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_escalation_levels          ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_sla_policies               ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_sla_clocks                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_sla_clock_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_escalation_events          ENABLE ROW LEVEL SECURITY;

-- Administrative configuration: admin-only visibility within the
-- owning organization, mirroring workflow_definitions' own
-- can_manage_workflow_definition-gated SELECT policy exactly (an
-- ordinary org member cannot see workflow definitions either).
DROP POLICY IF EXISTS workflow_business_calendars_select ON workflow_business_calendars;
CREATE POLICY workflow_business_calendars_select ON workflow_business_calendars
  FOR SELECT TO authenticated
  USING (can_manage_workflow_sla_config(organization_id));

DROP POLICY IF EXISTS workflow_business_calendar_versions_select ON workflow_business_calendar_versions;
CREATE POLICY workflow_business_calendar_versions_select ON workflow_business_calendar_versions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM workflow_business_calendars c
    WHERE c.id = calendar_id AND can_manage_workflow_sla_config(c.organization_id)
  ));

DROP POLICY IF EXISTS workflow_escalation_policies_select ON workflow_escalation_policies;
CREATE POLICY workflow_escalation_policies_select ON workflow_escalation_policies
  FOR SELECT TO authenticated
  USING (can_manage_workflow_sla_config(organization_id));

DROP POLICY IF EXISTS workflow_escalation_levels_select ON workflow_escalation_levels;
CREATE POLICY workflow_escalation_levels_select ON workflow_escalation_levels
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM workflow_escalation_policies p
    WHERE p.id = escalation_policy_id AND can_manage_workflow_sla_config(p.organization_id)
  ));

DROP POLICY IF EXISTS workflow_sla_policies_select ON workflow_sla_policies;
CREATE POLICY workflow_sla_policies_select ON workflow_sla_policies
  FOR SELECT TO authenticated
  USING (can_manage_workflow_sla_config(organization_id));

-- Instance-scoped runtime data: same visibility boundary as every
-- other workflow_ runtime table (workflow_events, workflow_decisions,
-- workflow_work_items) — can_view_workflow_instance. An escalation
-- target named in a level's action_config gains no visibility from
-- that alone; only actual workflow_participants membership (or
-- super-admin) grants it, exactly as before this patch.
DROP POLICY IF EXISTS workflow_sla_clocks_select ON workflow_sla_clocks;
CREATE POLICY workflow_sla_clocks_select ON workflow_sla_clocks
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_sla_clock_events_select ON workflow_sla_clock_events;
CREATE POLICY workflow_sla_clock_events_select ON workflow_sla_clock_events
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_escalation_events_select ON workflow_escalation_events;
CREATE POLICY workflow_escalation_events_select ON workflow_escalation_events
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

REVOKE ALL ON TABLE
  workflow_business_calendars, workflow_business_calendar_versions,
  workflow_escalation_policies, workflow_escalation_levels,
  workflow_sla_policies, workflow_sla_clocks,
  workflow_sla_clock_events, workflow_escalation_events
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE
  workflow_business_calendars, workflow_business_calendar_versions,
  workflow_escalation_policies, workflow_escalation_levels,
  workflow_sla_policies, workflow_sla_clocks,
  workflow_sla_clock_events, workflow_escalation_events
TO authenticated;

-- ─── 9. workflow_calculate_calendar_deadline — the calendar-aware
--    deadline arithmetic core. Plain wall-clock addition for
--    'hours'/'days'; genuine business-hours-aware iteration
--    (skipping non-working days, holidays, and outside-window time)
--    for 'business_hours'/'business_days', bounded at 3,660
--    iterations (~10 years of daily stepping) as a defensive maximum,
--    mirroring the 32-hop bound this engine already uses for graph
--    advancement. Pure, STABLE, no table mutation — safe to call
--    speculatively (e.g. by a future "preview this deadline" UI). ───
CREATE OR REPLACE FUNCTION workflow_calculate_calendar_deadline(
  p_start TIMESTAMPTZ,
  p_amount NUMERIC,
  p_unit TEXT,
  p_calendar_version_id UUID,
  p_timezone TEXT
) RETURNS TIMESTAMPTZ AS $$
DECLARE
  v_cal workflow_business_calendar_versions;
  v_remaining_minutes NUMERIC;
  v_local TIMESTAMP;
  v_day_start TIMESTAMP;
  v_day_end TIMESTAMP;
  v_available NUMERIC;
  v_iterations INTEGER := 0;
BEGIN
  IF p_amount < 0 THEN
    RAISE EXCEPTION 'Duration amount must be non-negative' USING ERRCODE = '22023';
  END IF;

  IF p_unit IN ('hours','days') THEN
    RETURN p_start + (p_amount || ' ' || p_unit)::INTERVAL;
  END IF;

  IF p_unit NOT IN ('business_hours','business_days') THEN
    RAISE EXCEPTION 'Unsupported duration unit: %', p_unit USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cal FROM workflow_business_calendar_versions WHERE id = p_calendar_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown business calendar version' USING ERRCODE = '22023';
  END IF;

  v_remaining_minutes := CASE
    WHEN p_unit = 'business_hours' THEN p_amount * 60
    ELSE p_amount * (EXTRACT(EPOCH FROM (v_cal.working_hours_end - v_cal.working_hours_start)) / 60)
  END;

  v_local := p_start AT TIME ZONE p_timezone;

  LOOP
    v_iterations := v_iterations + 1;
    IF v_iterations > 3660 THEN
      RAISE EXCEPTION 'Calendar deadline calculation exceeded the defensive iteration bound' USING ERRCODE = '0A000';
    END IF;

    v_day_start := date_trunc('day', v_local) + v_cal.working_hours_start;
    v_day_end   := date_trunc('day', v_local) + v_cal.working_hours_end;

    IF EXTRACT(ISODOW FROM v_local)::INTEGER = ANY(v_cal.working_days)
       AND date_trunc('day', v_local)::DATE <> ALL(v_cal.holidays)
    THEN
      IF v_local < v_day_start THEN v_local := v_day_start; END IF;
      IF v_local < v_day_end THEN
        v_available := EXTRACT(EPOCH FROM (v_day_end - v_local)) / 60;
        IF v_available >= v_remaining_minutes THEN
          v_local := v_local + (v_remaining_minutes || ' minutes')::INTERVAL;
          v_remaining_minutes := 0;
        ELSE
          v_remaining_minutes := v_remaining_minutes - v_available;
          v_local := v_day_end;
        END IF;
      END IF;
    END IF;

    EXIT WHEN v_remaining_minutes <= 0;

    v_local := date_trunc('day', v_local) + INTERVAL '1 day';
  END LOOP;

  RETURN v_local AT TIME ZONE p_timezone;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_calculate_calendar_deadline(TIMESTAMPTZ,NUMERIC,TEXT,UUID,TEXT) FROM PUBLIC, anon, authenticated;

-- ─── 10. create_workflow_business_calendar_version — creates the
--    calendar identity on first use, then always appends a new,
--    immutable, content-hashed version and activates it. Existing
--    clocks already pinned to an older version are completely
--    unaffected. ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_workflow_business_calendar_version(
  p_organization_id UUID,
  p_calendar_key TEXT,
  p_name TEXT,
  p_timezone TEXT,
  p_working_days INTEGER[],
  p_working_hours_start TIME,
  p_working_hours_end TIME,
  p_holidays DATE[],
  p_idempotency_key UUID
) RETURNS TABLE (calendar_id UUID, version_id UUID, version_number INTEGER, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_calendar_id UUID;
  v_next_version INTEGER;
  v_version_id UUID;
  v_content_hash TEXT;
BEGIN
  IF NOT can_manage_workflow_sla_config(p_organization_id) THEN
    RAISE EXCEPTION 'Not authorized to manage business calendars for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_organization_id IS NULL OR p_calendar_key IS NULL
     OR p_name IS NULL OR p_timezone IS NULL OR p_working_days IS NULL
     OR p_working_hours_start IS NULL OR p_working_hours_end IS NULL THEN
    RAISE EXCEPTION 'Missing required calendar fields' USING ERRCODE = '22023';
  END IF;

  v_content_hash := encode(digest(
    p_timezone || '|' || p_working_days::TEXT || '|' || p_working_hours_start::TEXT || '|' ||
    p_working_hours_end::TEXT || '|' || COALESCE(p_holidays,'{}')::TEXT, 'sha256'
  ), 'hex');

  SELECT c.id INTO v_calendar_id FROM workflow_business_calendars c
  WHERE c.organization_id = p_organization_id AND c.calendar_key = p_calendar_key;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_calendar_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  IF v_calendar_id IS NOT NULL THEN
    SELECT v.id, v.version_number INTO v_version_id, v_next_version
    FROM workflow_business_calendar_versions v
    WHERE v.calendar_id = v_calendar_id AND v.content_hash = v_content_hash;
    -- Not a true idempotency-key based replay path (versions carry no
    -- idempotency_key column, since every version is a wholly new,
    -- independently meaningful immutable fact) -- instead, creating
    -- an identical version twice simply reuses the existing version
    -- rather than creating a duplicate, which is the correct,
    -- content-addressed behavior for an immutable version stream.
    IF v_version_id IS NOT NULL THEN
      RETURN QUERY SELECT v_calendar_id, v_version_id, v_next_version, TRUE;
      RETURN;
    END IF;
  END IF;

  IF v_calendar_id IS NULL THEN
    INSERT INTO workflow_business_calendars (organization_id, calendar_key, name, created_by)
    VALUES (p_organization_id, p_calendar_key, p_name, v_actor)
    RETURNING id INTO v_calendar_id;
    v_next_version := 1;
  ELSE
    SELECT COALESCE(MAX(workflow_business_calendar_versions.version_number), 0) + 1 INTO v_next_version
    FROM workflow_business_calendar_versions WHERE workflow_business_calendar_versions.calendar_id = v_calendar_id;
  END IF;

  INSERT INTO workflow_business_calendar_versions (
    calendar_id, version_number, timezone, working_days, working_hours_start,
    working_hours_end, holidays, content_hash, created_by
  ) VALUES (
    v_calendar_id, v_next_version, p_timezone, p_working_days, p_working_hours_start,
    p_working_hours_end, COALESCE(p_holidays, '{}'), v_content_hash, v_actor
  ) RETURNING id INTO v_version_id;

  UPDATE workflow_business_calendars SET active_version_id = v_version_id, updated_at = clock_timestamp()
  WHERE id = v_calendar_id;

  RETURN QUERY SELECT v_calendar_id, v_version_id, v_next_version, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION create_workflow_business_calendar_version(UUID,TEXT,TEXT,TEXT,INTEGER[],TIME,TIME,DATE[],UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_business_calendar_version(UUID,TEXT,TEXT,TEXT,INTEGER[],TIME,TIME,DATE[],UUID) TO authenticated;

-- ─── 11. create_workflow_escalation_policy — validates and inserts a
--    full ordered level list atomically. Rejects duplicate/ambiguous
--    ordering and any action outside the closed seven-action
--    allowlist. Create-once; no update RPC exists. ───────────────────
CREATE OR REPLACE FUNCTION create_workflow_escalation_policy(
  p_organization_id UUID,
  p_policy_key TEXT,
  p_name TEXT,
  p_levels JSONB,
  p_idempotency_key UUID
) RETURNS TABLE (escalation_policy_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_policy_id UUID;
  v_existing workflow_escalation_policies;
  v_level JSONB;
  v_orders INTEGER[] := '{}';
  v_count INTEGER;
BEGIN
  IF NOT can_manage_workflow_sla_config(p_organization_id) THEN
    RAISE EXCEPTION 'Not authorized to manage escalation policies for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_organization_id IS NULL OR p_policy_key IS NULL OR p_name IS NULL
     OR p_levels IS NULL OR jsonb_typeof(p_levels) <> 'array' OR jsonb_array_length(p_levels) < 1 THEN
    RAISE EXCEPTION 'Missing required escalation policy fields, or levels must be a non-empty array' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_escalation_policy_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_escalation_policies
  WHERE organization_id = p_organization_id AND policy_key = p_policy_key AND created_by = v_actor;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.id, TRUE;
    RETURN;
  END IF;

  -- Validate every level before any INSERT: closed action allowlist
  -- (enforced again by the CHECK constraint as defense-in-depth),
  -- valid offset_from/offset_unit, and no duplicate/ambiguous
  -- level_order.
  FOR v_level IN SELECT * FROM jsonb_array_elements(p_levels) LOOP
    IF (v_level ->> 'level_order') IS NULL OR (v_level ->> 'level_order')::INTEGER NOT BETWEEN 1 AND 20 THEN
      RAISE EXCEPTION 'Each escalation level requires a level_order between 1 and 20' USING ERRCODE = '22023';
    END IF;
    IF (v_level ->> 'level_order')::INTEGER = ANY(v_orders) THEN
      RAISE EXCEPTION 'Duplicate or ambiguous escalation level_order: %', v_level ->> 'level_order' USING ERRCODE = '22023';
    END IF;
    v_orders := v_orders || (v_level ->> 'level_order')::INTEGER;
    IF (v_level ->> 'offset_from') NOT IN ('breach','previous_level') THEN
      RAISE EXCEPTION 'Invalid offset_from: %', v_level ->> 'offset_from' USING ERRCODE = '22023';
    END IF;
    IF (v_level ->> 'offset_unit') NOT IN ('hours','business_hours','days','business_days') THEN
      RAISE EXCEPTION 'Invalid offset_unit: %', v_level ->> 'offset_unit' USING ERRCODE = '22023';
    END IF;
    IF (v_level ->> 'action_code') NOT IN (
      'remind_actor','notify_supervisor','add_replace_candidates',
      'route_higher_scope','create_exception_work_item','mark_breached','follow_branch'
    ) THEN
      RAISE EXCEPTION 'Unsupported escalation action_code: %', v_level ->> 'action_code' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- level_order must form a contiguous 1..N sequence with no gaps --
  -- "levels fire in strict order... level n can only fire after
  -- level n-1" (docs/73) requires a total order with no ambiguity.
  SELECT count(*) INTO v_count FROM unnest(v_orders) o;
  IF v_count <> jsonb_array_length(p_levels)
     OR (SELECT array_agg(o ORDER BY o) FROM unnest(v_orders) o) <> (SELECT array_agg(g) FROM generate_series(1, v_count) g)
  THEN
    RAISE EXCEPTION 'Escalation levels must form a contiguous sequence starting at 1 with no gaps or duplicates' USING ERRCODE = '22023';
  END IF;

  INSERT INTO workflow_escalation_policies (organization_id, policy_key, name, created_by)
  VALUES (p_organization_id, p_policy_key, p_name, v_actor)
  RETURNING id INTO v_policy_id;

  FOR v_level IN SELECT * FROM jsonb_array_elements(p_levels) LOOP
    INSERT INTO workflow_escalation_levels (
      escalation_policy_id, level_order, offset_from, offset_amount, offset_unit,
      action_code, action_config, created_by
    ) VALUES (
      v_policy_id, (v_level ->> 'level_order')::INTEGER, v_level ->> 'offset_from',
      COALESCE((v_level ->> 'offset_amount')::NUMERIC, 0), v_level ->> 'offset_unit',
      v_level ->> 'action_code', COALESCE(v_level -> 'action_config', '{}'::JSONB), v_actor
    );
  END LOOP;

  RETURN QUERY SELECT v_policy_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION create_workflow_escalation_policy(UUID,TEXT,TEXT,JSONB,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_escalation_policy(UUID,TEXT,TEXT,JSONB,UUID) TO authenticated;

-- ─── 12. create_workflow_sla_policy ───────────────────────────────────
CREATE OR REPLACE FUNCTION create_workflow_sla_policy(
  p_organization_id UUID,
  p_policy_key TEXT,
  p_name TEXT,
  p_duration_amount NUMERIC,
  p_duration_unit TEXT,
  p_calendar_id UUID,
  p_timezone TEXT,
  p_warning_offsets JSONB,
  p_pause_eligible BOOLEAN,
  p_restart_eligible BOOLEAN,
  p_escalation_policy_id UUID,
  p_idempotency_key UUID
) RETURNS TABLE (sla_policy_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_policy_id UUID;
  v_existing workflow_sla_policies;
  v_offset JSONB;
BEGIN
  IF NOT can_manage_workflow_sla_config(p_organization_id) THEN
    RAISE EXCEPTION 'Not authorized to manage SLA policies for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_organization_id IS NULL OR p_policy_key IS NULL OR p_name IS NULL
     OR p_duration_amount IS NULL OR p_duration_unit IS NULL OR p_timezone IS NULL THEN
    RAISE EXCEPTION 'Missing required SLA policy fields' USING ERRCODE = '22023';
  END IF;
  IF p_duration_unit NOT IN ('hours','business_hours','days','business_days') THEN
    RAISE EXCEPTION 'Invalid duration_unit: %', p_duration_unit USING ERRCODE = '22023';
  END IF;
  IF p_duration_unit IN ('business_hours','business_days') AND p_calendar_id IS NULL THEN
    RAISE EXCEPTION 'A calendar_id is required for a calendar-aware duration unit' USING ERRCODE = '22023';
  END IF;
  IF p_calendar_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM workflow_business_calendars c WHERE c.id = p_calendar_id AND c.organization_id = p_organization_id AND c.is_active
  ) THEN
    RAISE EXCEPTION 'Calendar not found in this organization' USING ERRCODE = '22023';
  END IF;
  IF p_escalation_policy_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM workflow_escalation_policies p WHERE p.id = p_escalation_policy_id AND p.organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'Escalation policy not found in this organization' USING ERRCODE = '22023';
  END IF;
  IF p_warning_offsets IS NOT NULL AND jsonb_typeof(p_warning_offsets) <> 'array' THEN
    RAISE EXCEPTION 'warning_offsets must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF p_warning_offsets IS NOT NULL THEN
    FOR v_offset IN SELECT * FROM jsonb_array_elements(p_warning_offsets) LOOP
      IF (v_offset ->> 'amount') IS NULL OR (v_offset ->> 'unit') NOT IN ('hours','business_hours','days','business_days') THEN
        RAISE EXCEPTION 'Each warning offset requires a numeric amount and a valid unit' USING ERRCODE = '22023';
      END IF;
    END LOOP;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_policy_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_sla_policies
  WHERE organization_id = p_organization_id AND policy_key = p_policy_key AND created_by = v_actor;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.id, TRUE;
    RETURN;
  END IF;

  INSERT INTO workflow_sla_policies (
    organization_id, policy_key, name, duration_amount, duration_unit, calendar_id, timezone,
    warning_offsets, pause_eligible, restart_eligible, escalation_policy_id, created_by
  ) VALUES (
    p_organization_id, p_policy_key, p_name, p_duration_amount, p_duration_unit, p_calendar_id, p_timezone,
    COALESCE(p_warning_offsets, '[]'::JSONB), COALESCE(p_pause_eligible, FALSE), COALESCE(p_restart_eligible, FALSE),
    p_escalation_policy_id, v_actor
  ) RETURNING id INTO v_policy_id;

  RETURN QUERY SELECT v_policy_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION create_workflow_sla_policy(UUID,TEXT,TEXT,NUMERIC,TEXT,UUID,TEXT,JSONB,BOOLEAN,BOOLEAN,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_sla_policy(UUID,TEXT,TEXT,NUMERIC,TEXT,UUID,TEXT,JSONB,BOOLEAN,BOOLEAN,UUID,UUID) TO authenticated;

-- ─── 13. create_workflow_sla_clock — creates AND starts a clock in
--    one step (an SLA clock's whole point is "the start event has
--    already occurred, begin timing" — there is no separate
--    "scheduled" pre-start state, per the governing instruction's
--    "smallest state machine" guidance). Either references a
--    duration-based policy (p_policy_id, resolving the calendar
--    version live at this exact moment and pinning to it) or
--    supplies a one-off absolute deadline directly
--    (p_absolute_deadline) -- never both. Authorization:
--    can_manage_workflow_instance, since configuring a clock for an
--    instance is an administrative action on that instance. ────────
CREATE OR REPLACE FUNCTION create_workflow_sla_clock(
  p_instance_id UUID,
  p_step_id UUID,
  p_work_item_id UUID,
  p_policy_id UUID,
  p_start_event_type TEXT,
  p_start_reference_event_id UUID,
  p_absolute_deadline TIMESTAMPTZ,
  p_absolute_deadline_timezone TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, effective_deadline TIMESTAMPTZ, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_instance workflow_instances;
  v_policy workflow_sla_policies;
  v_calendar workflow_business_calendars;
  v_existing workflow_sla_clocks;
  v_clock_id UUID;
  v_deadline TIMESTAMPTZ;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF NOT can_manage_workflow_instance(p_instance_id) THEN
    RAISE EXCEPTION 'Not authorized to configure an SLA clock for this instance' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_instance_id IS NULL OR p_start_event_type IS NULL THEN
    RAISE EXCEPTION 'Missing required SLA clock fields' USING ERRCODE = '22023';
  END IF;
  IF p_start_event_type NOT IN ('step_entered','work_item_created','approval_round_opened','manual') THEN
    RAISE EXCEPTION 'Invalid start_event_type: %', p_start_event_type USING ERRCODE = '22023';
  END IF;
  IF (p_policy_id IS NULL) = (p_absolute_deadline IS NULL) THEN
    RAISE EXCEPTION 'Exactly one of policy_id (duration-based) or absolute_deadline must be supplied' USING ERRCODE = '22023';
  END IF;
  IF p_absolute_deadline IS NOT NULL AND btrim(COALESCE(p_absolute_deadline_timezone, '')) = '' THEN
    RAISE EXCEPTION 'A timezone is required when supplying an absolute_deadline' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_instance FROM workflow_instances WHERE id = p_instance_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow instance not found' USING ERRCODE = '42501';
  END IF;
  IF p_step_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_instance_steps s WHERE s.id = p_step_id AND s.instance_id = p_instance_id) THEN
    RAISE EXCEPTION 'Step does not belong to this instance' USING ERRCODE = '22023';
  END IF;
  IF p_work_item_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_work_items w WHERE w.id = p_work_item_id AND w.instance_id = p_instance_id) THEN
    RAISE EXCEPTION 'Work item does not belong to this instance' USING ERRCODE = '22023';
  END IF;
  IF p_start_reference_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_events e WHERE e.id = p_start_reference_event_id AND e.instance_id = p_instance_id) THEN
    RAISE EXCEPTION 'Start reference event does not belong to this instance' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_sla_clocks
  WHERE created_by = v_actor AND id IN (
    SELECT e.clock_id FROM workflow_sla_clock_events e WHERE e.idempotency_key = p_idempotency_key AND e.event_type = 'started'
  );
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.id, v_existing.effective_deadline, TRUE;
    RETURN;
  END IF;

  IF p_policy_id IS NOT NULL THEN
    SELECT * INTO v_policy FROM workflow_sla_policies WHERE id = p_policy_id AND organization_id = v_instance.home_organization_id AND is_active;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'SLA policy not found in this organization' USING ERRCODE = '22023';
    END IF;

    v_clock_id := gen_random_uuid();
    IF v_policy.duration_unit IN ('business_hours','business_days') THEN
      SELECT * INTO v_calendar FROM workflow_business_calendars WHERE id = v_policy.calendar_id;
      IF v_calendar.active_version_id IS NULL THEN
        RAISE EXCEPTION 'Calendar has no published version' USING ERRCODE = '0A000';
      END IF;
      v_deadline := workflow_calculate_calendar_deadline(
        v_now, v_policy.duration_amount, v_policy.duration_unit, v_calendar.active_version_id, v_policy.timezone
      );
    ELSE
      v_deadline := workflow_calculate_calendar_deadline(v_now, v_policy.duration_amount, v_policy.duration_unit, NULL, v_policy.timezone);
    END IF;

    INSERT INTO workflow_sla_clocks (
      id, instance_id, step_id, work_item_id, organization_id, policy_id, deadline_rule_type,
      start_event_type, start_reference_event_id, started_at, configured_duration_amount,
      configured_duration_unit, calendar_id, calendar_version_id, timezone, effective_deadline,
      effective_deadline_adjusted, warning_offsets, escalation_policy_id, pause_eligible, restart_eligible, created_by
    ) VALUES (
      v_clock_id, p_instance_id, p_step_id, p_work_item_id, v_instance.home_organization_id, v_policy.id, 'duration',
      p_start_event_type, p_start_reference_event_id, v_now, v_policy.duration_amount,
      v_policy.duration_unit, v_policy.calendar_id, v_calendar.active_version_id, v_policy.timezone, v_deadline,
      v_deadline, v_policy.warning_offsets, v_policy.escalation_policy_id, v_policy.pause_eligible, v_policy.restart_eligible, v_actor
    );
  ELSE
    v_clock_id := gen_random_uuid();
    v_deadline := p_absolute_deadline;
    INSERT INTO workflow_sla_clocks (
      id, instance_id, step_id, work_item_id, organization_id, policy_id, deadline_rule_type,
      start_event_type, start_reference_event_id, started_at, timezone, effective_deadline,
      effective_deadline_adjusted, pause_eligible, restart_eligible, created_by
    ) VALUES (
      v_clock_id, p_instance_id, p_step_id, p_work_item_id, v_instance.home_organization_id, NULL, 'absolute',
      p_start_event_type, p_start_reference_event_id, v_now, p_absolute_deadline_timezone, v_deadline,
      v_deadline, FALSE, FALSE, v_actor
    );
  END IF;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (v_clock_id, p_instance_id, 'started', v_actor, p_idempotency_key,
    jsonb_build_object('effective_deadline', v_deadline, 'start_event_type', p_start_event_type));

  RETURN QUERY SELECT v_clock_id, v_deadline, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION create_workflow_sla_clock(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_sla_clock(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ,TEXT,UUID) TO authenticated;

-- ─── 14. pause_workflow_sla_clock ─────────────────────────────────────
CREATE OR REPLACE FUNCTION pause_workflow_sla_clock(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, state TEXT, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'paused' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, 'paused'::TEXT, (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF NOT v_clock.pause_eligible THEN
    RAISE EXCEPTION 'This SLA clock is not eligible for pause' USING ERRCODE = '55000';
  END IF;
  IF v_clock.state <> 'running' THEN
    RAISE EXCEPTION 'Workflow SLA clock is not running' USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_sla_clocks
  SET state = 'paused', current_pause_started_at = clock_timestamp(), lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, reason, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'paused', v_actor, p_reason, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_clock.lock_version + 1));

  RETURN QUERY SELECT p_clock_id, 'paused'::TEXT, v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION pause_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pause_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) TO authenticated;

-- ─── 15. resume_workflow_sla_clock — continues the SAME logical
--    clock (never replaces it with a new one). The elapsed pause
--    interval is added to accumulated_paused_duration;
--    effective_deadline itself is never rewritten -- only
--    effective_deadline_adjusted (a GENERATED column) reflects the
--    shift, preserving the original deadline's semantic source
--    exactly as calculated at start/restart. Repeated pause/resume
--    cycles remain correct because each cycle only ever adds its own
--    elapsed interval to the running total. ─────────────────────────
CREATE OR REPLACE FUNCTION resume_workflow_sla_clock(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, state TEXT, effective_deadline_adjusted TIMESTAMPTZ, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
  v_paused_interval INTERVAL;
  v_new_accumulated INTERVAL;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'resumed' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, 'running'::TEXT,
      (v_existing.metadata ->> 'result_effective_deadline_adjusted')::TIMESTAMPTZ,
      (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state <> 'paused' THEN
    RAISE EXCEPTION 'Workflow SLA clock is not paused' USING ERRCODE = '55000';
  END IF;

  v_paused_interval := clock_timestamp() - v_clock.current_pause_started_at;
  v_new_accumulated := v_clock.accumulated_paused_duration + v_paused_interval;

  UPDATE workflow_sla_clocks
  SET state = 'running', accumulated_paused_duration = v_new_accumulated,
      effective_deadline_adjusted = v_clock.effective_deadline + v_new_accumulated,
      current_pause_started_at = NULL, lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'resumed', v_actor, p_idempotency_key,
    jsonb_build_object(
      'expected_lock_version', p_expected_lock_version, 'result_lock_version', v_clock.lock_version + 1,
      'paused_interval_seconds', EXTRACT(EPOCH FROM v_paused_interval),
      'result_accumulated_paused_duration_seconds', EXTRACT(EPOCH FROM v_new_accumulated),
      'result_effective_deadline_adjusted', (v_clock.effective_deadline + v_new_accumulated)));

  RETURN QUERY SELECT p_clock_id, 'running'::TEXT, (v_clock.effective_deadline + v_new_accumulated), v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION resume_workflow_sla_clock(UUID,BIGINT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION resume_workflow_sla_clock(UUID,BIGINT,UUID) TO authenticated;

-- ─── 16. restart_workflow_sla_clock — NOT resume. Discards prior
--    elapsed-time contribution entirely and begins a brand new
--    timing epoch from now(), recomputed fresh against the policy's
--    rule (re-resolving the calendar's currently-active version, since
--    a restart is a genuinely new window with its own "why was this
--    deadline this timestamp" story). The complete pre-restart
--    snapshot (effective_deadline, accumulated_paused_duration,
--    current_escalation_level, breached_at) is captured in the
--    'restarted' evidence event's metadata before being reset, so
--    history is preserved, never overwritten to look as though the
--    earlier timing period never existed. See docs/76 for why this
--    is implemented as an explicitly authorized administrative
--    command rather than wired to any automatic trigger. ───────────
CREATE OR REPLACE FUNCTION restart_workflow_sla_clock(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, effective_deadline TIMESTAMPTZ, restart_epoch INTEGER, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
  v_policy workflow_sla_policies;
  v_calendar workflow_business_calendars;
  v_new_deadline TIMESTAMPTZ;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_prior_snapshot JSONB;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'restarted' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id,
      (v_existing.metadata ->> 'result_effective_deadline')::TIMESTAMPTZ,
      (v_existing.metadata ->> 'result_restart_epoch')::INTEGER,
      (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF NOT v_clock.restart_eligible THEN
    RAISE EXCEPTION 'This SLA clock is not eligible for restart' USING ERRCODE = '55000';
  END IF;
  IF v_clock.state = 'paused' THEN
    RAISE EXCEPTION 'A paused SLA clock must be resumed before it can be restarted' USING ERRCODE = '55000';
  END IF;

  v_prior_snapshot := jsonb_build_object(
    'restart_epoch', v_clock.restart_epoch, 'effective_deadline', v_clock.effective_deadline,
    'accumulated_paused_duration_seconds', EXTRACT(EPOCH FROM v_clock.accumulated_paused_duration),
    'current_escalation_level', v_clock.current_escalation_level, 'breached_at', v_clock.breached_at,
    'warned_up_to_index', v_clock.warned_up_to_index, 'state_before_restart', v_clock.state
  );

  IF v_clock.deadline_rule_type = 'duration' THEN
    SELECT * INTO v_policy FROM workflow_sla_policies WHERE id = v_clock.policy_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The originating SLA policy no longer exists' USING ERRCODE = '0A000';
    END IF;
    IF v_policy.duration_unit IN ('business_hours','business_days') THEN
      SELECT * INTO v_calendar FROM workflow_business_calendars WHERE id = v_policy.calendar_id;
      IF v_calendar.active_version_id IS NULL THEN
        RAISE EXCEPTION 'Calendar has no published version' USING ERRCODE = '0A000';
      END IF;
      v_new_deadline := workflow_calculate_calendar_deadline(
        v_now, v_policy.duration_amount, v_policy.duration_unit, v_calendar.active_version_id, v_policy.timezone
      );
    ELSE
      v_new_deadline := workflow_calculate_calendar_deadline(v_now, v_policy.duration_amount, v_policy.duration_unit, NULL, v_policy.timezone);
    END IF;
  ELSE
    -- An absolute-deadline clock has no reusable rule to recompute
    -- from; restart re-bases its own original relative offset (the
    -- gap between its own start and deadline) from the restart
    -- instant, preserving the same "how far past start was the
    -- deadline" shape without inventing a new absolute date.
    v_new_deadline := v_now + (v_clock.effective_deadline - v_clock.started_at);
  END IF;

  UPDATE workflow_sla_clocks
  SET started_at = v_now, effective_deadline = v_new_deadline, effective_deadline_adjusted = v_new_deadline,
      calendar_version_id = COALESCE(v_calendar.active_version_id, calendar_version_id),
      accumulated_paused_duration = '0', current_pause_started_at = NULL,
      current_escalation_level = 0, breached_at = NULL, warned_up_to_index = -1,
      state = 'running', restart_epoch = workflow_sla_clocks.restart_epoch + 1, lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, reason, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'restarted', v_actor, p_reason, p_idempotency_key,
    jsonb_build_object(
      'expected_lock_version', p_expected_lock_version, 'result_lock_version', v_clock.lock_version + 1,
      'result_effective_deadline', v_new_deadline, 'result_restart_epoch', v_clock.restart_epoch + 1,
      'prior_epoch_snapshot', v_prior_snapshot));

  RETURN QUERY SELECT p_clock_id, v_new_deadline, v_clock.restart_epoch + 1, v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION restart_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION restart_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) TO authenticated;

-- ─── 17. complete_workflow_sla_clock / cancel_workflow_sla_clock ─────
-- Explicit, standalone commands -- NOT wired into decide_workflow_
-- work_item or any graph-advancement function (docs/73 design
-- decision 1: this additive layer never requires modifying those
-- functions). A future integration milestone may choose to call
-- these from a module adapter when the underlying work reaches a
-- terminal state; this phase provides only the safe primitive.
CREATE OR REPLACE FUNCTION complete_workflow_sla_clock(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, state TEXT, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'completed' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, 'completed'::TEXT, (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state NOT IN ('running','paused') THEN
    RAISE EXCEPTION 'Workflow SLA clock is not active' USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_sla_clocks
  SET state = 'completed', completed_at = clock_timestamp(), current_pause_started_at = NULL,
      lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'completed', v_actor, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_clock.lock_version + 1));

  RETURN QUERY SELECT p_clock_id, 'completed'::TEXT, v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION complete_workflow_sla_clock(UUID,BIGINT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION complete_workflow_sla_clock(UUID,BIGINT,UUID) TO authenticated;

CREATE OR REPLACE FUNCTION cancel_workflow_sla_clock(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, state TEXT, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'cancelled' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, 'cancelled'::TEXT, (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state NOT IN ('running','paused') THEN
    RAISE EXCEPTION 'Workflow SLA clock is not active' USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_sla_clocks
  SET state = 'cancelled', cancelled_at = clock_timestamp(), current_pause_started_at = NULL,
      lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, reason, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'cancelled', v_actor, p_reason, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_clock.lock_version + 1));

  RETURN QUERY SELECT p_clock_id, 'cancelled'::TEXT, v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION cancel_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cancel_workflow_sla_clock(UUID,BIGINT,TEXT,UUID) TO authenticated;

-- ─── 18. workflow_sla_offset_interval + due-detection foundation ─────
-- workflow_sla_offset_interval converts a warning-offset or
-- escalation-level offset (amount + unit) into a plain INTERVAL.
-- NARROW, DOCUMENTED SIMPLIFICATION: unlike the deadline itself
-- (workflow_calculate_calendar_deadline, which fully walks the
-- business calendar), business_hours/business_days offsets here are
-- treated identically to plain hours/days. Rationale: an offset is
-- "how long before this already-calendar-resolved deadline/level to
-- act", not an independent start-to-end calendar traversal -- the
-- deadline's own calendar-awareness is preserved in full; only the
-- lead-time measurement is simplified. Revisit only if a future
-- milestone explicitly requires calendar-aware lead times.
--
-- The three _due_for_* functions are read-only, deterministic
-- candidate queries -- NOT a worker. Nothing calls them on a
-- schedule; no cron/pg_cron/background process is created by this
-- patch. They exist so a FUTURE dispatcher can safely wrap them
-- (e.g. taking each candidate clock_id and acquiring its own
-- FOR UPDATE SKIP LOCKED lock via the existing record_/trigger_
-- RPCs, which already lock per-row) without this migration ever
-- invoking that loop itself. ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION workflow_sla_offset_interval(p_amount NUMERIC, p_unit TEXT)
RETURNS INTERVAL AS $$
  SELECT CASE
    WHEN p_unit IN ('hours','business_hours') THEN (p_amount || ' hours')::INTERVAL
    WHEN p_unit IN ('days','business_days') THEN (p_amount || ' days')::INTERVAL
    ELSE NULL
  END;
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_offset_interval(NUMERIC,TEXT) FROM PUBLIC, anon, authenticated;

-- Candidate clocks whose next unfired warning_offsets entry is due.
CREATE OR REPLACE FUNCTION workflow_sla_clocks_due_for_warning(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  clock_id UUID, instance_id UUID, warning_offset_index INTEGER,
  due_at TIMESTAMPTZ, effective_deadline_adjusted TIMESTAMPTZ
) AS $$
  SELECT c.id, c.instance_id, (c.warned_up_to_index + 1)::INTEGER, w.due_at, c.effective_deadline_adjusted
  FROM workflow_sla_clocks c
  CROSS JOIN LATERAL (
    SELECT c.effective_deadline_adjusted - workflow_sla_offset_interval(
      (c.warning_offsets -> (c.warned_up_to_index + 1) ->> 'amount')::NUMERIC,
      c.warning_offsets -> (c.warned_up_to_index + 1) ->> 'unit'
    ) AS due_at
  ) w
  WHERE c.state = 'running'
    AND c.warned_up_to_index + 1 < jsonb_array_length(c.warning_offsets)
    AND w.due_at <= clock_timestamp()
  ORDER BY w.due_at
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_clocks_due_for_warning(INTEGER) FROM PUBLIC, anon, authenticated;

-- Candidate clocks whose deadline has elapsed but are not yet marked
-- breached -- mirrors idx_workflow_sla_clocks_breach_due exactly.
CREATE OR REPLACE FUNCTION workflow_sla_clocks_due_for_breach(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (clock_id UUID, instance_id UUID, effective_deadline_adjusted TIMESTAMPTZ)
AS $$
  SELECT c.id, c.instance_id, c.effective_deadline_adjusted
  FROM workflow_sla_clocks c
  WHERE c.state = 'running' AND c.breached_at IS NULL
    AND c.effective_deadline_adjusted <= clock_timestamp()
  ORDER BY c.effective_deadline_adjusted
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_clocks_due_for_breach(INTEGER) FROM PUBLIC, anon, authenticated;

-- Candidate clocks whose NEXT escalation level (current_escalation_
-- level + 1) is due. offset_from = 'breach' anchors to breached_at;
-- offset_from = 'previous_level' anchors to the prior level's
-- workflow_escalation_events.occurred_at -- for level_order = 1,
-- where no previous level can exist, 'previous_level' is treated as
-- 'breach' (documented narrow interpretation, mirrors the offset-
-- interval simplification above). A level with no resolvable anchor
-- (e.g. not yet breached, or its immediate predecessor has not yet
-- fired) is correctly excluded because the CASE yields NULL and
-- NULL + interval = NULL.
CREATE OR REPLACE FUNCTION workflow_sla_clocks_due_for_escalation(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  clock_id UUID, instance_id UUID, escalation_policy_id UUID,
  escalation_level_id UUID, level_order INTEGER, action_code TEXT, due_at TIMESTAMPTZ
) AS $$
  SELECT c.id, c.instance_id, c.escalation_policy_id, lvl.id, lvl.level_order, lvl.action_code, base.due_at
  FROM workflow_sla_clocks c
  JOIN workflow_escalation_levels lvl
    ON lvl.escalation_policy_id = c.escalation_policy_id AND lvl.level_order = c.current_escalation_level + 1
  CROSS JOIN LATERAL (
    SELECT (
      (CASE
        WHEN lvl.offset_from = 'breach' THEN c.breached_at
        WHEN lvl.level_order = 1 THEN c.breached_at
        ELSE (SELECT e.occurred_at FROM workflow_escalation_events e
              WHERE e.clock_id = c.id AND e.level_order = lvl.level_order - 1)
      END) + workflow_sla_offset_interval(lvl.offset_amount, lvl.offset_unit)
    ) AS due_at
  ) base
  WHERE c.state = 'running'
    AND c.escalation_policy_id IS NOT NULL
    AND base.due_at IS NOT NULL
    AND base.due_at <= clock_timestamp()
  ORDER BY base.due_at
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION workflow_sla_clocks_due_for_escalation(INTEGER) FROM PUBLIC, anon, authenticated;

-- ─── 19. record_workflow_sla_warning — records that one specific,
--    in-order warning_offsets entry has become due. Never changes
--    clock.state (a warning is informational, not a lifecycle
--    transition). Sequential-only (must equal warned_up_to_index + 1)
--    so warnings can never be recorded out of order or skipped. ─────
CREATE OR REPLACE FUNCTION record_workflow_sla_warning(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_warning_offset_index INTEGER,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, warning_offset_index INTEGER, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
  v_offset JSONB;
  v_due_at TIMESTAMPTZ;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 OR p_warning_offset_index IS NULL THEN
    RAISE EXCEPTION 'Expected lock version, warning offset index, and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'warning_fired' OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR (v_existing.metadata ->> 'warning_offset_index')::INTEGER <> p_warning_offset_index
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, p_warning_offset_index, (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state <> 'running' THEN
    RAISE EXCEPTION 'Workflow SLA clock is not running' USING ERRCODE = '55000';
  END IF;
  IF p_warning_offset_index < 0 OR p_warning_offset_index >= jsonb_array_length(v_clock.warning_offsets) THEN
    RAISE EXCEPTION 'Warning offset index out of range' USING ERRCODE = '22023';
  END IF;
  IF p_warning_offset_index <> v_clock.warned_up_to_index + 1 THEN
    RAISE EXCEPTION 'Warning offsets must be recorded in order, next expected index is %', v_clock.warned_up_to_index + 1 USING ERRCODE = '55000';
  END IF;

  v_offset := v_clock.warning_offsets -> p_warning_offset_index;
  v_due_at := v_clock.effective_deadline_adjusted - workflow_sla_offset_interval((v_offset ->> 'amount')::NUMERIC, v_offset ->> 'unit');
  IF clock_timestamp() < v_due_at THEN
    RAISE EXCEPTION 'Warning offset % is not yet due', p_warning_offset_index USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_sla_clocks
  SET warned_up_to_index = p_warning_offset_index, lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'warning_fired', v_actor, p_idempotency_key,
    jsonb_build_object('warning_offset_index', p_warning_offset_index, 'expected_lock_version', p_expected_lock_version,
                        'result_lock_version', v_clock.lock_version + 1));

  RETURN QUERY SELECT p_clock_id, p_warning_offset_index, v_clock.lock_version + 1, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION record_workflow_sla_warning(UUID,BIGINT,INTEGER,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_workflow_sla_warning(UUID,BIGINT,INTEGER,UUID) TO authenticated;

-- ─── 20. record_workflow_sla_breach — records that the clock's own
--    deadline has elapsed. Sets breached_at only; never changes
--    clock.state (the work item stays active -- "breached" is
--    evidence, not a lifecycle state, per the governing instruction's
--    smallest-state-machine rule). Two independent paths can
--    legitimately reach the same breach fact (a future due-detection
--    worker calling this RPC directly, and a manual mark_breached
--    escalation action via trigger_workflow_sla_escalation) so once
--    breached_at is already set this call succeeds as a no-op rather
--    than erroring. ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION record_workflow_sla_breach(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS TABLE (clock_id UUID, breached_at TIMESTAMPTZ, lock_version BIGINT, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_existing workflow_sla_clock_events;
  v_new_breached_at TIMESTAMPTZ;
  v_new_lock_version BIGINT;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM workflow_sla_clock_events
  WHERE workflow_sla_clock_events.clock_id = p_clock_id AND workflow_sla_clock_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.event_type <> 'breached'
       OR (v_existing.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, v_clock.breached_at, (v_existing.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.breached_at IS NOT NULL THEN
    RETURN QUERY SELECT p_clock_id, v_clock.breached_at, v_clock.lock_version, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state <> 'running' THEN
    RAISE EXCEPTION 'Workflow SLA clock is not running' USING ERRCODE = '55000';
  END IF;
  IF clock_timestamp() < v_clock.effective_deadline_adjusted THEN
    RAISE EXCEPTION 'Workflow SLA clock deadline has not yet elapsed' USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_sla_clocks
  SET breached_at = clock_timestamp(), lock_version = workflow_sla_clocks.lock_version + 1
  WHERE id = p_clock_id
  RETURNING workflow_sla_clocks.breached_at, workflow_sla_clocks.lock_version INTO v_new_breached_at, v_new_lock_version;

  INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (p_clock_id, v_clock.instance_id, 'breached', v_actor, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_new_lock_version));

  RETURN QUERY SELECT p_clock_id, v_new_breached_at, v_new_lock_version, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION record_workflow_sla_breach(UUID,BIGINT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_workflow_sla_breach(UUID,BIGINT,UUID) TO authenticated;

-- ─── 21. trigger_workflow_sla_escalation — MANUAL escalation only.
--    Advances exactly one level (current_escalation_level + 1); never
--    skips, never fires the same level twice (both the explicit
--    lookup-by-next-level and the hard UNIQUE(clock_id,
--    escalation_level_id) backstop enforce this). Of the seven closed
--    escalation actions, only mark_breached performs a real effect
--    (and only ever touches this clock's own breached_at); the other
--    six are recorded as evidence only. Never grants visibility,
--    never advances the graph, never records a business decision, and
--    never delivers a notification -- this RPC's result is evidence
--    for a later milestone to act on. ───────────────────────────────
CREATE OR REPLACE FUNCTION trigger_workflow_sla_escalation(
  p_clock_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS TABLE (
  clock_id UUID, escalation_level_id UUID, level_order INTEGER, action_code TEXT,
  current_escalation_level INTEGER, lock_version BIGINT, replayed BOOLEAN
) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_clock workflow_sla_clocks;
  v_level workflow_escalation_levels;
  v_existing_event workflow_escalation_events;
  v_existing_by_key workflow_escalation_events;
  v_next_level INTEGER;
  v_new_lock_version BIGINT;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow SLA clock action requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  IF NOT can_manage_workflow_sla_clock(p_clock_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this SLA clock' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_sla_clock_lifecycle:' || v_actor::TEXT || ':' || p_clock_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_clock FROM workflow_sla_clocks WHERE id = p_clock_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow SLA clock is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing_by_key FROM workflow_escalation_events
  WHERE workflow_escalation_events.clock_id = p_clock_id AND workflow_escalation_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_by_key.triggering_actor_id IS DISTINCT FROM v_actor
       OR (v_existing_by_key.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_clock_id, v_existing_by_key.escalation_level_id, v_existing_by_key.level_order,
      v_existing_by_key.action_code, (v_existing_by_key.metadata ->> 'result_current_escalation_level')::INTEGER,
      (v_existing_by_key.metadata ->> 'result_lock_version')::BIGINT, TRUE;
    RETURN;
  END IF;

  IF v_clock.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow SLA clock changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_clock.state <> 'running' THEN
    RAISE EXCEPTION 'Workflow SLA clock is not running -- escalation cannot act on a paused or terminal clock' USING ERRCODE = '55000';
  END IF;
  IF v_clock.escalation_policy_id IS NULL THEN
    RAISE EXCEPTION 'This SLA clock has no escalation policy configured' USING ERRCODE = '55000';
  END IF;

  v_next_level := v_clock.current_escalation_level + 1;

  SELECT * INTO v_level FROM workflow_escalation_levels
  WHERE escalation_policy_id = v_clock.escalation_policy_id AND workflow_escalation_levels.level_order = v_next_level;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No further escalation level is configured beyond level %', v_clock.current_escalation_level USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_existing_event FROM workflow_escalation_events
  WHERE workflow_escalation_events.clock_id = p_clock_id AND workflow_escalation_events.escalation_level_id = v_level.id;
  IF FOUND THEN
    RAISE EXCEPTION 'Escalation level % has already fired for this clock', v_level.level_order USING ERRCODE = '55000';
  END IF;

  IF v_level.action_code = 'mark_breached' THEN
    UPDATE workflow_sla_clocks
    SET breached_at = COALESCE(breached_at, clock_timestamp()), current_escalation_level = v_next_level, lock_version = workflow_sla_clocks.lock_version + 1
    WHERE id = p_clock_id
    RETURNING workflow_sla_clocks.lock_version INTO v_new_lock_version;
  ELSE
    UPDATE workflow_sla_clocks
    SET current_escalation_level = v_next_level, lock_version = workflow_sla_clocks.lock_version + 1
    WHERE id = p_clock_id
    RETURNING workflow_sla_clocks.lock_version INTO v_new_lock_version;
  END IF;

  INSERT INTO workflow_escalation_events (
    clock_id, instance_id, escalation_level_id, level_order, action_code,
    triggered_by, triggering_actor_id, idempotency_key, metadata
  ) VALUES (
    p_clock_id, v_clock.instance_id, v_level.id, v_level.level_order, v_level.action_code,
    'manual', v_actor, p_idempotency_key,
    jsonb_build_object(
      'expected_lock_version', p_expected_lock_version, 'result_lock_version', v_new_lock_version,
      'result_current_escalation_level', v_next_level, 'action_config', v_level.action_config
    )
  );

  RETURN QUERY SELECT p_clock_id, v_level.id, v_level.level_order, v_level.action_code, v_next_level, v_new_lock_version, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION trigger_workflow_sla_escalation(UUID,BIGINT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION trigger_workflow_sla_escalation(UUID,BIGINT,UUID) TO authenticated;

COMMIT;
