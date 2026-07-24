# Staging Environment Requirements — Phase 1

**Type:** Staging-environment availability check (Step 7 of the MeetFlow → CorLink migration process), stopped per its own stop condition — **no migration was applied anywhere**.
**Companion documents:** `docs/04-platform-module-foundation.md`, `docs/05-live-organization-module-assessment.md`
**Date:** 2026-07-21
**Method:** Supabase MCP `list_projects`, `list_branches`, `list_organizations`, `get_organization`, `get_project` — all read-only, metadata-only calls. No project, branch, table, or row was created, applied to, or modified. No credentials are reproduced in this report.

---

## 1. What was checked

| Check | Tool | Result |
|---|---|---|
| All Supabase projects on this account | `list_projects` | Exactly 2 projects: `corlink-production` (`infjjroktzzhaxjvfknr`) and `meeting-room-booking` (`xvwileiyquqxxtzqxghm`, MeetFlow). No third project of any kind. |
| Database branches / preview branches on the CorLink project | `list_branches` (`project_id=infjjroktzzhaxjvfknr`) | **Errored**: `InternalServerErrorException — Project reference is missing when validating permissions`. Not a transient failure — retried once, same result. |
| Organization plan tier | `get_organization` (`id=ojdttkcggwfqeorzwybk`, the only organization on this account) | `"plan": "free"`. Supabase database branching (the feature `list_branches`/`create_branch` operate on) is a paid-plan feature — it is not available on the free plan, which explains the error above: there is no branching entitlement to list. |
| A separate, disposable Supabase project clearly intended for testing | `list_projects` (same call as above) | None exists. Both projects present are either production (CorLink) or a different application entirely (MeetFlow) — neither is a test/staging project. |

## 2. Conclusion

**No clearly isolated staging environment exists**, by any of the three routes this step was asked to check:

1. **Existing CorLink staging/development project** — does not exist. Only `corlink-production` is a CorLink project.
2. **Supabase database branch / preview branch connected to CorLink** — does not exist, and cannot currently be created: the organization is on the free plan, which does not include database branching. `create_branch` was **not** attempted, because doing so would require `confirm_cost` (an explicit cost-incurring action) for a feature this plan tier doesn't include — that is a billing/plan decision, not something this read-only-until-explicitly-approved step is authorized to make.
3. **A separate disposable Supabase project for testing** — does not exist.

Per this step's own rules ("Do not create a staging environment unless the connected Supabase tools explicitly support safe project branching or preview environments"), creating a brand-new ad hoc project was **not** attempted either — the only creation method this step authorized (branching/preview) is the one confirmed unavailable, and the instructions did not authorize project creation as a fallback. **The migration was not applied anywhere.**

---

## 3. Safest available staging options

### Option 1 — Upgrade the Supabase organization to a paid plan and use database branching

Once the organization (`supershid-dot's Org`, `ojdttkcggwfqeorzwybk`) is on a plan that includes branching (Pro tier or above, per Supabase's own plan matrix), `create_branch` would create an isolated branch database that **automatically clones the production schema** (per its own tool description: "This will apply all migrations from the main project to a fresh branch database. Note that production data will not carry over.") — the branch gets its own `project_id`, fully isolated from `infjjroktzzhaxjvfknr`, with a built-in merge/discard lifecycle that maps directly onto this migration's own rollback requirements (§7 of the requesting step).

**Setup requirement:** a plan upgrade decision — this is a billing action only the account owner can authorize, and is out of scope for me to initiate. Once upgraded, staging setup itself is a single `create_branch` call (plus `confirm_cost`), no manual schema bootstrap needed.

**Recommended if:** the owner wants the most faithful, officially-supported staging story with the least manual schema-maintenance burden going forward — this is the option Supabase itself designed for exactly this use case.

### Option 2 — Create a new, dedicated, free-tier Supabase project as a permanent staging project

Supabase's free tier allows a small number of projects per organization without requiring a plan upgrade (project creation itself, unlike branching, is not gated behind Pro). A project named e.g. `corlink-staging` could be created and then manually brought to schema parity with production by running CorLink's own baseline SQL files in the order already documented in `supabase/auth-setup.md`'s "Run SQL Files in Order" list (`schema.sql`, `rls.sql`, `notifications.sql`, `storage-policies.sql`, and every `patch-*.sql` file already applied to production, in sequence) — followed by Phase 1's own `patch-platform-module-foundation.sql`.

**Setup requirements:**
- Explicit authorization to create a new project (this step's rules only pre-authorized branching/preview, not fresh project creation — this would need to be requested as its own step).
- Manual, careful replication of every SQL file already live on production, in the exact order they were originally applied, to avoid the staging schema silently drifting from production (the very risk this step's §3 "verify schema compatibility" check exists to catch).
- Ongoing maintenance discipline: every future production patch would need to be mirrored onto this project to keep it useful as staging.

**Recommended if:** the owner prefers not to change the paid-plan status of the account, and is willing to accept the manual schema-parity maintenance cost as a standing responsibility.

### Option 3 — Local Postgres (already-established convention in this repository)

Phase 1's own development already used a local Postgres instance (stub `auth` schema, `authenticated`/`anon` roles, real `schema.sql` + `rls.sql`, fixture data) to verify the migration's SQL correctness and RLS behavior empirically — this is documented in this repo's own history as the established pattern for RLS-touching changes prior to any Supabase application.

**What it covers:** SQL correctness, idempotency, RLS policy behavior under `SET ROLE`/impersonated JWT claims — genuinely useful and already partially done for Phase 1.

**What it does not cover:** real Supabase Auth/session issuance, real anon/authenticated API keys and PostgREST request behavior, Supabase Storage, Edge Functions, or true end-to-end frontend-against-a-live-backend testing — this step's §6 (frontend validation: login, dashboard, Modules admin tab, mobile nav, direct-URL route protection, etc.) fundamentally requires a real Supabase project's Auth and REST layer, which local Postgres alone cannot provide.

**Recommended if:** as a first-pass sanity check only, in parallel with pursuing Option 1 or 2 — not a substitute for either, since it cannot satisfy this step's frontend-validation requirements (§6) or its rollback-test requirement against a real hosted project (§7).

### Option not recommended: using production because its transactional tables are currently empty

Explicitly ruled out by this step's own instructions ("Do not use the live production project as staging merely because its transactional tables are currently empty") and not reconsidered here — empty transactional tables do not make a project safe to test schema/RLS/rollback changes against; it is still the one project real users, real Auth sessions, and real Storage/Edge Function configuration depend on.

---

## 4. What this means for Phase 1

Phase 1 (`supabase/patch-platform-module-foundation.sql`, commit `737c29e`) remains fully prepared and locally verified, but **cannot proceed to live staging validation until one of Option 1 or Option 2 above is set up** — that setup decision (a plan upgrade, or authorization to create a new project) belongs to the account owner, not to this step. No code or migration changes were made in this step; nothing needed changing — the blocker is environmental availability, not a defect found in the migration itself.

---

## 5. Final Checks

- **Live production (`infjjroktzzhaxjvfknr`) was not modified:** confirmed — every call this step made was read-only project/organization metadata (`list_projects`, `list_branches`, `list_organizations`, `get_organization`, `get_project`); no `execute_sql`, `apply_migration`, or any write-capable tool was called against it.
- **MeetFlow (`xvwileiyquqxxtzqxghm`) was not accessed or modified:** confirmed — it appeared only in the `list_projects` result as an existence check; no project-specific call was made against it.
- **No frontend was deployed.**
- **No Git commit was pushed** — this document is committed locally only, per this step's rules.
- **CorLink remains on `feature/corlink-platform-migration`**, confirmed via `git status` before this step began.
- **No staging environment was created through an unsupported or uncertain workflow** — none was created at all, per §2's stop condition.

**Stop after this step**, per the requesting instruction — no migration was applied anywhere; awaiting the next step (most likely: the owner's choice between Option 1 and Option 2 above).
