-- ============================================================
-- NON-PRODUCTION. Local disposable-Postgres test harness only.
-- Applied ONLY by apply-canonical-schema.sh --local-test-harness, as
-- the LAST step, after every real migration. NEVER apply this against
-- a real Supabase project — a real Supabase project already grants
-- SELECT/INSERT/UPDATE/DELETE on `public` tables to anon/authenticated
-- by default and relies on RLS (not table grants) as the actual gate;
-- a bare local Postgres instance has no such default, so this file
-- recreates it, then re-locks every table whose own migration already
-- established a narrower grant (RLS alone is not enough there — those
-- tables are meant to be mutated only through their own RPCs).
-- ============================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA auth TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

-- Every workflow_ table (CAP-002) is meant to be SELECT-only for
-- anon/authenticated -- all mutation goes through workflow_* RPCs.
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\' LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- task_relationships (patch-task-relationships.sql) and
-- task_dependencies/task_dependency_waivers (patch-task-dependencies.sql)
-- each establish their own narrower table-level grants (REVOKE ALL
-- FROM PUBLIC, anon; GRANT SELECT ONLY to authenticated -- all
-- mutation goes through their own RPCs), which the blanket grant above
-- would otherwise silently reopen.
REVOKE ALL ON TABLE task_relationships FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE task_relationships FROM authenticated;
GRANT SELECT ON TABLE task_relationships TO authenticated;
REVOKE ALL ON TABLE task_dependencies, task_dependency_waivers FROM PUBLIC, anon;
GRANT SELECT ON TABLE task_dependencies, task_dependency_waivers TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE task_dependencies, task_dependency_waivers FROM authenticated;

-- CAP-003 direct-write closures: patch-requests-server-mutation-
-- foundation.sql / patch-entry-server-mutation-foundation.sql /
-- patch-internal-collaboration-server-mutation-foundation.sql /
-- patch-prisoner-letters-server-mutation-foundation.sql each REVOKE
-- INSERT, UPDATE (and, here, for symmetry, DELETE, which no patch
-- ever granted authenticated on these tables in the first place) on
-- their own business tables FROM authenticated -- mutation goes
-- through their own RPCs only.
REVOKE INSERT, UPDATE, DELETE ON TABLE requests, responses FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE external_correspondence, external_correspondence_replies FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE internal_requests, internal_request_replies FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE prisoner_letters, prisoner_replies FROM authenticated;

-- CAP-003 core outbox/notification tables: patch-notification-outbox-
-- persistence-foundation.sql's and patch-notification-recipient-
-- resolution.sql's own exact REVOKE/GRANT posture for platform_
-- outbox_events/user_notifications/platform_event_type_registry/
-- notification_intents (all mutation goes through
-- platform_enqueue_outbox_event()/process_platform_outbox_batch()/
-- create_notification_intent()/resolve_notification_intent()/
-- platform_create_user_notification() only).
REVOKE ALL ON TABLE platform_outbox_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE platform_outbox_events TO service_role;

REVOKE ALL ON TABLE user_notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE user_notifications TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE user_notifications TO service_role;

REVOKE ALL ON TABLE platform_event_type_registry FROM PUBLIC, anon;
GRANT SELECT ON TABLE platform_event_type_registry TO authenticated;
GRANT INSERT, UPDATE ON TABLE platform_event_type_registry TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE platform_event_type_registry TO service_role;

REVOKE ALL ON TABLE notification_intents FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE notification_intents TO service_role;
