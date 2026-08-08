-- ============================================================
-- CAP-003 Phase 1.1 -- Transactional Outbox + Durable Notification
-- Persistence Foundation.
--
-- Implements ONLY the inert persistence foundation defined by
-- docs/78-notification-outbox-architecture.md §25's Phase 1.1 scope:
-- the platform_outbox_events table, the user_notifications table, an
-- admin-managed event-type registry, immutability triggers separating
-- business-fact columns from mutable processing/state columns, strict
-- RLS, two internal/service-only SECURITY DEFINER creation primitives,
-- and two authenticated-facing read APIs (keyset-paginated list,
-- unread count). No worker, no recipient resolution, no module
-- integration, no legacy cutover -- all deliberately deferred to later
-- CAP-003 phases per docs/78 §25/§26. The legacy `notifications` table
-- (docs/79, docs/80) is completely untouched: this is purely additive.
--
-- Modeled directly on workflow_events' proven open-event-type shape
-- (docs/78 §2.5/§5.1), never on notifications/audit_logs' closed-enum
-- anti-pattern (docs/78 §2.1).
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── Event-type registry ────────────────────────────────────────────
-- Admin-managed reference data (docs/78 §5.4): per event_type, the
-- owning module, whether it is mandatory (future preference-layer
-- enforcement point, §11) and whether it requires acknowledgement
-- (§10). Configuration data, not itself part of the runtime hot path.
-- No event types are seeded here -- registering real business event
-- types is each future module integration's own concern (§25 Phase
-- 1.4), not this foundation patch's.
CREATE TABLE IF NOT EXISTS platform_event_type_registry (
  event_type               TEXT        PRIMARY KEY
                              CHECK (event_type ~ '^[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+\.v[1-9][0-9]*$'),
  owning_module             TEXT        NOT NULL,
  is_mandatory               BOOLEAN     NOT NULL DEFAULT TRUE,
  requires_acknowledgement   BOOLEAN     NOT NULL DEFAULT FALSE,
  description                TEXT,
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Transactional outbox ───────────────────────────────────────────
-- One shared, platform-owned table for all modules (docs/78 §5.1).
-- IMMUTABLE EVENT EVIDENCE: event_type, source_*, organization_id,
-- actor_id, correlation_id, causation_id, occurred_at, created_at,
-- payload, idempotency_key -- write-once at enqueue time.
-- MUTABLE PROCESSING STATE: status, claimed_by, claimed_at,
-- attempt_count, next_attempt_at, last_error, processed_at -- owned by
-- a future worker (§25 Phase 1.3), not touched by anything in this
-- patch, but the columns and their separation from evidence exist now
-- so that later phase needs no schema migration of its own.
CREATE TABLE IF NOT EXISTS platform_outbox_events (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type          TEXT        NOT NULL
                         CHECK (event_type ~ '^[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+\.v[1-9][0-9]*$'),
  source_module       TEXT        NOT NULL,
  source_record_type  TEXT        NOT NULL,
  source_record_id    UUID        NOT NULL,
  organization_id     UUID        NOT NULL REFERENCES organizations(id),
  actor_id            UUID        REFERENCES users(id),
  correlation_id      UUID        NOT NULL,
  causation_id        UUID,
  occurred_at         TIMESTAMPTZ NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  payload             JSONB       NOT NULL DEFAULT '{}'::JSONB,
  status              TEXT        NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending','claimed','processing','completed','failed','dead_letter')),
  claimed_by          TEXT,
  claimed_at          TIMESTAMPTZ,
  attempt_count       INTEGER     NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at     TIMESTAMPTZ,
  last_error          TEXT,
  processed_at        TIMESTAMPTZ,
  idempotency_key     UUID        NOT NULL,
  CONSTRAINT platform_outbox_events_payload_object CHECK (jsonb_typeof(payload) = 'object'),
  -- Bounded payload (docs/78 §5.3): safe display strings/references/
  -- identifiers only, never confidential business content -- 8KB is
  -- generous headroom for that shape while still refusing an
  -- accidental full-document dump.
  CONSTRAINT platform_outbox_events_payload_bounded CHECK (pg_column_size(payload) <= 8192),
  -- Enqueue-level idempotency (docs/78 §5.6): a retried domain
  -- transaction never produces a duplicate outbox event for the same
  -- logical fact.
  CONSTRAINT platform_outbox_events_idempotency_unique
    UNIQUE (source_module, source_record_type, source_record_id, event_type, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_platform_outbox_events_pending
  ON platform_outbox_events (next_attempt_at)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_platform_outbox_events_org_created
  ON platform_outbox_events (organization_id, created_at);
CREATE INDEX IF NOT EXISTS idx_platform_outbox_events_created_brin
  ON platform_outbox_events USING BRIN (created_at);

-- ─── Durable user notifications ─────────────────────────────────────
-- The record a user actually sees (docs/78 §9), distinct from the
-- outbox event that produced it. IMMUTABLE: recipient_user_id,
-- organization_id, notification_type, title_template_key,
-- template_params, source_*, outbox_event_id, priority,
-- deep_link_module, deep_link_params, created_at, expires_at.
-- MUTABLE (owning recipient only, via RLS): read_at, acknowledged_at,
-- archived_at (docs/78 §10).
CREATE TABLE IF NOT EXISTS user_notifications (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_user_id   UUID        NOT NULL REFERENCES users(id),
  organization_id     UUID        NOT NULL REFERENCES organizations(id),
  notification_type   TEXT        NOT NULL
                         CHECK (notification_type ~ '^[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+\.v[1-9][0-9]*$'),
  title_template_key  TEXT        NOT NULL,
  template_params     JSONB       NOT NULL DEFAULT '{}'::JSONB,
  source_module       TEXT        NOT NULL,
  source_record_type  TEXT        NOT NULL,
  source_record_id    UUID        NOT NULL,
  -- Traceability back to the outbox event that produced this row
  -- (docs/78 §9) -- also the notification-level idempotency boundary
  -- (§14): a worker that claims/replays the same event never creates
  -- a second notification for the same recipient.
  outbox_event_id     UUID        NOT NULL REFERENCES platform_outbox_events(id),
  priority             TEXT        NOT NULL DEFAULT 'normal'
                         CHECK (priority IN ('low','normal','high','urgent')),
  -- A module+params reference the frontend resolves into a route at
  -- render time -- never a raw baked-in URL (docs/78 §9).
  deep_link_module     TEXT,
  deep_link_params     JSONB,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  read_at              TIMESTAMPTZ,
  acknowledged_at      TIMESTAMPTZ,
  archived_at          TIMESTAMPTZ,
  expires_at           TIMESTAMPTZ,
  CONSTRAINT user_notifications_template_params_object CHECK (jsonb_typeof(template_params) = 'object'),
  CONSTRAINT user_notifications_template_params_bounded CHECK (pg_column_size(template_params) <= 4096),
  CONSTRAINT user_notifications_dedup_unique UNIQUE (outbox_event_id, recipient_user_id)
);

-- Unread-list/unread-count access path (docs/78 §20) -- "my unread
-- notifications" never scans a user's full historical set.
CREATE INDEX IF NOT EXISTS idx_user_notifications_recipient_read_created
  ON user_notifications (recipient_user_id, read_at, created_at DESC);
-- Cheaper unread-count-specific path, per docs/78 §20's own fallback.
CREATE INDEX IF NOT EXISTS idx_user_notifications_recipient_unread
  ON user_notifications (recipient_user_id, created_at DESC)
  WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_user_notifications_created_brin
  ON user_notifications USING BRIN (created_at);

-- ─── Immutability guards ────────────────────────────────────────────
-- Business/source fields become immutable once written; operational
-- processing fields (outbox) or personal state fields (notifications)
-- remain mutable, exactly as docs/78 §5.6/§10 require. Unlike
-- workflow_events (fully append-only, docs/78 §2.5's own precedent),
-- both new tables here have legitimately mutable columns, so a plain
-- "reject every UPDATE" trigger would be wrong -- these compare
-- column-by-column instead.
CREATE OR REPLACE FUNCTION platform_outbox_events_enforce_immutability()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.id                 IS DISTINCT FROM OLD.id
     OR NEW.event_type          IS DISTINCT FROM OLD.event_type
     OR NEW.source_module       IS DISTINCT FROM OLD.source_module
     OR NEW.source_record_type  IS DISTINCT FROM OLD.source_record_type
     OR NEW.source_record_id    IS DISTINCT FROM OLD.source_record_id
     OR NEW.organization_id     IS DISTINCT FROM OLD.organization_id
     OR NEW.actor_id            IS DISTINCT FROM OLD.actor_id
     OR NEW.correlation_id      IS DISTINCT FROM OLD.correlation_id
     OR NEW.causation_id        IS DISTINCT FROM OLD.causation_id
     OR NEW.occurred_at         IS DISTINCT FROM OLD.occurred_at
     OR NEW.created_at          IS DISTINCT FROM OLD.created_at
     OR NEW.payload             IS DISTINCT FROM OLD.payload
     OR NEW.idempotency_key     IS DISTINCT FROM OLD.idempotency_key
  THEN
    RAISE EXCEPTION 'platform_outbox_events business/evidence columns are immutable once written' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_platform_outbox_events_immutability ON platform_outbox_events;
CREATE TRIGGER trg_platform_outbox_events_immutability
  BEFORE UPDATE ON platform_outbox_events
  FOR EACH ROW EXECUTE FUNCTION platform_outbox_events_enforce_immutability();

CREATE OR REPLACE FUNCTION user_notifications_enforce_immutability()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.id                 IS DISTINCT FROM OLD.id
     OR NEW.recipient_user_id   IS DISTINCT FROM OLD.recipient_user_id
     OR NEW.organization_id     IS DISTINCT FROM OLD.organization_id
     OR NEW.notification_type  IS DISTINCT FROM OLD.notification_type
     OR NEW.title_template_key IS DISTINCT FROM OLD.title_template_key
     OR NEW.template_params     IS DISTINCT FROM OLD.template_params
     OR NEW.source_module       IS DISTINCT FROM OLD.source_module
     OR NEW.source_record_type  IS DISTINCT FROM OLD.source_record_type
     OR NEW.source_record_id    IS DISTINCT FROM OLD.source_record_id
     OR NEW.outbox_event_id     IS DISTINCT FROM OLD.outbox_event_id
     OR NEW.priority            IS DISTINCT FROM OLD.priority
     OR NEW.deep_link_module    IS DISTINCT FROM OLD.deep_link_module
     OR NEW.deep_link_params    IS DISTINCT FROM OLD.deep_link_params
     OR NEW.created_at          IS DISTINCT FROM OLD.created_at
     OR NEW.expires_at          IS DISTINCT FROM OLD.expires_at
  THEN
    RAISE EXCEPTION 'user_notifications business-fact columns are immutable once written' USING ERRCODE = '42501';
  END IF;

  -- acknowledged_at: settable once, never cleared, and only for
  -- notification types the registry actually marks
  -- requires_acknowledgement (docs/78 §10).
  IF NEW.acknowledged_at IS DISTINCT FROM OLD.acknowledged_at THEN
    IF OLD.acknowledged_at IS NOT NULL THEN
      RAISE EXCEPTION 'acknowledged_at cannot be changed once set' USING ERRCODE = '42501';
    END IF;
    IF NEW.acknowledged_at IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM platform_event_type_registry
      WHERE event_type = NEW.notification_type AND requires_acknowledgement = TRUE
    ) THEN
      RAISE EXCEPTION 'acknowledged_at may only be set for a notification_type the registry marks requires_acknowledgement' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_user_notifications_immutability ON user_notifications;
CREATE TRIGGER trg_user_notifications_immutability
  BEFORE UPDATE ON user_notifications
  FOR EACH ROW EXECUTE FUNCTION user_notifications_enforce_immutability();

-- ─── RLS ─────────────────────────────────────────────────────────────
ALTER TABLE platform_event_type_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_outbox_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_notifications           ENABLE ROW LEVEL SECURITY;

-- Registry: safe, non-sensitive reference data -- readable by any
-- authenticated user (mirrors commands/departments/sections' own
-- "auth.uid() IS NOT NULL" read convention, rls.sql); writable only by
-- an admin (same convention those tables use for their own INSERT/
-- UPDATE policies).
CREATE POLICY platform_event_type_registry_select ON platform_event_type_registry
  FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY platform_event_type_registry_insert ON platform_event_type_registry
  FOR INSERT WITH CHECK (is_admin());
CREATE POLICY platform_event_type_registry_update ON platform_event_type_registry
  FOR UPDATE USING (is_admin());

-- Outbox: operational infrastructure, not a user-facing record
-- (docs/78 §17). Zero policies for authenticated/anon -- RLS enabled
-- with no matching policy denies every operation by default for those
-- roles; service_role (BYPASSRLS) is the only role with real access,
-- via the explicit table grants below. No SELECT/INSERT/UPDATE/DELETE
-- policy of any kind is created for authenticated/anon, deliberately.

-- user_notifications: recipient reads/updates only their own rows
-- (docs/78 §17) -- SELECT and UPDATE (read/ack/archive state only,
-- enforced by the immutability trigger above, not by RLS itself,
-- since RLS cannot restrict individual columns). No INSERT policy for
-- authenticated/anon at all -- creation is exclusively the
-- SECURITY DEFINER path below (closing the exact §2.3 gap docs/78
-- diagnoses in the legacy table, structurally, from this table's
-- first day). No DELETE policy either.
CREATE POLICY user_notifications_select ON user_notifications
  FOR SELECT TO authenticated
  USING (recipient_user_id = auth.uid());
CREATE POLICY user_notifications_update ON user_notifications
  FOR UPDATE TO authenticated
  USING (recipient_user_id = auth.uid())
  WITH CHECK (recipient_user_id = auth.uid());

-- ─── Internal/service-only creation primitives ──────────────────────
-- Neither of these is exposed to ordinary authenticated sessions.
-- Recipient resolution and authorization revalidation (docs/78 §7-§8)
-- do not exist yet (Phase 1.2) -- until they do, a generally-callable
-- creation RPC would have no way to prove a given recipient is
-- legitimately entitled to notice of a given record, so both
-- primitives are granted to service_role only, identically to how
-- Phase 5.4's own dispatcher entry point is service_role-only
-- (docs/78 §2.5/§17). A future domain RPC (itself SECURITY DEFINER,
-- owned by the same role) calls these as a plain nested function call
-- from within its own transaction -- that requires no grant to
-- authenticated on these functions at all, since the nested call
-- executes under the calling SECURITY DEFINER function's owner role,
-- not the original session's.

CREATE OR REPLACE FUNCTION platform_enqueue_outbox_event(
  p_event_type         TEXT,
  p_source_module      TEXT,
  p_source_record_type TEXT,
  p_source_record_id   UUID,
  p_organization_id    UUID,
  p_actor_id           UUID,
  p_correlation_id     UUID,
  p_causation_id       UUID,
  p_occurred_at        TIMESTAMPTZ,
  p_payload            JSONB,
  p_idempotency_key    UUID
) RETURNS UUID AS $$
DECLARE
  v_id                  UUID;
  v_existing_payload     JSONB;
  v_existing_correlation UUID;
BEGIN
  IF p_event_type IS NULL OR p_source_module IS NULL OR p_source_record_type IS NULL
     OR p_source_record_id IS NULL OR p_organization_id IS NULL OR p_correlation_id IS NULL
     OR p_occurred_at IS NULL OR p_idempotency_key IS NULL
  THEN
    RAISE EXCEPTION 'event_type, source_module, source_record_type, source_record_id, organization_id, correlation_id, occurred_at, and idempotency_key are all required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p_organization_id) THEN
    RAISE EXCEPTION 'organization_id % does not reference an existing organization', p_organization_id USING ERRCODE = '22023';
  END IF;

  IF p_actor_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users WHERE id = p_actor_id) THEN
    RAISE EXCEPTION 'actor_id % does not reference an existing user', p_actor_id USING ERRCODE = '22023';
  END IF;

  INSERT INTO platform_outbox_events (
    event_type, source_module, source_record_type, source_record_id, organization_id,
    actor_id, correlation_id, causation_id, occurred_at, payload, idempotency_key
  ) VALUES (
    p_event_type, p_source_module, p_source_record_type, p_source_record_id, p_organization_id,
    p_actor_id, p_correlation_id, p_causation_id, p_occurred_at, COALESCE(p_payload, '{}'::JSONB), p_idempotency_key
  )
  ON CONFLICT (source_module, source_record_type, source_record_id, event_type, idempotency_key)
  DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Enqueue-level idempotency (docs/78 §5.6): the same logical fact
  -- was already enqueued -- a safe no-op replay ONLY if the content
  -- genuinely matches. A different payload/correlation_id reusing the
  -- same identity/idempotency key is a caller bug, rejected
  -- deterministically rather than silently discarded or merged.
  SELECT id, payload, correlation_id INTO v_id, v_existing_payload, v_existing_correlation
  FROM platform_outbox_events
  WHERE source_module = p_source_module AND source_record_type = p_source_record_type
    AND source_record_id = p_source_record_id
    AND event_type = p_event_type AND idempotency_key = p_idempotency_key;

  IF v_existing_payload IS DISTINCT FROM COALESCE(p_payload, '{}'::JSONB)
     OR v_existing_correlation IS DISTINCT FROM p_correlation_id
  THEN
    RAISE EXCEPTION 'idempotency_key % was already used for a different event (same source/type/key, different payload or correlation_id)', p_idempotency_key USING ERRCODE = '23505';
  END IF;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION platform_create_user_notification(
  p_recipient_user_id  UUID,
  p_organization_id    UUID,
  p_notification_type  TEXT,
  p_title_template_key TEXT,
  p_template_params    JSONB,
  p_source_module      TEXT,
  p_source_record_type TEXT,
  p_source_record_id   UUID,
  p_outbox_event_id    UUID,
  p_priority           TEXT,
  p_deep_link_module   TEXT,
  p_deep_link_params   JSONB,
  p_expires_at         TIMESTAMPTZ
) RETURNS UUID AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_recipient_user_id IS NULL OR p_organization_id IS NULL OR p_notification_type IS NULL
     OR p_title_template_key IS NULL OR p_source_module IS NULL OR p_source_record_type IS NULL
     OR p_source_record_id IS NULL OR p_outbox_event_id IS NULL
  THEN
    RAISE EXCEPTION 'recipient_user_id, organization_id, notification_type, title_template_key, source_module, source_record_type, source_record_id, and outbox_event_id are all required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_recipient_user_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'recipient_user_id % is not an active user', p_recipient_user_id USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM platform_outbox_events WHERE id = p_outbox_event_id) THEN
    RAISE EXCEPTION 'outbox_event_id % does not reference an existing outbox event', p_outbox_event_id USING ERRCODE = '22023';
  END IF;

  INSERT INTO user_notifications (
    recipient_user_id, organization_id, notification_type, title_template_key, template_params,
    source_module, source_record_type, source_record_id, outbox_event_id, priority,
    deep_link_module, deep_link_params, expires_at
  ) VALUES (
    p_recipient_user_id, p_organization_id, p_notification_type, p_title_template_key,
    COALESCE(p_template_params, '{}'::JSONB), p_source_module, p_source_record_type, p_source_record_id,
    p_outbox_event_id, COALESCE(p_priority, 'normal'), p_deep_link_module, p_deep_link_params, p_expires_at
  )
  -- Notification-level idempotency (docs/78 §14): a worker that claims
  -- the same event twice never creates duplicate notifications for the
  -- same recipient.
  ON CONFLICT (outbox_event_id, recipient_user_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT id INTO v_id FROM user_notifications
  WHERE outbox_event_id = p_outbox_event_id AND recipient_user_id = p_recipient_user_id;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── Authenticated-facing read APIs ──────────────────────────────────
-- Plain SECURITY INVOKER (the default) -- RLS on user_notications
-- already fully protects the underlying rows; these are bounded,
-- keyset-paginated convenience wrappers only, adding no privilege of
-- their own on top of what user_notifications_select already grants.

CREATE OR REPLACE FUNCTION list_my_notifications(
  p_limit             INTEGER DEFAULT 20,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id         UUID DEFAULT NULL,
  p_unread_only       BOOLEAN DEFAULT FALSE
) RETURNS SETOF user_notifications AS $$
  SELECT n.*
  FROM user_notifications n
  WHERE n.recipient_user_id = auth.uid()
    AND (NOT COALESCE(p_unread_only, FALSE) OR n.read_at IS NULL)
    AND (
      p_before_created_at IS NULL
      OR (p_before_id IS NOT NULL AND (n.created_at, n.id) < (p_before_created_at, p_before_id))
    )
  ORDER BY n.created_at DESC, n.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION count_my_unread_notifications()
RETURNS INTEGER AS $$
  SELECT count(*)::INTEGER FROM user_notifications
  WHERE recipient_user_id = auth.uid() AND read_at IS NULL;
$$ LANGUAGE sql STABLE;

-- ─── Grants ──────────────────────────────────────────────────────────
REVOKE ALL ON TABLE platform_outbox_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE platform_outbox_events TO service_role;

REVOKE ALL ON TABLE user_notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE user_notifications TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE user_notifications TO service_role;

REVOKE ALL ON TABLE platform_event_type_registry FROM PUBLIC, anon;
GRANT SELECT ON TABLE platform_event_type_registry TO authenticated;
GRANT INSERT, UPDATE ON TABLE platform_event_type_registry TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE platform_event_type_registry TO service_role;

REVOKE ALL ON FUNCTION platform_outbox_events_enforce_immutability() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION user_notifications_enforce_immutability() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION platform_enqueue_outbox_event(TEXT,TEXT,TEXT,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,JSONB,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION platform_enqueue_outbox_event(TEXT,TEXT,TEXT,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,JSONB,UUID) TO service_role;

REVOKE ALL ON FUNCTION platform_create_user_notification(UUID,UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID,UUID,TEXT,TEXT,JSONB,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION platform_create_user_notification(UUID,UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID,UUID,TEXT,TEXT,JSONB,TIMESTAMPTZ) TO service_role;

REVOKE ALL ON FUNCTION list_my_notifications(INTEGER,TIMESTAMPTZ,UUID,BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION list_my_notifications(INTEGER,TIMESTAMPTZ,UUID,BOOLEAN) TO authenticated;

REVOKE ALL ON FUNCTION count_my_unread_notifications() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION count_my_unread_notifications() TO authenticated;

COMMIT;
