# 24 — Staging Organization and User Bootstrap: Partial Results (Blocked)

**Status:** PARTIALLY COMPLETE, BLOCKED. Organizations and minimal org structure were created. The super admin account was created via the repository's own one-time bootstrap SQL pattern. **The remaining six users were NOT created** — creating them requires either an authenticated login (Supabase Auth token endpoint) or invoking the `create-user` Edge Function over HTTP, and both are blocked by this session's outbound network policy. No direct SQL write to `auth.users`, `auth.identities`, `public.users`, `user_assignments`, or `audit_logs` was performed for any of the six pending users, per explicit instruction.
**Date:** 2026-07-22
**Target verified:** staging (`vjobntuyzymhcuanyeak`, "CorLink Staging"), confirmed via `list_projects` before any write, distinct from production (`infjjroktzzhaxjvfknr`) and MeetFlow (`xvwileiyquqxxtzqxghm`).

---

## 1. Organizations created

| Org | Type | Code | ID |
|---|---|---|---|
| MCS-STG | `mcs` | `MCS-STG` | `58fc39a0-34da-4531-9975-3a77fed7d27f` |
| HRCM-STG | `authority` | `HRCM-STG` | `95a5eb35-5a58-4de3-bc62-5f6f0e8b3882` |

Both created via a plain `INSERT INTO organizations (...)` — the `organizations` table itself is application data, not part of Supabase Auth, so this write is unaffected by the Auth-table restriction below.

### 1a. Minimal org structure (also created)

Per `docs/20` §1: "Both organizations' internal structure ... must exist before any user account can be assigned — `users.org_id` is mandatory and every `user_assignments` row needs a real `scope_id`." Since three of the seven requested personas require a **section-scoped** `staff` role (Normal Staff, Room Manager, HRCM Correspondence Staff — see `docs/20` §3), at least one section per organization was required before any user creation (via the Edge Function or otherwise) could succeed at all. Created:

| Table | Org | ID | Parent |
|---|---|---|---|
| `commands` | MCS-STG | `c4e37b1f-24a2-457d-9edc-d2820e126cfb` ("Staging Command") | — |
| `departments` | MCS-STG | `81540889-d3de-4e39-84e9-2beb9e93d21e` ("Staging Department") | `c4e37b1f-...` |
| `sections` | MCS-STG | `7a7eb184-d47a-434d-b901-d16e8e5d4c5c` ("Staging Section", code `STG`) | department `81540889-...` |
| `divisions` | HRCM-STG | `c3ae96fb-8a2e-4e2d-aebc-facc5518e072` ("Staging Division") | — |
| `sections` | HRCM-STG | `1aabb5a7-bd80-4fa9-b4d4-fb0c86532988` ("Staging Section", code `STG`) | division `c3ae96fb-...` |

None of these tables are part of Supabase Auth (`organizations`, `commands`, `departments`, `divisions`, `sections` are all plain `public` schema application tables) — creating them does not touch `auth.*` in any way.

---

## 2. Super admin account — created successfully

The **only** user account created this step. Created via the exact SQL pattern already documented and approved in this repository for this specific, one-time purpose: `supabase/create-super-admin.sql` (referenced by `docs/18` step 17, `docs/20` §4's last row, and `auth-setup.md` §4 as the sole documented exception to "always use `create-user`" — precisely because no super admin exists yet to call that function, and this is the only account the repository itself instructs be bootstrapped this way).

| Field | Value |
|---|---|
| `auth.users.id` / `public.users.id` | `8206b528-3633-48db-bd1e-4211eb297599` |
| Login identity (`auth.users.email`) | `10108@corlink.internal` |
| `public.users.org_id` | `58fc39a0-34da-4531-9975-3a77fed7d27f` (MCS-STG — home org, irrelevant to authority scope per `docs/20` §3 persona #1) |
| `service_number` | `10108` |
| `full_name` | `Super Admin (Staging)` (not specified in the task; chosen as a plain, unambiguous label matching the requested persona name — no full name was invented beyond this) |
| `email` (display/notification) | `superadmin-stg@corlink.mv` |
| `is_super_admin` | `TRUE` |
| `is_prisoner_letters_staff` | `FALSE` (default; correct — super admin bypasses this check everywhere it's used, per `docs/20` §3) |
| `is_active` | `TRUE` |
| `password_expires_at` | `2026-10-20 17:54:19.64+00` (schema default, `NOW() + 90 days` — matches `create-super-admin.sql`'s own template, which does not force an immediate password change for this one bootstrap account) |
| `user_assignments` rows | None (correct — a super admin's authority is the `is_super_admin` flag itself, not a scope/role assignment, per schema comment and `docs/20` §3) |

**Password:** set to the task-specified value (`Corlink@1236`) via `crypt(..., gen_salt('bf'))`, matching `create-super-admin.sql`'s own hashing method exactly. Not printed anywhere in this document beyond this reference to its use.

---

## 3. Six users — NOT created (pending, blocked)

| # | Persona | Service number | Status |
|---|---|---|---|
| 1 | MCS Organization Admin | `10101` | **Not created** |
| 2 | Supervisor | `10102` | **Not created** |
| 3 | Normal Staff | `10103` | **Not created** |
| 4 | Room Manager | `10104` | **Not created** |
| 5 | HRCM Authority Admin | `10105` | **Not created** |
| 6 | HRCM Correspondence Staff | `10106` | **Not created** |

No row exists for any of these six service numbers in `auth.users`, `auth.identities`, `public.users`, or `user_assignments` — confirmed by the verification queries in §5. No `meeting_room_managers` grant was created for `10104` either, since the account it would reference doesn't exist, and no room exists to scope it to regardless (a separate, later prerequisite per `docs/20` §6 scenario 1 — room creation, itself out of scope for this step even had the users existed).

**Per explicit instruction, none of these were created via direct SQL** as a workaround. The only account created via direct SQL this step is the super admin (§2), which is the repository's own documented exception — not a precedent applied to the remaining six.

---

## 4. The blocker

This session's outbound HTTPS goes through a policy-enforcing proxy (`/root/.ccr/README.md`). Creating the remaining six users requires one of:
- **Authenticating as the super admin** via Supabase Auth's password-grant token endpoint (`POST https://vjobntuyzymhcuanyeak.supabase.co/auth/v1/token?grant_type=password`) — exactly what `js/auth.js`'s `Auth.signIn()` does via `supabase-js`'s `auth.signInWithPassword()` under the hood.
- **Invoking the `create-user` Edge Function** (`POST https://vjobntuyzymhcuanyeak.supabase.co/functions/v1/create-user`) with that admin's bearer token — the repository's own approved, sole mechanism for provisioning any account beyond the first super admin.

Both require an HTTPS connection to `vjobntuyzymhcuanyeak.supabase.co` on port 443. Attempting this failed outright:

```
curl -X POST "https://vjobntuyzymhcuanyeak.supabase.co/auth/v1/token?grant_type=password" ...
→ HTTP_STATUS=000 (connection failed)
```

The proxy's own diagnostic endpoint (`curl -sS "$HTTPS_PROXY/__agentproxy/status"`) recorded the reason directly:

```json
{
  "ts": "2026-07-22T17:55:23.172Z",
  "kind": "connect_rejected",
  "detail": "gateway answered 403 to CONNECT (policy denial or upstream failure)",
  "host": "vjobntuyzymhcuanyeak.supabase.co:443"
}
```

Per the proxy's own documented guidance (`/root/.ccr/README.md`, "403/407 from the proxy" section): *"The destination host is not allowed by your organization's egress policy for this session. Do not retry or route around it — report the blocked host."* This is a policy-level block, not a transient failure — retrying, using a different tool, or attempting a workaround would not change the outcome and was correctly not attempted.

**No Supabase MCP tool in this session's tool set can substitute for this** (`execute_sql`, `deploy_edge_function`, `list_edge_functions`, etc. — none can sign in as a user or invoke a deployed Edge Function's HTTP endpoint on this project's behalf).

**Resolution options, for whoever picks this up next:**
1. Grant this session (or a follow-up session) proxy/egress access to `vjobntuyzymhcuanyeak.supabase.co`, then resume from here — organizations, structure, and the super admin already exist, so only the six `create-user` calls remain.
2. Run the six `create-user` calls from an environment without this restriction (e.g., logging in as `10108` through the actual staging frontend at `https://corlink.pages.dev` and using its own "New User" admin flow — the exact production-equivalent path this repository's UI already provides).

---

## 5. Verification queries and results

All read-only, run against `vjobntuyzymhcuanyeak` after the changes above:

**Auth/profile counts:**
```sql
SELECT (SELECT count(*) FROM auth.users) AS auth_users_count,
       (SELECT count(*) FROM auth.identities) AS auth_identities_count,
       (SELECT count(*) FROM public.users) AS public_users_count,
       (SELECT count(*) FROM user_assignments) AS user_assignments_count;
```
→ `auth_users_count: 1`, `auth_identities_count: 1`, `public_users_count: 1`, `user_assignments_count: 0`

**Only user row present:**
```sql
SELECT id, org_id, service_number, full_name, email, is_super_admin,
       is_prisoner_letters_staff, is_active, password_expires_at
FROM public.users ORDER BY service_number;
```
→ Exactly one row: `10108`, `is_super_admin = true`, matching §2 above. No other service number (`10101`–`10106`) present.

**Role assignments:**
```sql
SELECT * FROM user_assignments;
```
→ Empty (`[]`) — expected, since the only user created (super admin) needs none, and none of the six role-bearing accounts exist yet.

**Room-manager grants:**
```sql
SELECT count(*) FROM meeting_room_managers;
```
→ `0` — expected; no room exists, and `10104` doesn't exist yet either.

**Organizations and structure:**
```sql
SELECT id, name, type, code FROM organizations ORDER BY code;
SELECT id, org_id, name FROM commands ORDER BY name;
SELECT id, command_id, name FROM departments ORDER BY name;
SELECT id, org_id, name FROM divisions ORDER BY name;
SELECT id, org_id, department_id, division_id, name, code FROM sections ORDER BY code;
```
→ Matches §1/§1a exactly — 2 organizations, 1 command, 1 department, 1 division, 2 sections, no unexpected rows.

**Login tests:** Not performed. Testing login for an MCS account and the super-admin account both require the same blocked HTTPS path (§4) — attempting either would hit the identical `403` policy denial, so neither was attempted rather than repeating a known-blocked call.

---

## 6. Warnings

- **Six of seven requested users remain uncreated.** This bootstrap is incomplete by design until the network blocker is resolved — see §4's resolution options.
- **Login was not verified for any account**, including the newly-created super admin, for the same network reason. The super admin's Auth row and password hash were written via the same trusted SQL pattern `create-super-admin.sql` already uses in production-equivalent bootstraps, so there is no specific reason to doubt it works — but this has not been independently confirmed by an actual sign-in in this session.
- **Room-manager authority for `10104`** cannot be granted even once that account exists, without a `meeting_rooms` row to scope it to (`meeting_room_managers.room_id` is `NOT NULL REFERENCES meeting_rooms(id)`) — room creation is a separate, later step (`docs/20` §6 scenario 1), not part of user bootstrap.
- **HRCM Correspondence Staff's `is_prisoner_letters_staff` flag** (per `docs/20` §3, account #7 needs this set `TRUE`) cannot be set until that account exists — `create-user` doesn't accept this field directly, so it would need a narrow, targeted follow-up update after creation (via the Admin UI's "Prisoner Letters Access" toggle, or an equivalent single-column update) — flagged here so it isn't missed once the six users are eventually created.

---

## 7. Confirmation of constraints honored

- **No direct SQL write to `auth.users`, `auth.identities`, `public.users`, `user_assignments`, or `audit_logs` was performed for any of the six pending users.** The only row written to any of these tables this step is the super admin (`auth.users`, `auth.identities`, `public.users`), via the repository's own pre-existing, documented one-time bootstrap script — not a workaround invented for this step.
- The `create-user` Edge Function and Supabase Auth Admin API were not bypassed for the six pending users — they were never reached at all, since the network path to invoke either is blocked.
- Production (`infjjroktzzhaxjvfknr`) was not contacted, read, or modified at any point.
- MeetFlow's project (`xvwileiyquqxxtzqxghm`) was not contacted, read, or modified at any point.
- No Auth setting was changed.
- No push occurred; no Git signing configuration was changed.

---

## 8. Files changed

- `docs/24-staging-user-bootstrap-results.md` (new, this file)

No other file was created or modified in this step.
