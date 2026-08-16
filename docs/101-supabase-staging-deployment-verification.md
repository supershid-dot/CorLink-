# 101 — Supabase Staging Deployment Verification

Verification pass over CorLink's Supabase **staging** project, confirming the full
canonical migration chain (`supabase/deploy/canonical-migration-order.txt`) already
applied there is structurally sound, functionally correct, and safe to build a
production runbook against. This document reports findings only — it does not apply
any SQL, and it does not authorize production deployment on its own.

Performed against branch `claude/phase-2-continuation-mc4hr1` at
`2e431e9bd610e6e350abcc51659efb9541149556`.

---

## 1. Staging project identity

| | |
|---|---|
| Project name | CorLink Staging |
| Project ref / MCP target | `vjobntuyzymhcuanyeak` |
| Region | ap-northeast-1 |
| Status | ACTIVE_HEALTHY |

Confirmed via `list_projects` before any query was run. Every query in this pass was
issued against this ref explicitly.

## 2. Production untouched confirmation

Production project ref `infjjroktzzhaxjvfknr` ("corlink-production") was never passed
as a `project_id` to any tool in this session. No query, read or write, touched it.
This document itself does not deploy anything to it.

## 3. Migrations already applied (not reapplied)

Per `supabase/deploy/canonical-migration-order.txt`, the full chain — base schema
through `patch-attachments-authorization-restoration.sql` — was already applied to
staging before this verification pass began. No migration file was re-run. Every
check below is read-only, or (where a mutation was necessary to prove a code path)
was performed inside a transaction that was rolled back, with staging's row counts
independently confirmed unchanged before and after.

## 4. Preserved counts

| Table | Expected (prior observation) | Confirmed this pass |
|---|---|---|
| `auth.users` | 7 | 7 |
| `public.users` | 7 | 7 |
| `organizations` | 2 | 2 |
| `sections` | 2 | 2 |
| `user_assignments` | 6 | 6 |

No unexpected change. Additionally confirmed: 0 `auth.users` rows without a matching
`public.users` profile, 0 `public.users` rows without a matching `auth.users` row, 0
users without an `org_id`, 0 inactive users. Staging now has real, distinct accounts
across both orgs (MCS-STG: org admin, supervisor, staff, room manager, super admin;
HRCM-STG: authority admin, correspondence staff) — a material improvement over an
earlier point in this engagement when only the super admin account existed.

## 5. Validator sweep results

Every committed forward `validate-*.sql` file (66 total; the 34 `-rollback` variants
were not run, since staging is not being rolled back) was executed against staging,
split across four parallel sweeps by subsystem.

| Total | PASS | FAIL | N/A | Confirmed DEFECTs |
|---|---|---|---|---|
| 66 | 61 | 4 | 1 | 1 |

**The 1 N/A**: `validate-meeting-attachments.sql` — its own header explicitly directs
"run against a disposable/local test database... **never** against staging or
production." Honored; not executed against staging.

**3 of the 4 FAILs are benign, not defects:**
- `validate-workflow-sla-escalation-foundation.sql` — its hard-fail check asserts
  `pg_cron` must not be installed at all. It is installed, but only for one
  pre-existing, unrelated job (`check-deadlines-daily`, a legacy overdue-request
  sweep with zero references to any `workflow_*` object). Every workflow-specific
  assertion in the file passed individually.
- `validate-task-attachments.sql` — 6 sub-checks use a `LIKE` pattern against the
  `attachments` policy text that a *later*, more protective patch
  (`patch-attachments-authorization-restoration.sql`) legitimately changed the shape
  of. The live policy is at least as restrictive as this older validator expected,
  not weaker — confirmed by direct policy-text inspection.
- `validate-legacy-notification-search-path-hardening.sql` — asserts 7 `notif_*`
  helper functions must have `proacl IS NULL` (never explicitly granted). They carry
  an *explicit* ACL that grants the exact same effective privileges (`anon`,
  `authenticated`, `service_role` all EXECUTE) — functionally identical to the
  default the validator expected, just recorded differently.

**1 of the 4 FAILs is a genuine, confirmed defect** — see §7 below.

## 6. Tasks module — schema and functional verification

**This was the highest-priority check**, since Tasks was reported missing before
this staging upgrade.

### Schema
6 of 7 named tables exist under those exact names (`tasks`, `task_assignments`,
`task_watchers`, `task_links`, `task_comments`, `task_number_sequences`).
`task_activity_events` does **not** exist as a distinct table — timeline/activity is
tracked through the same `audit_logs` table every other module in this codebase
already uses (`record_type = 'task'`), not a dedicated table. Two further tables
exist beyond what was asked for: `task_dependencies` and `task_relationships` (and
`task_dependency_waivers`), reflecting real functionality (dependency graphs,
cross-task relationships) not in the original checklist.

### Functions — real names differ from the assumed names
A rich, working set of task RPCs exists, but under different names than requested.
No function is missing functionality; the API surface is simply named per-module
rather than generically:

| Requested name | What actually exists |
|---|---|
| `task_access_level` | no direct equivalent — `can_view_task`/`can_manage_task` (booleans) serve this role |
| `assign_task_user` | `assign_task(p_task_id, p_user_id)` |
| `revoke_task_assignment` | `unassign_task(p_task_id, p_user_id)` |
| `set_primary_task_assignment` | no equivalent found — no "primary assignment" concept exists |
| `add_task_watcher` / `remove_task_watcher` | `watch_task(p_task_id)` (self-service) / `unwatch_task(p_task_id)` |
| `update_task_details` / `set_task_dates` | both folded into one `update_task(...)` RPC |
| `start_task` / `block_task` / `request_task_review` / `return_task_for_correction` | **no equivalents exist.** The real lifecycle is `draft → open → in_progress ↔ waiting → completed/cancelled` via `update_task(p_status := ...)`, enforced by `valid_task_status_transition()`. There is no "blocked," "in review," or "needs correction" state modeled anywhere. |
| `complete_task` / `cancel_task` | exist exactly as named |
| `link_task_record` / `unlink_task_record` | per-module functions instead: `link_existing_task_to_{entry,meeting,request,internal_collaboration,prisoner_letter}`, `unlink_task_from_{...}` |
| `add_task_comment` | exists exactly as named |
| `list_task_timeline` | no dedicated function — timeline is read from `audit_logs` directly |

This is a genuine naming/API-shape mismatch against the checklist used to write this
verification request, not a functional gap. If any other document or runbook
references the assumed names, it needs correcting to match what's actually deployed.

### Functional smoke test (rolled back — staging unmodified)
Run as one transaction using **real, distinct staging accounts** (not simulated
identities) — service numbers 10102 (supervisor), 10103 (staff, creator), 10104
(unrelated staff, later assignee), 10105 (HRCM-STG, cross-org), 10108 (super admin) —
plus a genuine anonymous (no-JWT) context. All 15 assertions passed:

1. Authorized task creation works.
2. Task number generated (`TSK-MCS-STG-2026-0001`).
3. Creator can view.
4. **Unrelated same-org user denied** (private-visibility task, not yet assigned) —
   both `can_view_task` and `can_manage_task` correctly `false`.
5. **Cross-org user denied** entirely.
6. **Same-org supervisor allowed** (view + manage), via the supervisor-or-above branch.
7. **Anonymous caller denied**, `can_view_task` returns `false` safely — no exception,
   correct for an RLS-composable function.
8. Assignment works; a cross-org assignment attempt is correctly rejected.
9. Assignment grants the assignee view + manage access.
10. Watcher (self-watch) works.
11. Full lifecycle transition works: `draft → open → in_progress → completed`, the
    final `complete_task` performed by the assignee (not the creator), proving
    assignees — not just creators — can legitimately manage a task.
12. An invalid post-completion transition is correctly rejected.
13. Timeline/activity evidence appears — 5 `audit_logs` rows for the one task
    (`created`, `assigned`, 2× `edited` for the status transitions, `completed`).
14. Anonymous `create_task` rejected.

Staging confirmed returned to its exact pre-test state afterward (0 rows across
`tasks`/`task_assignments`/`task_watchers`/task-scoped `audit_logs`).

**Tasks did not fail. Verification is complete and positive**, with the naming
caveat above.

## 7. CAP-002 — Workflow Engine

24 tables confirmed: `workflow_definitions`/`_definition_versions`, `workflow_instances`/
`_instance_steps`, `workflow_events`, `approvals`, `workflow_approval_rounds`/
`_positions`, `workflow_decisions`, `workflow_participants`, `workflow_tokens`,
`workflow_variables`, `workflow_work_items` (routing/gateway execution),
`workflow_delegations`/`_delegation_events`, `workflow_substitutions`/
`_substitution_events`, `workflow_sla_policies`/`_clocks`/`_clock_events`,
`workflow_business_calendars`/`_versions`, `workflow_escalation_policies`/`_levels`/
`_events`.

SLA/timer dispatch: `process_workflow_sla_due_batch` and the `workflow_sla_process_due_*`
functions exist and are correctly granted to `service_role` only (confirmed by the
validator sweep, file 13 — "dispatcher granted only to service_role... no
notification/cron/outbox wiring"). This is **by design**, not a gap: only one
pg_cron job exists on staging (`check-deadlines-daily`, unrelated legacy job); the
SLA dispatcher is meant to be invoked externally (e.g. a scheduled Edge Function or
external scheduler), not via `pg_cron`. 12 of 13 workflow validators passed cleanly
(§5's one benign FAIL was this subsystem's `pg_cron`-presence assertion).

## 8. Requests verification

19 server-authoritative RPCs confirmed present (`validate-requests-server-mutation-foundation.sql`,
PASS), 5 registered CAP-003 notification event types with atomic producers
(`validate-requests-notification-integration.sql`, PASS). Return-to-Sender and
bidirectionality logic covered by those same validators — no drift found.

**Direct-write closure — important nuance.** `requests`/`responses` retain their
pre-existing legacy RLS write policies (`requests_insert`, `requests_update`,
`requests_update_supervisor`, `requests_update_cancel`,
`requests_update_assigned_receiver`, `requests_update_section_receiver`,
`responses_insert`, `responses_update`, `responses_update_assigned_receiver`,
`responses_update_supervisor`) alongside the new RPCs. This is **by explicit design**,
not an oversight — `patch-requests-server-mutation-foundation.sql`'s own header
states: *"RLS on requests/responses is left completely intact — it remains the
backstop for any read and for any write path this milestone doesn't migrate."* The
RPCs migrate the audited, notification-triggering business mutations; RLS's own
narrowly-scoped checks remain as a fallback for whatever wasn't migrated. A raw
direct write through one of these legacy policies is authorization-safe (same org/
section/role checks RLS always enforced) but bypasses the RPC's audit-log and CAP-003
notification-outbox side effects. Flagged here because the verification request's
own "direct-write closure" phrasing implies full closure; the actual, documented
design intent is narrower ("RLS as backstop"). This is a documentation/expectation
mismatch worth a deliberate decision, not a silently-discovered defect.

## 9. Entry verification

12 mutation RPCs confirmed (`validate-entry-server-mutation-foundation.sql`, PASS), 4
notification event types with correct non-admin-bypass authorization on
`intent_user_can_view_entry` (`validate-entry-notification-integration.sql`, PASS).
Attachment branches for `external_correspondence`/`external_correspondence_reply`
confirmed restored and present in all 3 attachments policies (§10). Same
direct-write-closure nuance as §8 applies here — `patch-entry-server-mutation-foundation.sql`'s
header states the identical "RLS... left completely intact... remains the backstop"
design intent, confirmed by direct grep of the file.

## 10. Internal Collaboration verification

11 mutation RPCs confirmed (`validate-internal-collaboration-server-mutation-foundation.sql`,
PASS, "atomicity fix verified"), 5 notification event types, with the adapter
correctly *including* an admin/supervisor bypass where Entry's deliberately does not
(`validate-internal-collaboration-notification-integration.sql`, PASS — this
asymmetry is confirmed intentional per that validator's own expectations, not a
copy-paste inconsistency). Return-to-Sender and polymorphic parent behavior covered
by the same validator with no drift. Legacy direct-write policies (`internal_requests_insert`/
`_update`, `internal_request_replies_insert`/`_update`) are present on the underlying
tables, same as §8/§9.

## 11. Prisoner Letters verification

Server-mutation-foundation validator confirms "prisoner identity server-derived, row
locking, RLS matches Decision A" (PASS) — the six mutation RPCs enforce that **authority
cannot create** a letter (identity is server-derived, not client-asserted) and that
access is narrowed to `submitted_by`/`assigned_to` plus supervisor-or-above, exactly
as the attachments-policy inspection in §10/§12 independently confirms. 4 notification
event types confirmed with **no confidential letter content in payloads**
(`validate-prisoner-letters-notification-integration.sql`, PASS) — the
confidentiality-safe notification requirement holds. The attachment finalization lock
(delivered-status attachments cannot be deleted) is confirmed structurally present —
see §12.

## 12. Attachment authorization verification

The live `attachments` table's `select`/`insert`/`delete` RLS policies were read in
full and independently confirmed by the validator sweep
(`validate-attachments-authorization-restoration.sql`, PASS, "cross-org/unrelated-user
denial confirmed"). All 10 required record types are covered by both the table's own
CHECK constraint and every policy branch: `request`, `response`, `internal_request`,
`prisoner_letter`, `prisoner_reply`, `internal_reply`, `external_correspondence`,
`external_correspondence_reply`, `meeting`, `task`.

- **Valid users allowed / unrelated users denied / cross-org users denied**: confirmed
  structurally for every branch (each branch re-derives org/section/role from the
  parent record, not from the attachment row itself), and confirmed live in practice
  for `task` via §6's functional smoke test (which reuses the identical `can_view_task`/
  `can_manage_task` primitives the `task` attachment branches call).
- **Prisoner Letter delivered/final attachment delete remains denied**: confirmed
  directly in the policy source — both the `prisoner_letter` and `prisoner_reply`
  branches of `attachments_delete` require `pl.status <> 'delivered'`. Once a letter
  is delivered, no role can delete its attachments through this policy, full stop.

## 13. CAP-003 verification

All 4 tables confirmed (`platform_outbox_events`, `notification_intents`,
`user_notifications`, `platform_event_type_registry`), RLS enabled on all 4.
`user_notifications` has exactly 2 policies (SELECT/UPDATE, both scoped to
`auth.uid()`), zero INSERT/DELETE policies. `platform_outbox_events` and
`notification_intents` have **zero** policies at all — correct deny-by-default, not
an oversight, confirmed by direct negative testing:

- An ordinary authenticated user (10103) attempting a direct `INSERT` into
  `platform_outbox_events` got a genuine `permission denied for table
  platform_outbox_events` (no table-level GRANT exists for `authenticated`/`anon`).
- The same user attempting to `INSERT` into `notification_intents` got `permission
  denied for table notification_intents`.
- The same user attempting to call the worker RPC `process_platform_outbox_batch()`
  got `permission denied for function process_platform_outbox_batch` — confirmed
  `has_function_privilege('authenticated', ..., 'EXECUTE')` is `false` for both
  `authenticated` and `anon`.

Realtime: `validate-notification-realtime-legacy-cutover.sql` confirms RLS/grants
unchanged and Realtime publication membership correct for the legacy→CAP-003 cutover
(PASS). Recipient resolution and target-expansion (task watchers, meeting
participants) confirmed correct with the worker staying generic (no per-module
special-casing) — both PASS.

## 14. Realtime

Covered above in §13 — confirmed via `validate-notification-realtime-legacy-cutover.sql`
(PASS), no separate live-socket test was performed (no browser/HTTP access available
in this environment; see §18).

## 15. Security advisors

Ran `get_advisors(type='security')`: **404 total, 0 CRITICAL, 0 ERROR, 400 WARN, 4
INFO.**

- **370 of 400 WARNs** (`authenticated_security_definer_function_executable` /
  `anon_security_definer_function_executable`) are the expected, by-design shape of
  this entire codebase — every business RPC is `SECURITY DEFINER` and callable by
  `authenticated`, with its own internal `auth.uid()`/role checks. Not reported
  individually; this is architectural, not a finding.
- **28 `function_search_path_mutable`** — all 28 are trigger functions or plain
  validation/read helpers (`valid_*_status_transition`, `trigger_check_*_status`,
  `trigger_set_updated_at`/`_by`, `room_lock_key`, `meeting_effective_status`,
  `count_my_unread_notifications`, `list_my_notifications`, etc.) — **none are
  privilege-sensitive mutation RPCs**. Independently confirmed by
  `validate-security-definer-search-path.sql`: **278/278** `SECURITY DEFINER`
  functions in `public` correctly pin `search_path`, 0 unprotected. Worth a future
  hardening pass on these 28 helpers, not a blocking issue.
- **1 genuine confirmed DEFECT** (`table_privileges`, found via the Tasks validator
  agent, independently re-verified by direct `has_table_privilege()` query): the
  `authenticated` role holds raw `INSERT`/`UPDATE`/`DELETE` table grants on
  `task_relationships` — only `SELECT` is intended (its sibling table
  `task_dependencies` correctly has no such over-grant). **Currently mitigated**:
  exactly one `SELECT`-only RLS policy exists on `task_relationships`, no
  write policy, so an ordinary session cannot actually write through it today. This
  is defense-in-depth erosion, not a live exploit — but any future RLS
  misconfiguration would immediately expose unaudited writes bypassing
  `create_task_relationship`'s cycle-detection and authorization logic. **Recommend a
  small follow-up migration** (`REVOKE INSERT, UPDATE, DELETE ON task_relationships
  FROM authenticated;`) before treating this as fully hardened.
- **A related, same-class item found independently in this pass** (not in the
  validator's own checklist): `letter_reference_sequences` similarly has stray
  `INSERT` (and `SELECT`) grants for `authenticated`, with **zero** RLS policies of
  any kind. Same mitigation status (RLS's default-deny with no matching policy blocks
  everything today) and same recommendation (revoke the stray grants).
- **1 `extension_in_public`**: `btree_gist` is installed in the `public` schema;
  Supabase recommends a dedicated schema. Minor hygiene, not a security risk on its
  own.
- **1 `auth_leaked_password_protection`**: not enabled. Recommend enabling
  (HaveIBeenPwned check on new/changed passwords) — a Supabase Auth project setting,
  not a schema change.

No performance advisors were requested or reviewed, per the scope of this pass.

## 16. Login preservation

Zero writes were made to `auth.*` anywhere in this session. No password was reset.
Counts and orphan-linkage confirmed unchanged (§4). Existing staging login
credentials were not independently re-tested via the real Auth/HTTP flow — this
environment's outbound access to Supabase's own REST/Auth endpoints has been blocked
by session proxy policy since earlier in this engagement (unrelated to anything in
this pass); this is a re-confirmation of a pre-existing constraint, not a new one.

## 17. Frontend environment mapping

- **Committed default** (`js/config.js`, `index.html`'s CSP): both point to
  **production** (`https://infjjroktzzhaxjvfknr.supabase.co`), matching
  `config/environments/production.env`. This is intentional — production's own
  values are the tracked default.
- **Staging is reached only through a separate build pipeline**: a distinct
  Cloudflare Pages project (tracking `feature/corlink-platform-migration`, built via
  `scripts/build-cloudflare-staging.sh`) injects `CORLINK_SUPABASE_URL`/
  `CORLINK_SUPABASE_ANON_KEY` at build time from Cloudflare Pages CI environment
  variables — `config/environments/staging.env` is deliberately gitignored and never
  committed, and `scripts/build-cloudflare-staging.sh` refuses to build at all if
  `CF_PAGES_BRANCH` is `main`, specifically to prevent staging config ever silently
  applying to a production-tracked branch.
- **This session cannot confirm the live state of that Cloudflare Pages project.**
  The only Cloudflare tools available in this session (Workers, D1, KV, R2,
  Hyperdrive, docs search) do not cover Cloudflare Pages — no way to list the
  project, read its environment variables, check its last build status, or retrieve
  its deployment URL. This is the same gap identified earlier in this engagement
  (see `docs/30`), not new.

## 18. Exact staging test instructions / UAT question

**Can the user now open a frontend connected to `vjobntuyzymhcuanyeak` and test Tasks
+ the other current CorLink modules using existing login credentials?**

**No — not confirmable from this session.** The database side is fully ready (§4–§14).
The blocker is entirely on the frontend-deployment side, and it is the same blocker
already on record from earlier in this engagement:

1. This session has no Cloudflare Pages tool access, so it cannot confirm whether the
   staging Pages project's `CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY` are
   currently set to staging's values, whether a build has succeeded recently, or what
   URL that deployment is actually served from.
2. Until that's confirmed (either by enabling a Pages-capable connector for this
   session, or by an operator checking the Cloudflare dashboard directly and sharing
   the URL/status), there is no known-good staging URL to hand the user for testing.

Once a real deployment URL is confirmed pointed at `vjobntuyzymhcuanyeak` (verifiable
in-browser via DevTools → Network, confirming outbound calls target
`vjobntuyzymhcuanyeak.supabase.co`, not `infjjroktzzhaxjvfknr.supabase.co`), the
existing staging accounts (§4) should work for login — nothing in this pass touched
`auth.users`.

## 18a. Calendar route — observed state, not changed by this pass

Earlier in this engagement, `calendar`'s route was deliberately left inactive
(`route IS NULL`) pending a separate product decision, per the explicit rule that
route activation is not an automatic schema requirement. As of this pass,
`platform_modules` shows `calendar` with `route = 'calendar'`, `is_active = true` —
alongside `meetings` and `rooms`, both also active. **This verification pass did not
touch `platform_modules` and did not activate anything** — this is the state staging
was already in when this pass began, consistent with the full canonical chain
(which includes `patch-calendar-route-activation.sql`) having already been applied
before this pass started, per this task's own stated premise. This document cannot
confirm whether calendar's activation was itself a deliberate, reviewed product
decision or a side effect of applying the full chain in one sweep — that's worth
confirming with whoever ran the earlier deployment, but it is not a finding this
pass can respond to beyond reporting the observed state accurately.

## 19. Remaining blockers

1. **Frontend deployment status unconfirmable** (§17–§18) — the only real blocker to
   starting UAT.
2. **`task_relationships` / `letter_reference_sequences` over-grants** (§15) — low
   risk today (RLS blocks them regardless), but should be closed with a small
   follow-up migration before this is called fully hardened.
3. **"Direct-write closure" is narrower than the checklist assumed** (§8) — a
   decision point, not a defect: confirm whether the "RLS as backstop" design for
   Requests/Entry/Internal Collaboration/Prisoner Letters is acceptable as-is, or
   whether those legacy write policies should be dropped in a future patch.
4. **Multi-persona coverage is now much better than before, but not exhaustive.**
   This pass used 5 real distinct accounts across 2 orgs (creator, unrelated same-org
   staff, same-org supervisor, cross-org user, super admin) plus genuine anonymous —
   a real improvement over the single-super-admin state earlier in this engagement.
   It did not exercise every persona×module combination (e.g., an org admin's own
   distinct authority boundary, or a second HRCM-STG user acting as an "authorized
   participant" on a task/meeting) — those remain open for full UAT.
5. **SLA/escalation timer dispatch has no confirmed external scheduler.** The
   dispatcher functions exist and are correctly `service_role`-gated (§7), but this
   pass found no evidence (Edge Function, external cron, etc.) of what actually
   invokes them on a schedule in this environment. Not a defect — by design, `pg_cron`
   is not used for this — but worth confirming an actual invocation path exists
   before relying on SLA/escalation behavior in production.

## 20. Production GO/NO-GO

**Staging: GO for continued UAT, once the frontend-deployment blocker (§18) is
independently resolved.** The database layer — schema, functions, RLS, CAP-002
Workflow, CAP-002 Tasks, CAP-003 Notification Outbox, and all four core modules — is
structurally sound and functionally verified to the extent this environment allows.

**Production: NO-GO — not evaluated in this pass and not implied by it.** This
document verifies staging only. Production (`infjjroktzzhaxjvfknr`) currently
contains none of this chain (per the earlier Production Platform Migration Inventory
in this engagement) and requires its own separate runbook execution, its own
pre-deployment checks, and separate approval — none of which this pass performed or
authorizes. Before that runbook is executed, this pass recommends: (a) closing the
two over-grant findings in §15, (b) a deliberate decision on the direct-write-closure
question in §8, and (c) resolving the frontend-deployment visibility gap in §17 so
that whatever staging UAT is still open (§19 item 4) can actually happen first.
