-- CAP-003 Phase 1.2 notification recipient resolution -- rollback.
-- Restores the exact pre-1.2 schema: drops the service-only resolution
-- primitive (resolve_notification_intent), the service-only creation
-- primitive (create_notification_intent), both explicit-user
-- authorization-revalidation helpers (intent_user_can_view_workflow_instance,
-- intent_user_is_super_admin), the immutability trigger and its function,
-- and notification_intents itself. No CASCADE anywhere -- every dependent
-- object this patch created is dropped explicitly, in dependency order,
-- rather than relying on cascading drops to find them.
--
-- Phase 1.1's own objects (platform_outbox_events, user_notifications,
-- platform_event_type_registry, platform_enqueue_outbox_event,
-- platform_create_user_notification, list_my_notifications,
-- count_my_unread_notifications), CAP-003 1.0A/1.0B (legacy notification
-- fixes), and every CAP-002 object are completely outside this rollback's
-- scope -- Phase 1.2 never touched any of them, so there is nothing of
-- theirs to restore.
--
-- SAFETY GUARD: this rollback REFUSES to run if notification_intents
-- already contains any row. Phase 1.2's own table is durable evidence of
-- a recipient-resolution decision once populated (docs/78 SS6 -- "these
-- recipients should learn about this event"), and DROP TABLE would
-- permanently destroy it. This rollback exists for exact-rollback
-- verification against the genuinely inert, still-empty foundation this
-- milestone ships (no worker, no module integration -- nothing yet calls
-- create_notification_intent in production), not as an operational
-- "undo" once real intents exist.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_intent_count BIGINT;
BEGIN
  SELECT count(*) INTO v_intent_count FROM notification_intents;
  IF v_intent_count > 0 THEN
    RAISE EXCEPTION 'Refusing to roll back CAP-003 Phase 1.2: % notification_intents row(s) exist. Rolling back would DROP TABLE notification_intents, permanently destroying durable recipient-resolution evidence (docs/78 SS6). Archive/export this data first, or explicitly accept data loss by truncating the table yourself before re-running this rollback.',
      v_intent_count USING ERRCODE = '55000';
  END IF;
END $$;

DROP FUNCTION IF EXISTS resolve_notification_intent(UUID);
DROP FUNCTION IF EXISTS create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID);

DROP TRIGGER IF EXISTS trg_notification_intents_immutability ON notification_intents;
DROP FUNCTION IF EXISTS notification_intents_enforce_immutability();

DROP FUNCTION IF EXISTS intent_user_can_view_workflow_instance(UUID, UUID);
DROP FUNCTION IF EXISTS intent_user_is_super_admin(UUID);

DROP TABLE IF EXISTS notification_intents;

COMMIT;
