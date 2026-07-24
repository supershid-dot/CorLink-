# Staging Deployment and Validation Plan

**Type:** Staging-environment preparation and validation planning (no implementation). Companion to every prior migration document — this is the execution plan for applying what has already been designed, built, and locally tested, to a real hosted environment before it ever reaches CorLink production.
**Date:** 2026-07-22
**Scope of this step:** Documentation only. No migration was applied anywhere. No frontend code was changed. No Git push occurred. No hosted Supabase project (production `infjjroktzzhaxjvfknr` or MeetFlow `xvwileiyquqxxtzqxghm`) was accessed or modified.
**Companion documents:** `docs/06-staging-environment-requirements.md`, `docs/07-phase-1-staging-results.md`, `docs/11-rooms-booking-database-foundation.md`, `docs/14-meetings-database-foundation.md`, `docs/15-rooms-booking-frontend.md`, `docs/16-meetings-frontend.md`, `docs/rollback/001-platform-module-foundation.md`, `docs/rollback/002-rooms-booking-foundation.md`, `docs/rollback/003-meetings-foundation.md`.

---

## 0. A note on what could and could not be re-verified this session

`docs/06`/`docs/07` (2026-07-21) found no isolated staging environment available — free-tier organization, no database branching entitlement, and a hard 2-active-free-project cap already reached by the account's only two projects (`corlink-production`, `meeting-room-booking`). **The Supabase MCP connector is disconnected in this session** (confirmed: no `mcp__Supabase__*` tools are reachable at all, versus the full tool set `docs/06`/`docs/07` used). This means **none of `docs/06`'s findings could be re-confirmed live this session** — this plan treats them as the best-available, most-recent record (one day old relative to this document), not as freshly re-verified fact. **Before acting on §2's recommendation below, whoever executes this plan should first reconnect Supabase access and re-run the same read-only checks (`list_projects`, `list_organizations`, `get_organization`) to confirm nothing has changed** (a plan upgrade, a freed project slot, etc.) since `docs/06` was written.

---

## 1. Repository state and what must be applied

**Verified this step:** branch `feature/corlink-platform-migration`, HEAD `acdeaad`, working tree clean.

### 1a. Migrations that must be applied (in dependency order — see §4 for full detail)

| # | File | Creates | Depends on |
|---|---|---|---|
| 0 | *(baseline parity — not a new migration; see §4 Step 0)* | Brings a fresh staging project to today's actual production schema | N/A |
| 1 | `supabase/patch-platform-module-foundation.sql` | `platform_modules`, `organization_modules`, 3 helper functions, 4 RLS policies | Baseline parity (Step 0) |
| 2 | `supabase/patch-rooms-booking-foundation.sql` | `meeting_rooms`, `meeting_room_managers`, `meeting_room_blocks`, `meeting_room_bookings`, 10 RPCs, 8 RLS policies, `btree_gist` extension | Migration 1 (module-gated RLS) |
| 3 | `supabase/patch-meetings-foundation.sql` | `meetings`, `meeting_participants`, 7 RPCs, extends `meeting_room_bookings` (FK + index) and `reschedule_booking()` (adds `p_new_timezone`), extends `attachments`/`notifications`/`audit_logs` CHECK constraints | Migration 2 (extends its tables/functions directly — **must** run after it, not just conceptually depend on it) |
| 4 | `supabase/patch-rooms-route-activation.sql` | Sets `platform_modules.route = 'rooms'` | Migration 2 |
| 5 | `supabase/patch-meetings-route-activation.sql` | Sets `platform_modules.route = 'meetings'` | Migration 3 |
| 6 | Frontend deployment (`index.html` + `js/**`, staging-specific config — see §3's blocker) | Makes `#rooms`/`#meetings` reachable in a browser | Migrations 4 and 5 (routes must be non-`NULL` for `admin.js`'s Modules tab to allow enabling either module) |

### 1b. Validation scripts that must be executed

| Script | Validates |
|---|---|
| `supabase/validate-platform-module-foundation.sql` | Migration 1's catalogue/assignment/RLS shape |
| `supabase/validate-rooms-booking-foundation.sql` | Migration 2's tables/RPCs/RLS/idempotency |
| `supabase/validate-meetings-foundation.sql` | Migration 3's tables/RPCs/RLS/idempotency, including the `reschedule_booking()` 5-parameter signature and the "exactly one overload" check |

None of these three scripts write anything — every query is a `SELECT`, safe to run repeatedly against staging at any point after its corresponding migration.

### 1c. Current blockers

1. **No isolated staging environment currently exists** (per `docs/06`, not re-verified live this session — see §0). This is the single blocking item; everything else in this plan is ready to execute the moment it's resolved.
2. **Frontend config is hardcoded to production** — `js/config.js`'s `SUPABASE_URL`/`SUPABASE_ANON_KEY` and `index.html`'s CSP `connect-src`/`img-src` both hardcode `infjjroktzzhaxjvfknr.supabase.co` (this repo's own documented, deliberate CSP design — see `index.html`'s own comment on why it's pinned rather than wildcarded). Deploying the frontend against any staging project other than production requires a **staging-only** config swap that must never be committed to this branch (see §3).
3. **No dedicated rollback document exists yet for either route-activation patch** — both are a single idempotent `UPDATE`, trivial to reverse by hand (§8 gives the exact statement), but unlike migrations 1–3 they have no `docs/rollback/00N-*.md` companion. Not a blocker to proceeding, but flagged as a documentation gap worth closing alongside this plan.

### 1d. Staging options available (as last recorded, §0 caveat applies)

Restated from `docs/06` §3, not re-derived:

1. **Upgrade to a paid Supabase plan and use database branching** — most faithful, officially-supported option; requires a billing decision only the account owner can make.
2. **Create a new dedicated free-tier project** — blocked as of `docs/07`'s attempt (2-project cap already reached); would require either deleting/pausing an existing project or a plan upgrade to raise the cap, both outside this step's authorization.
3. **Local PostgreSQL** — already the working convention for every migration this whole session; covers SQL/RLS correctness fully, but cannot cover real Supabase Auth/Storage/PostgREST, so it cannot alone satisfy this plan's frontend/smoke-test requirements (§5, §7).

---

## 2. Staging strategy determination

**Checked this step:** whether Supabase database branching, a dedicated staging project, or a self-hosted staging stack now exists. **Could not be checked live** (§0) — the Supabase MCP connector is disconnected this session, so `list_projects`/`list_organizations`/`get_organization` could not be re-run. No self-hosted staging stack (a self-hosted Postgres + PostgREST + GoTrue stack standing in for Supabase) is referenced anywhere in this repository's own documentation, `docker-compose` files, or infrastructure scripts — a search of the repository root and `supabase/` found no such configuration, so "does a self-hosted stack exist" is answered directly from the repository's own contents: **no**.

**Recommendation (unchanged from `docs/06`, since nothing here could be re-verified): Option 2 (a new dedicated free-tier project), attempted first, falling back to Option 1 (plan upgrade) only if the account's project cap genuinely cannot be freed.** Reasoning:

- Option 1 (branching) is the most correct long-term answer but requires a billing decision — recommend it as the target state, not the immediate next action.
- Option 2 was already attempted once (`docs/07`) and failed only on the 2-project cap, not on any technical or policy obstacle — the fix is narrower (free a slot: delete the unused `meeting-room-booking` project if MeetFlow retirement has since been confirmed elsewhere, or pause it if Supabase's pause feature is available on the free tier) than a full plan upgrade, and doesn't commit the organization to an ongoing cost.
- Local Postgres (Option 3) remains valuable as a fast pre-check before spending a staging project's setup effort, exactly as it already served every migration phase in this repository's own history — but it is explicitly **not** a substitute for either Option 1 or Option 2, since it cannot execute this plan's §5/§7 frontend and smoke-test requirements.

**Production was not touched in determining this.**

---

## 3. Prerequisites

Before Step 1 of §4 can begin:

1. **A staging Supabase project exists and is reachable** (§2's decision made and executed by the account owner — creating or provisioning the project itself is a billing/administrative action outside this step's scope).
2. **A staging-only frontend config branch or build step exists.** Concretely: a copy of `js/config.js` with the staging project's `SUPABASE_URL`/`SUPABASE_ANON_KEY`, and a copy of `index.html` with its CSP `connect-src`/`img-src` pointed at the staging project's subdomain instead of `infjjroktzzhaxjvfknr.supabase.co`. **These two files must never be committed to `feature/corlink-platform-migration`** with staging values — that branch is destined to reach production, and a hardcoded staging URL merged into it would silently break production auth/API calls. The cleanest mechanism: a short-lived local branch or a deploy-time `sed` swap (mirroring `index.html`'s own documented cache-buster `sed` convention), never a permanent commit.
3. **Auth is configured on the staging project**, per `supabase/auth-setup.md` §3 (Site URL, email auth, password policy, session/JWT settings) — the same steps already required for production, applied a second time to the new project.
4. **Storage buckets exist on staging** (`attachments`, `org-logos`), per `auth-setup.md` §5, with `supabase/storage-policies.sql` applied.
5. **`pg_cron` and `btree_gist` extensions are enabled on staging**, per `auth-setup.md` §6 and `docs/10` §2 — both are on Supabase's curated extension allowlist and were self-served without issue on production; expected to work identically on a fresh project, not yet verified live.
6. **The `create-user`/`reset-password` Edge Functions are deployed to staging**, per `auth-setup.md` §7 — required before any staging user account can be created through the app's own admin flow rather than by hand.
7. **A super admin account exists on staging** (`supabase/create-super-admin.sql`), required to bootstrap every other account and to perform the module-enablement smoke tests in §7.

---

## 4. Migration order

Exact order, restated per this step's own instruction, with dependencies/outputs/rollback points made explicit:

### Step 0 — Baseline parity with current production

**Not one of the six numbered steps below, but a hard prerequisite to Step 1.** A staging project starts empty; production does not — it already carries every baseline file and historical patch. Run, in the exact order `supabase/auth-setup.md` §2 documents: `schema.sql` → `rls.sql` → `storage-policies.sql` (after bucket creation) → `notifications.sql` (after `pg_cron` is enabled) → every `patch-*.sql` file already live on production, in the changelog order that same document lists (dozens of files, spanning every feature shipped before this migration project began — Requests, Prisoner Letters, Entry, Internal Collaboration, review comments, and more). **`docs/02-live-supabase-inventory.md` is the authoritative record of what's actually live on production today** (captured 2026-07-21) — before trusting it as the parity target, re-confirm it's still accurate (production may have changed since), since Supabase access could not be re-checked this session (§0).
**Expected output:** a staging schema that is byte-for-byte structurally identical to production's current live schema (same table count, same policy count, same function set) — `docs/02`'s own captured counts are the check.
**Rollback point:** none needed at this step — if parity itself is wrong, the fix is re-deriving the file list from `docs/02`/`auth-setup.md`, not a schema rollback.

### Step 1 — Platform module foundation

**File:** `supabase/patch-platform-module-foundation.sql`. **Depends on:** Step 0 only.
**Expected output:** `platform_modules` (11 rows, all future modules' `route` still `NULL`), `organization_modules` (11 rows × every staging organization, the 4 already-shipped modules enabled, 7 future ones disabled), 3 helper functions, 4 RLS policies. Confirmed idempotent and RLS-correct against local Postgres (`docs/07`, all 13 tests passed) — not yet confirmed against a real hosted project.
**Rollback point:** `docs/rollback/001-platform-module-foundation.md` — the least destructive of the three; two brand-new, self-contained tables with nothing else in the schema referencing them.

### Step 2 — Rooms and Booking backend

**File:** `supabase/patch-rooms-booking-foundation.sql`. **Depends on:** Step 1 (module-gated RLS reads `platform_modules`/`organization_modules`); requires `btree_gist` enabled first (prerequisite §3 item 5).
**Expected output:** 4 new tables, the hybrid exclusion-constraint + trigger conflict-prevention design, 10 RPCs, 8 RLS policies, 6 new `notifications.type` values, 3 new `audit_logs.action`/`record_type` values. Confirmed against local Postgres including two-session concurrency and a rollback-then-reapply cycle (`docs/11`) — not yet confirmed against a real hosted project.
**Rollback point:** `docs/rollback/002-rooms-booking-foundation.md` — prerequisite check required first (no live `notifications`/`audit_logs` row may carry a value this migration introduced).

### Step 3 — Meetings backend

**File:** `supabase/patch-meetings-foundation.sql`. **Depends on:** Step 2 directly and non-optionally — this migration extends `meeting_room_bookings` (adds the `meeting_id` FK + a partial unique index) and replaces `reschedule_booking()` (adds a 5th parameter, `p_new_timezone`), so **Step 2 must have already run on this exact project** before Step 3 can be attempted at all; there is no independent path.
**Expected output:** 2 new tables, 7 RPCs, the meeting-link-guard trigger, the `reschedule_booking()` signature extension, 6 new `notifications.type` values, 5 new `audit_logs.action` values, `'meeting'` added to `attachments`/`audit_logs` record-type CHECKs, 3 attachments RLS policies extended with a `'meeting'` branch. Confirmed against local Postgres including six concurrency scenarios and a rollback-then-reapply cycle with a real, documented dangling-reference finding (`docs/14`, `docs/rollback/003` §1b) — not yet confirmed against a real hosted project.
**Rollback point:** `docs/rollback/003-meetings-foundation.md` — the most involved of the three; requires reverting `attachments_select`/`_insert`/`_delete` **before** dropping `can_view_meeting()`/`can_manage_meeting()` (a real ordering bug this repo's own testing already found and documented), and requires nulling dangling `meeting_room_bookings.meeting_id` values before any subsequent reapply.

### Step 4 — Rooms route activation

**File:** `supabase/patch-rooms-route-activation.sql`. **Depends on:** Step 2 (the frontend it activates, §6, calls Rooms RPCs that must already exist).
**Expected output:** `platform_modules.route = 'rooms'` (was `NULL`). Single idempotent `UPDATE`, confirmed locally (`docs/15`: first run `UPDATE 1`, second run `UPDATE 0`).
**Rollback point:** no dedicated file exists (§1c item 3); reversal is `UPDATE platform_modules SET route = NULL WHERE module_key = 'rooms';` — see §8.

### Step 5 — Meetings route activation

**File:** `supabase/patch-meetings-route-activation.sql`. **Depends on:** Step 3.
**Expected output:** `platform_modules.route = 'meetings'` (was `NULL`). Confirmed locally identically to Step 4 (`docs/16`).
**Rollback point:** same as Step 4's, targeting `module_key = 'meetings'` — see §8.

### Step 6 — Frontend deployment

**Depends on:** Steps 4 and 5 (without a non-`NULL` route, `admin.js`'s Modules tab cannot let a staging org admin enable either module, so the deployed UI would be unreachable regardless of the code being present) and prerequisite §3 item 2 (staging-specific config).
**Expected output:** the full CorLink SPA, including `js/data/rooms-api.js`/`js/views/rooms.js`/`js/data/meetings-api.js`/`js/views/meetings.js`, reachable at the staging URL, `#rooms` and `#meetings` both resolving once their modules are enabled for a test organization.
**Rollback point:** lowest-risk of all six — static files only, no data. Revert to the previous deployed build, or simply leave the new files in place; with Steps 4/5 rolled back first (§8's actual order), the new routes become unreachable (fail-closed via `moduleGuardPasses()`) even if the files themselves are still served.

---

## 5. Staging validation order

Run in this order — each builds on state the previous step created:

1. **SQL validation scripts** — `supabase/validate-platform-module-foundation.sql`, then `supabase/validate-rooms-booking-foundation.sql`, then `supabase/validate-meetings-foundation.sql`, immediately after their respective migration step in §4. All three are read-only.
2. **RLS verification** — re-run this repository's own local-Postgres RLS test matrices (docs/07 §5's 13 tests; docs/11 §3's tests 9/10/15/16; docs/14's equivalent Meetings tests, all already executed once each locally and documented) against the staging project itself, via the same `SET LOCAL ROLE`/impersonation pattern where a service-role/superuser connection is available, or via real staging user accounts and the actual Supabase client otherwise. The point of re-running these against staging specifically (not just trusting the local results) is that RLS behavior can differ subtly under a real PostgREST/Supabase Auth session (real JWTs, real `auth.uid()` resolution) versus this repository's own stub `auth` schema.
3. **Organization isolation** — confirm a staging user in one organization sees zero rows for another organization's rooms/bookings/meetings, mirroring `docs/11` test 9 exactly, using two real staging organizations and two real staging user accounts (not impersonation).
4. **Module enablement** — confirm `admin.js`'s Modules tab correctly shows Rooms/Meetings as enableable (route no longer `NULL`) only after Steps 4/5; enable each for one test organization only and confirm the other test organization's nav does **not** show the new links.
5. **Room booking conflicts** — re-run `docs/11`'s conflict-prevention scenarios (overlapping bookings, expired holds, room blocks, override paths) against staging, confirming the exclusion constraint and both conflict-guard triggers behave identically to local testing.
6. **Meeting-room integration** — assign a room to a meeting, confirm the linked booking's time/timezone stays in sync via `update_meeting`'s atomic reschedule delegation, confirm `assign_room_booking`'s one-active-booking-per-meeting enforcement, confirm detach clears `location_mode`.
7. **Cancellation cascade** — cancel a meeting with an active linked booking, confirm both become `cancelled` atomically; independently cancel a booking (not via Meetings) and confirm the meeting is correctly **unaffected** (the documented, deliberate asymmetry, `docs/12` §11).
8. **Participant privacy** — confirm `meeting_participant_list()` redacts external contact fields for a non-privileged caller and does not for a privileged one, against real staging sessions (not impersonation), since this is the one check most likely to reveal a session/JWT-resolution difference from local testing.
9. **Notifications** — confirm every notification type this migration introduces (6 booking types, 6 meeting types) fires correctly and that clicking a notification navigates to the correct deep link (`#rooms?bookingId=`, `#meetings?meetingId=`) in a real browser session.
10. **Attachment behavior** — upload a meeting attachment as a manager, confirm an ordinary participant can view but not upload/delete it (delete is uploader-only everywhere in this app, not manager-widened — `docs/16` §1), confirm the signed-URL download flow works against staging's real Storage bucket (something local Postgres cannot exercise at all).
11. **Frontend validation** — the full checklist `docs/07` §6 explicitly deferred (login, dashboard, every nav link, mobile bottom nav, direct-URL route protection, module-fetch failure behavior) plus this migration's own additions (Rooms and Meetings nav links, tabs, modals) — see §7's smoke-test checklist for the concise version.

---

## 6. Acceptance test matrix

Seven personas, each mapped against this app's actual two-layer access model (Layer 1: platform module + org enablement; Layer 2: role/relationship — `docs/04`, reused unmodified by every module built since).

| Persona | Accessible modules | Forbidden actions | Expected behavior |
|---|---|---|---|
| **Ordinary staff** (MCS org, no supervisor/admin role, no room-manager grant) | Requests, Entry, Rooms, Meetings (all module-enabled for their org) | Cannot approve/reject anyone's room booking; cannot see the Pending Approvals tab in Rooms (`_hasAnyManagerAuthority()` false); cannot create/edit rooms; cannot manage another user's meeting; cannot enable/disable modules; cannot reach Administration | Can submit a room booking (goes to `pending`), create/edit/cancel their own meetings, add/remove participants on meetings they created, view any meeting their `visibility` tier permits |
| **Room manager** (a staff member with an explicit `meeting_room_managers` grant for one specific room, no supervisor role) | Same as ordinary staff, plus the Pending Approvals tab in Rooms is visible | Cannot approve/reject/reschedule bookings for a room they don't manage; cannot manage meetings they didn't create and aren't a supervisor for (room-manager authority is room-scoped, not meeting-scoped — `can_manage_meeting()` has no room-manager branch) | Can directly confirm bookings (`create_room_booking`) and approve/reject pending ones **only for their managed room(s)**; a booking request for a room they don't manage still requires approval from someone with authority over *that* room |
| **Supervisor** (org-wide `supervisor`/`mcs_admin`/`authority_admin` role) | Everything module-enabled for their org, org-wide, regardless of section/room-specific grants; `mcs_admin`/`authority_admin` additionally reach Administration (plain `supervisor` role does not — `AppShell.isAdmin()` checks only `mcs_admin`/`authority_admin`, not `supervisor`) | Cannot see or manage any other organization's rooms/bookings/meetings, cannot enable/disable modules for any organization (super-admin-only) | Manages every room and every meeting in their own organization automatically, with zero per-room/per-meeting grant needed (`docs/10` §8 Option D, `can_manage_meeting()`'s org-supervisor branch); approves/rejects any pending booking org-wide; cancels any meeting org-wide (with a reason, since not the creator) |
| **Super admin** (`is_super_admin`) | Every module, every organization, unconditionally | Nothing forbidden by design — this is the intended unrestricted role | Sees and manages rooms/bookings/meetings across **every** organization; is the only role that can enable/disable a module for an organization (`organization_modules_write`); self-approving their own booking or meeting-cancellation-with-no-reason is the one path that additionally requires an explicit override reason, recorded distinctly in the audit trail, rather than being silently allowed |
| **Authority organization user** (a staff member of a non-MCS organization type, e.g. `Test Authority`/HRCM) | Whatever is enabled for *their own* organization only — Rooms/Meetings are **disabled by default** for a non-MCS org type unless a super admin explicitly enables them (`docs/12` §12's "external organizations receive no meetings module access by default" — the same default-disabled posture every non-Requests/non-Prisoner-Correspondence module already has) | Cannot see any MCS-organization room, booking, or meeting under any circumstance, even if their own org has Rooms/Meetings enabled — org isolation is absolute, never bypassed by module enablement (confirmed locally, `docs/11` test 9: an HRCM user saw 0 MCS rooms) | If their org has Rooms/Meetings enabled, functions identically to "ordinary staff" above, but scoped entirely to their own organization's data; if disabled, sees no nav link and a direct-URL attempt renders "Module unavailable" |
| **Participant** (an internal user added to a meeting by its creator/organizer, no other authority) | Can view the specific meeting(s) they're an active participant of, subject to `visibility` (`private`/`participants` both include active participants; `organization` additionally exposes every org-wide meeting) | Cannot edit, cancel, or manage participants/room assignment on a meeting they don't manage — every management control in the detail modal is hidden (`_canManage()` false), and the underlying RPCs independently reject the attempt regardless of what the UI shows | Sees their own row's full detail via `meeting_participant_list()`; sees other participants' external contact fields redacted (shown as "unavailable," never blank/broken); can remove themselves as a participant (self-removal is always permitted, no manager authority required) unless they are the sole organizer |
| **Anonymous user** (no session) | None | Cannot reach any route beyond `login`/`change-password` — `Router`'s own auth guard redirects before the module guard is even evaluated; cannot read any row from `meetings`, `meeting_participants`, `meeting_rooms`, `meeting_room_bookings`, or `meeting_room_blocks` (confirmed locally: `anon` role sees 0 rows from every one of these tables); every RPC raises "requires an authenticated caller" | Typing `#rooms` or `#meetings` directly in the URL bar redirects to `#login`, never to a partially-rendered page |

---

## 7. Smoke-test checklist

Concise, execution-order pass against a real staging deployment (not local Postgres — every item here needs real Auth/PostgREST/Storage):

- [ ] **Login** — a real staging user (service-number-based auth, per `AUTH_DOMAIN`) signs in successfully; an invalid password is rejected with the correct remaining-attempts message; lockout triggers after `MAX_LOGIN_ATTEMPTS`.
- [ ] **Organization switching** *(interpreted as: cross-org visibility for the one role that legitimately spans organizations)* — a super admin views rooms/meetings belonging to two different staging organizations in the same session without needing to "switch" (ordinary/supervisor users belong to exactly one organization and never switch — confirmed by this app's own data model, `users.org_id` is singular).
- [ ] **Module enablement** — a super admin enables Rooms for one staging org via `admin.js`'s Modules tab; that org's users see the Rooms nav link appear on their **next** page load without a code deploy; a second staging org where Rooms stays disabled shows no such link.
- [ ] **Room creation** — a supervisor creates a new room (name, capacity, bookable-until); it appears in the Rooms tab for every staff member in that org.
- [ ] **Booking lifecycle** — an ordinary staff member submits a booking request (→ `pending`); a supervisor approves it (→ `confirmed`); the same staff member reschedules it; a manager cancels it with a reason.
- [ ] **Approval flow** — a room manager (not a supervisor) sees the Pending Approvals tab and can approve/reject a request for their own managed room only.
- [ ] **Room blocks** — a manager creates a block over a free window (succeeds); a manager attempts a block over an existing confirmed booking without an override (rejected); with an override reason (succeeds, booking left untouched).
- [ ] **Meeting lifecycle** — create a draft meeting, publish it to `scheduled`, confirm it appears in Upcoming; let its `end_at` pass (or seed one already in the past) and confirm it appears in Past with a `Completed` badge; cancel a different meeting and confirm it appears in Cancelled.
- [ ] **Participant management** — add one internal and one external participant to a meeting; confirm the internal participant receives a `participant_added` notification; remove the external participant and confirm it disappears from the participant list (soft-removed, not visible anywhere in this frontend per `docs/16` §4's documented limitation).
- [ ] **Room assignment** — assign a room to a scheduled meeting; confirm the linked booking appears with matching time/timezone; change to a different room; detach the room and confirm `location_mode` clears.
- [ ] **Notification navigation** — click a `booking_submitted` notification and confirm it opens `#rooms` with the correct booking's detail modal; click a `meeting_created` notification and confirm it opens `#meetings` with the correct meeting's detail modal.
- [ ] **Attachment upload** — upload a file to a meeting as its creator; confirm a fellow participant can view/download it via the signed-URL flow but has no delete control; confirm the upload is rejected once the meeting is cancelled.
- [ ] **Route guards** — while logged out, attempt `#rooms` and `#meetings` directly by URL (redirects to login); while logged in to an org with Meetings disabled, attempt `#meetings` directly (renders "Module unavailable," not a blank or broken page).

---

## 8. Rollback playbook

**Rollback order is the exact reverse of the migration order in §4** — undo the most-recently-applied thing first, since later steps extend or depend on earlier ones (Step 3 modifies objects Step 2 created; Steps 4/5 only make sense once Steps 2/3 exist):

1. **Frontend rollback** (reverses §4 Step 6) — redeploy the previous static build, or simply leave files in place; with the routes deactivated next, `#rooms`/`#meetings` become unreachable regardless (fail-closed). **Data preserved:** all of it — this step touches no database object. **Data removed:** none.
2. **Meetings route deactivation** (reverses §4 Step 5) — `UPDATE platform_modules SET route = NULL WHERE module_key = 'meetings';`. **Data preserved:** everything; `organization_modules` enablement rows are untouched, so re-activating is a one-line reversal of this reversal. **Data removed:** none.
3. **Rooms route deactivation** (reverses §4 Step 4) — `UPDATE platform_modules SET route = NULL WHERE module_key = 'rooms';`. Same preservation/removal profile as step 2.
4. **Meetings backend rollback** (reverses §4 Step 3) — run `docs/rollback/003-meetings-foundation.md` §2's script **only after its §1 prerequisite checks pass** (no live `notifications`/`audit_logs`/`attachments` row may carry a Meetings-introduced value; delete such rows first if the rollback is proceeding regardless). **Critical ordering inside this script itself, already found and fixed once during local testing:** the `attachments_select`/`_insert`/`_delete` policies must be reverted to their pre-Meetings shape **before** `can_view_meeting()`/`can_manage_meeting()` are dropped, not after — reversing that order fails with a dependency error. **Data preserved:** `meeting_room_bookings` rows keep their history, including any `meeting_id` values, which become dangling references once `meetings` is dropped (expected, and safe as long as Meetings is not reapplied without first running §1b's cleanup); Rooms/Booking's own 4 tables, 10 RPCs, and all their data are completely untouched (confirmed by direct testing, `docs/rollback/003` §3). **Data removed:** `meetings`, `meeting_participants`, and every row in both.
5. **Rooms backend rollback** (reverses §4 Step 2) — run `docs/rollback/002-rooms-booking-foundation.md` §2's script, again only after its own §1 prerequisite check passes. **Note:** if step 4 above was skipped (Meetings never rolled back), this step will fail — `meeting_room_bookings` cannot be dropped while `meetings` still holds a live FK reference to rows that would need to survive it; Meetings must always be rolled back first. **Data preserved:** `platform_modules`/`organization_modules` and all pre-existing CorLink data (`organizations`, `users`, `requests`, `external_correspondence`, etc.) — confirmed untouched by direct testing. **Data removed:** `meeting_rooms`, `meeting_room_managers`, `meeting_room_blocks`, `meeting_room_bookings`, and every row in all four.
6. **Platform module foundation rollback** (reverses §4 Step 1) — run `docs/rollback/001-platform-module-foundation.md` §3's script. **Data preserved:** every pre-existing CorLink table; confirmed by direct testing that `organizations`/`users`/`requests`/`external_correspondence`/`prisoner_letters` counts are identical before and after. **Data removed:** `platform_modules`, `organization_modules`, and every row in both — this also silently reverts every module's nav visibility to the pre-Phase-1 "no Layer 1 opinion, always show" fallback behavior (`docs/04`'s documented `null`-fallback design), which is the **correct** restoration, not a side effect to worry about.

### Recovery procedures

- If a rollback step fails partway (a prerequisite check catches a live conflicting row), **the failing statement's own transaction rolls back atomically** — every rollback script in this repository is wrapped in a single `BEGIN`/`COMMIT` block specifically so a failure leaves the database in its exact pre-attempt state, confirmed directly during this session's own local testing for both `docs/rollback/002` and `docs/rollback/003` (§137, §418 of those documents respectively). Recovery is: resolve the reported conflict (usually: decide whether to delete the conflicting rows or abandon the rollback), then re-run the identical script.
- If Meetings needs to be **reapplied** after a rollback, run `docs/rollback/003` §1b's dangling-reference cleanup (`UPDATE meeting_room_bookings SET meeting_id = NULL WHERE ...`) first — confirmed as a real, tested requirement, not a hypothetical (`docs/rollback/003` §3's "dangling-reference reapply failure confirmed real").

### Post-rollback validation

After any rollback level, before considering staging stable again:

- Run the corresponding `docs/rollback/*.md` §4/§5's own "confirm existing functionality remains intact" checklist (login, Dashboard, Requests/Entry/Prisoner Correspondence/Administration all reachable, row counts on every untouched table match pre-rollback exactly).
- Re-run whichever `supabase/validate-*.sql` script(s) still apply at that rollback level — a validation script for a fully-rolled-back migration should report its target tables/functions as absent (`relation does not exist`-style errors), which is itself confirmation of clean removal, not a failure to be alarmed by.

---

## 9. Final review

- **No production environment touched** — every check this step performed was reading tracked `.sql`/`.md` files already in this repository; no `execute_sql`/`apply_migration`/any write-capable Supabase call was made (the connector is disconnected this session regardless — see §0).
- **No migrations applied** — anywhere, hosted or local. This step did not open a local Postgres session either; it is planning documentation only.
- **No frontend changes** — no `.js`/`.html`/`.css` file was modified.
- **No pushes** — this commit (§10) stays local, per every prior step's convention on this branch.
- **No MeetFlow modifications** — MeetFlow (`xvwileiyquqxxtzqxghm`) was not referenced by any tool call this step; it appears in this document only as prose context inherited from `docs/06`/`docs/07`.

---

## 10. Files changed

- `docs/17-staging-deployment-plan.md` (new, this file)

No other file was created or modified in this step.
