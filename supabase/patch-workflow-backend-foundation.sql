-- ============================================================
-- CAP-002 Phase 1: reusable Workflow backend foundation
--
-- Inert persistence and RPC boundary only. This patch deliberately
-- does not execute graphs, approvals, routing, timers, notifications,
-- escalations, adapters, or module mutations.
-- ============================================================

BEGIN;

-- ── Definition plane ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS workflow_definitions (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       UUID        REFERENCES organizations(id),
  definition_key        TEXT        NOT NULL,
  name                  TEXT        NOT NULL,
  subject_type          TEXT        NOT NULL,
  status                TEXT        NOT NULL DEFAULT 'draft'
                                    CHECK (status IN ('draft', 'active', 'retired')),
  active_version_id     UUID,
  lock_version          BIGINT      NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  created_by            UUID        NOT NULL REFERENCES users(id),
  updated_by            UUID        NOT NULL REFERENCES users(id),
  create_idempotency_key UUID       NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_definitions_key_check
    CHECK (definition_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_definitions_name_check CHECK (btrim(name) <> ''),
  CONSTRAINT workflow_definitions_subject_type_check
    CHECK (subject_type ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_definitions_creator_idempotency_unique
    UNIQUE (created_by, create_idempotency_key)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_definitions_scope_key
  ON workflow_definitions (COALESCE(organization_id, '00000000-0000-0000-0000-000000000000'::UUID), definition_key);
CREATE INDEX IF NOT EXISTS idx_workflow_definitions_org_status
  ON workflow_definitions (organization_id, status, definition_key);

DROP TRIGGER IF EXISTS set_updated_at ON workflow_definitions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_definitions
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TABLE IF NOT EXISTS workflow_definition_versions (
  id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id          UUID        NOT NULL REFERENCES workflow_definitions(id),
  version_number         INTEGER     NOT NULL CHECK (version_number > 0),
  status                 TEXT        NOT NULL DEFAULT 'draft'
                                     CHECK (status IN ('draft', 'published', 'retired')),
  capability_version     INTEGER     NOT NULL DEFAULT 1 CHECK (capability_version > 0),
  definition_payload     JSONB       NOT NULL,
  content_hash           TEXT        NOT NULL,
  created_by             UUID        NOT NULL REFERENCES users(id),
  create_idempotency_key UUID        NOT NULL,
  published_by           UUID        REFERENCES users(id),
  published_at           TIMESTAMPTZ,
  publish_idempotency_key UUID,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_definition_versions_number_unique UNIQUE (definition_id, version_number),
  CONSTRAINT workflow_definition_versions_id_definition_unique UNIQUE (id, definition_id),
  CONSTRAINT workflow_definition_versions_creator_idempotency_unique
    UNIQUE (created_by, create_idempotency_key),
  CONSTRAINT workflow_definition_versions_payload_check
    CHECK (jsonb_typeof(definition_payload) = 'object'),
  CONSTRAINT workflow_definition_versions_hash_check
    CHECK (content_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT workflow_definition_versions_publish_alignment_check CHECK (
    (status = 'draft' AND published_by IS NULL AND published_at IS NULL AND publish_idempotency_key IS NULL)
    OR
    (status IN ('published', 'retired') AND published_by IS NOT NULL AND published_at IS NOT NULL AND publish_idempotency_key IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_definition_versions_one_draft
  ON workflow_definition_versions (definition_id) WHERE status = 'draft';
CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_definition_versions_publish_idempotency
  ON workflow_definition_versions (published_by, publish_idempotency_key)
  WHERE publish_idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_workflow_definition_versions_lookup
  ON workflow_definition_versions (definition_id, version_number DESC);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'workflow_definitions_active_version_fkey'
  ) THEN
    ALTER TABLE workflow_definitions
      ADD CONSTRAINT workflow_definitions_active_version_fkey
      FOREIGN KEY (active_version_id, id)
      REFERENCES workflow_definition_versions(id, definition_id);
  END IF;
END $$;

-- ── Runtime plane ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS workflow_instances (
  id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id          UUID        NOT NULL REFERENCES workflow_definitions(id),
  definition_version_id  UUID        NOT NULL,
  subject_type           TEXT        NOT NULL,
  subject_id             UUID        NOT NULL,
  home_organization_id   UUID        NOT NULL REFERENCES organizations(id),
  participant_organization_ids UUID[] NOT NULL,
  status                 TEXT        NOT NULL DEFAULT 'pending' CHECK (status IN (
                           'pending', 'active', 'suspended', 'completed',
                           'rejected', 'cancelled', 'withdrawn', 'failed'
                         )),
  terminal_outcome       TEXT,
  execution_epoch        INTEGER     NOT NULL DEFAULT 1 CHECK (execution_epoch > 0),
  lock_version           BIGINT      NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  next_event_sequence    BIGINT      NOT NULL DEFAULT 2 CHECK (next_event_sequence > 0),
  correlation_id         UUID        NOT NULL,
  created_by             UUID        NOT NULL REFERENCES users(id),
  create_idempotency_key UUID        NOT NULL,
  started_at             TIMESTAMPTZ,
  ended_at               TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_instances_version_definition_fkey
    FOREIGN KEY (definition_version_id, definition_id)
    REFERENCES workflow_definition_versions(id, definition_id),
  CONSTRAINT workflow_instances_creator_idempotency_unique
    UNIQUE (created_by, create_idempotency_key),
  CONSTRAINT workflow_instances_subject_type_check
    CHECK (subject_type ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_instances_home_participant_check
    CHECK (home_organization_id = ANY(participant_organization_ids)),
  CONSTRAINT workflow_instances_participant_orgs_nonempty_check
    CHECK (cardinality(participant_organization_ids) > 0),
  CONSTRAINT workflow_instances_terminal_alignment_check CHECK (
    (status IN ('completed', 'rejected', 'cancelled', 'withdrawn') AND terminal_outcome IS NOT NULL AND ended_at IS NOT NULL)
    OR
    (status NOT IN ('completed', 'rejected', 'cancelled', 'withdrawn') AND terminal_outcome IS NULL AND ended_at IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_instances_one_active_subject
  ON workflow_instances (definition_id, subject_type, subject_id)
  WHERE status IN ('pending', 'active', 'suspended', 'failed');
CREATE INDEX IF NOT EXISTS idx_workflow_instances_subject
  ON workflow_instances (subject_type, subject_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_instances_org_status
  ON workflow_instances (home_organization_id, status, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_instances_definition_version
  ON workflow_instances (definition_version_id, created_at DESC, id DESC);

DROP TRIGGER IF EXISTS set_updated_at ON workflow_instances;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_instances
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TABLE IF NOT EXISTS workflow_instance_steps (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id        UUID        NOT NULL REFERENCES workflow_instances(id),
  definition_node_key TEXT       NOT NULL,
  run_number         INTEGER     NOT NULL DEFAULT 1 CHECK (run_number > 0),
  state              TEXT        NOT NULL DEFAULT 'pending' CHECK (state IN (
                       'pending', 'ready', 'active', 'waiting', 'completed',
                       'skipped', 'cancelled', 'expired', 'failed'
                     )),
  result_code        TEXT,
  retry_count        INTEGER     NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  activated_at       TIMESTAMPTZ,
  ended_at           TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_instance_steps_node_key_check
    CHECK (definition_node_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_instance_steps_run_unique
    UNIQUE (instance_id, definition_node_key, run_number)
);

CREATE INDEX IF NOT EXISTS idx_workflow_instance_steps_current
  ON workflow_instance_steps (instance_id, state, created_at, id)
  WHERE state IN ('pending', 'ready', 'active', 'waiting', 'failed');

DROP TRIGGER IF EXISTS set_updated_at ON workflow_instance_steps;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_instance_steps
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TABLE IF NOT EXISTS workflow_tokens (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id    UUID        NOT NULL REFERENCES workflow_instances(id),
  step_id        UUID        REFERENCES workflow_instance_steps(id),
  token_key      TEXT        NOT NULL,
  state          TEXT        NOT NULL DEFAULT 'active'
                             CHECK (state IN ('active', 'waiting', 'consumed', 'cancelled', 'failed')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  consumed_at    TIMESTAMPTZ,
  CONSTRAINT workflow_tokens_key_check CHECK (token_key ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_tokens_key_unique UNIQUE (instance_id, token_key),
  CONSTRAINT workflow_tokens_consumed_alignment_check CHECK (
    (state = 'consumed' AND consumed_at IS NOT NULL)
    OR (state <> 'consumed' AND consumed_at IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_workflow_tokens_active
  ON workflow_tokens (instance_id, state, created_at, id)
  WHERE state IN ('active', 'waiting', 'failed');

CREATE TABLE IF NOT EXISTS workflow_work_items (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id         UUID        NOT NULL REFERENCES workflow_instances(id),
  step_id             UUID        REFERENCES workflow_instance_steps(id),
  token_id            UUID        REFERENCES workflow_tokens(id),
  work_item_type      TEXT        NOT NULL CHECK (work_item_type IN (
                        'activity', 'approval', 'routing', 'acknowledgement', 'exception'
                      )),
  state               TEXT        NOT NULL DEFAULT 'offered' CHECK (state IN (
                        'offered', 'claimed', 'completed', 'cancelled', 'expired', 'failed'
                      )),
  organization_id     UUID        NOT NULL REFERENCES organizations(id),
  section_id          UUID        REFERENCES sections(id),
  assigned_to         UUID        REFERENCES users(id),
  claimed_by          UUID        REFERENCES users(id),
  completed_by        UUID        REFERENCES users(id),
  priority            SMALLINT    NOT NULL DEFAULT 0 CHECK (priority BETWEEN -100 AND 100),
  due_at              TIMESTAMPTZ,
  lock_version        BIGINT      NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  offered_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  claimed_at          TIMESTAMPTZ,
  completed_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_work_items_claim_alignment_check CHECK (
    (state = 'claimed' AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL)
    OR state <> 'claimed'
  ),
  CONSTRAINT workflow_work_items_complete_alignment_check CHECK (
    (state = 'completed' AND completed_by IS NOT NULL AND completed_at IS NOT NULL)
    OR state <> 'completed'
  )
);

DROP INDEX IF EXISTS idx_workflow_work_items_assignee_queue;
CREATE INDEX idx_workflow_work_items_assignee_queue
  ON workflow_work_items (assigned_to, created_at DESC, id DESC)
  INCLUDE (instance_id, work_item_type, state, priority, due_at)
  WHERE state IN ('offered', 'claimed', 'failed');
DROP INDEX IF EXISTS idx_workflow_work_items_org_queue;
CREATE INDEX idx_workflow_work_items_org_queue
  ON workflow_work_items (organization_id, created_at DESC, id DESC)
  INCLUDE (instance_id, work_item_type, state, priority, due_at)
  WHERE state IN ('offered', 'claimed', 'failed');
CREATE INDEX IF NOT EXISTS idx_workflow_work_items_instance
  ON workflow_work_items (instance_id, state, created_at, id);
CREATE INDEX IF NOT EXISTS idx_workflow_work_items_due
  ON workflow_work_items (due_at, id)
  WHERE due_at IS NOT NULL AND state IN ('offered', 'claimed');

DROP TRIGGER IF EXISTS set_updated_at ON workflow_work_items;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_work_items
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TABLE IF NOT EXISTS workflow_participants (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id           UUID        NOT NULL REFERENCES workflow_instances(id),
  work_item_id          UUID        REFERENCES workflow_work_items(id),
  user_id               UUID        NOT NULL REFERENCES users(id),
  participant_role      TEXT        NOT NULL CHECK (participant_role IN (
                          'owner', 'manager', 'candidate', 'assignee', 'viewer'
                        )),
  authority_source      TEXT        NOT NULL,
  joined_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at              TIMESTAMPTZ,
  created_by            UUID        NOT NULL REFERENCES users(id),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_participants_authority_check CHECK (btrim(authority_source) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_participants_active_unique
  ON workflow_participants (
    instance_id,
    COALESCE(work_item_id, '00000000-0000-0000-0000-000000000000'::UUID),
    user_id,
    participant_role
  ) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workflow_participants_user_active
  ON workflow_participants (user_id, instance_id, work_item_id, participant_role)
  WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workflow_participants_instance
  ON workflow_participants (instance_id, created_at, id);

CREATE TABLE IF NOT EXISTS workflow_decisions (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id      UUID        NOT NULL REFERENCES workflow_instances(id),
  step_id          UUID        NOT NULL REFERENCES workflow_instance_steps(id),
  work_item_id     UUID        NOT NULL REFERENCES workflow_work_items(id),
  decision_code    TEXT        NOT NULL,
  actor_id         UUID        NOT NULL REFERENCES users(id),
  authority_source TEXT        NOT NULL,
  comment          TEXT,
  command_id       UUID        NOT NULL,
  decided_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_decisions_code_check
    CHECK (decision_code ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_decisions_authority_check CHECK (btrim(authority_source) <> ''),
  CONSTRAINT workflow_decisions_command_unique UNIQUE (instance_id, command_id)
);

CREATE INDEX IF NOT EXISTS idx_workflow_decisions_instance
  ON workflow_decisions (instance_id, decided_at, id);
CREATE INDEX IF NOT EXISTS idx_workflow_decisions_work_item
  ON workflow_decisions (work_item_id, decided_at, id);

CREATE TABLE IF NOT EXISTS workflow_variables (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id    UUID        NOT NULL REFERENCES workflow_instances(id),
  variable_name  TEXT        NOT NULL,
  value_type     TEXT        NOT NULL CHECK (value_type IN (
                   'null', 'boolean', 'number', 'string', 'date', 'timestamp', 'uuid', 'json'
                 )),
  variable_value JSONB       NOT NULL,
  classification TEXT        NOT NULL DEFAULT 'restricted'
                             CHECK (classification IN ('public', 'restricted')),
  created_by     UUID        NOT NULL REFERENCES users(id),
  updated_by     UUID        NOT NULL REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_variables_name_check
    CHECK (variable_name ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_variables_name_unique UNIQUE (instance_id, variable_name)
);

CREATE INDEX IF NOT EXISTS idx_workflow_variables_instance
  ON workflow_variables (instance_id, variable_name);

DROP TRIGGER IF EXISTS set_updated_at ON workflow_variables;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON workflow_variables
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TABLE IF NOT EXISTS workflow_events (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id     UUID        NOT NULL REFERENCES workflow_instances(id),
  event_sequence  BIGINT      NOT NULL CHECK (event_sequence > 0),
  event_type      TEXT        NOT NULL,
  actor_id        UUID        REFERENCES users(id),
  step_id         UUID        REFERENCES workflow_instance_steps(id),
  work_item_id    UUID        REFERENCES workflow_work_items(id),
  correlation_id  UUID        NOT NULL,
  causation_id    UUID,
  idempotency_key UUID        NOT NULL,
  metadata        JSONB       NOT NULL DEFAULT '{}'::JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT workflow_events_type_check CHECK (event_type ~ '^[a-z][a-z0-9_]{0,62}$'),
  CONSTRAINT workflow_events_metadata_check CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT workflow_events_sequence_unique UNIQUE (instance_id, event_sequence),
  CONSTRAINT workflow_events_idempotency_unique UNIQUE (instance_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_workflow_events_instance_sequence
  ON workflow_events (instance_id, event_sequence DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_events_correlation
  ON workflow_events (correlation_id, created_at, id);
CREATE INDEX IF NOT EXISTS idx_workflow_events_created_brin
  ON workflow_events USING BRIN (created_at);

-- ── Immutability guards ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION workflow_reject_immutable_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_decisions_immutable ON workflow_decisions;
CREATE TRIGGER workflow_decisions_immutable
  BEFORE UPDATE OR DELETE ON workflow_decisions
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_immutable_mutation();

DROP TRIGGER IF EXISTS workflow_events_immutable ON workflow_events;
CREATE TRIGGER workflow_events_immutable
  BEFORE UPDATE OR DELETE ON workflow_events
  FOR EACH ROW EXECUTE FUNCTION workflow_reject_immutable_mutation();

CREATE OR REPLACE FUNCTION workflow_guard_definition_version_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Workflow definition versions cannot be deleted' USING ERRCODE = '55000';
  END IF;

  IF OLD.definition_id IS DISTINCT FROM NEW.definition_id
     OR OLD.version_number IS DISTINCT FROM NEW.version_number
     OR OLD.capability_version IS DISTINCT FROM NEW.capability_version
     OR OLD.definition_payload IS DISTINCT FROM NEW.definition_payload
     OR OLD.content_hash IS DISTINCT FROM NEW.content_hash
     OR OLD.created_by IS DISTINCT FROM NEW.created_by
     OR OLD.create_idempotency_key IS DISTINCT FROM NEW.create_idempotency_key
     OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'Workflow definition version content is immutable' USING ERRCODE = '55000';
  END IF;

  IF NOT (
    (OLD.status = 'draft' AND NEW.status = 'published')
    OR (OLD.status = 'published' AND NEW.status = 'retired')
    OR OLD.status = NEW.status
  ) THEN
    RAISE EXCEPTION 'Invalid workflow definition version transition: % -> %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS workflow_definition_versions_immutable ON workflow_definition_versions;
CREATE TRIGGER workflow_definition_versions_immutable
  BEFORE UPDATE OR DELETE ON workflow_definition_versions
  FOR EACH ROW EXECUTE FUNCTION workflow_guard_definition_version_mutation();

-- ── Authorization helpers ───────────────────────────────────────

CREATE OR REPLACE FUNCTION workflow_actor_is_active()
RETURNS BOOLEAN AS $$
  SELECT auth.uid() IS NOT NULL
    AND EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.is_active = TRUE);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION can_manage_workflow_definition(p_definition_id UUID)
RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM workflow_definitions d
      WHERE d.id = p_definition_id
        AND d.organization_id = get_my_org_id()
        AND is_admin()
    )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION can_view_workflow_instance(p_instance_id UUID)
RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM workflow_participants p
      WHERE p.instance_id = p_instance_id
        AND p.user_id = auth.uid()
        AND p.ended_at IS NULL
    )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION can_manage_workflow_instance(p_instance_id UUID)
RETURNS BOOLEAN AS $$
  SELECT workflow_actor_is_active() AND (
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM workflow_participants p
      WHERE p.instance_id = p_instance_id
        AND p.user_id = auth.uid()
        AND p.participant_role IN ('owner', 'manager')
        AND p.ended_at IS NULL
    )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ── RLS: SELECT only; every mutation is RPC-owned ──────────────

ALTER TABLE workflow_definitions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_definition_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_instances            ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_instance_steps       ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_tokens               ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_work_items           ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_participants         ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_decisions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_variables            ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_events               ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS workflow_definitions_select ON workflow_definitions;
CREATE POLICY workflow_definitions_select ON workflow_definitions
  FOR SELECT TO authenticated
  USING (can_manage_workflow_definition(id));

DROP POLICY IF EXISTS workflow_definition_versions_select ON workflow_definition_versions;
CREATE POLICY workflow_definition_versions_select ON workflow_definition_versions
  FOR SELECT TO authenticated
  USING (can_manage_workflow_definition(definition_id));

DROP POLICY IF EXISTS workflow_instances_select ON workflow_instances;
CREATE POLICY workflow_instances_select ON workflow_instances
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(id));

DROP POLICY IF EXISTS workflow_instance_steps_select ON workflow_instance_steps;
CREATE POLICY workflow_instance_steps_select ON workflow_instance_steps
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_tokens_select ON workflow_tokens;
CREATE POLICY workflow_tokens_select ON workflow_tokens
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_work_items_select ON workflow_work_items;
CREATE POLICY workflow_work_items_select ON workflow_work_items
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_participants_select ON workflow_participants;
CREATE POLICY workflow_participants_select ON workflow_participants
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_decisions_select ON workflow_decisions;
CREATE POLICY workflow_decisions_select ON workflow_decisions
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_variables_select ON workflow_variables;
CREATE POLICY workflow_variables_select ON workflow_variables
  FOR SELECT TO authenticated
  USING (can_manage_workflow_instance(instance_id));

DROP POLICY IF EXISTS workflow_events_select ON workflow_events;
CREATE POLICY workflow_events_select ON workflow_events
  FOR SELECT TO authenticated
  USING (can_view_workflow_instance(instance_id));

-- ── Generic definition and instance RPC foundation ─────────────

CREATE OR REPLACE FUNCTION create_workflow_definition(
  p_organization_id UUID,
  p_definition_key TEXT,
  p_name TEXT,
  p_subject_type TEXT,
  p_definition_payload JSONB,
  p_idempotency_key UUID
) RETURNS TABLE (definition_id UUID, version_id UUID, version_number INTEGER) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_existing workflow_definitions;
  v_definition_id UUID;
  v_version_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow definition creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'An idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_organization_id IS NULL THEN
    IF NOT is_super_admin() THEN
      RAISE EXCEPTION 'Only a super administrator may create a platform workflow definition' USING ERRCODE = '42501';
    END IF;
  ELSIF p_organization_id <> get_my_org_id() OR NOT is_admin() THEN
    RAISE EXCEPTION 'Not authorized to create a workflow definition for this organization' USING ERRCODE = '42501';
  END IF;
  IF p_definition_key IS NULL OR p_definition_key !~ '^[a-z][a-z0-9_]{0,62}$'
     OR p_subject_type IS NULL OR p_subject_type !~ '^[a-z][a-z0-9_]{0,62}$'
     OR p_name IS NULL OR btrim(p_name) = ''
     OR p_definition_payload IS NULL OR jsonb_typeof(p_definition_payload) <> 'object'
     OR octet_length(p_definition_payload::TEXT) > 1048576 THEN
    RAISE EXCEPTION 'Invalid workflow definition input' USING ERRCODE = '22023';
  END IF;

  -- Serialize retries for one caller/key before consulting the idempotency row.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('workflow_definition_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing
  FROM workflow_definitions
  WHERE created_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.organization_id IS DISTINCT FROM p_organization_id
       OR v_existing.definition_key <> p_definition_key
       OR v_existing.name <> btrim(p_name)
       OR v_existing.subject_type <> p_subject_type
       OR NOT EXISTS (
         SELECT 1 FROM workflow_definition_versions v
         WHERE v.definition_id = v_existing.id
           AND v.version_number = 1
           AND v.definition_payload = p_definition_payload
       ) THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT v_existing.id, v.id, v.version_number
      FROM workflow_definition_versions v
      WHERE v.definition_id = v_existing.id AND v.version_number = 1;
    RETURN;
  END IF;

  INSERT INTO workflow_definitions (
    organization_id, definition_key, name, subject_type,
    created_by, updated_by, create_idempotency_key
  ) VALUES (
    p_organization_id, p_definition_key, btrim(p_name), p_subject_type,
    v_actor, v_actor, p_idempotency_key
  ) RETURNING id INTO v_definition_id;

  INSERT INTO workflow_definition_versions (
    definition_id, version_number, definition_payload, content_hash,
    created_by, create_idempotency_key
  ) VALUES (
    v_definition_id, 1, p_definition_payload,
    encode(digest(convert_to(p_definition_payload::TEXT, 'UTF8'), 'sha256'), 'hex'),
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_version_id;

  RETURN QUERY SELECT v_definition_id, v_version_id, 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION create_workflow_definition_version(
  p_definition_id UUID,
  p_definition_payload JSONB,
  p_idempotency_key UUID
) RETURNS TABLE (version_id UUID, version_number INTEGER) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_definition workflow_definitions;
  v_existing workflow_definition_versions;
  v_number INTEGER;
  v_id UUID;
BEGIN
  IF NOT workflow_actor_is_active() OR NOT can_manage_workflow_definition(p_definition_id) THEN
    RAISE EXCEPTION 'Not authorized to version this workflow definition' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_definition_payload IS NULL
     OR jsonb_typeof(p_definition_payload) <> 'object'
     OR octet_length(p_definition_payload::TEXT) > 1048576 THEN
    RAISE EXCEPTION 'Invalid workflow definition version input' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('workflow_definition_version:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing
  FROM workflow_definition_versions
  WHERE created_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.definition_id <> p_definition_id
       OR v_existing.definition_payload <> p_definition_payload THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.version_number;
    RETURN;
  END IF;

  SELECT * INTO v_definition FROM workflow_definitions
  WHERE id = p_definition_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Workflow definition not found' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (
    SELECT 1 FROM workflow_definition_versions
    WHERE definition_id = p_definition_id AND status = 'draft'
  ) THEN
    RAISE EXCEPTION 'This workflow definition already has a draft version' USING ERRCODE = '55000';
  END IF;

  SELECT COALESCE(MAX(v.version_number), 0) + 1 INTO v_number
  FROM workflow_definition_versions v WHERE v.definition_id = p_definition_id;

  INSERT INTO workflow_definition_versions (
    definition_id, version_number, definition_payload, content_hash,
    created_by, create_idempotency_key
  ) VALUES (
    p_definition_id, v_number, p_definition_payload,
    encode(digest(convert_to(p_definition_payload::TEXT, 'UTF8'), 'sha256'), 'hex'),
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id, v_number;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION publish_workflow_definition_version(
  p_version_id UUID,
  p_expected_definition_lock_version BIGINT,
  p_idempotency_key UUID
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_version workflow_definition_versions;
  v_definition workflow_definitions;
BEGIN
  IF NOT workflow_actor_is_active() OR p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Publishing requires an active authenticated caller and idempotency key' USING ERRCODE = '42501';
  END IF;

  SELECT d.* INTO v_definition
  FROM workflow_definitions d
  JOIN workflow_definition_versions v ON v.definition_id = d.id
  WHERE v.id = p_version_id
  FOR UPDATE OF d;
  IF NOT FOUND OR NOT can_manage_workflow_definition(v_definition.id) THEN
    RAISE EXCEPTION 'Workflow definition version not found or not manageable' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_version FROM workflow_definition_versions
  WHERE id = p_version_id FOR UPDATE;

  IF v_version.status = 'published'
     AND v_version.publish_idempotency_key = p_idempotency_key
     AND v_version.published_by = v_actor THEN
    RETURN v_version.id;
  END IF;
  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'Only a draft workflow definition version may be published' USING ERRCODE = '55000';
  END IF;
  IF v_definition.lock_version <> p_expected_definition_lock_version THEN
    RAISE EXCEPTION 'Workflow definition changed concurrently' USING ERRCODE = '40001';
  END IF;

  -- Phase 1 definitions are intentionally inert. Later graph validation
  -- and runtime phases will replace this boundary under separate approval.
  IF jsonb_typeof(v_version.definition_payload -> 'nodes') <> 'array'
     OR jsonb_typeof(v_version.definition_payload -> 'edges') <> 'array'
     OR jsonb_array_length(v_version.definition_payload -> 'nodes') <> 0
     OR jsonb_array_length(v_version.definition_payload -> 'edges') <> 0 THEN
    RAISE EXCEPTION 'Phase 1 may publish only an inert workflow definition' USING ERRCODE = '0A000';
  END IF;

  UPDATE workflow_definition_versions
  SET status = 'retired'
  WHERE definition_id = v_definition.id AND status = 'published';

  UPDATE workflow_definition_versions
  SET status = 'published', published_by = v_actor, published_at = NOW(),
      publish_idempotency_key = p_idempotency_key
  WHERE id = p_version_id;

  UPDATE workflow_definitions
  SET status = 'active', active_version_id = p_version_id,
      updated_by = v_actor, lock_version = lock_version + 1
  WHERE id = v_definition.id;

  RETURN p_version_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION create_workflow_instance(
  p_definition_version_id UUID,
  p_subject_type TEXT,
  p_subject_id UUID,
  p_home_organization_id UUID,
  p_idempotency_key UUID,
  p_correlation_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_definition workflow_definitions;
  v_version workflow_definition_versions;
  v_existing workflow_instances;
  v_instance_id UUID;
  v_correlation UUID := COALESCE(p_correlation_id, gen_random_uuid());
BEGIN
  IF NOT workflow_actor_is_active() THEN
    RAISE EXCEPTION 'Workflow instance creation requires an active authenticated caller' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_subject_id IS NULL OR p_home_organization_id IS NULL THEN
    RAISE EXCEPTION 'Subject, organization, and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  -- Idempotency is caller-scoped. The subject lock separately serializes
  -- competing commands that try to create the one active aggregate.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('workflow_instance_create:' || v_actor::TEXT || ':' || p_idempotency_key::TEXT, 0)
  );

  SELECT * INTO v_existing FROM workflow_instances
  WHERE created_by = v_actor AND create_idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.definition_version_id <> p_definition_version_id
       OR v_existing.subject_type <> p_subject_type
       OR v_existing.subject_id <> p_subject_id
       OR v_existing.home_organization_id <> p_home_organization_id
       OR (p_correlation_id IS NOT NULL AND v_existing.correlation_id <> p_correlation_id) THEN
      RAISE EXCEPTION 'Idempotency key was already used with different input' USING ERRCODE = '22023';
    END IF;
    RETURN v_existing.id;
  END IF;

  SELECT * INTO v_version
  FROM workflow_definition_versions
  WHERE id = p_definition_version_id;
  IF FOUND THEN
    SELECT * INTO v_definition
    FROM workflow_definitions
    WHERE id = v_version.definition_id;
  END IF;
  IF NOT FOUND OR v_version.status <> 'published'
     OR v_definition.active_version_id <> p_definition_version_id
     OR v_definition.status <> 'active' THEN
    RAISE EXCEPTION 'An active published workflow definition version is required' USING ERRCODE = '55000';
  END IF;
  IF p_subject_type <> v_definition.subject_type THEN
    RAISE EXCEPTION 'Workflow subject type does not match its definition' USING ERRCODE = '22023';
  END IF;
  IF p_home_organization_id <> get_my_org_id() OR NOT is_admin() THEN
    RAISE EXCEPTION 'Only an administrator of the home organization may create a Phase 1 instance' USING ERRCODE = '42501';
  END IF;
  IF v_definition.organization_id IS NOT NULL
     AND v_definition.organization_id <> p_home_organization_id THEN
    RAISE EXCEPTION 'Workflow definition is not available to this organization' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'workflow_active_subject:' || v_definition.id::TEXT || ':' ||
      p_subject_type || ':' || p_subject_id::TEXT,
      0
    )
  );

  INSERT INTO workflow_instances (
    definition_id, definition_version_id, subject_type, subject_id,
    home_organization_id, participant_organization_ids, correlation_id,
    created_by, create_idempotency_key
  ) VALUES (
    v_definition.id, v_version.id, p_subject_type, p_subject_id,
    p_home_organization_id, ARRAY[p_home_organization_id], v_correlation,
    v_actor, p_idempotency_key
  ) RETURNING id INTO v_instance_id;

  INSERT INTO workflow_participants (
    instance_id, user_id, participant_role, authority_source, created_by
  ) VALUES (
    v_instance_id, v_actor, 'owner', 'phase1_definition_administrator', v_actor
  );

  INSERT INTO workflow_events (
    instance_id, event_sequence, event_type, actor_id,
    correlation_id, idempotency_key, metadata
  ) VALUES (
    v_instance_id, 1, 'instance_created', v_actor,
    v_correlation, p_idempotency_key, '{}'::JSONB
  );

  RETURN v_instance_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION get_workflow_instance(p_instance_id UUID)
RETURNS TABLE (
  instance_id UUID,
  definition_id UUID,
  definition_version_id UUID,
  definition_key TEXT,
  definition_version INTEGER,
  subject_type TEXT,
  subject_id UUID,
  home_organization_id UUID,
  status TEXT,
  terminal_outcome TEXT,
  execution_epoch INTEGER,
  lock_version BIGINT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
  SELECT i.id, i.definition_id, i.definition_version_id,
         d.definition_key, v.version_number,
         i.subject_type, i.subject_id, i.home_organization_id,
         i.status, i.terminal_outcome, i.execution_epoch, i.lock_version,
         i.created_at, i.updated_at
  FROM workflow_instances i
  JOIN workflow_definitions d ON d.id = i.definition_id
  JOIN workflow_definition_versions v ON v.id = i.definition_version_id
  WHERE i.id = p_instance_id AND can_view_workflow_instance(i.id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_workflow_work_items(
  p_limit INTEGER DEFAULT 50,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL
) RETURNS TABLE (
  work_item_id UUID,
  instance_id UUID,
  work_item_type TEXT,
  state TEXT,
  priority SMALLINT,
  due_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
) AS $$
  SELECT w.id, w.instance_id, w.work_item_type, w.state,
         w.priority, w.due_at, w.created_at
  FROM workflow_work_items w
  WHERE workflow_actor_is_active()
    AND w.state IN ('offered', 'claimed', 'failed')
    AND (
      w.assigned_to = auth.uid()
      OR EXISTS (
        SELECT 1 FROM workflow_participants p
        WHERE p.instance_id = w.instance_id
          AND p.work_item_id = w.id
          AND p.user_id = auth.uid()
          AND p.participant_role IN ('candidate', 'assignee')
          AND p.ended_at IS NULL
      )
    )
    AND (
      p_before_created_at IS NULL
      OR (p_before_id IS NOT NULL AND (w.created_at, w.id) < (p_before_created_at, p_before_id))
    )
  ORDER BY w.created_at DESC, w.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ── Grants ──────────────────────────────────────────────────────

REVOKE ALL ON TABLE
  workflow_definitions, workflow_definition_versions, workflow_instances,
  workflow_instance_steps, workflow_tokens, workflow_work_items,
  workflow_participants, workflow_decisions, workflow_variables, workflow_events
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE
  workflow_definitions, workflow_definition_versions, workflow_instances,
  workflow_instance_steps, workflow_tokens, workflow_work_items,
  workflow_participants, workflow_decisions, workflow_variables, workflow_events
TO authenticated;

REVOKE ALL ON FUNCTION workflow_actor_is_active() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION workflow_reject_immutable_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION workflow_guard_definition_version_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION can_manage_workflow_definition(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION can_view_workflow_instance(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION can_manage_workflow_instance(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION create_workflow_definition(UUID, TEXT, TEXT, TEXT, JSONB, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION create_workflow_definition_version(UUID, JSONB, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION publish_workflow_definition_version(UUID, BIGINT, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION create_workflow_instance(UUID, TEXT, UUID, UUID, UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION get_workflow_instance(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION list_workflow_work_items(INTEGER, TIMESTAMPTZ, UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION workflow_actor_is_active() TO authenticated;
GRANT EXECUTE ON FUNCTION can_manage_workflow_definition(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION can_view_workflow_instance(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION can_manage_workflow_instance(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_workflow_definition(UUID, TEXT, TEXT, TEXT, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_workflow_definition_version(UUID, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION publish_workflow_definition_version(UUID, BIGINT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_workflow_instance(UUID, TEXT, UUID, UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_workflow_instance(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION list_workflow_work_items(INTEGER, TIMESTAMPTZ, UUID) TO authenticated;

COMMIT;
