-- ============================================================
-- CAP-002 Phase 5.1 — Delegation and Substitution Persistence
-- Foundation.
--
-- Implements ONLY the reusable backend persistence, validation,
-- authorization, lifecycle, and evidence foundation for workflow
-- delegation and substitution, per docs/73-workflow-delegation-
-- escalation-architecture.md. It does NOT integrate either feature
-- into live work-item resolution: workflow_work_items.assigned_to,
-- candidate resolution, approval decision authorization,
-- workflow_enter_downstream_node(), decide_workflow_work_item(), and
-- every other existing execution-plane function are untouched,
-- byte-for-byte, by this patch. No SLA clock, escalation execution,
-- timer, background worker, or notification exists yet — this
-- milestone stores only the states and rules a future automatic-
-- activation/expiry worker would need, per docs/73's own "Scalability
-- model" and the explicit Phase 5.1 instruction not to build one now.
--
-- Two new record families, each with its own append-only lifecycle-
-- evidence table, mirroring the exact terminal-state-immutability
-- discipline workflow_approval_rounds/workflow_approval_positions
-- already use (workflow_reject_terminal_round_mutation/
-- workflow_reject_terminal_position_mutation in patch-workflow-
-- approval-round-lifecycle.sql), and the exact idempotent-replay
-- discipline every other command in this engine already uses
-- (compare decide_workflow_work_item's post-Phase-4.3 replay
-- comparison, which this patch's lifecycle RPCs follow from day one
-- rather than needing a later hardening fix).
--
-- Delegation is structurally single-hop and non-transitive: a
-- delegation's delegator must hold standing authority in the named
-- scope (checked against existing, unmodified tables at creation
-- time), never merely another delegation — so no chain can ever be
-- constructed (docs/73 design decision 4). Reciprocal overlapping
-- delegation between the same two users for the same scope, and
-- ordinary same-direction duplicates, are both rejected by one
-- database-enforced EXCLUDE constraint keyed on an order-independent
-- pair fingerprint (see "Overlap enforcement" below) — this phase
-- elevates docs/73's "flag as a warning" guidance for the reciprocal
-- case to a hard, database-enforced rejection, per this phase's own
-- explicit instruction to prevent it outright; this is a deliberate,
-- documented tightening within the bounds docs/73 left open (see its
-- "Open questions"), not a contradiction of the architecture.
--
-- Substitution overlap for the same represented position/person is a
-- hard rejection with no reciprocal case (represented parties don't
-- have a symmetric "other side"), matching docs/73's "Substitution
-- limits" exactly (never a warning, always a rejection).
--
-- Overlap enforcement mechanism: PostgreSQL EXCLUDE USING gist
-- constraints (requiring btree_gist), the exact same mechanism and
-- style already established elsewhere in this repository for
-- meeting_room_bookings' conflict prevention (patch-rooms-booking-
-- foundation.sql) — proven, native, immune to any application bug or
-- direct-API bypass, not reinvented here.
--
-- "Overlap" in Version 1 means an EXACT match of every scope-
-- identifying field for the same scope/represented type — not fuzzy
-- hierarchical containment across granularities (e.g. an
-- organization-wide role scope is not treated as "overlapping" a
-- narrower section-scoped delegation of the same role). This is the
-- simplest, fully decidable rule and is documented explicitly per
-- this phase's "fail closed on ambiguous scope overlap" instruction:
-- comparisons this phase cannot decide (different scope/represented
-- types) are never attempted as "overlapping" — they are simply
-- different resources, not an ambiguous version of the same one.
-- ============================================================

BEGIN;

-- ─── 1. Extension (idempotent, additive only) ──────────────────────
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ─── 2. workflow_delegations ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workflow_delegations (
  id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id             UUID        NOT NULL REFERENCES organizations(id),
  delegator_id                UUID        NOT NULL REFERENCES users(id),
  delegate_id                 UUID        NOT NULL REFERENCES users(id),
  scope_type                  TEXT        NOT NULL CHECK (scope_type IN
                                 ('work_item','definition_step','organization_role','section_role')),
  scope_work_item_id          UUID        REFERENCES workflow_work_items(id),
  scope_definition_id         UUID        REFERENCES workflow_definitions(id),
  scope_step_key              TEXT,
  scope_role_organization_id  UUID        REFERENCES organizations(id),
  scope_section_id            UUID        REFERENCES sections(id),
  scope_role                  TEXT,
  scope_fingerprint           TEXT        GENERATED ALWAYS AS (
                                 scope_type || '|' ||
                                 COALESCE(scope_work_item_id::TEXT,'') || '|' ||
                                 COALESCE(scope_definition_id::TEXT,'') || '|' ||
                                 COALESCE(scope_step_key,'') || '|' ||
                                 COALESCE(scope_role_organization_id::TEXT,'') || '|' ||
                                 COALESCE(scope_section_id::TEXT,'') || '|' ||
                                 COALESCE(scope_role,'')
                               ) STORED,
  pair_key                    TEXT        GENERATED ALWAYS AS (
                                 LEAST(delegator_id::TEXT, delegate_id::TEXT) || ':' ||
                                 GREATEST(delegator_id::TEXT, delegate_id::TEXT)
                               ) STORED,
  kind                        TEXT        NOT NULL CHECK (kind IN ('temporary','permanent')),
  activation_mode             TEXT        NOT NULL CHECK (activation_mode IN ('manual','automatic')),
  starts_at                   TIMESTAMPTZ NOT NULL,
  ends_at                     TIMESTAMPTZ,
  effective_ends_at           TIMESTAMPTZ GENERATED ALWAYS AS (COALESCE(ends_at, 'infinity'::TIMESTAMPTZ)) STORED,
  status                      TEXT        NOT NULL CHECK (status IN
                                 ('pending_acceptance','scheduled','active','revoked','expired','rejected')),
  reason                      TEXT,
  created_by                  UUID        NOT NULL REFERENCES users(id),
  create_idempotency_key      UUID        NOT NULL,
  accepted_at                 TIMESTAMPTZ,
  accepted_by                 UUID        REFERENCES users(id),
  rejected_at                 TIMESTAMPTZ,
  rejected_by                 UUID        REFERENCES users(id),
  revoked_at                  TIMESTAMPTZ,
  revoked_by                  UUID        REFERENCES users(id),
  revocation_reason           TEXT,
  lock_version                BIGINT      NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT workflow_delegations_no_self_delegation CHECK (delegator_id <> delegate_id),
  CONSTRAINT workflow_delegations_creator_idempotency_unique UNIQUE (created_by, create_idempotency_key),
  CONSTRAINT workflow_delegations_window_check CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT workflow_delegations_kind_window_check CHECK (
    (kind = 'temporary' AND ends_at IS NOT NULL) OR (kind = 'permanent' AND ends_at IS NULL)
  ),
  CONSTRAINT workflow_delegations_scope_alignment_check CHECK (
    (scope_type = 'work_item' AND scope_work_item_id IS NOT NULL
       AND scope_definition_id IS NULL AND scope_step_key IS NULL
       AND scope_role_organization_id IS NULL AND scope_section_id IS NULL AND scope_role IS NULL)
    OR
    (scope_type = 'definition_step' AND scope_definition_id IS NOT NULL AND scope_step_key IS NOT NULL
       AND scope_work_item_id IS NULL
       AND scope_role_organization_id IS NULL AND scope_section_id IS NULL AND scope_role IS NULL)
    OR
    (scope_type = 'organization_role' AND scope_role_organization_id IS NOT NULL AND scope_role IS NOT NULL
       AND scope_work_item_id IS NULL AND scope_definition_id IS NULL AND scope_step_key IS NULL
       AND scope_section_id IS NULL)
    OR
    (scope_type = 'section_role' AND scope_section_id IS NOT NULL AND scope_role IS NOT NULL
       AND scope_work_item_id IS NULL AND scope_definition_id IS NULL AND scope_step_key IS NULL
       AND scope_role_organization_id IS NULL)
  ),
  CONSTRAINT workflow_delegations_step_key_check CHECK (scope_step_key IS NULL OR scope_step_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_delegations_role_check CHECK (scope_role IS NULL OR scope_role IN
    ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff')),
  CONSTRAINT workflow_delegations_acceptance_alignment_check CHECK (
    (status = 'pending_acceptance' AND accepted_at IS NULL AND rejected_at IS NULL)
    OR (status <> 'pending_acceptance')
  ),
  CONSTRAINT workflow_delegations_rejected_alignment_check CHECK (
    (status = 'rejected' AND rejected_at IS NOT NULL AND rejected_by IS NOT NULL)
    OR (status <> 'rejected' AND rejected_at IS NULL AND rejected_by IS NULL)
  ),
  CONSTRAINT workflow_delegations_revoked_alignment_check CHECK (
    (status = 'revoked' AND revoked_at IS NOT NULL AND revoked_by IS NOT NULL)
    OR (status <> 'revoked' AND revoked_at IS NULL AND revoked_by IS NULL)
  )
);

-- Primary overlap safety net: same (unordered) delegator/delegate
-- pair, same exact scope, overlapping validity window, both records
-- in a non-terminal status — catches ordinary duplicates AND
-- reciprocal A->B / B->A delegation of the same scope in one rule,
-- since pair_key is order-independent. Immune to any application bug
-- or direct-API bypass, exactly like the meeting_room_bookings
-- precedent this mirrors.
ALTER TABLE workflow_delegations DROP CONSTRAINT IF EXISTS workflow_delegations_no_overlap;
ALTER TABLE workflow_delegations
  ADD CONSTRAINT workflow_delegations_no_overlap
  EXCLUDE USING gist (
    pair_key WITH =,
    scope_fingerprint WITH =,
    tstzrange(starts_at, effective_ends_at, '[)') WITH &&
  ) WHERE (status IN ('pending_acceptance','scheduled','active'));

CREATE INDEX IF NOT EXISTS idx_workflow_delegations_delegator
  ON workflow_delegations (delegator_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_delegations_delegate
  ON workflow_delegations (delegate_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_delegations_org
  ON workflow_delegations (organization_id, status, created_at DESC, id DESC);

DROP TRIGGER IF EXISTS set_updated_at ON workflow_delegations;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_delegations
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Terminal-state immutability, mirroring workflow_reject_terminal_
-- round_mutation exactly: the one-time transition INTO a terminal
-- status remains unaffected; once OLD.status is already terminal, any
-- further UPDATE is rejected, and DELETE is always rejected.
CREATE OR REPLACE FUNCTION workflow_reject_terminal_delegation_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Workflow delegation history is immutable and cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF OLD.status IN ('revoked','expired','rejected') THEN
    RAISE EXCEPTION 'Workflow delegation % has already reached a terminal state and cannot be modified', OLD.id
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_delegations_immutable_after_terminal ON workflow_delegations;
CREATE TRIGGER workflow_delegations_immutable_after_terminal
  BEFORE UPDATE OR DELETE ON workflow_delegations
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_terminal_delegation_mutation();

-- ─── 3. workflow_delegation_events (immutable evidence) ─────────────
CREATE TABLE IF NOT EXISTS workflow_delegation_events (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  delegation_id     UUID        NOT NULL REFERENCES workflow_delegations(id),
  event_type        TEXT        NOT NULL CHECK (event_type IN
                       ('created','accepted','rejected','activated','revoked','expired')),
  actor_id          UUID        REFERENCES users(id),
  previous_status   TEXT,
  new_status        TEXT        NOT NULL,
  reason            TEXT,
  idempotency_key   UUID        NOT NULL,
  metadata          JSONB       NOT NULL DEFAULT '{}'::JSONB,
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_delegation_events_idempotency_unique UNIQUE (delegation_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_workflow_delegation_events_history
  ON workflow_delegation_events (delegation_id, occurred_at, id);

CREATE OR REPLACE FUNCTION workflow_reject_delegation_event_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_delegation_events_immutable ON workflow_delegation_events;
CREATE TRIGGER workflow_delegation_events_immutable
  BEFORE UPDATE OR DELETE ON workflow_delegation_events
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_delegation_event_mutation();

-- ─── 4. workflow_substitutions ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS workflow_substitutions (
  id                             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id                UUID        NOT NULL REFERENCES organizations(id),
  represented_type                TEXT        NOT NULL CHECK (represented_type IN
                                    ('user','organization_role','section_role')),
  represented_user_id             UUID        REFERENCES users(id),
  represented_role_organization_id UUID       REFERENCES organizations(id),
  represented_section_id          UUID        REFERENCES sections(id),
  represented_role                TEXT,
  represented_fingerprint         TEXT        GENERATED ALWAYS AS (
                                     represented_type || '|' ||
                                     COALESCE(represented_user_id::TEXT,'') || '|' ||
                                     COALESCE(represented_role_organization_id::TEXT,'') || '|' ||
                                     COALESCE(represented_section_id::TEXT,'') || '|' ||
                                     COALESCE(represented_role,'')
                                   ) STORED,
  substitute_id                   UUID        NOT NULL REFERENCES users(id),
  kind                             TEXT        NOT NULL CHECK (kind IN ('planned_leave','acting_appointment')),
  starts_at                       TIMESTAMPTZ NOT NULL,
  ends_at                         TIMESTAMPTZ NOT NULL,
  status                          TEXT        NOT NULL CHECK (status IN
                                    ('scheduled','active','revoked','expired','cancelled')),
  reason                          TEXT,
  configured_by                   UUID        NOT NULL REFERENCES users(id),
  create_idempotency_key          UUID        NOT NULL,
  revoked_at                      TIMESTAMPTZ,
  revoked_by                      UUID        REFERENCES users(id),
  revocation_reason               TEXT,
  lock_version                    BIGINT      NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT workflow_substitutions_creator_idempotency_unique UNIQUE (configured_by, create_idempotency_key),
  CONSTRAINT workflow_substitutions_window_check CHECK (ends_at > starts_at),
  CONSTRAINT workflow_substitutions_kind_type_check CHECK (
    (kind = 'planned_leave' AND represented_type = 'user')
    OR (kind = 'acting_appointment' AND represented_type IN ('organization_role','section_role'))
  ),
  CONSTRAINT workflow_substitutions_represented_alignment_check CHECK (
    (represented_type = 'user' AND represented_user_id IS NOT NULL
       AND represented_role_organization_id IS NULL AND represented_section_id IS NULL AND represented_role IS NULL)
    OR
    (represented_type = 'organization_role' AND represented_role_organization_id IS NOT NULL AND represented_role IS NOT NULL
       AND represented_user_id IS NULL AND represented_section_id IS NULL)
    OR
    (represented_type = 'section_role' AND represented_section_id IS NOT NULL AND represented_role IS NOT NULL
       AND represented_user_id IS NULL AND represented_role_organization_id IS NULL)
  ),
  CONSTRAINT workflow_substitutions_role_check CHECK (represented_role IS NULL OR represented_role IN
    ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff')),
  CONSTRAINT workflow_substitutions_no_self_substitution CHECK (
    represented_type <> 'user' OR represented_user_id <> substitute_id
  ),
  CONSTRAINT workflow_substitutions_revoked_alignment_check CHECK (
    (status IN ('revoked','cancelled') AND revoked_at IS NOT NULL AND revoked_by IS NOT NULL)
    OR (status NOT IN ('revoked','cancelled') AND revoked_at IS NULL AND revoked_by IS NULL)
  )
);

-- Hard-reject overlap for the same represented position/person and
-- effective scope — never merely a warning, per docs/73's
-- "Substitution limits" (deterministic effective-substitute
-- resolution: "who is acting for X right now" always has exactly one
-- unambiguous answer).
ALTER TABLE workflow_substitutions DROP CONSTRAINT IF EXISTS workflow_substitutions_no_overlap;
ALTER TABLE workflow_substitutions
  ADD CONSTRAINT workflow_substitutions_no_overlap
  EXCLUDE USING gist (
    represented_fingerprint WITH =,
    tstzrange(starts_at, ends_at, '[)') WITH &&
  ) WHERE (status IN ('scheduled','active'));

CREATE INDEX IF NOT EXISTS idx_workflow_substitutions_represented_user
  ON workflow_substitutions (represented_user_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_substitutions_represented_org
  ON workflow_substitutions (represented_role_organization_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_substitutions_represented_section
  ON workflow_substitutions (represented_section_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_substitutions_substitute
  ON workflow_substitutions (substitute_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_substitutions_org
  ON workflow_substitutions (organization_id, status, created_at DESC, id DESC);

DROP TRIGGER IF EXISTS set_updated_at ON workflow_substitutions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_substitutions
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE OR REPLACE FUNCTION workflow_reject_terminal_substitution_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Workflow substitution history is immutable and cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF OLD.status IN ('revoked','expired','cancelled') THEN
    RAISE EXCEPTION 'Workflow substitution % has already reached a terminal state and cannot be modified', OLD.id
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_substitutions_immutable_after_terminal ON workflow_substitutions;
CREATE TRIGGER workflow_substitutions_immutable_after_terminal
  BEFORE UPDATE OR DELETE ON workflow_substitutions
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_terminal_substitution_mutation();

-- ─── 5. workflow_substitution_events (immutable evidence) ───────────
CREATE TABLE IF NOT EXISTS workflow_substitution_events (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  substitution_id   UUID        NOT NULL REFERENCES workflow_substitutions(id),
  event_type        TEXT        NOT NULL CHECK (event_type IN
                       ('created','activated','revoked','cancelled','expired')),
  actor_id          UUID        REFERENCES users(id),
  previous_status   TEXT,
  new_status        TEXT        NOT NULL,
  reason            TEXT,
  idempotency_key   UUID        NOT NULL,
  metadata          JSONB       NOT NULL DEFAULT '{}'::JSONB,
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_substitution_events_idempotency_unique UNIQUE (substitution_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_workflow_substitution_events_history
  ON workflow_substitution_events (substitution_id, occurred_at, id);

DROP TRIGGER IF EXISTS workflow_substitution_events_immutable ON workflow_substitution_events;
CREATE TRIGGER workflow_substitution_events_immutable
  BEFORE UPDATE OR DELETE ON workflow_substitution_events
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_delegation_event_mutation();

-- ─── 6. Shared visibility predicates ─────────────────────────────────
-- Reused identically by RLS policies (direct-read backstop) and the
-- get_/list_ RPCs below (the actual, SECURITY DEFINER read path) —
-- one authoritative definition, not duplicated logic.
CREATE OR REPLACE FUNCTION workflow_delegation_visible_to_caller(
  p_delegator_id UUID, p_delegate_id UUID, p_organization_id UUID
) RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin()
    OR p_delegator_id = auth.uid()
    OR p_delegate_id = auth.uid()
    OR (p_organization_id = get_my_org_id() AND is_admin())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION workflow_substitution_visible_to_caller(
  p_represented_type TEXT, p_represented_user_id UUID, p_substitute_id UUID, p_organization_id UUID
) RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin()
    OR p_substitute_id = auth.uid()
    OR (p_represented_type = 'user' AND p_represented_user_id = auth.uid())
    OR (p_organization_id = get_my_org_id() AND is_admin())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION can_manage_workflow_delegation_scope(p_organization_id UUID)
RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin() OR (p_organization_id = get_my_org_id() AND is_admin())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. create_workflow_delegation ───────────────────────────────────
CREATE OR REPLACE FUNCTION create_workflow_delegation(
  p_organization_id UUID,
  p_delegator_id UUID,
  p_delegate_id UUID,
  p_scope JSONB,
  p_kind TEXT,
  p_activation_mode TEXT,
  p_starts_at TIMESTAMPTZ,
  p_ends_at TIMESTAMPTZ,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (
  delegation_id UUID,
  status TEXT,
  lock_version BIGINT,
  event_id UUID,
  replayed BOOLEAN
) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_is_org_admin BOOLEAN;
  v_existing workflow_delegations;
  v_existing_event workflow_delegation_events;
  v_scope_type TEXT;
  v_scope_keys TEXT[];
  v_scope_work_item_id UUID;
  v_scope_definition_id UUID;
  v_scope_step_key TEXT;
  v_scope_role_organization_id UUID;
  v_scope_section_id UUID;
  v_scope_role TEXT;
  v_status TEXT;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_delegation_id UUID;
  v_event_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow delegation creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_organization_id IS NULL OR p_delegator_id IS NULL OR p_delegate_id IS NULL
     OR p_scope IS NULL OR jsonb_typeof(p_scope) <> 'object'
     OR p_kind IS NULL OR p_activation_mode IS NULL OR p_starts_at IS NULL THEN
    RAISE EXCEPTION 'Missing required delegation fields' USING ERRCODE = '22023';
  END IF;
  IF p_kind NOT IN ('temporary','permanent') THEN
    RAISE EXCEPTION 'Invalid delegation kind' USING ERRCODE = '22023';
  END IF;
  IF p_activation_mode NOT IN ('manual','automatic') THEN
    RAISE EXCEPTION 'Invalid delegation activation mode' USING ERRCODE = '22023';
  END IF;
  IF p_delegator_id = p_delegate_id THEN
    RAISE EXCEPTION 'Self-delegation is not permitted' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'temporary' AND p_ends_at IS NULL THEN
    RAISE EXCEPTION 'Temporary delegation requires an end time' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'permanent' AND p_ends_at IS NOT NULL THEN
    RAISE EXCEPTION 'Permanent delegation must not specify an end time' USING ERRCODE = '22023';
  END IF;
  IF p_ends_at IS NOT NULL AND p_ends_at <= p_starts_at THEN
    RAISE EXCEPTION 'End time must be after start time' USING ERRCODE = '22023';
  END IF;
  -- Initial Version 1 policy limit (docs/73 left the exact bound
  -- open; this phase applies the conservative default the governing
  -- instruction specifies).
  IF p_kind = 'temporary' AND p_ends_at > p_starts_at + INTERVAL '365 days' THEN
    RAISE EXCEPTION 'Temporary delegation exceeds the maximum permitted duration of 365 days' USING ERRCODE = '22023';
  END IF;

  -- Authorization (docs/73 "Authorization"): administrative authority
  -- is required for automatic activation or permanent delegation;
  -- otherwise the caller must be the delegator themself, or an
  -- administrator acting on the delegator's behalf.
  v_is_org_admin := can_manage_workflow_delegation_scope(p_organization_id);
  IF p_kind = 'permanent' OR p_activation_mode = 'automatic' THEN
    IF NOT v_is_org_admin THEN
      RAISE EXCEPTION 'Automatic or permanent delegation requires administrative authority over this organization' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF v_actor <> p_delegator_id AND NOT v_is_org_admin THEN
      RAISE EXCEPTION 'Not authorized to create a delegation for this delegator' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p_delegator_id AND u.is_active AND u.org_id = p_organization_id) THEN
    RAISE EXCEPTION 'Delegator is not an active member of this organization' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p_delegate_id AND u.is_active AND u.org_id = p_organization_id) THEN
    RAISE EXCEPTION 'Delegate must be an active member of the same organization' USING ERRCODE = '22023';
  END IF;

  -- Scope validation — one authoritative layer, closed allowlist of
  -- four scope types (docs/73 "Delegation scopes"). A delegation
  -- never grants a scope broader than the delegator's own current
  -- standing: for work_item and role-based scopes this is verified
  -- directly against existing, unmodified tables below.
  v_scope_type := p_scope ->> 'type';
  IF v_scope_type IS NULL OR v_scope_type NOT IN ('work_item','definition_step','organization_role','section_role') THEN
    RAISE EXCEPTION 'Unsupported delegation scope type' USING ERRCODE = '22023';
  END IF;

  CASE v_scope_type
    WHEN 'work_item' THEN
      v_scope_keys := ARRAY['type','work_item_id'];
      v_scope_work_item_id := NULLIF(p_scope ->> 'work_item_id','')::UUID;
      IF v_scope_work_item_id IS NULL THEN
        RAISE EXCEPTION 'work_item scope requires work_item_id' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM workflow_work_items w
        WHERE w.id = v_scope_work_item_id AND w.organization_id = p_organization_id
      ) THEN
        RAISE EXCEPTION 'Work item not found in this organization' USING ERRCODE = '22023';
      END IF;
      -- The delegator must be the work item's own current holder —
      -- a delegation cannot name a scope the delegator does not
      -- themself hold (docs/73 "Delegation scopes").
      IF NOT EXISTS (
        SELECT 1 FROM workflow_work_items w
        WHERE w.id = v_scope_work_item_id AND w.assigned_to = p_delegator_id
      ) THEN
        RAISE EXCEPTION 'Delegator does not hold the named work item' USING ERRCODE = '42501';
      END IF;
    WHEN 'definition_step' THEN
      v_scope_keys := ARRAY['type','definition_id','step_key'];
      v_scope_definition_id := NULLIF(p_scope ->> 'definition_id','')::UUID;
      v_scope_step_key := p_scope ->> 'step_key';
      IF v_scope_definition_id IS NULL OR v_scope_step_key IS NULL OR v_scope_step_key !~ '^[a-z][a-z0-9_]{0,62}$' THEN
        RAISE EXCEPTION 'definition_step scope requires a valid definition_id and step_key' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM workflow_definitions d
        WHERE d.id = v_scope_definition_id AND (d.organization_id = p_organization_id OR d.organization_id IS NULL)
      ) THEN
        RAISE EXCEPTION 'Workflow definition not found in this organization' USING ERRCODE = '22023';
      END IF;
    WHEN 'organization_role' THEN
      v_scope_keys := ARRAY['type','organization_id','role'];
      v_scope_role_organization_id := NULLIF(p_scope ->> 'organization_id','')::UUID;
      v_scope_role := p_scope ->> 'role';
      IF v_scope_role_organization_id IS DISTINCT FROM p_organization_id THEN
        RAISE EXCEPTION 'organization_role scope must match the delegation organization' USING ERRCODE = '22023';
      END IF;
      IF v_scope_role IS NULL OR v_scope_role NOT IN ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff') THEN
        RAISE EXCEPTION 'Unsupported organization role' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM user_assignments a
        WHERE a.user_id = p_delegator_id AND a.scope_type = 'organization' AND a.scope_id = p_organization_id
          AND a.role = v_scope_role AND a.is_active
      ) THEN
        RAISE EXCEPTION 'Delegator does not hold the named organization role' USING ERRCODE = '42501';
      END IF;
    WHEN 'section_role' THEN
      v_scope_keys := ARRAY['type','section_id','role'];
      v_scope_section_id := NULLIF(p_scope ->> 'section_id','')::UUID;
      v_scope_role := p_scope ->> 'role';
      IF v_scope_section_id IS NULL THEN
        RAISE EXCEPTION 'section_role scope requires section_id' USING ERRCODE = '22023';
      END IF;
      IF v_scope_role IS NULL OR v_scope_role NOT IN ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff') THEN
        RAISE EXCEPTION 'Unsupported section role' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM sections s WHERE s.id = v_scope_section_id AND s.org_id = p_organization_id) THEN
        RAISE EXCEPTION 'Section not found in this organization' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM user_assignments a
        WHERE a.user_id = p_delegator_id AND a.scope_type = 'section' AND a.scope_id = v_scope_section_id
          AND a.role = v_scope_role AND a.is_active
      ) THEN
        RAISE EXCEPTION 'Delegator does not hold the named section role' USING ERRCODE = '42501';
      END IF;
  END CASE;

  IF NOT (SELECT COALESCE(array_agg(k), ARRAY[]::TEXT[]) FROM jsonb_object_keys(p_scope) k) <@ v_scope_keys THEN
    RAISE EXCEPTION 'Unexpected fields in delegation scope' USING ERRCODE = '22023';
  END IF;

  -- Serialize retries of this exact caller/key first.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_delegation_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_delegations
  WHERE created_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.organization_id IS DISTINCT FROM p_organization_id
       OR v_existing.delegator_id IS DISTINCT FROM p_delegator_id
       OR v_existing.delegate_id IS DISTINCT FROM p_delegate_id
       OR v_existing.scope_type IS DISTINCT FROM v_scope_type
       OR v_existing.scope_work_item_id IS DISTINCT FROM v_scope_work_item_id
       OR v_existing.scope_definition_id IS DISTINCT FROM v_scope_definition_id
       OR v_existing.scope_step_key IS DISTINCT FROM v_scope_step_key
       OR v_existing.scope_role_organization_id IS DISTINCT FROM v_scope_role_organization_id
       OR v_existing.scope_section_id IS DISTINCT FROM v_scope_section_id
       OR v_existing.scope_role IS DISTINCT FROM v_scope_role
       OR v_existing.kind IS DISTINCT FROM p_kind
       OR v_existing.activation_mode IS DISTINCT FROM p_activation_mode
       OR v_existing.starts_at IS DISTINCT FROM p_starts_at
       OR v_existing.ends_at IS DISTINCT FROM p_ends_at
       OR v_existing.reason IS DISTINCT FROM p_reason THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    SELECT id INTO v_event_id FROM workflow_delegation_events
    WHERE workflow_delegation_events.delegation_id = v_existing.id AND event_type = 'created';
    RETURN QUERY SELECT v_existing.id, v_existing.status, v_existing.lock_version, v_event_id, TRUE;
    RETURN;
  END IF;

  -- Also serialize concurrent creates targeting the same logical
  -- (pair, scope) unit before either INSERT is attempted, so the
  -- EXCLUDE constraint below is a defense-in-depth backstop rather
  -- than the primary serialization mechanism.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'wf_delegation_overlap:' ||
      LEAST(p_delegator_id::TEXT, p_delegate_id::TEXT) || ':' || GREATEST(p_delegator_id::TEXT, p_delegate_id::TEXT) || ':' ||
      v_scope_type || ':' || COALESCE(v_scope_work_item_id::TEXT,'') || ':' || COALESCE(v_scope_definition_id::TEXT,'') || ':' ||
      COALESCE(v_scope_step_key,'') || ':' || COALESCE(v_scope_role_organization_id::TEXT,'') || ':' ||
      COALESCE(v_scope_section_id::TEXT,'') || ':' || COALESCE(v_scope_role,''),
      0
    )
  );

  v_status := CASE
    WHEN p_activation_mode = 'manual' THEN 'pending_acceptance'
    WHEN p_starts_at <= v_now THEN 'active'
    ELSE 'scheduled'
  END;

  INSERT INTO workflow_delegations (
    organization_id, delegator_id, delegate_id, scope_type,
    scope_work_item_id, scope_definition_id, scope_step_key,
    scope_role_organization_id, scope_section_id, scope_role,
    kind, activation_mode, starts_at, ends_at, status, reason,
    created_by, create_idempotency_key
  ) VALUES (
    p_organization_id, p_delegator_id, p_delegate_id, v_scope_type,
    v_scope_work_item_id, v_scope_definition_id, v_scope_step_key,
    v_scope_role_organization_id, v_scope_section_id, v_scope_role,
    p_kind, p_activation_mode, p_starts_at, p_ends_at, v_status, p_reason,
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_delegation_id;

  INSERT INTO workflow_delegation_events (
    delegation_id, event_type, actor_id, previous_status, new_status, reason, idempotency_key, metadata
  ) VALUES (
    v_delegation_id, 'created', v_actor, NULL, v_status, p_reason, p_idempotency_key,
    jsonb_build_object('kind', p_kind, 'activation_mode', p_activation_mode)
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_delegation_id, v_status, 0::BIGINT, v_event_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. accept_workflow_delegation ───────────────────────────────────
CREATE OR REPLACE FUNCTION accept_workflow_delegation(
  p_delegation_id UUID,
  p_expected_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS TABLE (delegation_id UUID, status TEXT, lock_version BIGINT, event_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_delegation workflow_delegations;
  v_existing_event workflow_delegation_events;
  v_new_status TEXT;
  v_event_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow delegation acceptance requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_delegation_lifecycle:' || v_actor::TEXT || ':' || p_delegation_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_delegation FROM workflow_delegations WHERE id = p_delegation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow delegation is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing_event FROM workflow_delegation_events
  WHERE workflow_delegation_events.delegation_id = p_delegation_id AND workflow_delegation_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_event.actor_id IS DISTINCT FROM v_actor
       OR v_existing_event.event_type <> 'accepted'
       OR (v_existing_event.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_delegation_id, v_existing_event.new_status,
      (v_existing_event.metadata ->> 'result_lock_version')::BIGINT, v_existing_event.id, TRUE;
    RETURN;
  END IF;

  IF v_delegation.delegate_id <> v_actor THEN
    RAISE EXCEPTION 'Only the named delegate may accept this delegation' USING ERRCODE = '42501';
  END IF;
  IF v_delegation.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow delegation changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_delegation.status <> 'pending_acceptance' THEN
    RAISE EXCEPTION 'Workflow delegation is not pending acceptance' USING ERRCODE = '55000';
  END IF;

  v_new_status := CASE WHEN v_delegation.starts_at <= clock_timestamp() THEN 'active' ELSE 'scheduled' END;

  UPDATE workflow_delegations
  SET status = v_new_status, accepted_at = clock_timestamp(), accepted_by = v_actor, lock_version = v_delegation.lock_version + 1
  WHERE id = p_delegation_id;

  INSERT INTO workflow_delegation_events (
    delegation_id, event_type, actor_id, previous_status, new_status, idempotency_key, metadata
  ) VALUES (
    p_delegation_id, 'accepted', v_actor, v_delegation.status, v_new_status, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_delegation.lock_version + 1)
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT p_delegation_id, v_new_status, v_delegation.lock_version + 1, v_event_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 9. reject_workflow_delegation ───────────────────────────────────
CREATE OR REPLACE FUNCTION reject_workflow_delegation(
  p_delegation_id UUID,
  p_expected_lock_version BIGINT,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (delegation_id UUID, status TEXT, lock_version BIGINT, event_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_delegation workflow_delegations;
  v_existing_event workflow_delegation_events;
  v_event_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow delegation rejection requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_delegation_lifecycle:' || v_actor::TEXT || ':' || p_delegation_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_delegation FROM workflow_delegations WHERE id = p_delegation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow delegation is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing_event FROM workflow_delegation_events
  WHERE workflow_delegation_events.delegation_id = p_delegation_id AND workflow_delegation_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_event.actor_id IS DISTINCT FROM v_actor
       OR v_existing_event.event_type <> 'rejected'
       OR v_existing_event.reason IS DISTINCT FROM p_reason
       OR (v_existing_event.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_delegation_id, v_existing_event.new_status,
      (v_existing_event.metadata ->> 'result_lock_version')::BIGINT, v_existing_event.id, TRUE;
    RETURN;
  END IF;

  IF v_delegation.delegate_id <> v_actor THEN
    RAISE EXCEPTION 'Only the named delegate may decline this delegation' USING ERRCODE = '42501';
  END IF;
  IF v_delegation.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow delegation changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_delegation.status <> 'pending_acceptance' THEN
    RAISE EXCEPTION 'Workflow delegation is not pending acceptance' USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_delegations
  SET status = 'rejected', rejected_at = clock_timestamp(), rejected_by = v_actor, lock_version = v_delegation.lock_version + 1
  WHERE id = p_delegation_id;

  INSERT INTO workflow_delegation_events (
    delegation_id, event_type, actor_id, previous_status, new_status, reason, idempotency_key, metadata
  ) VALUES (
    p_delegation_id, 'rejected', v_actor, v_delegation.status, 'rejected', p_reason, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_delegation.lock_version + 1)
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT p_delegation_id, 'rejected'::TEXT, v_delegation.lock_version + 1, v_event_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 10. revoke_workflow_delegation ──────────────────────────────────
CREATE OR REPLACE FUNCTION revoke_workflow_delegation(
  p_delegation_id UUID,
  p_expected_lock_version BIGINT,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (delegation_id UUID, status TEXT, lock_version BIGINT, event_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_delegation workflow_delegations;
  v_existing_event workflow_delegation_events;
  v_authorized BOOLEAN;
  v_event_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow delegation revocation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_delegation_lifecycle:' || v_actor::TEXT || ':' || p_delegation_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_delegation FROM workflow_delegations WHERE id = p_delegation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow delegation is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing_event FROM workflow_delegation_events
  WHERE workflow_delegation_events.delegation_id = p_delegation_id AND workflow_delegation_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_event.actor_id IS DISTINCT FROM v_actor
       OR v_existing_event.event_type <> 'revoked'
       OR v_existing_event.reason IS DISTINCT FROM p_reason
       OR (v_existing_event.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_delegation_id, v_existing_event.new_status,
      (v_existing_event.metadata ->> 'result_lock_version')::BIGINT, v_existing_event.id, TRUE;
    RETURN;
  END IF;

  v_authorized := v_delegation.delegator_id = v_actor OR can_manage_workflow_delegation_scope(v_delegation.organization_id);
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to revoke this delegation' USING ERRCODE = '42501';
  END IF;
  IF v_delegation.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow delegation changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_delegation.status IN ('revoked','expired','rejected') THEN
    RAISE EXCEPTION 'Workflow delegation has already reached a terminal state' USING ERRCODE = '55000';
  END IF;

  UPDATE workflow_delegations
  SET status = 'revoked', revoked_at = clock_timestamp(), revoked_by = v_actor, revocation_reason = p_reason,
      lock_version = v_delegation.lock_version + 1
  WHERE id = p_delegation_id;

  INSERT INTO workflow_delegation_events (
    delegation_id, event_type, actor_id, previous_status, new_status, reason, idempotency_key, metadata
  ) VALUES (
    p_delegation_id, 'revoked', v_actor, v_delegation.status, 'revoked', p_reason, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_delegation.lock_version + 1)
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT p_delegation_id, 'revoked'::TEXT, v_delegation.lock_version + 1, v_event_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 11. get_workflow_delegation / list_workflow_delegations ────────
CREATE OR REPLACE FUNCTION get_workflow_delegation(p_delegation_id UUID)
RETURNS TABLE (
  delegation_id UUID, organization_id UUID, delegator_id UUID, delegate_id UUID,
  scope_type TEXT, scope_work_item_id UUID, scope_definition_id UUID, scope_step_key TEXT,
  scope_role_organization_id UUID, scope_section_id UUID, scope_role TEXT,
  kind TEXT, activation_mode TEXT, starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ,
  status TEXT, reason TEXT, lock_version BIGINT, created_at TIMESTAMPTZ
) AS $$
  SELECT d.id, d.organization_id, d.delegator_id, d.delegate_id,
         d.scope_type, d.scope_work_item_id, d.scope_definition_id, d.scope_step_key,
         d.scope_role_organization_id, d.scope_section_id, d.scope_role,
         d.kind, d.activation_mode, d.starts_at, d.ends_at,
         d.status, d.reason, d.lock_version, d.created_at
  FROM workflow_delegations d
  WHERE d.id = p_delegation_id
    AND workflow_delegation_visible_to_caller(d.delegator_id, d.delegate_id, d.organization_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_workflow_delegations(
  p_organization_id UUID DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL
) RETURNS TABLE (
  delegation_id UUID, organization_id UUID, delegator_id UUID, delegate_id UUID,
  scope_type TEXT, kind TEXT, activation_mode TEXT, starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ,
  status TEXT, created_at TIMESTAMPTZ
) AS $$
  -- The p_role branches are a deliberate performance short-circuit,
  -- not a semantic change: with p_role set, the only rows a caller
  -- could ever see are their own (a strict subset of what
  -- workflow_delegation_visible_to_caller already allows via its own
  -- self-match branches), so the expensive multi-function visibility
  -- check — is_admin()/get_my_org_id()/is_super_admin() are all
  -- SECURITY DEFINER and therefore never inlined by the planner,
  -- making a per-row evaluation genuinely costly at scale — is only
  -- evaluated in the p_role IS NULL ("everything I can see, including
  -- via administrative authority") case that actually needs it.
  SELECT d.id, d.organization_id, d.delegator_id, d.delegate_id,
         d.scope_type, d.kind, d.activation_mode, d.starts_at, d.ends_at, d.status, d.created_at
  FROM workflow_delegations d
  WHERE (
    (p_role = 'delegator' AND d.delegator_id = auth.uid())
    OR (p_role = 'delegate' AND d.delegate_id = auth.uid())
    OR (p_role IS NULL AND workflow_delegation_visible_to_caller(d.delegator_id, d.delegate_id, d.organization_id))
  )
    AND (p_organization_id IS NULL OR d.organization_id = p_organization_id)
    AND (
      p_before_created_at IS NULL
      OR (p_before_id IS NOT NULL AND (d.created_at, d.id) < (p_before_created_at, p_before_id))
    )
  ORDER BY d.created_at DESC, d.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 12. create_workflow_substitution ────────────────────────────────
CREATE OR REPLACE FUNCTION create_workflow_substitution(
  p_organization_id UUID,
  p_represented JSONB,
  p_substitute_id UUID,
  p_kind TEXT,
  p_starts_at TIMESTAMPTZ,
  p_ends_at TIMESTAMPTZ,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (substitution_id UUID, status TEXT, lock_version BIGINT, event_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_existing workflow_substitutions;
  v_represented_type TEXT;
  v_represented_keys TEXT[];
  v_represented_user_id UUID;
  v_represented_role_organization_id UUID;
  v_represented_section_id UUID;
  v_represented_role TEXT;
  v_status TEXT;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_substitution_id UUID;
  v_event_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow substitution creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_organization_id IS NULL OR p_represented IS NULL OR jsonb_typeof(p_represented) <> 'object'
     OR p_substitute_id IS NULL OR p_kind IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL THEN
    RAISE EXCEPTION 'Missing required substitution fields' USING ERRCODE = '22023';
  END IF;
  IF p_kind NOT IN ('planned_leave','acting_appointment') THEN
    RAISE EXCEPTION 'Invalid substitution kind' USING ERRCODE = '22023';
  END IF;
  IF p_ends_at <= p_starts_at THEN
    RAISE EXCEPTION 'End time must be after start time' USING ERRCODE = '22023';
  END IF;
  IF p_ends_at > p_starts_at + INTERVAL '365 days' THEN
    RAISE EXCEPTION 'Substitution exceeds the maximum permitted duration of 365 days' USING ERRCODE = '22023';
  END IF;

  -- Authorization (docs/73: "always administrator-configured, never
  -- self-service").
  IF NOT can_manage_workflow_delegation_scope(p_organization_id) THEN
    RAISE EXCEPTION 'Creating a substitution requires administrative authority over this organization' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p_substitute_id AND u.is_active AND u.org_id = p_organization_id) THEN
    RAISE EXCEPTION 'Substitute must be an active member of this organization' USING ERRCODE = '22023';
  END IF;

  v_represented_type := p_represented ->> 'type';
  IF v_represented_type IS NULL OR v_represented_type NOT IN ('user','organization_role','section_role') THEN
    RAISE EXCEPTION 'Unsupported substitution represented type' USING ERRCODE = '22023';
  END IF;
  IF (p_kind = 'planned_leave' AND v_represented_type <> 'user')
     OR (p_kind = 'acting_appointment' AND v_represented_type NOT IN ('organization_role','section_role')) THEN
    RAISE EXCEPTION 'Substitution kind does not match represented type' USING ERRCODE = '22023';
  END IF;

  CASE v_represented_type
    WHEN 'user' THEN
      v_represented_keys := ARRAY['type','user_id'];
      v_represented_user_id := NULLIF(p_represented ->> 'user_id','')::UUID;
      IF v_represented_user_id IS NULL THEN
        RAISE EXCEPTION 'user substitution requires user_id' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM users u WHERE u.id = v_represented_user_id AND u.org_id = p_organization_id) THEN
        RAISE EXCEPTION 'Represented user not found in this organization' USING ERRCODE = '22023';
      END IF;
      IF v_represented_user_id = p_substitute_id THEN
        RAISE EXCEPTION 'Self-substitution is not permitted' USING ERRCODE = '22023';
      END IF;
    WHEN 'organization_role' THEN
      v_represented_keys := ARRAY['type','organization_id','role'];
      v_represented_role_organization_id := NULLIF(p_represented ->> 'organization_id','')::UUID;
      v_represented_role := p_represented ->> 'role';
      IF v_represented_role_organization_id IS DISTINCT FROM p_organization_id THEN
        RAISE EXCEPTION 'organization_role scope must match the substitution organization' USING ERRCODE = '22023';
      END IF;
      IF v_represented_role IS NULL OR v_represented_role NOT IN ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff') THEN
        RAISE EXCEPTION 'Unsupported organization role' USING ERRCODE = '22023';
      END IF;
    WHEN 'section_role' THEN
      v_represented_keys := ARRAY['type','section_id','role'];
      v_represented_section_id := NULLIF(p_represented ->> 'section_id','')::UUID;
      v_represented_role := p_represented ->> 'role';
      IF v_represented_section_id IS NULL THEN
        RAISE EXCEPTION 'section_role scope requires section_id' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM sections s WHERE s.id = v_represented_section_id AND s.org_id = p_organization_id) THEN
        RAISE EXCEPTION 'Section not found in this organization' USING ERRCODE = '22023';
      END IF;
      IF v_represented_role IS NULL OR v_represented_role NOT IN ('mcs_admin','authority_admin','supervisor','assigned_receiver','staff') THEN
        RAISE EXCEPTION 'Unsupported section role' USING ERRCODE = '22023';
      END IF;
  END CASE;

  IF NOT (SELECT COALESCE(array_agg(k), ARRAY[]::TEXT[]) FROM jsonb_object_keys(p_represented) k) <@ v_represented_keys THEN
    RAISE EXCEPTION 'Unexpected fields in substitution represented value' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_substitution_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_substitutions
  WHERE configured_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.organization_id IS DISTINCT FROM p_organization_id
       OR v_existing.represented_type IS DISTINCT FROM v_represented_type
       OR v_existing.represented_user_id IS DISTINCT FROM v_represented_user_id
       OR v_existing.represented_role_organization_id IS DISTINCT FROM v_represented_role_organization_id
       OR v_existing.represented_section_id IS DISTINCT FROM v_represented_section_id
       OR v_existing.represented_role IS DISTINCT FROM v_represented_role
       OR v_existing.substitute_id IS DISTINCT FROM p_substitute_id
       OR v_existing.kind IS DISTINCT FROM p_kind
       OR v_existing.starts_at IS DISTINCT FROM p_starts_at
       OR v_existing.ends_at IS DISTINCT FROM p_ends_at
       OR v_existing.reason IS DISTINCT FROM p_reason THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    SELECT id INTO v_event_id FROM workflow_substitution_events
    WHERE workflow_substitution_events.substitution_id = v_existing.id AND event_type = 'created';
    RETURN QUERY SELECT v_existing.id, v_existing.status, v_existing.lock_version, v_event_id, TRUE;
    RETURN;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'wf_substitution_overlap:' || v_represented_type || ':' ||
      COALESCE(v_represented_user_id::TEXT,'') || ':' || COALESCE(v_represented_role_organization_id::TEXT,'') || ':' ||
      COALESCE(v_represented_section_id::TEXT,'') || ':' || COALESCE(v_represented_role,''),
      0
    )
  );

  v_status := CASE WHEN p_starts_at <= v_now THEN 'active' ELSE 'scheduled' END;

  INSERT INTO workflow_substitutions (
    organization_id, represented_type, represented_user_id, represented_role_organization_id,
    represented_section_id, represented_role, substitute_id, kind, starts_at, ends_at, status, reason,
    configured_by, create_idempotency_key
  ) VALUES (
    p_organization_id, v_represented_type, v_represented_user_id, v_represented_role_organization_id,
    v_represented_section_id, v_represented_role, p_substitute_id, p_kind, p_starts_at, p_ends_at, v_status, p_reason,
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_substitution_id;

  INSERT INTO workflow_substitution_events (
    substitution_id, event_type, actor_id, previous_status, new_status, reason, idempotency_key, metadata
  ) VALUES (
    v_substitution_id, 'created', v_actor, NULL, v_status, p_reason, p_idempotency_key,
    jsonb_build_object('kind', p_kind)
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_substitution_id, v_status, 0::BIGINT, v_event_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 13. revoke_workflow_substitution ────────────────────────────────
-- Sets 'cancelled' if the record was still 'scheduled' (never became
-- effective) or 'revoked' if it was already 'active' — docs/73 +
-- this phase's explicit "revocation or cancellation before
-- activation where architecture permits", determined by the record's
-- own current status at revocation time, not a separate command.
CREATE OR REPLACE FUNCTION revoke_workflow_substitution(
  p_substitution_id UUID,
  p_expected_lock_version BIGINT,
  p_reason TEXT,
  p_idempotency_key UUID
) RETURNS TABLE (substitution_id UUID, status TEXT, lock_version BIGINT, event_id UUID, replayed BOOLEAN) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_substitution workflow_substitutions;
  v_existing_event workflow_substitution_events;
  v_new_status TEXT;
  v_event_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow substitution revocation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_expected_lock_version IS NULL OR p_expected_lock_version < 0 THEN
    RAISE EXCEPTION 'Expected lock version and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('wf_substitution_lifecycle:' || v_actor::TEXT || ':' || p_substitution_id::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_substitution FROM workflow_substitutions WHERE id = p_substitution_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow substitution is not available for this action' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing_event FROM workflow_substitution_events
  WHERE workflow_substitution_events.substitution_id = p_substitution_id AND workflow_substitution_events.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing_event.actor_id IS DISTINCT FROM v_actor
       OR v_existing_event.event_type NOT IN ('revoked','cancelled')
       OR v_existing_event.reason IS DISTINCT FROM p_reason
       OR (v_existing_event.metadata ->> 'expected_lock_version')::BIGINT <> p_expected_lock_version THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT p_substitution_id, v_existing_event.new_status,
      (v_existing_event.metadata ->> 'result_lock_version')::BIGINT, v_existing_event.id, TRUE;
    RETURN;
  END IF;

  IF NOT can_manage_workflow_delegation_scope(v_substitution.organization_id) THEN
    RAISE EXCEPTION 'Not authorized to revoke this substitution' USING ERRCODE = '42501';
  END IF;
  IF v_substitution.lock_version <> p_expected_lock_version THEN
    RAISE EXCEPTION 'Workflow substitution changed concurrently' USING ERRCODE = '40001';
  END IF;
  IF v_substitution.status IN ('revoked','expired','cancelled') THEN
    RAISE EXCEPTION 'Workflow substitution has already reached a terminal state' USING ERRCODE = '55000';
  END IF;

  v_new_status := CASE WHEN v_substitution.status = 'scheduled' THEN 'cancelled' ELSE 'revoked' END;

  UPDATE workflow_substitutions
  SET status = v_new_status, revoked_at = clock_timestamp(), revoked_by = v_actor, revocation_reason = p_reason,
      lock_version = v_substitution.lock_version + 1
  WHERE id = p_substitution_id;

  INSERT INTO workflow_substitution_events (
    substitution_id, event_type, actor_id, previous_status, new_status, reason, idempotency_key, metadata
  ) VALUES (
    p_substitution_id, v_new_status, v_actor, v_substitution.status, v_new_status, p_reason, p_idempotency_key,
    jsonb_build_object('expected_lock_version', p_expected_lock_version, 'result_lock_version', v_substitution.lock_version + 1)
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT p_substitution_id, v_new_status, v_substitution.lock_version + 1, v_event_id, FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 14. get_workflow_substitution / list_workflow_substitutions ────
CREATE OR REPLACE FUNCTION get_workflow_substitution(p_substitution_id UUID)
RETURNS TABLE (
  substitution_id UUID, organization_id UUID, represented_type TEXT, represented_user_id UUID,
  represented_role_organization_id UUID, represented_section_id UUID, represented_role TEXT,
  substitute_id UUID, kind TEXT, starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ,
  status TEXT, reason TEXT, lock_version BIGINT, created_at TIMESTAMPTZ
) AS $$
  SELECT s.id, s.organization_id, s.represented_type, s.represented_user_id,
         s.represented_role_organization_id, s.represented_section_id, s.represented_role,
         s.substitute_id, s.kind, s.starts_at, s.ends_at, s.status, s.reason, s.lock_version, s.created_at
  FROM workflow_substitutions s
  WHERE s.id = p_substitution_id
    AND workflow_substitution_visible_to_caller(s.represented_type, s.represented_user_id, s.substitute_id, s.organization_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_workflow_substitutions(
  p_organization_id UUID DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL
) RETURNS TABLE (
  substitution_id UUID, organization_id UUID, represented_type TEXT, represented_user_id UUID,
  represented_role_organization_id UUID, represented_section_id UUID, represented_role TEXT,
  substitute_id UUID, kind TEXT, starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ, status TEXT, created_at TIMESTAMPTZ
) AS $$
  -- Same deliberate performance short-circuit as list_workflow_
  -- delegations: with p_role set, only the caller's own rows (as
  -- represented party or substitute) are ever returned, a strict
  -- subset of workflow_substitution_visible_to_caller's own self-match
  -- branches, so the expensive admin-inclusive check only runs when
  -- p_role IS NULL.
  SELECT s.id, s.organization_id, s.represented_type, s.represented_user_id,
         s.represented_role_organization_id, s.represented_section_id, s.represented_role,
         s.substitute_id, s.kind, s.starts_at, s.ends_at, s.status, s.created_at
  FROM workflow_substitutions s
  WHERE (
    (p_role = 'represented' AND s.represented_type = 'user' AND s.represented_user_id = auth.uid())
    OR (p_role = 'substitute' AND s.substitute_id = auth.uid())
    OR (p_role IS NULL AND workflow_substitution_visible_to_caller(s.represented_type, s.represented_user_id, s.substitute_id, s.organization_id))
  )
    AND (p_organization_id IS NULL OR s.organization_id = p_organization_id)
    AND (
      p_before_created_at IS NULL
      OR (p_before_id IS NOT NULL AND (s.created_at, s.id) < (p_before_created_at, p_before_id))
    )
  ORDER BY s.created_at DESC, s.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 15. RLS: SELECT only; every mutation is RPC-owned ───────────────
ALTER TABLE workflow_delegations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_delegation_events   ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_substitutions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_substitution_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS workflow_delegations_select ON workflow_delegations;
CREATE POLICY workflow_delegations_select ON workflow_delegations FOR SELECT
  USING (workflow_delegation_visible_to_caller(delegator_id, delegate_id, organization_id));

DROP POLICY IF EXISTS workflow_delegation_events_select ON workflow_delegation_events;
CREATE POLICY workflow_delegation_events_select ON workflow_delegation_events FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM workflow_delegations d
    WHERE d.id = workflow_delegation_events.delegation_id
      AND workflow_delegation_visible_to_caller(d.delegator_id, d.delegate_id, d.organization_id)
  ));

DROP POLICY IF EXISTS workflow_substitutions_select ON workflow_substitutions;
CREATE POLICY workflow_substitutions_select ON workflow_substitutions FOR SELECT
  USING (workflow_substitution_visible_to_caller(represented_type, represented_user_id, substitute_id, organization_id));

DROP POLICY IF EXISTS workflow_substitution_events_select ON workflow_substitution_events;
CREATE POLICY workflow_substitution_events_select ON workflow_substitution_events FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM workflow_substitutions s
    WHERE s.id = workflow_substitution_events.substitution_id
      AND workflow_substitution_visible_to_caller(s.represented_type, s.represented_user_id, s.substitute_id, s.organization_id)
  ));

-- ─── 16. Grants ──────────────────────────────────────────────────────
REVOKE ALL ON TABLE
  workflow_delegations, workflow_delegation_events,
  workflow_substitutions, workflow_substitution_events
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE
  workflow_delegations, workflow_delegation_events,
  workflow_substitutions, workflow_substitution_events
  TO authenticated;

-- These two are invoked directly from RLS USING clauses, which
-- evaluate in the querying role's own context (authenticated) rather
-- than as a nested call from within another SECURITY DEFINER
-- function body — so, exactly like can_view_workflow_instance/
-- can_manage_workflow_instance (patch-workflow-backend-foundation.sql),
-- authenticated needs EXECUTE for RLS to work at all; only anon is
-- denied.
REVOKE ALL ON FUNCTION workflow_delegation_visible_to_caller(UUID,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION workflow_delegation_visible_to_caller(UUID,UUID,UUID) TO authenticated;
REVOKE ALL ON FUNCTION workflow_substitution_visible_to_caller(TEXT,UUID,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION workflow_substitution_visible_to_caller(TEXT,UUID,UUID,UUID) TO authenticated;
-- can_manage_workflow_delegation_scope is only ever called from
-- within already-SECURITY-DEFINER RPC bodies (never from an RLS
-- USING clause), so it stays fully ungranted, like
-- can_manage_workflow_definition.
REVOKE ALL ON FUNCTION can_manage_workflow_delegation_scope(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION workflow_reject_terminal_delegation_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION workflow_reject_delegation_event_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION workflow_reject_terminal_substitution_mutation() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION create_workflow_delegation(UUID,UUID,UUID,JSONB,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_delegation(UUID,UUID,UUID,JSONB,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION accept_workflow_delegation(UUID,BIGINT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION accept_workflow_delegation(UUID,BIGINT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION reject_workflow_delegation(UUID,BIGINT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION reject_workflow_delegation(UUID,BIGINT,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION revoke_workflow_delegation(UUID,BIGINT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION revoke_workflow_delegation(UUID,BIGINT,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION get_workflow_delegation(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_workflow_delegation(UUID) TO authenticated;
REVOKE ALL ON FUNCTION list_workflow_delegations(UUID,TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION list_workflow_delegations(UUID,TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;

REVOKE ALL ON FUNCTION create_workflow_substitution(UUID,JSONB,UUID,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_workflow_substitution(UUID,JSONB,UUID,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION revoke_workflow_substitution(UUID,BIGINT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION revoke_workflow_substitution(UUID,BIGINT,TEXT,UUID) TO authenticated;
REVOKE ALL ON FUNCTION get_workflow_substitution(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_workflow_substitution(UUID) TO authenticated;
REVOKE ALL ON FUNCTION list_workflow_substitutions(UUID,TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION list_workflow_substitutions(UUID,TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;

COMMIT;
