# Staging Auth and User Bootstrap Plan

**Type:** Planning only. No Auth configuration was changed, no user was created, no Edge Function was deployed, no frontend was deployed, and staging/production were not modified in producing this document.
**Date:** 2026-07-22
**Scope:** Defines the staging organizations, the minimum set of test accounts needed for acceptance testing, the naming/password conventions for those accounts, the exact module-enablement matrix, the Rooms/Meetings test scenarios, and the manual Auth settings that will need to be configured later (not now). This is the next planning layer on top of `docs/17-staging-deployment-plan.md` (deployment/validation plan) and `docs/18-staging-bootstrap-plan.md` (exact bootstrap file order) — both reviewed in full before writing this document — and reflects the state actually reached in `docs/19-staging-bootstrap-results.md` (canonical baseline + migration patch stack + idempotency fix all applied and verified against `vjobntuyzymhcuanyeak`).

---

## 0. What's already true on staging (from `docs/19`, not re-verified live this step)

- Schema/RLS/storage-policies/notifications baseline applied.
- All 5 migration-patch-stack files applied (platform modules, Rooms/Booking, Meetings, both route activations).
- All 3 validation scripts pass.
- The platform-module route-reset idempotency defect is fixed and verified.
- **Zero organizations, zero users, zero Auth accounts exist on staging.** `organization_modules` has 0 rows for the same reason — the seed's `INSERT ... SELECT FROM organizations` naturally produces nothing against an empty `organizations` table.
- Storage buckets (`attachments`, `org-logos`) exist with correct policies/limits.
- Edge Functions (`create-user`, `reset-password`) are **not** deployed to staging.
- Auth is **not** configured on staging beyond the automatically-provisioned API keys (Site URL, redirect URLs, password policy, JWT settings all still at Supabase's untouched defaults).

This plan is written against that starting point — a genuinely empty, but structurally complete, staging database.

---

## 1. Staging organizations

Two organizations, matching this application's own real, already-shipped one-directional design (`prisoner_letters_insert`'s `organizations.type = 'mcs'`/`'authority'` check, `docs/17` §6's persona table) rather than inventing a fictional relationship that wouldn't actually exercise that logic. Per `docs/18` §8's own flagged judgment call ("mirror real org names, or use fictional ones — not a technical blocker either way"), staging deliberately uses **distinct codes and display names from production's** so no export, screenshot, or dashboard view could ever be mistaken for the real thing, while still modeling the correct MCS→HRCM relationship the app's Prisoner Correspondence module depends on.

| Org | Type | Code | Name | Notes |
|---|---|---|---|---|
| **Org A** | `mcs` | `MCS-STG` | Maldives Correctional Service (Staging) | The sending side of Prisoner Correspondence; the org Rooms/Meetings get enabled for by default (see §6) |
| **Org B** | `authority` | `HRCM-STG` | Human Rights Commission of the Maldives (Staging) | The receiving side of Prisoner Correspondence (reply-only, per `prisoner_letters_insert`'s one-directional check); Rooms/Meetings deliberately left disabled by default, to exercise the "non-MCS org gets no scheduling access by default" behavior `docs/17` §6 documents |

**Two organizations, not three, is deliberate and sufficient**: `docs/17` §5 item 3's cross-org isolation check ("a staging user in one organization sees zero rows for another organization's rooms/bookings/meetings") is already specified against exactly this MCS-vs-authority pairing, mirroring `docs/11` test 9's own precedent (an HRCM-type user saw 0 MCS rooms). No third organization is required for any check currently defined in `docs/17`.

Both organizations' internal structure (at least one command/department for MCS-STG, one division for HRCM-STG, and at least one section each) must exist before any user account can be assigned — `users.org_id` is mandatory and every `user_assignments` row needs a real `scope_id`. This structure is not itself a user-account concern and is out of scope for this document; it is a prerequisite for §3 below, to be created via the app's own Admin > Structure UI once the first super admin can log in (see §10's bootstrapping-order note).

---

## 2. Test email / login-identity naming convention

Login identity is never a free-form email — `AUTH_DOMAIN = 'corlink.internal'` (`js/config.js`) means every account authenticates as `<service_number>@corlink.internal`. The **service number itself** is therefore the naming convention that matters.

**Convention:** `STG-<ORGCODE>-<ROLE>-<SEQ>`, e.g. `STG-MCS-SUPERADMIN-01`, `STG-HRCM-ADMIN-01`. This:
- Makes every staging account visually unmistakable from a real production service number in any log, audit-trail entry, or notification.
- Is stable and predictable across the 7 accounts in §3, so acceptance testers don't need a lookup table to know which login belongs to which persona.
- Never collides with a real production service number format (production numbers are assumed to follow the organization's real personnel numbering, not a `STG-` prefix).

The separate `users.email` column (real email, used only for notification display — this app currently has no functioning outbound email Edge Function at all, per `docs/18` §6, so this field is not actually deliverable to anyone today regardless) should use a clearly-fake, non-deliverable address per account, e.g. `stg-mcs-superadmin-01@corlink-staging.invalid` — the `.invalid` TLD is reserved by RFC 2606 specifically for this purpose, so even if outbound email is ever wired up later, these addresses can never accidentally reach a real inbox.

---

## 3. Minimum test accounts

Seven accounts, the minimum needed to exercise every distinct authority tier `docs/17` §6's acceptance matrix defines, plus the two roles (`assigned_receiver`, and an explicit `meeting_room_managers` grant) that table's personas depend on but that aren't separately called out as top-level personas.

| # | Persona | Login identity | Organization | `user_assignments` role | `is_super_admin` | `is_prisoner_letters_staff` | Explicit `meeting_room_managers` grant |
|---|---|---|---|---|---|---|---|
| 1 | Super admin | `STG-MCS-SUPERADMIN-01` | MCS-STG (home org; irrelevant to authority scope) | none needed | **TRUE** | not needed (super admin bypasses the flag everywhere it's checked) | no |
| 2 | MCS organization admin | `STG-MCS-ADMIN-01` | MCS-STG | `mcs_admin`, `scope_type='organization'` | FALSE | no | no |
| 3 | Supervisor | `STG-MCS-SUPERVISOR-01` | MCS-STG | `supervisor`, `scope_type='organization'` | FALSE | no | no |
| 4 | Normal staff | `STG-MCS-STAFF-01` | MCS-STG | `staff`, section-scoped | FALSE | no | no |
| 5 | Room manager | `STG-MCS-ROOMMGR-01` | MCS-STG | `staff`, section-scoped (deliberately **not** supervisor — see below) | FALSE | no | **yes**, for exactly one of the two test rooms created in §7 |
| 6 | HRCM authority admin | `STG-HRCM-ADMIN-01` | HRCM-STG | `authority_admin`, `scope_type='organization'` | FALSE | no | no |
| 7 | HRCM correspondence staff | `STG-HRCM-CORR-01` | HRCM-STG | `staff`, section-scoped | FALSE | **TRUE** | no |

**Why #5 (Room manager) must be a plain `staff` role, not `supervisor`:** `is_room_manager()` grants authority three independent ways — super admin, org-wide `supervisor`/`mcs_admin`/`authority_admin`, or an explicit `meeting_room_managers` row. If #5 also held `supervisor`, every negative test ("cannot approve a booking for a room they don't manage") would pass for the wrong reason (org-wide supervisor authority masking the room-scoped grant actually being tested). Keeping #5 at plain `staff` + one explicit grant is what makes the room-scoped (not org-wide) nature of `is_room_manager()` actually testable.

**Why #7 needs the `is_prisoner_letters_staff` flag and #6 does not automatically inherit it:** `is_prisoner_letters_staff()` is a flat per-user flag with **no** admin/supervisor fallback — this repository's own design deliberately excludes automatic access even for org admins (`schema.sql`'s comment on the column: "Set FALSE by default for every new user (including admins/supervisors)... independent of which section they otherwise belong to"). #6 (HRCM admin) is included specifically to test that an org admin **without** this flag still cannot see prisoner-letter content — a real, already-shipped restriction worth confirming on staging, not a gap in this plan.

### 3a. Per-account testing detail

| # | Persona | Required modules (once §6 enablement applied) | Permissions to test | Expected restrictions |
|---|---|---|---|---|
| 1 | Super admin | All 11, every org | Enable/disable a module for either org; cross-org room/meeting visibility in one session; self-approve own booking/meeting-cancel-with-no-reason via the override-reason path (audited distinctly) | None by design — confirm the override path is the *only* self-approval route (a bare self-approval attempt without override reason must still fail, even for a super admin) |
| 2 | MCS organization admin | Requests, Entry, Prisoner Correspondence, Administration, Rooms, Meetings | Manage every MCS-STG room/meeting org-wide with zero per-room/per-meeting grant; reach Administration | Cannot touch HRCM-STG's anything; cannot enable/disable modules for any org (`organization_modules_write` is super-admin-only) |
| 3 | Supervisor | Same as #2 | Same org-wide room/meeting authority as #2 (`docs/10` §8 Option D's org-supervisor branch) | Cannot reach Administration (`AppShell.isAdmin()` checks only `mcs_admin`/`authority_admin`, not plain `supervisor` — confirmed in `docs/17` §6) |
| 4 | Normal staff | Requests, Entry, Rooms, Meetings | Submit a booking (→ `pending`); create/edit/cancel own meetings; add/remove participants on own meetings | No Pending Approvals tab; cannot create/edit rooms; cannot manage another user's meeting |
| 5 | Room manager | Same as #4 | Sees Pending Approvals tab; can `create_room_booking`/approve/reject/reschedule **only** for their one managed room | Cannot act on the *other* test room; room-manager authority does **not** extend to meeting management (`can_manage_meeting()` has no room-manager branch — confirmed `docs/12`/`docs/17`) |
| 6 | HRCM authority admin | Requests, Entry, Prisoner Correspondence, Administration (Rooms/Meetings only if explicitly enabled per §6's optional step) | Administration reachable for HRCM-STG only; org-wide authority over HRCM-STG's own Rooms/Meetings **if** enabled | Cannot see/manage MCS-STG's anything (org isolation); cannot see prisoner-letter content without the separate `is_prisoner_letters_staff` flag (confirmed absent for this account, deliberately) |
| 7 | HRCM correspondence staff | Requests, Entry, Prisoner Correspondence | View/reply to letters MCS-STG sent (receiving side only) | Cannot compose an original prisoner letter (`prisoner_letters_insert` requires `from_prison_id`'s org `type = 'mcs'`); no Rooms/Meetings unless separately granted and enabled |

---

## 4. Password / reset strategy

- Accounts are created through the `create-user` Edge Function once deployed (see §10 — currently blocked), never by hand-writing `auth.users` rows directly, so the password-history/expiry bootstrap (`user_password_history`, `password_expires_at`) is set up correctly from account creation, matching how every real account is created today.
- Each account gets its own strong, randomly-generated initial password at creation time, meeting `auth-setup.md`'s policy (≥10 chars, upper/lower/number/special).
- **Actual passwords are never recorded in this document, this repository, or any committed file** — consistent with this whole migration project's standing instruction never to commit staging credentials. Whoever runs the actual account-creation step should store them only in a password manager or equivalent secure, non-versioned location.
- `reset-password` (once deployed) is the mechanism for any mid-testing password change — no account should ever need its password reset via direct SQL.
- The one necessary exception is the **very first** super admin account, which — per `docs/18` §8/§11 and `auth-setup.md` §4 — must be created by first creating the Auth user via the Supabase Dashboard (which sets its own initial password through that UI, not through `create-user`, since no super admin yet exists to call it), then running a hand-edited `create-super-admin.sql` INSERT against the resulting UUID. This is a one-time, unavoidable bootstrapping exception, not a precedent for the other 6 accounts.

---

## 5. Organization-module assignments

| Module | MCS-STG | HRCM-STG | Rationale |
|---|---|---|---|
| `requests` | ✅ enabled | ✅ enabled | Default-on for every org today (seed behavior, `docs/04`) |
| `entry` | ✅ enabled | ✅ enabled | Same |
| `prisoner_correspondence` | ✅ enabled | ✅ enabled | Same; also required for §3's #7 scenario |
| `administration` | ✅ enabled | ✅ enabled | Same |
| `rooms` | ✅ **enabled** (explicit, post-bootstrap) | ❌ disabled (default) | MCS-STG is the org Rooms/Meetings acceptance testing runs against by default |
| `meetings` | ✅ **enabled** (explicit, post-bootstrap) | ❌ disabled (default) | Same |
| `prison_registry`, `tasks`, `calendar`, `reports`, `document_signing` | ❌ disabled (default) | ❌ disabled (default) | Unshipped — `route IS NULL`, cannot be enabled regardless (enforced server-side, not just hidden client-side) |

**Optional additional step, not part of the default plan:** once MCS-STG's Rooms/Meetings scenarios (§7) are exercised and passing, a super admin can *additionally* enable Rooms and/or Meetings for HRCM-STG specifically to exercise `docs/17` §6's "authority organization user, module enabled" positive path (currently only the *disabled* path is covered by the default assignment above). Flagged here so it isn't silently missed, not scheduled as a required step in this plan.

---

## 6. Rooms/Meetings test scenarios

All scenarios run against **MCS-STG only** (per §5), using accounts #2–#5 from §3, in this order (mirrors `docs/17` §5/§7 directly, mapped onto this plan's specific accounts):

1. **Room provisioning** — #2 (MCS admin) or #3 (supervisor) creates **two** rooms in MCS-STG: `Room A` and `Room B`. #5 (room manager) is granted `meeting_room_managers` for `Room A` only, never `Room B`.
2. **Booking lifecycle** — #4 (staff) submits a booking for `Room A` (→ `pending`); #3 (supervisor) approves it (→ `confirmed`); #4 reschedules it; #3 cancels it with a reason.
3. **Room-scoped approval** — #5 (room manager) sees the Pending Approvals tab and can approve/reject a `Room A` request; a `Room B` request must **not** be approvable by #5 (only #2/#3/super admin can act on it) — this is the core defect-class this account exists to catch.
4. **Room blocks** — #5 creates a block over a free `Room A` window (succeeds); attempts a block over an existing confirmed `Room A` booking without an override (rejected); with an override reason (succeeds, booking left untouched).
5. **Meeting lifecycle** — #4 creates a draft meeting, publishes it to `scheduled`, adds #5 as an internal participant and one external participant (name/email only, no account), assigns `Room A` to it, confirms the linked booking's time/timezone match, detaches the room and confirms `location_mode` clears.
6. **Cancellation asymmetry** — #4 cancels a meeting with an active linked booking and confirms both become `cancelled` atomically; separately, #3 cancels a *different* meeting's linked booking directly through Rooms (not via Meetings) and confirms the meeting itself is **unaffected** (the documented, deliberate asymmetry — `docs/12` §11).
7. **Participant privacy** — #5 (non-privileged, an ordinary participant on #4's meeting) calls `meeting_participant_list()` and confirms external participants' contact fields are redacted; #4 (the creator, privileged) confirms they are not.
8. **Cross-org isolation** — #6 or #7 (HRCM-STG) attempts to view any MCS-STG room/booking/meeting and confirms zero rows, regardless of HRCM-STG's own module-enablement state.

---

## 7. Mapping to `docs/17` §6's acceptance matrix

`docs/17` defines 7 personas; this plan's 7 accounts cover 5 of them one-to-one, and the remaining 2 are covered without a *dedicated* account, noted explicitly rather than silently dropped:

| `docs/17` persona | Covered by | Note |
|---|---|---|
| Ordinary staff | Account #4 | Direct match |
| Room manager | Account #5 | Direct match |
| Supervisor | Account #3 | Direct match |
| Super admin | Account #1 | Direct match |
| Authority organization user | Accounts #6 (admin tier) and #7 (staff tier) | `docs/17`'s single persona row is split into two accounts here since this plan also needs to separately test the `is_prisoner_letters_staff` flag's admin-does-not-auto-inherit-it behavior (§3's #6/#7 rationale) |
| **Participant** | **No dedicated account** — exercised by adding account #5 (or any non-creator account) as a participant on a meeting created by account #4, per §6 scenario 7 | Not a distinct login identity; a role a test account plays situationally |
| **Anonymous user** | **No account at all** — exercised with a logged-out browser session | By definition has no login identity to provision |

---

## 8. Auth settings that must be configured manually later (not now)

Restated from `docs/18` §5, none of this is expressible as SQL and **none of it has been changed by this planning step**:

| Setting | Required value | Status |
|---|---|---|
| **Site URL** | The staging frontend's own deployed URL | **Cannot be set yet — the URL itself doesn't exist.** Blocked on the frontend-deployment step (`docs/17` §4 Step 6), which is out of scope for this plan and not yet scheduled. |
| **Redirect URLs** | Same staging URL(s), whatever they turn out to be | Same blocker as Site URL |
| **Email templates** | Likely no changes needed | This app never relies on Supabase's own auth-email flows (no self-registration, no email-confirmation step — `auth-setup.md` §3: "Email confirmations: OFF", "Signup: disabled") — flagged as low-priority/likely-no-op rather than a hard requirement, but not yet confirmed by inspecting the actual template contents on this project |
| **Enabled providers** | Email/password only | No OAuth or social provider is referenced anywhere in this codebase |
| **JWT expiry** | 1800s (30 min), matching `SESSION_TIMEOUT_MINUTES` in `js/config.js` | Not yet set — still at Supabase's project default |
| **Refresh token rotation** | ON, 10s reuse interval | Not yet set |
| **Password policy** | Enforced client-side + by the `create-user`/`reset-password` Edge Functions (not by Supabase Auth natively) | N/A to Auth dashboard config directly — restated here for completeness since it's part of the same `auth-setup.md` §3 checklist |

---

## 9. Blocked items

Everything in this document remains a **plan** until these are resolved, in this dependency order:

1. **Edge Functions not deployed to staging** (`create-user`, `reset-password` — `docs/18` §6/§11). Without them, no account in §3 can be created through the app's own admin flow. This is the single largest blocker — nothing in §3 can actually happen until it's resolved.
2. **No super admin exists yet, and creating the first one is itself blocked by #1's absence** — the standard flow (an existing super admin uses the admin UI, which calls `create-user`) has no bootstrap super admin to start from. The documented escape hatch (`docs/18` §8/§11: create the Auth user via Dashboard, then hand-run `create-super-admin.sql`) is the only way to break this cycle, and has not been executed — it requires a deliberate, separately-authorized step, not something this planning document performs.
3. **No organizations or structure exist yet** (§1's MCS-STG/HRCM-STG, plus each org's commands/departments/divisions/sections) — creating them requires either direct SQL (a deliberate, separately-authorized step, consistent with how `seed.sql` itself is described in `docs/18` §8 as "not a run-as-is script") or the Admin UI, which itself requires #2's super admin to already exist and be logged in.
4. **Frontend not deployed to staging** (`docs/17` §4 Step 6) — blocks §8's Site URL/redirect URL values from even being knowable, and blocks every UI-driven step in §6/§7 from being executable at all (there is no admin UI to click through without a deployed frontend).
5. **Auth settings genuinely unconfigured** (§8) — deliberately left untouched by this step, per instruction; listed so the next execution step has an exact, non-ambiguous checklist rather than needing to re-derive it from `auth-setup.md` again.

None of these blockers were addressed by this step — this document is the plan for resolving them, not the resolution itself.

---

## 10. Final review

- **No Auth setting was changed** — this step performed no Supabase Auth dashboard or API call of any kind.
- **No user was created** — no `auth.users`, `public.users`, or `user_assignments` row was inserted anywhere.
- **No Edge Function was deployed.**
- **No frontend was deployed** — no `.js`/`.html`/`.css` file was modified.
- **Staging (`vjobntuyzymhcuanyeak`) was not modified** — this step made no Supabase MCP tool call at all (the connector was disconnected for this step regardless, per the session's ambient state, but this step's own scope — pure documentation — required no live check either way).
- **Production (`infjjroktzzhaxjvfknr`) was not touched.**
- **No push occurred** — this commit stays local, per every prior step's convention on this branch.
- **No Git signing configuration was changed.**

---

## 11. Files changed

- `docs/20-staging-auth-and-user-bootstrap-plan.md` (new, this file)

No other file was created or modified in this step.
