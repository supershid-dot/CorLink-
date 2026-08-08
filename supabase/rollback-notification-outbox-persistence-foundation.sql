-- CAP-003 Phase 1.1 notification outbox persistence foundation --
-- rollback. Restores the exact pre-1.1 schema: drops both new
-- authenticated-facing read RPCs, both service-only creation
-- primitives, both immutability triggers and their functions, and all
-- three new tables (platform_outbox_events, user_notifications,
-- platform_event_type_registry). No CASCADE is used anywhere --
-- every dependent object this patch created is dropped explicitly, in
-- dependency order, rather than relying on cascading drops to find
-- them.
--
-- Legacy notifications (docs/79/docs/80) and every CAP-002 object are
-- completely outside this rollback's scope -- Phase 1.1 never touched
-- either, so there is nothing of theirs to restore.
--
-- SAFETY GUARD: this rollback REFUSES to run if either new table
-- already contains any row. Phase 1.1's own tables are durable
-- business evidence once populated (docs/78 §19/§21 -- "these are the
-- durable evidence a specific user was told a specific thing, which
-- may itself have compliance relevance"), and DROP TABLE would
-- permanently destroy it. This rollback exists for exact-rollback
-- verification against the genuinely inert, still-empty foundation
-- this milestone ships (no worker, no recipient resolution, no module
-- integration -- nothing yet writes real production data into these
-- tables), not as an operational "undo" once real notifications exist.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_outbox_count BIGINT; v_notif_count BIGINT;
BEGIN
  SELECT count(*) INTO v_outbox_count FROM platform_outbox_events;
  SELECT count(*) INTO v_notif_count FROM user_notifications;
  IF v_outbox_count > 0 OR v_notif_count > 0 THEN
    RAISE EXCEPTION 'Refusing to roll back CAP-003 Phase 1.1: % platform_outbox_events row(s) and % user_notifications row(s) exist. Rolling back would DROP TABLE both, permanently destroying durable business evidence (docs/78 SS19/SS21). Archive/export this data first, or explicitly accept data loss by truncating both tables yourself before re-running this rollback.',
      v_outbox_count, v_notif_count USING ERRCODE = '55000';
  END IF;
END $$;

DROP FUNCTION IF EXISTS count_my_unread_notifications();
DROP FUNCTION IF EXISTS list_my_notifications(INTEGER, TIMESTAMPTZ, UUID, BOOLEAN);
DROP FUNCTION IF EXISTS platform_create_user_notification(UUID,UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID,UUID,TEXT,TEXT,JSONB,TIMESTAMPTZ);
DROP FUNCTION IF EXISTS platform_enqueue_outbox_event(TEXT,TEXT,TEXT,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,JSONB,UUID);

DROP TRIGGER IF EXISTS trg_user_notifications_immutability ON user_notifications;
DROP TRIGGER IF EXISTS trg_platform_outbox_events_immutability ON platform_outbox_events;
DROP FUNCTION IF EXISTS user_notifications_enforce_immutability();
DROP FUNCTION IF EXISTS platform_outbox_events_enforce_immutability();

DROP TABLE IF EXISTS user_notifications;
DROP TABLE IF EXISTS platform_outbox_events;
DROP TABLE IF EXISTS platform_event_type_registry;

COMMIT;
