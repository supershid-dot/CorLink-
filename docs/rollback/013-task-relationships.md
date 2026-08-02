# Rollback — 013: Task Relationships

Use `supabase/rollback-task-relationships.sql` to remove T3E/T3E.1 and return the database surface to T3D.1.

The rollback deliberately refuses while `task_relationships` contains any active or removed row. Removed rows are still business history; dropping the table would destroy them just as surely as active rows. Before abandoning the feature, an operator must export that history and explicitly decide to delete it. The rollback script never deletes relationship data itself.

After the prerequisite is satisfied, the transaction drops only the five relationship functions, the relationship audit policy, and `task_relationships`, then restores `audit_logs_record_type_check` to the exact T3D.1 list without `task_relationship`. It does not touch Tasks, assignments, watchers, comments, attachments, `task_links`, or any module integration.

The tested cycle is:

1. Capture the T3D.1 schema objects and grants.
2. Apply T3E and T3E.1 and create exercised relationship data.
3. Confirm rollback refusal while data exists and atomic preservation of all objects/data.
4. Export/delete the disposable relationship rows explicitly.
5. Apply the rollback and compare the schema/grant capture to T3D.1.
6. Reapply T3E and T3E.1 and rerun validation and behavioral tests.

See `docs/50-task-relationships.md` for the executed totals and equality result.
