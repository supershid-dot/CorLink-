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
- **Realtime**: Database → Replication (or Table Editor → table → "Realtime") → enable on `notifications`, `requests`, `responses`. The notification bell subscribes to `notifications` INSERTs live; without this it still works, just requires a page reload to see new notifications.
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
