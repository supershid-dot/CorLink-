-- ============================================================
-- CAP-003 Phase 1.2 -- Recipient Resolution + Authorization-Safe
-- Notification Intent Creation.
--
-- Implements the generic layer docs/78 §6-§8/§25 scope for this
-- milestone: notification_intents (the "these recipients should learn
-- about this event" decision, §6 -- deliberately not itself a
-- user-visible notification), a closed typed target-descriptor model
-- (§7.1, narrowed here to the six generic target kinds whose
-- membership/authorization semantics are already unambiguous in this
-- repository -- see docs/82 §"Supported generic target types" for the
-- narrowing rationale), server-authoritative recipient resolution
-- (§7.2-§7.3), and processing-time authorization revalidation (§8)
-- reusing existing helpers rather than inventing a parallel permission
-- system. No worker, no module integration, no legacy cutover -- all
-- deliberately deferred (§25 Phase 1.3/1.4/1.5).
--
-- Authorization dispatch is closed and structural, never dynamic SQL:
-- exactly two source_record_type values are supported for this
-- milestone -- 'workflow_instance' (CAP-002's own participant model,
-- the only source module whose visibility semantics are already
-- unambiguous AND generically resolvable without a module-specific
-- adapter) and 'platform' (no confidential source record at all, e.g.
-- a system-wide notice -- authorization reduces to "recipient is
-- active"). Any other source_record_type is rejected at intent
-- CREATION time, closed-allowlist, never faked -- Requests, Entry,
-- Internal Collaboration, Prisoner Letters, Tasks, and Meetings all
-- remain deferred to Phase 1.4's own module adapters, per the
-- governing instruction's explicit narrowing.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── Generalized explicit-user helpers (this milestone's own,
--    narrowly-scoped additions -- mirrors 1.0B's notif_* convention:
--    every existing RLS/visibility helper in this codebase is
--    auth.uid()-bound by design, since it only ever needs to answer
--    "can the CALLER see this", never "can this OTHER candidate user
--    see this". Prefixed intent_ to keep provenance distinct from
--    1.0B's notif_* helpers (a different milestone's own narrow
--    additions, for the legacy table's own authorization model). ───

CREATE OR REPLACE FUNCTION intent_user_is_super_admin(p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT is_super_admin FROM users WHERE id = p_user), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Generalized can_view_workflow_instance() (patch-workflow-backend-
-- foundation.sql) for an explicit candidate user rather than
-- auth.uid() -- same two branches (super_admin, or an active
-- workflow_participants row), reusing workflow_participants directly
-- rather than duplicating its membership logic.
CREATE OR REPLACE FUNCTION intent_user_can_view_workflow_instance(p_instance_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT intent_user_is_super_admin(p_user) OR EXISTS (
    SELECT 1 FROM workflow_participants p
    WHERE p.instance_id = p_instance_id AND p.user_id = p_user AND p.ended_at IS NULL
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── notification_intents ───────────────────────────────────────────
-- The "these recipients should learn about this event" decision
-- (docs/78 §6), never itself a user-visible notification. Every
-- business-identity field is denormalized from its parent outbox
-- event at creation time (trusted, server-derived -- never re-supplied
-- and trusted from a caller), matching user_notifications' own
-- established denormalization convention from Phase 1.1.
CREATE TABLE IF NOT EXISTS notification_intents (
  id                        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  outbox_event_id           UUID        NOT NULL REFERENCES platform_outbox_events(id),
  organization_id           UUID        NOT NULL REFERENCES organizations(id),
  notification_type         TEXT        NOT NULL
                               CHECK (notification_type ~ '^[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+\.v[1-9][0-9]*$'),
  title_template_key        TEXT        NOT NULL,
  template_params           JSONB       NOT NULL DEFAULT '{}'::JSONB,
  source_module              TEXT        NOT NULL,
  -- Closed authorization-dispatch key (see header) -- everything else
  -- about the source record is opaque to this generic layer.
  source_record_type        TEXT        NOT NULL CHECK (source_record_type IN ('workflow_instance', 'platform')),
  source_record_id          UUID        NOT NULL,
  priority                  TEXT        NOT NULL DEFAULT 'normal' CHECK (priority IN ('low','normal','high','urgent')),
  -- Closed target-descriptor model (docs/78 §7.1, narrowed -- see
  -- header). Exactly one target_* field is populated, matching
  -- target_type; enforced by the CHECK constraint below, not by
  -- convention.
  target_type                TEXT        NOT NULL CHECK (target_type IN (
                                'specific_users', 'org_admins', 'section', 'section_leadership',
                                'workflow_participants', 'work_item_assignee'
                              )),
  target_user_ids            UUID[],
  target_organization_id     UUID        REFERENCES organizations(id),
  target_section_id          UUID        REFERENCES sections(id),
  target_workflow_instance_id UUID       REFERENCES workflow_instances(id),
  target_work_item_id        UUID        REFERENCES workflow_work_items(id),
  -- Deterministic string identity of the target descriptor, used for
  -- enqueue-level dedup (UNIQUE below) -- e.g. a sorted, comma-joined
  -- user-id list for specific_users, or the bare id text for every
  -- single-id target type.
  target_key                 TEXT        NOT NULL,
  status                     TEXT        NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending', 'resolved', 'partially_resolved', 'failed')),
  resolved_at                 TIMESTAMPTZ,
  resolved_count              INTEGER     NOT NULL DEFAULT 0 CHECK (resolved_count >= 0),
  skipped_count                INTEGER     NOT NULL DEFAULT 0 CHECK (skipped_count >= 0),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT notification_intents_template_params_object CHECK (jsonb_typeof(template_params) = 'object'),
  CONSTRAINT notification_intents_template_params_bounded CHECK (pg_column_size(template_params) <= 4096),
  -- No user-controlled arbitrary recipient expansion (governing
  -- instruction, "INTENT CREATION API"): a specific_users target is
  -- bounded, never an unlimited list.
  CONSTRAINT notification_intents_target_user_ids_bounded CHECK (
    target_user_ids IS NULL OR array_length(target_user_ids, 1) <= 50
  ),
  -- Structural, not executable (governing instruction, "TARGET
  -- DESCRIPTOR SAFETY"): exactly one target_* field populated,
  -- matching target_type -- never a free-form expression.
  CONSTRAINT notification_intents_target_shape_check CHECK (
    (target_type = 'specific_users' AND target_user_ids IS NOT NULL AND array_length(target_user_ids,1) > 0
      AND target_organization_id IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL)
    OR (target_type = 'org_admins' AND target_organization_id IS NOT NULL
      AND target_user_ids IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL)
    OR (target_type IN ('section', 'section_leadership') AND target_section_id IS NOT NULL
      AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL)
    OR (target_type = 'workflow_participants' AND target_workflow_instance_id IS NOT NULL
      AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL AND target_work_item_id IS NULL)
    OR (target_type = 'work_item_assignee' AND target_work_item_id IS NOT NULL
      AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL)
  ),
  -- Enqueue-level dedup (docs/78 §14's own pattern, applied to
  -- intents): the same outbox event targeting the same descriptor
  -- identity never creates a second intent.
  CONSTRAINT notification_intents_dedup_unique UNIQUE (outbox_event_id, target_type, target_key)
);

CREATE INDEX IF NOT EXISTS idx_notification_intents_status_pending
  ON notification_intents (created_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_notification_intents_outbox_event
  ON notification_intents (outbox_event_id);
CREATE INDEX IF NOT EXISTS idx_notification_intents_created_brin
  ON notification_intents USING BRIN (created_at);

-- Business-fact columns are immutable once written -- same column-
-- diff BEFORE UPDATE pattern Phase 1.1 established for the two tables
-- it introduced (a plain "reject every UPDATE" trigger would be wrong
-- here too: status/resolved_at/resolved_count/skipped_count are
-- legitimately mutable outcome-recording fields).
CREATE OR REPLACE FUNCTION notification_intents_enforce_immutability()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.outbox_event_id IS DISTINCT FROM OLD.outbox_event_id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.notification_type IS DISTINCT FROM OLD.notification_type
     OR NEW.title_template_key IS DISTINCT FROM OLD.title_template_key
     OR NEW.template_params IS DISTINCT FROM OLD.template_params
     OR NEW.source_module IS DISTINCT FROM OLD.source_module
     OR NEW.source_record_type IS DISTINCT FROM OLD.source_record_type
     OR NEW.source_record_id IS DISTINCT FROM OLD.source_record_id
     OR NEW.priority IS DISTINCT FROM OLD.priority
     OR NEW.target_type IS DISTINCT FROM OLD.target_type
     OR NEW.target_user_ids IS DISTINCT FROM OLD.target_user_ids
     OR NEW.target_organization_id IS DISTINCT FROM OLD.target_organization_id
     OR NEW.target_section_id IS DISTINCT FROM OLD.target_section_id
     OR NEW.target_workflow_instance_id IS DISTINCT FROM OLD.target_workflow_instance_id
     OR NEW.target_work_item_id IS DISTINCT FROM OLD.target_work_item_id
     OR NEW.target_key IS DISTINCT FROM OLD.target_key
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'notification_intents business-fact/target-descriptor columns are immutable once written' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_notification_intents_immutability ON notification_intents;
CREATE TRIGGER trg_notification_intents_immutability
  BEFORE UPDATE ON notification_intents
  FOR EACH ROW EXECUTE FUNCTION notification_intents_enforce_immutability();

-- ─── RLS ─────────────────────────────────────────────────────────────
-- Internal platform object, same posture as platform_outbox_events
-- (docs/78 §17): RLS enabled, zero policies for authenticated/anon --
-- ordinary users never browse raw intents or target descriptors.
ALTER TABLE notification_intents ENABLE ROW LEVEL SECURITY;

-- ─── create_notification_intent -- internal/service-only ───────────
-- Every business-identity field (organization_id, source_module,
-- source_record_type, source_record_id) is DERIVED from the parent
-- outbox event, never re-supplied and trusted from the caller --
-- the source reference is therefore structurally valid by
-- construction, not merely validated after the fact.
CREATE OR REPLACE FUNCTION create_notification_intent(
  p_outbox_event_id      UUID,
  p_notification_type    TEXT,
  p_title_template_key   TEXT,
  p_template_params      JSONB,
  p_priority              TEXT,
  p_target_type           TEXT,
  p_target_user_ids       UUID[],
  p_target_organization_id UUID,
  p_target_section_id     UUID,
  p_target_workflow_instance_id UUID,
  p_target_work_item_id   UUID
) RETURNS UUID AS $$
DECLARE
  v_event RECORD;
  v_target_key TEXT;
  v_id UUID;
  v_sorted_ids UUID[];
BEGIN
  IF p_outbox_event_id IS NULL OR p_notification_type IS NULL OR p_title_template_key IS NULL
     OR p_target_type IS NULL
  THEN
    RAISE EXCEPTION 'outbox_event_id, notification_type, title_template_key, and target_type are all required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_event FROM platform_outbox_events WHERE id = p_outbox_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox_event_id % does not reference an existing outbox event', p_outbox_event_id USING ERRCODE = '22023';
  END IF;

  -- Closed source_record_type allowlist -- structural, at creation
  -- time, never a silent fake at resolution time (governing
  -- instruction: "Unsupported source types must fail closed or remain
  -- deferred").
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform') THEN
    RAISE EXCEPTION 'source_record_type % has no generic Phase 1.2 authorization dispatch and remains deferred to a future module-adapter phase', v_event.source_record_type USING ERRCODE = '42501';
  END IF;

  -- Derive the target_key deterministically per target_type.
  CASE p_target_type
    WHEN 'specific_users' THEN
      IF p_target_user_ids IS NULL OR array_length(p_target_user_ids,1) IS NULL THEN
        RAISE EXCEPTION 'target_user_ids is required for target_type=specific_users' USING ERRCODE = '22023';
      END IF;
      SELECT array_agg(DISTINCT u ORDER BY u) INTO v_sorted_ids FROM unnest(p_target_user_ids) AS u;
      v_target_key := array_to_string(v_sorted_ids, ',');
    WHEN 'org_admins' THEN
      IF p_target_organization_id IS NULL THEN RAISE EXCEPTION 'target_organization_id is required for target_type=org_admins' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_organization_id::TEXT;
    WHEN 'section', 'section_leadership' THEN
      IF p_target_section_id IS NULL THEN RAISE EXCEPTION 'target_section_id is required for target_type=%', p_target_type USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_section_id::TEXT;
    WHEN 'workflow_participants' THEN
      IF p_target_workflow_instance_id IS NULL THEN RAISE EXCEPTION 'target_workflow_instance_id is required for target_type=workflow_participants' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_workflow_instance_id::TEXT;
    WHEN 'work_item_assignee' THEN
      IF p_target_work_item_id IS NULL THEN RAISE EXCEPTION 'target_work_item_id is required for target_type=work_item_assignee' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_work_item_id::TEXT;
    ELSE
      RAISE EXCEPTION 'Unsupported target_type: %', p_target_type USING ERRCODE = '22023';
  END CASE;

  INSERT INTO notification_intents (
    outbox_event_id, organization_id, notification_type, title_template_key, template_params,
    source_module, source_record_type, source_record_id, priority,
    target_type, target_user_ids, target_organization_id, target_section_id,
    target_workflow_instance_id, target_work_item_id, target_key
  ) VALUES (
    p_outbox_event_id, v_event.organization_id, p_notification_type, p_title_template_key,
    COALESCE(p_template_params, '{}'::JSONB),
    v_event.source_module, v_event.source_record_type, v_event.source_record_id,
    COALESCE(p_priority, 'normal'),
    p_target_type,
    CASE WHEN p_target_type = 'specific_users' THEN v_sorted_ids ELSE NULL END,
    CASE WHEN p_target_type = 'org_admins' THEN p_target_organization_id ELSE NULL END,
    CASE WHEN p_target_type IN ('section','section_leadership') THEN p_target_section_id ELSE NULL END,
    CASE WHEN p_target_type = 'workflow_participants' THEN p_target_workflow_instance_id ELSE NULL END,
    CASE WHEN p_target_type = 'work_item_assignee' THEN p_target_work_item_id ELSE NULL END,
    v_target_key
  )
  ON CONFLICT (outbox_event_id, target_type, target_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT id INTO v_id FROM notification_intents
  WHERE outbox_event_id = p_outbox_event_id AND target_type = p_target_type AND target_key = v_target_key;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── resolve_notification_intent -- internal/service-only ──────────
-- The synchronous primitive a future Phase 1.3 worker will call, one
-- intent at a time -- NOT the worker itself. Deterministic: load,
-- validate state, resolve target descriptor to candidates,
-- revalidate current authorization per candidate against the closed
-- source-type dispatcher, deduplicate, create user_notifications
-- idempotently (reusing Phase 1.1's own platform_create_user_notification
-- primitive directly rather than duplicating its dedup logic), record
-- the outcome, return a bounded structural result. Never claims
-- delivery -- delivery is not a concept this function has any notion of.
CREATE OR REPLACE FUNCTION resolve_notification_intent(p_intent_id UUID)
RETURNS TABLE(status TEXT, resolved_count INTEGER, skipped_count INTEGER) AS $$
DECLARE
  v_intent RECORD;
  v_candidate UUID;
  v_candidates UUID[];
  v_resolved INTEGER := 0;
  v_skipped INTEGER := 0;
  v_authorized BOOLEAN;
  v_final_status TEXT;
BEGIN
  IF p_intent_id IS NULL THEN
    RAISE EXCEPTION 'intent_id is required' USING ERRCODE = '22023';
  END IF;

  -- Row lock: a concurrent resolver blocks here until the first one
  -- commits, then sees the already-recorded terminal status below and
  -- returns it as a safe idempotent no-op rather than re-resolving.
  SELECT * INTO v_intent FROM notification_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_id % does not reference an existing notification intent', p_intent_id USING ERRCODE = '22023';
  END IF;

  IF v_intent.status <> 'pending' THEN
    RETURN QUERY SELECT v_intent.status, v_intent.resolved_count, v_intent.skipped_count;
    RETURN;
  END IF;

  -- Target-descriptor resolution (docs/78 §7.2-§7.3): produces
  -- candidates only, never itself an authorization decision. Every
  -- one of these six branches reuses an existing, already-safe
  -- resolution helper/table rather than duplicating membership logic.
  CASE v_intent.target_type
    WHEN 'specific_users' THEN
      v_candidates := v_intent.target_user_ids;
    WHEN 'org_admins' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates FROM org_supervisor_user_ids(v_intent.target_organization_id) AS u;
    WHEN 'section' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates FROM section_user_ids(v_intent.target_section_id, NULL::TEXT[]) AS u;
    WHEN 'section_leadership' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates
        FROM section_user_ids(v_intent.target_section_id, ARRAY['mcs_admin','authority_admin','supervisor']) AS u;
    WHEN 'workflow_participants' THEN
      SELECT array_agg(DISTINCT p.user_id) INTO v_candidates
        FROM workflow_participants p WHERE p.instance_id = v_intent.target_workflow_instance_id AND p.ended_at IS NULL;
    WHEN 'work_item_assignee' THEN
      SELECT array_agg(DISTINCT w.assigned_to) INTO v_candidates
        FROM workflow_work_items w WHERE w.id = v_intent.target_work_item_id AND w.assigned_to IS NOT NULL;
  END CASE;

  IF v_candidates IS NOT NULL THEN
    FOREACH v_candidate IN ARRAY v_candidates LOOP
      IF v_candidate IS NULL THEN CONTINUE; END IF;

      -- Recipient existence/active-status check.
      IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_candidate AND is_active = TRUE) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Processing-time authorization revalidation (docs/78 §8) --
      -- late, against the SOURCE record's own authoritative model,
      -- never cached from enqueue time, never inferred from "same
      -- organization" or from notification metadata itself. Closed
      -- dispatcher: exactly the two source_record_type values allowed
      -- at intent-creation time are handled here; there is no
      -- fallthrough/default branch that could silently authorize an
      -- unrecognized source type.
      IF v_intent.source_record_type = 'workflow_instance' THEN
        v_authorized := intent_user_can_view_workflow_instance(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'platform' THEN
        -- No confidential source record exists to revalidate against
        -- -- active-user status (already checked above) is the whole
        -- authorization requirement for a platform-wide notice.
        v_authorized := TRUE;
      ELSE
        v_authorized := FALSE; -- structurally unreachable (create_notification_intent already rejects this), fails closed regardless.
      END IF;

      IF NOT v_authorized THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      PERFORM platform_create_user_notification(
        v_candidate, v_intent.organization_id, v_intent.notification_type, v_intent.title_template_key,
        v_intent.template_params, v_intent.source_module, v_intent.source_record_type, v_intent.source_record_id,
        v_intent.outbox_event_id, v_intent.priority, NULL, NULL, NULL
      );
      v_resolved := v_resolved + 1;
    END LOOP;
  END IF;

  v_final_status := CASE
    WHEN v_resolved > 0 AND v_skipped = 0 THEN 'resolved'
    WHEN v_resolved > 0 AND v_skipped > 0 THEN 'partially_resolved'
    ELSE 'failed'
  END;

  UPDATE notification_intents
  SET status = v_final_status, resolved_at = now(), resolved_count = v_resolved, skipped_count = v_skipped
  WHERE id = p_intent_id;

  RETURN QUERY SELECT v_final_status, v_resolved, v_skipped;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── Grants ──────────────────────────────────────────────────────────
REVOKE ALL ON TABLE notification_intents FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE notification_intents TO service_role;

REVOKE ALL ON FUNCTION intent_user_is_super_admin(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION intent_user_can_view_workflow_instance(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION notification_intents_enforce_immutability() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID) TO service_role;

REVOKE ALL ON FUNCTION resolve_notification_intent(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION resolve_notification_intent(UUID) TO service_role;

COMMIT;
