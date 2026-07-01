# CorLink Edge Functions

## create-user

Creates a new Supabase Auth user + `public.users` profile + optional
`user_assignments`, using the service role key server-side. Required
because creating `auth.users` rows needs elevated privileges that must
never be exposed to the frontend (anon key can't do this).

### Deploy via Supabase Dashboard (no CLI needed)

1. Go to your project → **Edge Functions** → **Deploy a new function**
2. Name it `create-user`
3. Paste the contents of `create-user/index.ts` into the editor
4. Deploy

The function automatically has access to `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` as environment variables — no extra config
needed.

### Deploy via Supabase CLI (alternative)

```bash
supabase functions deploy create-user
```

### How it's called

The frontend calls this via `supabase.functions.invoke('create-user', { body: {...} })`
(see `js/data/admin-api.js` → `createUser()`). The Supabase client
automatically attaches the caller's JWT, which the function uses to
verify the caller holds an admin role before doing anything.

### Response

On success, returns `{ user_id, service_number, temp_password }`. The
admin UI displays the temp password once — it is NOT stored anywhere
in plaintext. The new user's password is already expired
(`password_expires_at` set to now), forcing them through the
change-password flow on first login.
