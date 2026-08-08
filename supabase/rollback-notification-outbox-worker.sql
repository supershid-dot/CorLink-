-- CAP-003 Phase 1.3 notification outbox worker -- rollback. Reverses
-- patch-notification-outbox-worker.sql exactly.
--
-- Refusal precedent: this phase is purely additive -- it creates four
-- new functions (process_platform_outbox_batch,
-- replay_dead_lettered_outbox_event, platform_outbox_worker_backoff_
-- interval, platform_outbox_events_due_for_processing) plus one
-- platform_event_type_registry row it registers for the single
-- generic event shape it recognizes, and touches zero existing
-- tables, columns, functions, grants, or comments (see the patch's
-- own header). It creates no new table and stores no durable business
-- evidence of its own: every intent/notification the worker ever
-- creates lands in Phase 1.2's notification_intents / Phase 1.1's
-- user_notifications, using exactly the primitives a direct manual
-- call already produces (docs/82's own suite already exercises those
-- primitives independent of this worker) -- there is nothing this
-- rollback could destroy that Phase 1.1/1.2's own rollbacks do not
-- already own. This rollback never touches platform_outbox_events,
-- notification_intents, or user_notifications rows themselves (per
-- the governing instruction: "Do not delete outbox, intents, or
-- user_notifications") -- dropping the worker functions removes only
-- the automatic-processing code path; every event, intent, and
-- notification already durably recorded (whether processed by this
-- worker or created directly, as in docs/82's own suite) is completely
-- unaffected, exactly as CAP-002 Phase 5.4's own rollback established
-- for the identical reason ("a function body only affects future
-- calls, never already-stored rows").
--
-- The registered platform_event_type_registry row is configuration
-- data, not business evidence (docs/78 SS5.4: "configuration data, not
-- itself part of this architecture's runtime hot path") -- no FK ties
-- any platform_outbox_events/user_notifications row to this registry
-- row (event_type is a plain pattern-checked TEXT column, not a
-- foreign key), and the only code that ever reads the registry (the
-- user_notifications acknowledged_at immutability trigger) is
-- unaffected either way since this event type is registered
-- requires_acknowledgement = FALSE. Removing it is therefore safe
-- regardless of how much real processing history already references
-- this event_type string. No refusal path is needed or implemented.
\set ON_ERROR_STOP on
BEGIN;

DROP FUNCTION IF EXISTS replay_dead_lettered_outbox_event(UUID);
DROP FUNCTION IF EXISTS process_platform_outbox_batch(INTEGER, TEXT);
DROP FUNCTION IF EXISTS platform_outbox_worker_backoff_interval(INTEGER);
DROP FUNCTION IF EXISTS platform_outbox_events_due_for_processing(INTEGER);

DELETE FROM platform_event_type_registry WHERE event_type = 'platform.generic_notification_request.v1';

COMMIT;
