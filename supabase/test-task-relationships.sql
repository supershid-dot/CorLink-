-- CorLink — Behavioral tests for T3E Task Relationships
-- Run only against a disposable/local database with the full patch chain.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE relationship_test_ids AS
SELECT u.id AS actor, t.id AS task_a,
       (SELECT id FROM users WHERE org_id = u.org_id AND is_active AND id <> u.id ORDER BY id LIMIT 1) AS outsider,
       (SELECT id FROM tasks WHERE created_by = u.id AND id <> t.id ORDER BY created_at LIMIT 1) AS task_b,
       (SELECT id FROM tasks WHERE created_by = u.id AND id <> t.id ORDER BY created_at DESC LIMIT 1) AS task_c
FROM users u
JOIN tasks t ON t.created_by = u.id
WHERE u.is_active
  AND (SELECT count(*) FROM tasks tx WHERE tx.created_by = u.id AND tx.id <> t.id) >= 2
LIMIT 1;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM relationship_test_ids WHERE outsider IS NOT NULL AND task_a IS NOT NULL AND task_b IS NOT NULL AND task_c IS NOT NULL AND task_b <> task_c) THEN
    RAISE EXCEPTION 'TEST SETUP FAILED: requires an organization with two active users and one user who created three tasks';
  END IF;
END $$;

UPDATE tasks SET visibility = 'organization'
WHERE id IN (SELECT task_a FROM relationship_test_ids UNION SELECT task_b FROM relationship_test_ids UNION SELECT task_c FROM relationship_test_ids);
GRANT SELECT ON relationship_test_ids TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', actor)::text, true) FROM relationship_test_ids;

-- Creation and reciprocal listing.
CREATE TEMP TABLE created_relationship AS
SELECT create_task_relationship(task_a, task_b, 'parent') AS id FROM relationship_test_ids;
DO $$ BEGIN
  IF (SELECT count(*) FROM relationship_test_ids i, LATERAL list_related_tasks(i.task_a) r WHERE r.relationship_type = 'parent') <> 1
     OR (SELECT count(*) FROM relationship_test_ids i, LATERAL list_related_tasks(i.task_b) r WHERE r.relationship_type = 'child') <> 1 THEN
    RAISE EXCEPTION 'TEST FAILED: creation/listing/inverse relationship';
  END IF;
END $$;

-- Self prevention.
DO $$ BEGIN
  BEGIN
    PERFORM create_task_relationship(task_a, task_a, 'related') FROM relationship_test_ids;
    RAISE EXCEPTION 'TEST FAILED: self relationship accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'TEST FAILED:%' THEN RAISE; END IF; END;
END $$;

-- Duplicate prevention, including inverse direction/type.
DO $$ BEGIN
  BEGIN
    PERFORM create_task_relationship(task_b, task_a, 'child') FROM relationship_test_ids;
    RAISE EXCEPTION 'TEST FAILED: duplicate active relationship accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'TEST FAILED:%' THEN RAISE; END IF; END;
END $$;

-- Circular parent/child prevention: A parent B, B parent C, reject C parent A.
SELECT create_task_relationship(task_b, task_c, 'parent') FROM relationship_test_ids;
DO $$ BEGIN
  BEGIN
    PERFORM create_task_relationship(task_c, task_a, 'parent') FROM relationship_test_ids;
    RAISE EXCEPTION 'TEST FAILED: circular parent chain accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'TEST FAILED:%' THEN RAISE; END IF; END;
END $$;

-- Permission capabilities are server-derived and visible endpoints are required.
DO $$ BEGIN
  IF NOT (SELECT can_create FROM relationship_test_ids i, LATERAL get_task_relationship_capabilities(i.task_a)) THEN
    RAISE EXCEPTION 'TEST FAILED: creator capability missing';
  END IF;
END $$;

-- A viewer who can see, but cannot manage, the task cannot mutate it.
SELECT set_config('request.jwt.claims', json_build_object('sub', outsider)::text, true) FROM relationship_test_ids;
DO $$ BEGIN
  IF (SELECT can_create FROM relationship_test_ids i, LATERAL get_task_relationship_capabilities(i.task_a)) THEN
    RAISE EXCEPTION 'TEST FAILED: non-manager received create capability';
  END IF;
  BEGIN
    PERFORM create_task_relationship(task_a, task_c, 'related') FROM relationship_test_ids;
    RAISE EXCEPTION 'TEST FAILED: non-manager created a relationship';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'TEST FAILED:%' THEN RAISE; END IF; END;
END $$;
SELECT set_config('request.jwt.claims', json_build_object('sub', actor)::text, true) FROM relationship_test_ids;

-- Removal is soft, disappears from normal lists, and retains history.
SELECT remove_task_relationship(id) FROM created_relationship;
DO $$ BEGIN
  IF (SELECT removed_at IS NULL FROM task_relationships WHERE id = (SELECT id FROM created_relationship))
     OR EXISTS (SELECT 1 FROM relationship_test_ids i, LATERAL list_related_tasks(i.task_a) r WHERE r.related_task_id = i.task_b) THEN
    RAISE EXCEPTION 'TEST FAILED: removal/visibility';
  END IF;
  RAISE NOTICE 'ALL TASK RELATIONSHIP TESTS PASSED';
END $$;

ROLLBACK;
