# Supabase Auth Configuration — CorLink

## 1. Create Supabase Project
1. Go to https://supabase.com → New project
2. Name: `corlink-production` (or `corlink-dev` for dev)
3. Region: nearest to Maldives (Singapore recommended)
4. Save the **Project URL** and **anon key** → paste into `js/config.js`

## 2. Run SQL Files in Order
In the Supabase SQL editor (if you already ran an earlier version, run `reset.sql` first):
1. `supabase/reset.sql` — only needed if re-running after schema changes
2. `supabase/schema.sql`
3. `supabase/rls.sql`
4. `supabase/seed.sql`
5. `supabase/security-functions.sql` — server-side login lockout + audit logging RPCs
6. `supabase/create-super-admin.sql` — creates the initial super admin account
7. `supabase/storage-policies.sql` — org-logos bucket access (run after creating the buckets in step 5 below)
8. `supabase/notifications.sql` — notification lookup RPCs + the daily overdue-request check (needs the pg_cron extension — see step 6 below)

If you already ran an earlier version of `schema.sql`/`rls.sql`, run whichever of these
match what changed since, instead of re-running the full files:
- `supabase/patch-user-assignments-scope.sql` — user_assignments command/department/
  division-level scoping
- `supabase/patch-phase3-requests-rls.sql` — requests/approvals/attachments RLS fixes
- `supabase/patch-phase4-prisoner-letters-rls.sql` — prisoner_letters/prisoner_replies RLS fixes
- `supabase/patch-org-scope-admin.sql` — adds 'organization' as a user_assignments scope
  level, so an org's first admin can be created before it has any structure
- `supabase/patch-designations.sql` — adds the designations table (org-managed job
  titles/positions) and users.designation_id
- `supabase/patch-phase6-workflow.sql` — requests/responses read receipts, internal
  section-to-section collaboration, conversation threading, assigned_receiver
  permissions — run this AND re-run `supabase/storage-policies.sql` (it now also
  covers the `attachments` bucket, which needs creating first — see step 5 below)
- `supabase/patch-cross-org-names.sql` — lets a user resolve the name/designation of
  someone in the OTHER organization on a request/response/approval/prisoner letter
  they can already see (fixes names showing as "Unknown")
- `supabase/patch-independent-lang-edit.sql` — adds `subject_language` (subject and
  body can now be written in different languages) and fixes `requests_update`/
  `responses_update` RLS so a draft stays editable through `pending_approval`, not
  just before submitting (also fixes a pre-existing bug where "Submit for Approval"
  always failed RLS)
- `supabase/patch-internal-workflow.sql` — internal collaboration gets the full
  external-style lifecycle: assign-to-staff on internal requests, and replies now go
  draft → submit for approval → supervisor approves & sends (draft/pending replies
  are hidden from the asking section until sent)
- `supabase/patch-review-comments.sql` — Word-style review comments on drafts
  awaiting approval (supervisor quotes a passage + note; drafter resolves and
  resubmits)
- `supabase/patch-prisoner-letters-v2.sql` — prisoner registry (searchable dropdown
  source for letters), letter read receipts, per-letter PL- reference numbers, and
  attachments on letters/replies — also re-run `supabase/storage-policies.sql` OR this
  patch (it updates the storage insert policy's allowed folders too)
- `supabase/patch-prisoner-registry-section.sql` — restricts adding/editing the
  prisoner registry to a designated section (configurable per-org, same shape as
  Default Receiving Section — falls back to any org member if left unset), and
  closes a gap where an authority-org member could insert a prisoner_letter directly
  via the API despite the compose button being hidden for them — letters can now
  only ever be created MCS -> authority
- `supabase/patch-approvals-visibility-fix.sql` — fixes `approvals_select`, which
  previously only let the reviewer, any org's admin (unscoped), or the record's
  literal creator see an approval row — hiding the "approved by [Supervisor]" banner
  from the receiving organization's supervisors/section members. Now mirrors
  requests_select/responses_select's visibility shape exactly.
- `supabase/patch-cc-recipients.sql` — adds "Loop In Staff": a same-org, read-only
  CC list on a specific request or response, picked at compose time (New Request,
  Follow-up, Draft Response). New `cc_recipients` table + policies, plus additive
  visibility grants on `requests`/`responses`/`attachments` for whoever's CC'd.
- `supabase/patch-internal-collab-audit-visibility.sql` — fixes
  `can_view_case_audit_record()`, which had no branch at all for
  `record_type = 'internal_request'` — the Internal Collaboration panel's new
  routing-history timeline (received/routed/received/assigned across a
  re-route) would have silently shown nothing to anyone, including the
  internal request's own creator or section members.
- `supabase/patch-internal-collab-deadline.sql` — adds `internal_requests.deadline`
  and enforces (server-side, in `internal_requests_insert`) that it can't be later
  than the parent request's own deadline.
- `supabase/patch-internal-reply-attachments.sql` — adds a new `internal_reply`
  attachments record type (mirroring `internal_request_replies_select`'s own
  visibility shape) so a Draft Reply in Internal Collaboration can attach files,
  same as every other draft/compose flow in the app.
- `supabase/patch-missing-indexes.sql` — adds indexes on
  `internal_requests.parent_request_id`, `internal_request_replies.internal_request_id`,
  `review_comments(record_type, record_id)`, and `cc_recipients.user_id` — none of
  these had one, so every request-detail page load did a full table scan per
  internal request/reply/comment lookup (RLS re-evaluates its policy per scanned
  row, making this worse as the tables grew), eventually tripping Postgres's
  statement_timeout ("Couldn't load this request: canceling statement due to
  statement timeout"). Run this one now if you're seeing that error.
- `supabase/patch-narrow-supervisor-visibility.sql` — a plain supervisor
  previously saw every request/response their org was party to, regardless
  of section, via a blanket `is_supervisor_or_above()` term in
  `requests_select`/`responses_select`/`approvals_select`/`can_view_request_
  or_response()` — including still-unrouted mail. Narrowed to `is_admin()`;
  a supervisor's visibility now comes from the same section/creator/
  received_by branches every other staff member relies on, plus the
  separate additive Loop-In-Staff/assigned-receiver policies. Also fixes a
  real cross-org bug found along the way: `attachments_select` had a bare
  `OR is_supervisor_or_above()` with no org check at all, letting a
  supervisor in ANY organization see attachments belonging to a completely
  unrelated org's request/response. Verified against a real local Postgres
  instance (two sections, two section supervisors, one org admin, one
  CC'd staffer): the same-section supervisor and admin still see the
  request/its approvals/its attachments, the other section's supervisor no
  longer does, and the CC'd staffer still does via the unrelated CC policy.
- `supabase/patch-audit-integrity.sql` — `audit_insert` previously only
  checked `auth.uid() IS NOT NULL`, letting any authenticated user forge an
  audit_logs row with an arbitrary `user_id` via a direct REST call (e.g.
  "approved by [someone else]"). Now requires `user_id = auth.uid()` —
  every real call site already sets this, so no legitimate use breaks.
  Verified against a real local Postgres instance: a forged insert
  (different user_id than the caller) is rejected; a self-attributed
  insert still succeeds.
- Re-run `supabase/storage-policies.sql` (it's idempotent, safe to re-run
  anytime) — two fixes: (1) the `attachments` bucket's Storage INSERT
  policy was missing `'internal_reply'` from its allowed-folder list, so
  every attachment upload on a Draft Reply in Internal Collaboration has
  been silently failing since that feature shipped; (2) sets
  `file_size_limit`/`allowed_mime_types` server-side on the `attachments`
  and `org-logos` buckets, matching the client-side checks already in
  `attachments-api.js` — closes the gap where a direct Storage API call
  could bypass those checks entirely.
- `supabase/patch-workflow-transitions.sql` — RLS gates WHO can update a
  request/response, but nothing previously stopped a legitimately-
  authorized supervisor's UPDATE from jumping the `status` column
  straight from `draft` to `sent` via a direct API call, skipping the
  approvals-table record of who actually reviewed it. Adds a
  `BEFORE UPDATE OF status` trigger on both tables validating every
  transition against the exact set `js/data/requests-api.js` actually
  uses. Verified against a real local Postgres instance: the full
  legitimate chain, the return-for-correction loop, and the `overdue`
  overlay all still work; a direct `draft` → `sent` skip and a
  `closed` → `draft` reversal are both rejected; a non-status UPDATE
  doesn't invoke the trigger at all.
- `supabase/patch-prisoner-letters-staff-flag.sql` — restricts the whole
  Prisoner Letters module (menu, letters, replies, their attachments, and
  registry search) to staff individually designated for that duty
  (`users.is_prisoner_letters_staff`, granted per-user via Admin > Manage
  User) — previously any org member could see the menu, and the
  submitter/assignee/any-supervisor visibility shape every other module
  uses applied here too. This is a deliberate exception to that shape:
  there's **no** automatic bypass for supervisors/admins — someone in
  either role who isn't personally flagged gets no access at all, not
  even to letters they'd otherwise be a supervisor over. **Run this, then
  immediately grant the flag to whoever should actually handle prisoner
  letters (Admin → Users → Manage → Prisoner Letters Access) — until you
  do, nobody in the organization can use this module, admins included.**
  Verified against a real local Postgres instance (two orgs, one flagged
  + one unflagged staffer + one unflagged supervisor on each side):
  flagged staff see/insert/update/reply correctly; unflagged staff and
  unflagged supervisors alike see zero letters and are rejected on every
  insert/update/reply attempt; the patch file was applied twice with zero
  errors (idempotent) and produces identical results whether run against
  a fresh schema or migrated onto the pre-existing (unpatched) RLS shape.
- `supabase/patch-entry-module.sql` — adds the **Entry** module: a new
  `external_correspondence` / `external_correspondence_replies` pair of
  tables for requests/letters/complaints that arrive from OUTSIDE the
  CorLink network entirely (the general public and prisoners' families
  writing to a public inbox like `info@corrections.gov.mv` or by post,
  other government offices that are NOT registered CorLink
  organizations, and written complaints prisoners hand in directly).
  Unlike `requests`, there's no `from_org_id`/`to_org_id` — none of
  these senders have a CorLink account. A staff member in the org's
  designated Entry section (`organizations.entry_section_id`, configured
  the same way as Default Receiving Section / Prisoner Registry Section
  via Admin → Organization Settings → **Entry Section**) logs what
  arrived and routes it to whichever internal section is responsible for
  responding; that section drafts a reply (draft → pending_approval →
  sent, same shape as Internal Collaboration replies) which CorLink
  keeps as the file copy — staff still send it back to the original
  sender themselves (email/post/etc), then mark it delivered here.
  Same never-breaks-on-upgrade shape as the other two designated-section
  settings: leave `entry_section_id` unset and any staff member in the
  org can log/route entries, same as before this module existed.
  Extends `attachments`/`audit_logs`/`notifications` CHECK constraints
  and the Storage bucket's upload folder allowlist (also update
  `supabase/storage-policies.sql` if you run that file separately from
  this patch). **Run this, then decide whether to designate an Entry
  section** (Admin → Organization Settings) — until you do, any staff
  member in the org can use the module, matching the pre-designation
  fallback the other two settings already use.
- `supabase/patch-rls-scope-indexes.sql` — if `patch-missing-indexes.sql`
  above didn't fully fix a recurring "Couldn't load this request:
  canceling statement due to statement timeout," this is the deeper
  cause: `scope_section_ids()` (the function every RLS scoping helper —
  `my_section_ids`/`my_supervised_section_ids`/`has_role_in_section` —
  calls to expand a command/department/division/organization-level
  assignment down to its concrete sections) had no index to seek
  `sections` by `department_id`/`division_id`/`org_id`, so it fell back
  to a full table scan for any assignment not scoped directly at the
  section level — most notably org-wide admin grants (scope_type
  `'organization'`). Because these RLS helpers are `SECURITY DEFINER`
  (required to avoid RLS-recursion against `user_assignments`), Postgres
  can't hoist or cache that scan across separate calls, so it re-runs
  fresh for every row a query's RLS check touches — a case with a long
  audit/routing history multiplies this badly enough to trip the
  timeout on its own, independent of the first indexes patch. Adds
  indexes on `sections(department_id)`, `sections(division_id)`,
  `sections(org_id)`, and `departments(command_id)`. Also paired with
  an app-code fix (already shipped) that narrows
  `RequestsAPI.listCaseAuditTrail` to the specific audit actions
  request-detail.js actually renders instead of fetching (and
  RLS-evaluating) every action ever logged for a case, including a
  whole `response`-side query that was never even used.
- `supabase/patch-return-to-sender.sql` — lets a wrongly-routed section
  send an external request back to whoever routed it there — one hop
  back (`requests.previous_section_id`, trigger-maintained), not a
  fixed org default — so it naturally supports ping-pong if it gets
  misrouted again. Internal Collaboration gets the equivalent for free
  (`internal_requests.from_section_id` was already a permanent pointer)
  with no schema or RLS change on that side. New `returned_to_sender`
  audit action, kept distinct from the pre-existing `returned` (draft-
  rejection) action so the two show up as separate, distinguishable
  events in the case timeline.
- `supabase/patch-cancel-request.sql` — lets the sender pull a request
  back any time before a response has actually been sent (the original
  creator, or a supervisor of the sending section). New `'cancelled'`
  status (terminal, like `closed`) blocks further responses and
  Internal Collaboration on that case at the database level, not just
  in the UI. Bundles two incidental fixes found necessary while making
  `'cancelled'` reachable (same pattern as `patch-narrow-supervisor-
  visibility.sql`'s own incidental cross-org fix): (1)
  `requests_update_supervisor` had no `WITH CHECK` at all, which would
  have let a RECEIVING-org supervisor cancel a request too — added a
  `WITH CHECK` that only restricts the new `'cancelled'` outcome, every
  other transition through that policy is untouched; (2)
  `check_deadlines()`'s nightly cron had no transition edge out of
  `'cancelled'`, so the first cancelled-and-overdue row it hit would
  `RAISE EXCEPTION` and abort the entire nightly run for every other
  request that day — added `'cancelled'` to its exclusion list (this
  patch re-applies that fix so a live DB that only runs patch files
  still gets it). Safe to run before or after
  `patch-return-to-sender.sql` — both converge on the same final
  `audit_logs.action` CHECK list.
- `supabase/patch-fix-routing-rls-visibility.sql` — fixes "new row
  violates row-level security policy for table requests" when a
  section-scoped supervisor routes or returns a request away from
  their own section. Root cause (isolated by replicating the reporting
  org's exact data on a local Postgres and bisecting policies):
  Postgres re-checks the post-UPDATE row against the table's **SELECT**
  policies on any UPDATE that reads columns — a WHERE clause alone is
  enough, no RETURNING needed — so the very act of handing a case off
  to a section the actor can't see aborted the hand-off itself. Fix:
  the SELECT policies now include the trigger-maintained
  `previous_section_id`, keeping the section that just handed a case
  off visible to itself (one hop of history, overwritten on the next
  move). Also fixes two more bugs found in the same investigation:
  (1) `internal_requests_update`'s cancelled-parent EXISTS (from
  `patch-cancel-request.sql`) referenced `parent_request_id`
  unqualified — the same column-shadowing trap already documented on
  `internal_requests_insert` — silently breaking EVERY internal-
  collaboration update (Mark Received/Assign/Reroute/Close/Return);
  (2) internal_requests needed its own `previous_section_id` +
  explicit WITH CHECK so a plain member's Return to Sender doesn't
  self-reject. Also reverts `patch-fix-section-receiver-supervisor-
  conflict.sql`'s WITH CHECK loosening — verified empirically that
  permissive policies' WITH CHECKs are OR'd, so that change was inert
  and the original narrow rule is restored. **Run this even if you ran
  every earlier patch — it supersedes the section-receiver one.**
- `supabase/patch-protect-user-privilege-columns.sql` — closes a self
  privilege-escalation gap: `users_update_own_prefs`
  (`id = auth.uid()`) and `users_update_admin` both have USING but no
  WITH CHECK, and RLS only restricts which ROW an UPDATE can touch, not
  which COLUMNS change on it. Concretely, any authenticated user could
  PATCH their own row with `{"is_super_admin": true}` (or
  `org_id`/`is_active`/`is_prisoner_letters_staff`) via
  `users_update_own_prefs` — still just `id = auth.uid()` on both
  sides — and self-escalate to super admin; an org admin could do the
  same to any user in their own org via `users_update_admin`, including
  granting super-admin, a privilege the app's own UI never grants (it's
  only ever set by the one-time `create-super-admin.sql` script). A
  WITH CHECK addition can't fix this — Postgres RLS's WITH CHECK can't
  compare OLD vs NEW in one expression, it only sees the post-update
  row — so this adds a `BEFORE UPDATE ON users` trigger instead, same
  pattern as the existing status-transition guards on
  requests/responses/external_correspondence. Two tiers, matching what
  the app's admin UI actually does today: `is_active`/
  `is_prisoner_letters_staff` stay reachable by any `is_admin()` (org
  admins legitimately toggle these on their own org's users);
  `is_super_admin`/`org_id` are restricted to `is_super_admin()`
  specifically, since no UI flow ever touches them. Verified against a
  real local Postgres instance (a super admin, an org admin, and two
  regular staff, one org): a staffer's self-PATCH to `is_super_admin`
  is rejected while their own harmless self-update (password/name)
  still succeeds; an org admin's `is_active`/`is_prisoner_letters_staff`
  toggle on another org member still succeeds (matches `admin.js`)
  while their attempt to grant super-admin or reassign a user's org is
  rejected; a super admin's own super-admin grant still succeeds.
  (Also observed, unrelated to this patch: `users_select_same_org`
  having no `is_super_admin()` bypass means a super admin's `org_id`
  reassignment is independently blocked by Postgres re-checking the
  post-UPDATE row against SELECT policies — same class of bug as
  `patch-fix-routing-rls-visibility.sql`'s `requests` finding. Not
  fixed here since nothing in the app ever reassigns `org_id`, and it
  only makes that column stricter, never weaker.)
- `supabase/patch-lock-attachment-delete.sql` — `attachments_delete`
  previously only checked `uploaded_by = auth.uid()`, with no lock/
  editability check at all, unlike `attachments_insert` (which blocks
  new uploads once the parent record is locked/sent/closed). That let
  an uploader delete their own attachment from a request or response
  AFTER it had been approved and sent (or an internal reply/Entry
  record after it left draft), silently removing a file from what's
  supposed to be an immutable case record — a real evidence-integrity
  gap for a correctional-service correspondence system. Now mirrors
  `attachments_insert`'s own per-`record_type` editability conditions
  exactly (request/response: only while `is_locked = FALSE`; internal
  reply/Entry reply: only while draft/pending_approval; Entry record:
  only while not closed; internal_request/prisoner_letter/
  prisoner_reply: same org/section conditions as insert, matching
  insert's own lack of a lock concept on those). Verified against a
  real local Postgres instance: deleting your own attachment on a
  still-draft request succeeds; deleting your own attachment on a
  locked/sent request now deletes 0 rows.
- `supabase/patch-participant-column-indexes.sql` — third and (measured)
  final root cause behind the recurring "Couldn't load this request:
  canceling statement due to statement timeout" on the request-detail
  page. The two earlier timeout patches (`patch-missing-indexes.sql`,
  `patch-rls-scope-indexes.sql`) narrowed candidate rows and sped up the
  section-hierarchy expansion; this one fixes a *different* cost that
  scales linearly with total data volume — which is why the timeout kept
  returning as history accumulated. Every embedded `users(...)` name
  resolution on the page makes Postgres apply `users_select_correspondence`,
  whose body does `EXISTS (SELECT 1 FROM requests WHERE created_by =
  users.id OR assigned_to = users.id OR received_by = users.id ...)` — and
  the same OR-of-participant-columns shape against responses/approvals/
  prisoner_letters/prisoner_replies. None of those participant columns
  were indexed, so each EXISTS was a full sequential scan of the table,
  re-run once per user resolved and getting slower as the table grew.
  Adds a single-column index on each so Postgres BitmapOrs index scans
  instead. Indexes only — no behavior change. Verified against a
  5,000-request / 30,000-audit_logs local dataset: one cross-org user
  resolution dropped from a 12,973-cost sequential scan on `requests` to
  a 424-cost bitmap index scan (and the latent `responses` branch from
  251,269 to 5,118). Idempotent (`IF NOT EXISTS`). Note: `CREATE INDEX`
  briefly locks writes on each table — run in a quiet window, or use
  `CREATE INDEX CONCURRENTLY` (which can't run in the patch's transaction
  block) if that matters for your deployment.
- `supabase/patch-deadline-time.sql` — gives request deadlines a time of
  day. Widens `requests.deadline` and `internal_requests.deadline` from
  `DATE` to `TIMESTAMPTZ` so a deadline can be, e.g., "due 2026-07-20
  16:30". The compose/edit forms now show a 24-hour time input next to the
  date/days input; a date entered without a time defaults to 12:00 (noon).
  Overdue is now keyed off the exact instant rather than end-of-day, both
  in the UI (`new Date(deadline) < now`) and in `check_deadlines()` — so
  **re-run `supabase/notifications.sql`** too, which now compares
  `deadline < NOW()` (was `< CURRENT_DATE`) and formats the deadline with
  its time in the overdue notification. Existing date-only rows migrate to
  12:00 Maldives time (UTC+5), matching the noon default, so nothing
  silently becomes due at 00:00. The patch is idempotent — each `ALTER` is
  guarded to fire only while the column is still `DATE`. `prisoner_letters.
  deadline` and `deadline_extensions.new_deadline` are intentionally left
  as `DATE` (no UI surfaces a time for them).
- `supabase/patch-internal-and-letters-indexes.sql` — a scalability audit
  found `internal_requests` and `prisoner_letters` had the same missing-
  index gap `patch-participant-column-indexes.sql` fixed on
  requests/responses, just not yet triggered on these smaller tables.
  `internal_requests_select`'s RLS and `listOutstandingForSections`/
  `listAssignedToUser` (`internal-requests-api.js`) filter directly on
  `from_section_id`/`to_section_id`/`status`/`assigned_to`/`created_by`/
  `previous_section_id` — only `parent_request_id` was indexed.
  `prisoner_letters.listInbox` filters on `to_org_id`, which also had no
  index (`from_prison_id`, `listSent`'s own filter, already did). Indexes
  only — no behavior change. Idempotent (`IF NOT EXISTS`). Verified
  against a local Postgres instance: all 7 indexes created on first run,
  second run a clean no-op.
- Request-detail's Realtime subscription (`js/views/request-detail.js`,
  `_subscribeRealtime`) is now filtered to the specific case being
  viewed instead of subscribing unfiltered to all 4 tables. The previous
  version relied on "Realtime only delivers rows my RLS lets me SELECT"
  for correctness, which is true but not free — an unfiltered
  `postgres_changes` subscription evaluates RLS for every write on those
  tables *anywhere in the org* against every open request-detail tab,
  which doesn't scale with concurrent viewers. `filter: id=in.(...)` (built
  from the case's request/internal-request ids, since a case spans
  multiple `requests` rows via `parent_request_id` chaining) narrows what
  reaches the RLS check at all, with no visibility change — filters apply
  in addition to RLS, not instead of it. Re-subscribes on every reload
  (not just page load) so a round or loop-in added mid-session gets
  covered by the next subscription. One known, narrow tradeoff: a reply
  added to an internal request that was *itself* created in the same
  viewing session, before any reload, won't trigger its own toast (the
  internal request's own creation already did). No SQL involved — pure
  client-side change.
- Capped 5 more previously-unbounded list functions at INBOX_LIST_CAP,
  same fix/reasoning as RequestsAPI.listInbox/listSent: `PrisonerLettersAPI.
  listInbox/listSent`, `EntryAPI.listAll/listUnrouted/listForSections`,
  `InternalRequestsAPI.listOutstandingForSections/listAssignedToUser`, and
  `RequestsAPI.listStaffWorkload`. Each now returns `{ items, totalCount }`
  instead of a bare array — every call site (Prisoner Letters Inbox/Sent,
  the Entry module's "All Entries" view, the Requests page's Info Requests
  tab and Team tab, and the dashboard's Internal Collaboration rows)
  updated to match, with a "showing most recent N of M" hint wherever a
  list is actually truncated. No SQL — pure client-side change.
- `supabase/patch-action-needed-counts-rpc.sql` — new
  `requests_action_needed_counts()` RPC. The Requests nav badge (shown on
  every page) and the Requests page's own Inbox/Sent/Info tab badges used
  to compute their "needs my action" totals by fetching the (now-capped)
  inbox/sent/info lists into the browser and counting matches in JS — this
  does the counting in Postgres instead, via a single lightweight query,
  so the number stays exact regardless of any list's cap. The SQL is a
  verbatim port of the exact predicates `_inboxViews`/`_sentViews`'
  `needs_action` test already uses (js/views/requests.js) — those tab
  chips/filters still use the JS version against the fetched list, so if
  either one ever needs to change, the other must change with it (see the
  function's own comment in rls.sql). SECURITY INVOKER (not DEFINER) —
  runs under the caller's own RLS, same as a normal query. Verified
  against a local Postgres instance with a hand-built dataset covering
  every branch of both predicates across 4 roles (plain staff, section
  supervisor, org-wide admin, assigned_receiver-only) — every count
  matched a manual row-by-row check. Idempotent (`CREATE OR REPLACE`).
- `supabase/patch-internal-collab-freeze-on-close.sql` — `internal_requests_
  insert`'s WITH CHECK only blocked starting a brand-new "Loop in a
  Section" round on a `cancelled` case; a `closed` or `responded` case
  still let the assignee start one, despite there being no more work
  left to do. The button was visible in the UI on a closed case (real
  gap, not cosmetic) — now blocked for `cancelled`/`closed`/`responded`
  alike. Narrower than `internal_requests_update` on purpose: an
  internal_request already IN FLIGHT when the case reaches one of these
  statuses stays updatable there so it can still be finished — only
  starting a NEW one is blocked. `request-detail.js`'s `canStart` gate
  updated to match (UI courtesy; RLS is the real gate). Verified against
  a local Postgres instance: INSERT allowed on sent/received/in_progress/
  overdue, rejected on cancelled/closed/responded. Idempotent (`DROP
  POLICY IF EXISTS` + `CREATE POLICY`).
- `supabase/patch-entry-multi-section.sql` — Entry can now be logged by
  MORE THAN ONE section per org. Replaces `organizations.entry_section_id`
  (a single nullable FK) with a new join table, `entry_sections`
  (backfilled from the old column, which is then dropped), and rewrites
  `is_entry_staff()`/`update_org_workflow_settings()` to match. Admin's
  Entry Section picker is now a checkbox list instead of a single
  dropdown. Verified against a local Postgres instance: a section not in
  `entry_sections` cannot log an entry; a section in it can; the
  org-wide fallback (zero rows configured) still works. Idempotent.
- `supabase/patch-entry-review-comments.sql` — extends the existing
  review-comment mechanism (already used for request/response drafts and
  internal-collaboration replies) to Entry replies too: a supervisor can
  now leave a comment before approving a reply to external
  correspondence, same force-resolve-before-resubmit UX as elsewhere.
  Just a new `'entry_reply'` `record_type` branch on the existing
  `review_comments` table/policies — no new table. Verified: a
  non-supervisor is blocked from commenting; the responding section's
  supervisor can. Idempotent.
- `supabase/patch-internal-collab-polymorphic-parent.sql` — Internal
  Collaboration ("Loop in a Section") now works for Entry too: the
  section holding an entry can ask another section for information
  while keeping ownership of the entry itself, exactly like it already
  works for external requests. `internal_requests`/`internal_request_
  replies` are generalized to anchor to EITHER a request
  (`parent_request_id`) OR an entry (`parent_entry_id`, new column) —
  exactly one, enforced by a new CHECK constraint — rather than
  duplicating a parallel table pair. Two real bugs were caught by
  validation and fixed in the same patch, not shipped and found later:
  (1) `internal_request_replies_insert`/`_update` used to INNER JOIN
  `requests` to check the parent wasn't cancelled — once
  `parent_request_id` can be NULL for an entry-anchored row, that join
  silently matched zero rows, which would have blocked every reply to
  an entry-anchored loop-in. Fixed by routing the check through a new
  `internal_requests_parent_not_frozen()` helper instead of an inline
  join. (2) A section looped in via an entry-anchored `internal_requests`
  row had no RLS path to see the parent entry itself — the same gap
  `patch-internal-collab-request-visibility.sql` already fixed on the
  requests side; mirrored here as
  `external_correspondence_select_via_internal_collab`. A third helper,
  `internal_requests_parent_deadline_ok()`, casts the candidate deadline
  to a bare date before comparing against `external_correspondence.
  deadline` (a `DATE` column, unlike `requests.deadline`'s `TIMESTAMPTZ`)
  — a direct comparison would have implicitly cast the DATE to midnight
  and wrongly rejected a same-day deadline at any time later than 00:00.
  Also adds the entry-detail.js UI for this (Internal Collaboration
  panel, Loop In modal, reply thread) and an Entry-specific Info
  Requests tab; `requests.js`'s own Info Requests tab and dashboard's
  Internal Collaboration rows are now filtered to request-anchored rows
  only, so each module's queue stays scoped to its own domain even
  though the underlying table/API is shared. Verified against a local
  Postgres instance, both against a fresh full schema AND against the
  actual pre-patch schema (simulating a real upgrade): both bugs
  confirmed fixed, the deadline-cast fix confirmed on a same-day/
  later-time case, a day-after-deadline case still correctly rejected,
  and an unrelated section confirmed still unable to see the entry.
  Idempotent.
- `supabase/patch-entry-received.sql` — adds `received_by`/`received_at`
  to `external_correspondence`: once an entry is routed, the receiving
  section can explicitly mark it as received (same receipt shape as
  requests/responses/internal_requests), and that shows up in the
  Activity Log with staff name + timestamp. Distinct from the
  pre-existing `received_date`, which just records when the
  correspondence itself arrived. No RLS changes — `external_
  correspondence_update_section` already grants the receiving section
  unrestricted UPDATE. Also: the "Routed" activity-log line now names
  the destination section instead of a generic "to section"; the
  Internal Collaboration panel moved to render below the Logged Entry
  thread instead of above it; the Logged Entry's own upload box now
  hides once the entry leaves `logged` status; and the Entry reply
  approval line now uses the same green `.thread-approval--approved`
  banner style as Requests. Idempotent.
- Entry's Internal Collaboration panel brought to full UI parity with
  Requests' own (per-row next-step banner, Route to Another Section,
  Return to Sender, review comments + Edit Draft on internal replies,
  comment-capture on approve/return, supervisor picker on submit,
  primary-action highlighting) — no schema/RLS changes, the underlying
  `internal-requests-api.js` functions and `review_comments` RLS were
  already parent-agnostic.
- `supabase/patch-entry-staff-scope.sql` — fixes a real RLS bug:
  `is_entry_staff()` used to OR in `is_supervisor_or_above()` unscoped
  by section, so every supervisor/admin in the org could see (and, via
  the policies that gate on `is_entry_staff()`, manage) every logged
  entry regardless of section — reported as "all the entry is visible
  to all the supervisors." Fixed by dropping that clause entirely;
  visibility is now: a member of one of the org's designated
  `entry_sections` (or any org member when none are configured yet,
  same fallback as before), OR — unchanged, via `external_
  correspondence_select`'s other branches — the entry's `to_section_id`
  member, the assigned staff member, or whoever logged it. Verified
  against a local Postgres instance: an unrelated supervisor (not in
  any entry section, not the to_section, not assigned, not the
  logger) went from seeing a routed entry (bug reproduced against the
  old function) to correctly getting zero rows after the fix, while an
  entry_sections member and the to_section member both still see it.
  Idempotent.
- Also this round: `_renderProcessEvents`'s audit-action allowlist was
  missing `'received'` (added in the patch above), so "Marked as
  Received" never actually showed up in the Activity Log despite being
  recorded — fixed. An "Edit Draft" action was added for the Logged
  Entry itself, available only while `status = 'logged'` (before
  routing) — `EntryAPI.updateDraft()`, no RLS change needed since
  `external_correspondence_update_entry` already allows entry staff to
  update any column. The "Not visible outside this organization" badge
  was removed from Entry's Internal Collaboration panel — meaningless
  there since, unlike Requests, Entry has no cross-org counterpart to
  hide anything from. Dashboard's Internal Collaboration "Action
  Needed" rows were scoped to request-anchored `internal_requests`
  only; added the missing entry-anchored equivalent (same buckets,
  linking to `#entry?tab=info` instead of `#requests?tab=info`) — a
  section looped in on an entry previously saw nothing on their
  dashboard at all, not even once received.
- Entry deadline is now set when assigning a staff member (Assign
  Staff modal), not only at logging time — reuses the same
  days/date/time picker and `external_correspondence.deadline` column,
  just a second entry point for it (`EntryAPI.assign()` now takes a
  `deadline` argument). The Entry list also gained a Deadline column
  with the same overdue/due-soon badge Requests already has
  (`RequestsView._deadlineCell`) — no schema/RLS change, `deadline`
  already existed. A reply's attachment upload box now hides once it's
  submitted for approval (was staying visible through
  `pending_approval`, `canUpload` now requires `status === 'draft'`).
- `supabase/patch-entry-reply-returned-approval.sql` — fixes a real
  gap: `EntryAPI.returnReply()` never wrote an `approvals` row
  (`decision='returned'`), unlike `requests-api.js`'s
  `returnRequest`/`returnResponse`, so a reply a supervisor returned
  for correction never showed up on the drafting staff member's
  dashboard — reported as "not shown in action needed window for the
  draft replying staff." Adds `'external_correspondence_reply'` to
  `approvals`'s `record_type` CHECK and a matching `approvals_select`
  branch (visibility: admin, the entry's `to_section_id` member, or the
  reply's own drafter). New dashboard row "Entry Reply Returned for
  Correction" matches `myEntries`' embedded replies (now also
  selecting `id`/`created_by`, not just `status`) against these
  `approvals` rows, same shape as the existing Requests row. Also added
  a missing "Edit Draft" button + modal on the main Entry reply thread
  (`EntryAPI.updateReplyDraft()` already existed in the data layer but
  was never wired to a UI button here) — a reply returned for changes,
  or blocked by an open review comment, had no way to actually edit its
  text. Idempotent.
- Full Entry module review, 4 fixes:
  - Dead "Needs My Action" chip on the Entry Sent tab —
    `EntryAPI`'s list query never selected `delivery_method` on the
    embedded replies, so the chip's `r.delivery_method` test always
    failed. Added to the embed.
  - **`check_deadlines()` was silently broken for requests too, not
    just missing for Entry.** `section_user_ids()` returns `SETOF
    UUID` with an anonymous result column (named after the function
    itself), but the query read it as `SELECT user_id AS uid FROM
    section_user_ids(...)` — a column that doesn't exist. Every run
    with at least one overdue request threw and rolled back the whole
    function call, including every 'overdue' status flip already made
    earlier in that same run — the entire nightly deadline job had
    likely never actually worked. Fixed to `FROM
    section_user_ids(...) AS uid`. Caught by actually running
    `check_deadlines()` against seeded data rather than just reading
    it. Extended the same function with an Entry loop: Entry has no
    `overdue` status to flip to (state machine is logged -> routed ->
    responded -> closed), so this only notifies once per case,
    deduped via `NOT EXISTS` against `notifications` instead of a
    status change; cutoff is `CURRENT_DATE` (deadline is a DATE, not
    the requests table's TIMESTAMPTZ) so an entry counts as overdue
    once its whole deadline day has passed; unrouted entries are
    skipped (no single section to notify, already surfaced via
    Unrouted Entries regardless of deadline). Verified end-to-end
    against a local Postgres instance: an overdue routed entry gets
    notified exactly once (unrouted / already-responded / not-yet-due
    entries correctly skipped), a second run doesn't duplicate, and
    the requests-side fix still flips status + notifies + doesn't
    duplicate on rerun.
  - New dashboard row "Entry Reply Delivered — Close" — Entry's
    counterpart to the existing "Reply Received — Acknowledge &
    Close" row, reusing the `entries` list (with its replies embed)
    the adjacent Unrouted Entries row already fetches.
  - `external_correspondence.deadline` is a `DATE` column, but the
    Assign/Edit Draft deadline fields reused `RequestsView`'s
    TIMESTAMPTZ-oriented helpers unmodified — displaying a spurious
    "05:00" on every entry deadline (a bare date parses as UTC
    midnight, shown at UTC+5 in Maldives) and, on write, capable of
    silently shifting the stored date back a day for an early-morning
    local time (UTC is behind a positive offset). Added bare-date
    detection (`_isBareDate`) to `RequestsView`'s shared deadline
    helpers (`_deadlineParts`/`_formatDeadline`/`_isDeadlineOverdue`
    via a new `_deadlineInstant`/`_deadlineCell`) so a bare
    'YYYY-MM-DD' is displayed without a fabricated time and treated as
    due at end-of-day for overdue purposes, and a `dateOnly` parameter
    on `_deadlineFieldHtml`/`_bindDeadlineField`/`_combineDeadline` so
    Entry's two write sites (Edit Draft, Assign Staff) skip the
    timestamp round-trip entirely and write/read a bare date directly.
    Zero behavior change for Requests' own TIMESTAMPTZ deadlines
    (never bare-date, so `_isBareDate` is always false for them).

## 3. Auth Settings (Supabase Dashboard → Authentication → Settings)

### Site URL
```
https://<your-github-username>.github.io/CorLink
```
For local dev: `http://localhost:5500` (or your Live Server port)

### Email Auth
- Enable email confirmations: **OFF** (admin creates accounts, no self-signup)
- Disable signup: **ON** (users cannot self-register — admins create all accounts)

### Password Policy
Supabase does not enforce complex password policies natively.
CorLink enforces these rules **client-side on password change** and via an **Edge Function**:
- Minimum 10 characters
- At least one uppercase letter
- At least one lowercase letter
- At least one number
- At least one special character
- No reuse of last 5 passwords (checked against `user_password_history` table)
- Expires every 90 days (tracked in `users.password_expires_at`)

### Session / JWT
- JWT expiry: `1800` seconds (30 minutes) — matches inactivity timeout
- Refresh token rotation: **ON**
- Reuse interval: `10` seconds

## 4. Create Super Admin Account

In Supabase Auth dashboard → Authentication → Users → "Add user":
- Email: `MCS-001@corlink.internal` ← replace `MCS-001` with actual service number
- Password: (meets the policy above)
- Copy the UUID assigned by Supabase Auth

Then in SQL editor, run the commented INSERT from `seed.sql` with that UUID.

## 5. Storage Buckets

Create these buckets in Supabase → Storage:
| Bucket name         | Public | Purpose                      |
|---------------------|--------|------------------------------|
| `attachments`       | No     | Request/response attachments |
| `prisoner-letters`  | No     | Prisoner letter files        |
| `org-logos`         | Yes    | Organization logos           |

Enable RLS on all private buckets.

## 6. Realtime & pg_cron (Phase 5 — Notifications)
- **Realtime**: Database → Replication (or Table Editor → table → "Realtime") → enable on `notifications`, `requests`, `responses`, `internal_requests`, `internal_request_replies`. The notification bell subscribes to `notifications` INSERTs live; request-detail.js's "This case has been updated" toast subscribes to the other four. Without this it still works, just requires a page reload to see live updates.
- **pg_cron**: Database → Extensions → search "pg_cron" → enable. `supabase/notifications.sql` schedules a daily job (`check_deadlines()`, 03:00 UTC) that flips requests past their deadline to `overdue` and notifies the relevant section. If you run that file before enabling the extension, re-run just the `CREATE EXTENSION`/`cron.schedule` lines at the top afterward.

## 7. Edge Functions

### create-user (Phase 2 — required now)
Creates new staff accounts (needs the service role key, so it can't run
client-side). See `supabase/functions/README.md` for deploy steps —
either paste-and-deploy via the Supabase Dashboard, or `supabase functions deploy create-user`
if you have the CLI.

### reset-password (Phase 2 — required now)
Admin-initiated password resets. Same deploy steps as create-user.

### Not yet built
- `send-notification-email` — Email notifications via Resend, for when in-app notifications alone aren't enough (needs a Resend API key you'd provide)
- `validate-password` — Server-side password-history check beyond what the client already enforces
