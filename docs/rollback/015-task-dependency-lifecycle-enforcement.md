# Rollback - 015: Task Dependency Lifecycle Enforcement

Run `supabase/rollback-task-dependency-lifecycle-enforcement.sql` only to remove T3F.2 while retaining the approved T3F.1 dependency foundation.

The rollback is transactional. It drops only the T3F.2 read-state wrapper and restores the exact T3F.1 definitions of `create_task_dependency(uuid, uuid)`, `update_task(uuid, text, text, text, text, date, date, uuid, text)`, and `complete_task(uuid, text)`. It does not use `CASCADE` and does not touch dependency rows, waivers, Tasks, Task Relationships, module links, attachments, comments, assignments, watchers, audits, notifications, or module records.

The verified procedure is: exercise lifecycle and concurrency scenarios; capture the T3F.2 definitions and grants; run rollback; compare the normalized schema, the three restored `pg_get_functiondef()` values, and ACLs with the T3F.1 checkpoint; reapply T3F.2; rerun the validator and behavioral suite.
