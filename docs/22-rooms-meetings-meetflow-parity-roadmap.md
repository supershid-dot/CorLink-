# 22 — Rooms, Calendar, Meetings & Meeting Administration: MeetFlow Parity Roadmap

**Status: PLANNING ONLY, DECISIONS FINALIZED. No code, schema, or configuration has been changed. Nothing in this document has been applied anywhere. All six open design questions (§5) have been decided by the project owner. This roadmap requires explicit approval before any implementation step begins.**

**Directive:** CorLink's Rooms, Calendar, Meetings, and Meeting Administration should reach **feature and workflow parity** with MeetFlow — not code parity, not architecture parity. Every item below is filtered through one rule: **build what MeetFlow's users can *do*, using CorLink's own architecture to do it.** Where MeetFlow's implementation of a workflow is itself insecure, single-tenant, or client-side-only, that implementation is not the target — only the user-facing capability is.

This document was produced from two full, independent research passes (every CorLink Rooms/Meetings design doc, migration, and shipped frontend file; every line of MeetFlow's schema, frontend, and login function), then refined through six explicit design decisions made by the project owner (§5). Specific table/column/RPC/line-number citations below come from those research passes.

---

## 1. Non-negotiable architecture constraints

Every feature decision in §3 is filtered through these. None of them are up for reinterpretation per-feature — they are the definition of "preserving CorLink's architecture" the directive asked for.

1. **Multi-organization isolation.** Every new table gets `org_id`/`organization_id`; every new RPC and RLS policy is org-scoped. MeetFlow has no organizations at all (single global tenant) — nothing about its data model transfers directly.
2. **Real server-side RLS, not blanket allow.** MeetFlow's entire authorization model (once its optional "Step 2" is even run) is one `USING (true) WITH CHECK (true)` policy per table, with **zero CHECK constraints anywhere in its schema** — every "permission," "privacy," "lock," and "conflict" MeetFlow appears to enforce is client-side JavaScript only, invisible to a direct REST call. CorLink's existing convention for Rooms/Meetings — SELECT-only RLS, all writes through audited `SECURITY DEFINER` RPCs, real CHECK constraints, real exclusion constraints — is the pattern every new table and RPC below must follow.
3. **Permissions via the existing role system.** Reuse `user_assignments`/`is_admin()`/`is_supervisor_or_above()`/`is_room_manager()`/`can_manage_meeting()` and section/org scoping. No new flat `role` column, no new ad hoc boolean flags on `users`, no client-side-only permission checks. MeetFlow's `staff.role` + `can_view_all`/`can_create_groups`/`can_request_users` flags do not get ported as a model — only the *capabilities* they gate (see §3) get re-derived from CorLink's own role system.
4. **Module gating stays authoritative.** `platform_modules.route` + `organization_modules.is_enabled` continue to gate every new screen/feature exactly as they gate Rooms/Meetings today. The new Calendar surface (§3.2) needs its own module key and route, seeded `route IS NULL` until explicitly activated, following the exact same two-step pattern already used for `rooms`/`meetings`.
5. **CorLink's own design system and branding.** No MeetFlow visual language, layout, or component patterns get ported — new UI (the calendar grid in particular) gets built using CorLink's existing CSS conventions, dark-mode support, and Divehi/RTL handling (`js/views/*.js`, `css/style.css`), the same way Rooms/Meetings' existing screens already do.
6. **Auth stays exactly as-is.** CorLink's Supabase Auth + synthetic `serviceNumber@corlink.internal` email convention is untouched. MeetFlow's own login mechanism, `staff` table, `MF_JWT_SECRET`, and `meetflow-login` Edge Function were already retired per `docs/03` — nothing in this roadmap reopens that decision.
7. **UUID PKs, existing `attachments` system, existing in-app notification bell, existing `audit_logs` with server-derived actor identity.** MeetFlow's serial-int PKs, link-only "documents" hack, Telegram-first notification model, and client-supplied audit actor fields are not the target shape for any of the corresponding CorLink features — see §4 for the specific list of MeetFlow behaviors that must not be replicated even where the underlying *capability* is in scope.

---

## 2. What CorLink already has that must be the foundation, not be replaced

This matters because in several places CorLink's existing "V1" implementation is **already more capable and more secure than MeetFlow's equivalent**, despite MeetFlow having more surface-level features. New work extends this foundation; it does not rebuild it.

- **Room booking conflict prevention is real and server-enforced** (`btree_gist` `EXCLUDE` constraint on `meeting_room_bookings` + `meeting_room_bookings_conflict_guard()` trigger with advisory-lock ordering) — MeetFlow's equivalent is 100% client-side JavaScript, trivially bypassable via a direct REST call, confirmed by the MeetFlow research pass.
- **Room blocks (maintenance holds) are actually enforced** — CorLink's `meeting_room_blocks_conflict_guard()` trigger checks new blocks against active bookings and vice versa, recording impacted booking IDs. MeetFlow's `room_blocks` is confirmed **purely decorative** — it visually hatches the Rooms-tab grid but is never consulted by the booking-save code path at all, so a "blocked" room can still be booked through the normal flow.
- **Meeting visibility (private/participants/organization) is enforced server-side** via `can_view_meeting()`/RLS. MeetFlow's `privacy` field is confirmed **UI-only obfuscation** — the full row (notes, minutes, attachments, nested participants) is present in every `GET meetings` response regardless of privacy; only rendering is gated client-side.
- **All Rooms/Meetings writes go through audited `SECURITY DEFINER` RPCs with server-derived actor identity** (`auth.uid()`), never a client-supplied actor field. MeetFlow's `logAudit()` takes `actor_id`/`actor_svc`/`actor_name` straight from client state — forgeable by design, independent of its RLS gaps.
- **Attachments already use CorLink's real file-upload system** (Meetings only, so far) — MeetFlow's "Documents" feature is link-only (user-pasted URLs, not uploaded files, since MeetFlow has zero Storage buckets).
- **Self-approval is blocked**, org isolation is real, and every enum-like column has a genuine CHECK constraint. None of this exists in MeetFlow's schema at all (zero CHECK constraints anywhere, confirmed by full-file review).

Any new feature below that touches these areas extends this existing foundation — it does not introduce a parallel, weaker mechanism alongside it.

---

## 3. Feature-by-feature comparison

Legend: **✅ MATCHES** (CorLink already has an equivalent or better capability) · **➕ MISSING** (net-new build, no fundamental redesign needed) · **🔧 REDESIGN** (MeetFlow has the capability, but it must be rebuilt against CorLink's architecture, not ported) · **✔ DECIDED** (previously open, now resolved — see §5) · **🚫 EXCLUDED** (see §4 — must not be replicated regardless of MeetFlow having it)

### 3.1 Rooms

| Capability | Status | Notes |
|---|---|---|
| Room CRUD (name, capacity) | ✅ | CorLink's `meeting_rooms` (name/capacity/`bookable_until`) is already cleaner than MeetFlow's `rooms` (name/capacity/`end_hour`, where **both `capacity` and `end_hour` are confirmed dead columns** — never read, written, or displayed anywhere in MeetFlow's code). |
| Booking request → approve/reject workflow | ✅ | Already implemented, server-enforced, self-approval blocked. Superior to MeetFlow's equivalent (§2). |
| Conflict prevention | ✅ | Server-enforced exclusion constraint + trigger vs. MeetFlow's client-only, bypassable check (§2). |
| Room manager grants | ✅ | `meeting_room_managers` (additive, org-scoped) has no real MeetFlow analog — MeetFlow's closest concept is global-admin-or-section-co-management, which is coarser. |
| Room maintenance blocks | ✅ | Real and enforced in CorLink; decorative-only in MeetFlow (§2) — CorLink's version is already the correct target, not MeetFlow's. Now also a first-class Calendar item type (§3.2, Q5). |
| **Visual calendar/week-grid room schedule** | ➕ | MeetFlow's Rooms tab shows a 7-day grid (desktop) / day-agenda (mobile) per selected room, with the block overlay drawn directly on it. CorLink's "Schedule" tab is a single-day list only. Build as an extension of the Calendar grid component (§3.2/Phase D), reused for a room-scoped view — not a separate implementation. Sequenced after Calendar itself (Phase C), since Phase D reuses Phase C's component. |
| Dynamic duration capping to actual room availability | ➕ | Low-risk UX addition on top of the existing `check_room_availability` RPC — cap the duration/end-time picker to the next actual conflict instead of only validating on submit. |
| Hold-creation UI | ➕ | RPC (`create_booking_hold`) already exists and is unused by the frontend (`docs/15` confirms this was a deliberate V1 omission, not an oversight). Small addition if wanted; not requested by the MeetFlow comparison specifically (MeetFlow has no "hold" concept distinct from a pending/confirmed booking), so **not required for parity** — optional. |

### 3.2 Calendar (new module — SHIPPED, narrower scope than originally decided)

**✔ DECIDED (Q5):** Calendar is CorLink's **single, complete schedule view**, not a meetings-only view. It shows five distinct item types, each visually distinguishable, each routing to its own correct detail screen:

| Item type | Visual treatment | Selecting it opens |
|---|---|---|
| Meeting | Standard event styling, colored by section (as MeetFlow does) | Meeting Details |
| Draft / Pre-booked Meeting (§3.3, Q4) | Distinct dashed/draft styling | Draft Meeting editor (the standard meeting-edit flow, pre-filled) |
| Recurring meeting occurrence (§3.3, Q3) | Standard meeting styling + a recurrence indicator icon | Meeting Details for that specific occurrence |
| Standalone Room Booking (no linked meeting) | Distinct styling from a meeting (different from both meeting and draft treatments) | Room Booking details |
| Room Block / Maintenance | Admin-view or optional filter, hatched/blocked styling (matching the existing Rooms-tab visual language) | Room Block details |
| Staff leave (§3.4, Q6) | Visual indicator on the affected person's schedule | Leave record detail (lightweight) |

**Status: SHIPPED, with narrowed scope** — `js/data/calendar-api.js`, `js/views/calendar.js`, `supabase/patch-calendar-route-activation.sql`, committed `edd02b4`. Calendar shipped supporting **four** of the six item types above (Meeting, Recurring occurrence, Standalone Room Booking, Room Block/Maintenance); the bulk Draft/Pre-booked Meeting mechanism and Staff leave are not yet data sources, since neither underlying feature exists yet. This deviates from the sequencing note below, which called for both Phase F (Recurring/Drafts) and Phase H (Leave) to complete before Calendar begins — Calendar shipped after Phase F's Recurring Meetings Phase 1 alone, with the bulk pre-booking mechanism and Leave both still pending. See `docs/26-calendar-design-decisions.md` for the full reconciliation, including the architecture decision (client-side composition over the three existing APIs, no new RPC, no new RLS) and every other deviation from this section's original text. **The single-draft-meeting `status='draft'` state (distinct from the bulk mechanism — see §3.3 Q4 below and `docs/27-draft-meetings-design-decisions.md`) was already rendered by Calendar from day one and has since been fully hardened; Calendar itself required no change for that.**

Because Calendar must render all of the above from day one, it is sequenced **after** Recurring Meetings/Draft Meetings (Phase F) and Leave Management (Phase H) in §6 — not before them as originally proposed. Building it earlier would mean immediately reworking it once those data sources exist. *(As shipped, this ordering was not fully honored — see status note above.)*

| Capability | Status | Notes |
|---|---|---|
| Week-grid / day-agenda visual schedule | ✅ (shipped, list-style not positioned-grid) | Shipped as day/week/month/agenda views, each listing events per day/column rather than positioning them against a time axis. Client-side composition only — no `calendar_events_for_range()` RPC was built; `docs/23` §2's own "decide only after measuring" clause permitted this, and no measurement ever showed it necessary. Positioned hour-grid remains a deferred improvement (`docs/26` §5). |
| Staff picker — view another staff member's schedule | ➖ deferred | Not built. MeetFlow's broken per-viewer-grant mechanism (`ssa_viewer_<staffId>`, described below) remains correctly unreplicated — no equivalent mechanism, safe or otherwise, exists in this codebase. Calendar's only participant filter is a self-scoped "only my meetings" toggle. MeetFlow gates this with `can_view_all` (global admin-equivalent flag) plus a genuinely broken mechanism: per-viewer grants stored as a JSON array in a generic `app_config` key (`ssa_viewer_<staffId>`), confirmed **directly writable by any authenticated staff member for any other staff member's key** under MeetFlow's blanket RLS — a real, concrete privilege-escalation path found during this research, not a hypothetical. **Do not replicate this mechanism at all.** Rebuild "whose schedule can I view" purely from CorLink's existing role system: org admin/supervisor sees their scope (section/org) exactly as `is_supervisor_or_above()` already defines it elsewhere in the app; no new grant table, no new flag. |
| Section-based color coding | ➖ deferred | Not built. Events are styled by type (meeting/booking/block/locked/draft), not by section. |
| `.ics` calendar export | ➖ deferred | Not built. |
| Merge standalone room bookings, drafts, recurring occurrences, room blocks, leave into one view | 🔧 partially shipped | Standalone room bookings, recurring occurrences, and room blocks are merged and de-duplicated (a room-booked meeting renders once, not twice); single-draft meetings (`status='draft'`) render with distinct styling and are fully hardened as of `docs/27`. The bulk pre-booking mechanism and leave are absent, since neither exists elsewhere in the app yet — see `docs/26` §2/§3/§8. |

### 3.3 Meetings

| Capability | Status | Notes |
|---|---|---|
| One-off meeting create/edit/cancel | ✅ | Already implemented, RLS-enforced. |
| Internal + external participants, one table | ✅ | Already implemented (`meeting_participants`, XOR-enforced identity). |
| Visibility (private/participants/organization) | ✅ | Server-enforced (§2) — superior to MeetFlow's cosmetic `privacy` field. Preserve, extend, never weaken. |
| Room assignment/detach, linked to Rooms module | ✅ | Already implemented via `meeting_room_bookings.meeting_id` as the sole pointer — deliberately avoids the dual-source-of-truth problem MeetFlow's inline `meetings.room_id` has. Preserve this design; do not inline a room reference back onto `meetings`. |
| Attachments | ✅ | Real file uploads via the existing shared attachments system — better than MeetFlow's link-only "Documents" panel (§2). Extend the existing mechanism (e.g. delete support, if ever added) rather than building a parallel link-list feature. |
| **RSVP (participant accept/decline + note)** | ➕ | Schema already has `invitation_status` (`pending`/`accepted`/`declined`/`not_required`) — **the data model already matches MeetFlow's `rsvp` concept**. What's missing is purely the workflow: no RPC exists to let a participant update their own `invitation_status`, no UI to do it. This is the smallest, safest, highest-value gap to close first. |
| **Attendance marking** | ➕ | Same situation as RSVP — `attendance_status` column exists, no RPC, no UI. Small, safe, closes an existing schema/UI mismatch rather than requiring new design. |
| **Meeting minutes** (shared, finalizable) | ➕ | Net new columns (`minutes`, `minutes_finalized`, `minutes_updated_by`/`_at`) + two RPCs (`update_minutes`, `finalize_minutes`) + edit gating (creator/supervisor/admin; locked to admin-only once finalized, mirroring MeetFlow's actual behavior). No new tables. |
| **Personal private notes per participant** | ➕ | Net new column on `meeting_participants` (`personal_notes`) + one RPC restricted to updating the caller's own row (already the exact restriction pattern `meeting_participants_select` uses today for non-managers). |
| **Meeting "lock"** | ✔ DECIDED (Q2) | **Final permission tiers:** Creator — can always lock/unlock/edit/cancel their own meeting. Organization Administrator — can override a lock, but only within their own organization. Super Administrator — can override any lock, across all organizations. Supervisors, Room Managers, and normal staff **cannot** override a lock under any circumstance — this specifically overrides the normal "any co-worker in the same section can co-manage a meeting" rule while locked. |
| **Recurring meetings / series** | ✔ DECIDED (Q3) — **Phase 1 and Phase 2 shipped** | **Final approach: true recurring-series architecture, built in two phases.** — See dedicated breakout below. **Phase 1 (weekly/bi-weekly/monthly, single-transaction bulk creation, individually editable/cancellable occurrences) has shipped** (`supabase/patch-meetings-recurring.sql`). **Phase 2 (this/future/all-series edit and cancel, series authorization, series exceptions, notification suppression) has shipped and is approved** — `update_entire_series()`, `update_series_this_and_future()`, `cancel_entire_series()`, `cancel_series_this_and_future()`. See `docs/25-recurring-meetings-phase1-design-decisions.md` (Phase 1) and `docs/28-recurring-meetings-phase2-implementation.md` (Phase 2). |
| **Pre-booking / placeholder meeting slots** | ✔ DECIDED (Q4) — **single-draft workflow SHIPPED, bulk mechanism pending** | **Final model: Draft Meeting.** Lives entirely in the Meetings module. A draft meeting may or may not have a room; may or may not have participants. Appears on Calendar with a clear Draft/Pre-booked visual indicator (§3.2). Anyone with permission can open it and complete the remaining details. **Converting a draft into a real meeting reuses the standard meeting-edit workflow — it is not a separate "convert" mechanism.** Integrates with recurring meetings: bulk-creating a batch of draft slots across a date range × days-of-week × time window is a specific application of the recurring-meeting creation machinery (Phase F, below) with a draft flag, not a second, separately-built bulk-create feature. **The single-meeting draft lifecycle (create/edit/activate/delete, notification suppression, RSVP/attendance/minutes/lock rejection) shipped** (`supabase/patch-meetings-drafts.sql`, committed `b6ee08c` — see `docs/27-draft-meetings-design-decisions.md`). **The bulk date-range × days-of-week creation mechanism remains unbuilt and pending.** |
| **Meeting groups** (named, reusable invite lists) | ➕ | Net new: two org-scoped tables (members; who-may-use-this-group), real RLS (not MeetFlow's blanket allow), admin-managed UI, and a "one-click add all members" convenience wired into the existing Add Participant modal. |
| **Notify participants** (schedule/reminder/custom message) | ✔ DECIDED (Q1) | **Final approach: in-app notification bell only, plus a reliable server-side scheduled reminder job (`pg_cron`, mirroring the existing `check_deadlines()` pattern), firing a new `meeting_reminder` notification type before the meeting starts.** No Telegram integration, no outbound email integration, at this time. Both remain available as separate, optional future integrations that must not block this roadmap. This is materially more reliable than MeetFlow's own mechanism, which is confirmed to simply never fire a reminder if nobody has the app open in a browser tab when it comes due. |
| **Global search over meetings** | ➕ | CorLink already has topbar global search (reference number/subject, per prior work) — likely a small addition to extend it to meetings/rooms if not already covered; verify current scope before treating as net-new work. |
| `.ics` export | ➕ | Same as Calendar's — no new security surface. |

#### Recurring meetings — detailed, phased scope (Q3)

**Architecture:** a true recurring-series system — a series definition record plus individually-addressable occurrence rows that remain linked to it — designed from the start to support Phase 2, even though the initial UI only exposes Phase 1. This means the schema (series table, occurrence linkage, exception/override representation) and the RPC surface are built for the full model up front; only the *frontend* is scoped down for the first release.

**Phase 1 — required for MeetFlow parity, ships first: SHIPPED** (`supabase/patch-meetings-recurring.sql`; see `docs/25-recurring-meetings-phase1-design-decisions.md` for the full design-decision record).
- Recurrence patterns: weekly, every 2 weeks, monthly.
- End date (no open-ended/"forever" recurrence).
- Single server-side transactional RPC creates every occurrence at once (not a client-side loop of individual round-trips, unlike MeetFlow's own implementation).
- Each occurrence is individually editable and individually cancellable once created.
- No "edit the whole series at once" UI in this phase — that's Phase 2.

**Phase 2 — CorLink enhancement, ships once Phase 1 is stable:**
- Edit this occurrence only.
- Edit this and all future occurrences.
- Edit the entire series.
- Cancel one occurrence.
- Cancel future occurrences.
- Cancel the entire series.
- Exception dates (a specific date in the pattern is deliberately skipped/removed from the series).
- Skipped occurrences (distinct from cancelled — a date that was never generated in the first place, e.g. after an exception is applied).

**Design implication for Phase 1's schema work:** every occurrence row needs a way to reference (a) the series it belongs to, (b) its position/date within that series, and (c) whether it has ever been individually detached/edited away from the series definition (needed for Phase 2's "this occurrence only" edits to not silently get overwritten by a later "edit all future" operation) — this must be modeled in Phase 1 even though no UI exposes it yet.

### 3.4 Meeting Administration

MeetFlow's Admin tab bundles two very different things: (a) generic staff/section/org administration, which CorLink's **existing Admin Portal already does, and does better** (real `user_assignments` scope model vs. MeetFlow's flat section+extras; existing Audit Log tab; admin-created-user Edge Functions vs. MeetFlow's self-request-and-cleartext-Telegram-send flow); and (b) genuinely Rooms/Meetings-specific administration, which is the actual parity gap.

| Capability | Status | Notes |
|---|---|---|
| Staff/user CRUD, roles, section structure | ✅ | Already exists and is architecturally richer — do not duplicate inside a Rooms/Meetings-specific admin screen. |
| Audit log viewer | ✅ | Already exists (Admin Portal). |
| New-user / password-reset flow | ✅🚫 | CorLink's `create-user`/`reset-password` Edge Functions (admin-initiated, one-time in-UI password display) are already the correct, more secure pattern. **Do not build MeetFlow's self-request-then-admin-approves-then-cleartext-Telegram-send flow at all** — see §4. |
| Room CRUD, room managers | ✅ | Already lives inside the Rooms module itself (not a separate admin screen) — matches CorLink's existing per-module self-administration pattern (e.g. Entry's own section picker). Keep it there for Rooms; do the same for any new Meetings-specific admin surface below rather than centralizing into the generic Admin Portal. |
| **Meeting groups CRUD** | ➕ | Lives inside the Meetings module's own admin/settings area, consistent with the Room CRUD precedent above — not the generic Admin Portal. |
| **Leave management (staff leave records + types)** | ✔ DECIDED (Q6) | **Final scope: lightweight, advisory-only, "leave management-lite."** Specific requirements: (1) Staff can record their own leave. (2) Organization Administrators can manage leave records within their own organization (create/edit/remove on behalf of staff, not just view). (3) Leave *types* are managed centrally as a real, shared, org-level setting — not MeetFlow's browser-local-only list. (4) Leave appears on the Calendar with its own visual indicator (§3.2). (5) Meeting organizers get a warning when inviting someone who is on leave. (6) **Leave never automatically blocks anyone from being added to a meeting** — warning only, no enforcement, matching MeetFlow's own actual (non-)enforcement level exactly. **Explicitly not an approval workflow** — no supervisor sign-off step, no pending/approved/rejected state. **Forward-compatibility note:** if CorLink ever introduces a dedicated HR/Leave Management module, this functionality should be designed so it can integrate with that module later rather than be duplicated by it — keep the leave-record table and its access boundary narrow and self-contained for exactly this reason, rather than growing bespoke workflow logic here that a future dedicated module would need to un-do. |
| **Org-level Rooms/Meetings configuration** (e.g. working-hours defaults) | ➕ (optional) | MeetFlow's "Calendar Hours" panel is also confirmed localStorage-only (global, not per-admin-session-shared, not per-org) — not a real feature to replicate as-is. If wanted, this is a genuinely new, small feature: a real `organization_modules.configuration` JSONB entry (the slot already exists per `docs/09`, currently unused) read by the Calendar/Rooms views. Flag as nice-to-have, not required for parity, since MeetFlow's own version isn't real shared configuration either. |
| **Dashboard integration** (Action-Needed rows, Home-tab-equivalent stats) | ➕ | Currently **zero** Rooms/Meetings presence anywhere on CorLink's dashboard (confirmed by grep — no matches at all), unlike Entry/Requests which both have dedicated rows. This isn't really a MeetFlow-parity item (MeetFlow's "Home" tab is its own thing, Meetings-specific: next-meeting banner, today's count, pending-RSVP count) so much as bringing Rooms/Meetings up to CorLink's *own* existing convention — but it directly covers the same underlying workflows MeetFlow's Home tab provides, so it's included here as in-scope. |

---

## 4. Explicitly excluded — MeetFlow behaviors that must never be ported

These are not "deferred" — they are confirmed, specific anti-patterns found during the MeetFlow research pass that must not be replicated in CorLink under any interpretation of "parity," because the directive explicitly says to preserve CorLink's architecture (auth, RLS, permissions, modules) while matching MeetFlow's *workflows*, not its implementation quality:

1. **MeetFlow's own login/auth mechanism** (`staff` table, hand-rolled PBKDF2, custom-signed JWT via `MF_JWT_SECRET`, three-way password-verify fallback including **plaintext-equality comparison**) — already retired per `docs/03`, stays retired.
2. **Blanket `USING(true)` RLS or RLS-disabled tables**, and **free-text "enum" columns with zero CHECK constraints** — every new table follows CorLink's existing SELECT-only-RLS-plus-audited-RPC convention with real CHECK constraints, exactly like every table already in `schema.sql`.
3. **Flat `role` + ad hoc boolean-flag permission model** — new capabilities map onto `user_assignments`/existing role helpers, never a new flag column on `users`.
4. **Client-side-only enforcement of anything security- or business-rule-relevant** — room conflicts, privacy, lock state, minutes-finalized state, recurrence limits, and any new booking/meeting rule must be enforced server-side (RPC/RLS/trigger/CHECK), not merely hidden or disabled in the UI. This is the single most common MeetFlow anti-pattern found (confirmed independently for: room-conflict checking, `is_locked`, `minutes_finalized`, `privacy`, and every "enum" column). The now-decided meeting-lock override tiers (Q2) must be enforced the same way — server-side, not a UI-only gate.
5. **Serial integer PKs** — CorLink is UUID-only throughout; no exceptions for new Rooms/Meetings/Calendar tables.
6. **Telegram bot integration and `mailto:`-based "email."** **Now formally decided, not just recommended (Q1):** not built at this time. CorLink's in-app notification bell plus a scheduled reminder job is the approach. Telegram and real email delivery remain available as separate, optional future integrations, explicitly not gating or blocking any part of this roadmap.
7. **Cleartext credential transmission** — MeetFlow sends freshly-generated temp passwords in plaintext over the Telegram Bot API to both the new user and the requesting admin, for both new-user creation and password reset. CorLink's existing `create-user`/`reset-password` Edge Functions already do this correctly (one-time in-admin-UI display, never transmitted elsewhere) — this pattern is not touched or regressed by anything in this roadmap.
8. **Self-service "request a new account for yourself" flow** — MeetFlow lets any `can_request_users` staff member request a brand-new account be created, approved later by an admin. CorLink's existing admin-creates-user model is the correct pattern and is not replaced.
9. **Client-supplied audit-log actor identity** — every new RPC continues CorLink's existing convention of deriving the actor from `auth.uid()` server-side, never accepting an actor field from the client, unlike MeetFlow's `logAudit()`.
10. **Weak/non-cryptographic randomness for anything security-adjacent** — e.g., the new recurring-series identifiers (Q3) must be real UUIDs (`gen_random_uuid()`), not `Date.now().toString(36)` as MeetFlow uses; called out specifically because Recurring Meetings/Draft Meetings (Phase F) is new work where this could otherwise be copied from MeetFlow's implementation by habit.
11. **Destroy-and-recreate of related rows on edit** — MeetFlow deletes and fully re-inserts every `participants` row on every meeting edit, silently discarding RSVP/attendance/personal-notes history for unaffected participants. Any new/modified `update_meeting`-style RPC must diff, not replace.
12. **Decorative-only room blocks and cosmetic-only privacy** — already covered in §2; explicitly restated here because they're the two clearest examples of "MeetFlow *appears* to have this feature but it provides no actual guarantee," and a parity effort focused only on visible UI could otherwise reintroduce exactly this gap by copying the visible behavior without the enforcement CorLink already has.
13. **A leave-approval workflow.** Explicitly decided against (Q6) — leave management stays advisory-only, matching MeetFlow's own actual (lack of) enforcement, not a new approval system layered on top of it.

---

## 5. Resolved design decisions

All six open questions from the original roadmap draft have been decided by the project owner. Recorded here for permanent reference; §3 and §6 have been updated throughout to reflect these.

| # | Question | Decision |
|---|---|---|
| 1 | Telegram/email integration | **In-app notification bell + reliable server-side scheduled reminders only.** No Telegram, no outbound email, at this time. Both remain optional future integrations that must not block this roadmap. |
| 2 | Meeting lock override scope | **Creator** — always full control of their own meeting. **Organization Administrator** — can override a lock within their own organization only. **Super Administrator** — can override any lock, org-wide. Supervisors, Room Managers, and normal staff cannot override a lock. |
| 3 | Recurring meetings design | **True recurring-series architecture, phased.** Phase 1 (required for parity): weekly/biweekly/monthly + end date, single-transaction bulk creation, individually editable/cancellable occurrences. Phase 2 (CorLink enhancement, schema/API designed for it from day one, UI ships later): this-occurrence/this-and-future/whole-series edit and cancel; exception dates; skipped occurrences. |
| 4 | Pre-booking placement | **Meetings module, as a Draft Meeting.** Room and participants both optional. Shown on Calendar with a Draft/Pre-booked indicator. Completed via the standard meeting-edit workflow, not a separate "convert" mechanism. Integrates with recurring meetings for bulk creation. |
| 5 | Calendar's scope | **Calendar becomes CorLink's single, complete schedule view** — meetings, draft/pre-booked meetings, standalone room bookings, recurring meeting occurrences, and room blocks/maintenance (admin view or optional filter), each visually distinct, each opening its own correct detail screen. |
| 6 | Leave management depth | **Advisory-only, with specific requirements:** staff self-log; org admins can manage leave within their org; leave types are a real org-level setting (not MeetFlow's browser-local list); leave shows on Calendar with a visual indicator; meeting organizers get a warning when inviting someone on leave; leave never blocks an invite. Not an approval workflow. Should integrate with, not duplicate, any future dedicated HR/Leave module. |

---

## 6. Safest implementation order

Phased by risk and dependency, following this project's established discipline: schema → RLS → RPC → local-Postgres testing → validation script → docs → frontend, one thing at a time, for every phase. This sequence has been reworked from the original draft now that Calendar's scope (Q5) requires draft meetings, recurring occurrences, and leave data to already exist before Calendar can render them correctly — Calendar is now a late-stage phase, not an early one. Phases marked **(flexible)** have no hard dependency on the phases before or after them and can be resequenced or interleaved.

| Phase | Contents | Why here |
|---|---|---|
| **A** | RSVP response RPC + UI; attendance-marking RPC + UI | Smallest possible increment — schema already supports both, purely additive, zero new tables. Establishes the review/testing rhythm for this new direction before anything bigger. |
| **B** | Meeting minutes (shared, finalizable); personal private notes per participant; **meeting lock, with the three-tier override permission from Q2** | Small, additive, mostly no new tables (lock is a couple of columns + an authorization-logic change to the existing manage-meeting check). Independent of everything else. |
| **I (flexible)** | Dashboard Action-Needed rows + stats for Rooms/Meetings | No dependency on anything else; low risk, high visibility — can run any time, including in parallel with A/B. |
| **J (flexible)** | Automatic in-app meeting reminders via `pg_cron` (new `meeting_reminder` notification type, mirrors existing `check_deadlines()` job) | Implements the Q1 decision. No dependency beyond confirming the notification pipeline (validated by Phase A/B's RPC work); can run early. |
| **E (flexible)** | Meeting groups (schema, RLS, RPCs, admin UI, Add Participant integration) | Independent of everything else in this list; can run in parallel with I/J or immediately after A/B. |
| **H (flexible, but before C)** | Leave management: self-service staff records, org-admin management within their org, org-level configurable leave types, organizer warning on invite | Implements the Q6 decision. Low risk, small schema footprint, no dependency on Recurring/Drafts — but **must land before Phase C**, since Calendar (per Q5) needs to show a leave indicator from day one. |
| **F** | **Recurring meetings, Phase 1** (weekly/biweekly/monthly + end date, single-transaction bulk creation, individually editable/cancellable occurrences, schema designed for Phase 2 from the start) **— SHIPPED** (`supabase/patch-meetings-recurring.sql`, `docs/25-recurring-meetings-phase1-design-decisions.md`). **+ Draft/Pre-booked Meetings** — the single-draft-meeting workflow **— SHIPPED** (`supabase/patch-meetings-drafts.sql`, `docs/27-draft-meetings-design-decisions.md`); the bulk date-range × days-of-week creation mechanism, sharing the recurring engine with a draft flag, **remains unbuilt and pending**. | The single biggest design/build effort in this roadmap — implements Q3 and Q4 together, since the project owner's own decision on Q4 explicitly ties pre-booking's bulk creation to the recurring-meeting engine. In practice, Recurring Meetings Phase 1, the single-draft-meeting workflow, and the bulk pre-booking mechanism shipped (or remain to ship) as three separable pieces of work rather than one combined delivery — see `docs/25` and `docs/27` for the reconciliation. Sequenced after the smaller wins (A/B/I/J/E/H) so the team has multiple successful, smaller phases under this new direction's review discipline before taking on the largest one. |
| **C** | **Calendar module**: its own design-decision doc, then schema/RPC (a purpose-built read RPC composing meetings, drafts, recurring occurrences, standalone bookings, room blocks, and leave — likely no new tables beyond what F/H already added), then the new view/route with week-grid + day-agenda + staff picker, rendering all six item types from §3.2's table with distinct styling and correct detail-screen routing — **SHIPPED**, narrower scope (`js/data/calendar-api.js`, `js/views/calendar.js`, `supabase/patch-calendar-route-activation.sql`, committed `edd02b4`). No composed RPC was built (client-side merge of existing `MeetingsAPI`/`RoomsAPI` reads instead); four of six item types are supported (drafts and leave omitted — neither data source exists yet); no staff picker, section color coding, or `.ics` export. See `docs/26-calendar-design-decisions.md`. | Shipped after Phase F's Recurring Meetings Phase 1 alone, not after both F and H as this row originally required — Draft/Pre-booked Meetings (the rest of Phase F) and Phase H (Leave) both remain pending, and Calendar's scope was narrowed accordingly rather than waiting on either. This was the single biggest visible feature to end users; `docs/26` records why the narrower scope was judged sufficient to ship now, and what remains to close the gap to the original six-item-type decision. |
| **D** | Rooms visual calendar/week-grid view, reusing Phase C's grid component, replacing/augmenting the single-day list in the Schedule tab | Depends directly on Phase C's grid component existing; otherwise low schema risk (no new tables, existing `fetchBookings` data plus room blocks, already real). **Not started. Calendar (Phase C) shipped without a reusable positioned grid component (list-style day/week/month/agenda views instead) — this phase's premise should be revisited before work begins; see `docs/26` §5.** |
| **(Recurring meetings Phase 2 — SHIPPED, see row above; any org-level Rooms/Meetings configuration remains pending)** | Recurring Meetings Phase 2 (this/future/all-series edit and cancel, exception dates, skipped occurrences) shipped — see `docs/28-recurring-meetings-phase2-implementation.md`. The optional org-level working-hours configuration noted in §3.4 remains unbuilt. | Phase 2's RPC surface shipped ahead of a dedicated frontend for it (no UI change was part of this scope); the working-hours configuration remains deferred with no scheduled phase. |

**Do not reorder A and B behind anything else** — they are the lowest-risk, highest-value closes of an existing schema/UI mismatch and should ship first regardless of how the rest of the sequence is adjusted.

**Do not build Calendar (Phase C) before Phase F and Phase H are done** — this is a direct consequence of the Q5 decision, not an arbitrary preference; Calendar's whole purpose is to be the complete schedule view, and it cannot be complete until drafts, recurring occurrences, and leave data exist to show. **As shipped, this was not fully honored: Calendar shipped after Phase F's Recurring Meetings Phase 1 alone, with the bulk pre-booking mechanism and Phase H (Leave) both still pending, and its scope narrowed to the four item types that already had a data source. See `docs/26-calendar-design-decisions.md` §5/§6 for the reconciliation. The single-draft-meeting workflow has since shipped (`docs/27`) and required no Calendar change, since Calendar already rendered `status='draft'` meetings.**

---

## 7. Testing/verification discipline for this effort

Unchanged from every prior step in this project — restated here because the direction change doesn't relax it:

- Local PostgreSQL testing (stub `auth` schema, real `schema.sql`+`rls.sql`, hex-only UUID seed data) before any schema/RLS change reaches even a validation script, matching the exact convention already used for Rooms/Meetings/Entry.
- A written validation script per new migration, mirroring `validate-rooms-booking-foundation.sql`/`validate-meetings-foundation.sql`'s pattern.
- Idempotency testing for any patch file meant to be safely rerunnable.
- A hard safety check (independent `list_projects` verification, staging ≠ production) before any write to a real Supabase project, exactly as established throughout the staging bootstrap work.
- One phase at a time, with its own docs entry recording what was decided/built/tested, following the `docs/09`→`docs/16` precedent this roadmap itself is built from. Phase F (Recurring Meetings + Draft Meetings) and Phase C (Calendar) each get their own design-decision doc before schema work begins, matching the `docs/09`/`docs/12` precedent for the original Rooms/Meetings work.
- MeetFlow's own live Supabase project (`meeting-room-booking`, `xvwileiyquqxxtzqxghm`) is never a target for any write, at any point — it remains read-only reference material, exactly as it has been throughout this migration.
- The Phase 1/Phase 2 split for Recurring Meetings (Q3) is a testing discipline in its own right: Phase 1's schema must be validated as correctly supporting Phase 2's future operations (this/future/all-series edit, exceptions, skips) even before Phase 2's RPCs/UI are built — this should be an explicit item in Phase F's own validation script, not assumed.

---

## 8. Sources reviewed for this roadmap

- `docs/01` (static CorLink/MeetFlow architecture audit), `docs/02` (live Supabase inventory), `docs/08` (MeetFlow booking schema analysis) — prior MeetFlow findings, cross-checked against source rather than re-derived from scratch.
- `docs/09`–`docs/16` (Rooms/Meetings V1 decisions, technical readiness, database foundation, frontend implementation records) — full CorLink current-state inventory.
- `supabase/patch-rooms-booking-foundation.sql`, `supabase/patch-meetings-foundation.sql`, `supabase/patch-rooms-route-activation.sql`, `supabase/patch-meetings-route-activation.sql` — actual applied schema/RLS/RPCs.
- `js/data/rooms-api.js`, `js/data/meetings-api.js`, `js/views/rooms.js`, `js/views/meetings.js`, `js/views/admin.js`, `js/views/dashboard.js`, `js/views/shell.js`, `js/router.js`, `index.html` — actual shipped frontend.
- `references/meetflow/schema_v2.sql` (full, 342 lines), `references/meetflow/index.html` (full, 3,442 lines), `references/meetflow/supabase/functions/meetflow-login/index.ts` (full, 161 lines) — complete MeetFlow source.
- Six rounds of explicit design-decision discussion with the project owner (§5), covering notifications, meeting lock scope, recurring meetings, pre-booking placement, Calendar scope, and leave management depth.

---

## 9. Confirmation

No code, schema, configuration, or documentation other than this file was changed in the preparation of this roadmap. No Supabase project (staging, production, or the MeetFlow reference project) was contacted. This file has not been committed.

**Awaiting your approval before any implementation begins.** All six open design questions are now resolved (§5); the phase order in §6 reflects them. Implementation, commits, and pushes remain on hold until you explicitly authorize the first phase.
