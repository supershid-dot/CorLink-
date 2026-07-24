# 21 — Staging Edge Functions: Assessment and Deployment Plan

**Status:** Repository-only assessment. **Supabase MCP tools were unavailable in this session.** Live target verification (independently confirming staging `vjobntuyzymhcuanyeak` vs. production `infjjroktzzhaxjvfknr` before any operation) was **not performed**, because this step required no Supabase reads or writes — everything below comes from reading tracked files in this repository (`supabase/functions/`, `references/meetflow/supabase/functions/`, `js/data/admin-api.js`, `docs/02`, `docs/03`, `docs/18`) and the earlier-established findings in those docs. **Neither staging nor production was contacted, read, or modified in any way during this step.** Actual deployment of any function requires a fresh, independent target-verification step once Supabase MCP tools are available again — this document is planning input for that later step, not a substitute for it.

---

## 1. Repository inventory of Edge Functions

Exactly two Edge Functions exist in CorLink's own deployable set (`supabase/functions/`). A third function exists only under `references/meetflow/` — a historical MeetFlow source snapshot kept for migration-comparison purposes, not part of CorLink's application and not a deployment candidate.

### 1.1 `create-user` — **active, in scope**

| | |
|---|---|
| Source path | `supabase/functions/create-user/index.ts` |
| Purpose | Creates a new Supabase Auth user + `public.users` profile + optional `user_assignments` rows, using the service-role key. Required because provisioning `auth.users` rows needs elevated privileges the anon key cannot exercise. |
| Entry point | `Deno.serve(async (req) => {...})`, single file, no shared/imported modules |
| Authentication expectations | Caller must send a valid `Authorization` bearer JWT. The function independently re-verifies the caller (a) has a valid session via an anon-key-scoped client's `auth.getUser()`, then (b) holds an admin role (`is_super_admin` OR an active `mcs_admin`/`authority_admin` assignment) via a **separate** service-role query — not merely trusting RLS, since the function's own service-role client bypasses RLS entirely. |
| Env vars / secrets | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` — all three auto-injected by the Supabase Edge Runtime into every function's environment for the project it's deployed to. No manual secret configuration required. |
| Service-role usage | Yes — reads the caller's own profile/assignments for the admin check, validates every assignment's `scope_org_id` via RPC and every `designation_id`'s `org_id` (both explicitly to prevent a cross-tenant privilege-escalation path the code's own comments document), calls `auth.admin.createUser`, inserts the `users` profile row, inserts `user_assignments` rows, inserts an `audit_logs` row, and calls `auth.admin.deleteUser` as a compensating rollback if the profile insert fails. |
| DB tables / RPCs used | `users` (select, insert), `user_assignments` (select, insert), `designations` (select), `audit_logs` (insert), `scope_org_id()` RPC, `auth.admin.createUser` / `auth.admin.deleteUser` |
| Required for staging? | **Yes.** This is the only way to create a user — the anon key cannot call `auth.admin.*`. `docs/20`'s entire 7-account test-account plan depends on this function existing and working on staging. |
| Depends on Auth? | Needs *a* valid authenticated admin session to be called at all — but not on any staging-specific Auth *setting* (Site URL, redirect URLs, email templates) being finalized first. In practice this means it can't be usefully exercised until the initial super admin account exists (a separate, still-blocked bootstrap step — see §5 and `docs/18` step 17). |
| Depends on frontend deployment? | Not strictly — it's a plain HTTPS endpoint invocable with any HTTP client given a valid JWT. In practice the only built caller is `js/data/admin-api.js` → `js/views/admin.js`'s "New User" form, so the *intended* operational path does depend on frontend deployment, even though direct API invocation for bootstrap purposes remains possible without it. |

### 1.2 `reset-password` — **active, in scope**

| | |
|---|---|
| Source path | `supabase/functions/reset-password/index.ts` |
| Purpose | Admin-initiated password reset for another user (e.g. locked out / forgot password). Requires the service-role key (`auth.admin.updateUserById`), so it cannot run client-side. |
| Entry point | `Deno.serve(async (req) => {...})`, single file |
| Authentication expectations | Identical two-layer check to `create-user`: own-JWT identity, then an independent service-role re-check of admin role. |
| Env vars / secrets | Same three auto-injected variables as `create-user`; no manual configuration required. |
| Service-role usage | Yes — reads the caller's own profile/assignments for the admin check, reads the target user's profile, calls `auth.admin.updateUserById`, updates `users.password_expires_at` to force the change-password flow, inserts an `audit_logs` row. |
| DB tables / RPCs used | `users` (select ×2, update), `user_assignments` (select), `audit_logs` (insert), `auth.admin.updateUserById` |
| Required for staging? | **Yes**, same reasoning as `create-user` — no other supported way to reset a password. |
| Depends on Auth? | Same as `create-user`. |
| Depends on frontend deployment? | Same as `create-user` — invoked from `admin.js`'s "Manage User" modal in the intended path; directly invocable otherwise. |

### 1.3 `meetflow-login` — **historical reference only, out of scope**

| | |
|---|---|
| Source path | `references/meetflow/supabase/functions/meetflow-login/index.ts` (reference snapshot, not under `supabase/functions/`, never part of CorLink's own deployable set) |
| Purpose | MeetFlow's own login endpoint. Verifies `svc_no`/`password` against a custom `staff` table using hand-rolled PBKDF2-SHA256, then hand-signs its own HS256 JWT — **this function *is* MeetFlow's entire authentication mechanism, and it does not use Supabase Auth at all.** |
| Entry point | `Deno.serve(async (req: Request) => {...})` |
| Authentication expectations | **None upstream — unauthenticated by design.** This endpoint is itself the credential-verification boundary. |
| Env vars / secrets | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `MF_JWT_SECRET` (a hand-rolled JWT-signing secret with no CorLink equivalent — CorLink has no analogous concept, since Supabase Auth issues and verifies its own JWTs). |
| Service-role usage | Yes, for every query — the function's entire security model rests on the service-role key bypassing RLS, which is moot on the source MeetFlow project anyway since its RLS is a blanket `USING (true) WITH CHECK (true)` allow-all per `docs/02` §3. |
| DB tables / RPCs used | `staff` (select, update), `staff_requests` (insert) — **neither table exists anywhere in CorLink's schema.** |
| Required for staging? | **No.** Retired per `docs/03` §1/§2: "MeetFlow authentication is retired, not merged." Deploying this against CorLink would fail outright (its target tables don't exist) even before considering that it's a deliberate Supabase-Auth bypass. |
| Depends on Auth? | N/A — bypasses Supabase Auth entirely; this is the finding, not a dependency to satisfy. |
| Depends on frontend deployment? | N/A — retired, not part of any CorLink deployment plan. |

No other `.ts`, Edge Function directories, `deno.json`, `import_map.json`, or `supabase/config.toml` exist anywhere in the repository outside the three files above (confirmed by a full-repository search this step).

---

## 2. Comparison with historical findings (`docs/02` §3, §5, §6)

Three additional functions were identified during the earlier MeetFlow live-inventory audit — **none of them exist in any repository.** They were found only by fetching source directly off the live, separate MeetFlow production Supabase project (`meeting-room-booking`, project ref `xvwileiyquqxxtzqxghm` — distinct from both CorLink staging and CorLink production) via the read-only `get_edge_function` MCP tool, never invoked, never checked into version control by MeetFlow's own team.

| Function | Where it lives | What it is | Relevance to this CorLink staging plan |
|---|---|---|---|
| `smooth-service` | Live-only, MeetFlow project | Confirmed via full source fetch to be a **byte-for-byte functional duplicate of `meetflow-login`** — independently re-implements the same PBKDF2 verification + JWT minting using the service-role key | **None.** Not present in this repository. Not CorLink's to deploy, manage, or decommission — flagged in `docs/02`/`docs/03` for the project owner to address on the MeetFlow side directly. |
| `clever-service` | Live-only, MeetFlow project | Same finding as `smooth-service` — a second independent duplicate of `meetflow-login` | Same as above — out of scope here. |
| Previously undocumented function (`swift-worker`) | Live-only, MeetFlow project | Generic Supabase boilerplate/example function, unrelated to any application logic — an apparent leftover default deploy, still live and reachable | Same as above — out of scope here. |

**Repo-inspection result for this step: CorLink's own `supabase/functions/` tree shows none of this pattern.** There are exactly two functions, they serve two distinct, non-overlapping purposes (create vs. reset), and neither is a duplicate of the other or of anything else in the tree. Because staging currently has **zero Edge Functions deployed** (`docs/19` §6, confirmed via `list_edge_functions` in an earlier step), there is also no live-vs-repo drift to check on the CorLink side yet — that comparison becomes relevant only after functions are actually deployed to staging, at which point a future step should re-run `list_edge_functions` against staging and diff it against this inventory.

---

## 3. Findings against the specific risk checklist

- **Obsolete MeetFlow functions:** `meetflow-login` (repo reference only) and the live-only `smooth-service`/`clever-service`/`swift-worker` (§2). None are candidates for staging deployment. None require any action from this CorLink migration beyond the exclusion already recorded in `docs/03`.
- **Duplicate login or account-management functions:** None found within CorLink's own codebase. `create-user` and `reset-password` are the only two functions and serve distinct purposes. The duplicate-login pattern previously found on the MeetFlow project has no analog here.
- **Unsafe or unnecessary service-role usage:** Both `create-user` and `reset-password` use the service-role key for capabilities that genuinely require it (`auth.admin.*` calls, and reading `user_assignments`/`designations` past what the calling user's own RLS view would show, specifically to perform the cross-tenant scope validation described in §1.1). Both functions **compensate** for the RLS bypass by re-implementing the admin-role check and (in `create-user`) the assignment/designation org-ownership check explicitly in code, rather than assuming the service-role client's writes are safe by default. This is correct, defended usage — not flagged as a risk. By contrast, `meetflow-login`'s service-role usage **is** its entire security boundary (no independent authorization check exists, because the function itself is the auth mechanism) — a structural characteristic of the retired MeetFlow project, not something carried into CorLink.
- **Hardcoded project URLs, keys, email addresses, organization IDs, redirect URLs, or CORS origins:** None found in `create-user` or `reset-password` — `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`/`SUPABASE_ANON_KEY` are all read from `Deno.env.get(...)`, never inlined. Both functions do hardcode `AUTH_DOMAIN = 'corlink.internal'` (matching `js/config.js`'s `AUTH_DOMAIN` constant exactly) — this is a synthetic, non-secret, deliberately environment-agnostic value used identically in every environment by design, not a staging/production divergence risk.
  - **CORS note (pre-existing, not staging-specific):** both functions set `'Access-Control-Allow-Origin': origin || '*'`, reflecting whatever `Origin` header the request sends rather than pinning to a specific allowed origin. This does not by itself allow unauthorized access (every request still needs a valid bearer JWT to do anything), but it is more permissive than a fixed-origin allowlist. Documented here as a security note; not a blocker for staging deployment, and not introduced or worsened by this step.
- **Functions exposing password hashes or bypassing canonical Supabase Auth:** `create-user`/`reset-password` do the opposite — they call Supabase Auth's own admin API (`auth.admin.createUser`, `auth.admin.updateUserById`), the canonical server-side provisioning path, and never read or return a password hash (only a freshly-generated random temporary password, returned once, matching the existing documented one-time-display convention). `meetflow-login` is the one function that bypasses canonical Supabase Auth entirely by design — already covered above, and explicitly excluded from CorLink.
- **Missing deployment configuration or secret documentation:** No `supabase/config.toml` is tracked in this repository, meaning there is no committed CLI deployment manifest — deployment is manual, per `supabase/functions/README.md` (Dashboard paste-and-deploy, or an ad hoc `supabase functions deploy <name>` command run outside any tracked config). This matches `docs/18` §6's earlier finding, not a new gap. No secrets beyond the three auto-injected variables are referenced by either approved function, so there is nothing missing to document for them specifically.

---

## 4. Deployment decision

| Function | Decision |
|---|---|
| `create-user` | **Approved for staging deployment.** No code changes required. |
| `reset-password` | **Approved for staging deployment.** No code changes required. |
| `meetflow-login` | **Obsolete — must not be deployed.** Retired per `docs/03`; references tables (`staff`, `staff_requests`) that do not exist in CorLink's schema at all. |
| `smooth-service`, `clever-service`, `swift-worker` | **Obsolete — must not be deployed.** Not present in any repository; live only on the separate MeetFlow production project; not CorLink's to manage. No action item for this migration beyond the exclusion already recorded in `docs/02`/`docs/03`. |

**Blocked pending correction:** none — both candidate functions pass this review as-is.

**Deferred (not blocked, but not yet meaningfully usable):** Deployment of `create-user`/`reset-password` is not itself blocked by Auth configuration or frontend deployment. Their *first successful invocation* is, however, necessarily deferred until an authenticated admin session exists to call them with — which requires the initial super admin account, itself a separate, still-blocked bootstrap step (`docs/18` step 17; `docs/20` §9's dependency chain: Edge Functions → super admin bootstrap → org/user structure → frontend deployment → Auth settings). Deploying the functions now is still worthwhile since it removes them from the critical path once the super admin step is authorized.

---

## 5. Required secrets (names only — no values)

| Secret name | Needed by | Manual configuration required? |
|---|---|---|
| `SUPABASE_URL` | `create-user`, `reset-password` | No — auto-injected by the Supabase Edge Runtime per project |
| `SUPABASE_SERVICE_ROLE_KEY` | `create-user`, `reset-password` | No — auto-injected |
| `SUPABASE_ANON_KEY` | `create-user`, `reset-password` | No — auto-injected |

**No secrets are missing for the approved deployment set.** Both functions rely solely on the three auto-injected environment variables, which Supabase provides automatically and identically for every Edge Function on every project — no per-function or per-project manual secret entry is needed for `create-user` or `reset-password`.

(`MF_JWT_SECRET`, needed only by the excluded `meetflow-login`, is not applicable here and is not being configured.)

---

## 6. Dependency order and proposed deployment sequence (planning only — not executed this step)

1. **Independently re-verify the deploy target** immediately before deploying anything (fresh `list_projects` call, confirm `vjobntuyzymhcuanyeak` ≠ `infjjroktzzhaxjvfknr`) — Edge Function deployment is project-scoped by the Dashboard/CLI session's active project, which is exactly the kind of context that can silently point at the wrong project if not re-checked at the moment of the write, independent of any check performed in an earlier, now-stale step.
2. Deploy `create-user` and `reset-password`. No ordering dependency exists between the two — they can be deployed in either order or together. Recommended: deploy both in the same session since both are required before any admin workflow (user creation *or* password reset) functions at all.
3. Confirm via `list_edge_functions` (read-only) that both functions now appear on staging, matching this document's inventory.
4. Do **not** attempt to invoke either function yet — meaningful invocation requires the super admin bootstrap step (§4) to happen first, which is out of scope for this document.

---

## 7. Security risks summary

| Risk | Severity | Status |
|---|---|---|
| Duplicate/undocumented login functions accumulating undetected (the exact pattern found on MeetFlow) | N/A to CorLink | Confirmed absent from this repository this step; no live staging functions exist yet to drift from it either |
| Permissive CORS (`Access-Control-Allow-Origin` reflects request origin) on both approved functions | Low | Pre-existing, not staging-specific; every call still requires a valid bearer JWT; noted for awareness, no fix required to proceed |
| Service-role bypass of RLS in both approved functions | Informational | Confirmed both functions independently re-implement the authorization checks RLS would otherwise provide, specifically to close the cross-tenant privilege-escalation gap the code's own comments describe; not a finding requiring action |
| `meetflow-login`'s Supabase-Auth bypass / hand-rolled crypto | N/A to CorLink | Confirmed excluded from deployment; retired per `docs/03`; would fail outright against CorLink's schema regardless |
| No committed `supabase/config.toml` / CLI deployment manifest | Low | Deployment remains a manual, documented (README) process; not a security risk, a process-consistency note for whoever performs the actual deploy step |

## 8. Remediation required before deployment

**None.** Both `create-user` and `reset-password` pass this assessment as-is; no code, secret, or configuration changes are required before they can be deployed to staging in a future, explicitly-authorized step.

## 9. Proposed rollback check (for the future deployment step, not performed now)

If either function needs to be rolled back after deployment: delete the function via Dashboard/CLI (`supabase functions delete <name>` or the Dashboard's delete action) and re-confirm via `list_edge_functions` that it no longer appears. Neither function performs any schema/DDL change on deploy or delete — rollback is limited to removing the deployed function itself; it does not need to unwind any database state, since all state changes the functions perform (`users`, `user_assignments`, `audit_logs`, `auth.users`) are ordinary application data, not migration-tracked schema.

---

## 10. Confirmation of constraints honored

- **Supabase MCP tools were unavailable this step** — confirmed via tool search before starting; no Supabase-prefixed tool was callable.
- **Live target verification was not performed** — deliberately waived for this step only, per explicit instruction, because no Supabase project was read or written.
- **This was a repository-only assessment** — every fact above comes from reading tracked files (`supabase/functions/*`, `references/meetflow/supabase/functions/*`, `js/data/admin-api.js`, `js/config.js`, `js/auth.js`, `docs/02`, `docs/03`, `docs/18`, `docs/19`) and prior git history.
- **Neither staging (`vjobntuyzymhcuanyeak`) nor production (`infjjroktzzhaxjvfknr`) was contacted, read, or modified** at any point in this step.
- **No function was deployed.** No secret was configured. No user was created. No Auth setting was changed. No frontend was deployed.
- **Deployment requires a target-verification step** — before any function in §4's "approved" set is actually deployed, a fresh, independent Supabase target check (staging ≠ production, tools reachable) must be performed as its own gated step.

---

## Edge Function deployment results

**Date:** 2026-07-22
**Executed against:** staging (`vjobntuyzymhcuanyeak`, "CorLink Staging") only.

### Target verification

- Before the first deployment: `list_projects` called and confirmed `vjobntuyzymhcuanyeak` = "CorLink Staging", distinct from `infjjroktzzhaxjvfknr` ("corlink-production") and `xvwileiyquqxxtzqxghm` ("meeting-room-booking").
- Before the second deployment: `list_projects` re-run and re-confirmed the same three references, unchanged.
- Supabase MCP tools remained connected and responsive throughout; no disconnection occurred, so no abort condition was triggered.

### Secret availability verification (no values exposed)

- `SUPABASE_URL`: confirmed present via `get_project_url` (`https://vjobntuyzymhcuanyeak.supabase.co`).
- `SUPABASE_ANON_KEY`: confirmed an active, non-disabled anon key exists via `get_publishable_keys` (value not recorded in this document).
- `SUPABASE_SERVICE_ROLE_KEY`: no read tool exists for this value by design (it is a genuine secret). Per Supabase's platform architecture, this variable is auto-injected identically into every Edge Function's runtime for every project, requiring no manual configuration — consistent with this document's earlier §5 finding.
- No secret values were printed at any point in this step.

### JWT verification setting

- Repository has no `supabase/config.toml` and no other `verify_jwt` override anywhere in the tracked source.
- Both functions are coded to require a valid `Authorization` bearer JWT (reject with 401 if missing) and independently re-verify caller identity/role — consistent with, not conflicting with, gateway-level JWT enforcement.
- Deployed both functions with `verify_jwt: true` (the tool's own default), preserving rather than changing the repository's intended authentication behavior. No Auth configuration was touched.

### Deployment order and results

1. **`create-user`** — deployed first (no ordering dependency between the two functions; this order matches this document's §6 recommendation).
   - Function ID: `ac007374-b08b-42bb-8106-71efe3f9185d`
   - Version: 1
   - Status: `ACTIVE`
   - JWT verification: `true`
   - Deployment timestamp (epoch ms): `1784722359018`
2. **`reset-password`** — deployed second, after re-verifying the target.
   - Function ID: `67a663fe-0708-487c-b3f3-9b32ffcfacbe`
   - Version: 1
   - Status: `ACTIVE`
   - JWT verification: `true`
   - Deployment timestamp (epoch ms): `1784722380225`

### Final staging function inventory

`list_edge_functions` against `vjobntuyzymhcuanyeak` after both deployments returned exactly:

| Slug | Status | Version | `verify_jwt` |
|---|---|---|---|
| `create-user` | ACTIVE | 1 | true |
| `reset-password` | ACTIVE | 1 | true |

No unexpected function appeared. No MeetFlow function (`meetflow-login`, `smooth-service`, `clever-service`, `swift-worker`) exists on staging.

### Warnings

- Permissive CORS (`Access-Control-Allow-Origin` reflects request `Origin` header) remains present in both functions, as already noted in §3/§7 above — pre-existing, not introduced by this deployment, not a blocker.
- No other new findings during deployment.

### Deferred invocation testing

- Neither function was invoked during this step. Meaningful invocation requires an authenticated admin session, which requires the super-admin bootstrap step (`docs/20` §9 / this document's §4) — a separate, not-yet-authorized step. This deployment only removes the Edge Functions themselves from that critical path.

### Constraints honored

- Staging (`vjobntuyzymhcuanyeak`) received exactly two function deployments; no other write of any kind was made to it.
- Production (`infjjroktzzhaxjvfknr`) was not contacted, read, or modified at any point.
- MeetFlow's project (`xvwileiyquqxxtzqxghm`) was not contacted, read, or modified at any point.
- No Auth setting was changed. No user was created. No frontend was deployed. No secret value was printed.

---

## 11. Files changed

- `docs/21-staging-edge-functions-plan.md` (this file — added "Edge Function deployment results" section)

No other file was created or modified in this step.
