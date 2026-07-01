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

## 6. Realtime (for Phase 5 — Notifications)
Enable Realtime on: `notifications`, `requests`, `responses`
(Leave disabled for Phase 1)

## 7. Edge Functions

### create-user (Phase 2 — required now)
Creates new staff accounts (needs the service role key, so it can't run
client-side). See `supabase/functions/README.md` for deploy steps —
either paste-and-deploy via the Supabase Dashboard, or `supabase functions deploy create-user`
if you have the CLI.

### Later phases (Phase 5+)
- `send-notification-email` — Sends email notifications via Resend
- `check-deadlines` — Cron: marks overdue requests, sends warnings
- `validate-password` — Checks password history on change
