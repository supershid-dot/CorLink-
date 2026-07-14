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
