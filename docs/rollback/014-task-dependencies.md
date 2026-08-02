# Rollback — 014: Task Dependency Backend Foundation

Run `supabase/rollback-task-dependencies.sql` only when abandoning T3F.1. It refuses while any dependency row—active or removed—or dependency audit row remains. Those rows are business and compliance history; operators must export them and explicitly decide whether to delete them. The rollback never deletes data itself.

After the refusal prerequisites are satisfied, the transaction removes only T3F.1 policies, RPCs, private helpers, tables, indexes, and triggers, then restores the audit record/action constraints to the exact T3F architecture-checkpoint values. It does not touch Tasks, informational `task_relationships`, module `task_links`, comments, assignments, watchers, attachments, notifications, or module records.

The verified procedure is: capture the pre-T3F.1 schema and grants; apply T3F.1; prove refusal with dependency/audit history; explicitly clear disposable fixtures; roll back; compare normalized schema/grants; reapply; and rerun all validators and behavioral tests.
