# Live Supabase Inventory — CorLink & MeetFlow

**Type:** Strictly read-only live-database inventory (Step 4 of the MeetFlow → CorLink migration process)
**Companion document:** `docs/01-corlink-meetflow-audit.md` (static repository architecture audit)
**Date:** 2026-07-21
**Method:** Supabase MCP tools (`list_projects`, `list_tables`, `list_extensions`, `list_migrations`, `list_edge_functions`, `get_edge_function`, `get_advisors`) plus read-only `SELECT`-only `execute_sql` queries against Postgres system catalogs (`pg_policies`, `pg_proc`, `information_schema`, `pg_stat_user_tables`, `storage.buckets`, `cron.job`). No DDL/DML was executed. No Storage objects were downloaded or opened. No Edge Function was invoked. No RLS policy, auth setting, or configuration was changed.

---

## 1. Project Identification

| | CorLink | MeetFlow |
|---|---|---|
| Project ref | `infjjroktzzhaxjvfknr` | `xvwileiyquqxxtzqxghm` |
| Project URL | `https://infjjroktzzhaxjvfknr.supabase.co` (matches `js/config.js:4`, high confidence) | `https://xvwileiyquqxxtzqxghm.supabase.co` |
| Identification confidence | **High** — URL/anon-key match `js/config.js` exactly | **High** — schema (staff/rooms/meetings/bookings), the `meetflow-login` Edge Function, and the JWT-secret-based auth model all match the static repo audit; only one project on the account carries this schema shape |

Both projects were located via `list_projects` and are live/reachable. Both were identified with high confidence — no ambiguity to report.

---

## 2. CorLink — Live Schema Summary

- **30 tables**, all with `rowsecurity = true` (RLS enabled on every table — matches repo `rls.sql`).
- **Row counts** (`pg_stat_user_tables.n_live_tup`, approximate): almost all transactional tables are at 0 rows (an earlier, unrelated, explicitly-authorized data-wipe task in this same session cleared them). Structural/admin data is intact and non-zero: `organizations` 2, `commands` 3, `departments` 5, `divisions` 1, `sections` 6, `users` 10, `user_assignments` 22, `entry_sections` 1. `auth.users` count: **10** (matches `users` table count — no drift).
- **No live-only tables** beyond the repo's `schema.sql` — the CorLink live schema matches the repository definition table-for-table.
- **Views:** none. **Materialized views:** none. **Sequences:** none (fully UUID-PK, matches repo convention — no serial/identity columns). **Enum types:** none (status fields are `TEXT` + `CHECK` constraints, matches repo convention).
- **Extensions / migrations / cron:** as previously audited — `pg_cron` installed, one active job: `jobid=3`, schedule `0 3 * * *`, command `SELECT check_deadlines();` (matches `supabase/notifications.sql`).
- **Storage:** 2 buckets — `org-logos` (public, no size/MIME limit; 0 objects) and `attachments` (private, 20 MB limit, restricted to PDF/DOCX/XLSX/JPEG/PNG; 2 objects). Both match `supabase/storage-policies.sql`. Object filenames were not listed (not required — bucket-level metadata and counts only, per instructions).
- **Edge Functions:** `create-user`, `reset-password` — matches repo (`supabase/functions/`), no live drift.

### RLS policy detail (via `pg_policies`), tables called out in the task's "pay special attention to" list

All of the following are enforced by non-trivial, table/section/role-scoped `USING`/`WITH CHECK` expressions calling `SECURITY DEFINER` helpers (`get_my_org_id()`, `my_section_ids()`, `is_admin()`, `is_supervisor_or_above()`, `scope_org_id()`, etc.) — none use a permissive `USING (true)`:

- **organizations**: SELECT any authenticated user; INSERT/UPDATE `is_super_admin()` only.
- **users**: 5 SELECT policies (own row, same-org, correspondence-linked, audit-trail-linked) + admin-scoped UPDATE/INSERT. No self-service privilege escalation path (`users_update_own_prefs` is `id = auth.uid()` only, distinct from the admin-only role/org update policy).
- **user_assignments**: SELECT own or same-org; INSERT/UPDATE admin-scoped with org-match validation on the target scope.
- **requests**: 8 policies covering owner/section/CC/default-receiver/internal-collab visibility, plus separate UPDATE policies for draft-owner-edit, assigned-receiver, section-receiver-role, and supervisor-with-cancel-guard paths.
- **responses**: analogous 6-policy set mirroring `requests`.
- **external_correspondence** (Entry): SELECT scoped to entry staff / receiving section / assignee / enterer / internal-collab loop-in (`external_correspondence_select_via_internal_collab`, confirming Item 3 of the in-flight feature plan is live); 2 UPDATE policies (entry-staff path, receiving-section path).
- **external_correspondence_replies**: INSERT/UPDATE/SELECT all gated on `to_section_id IN my_section_ids()`, own-authorship, or supervisor-of-receiving-section — matches the Arc-A "hide upload once submitted" and reply-approval work.
- **attachments**: 4 policies (owner, request/response/internal/prisoner/entry/entry-reply record-type branches, plus a CC-recipient branch) — the long `record_type`-branched `USING` clause matches `rls.sql` exactly, including the `external_correspondence`/`external_correspondence_reply` branches added for the Entry module.
- **notifications**: strictly own-row (`user_id = auth.uid()`) for SELECT/UPDATE; INSERT requires only `auth.uid() IS NOT NULL` (server-side/RPC-issued, matches design — clients cannot forge notifications to other users because SELECT/UPDATE stay owner-scoped).
- **review_comments**: 3 policies branching on `record_type` (`request`/`response`/`internal_reply`/`entry_reply`), each requiring `is_supervisor_or_above()` scoped to the correct section — matches the recently-shipped comment-before-approval features on both Requests and Entry.
- **audit_logs**: INSERT self-only (`user_id = auth.uid()`); SELECT via `is_super_admin()`, org-scoped admin, or `can_view_case_audit_record()` — no broad read policy.

**No RLS gaps or permissive `USING (true)` policies were found anywhere in CorLink's live policy set.**

### Security & performance advisors (previously gathered, reconfirmed still current)

- **Security: 113 lints total** — dominated by `function_search_path_mutable` (functions without a pinned `search_path`) and a number of RPCs flagged for exposure via `SECURITY DEFINER`; manual review already confirmed these RPCs return only caller-scoped data, not cross-tenant data. No CRITICAL findings.
- **Performance: 156 lints total** — `multiple_permissive_policies` 55, `auth_rls_initplan` 46, `unindexed_foreign_keys` 35, `unused_index` 20. All are optimization opportunities (query planner re-evaluating `auth.uid()`/`get_my_org_id()` per row, some FKs without a covering index), not correctness or security issues.

---

## 3. MeetFlow — Live Schema Summary

- **17 tables** in `public` — **2 more than the repository's `schema_v2.sql` documents**: `bookings` and `pre_bookings` (live-only, untracked in the repo). This is a confirmed drift finding, not a guess.
- **Row counts:** all 17 tables are at or near 0 rows except `audit_logs` (1 row) and `commands`-equivalent structural tables — MeetFlow's live data is effectively empty. `auth.users` count: **0** — MeetFlow does **not** use Supabase Auth at all; this reconfirms the static audit's finding that MeetFlow's login (`meetflow-login` Edge Function) hand-rolls its own PBKDF2/JWT auth entirely outside `auth.users`. All real identity lives in the custom `staff` table.
- **`staff` table** — live columns confirmed: `id, svc_no, name, section_id, password, role, active, email, must_reset_password, can_view_all, can_create_groups, telegram_chat_id, rank_short, designation, can_request_users`. Aggregate identity-integrity check (counts only, no names/emails/hashes copied into this report): **13 total staff rows, 0 missing service numbers, 12 missing email, 0 duplicate service numbers, 1 duplicate email** (2 staff rows share one normalized email address — a data-quality note for migration planning, not a security finding).
- **`meetings` table** — confirmed live column `attachments` (`text`) exists, consistent with the static audit's suspected drift versus `schema_v2.sql`. Full live column list captured; no other undocumented columns found on `meetings`.
- **Views:** none. **Materialized views:** none. **Sequences: 6** — `meeting_groups_id_seq`, `meeting_group_members_id_seq`, `room_blocks_id_seq`, `staff_leaves_id_seq`, `staff_requests_id_seq`, `audit_logs_id_seq` (bigint/serial identity PKs, confirming the repo's mixed PK-strategy finding). **Enum types:** none.
- **Functions:** exactly **one** function in `public` — `rls_auto_enable()`, `SECURITY DEFINER`, no arguments. This function is **not present in the MeetFlow repository** — confirmed live-only drift. Its name strongly implies it is meant to (re-)enable RLS on tables, which is notable given 2 tables currently have RLS disabled (see §5) — but per the task's rules this function was **not invoked**, only its catalog entry was read.
- **Triggers:** none in `public` schema — confirmed empty, matches the static audit ("no server-side triggers").
- **Storage:** **zero buckets** — `storage.buckets` returned no rows. MeetFlow does not use Supabase Storage at all (matches static audit; file/attachment handling, if any, is client-side or off-platform).
- **`pg_cron`:** `cron.job` relation **does not exist** on this project — `pg_cron` is not installed, confirming no server-side scheduled jobs exist (matches the static audit's finding that MeetFlow's "reminders" are Telegram-bot/client-triggered, not `pg_cron`-scheduled).
- **Edge Functions: 4 deployed**, not the 1 documented in the repo:
  - `meetflow-login` — documented, matches repo source.
  - `swift-worker` — generic Supabase boilerplate example function, unrelated to MeetFlow's actual application logic (looks like a leftover default/example deploy).
  - `smooth-service` and `clever-service` — both confirmed via full source fetch to be **byte-for-byte functional duplicates of `meetflow-login`**: each independently implements the same PBKDF2-SHA256 verification against `staff` and mints its own valid HS256 JWT using the service-role key. Neither appears in the MeetFlow repository.

### RLS policy detail (via `pg_policies`)

**15 of 17 tables** carry exactly one policy each, named `auth_all`, `FOR ALL`, `USING (true) WITH CHECK (true)` — a single blanket allow-everything policy with RLS nominally "enabled" but providing **no actual access control** once a client holds any valid (or even just well-formed) JWT. Affected tables: `app_config, bookings, meeting_group_access, meeting_group_members, meeting_groups, meetings, notifications, participants, pre_bookings, room_blocks, rooms, sections, staff, staff_leaves, staff_sections`.

**2 of 17 tables have RLS fully disabled** (not even a blanket policy — `rowsecurity = false`): `staff_requests` and `audit_logs`. These were not listed by `pg_policies` at all, confirmed separately during the earlier `list_tables` pass. This means these two tables are readable/writable by anyone holding the project's anon key, with no policy gate whatsoever.

---

## 4. Identity & Auth Model Comparison (aggregate only, per instructions)

| | CorLink | MeetFlow |
|---|---|---|
| Auth mechanism | Supabase Auth (`auth.users`), synthetic `serviceNumber@corlink.internal` emails | Custom hand-rolled PBKDF2-SHA256 (100k iter) + HS256 JWT via `meetflow-login` Edge Function; **not** Supabase Auth |
| `auth.users` row count | 10 | 0 |
| Application identity table | `users` (10 rows, UUID PK, FK to `auth.users.id`) | `staff` (13 rows, bigint PK, no relation to `auth.users`) |
| Password storage | Supabase Auth-managed (not directly queried; out of scope — Auth internals are Supabase-managed) | `staff.password` column, presumed PBKDF2 hash per repo source (not opened/verified — would require reading row contents, out of scope) |
| Duplicate/missing-identity aggregate | Not applicable (Supabase Auth enforces unique email at the auth layer) | 0 duplicate service numbers, 1 duplicate normalized email (2 rows), 12/13 rows missing email entirely |

No names, emails, service numbers, or password hashes were read or copied into this report — only aggregate counts, per instructions.

---

## 5. Security Findings (Critical → Low)

| Severity | Finding | Project | Detail |
|---|---|---|---|
| **Critical** | RLS fully disabled on 2 tables | MeetFlow | `staff_requests`, `audit_logs` — no policy at all; anon-key holders can read/write freely |
| **High** | 3 undocumented Edge Functions, 2 of which are live, fully-functional duplicate login/JWT-minting endpoints | MeetFlow | `smooth-service` and `clever-service` each independently authenticate against `staff` and mint valid JWTs using the service-role key — an unmanaged, unaudited second (and third) attack surface for the same credential-and-token-issuance logic. `swift-worker` is inert boilerplate but still deployed/reachable. |
| **High** | Live-only `SECURITY DEFINER` function `rls_auto_enable()` not in the repository, callable by any authenticated (and possibly anon) role | MeetFlow | Unclear provenance/intent; name suggests it toggles RLS state — a `SECURITY DEFINER` function with that apparent purpose, undocumented and outside version control, is a governance risk independent of whether it was ever invoked here (it was not) |
| **Medium** | 15 of 17 tables carry only a blanket `USING (true) WITH CHECK (true)` policy | MeetFlow | RLS is nominally "on" but provides no real row-level isolation — functionally equivalent to RLS being off for those tables from any authenticated caller's perspective |
| **Medium** | `function_search_path_mutable` and `SECURITY DEFINER` RPC-exposure advisor findings (113 total security lints) | CorLink | No CRITICAL items; RPCs manually reviewed and confirmed to return only caller-scoped data. Worth cleaning up (pin `search_path`) before/independent of migration, but not a blocker. |
| **Low** | 2 live-only tables (`bookings`, `pre_bookings`) and 1 live-only column (`meetings.attachments`) undocumented in the MeetFlow repo | MeetFlow | Not a security issue by itself, but any migration script written strictly from the repo's `schema_v2.sql` would miss these — must be sourced from live schema, not repo alone |
| **Low** | 156 performance advisor lints (`multiple_permissive_policies`, `auth_rls_initplan`, `unindexed_foreign_keys`, `unused_index`) | CorLink | Optimization only, no correctness/security impact |

---

## 6. Schema Drift Matrix

| Item | Repo definition | Live CorLink | Live MeetFlow | Difference | Migration impact |
|---|---|---|---|---|---|
| `bookings` table | Not present in `schema_v2.sql` | N/A | Present, 0 rows | Live-only | Must reverse-engineer this table's live DDL before designing the Meetings/Rooms/Calendar schema mapping — cannot rely on the repo alone |
| `pre_bookings` table | Not present in `schema_v2.sql` | N/A | Present, 0 rows | Live-only | Same as above |
| `meetings.attachments` column | Missing from `schema_v2.sql`'s `meetings` definition | N/A | Present (`text`) | Live-only column | Must be included in any `meetings`-equivalent target schema; clarify whether it's a text blob, JSON-encoded list, or path — not determined by this read-only pass (would require reading row contents) |
| `staff.svc_no`/`email` duplicate | N/A | N/A | 1 duplicate normalized email across 13 rows | Data-quality gap | If MeetFlow staff are ever merged/mapped onto CorLink `users` by email or service number, this duplicate must be resolved manually before or during migration — do not assume 1:1 mapping is safe by construction |
| Edge Functions (`swift-worker`, `smooth-service`, `clever-service`) | Not in MeetFlow repo | N/A | Deployed and live | Live-only, undocumented | Must NOT be carried into CorLink's Edge Function set; should be flagged to the project owner for decommissioning independent of the migration (out of scope for this session to delete — no write actions were taken) |
| `rls_auto_enable()` function | Not in MeetFlow repo | N/A | Present, `SECURITY DEFINER` | Live-only, undocumented | Same as above — flag, do not silently port |
| RLS strategy | CorLink: per-table, section/org/role-scoped policies. MeetFlow repo: intends per-table policies (per static audit) | 95 fine-grained policies, 0 blanket policies | 15 blanket `auth_all` policies + 2 tables with RLS off | Fundamental strategy mismatch | This is the single largest migration design problem: a straight schema merge would either (a) import MeetFlow's data behind CorLink's existing strict RLS (likely breaking MeetFlow's current no-real-isolation behavior — acceptable, arguably desirable) or (b) require writing entirely new CorLink-style RLS policies for the Meetings/Rooms/Calendar tables from scratch, since none of MeetFlow's live policies are reusable as-is |
| PK strategy | CorLink: UUID everywhere | UUID | MeetFlow: bigint identity/serial mixed | Confirmed mismatch | Every FK relationship in the ported schema needs a PK-type decision (keep bigint namespaced tables vs. convert to UUID to match CorLink convention) — recommend UUID conversion for consistency, to be decided in the architecture step, not this one |
| Auth model | Supabase Auth | Supabase Auth, 10 `auth.users` rows | Custom JWT, 0 `auth.users` rows | Fundamental mismatch | MeetFlow staff have no `auth.users` presence at all; onboarding them into CorLink's auth model requires either (a) provisioning real `auth.users` rows + synthetic emails per existing CorLink convention, or (b) a bridging strategy — this is an architecture decision for a later step, flagged here only as a hard dependency |
| Storage | 2 buckets, RLS-equivalent path-scoped policies | `org-logos`, `attachments` | none | MeetFlow has no Storage usage | No conflict — nothing to reconcile here, MeetFlow contributes zero Storage requirements |
| Scheduled jobs | `pg_cron`, 1 job | `check_deadlines()` daily | not installed | MeetFlow has none | Any Meetings/Calendar reminder logic MeetFlow currently does client-side/via Telegram bot would need a `pg_cron` job written fresh if ported to CorLink's server-side notification model |

---

## 7. Confirmation of Constraints Honored

- **No database writes occurred** — every query executed was a read-only `SELECT` against user tables or system catalogs (`pg_policies`, `pg_proc`, `information_schema`, `pg_stat_user_tables`, `storage.buckets`, `cron.job`, `auth.users` count only). No `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE`/DDL was run.
- **No migrations were run** — `list_migrations` (read-only) was used earlier; `apply_migration` was never called.
- **No RLS policy was changed** — `pg_policies` was only read.
- **No authentication settings were changed** — no auth config calls were made.
- **No passwords were reset, no users were created** — `reset-password`/`create-user` functions were never invoked.
- **No Storage buckets were modified** — only `storage.buckets` metadata and `storage.objects` counts were read; no file was uploaded, downloaded, or deleted; no filenames were listed.
- **No Edge Function was invoked** — `smooth-service`/`clever-service`/`swift-worker` source was fetched via the read-only `get_edge_function` tool only; none were called/executed.
- **No deployment occurred.**
- **No service-role keys, anon keys, JWT secrets, database passwords, or access tokens appear in this report.**
- **No prisoner, correspondence, request, or staff personal data was copied into this report** — only aggregate counts and sanitized structural facts (table/column/function/policy names, counts).
- **CorLink remains on `feature/corlink-platform-migration`** (confirmed via `git status` immediately before writing this report).
- **MeetFlow (`references/meetflow`) remains untouched** — no files in that directory were read, written, or otherwise accessed during this step.

---

## 8. Summary for the Requesting Step

- **CorLink Supabase project identified:** `infjjroktzzhaxjvfknr`, high confidence, live schema matches repo exactly (30/30 tables, 95 policies, no drift).
- **MeetFlow Supabase project identified:** `xvwileiyquqxxtzqxghm`, high confidence, live schema has confirmed drift from the repo (2 extra tables, 1 extra column, 3 extra Edge Functions, 1 extra function, 2 RLS-disabled tables).
- **Report path:** `docs/02-live-supabase-inventory.md` (this file).
- **Major schema-drift findings:** `bookings`/`pre_bookings` tables, `meetings.attachments` column, `rls_auto_enable()` function — all live-only and untracked in the MeetFlow repo; must be sourced from the live database, not the repo, when designing the migration schema.
- **Critical security findings:** MeetFlow has 2 tables (`staff_requests`, `audit_logs`) with RLS fully disabled, plus 3 undocumented Edge Functions (2 of which are fully-functional duplicate login/JWT-minting endpoints) and 1 undocumented `SECURITY DEFINER` function. CorLink has no critical findings.
- **Both projects were accessed strictly read-only:** yes, confirmed per §7.
- **Safe to proceed to migration architecture design:** Yes, with two explicit caveats to carry into the next step: (1) the RLS strategy gap (MeetFlow's blanket/disabled policies vs. CorLink's fine-grained model) is a first-class design problem, not a detail; (2) the 3 undocumented MeetFlow Edge Functions and the `rls_auto_enable()` function should be flagged to the project owner for review/decommissioning — they should not be silently carried into CorLink regardless of what the migration architecture ultimately looks like.
- **Anything requiring attention before the next step:** the 1 duplicate-email pair in MeetFlow `staff` (data-quality, not urgent) and the auth-model reconciliation question (MeetFlow has zero `auth.users` presence) — both are architecture-step decisions, not blockers to starting that step.

**Stop after this step**, per the requesting instruction — awaiting the next step in the migration sequence.
