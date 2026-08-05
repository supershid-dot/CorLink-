-- CAP-002 Phase 2B.1 transactional rollback.
--
-- Removes only what this patch added/changed: the new
-- canonicalize_workflow_definition_payload() helper, and restores
-- create_workflow_definition/create_workflow_definition_version/
-- publish_workflow_definition_version to their exact Phase 1 bodies
-- (copied verbatim from supabase/patch-workflow-backend-foundation.sql
-- — that file was never edited by this patch, so its text is still
-- the authoritative pre-patch source, not hand-transcribed).
--
-- Refuses to run if any executable-v1 (schema_version-bearing)
-- definition version exists, per docs/63's own rollback contract —
-- rolling back the validator while an executable definition already
-- exists would silently strip the only gate that ever validated it,
-- and any already-published executable version would become
-- publishable-again-without-validation on a future republish attempt
-- (impossible today since publish is one-shot per version, but the
-- preflight check is a hard, unconditional refusal regardless).
-- Preserves every Phase 1/2 table, row, RLS policy, grant, and index.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count
  FROM workflow_definition_versions
  WHERE definition_payload ? 'schema_version';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Refusing rollback: % executable-v1 workflow_definition_versions row(s) exist. Rollback would remove the only validator that ever checked them.', v_count
      USING ERRCODE = '55000';
  END IF;
END $$;

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

DROP FUNCTION IF EXISTS canonicalize_workflow_definition_payload(JSONB, UUID);

COMMIT;
