# 23 — Rooms, Calendar, Meetings & Meeting Administration: Implementation Specification

**Status: PLANNING ONLY. No code, SQL, or configuration has been changed. Nothing in this document has been applied anywhere. This specification requires explicit approval before any implementation step begins.**

This document turns the approved roadmap (`docs/22-rooms-meetings-meetflow-parity-roadmap.md`) into a concrete implementation specification for every phase. It assumes familiarity with `docs/22` (architecture constraints, feature comparison, the six resolved design decisions, and the phase order) and does not repeat that reasoning — only the *how* is specified here.

---

## 0. Cross-phase conventions (apply to every phase below unless a phase explicitly overrides one)

- **UUID PKs**, `org_id`/`organization_id` on every new table, `created_at`/`updated_at` timestamps, `trigger_set_updated_at()` reused where an `updated_at` column exists.
- **SELECT-only RLS + `SECURITY DEFINER` RPC writes** on every new table — no direct INSERT/UPDATE/DELETE policy for any role, matching every table already in `schema.sql`/`rls.sql`. Every mutating RPC: `SET search_path = public, pg_temp`, actor derived only from `auth.uid()`, never a client-supplied identity field.
- **Real CHECK constraints** on every enum-like column — no free-text "enum" columns.
- **Migration file naming**: `supabase/patch-<feature>.sql` + `supabase/validate-<feature>.sql`, following the exact structure of the existing Rooms/Meetings patches (numbered sections, `BEGIN`/`COMMIT` wrapper, `CREATE TABLE IF NOT EXISTS`/`CREATE OR REPLACE FUNCTION`/`DROP POLICY IF EXISTS`+`CREATE POLICY`, idempotent seed `ON CONFLICT` clauses).
- **Local PostgreSQL testing** (stub `auth` schema, real `schema.sql`+`rls.sql`, hex-only UUID seed data) before any migration reaches a validation script, per this project's established convention — restated per-phase below only where a phase has a testing nuance beyond this default.
- **Hard safety check** (independent target verification, staging ≠ production) before any write to a real Supabase project, for every phase, no exceptions.
- **Shared CHECK-constraint coordination risk**: several phases below extend the same shared CHECK constraints (`notifications.type`, `audit_logs.action`, `audit_logs.record_type`). If two phases' migrations are developed in parallel, their `ALTER TABLE ... ADD CONSTRAINT` statements for these shared columns must not be applied concurrently against the same database — each phase's patch file should `DROP CONSTRAINT IF EXISTS` + re-`ADD CONSTRAINT` with the **full accumulated list** of values (its own new values plus every other already-applied phase's values), exactly the pattern already used every time a prior patch in this project extended one of these same constraints. This is called out once here rather than repeated in every phase's migration section.
- **Docs**: every phase gets its own `docs/NN-*.md` implementation-record entry when built, following the `docs/09`→`docs/16` precedent — numbers to be assigned at build time, not reserved here.

---

## Phase A — RSVP response + attendance marking

### 1. Objective
Close the existing schema/UI mismatch: `meeting_participants.invitation_status` and `attendance_status` already exist but nothing can update them. Let a participant respond to their own invitation (accept/decline + note) and let an authorized user mark attendance.

### 2. Database changes
- `meeting_participants`: add `invitation_note TEXT` (mirrors MeetFlow's `rsvp_note`), `attendance_marked_by UUID REFERENCES users(id)`, `attendance_marked_at TIMESTAMPTZ`, `attendance_note TEXT`.
- No new tables. No new indexes required (existing `meeting_id`-scoped indexes already cover the access patterns).
- CHECK addition: `(attendance_marked_by IS NULL) = (attendance_marked_at IS NULL)` (bidirectional pairing, matching the existing pattern used for `approved_by`/`approved_at` elsewhere in this module).

### 3. RLS policy changes
None. `meeting_participants` remains SELECT-only with zero write policy; both new RPCs write via `SECURITY DEFINER`.

### 4. RPCs / database functions
- `respond_to_invitation(p_participant_id UUID, p_response TEXT, p_note TEXT DEFAULT NULL)` — requires `user_id = auth.uid()` on the target row; `p_response IN ('accepted','declined')`; updates `invitation_status`/`invitation_note`; fires a new `participant_responded` notification to the meeting's organizer.
- `mark_attendance(p_participant_id UUID, p_status TEXT, p_note TEXT DEFAULT NULL)` — requires `can_manage_meeting(meeting_id)`; `p_status IN ('attended','absent','excused')`; sets `attendance_status`/`attendance_marked_by`/`attendance_marked_at`/`attendance_note`.

### 5. Frontend pages and components
`js/views/meetings.js` meeting-detail modal: "Your RSVP" section (Accept/Decline buttons + optional note, shown only while `invitation_status='pending'` for the caller's own row) and a "Change" link once responded; per-participant Attendance toggle buttons in the participant list, visible only when `can_manage_meeting()` is true for the viewer.

### 6. Backend service changes
None — no Edge Function involvement.

### 7. Notification changes
New `notifications.type` value: `participant_responded`. New `audit_logs.action` values: `invitation_responded`, `attendance_marked`.

### 8. Permission changes
None new — reuses `can_manage_meeting()` and the existing "own row only" pattern already used for `meeting_participants_select`.

### 9. Migration strategy
`supabase/patch-meetings-rsvp-attendance.sql` — additive columns via `ADD COLUMN IF NOT EXISTS`, two new `CREATE OR REPLACE FUNCTION`s, one CHECK constraint addition, one CHECK-constraint-list extension (`notifications.type`, `audit_logs.action`) per §0's coordination note. Fully idempotent. Local Postgres test → `validate-meetings-rsvp-attendance.sql` → staging (hard safety check first) → docs entry.

### 10. Test plan
- A participant can respond only to their own `invitation_status`, never another participant's (attempt as a different authenticated user → rejected).
- `mark_attendance` succeeds for the creator/supervisor/admin, rejected for an ordinary non-managing participant.
- Idempotency: rerunning the patch file produces no duplicate constraints/functions and does not reset any already-set value.
- Notification fires exactly once per response/attendance-mark action, addressed to the correct recipient.
- RLS re-verified as SELECT-only on `meeting_participants` after the patch (no write policy introduced).

### 11. Dependencies
None. First phase — no prerequisite work.

### 12. Risks
Low. Only material risk is the shared-CHECK-constraint coordination noted in §0 if developed in parallel with another phase touching the same constraints (B, F, and the reminder work in J all touch `notifications.type`).

---

## Phase B — Meeting minutes, personal notes, and meeting lock (three-tier)

### 1. Objective
Add shared, finalizable meeting minutes; private per-participant notes; and a meeting lock with the Q2-decided override tiers (creator always; org admin within their own org; super admin anywhere; nobody else).

### 2. Database changes
- `meetings`: add `minutes TEXT`, `minutes_finalized BOOLEAN NOT NULL DEFAULT FALSE`, `minutes_updated_by UUID REFERENCES users(id)`, `minutes_updated_at TIMESTAMPTZ`, `is_locked BOOLEAN NOT NULL DEFAULT FALSE`, `locked_by UUID REFERENCES users(id)`, `locked_at TIMESTAMPTZ`.
- `meeting_participants`: add `personal_notes TEXT`.
- CHECK additions: `(is_locked = FALSE OR locked_by IS NOT NULL)`, `(minutes_finalized = FALSE OR minutes IS NOT NULL)`.
- No new tables, no new indexes.

### 3. RLS policy changes
None on the tables themselves (still SELECT-only + RPC writes). **`meeting_participant_list()` (the existing safe redacted-read RPC) must be modified** to null out `personal_notes` for every caller except the row's own `user_id` — this is the single security-sensitive change in this phase and must not be skipped; without it, `personal_notes` would be readable by anyone `can_manage_meeting()` returns true for, defeating the "personal/private" intent.

### 4. RPCs / database functions
- `is_meeting_lock_overridable(p_meeting_id UUID) RETURNS BOOLEAN` STABLE SECURITY DEFINER — `is_super_admin() OR (is_admin() AND organization_id = get_my_org_id()) OR created_by = auth.uid()`.
- `lock_meeting(p_meeting_id UUID)` — creator only (locking is the creator's own choice; it is not something an org admin initiates on someone else's meeting).
- `unlock_meeting(p_meeting_id UUID)` — gated by `is_meeting_lock_overridable()` (creator, or org admin in-org, or super admin), consistent with "override" in Q2 including the ability to lift the lock outright.
- `update_minutes(p_meeting_id UUID, p_minutes TEXT)` — `can_manage_meeting()` normally; once `minutes_finalized`, restricted to `is_super_admin() OR (is_admin() AND organization_id = get_my_org_id())`.
- `finalize_minutes(p_meeting_id UUID)` — `is_supervisor_or_above()` scoped to the meeting's org, or super admin.
- `update_my_notes(p_participant_id UUID, p_notes TEXT)` — restricted to the row's own `user_id = auth.uid()`.
- **Modify** (body-only, `CREATE OR REPLACE`, no signature change) `update_meeting()`, `cancel_meeting()`, `add_participant()`, `remove_participant()`: at the top of each, if `meetings.is_locked` and `NOT is_meeting_lock_overridable(p_meeting_id)`, raise an exception before any other logic runs.

### 5. Frontend pages and components
Meeting-detail modal: Minutes panel (view/edit/finalize, read-only banner once finalized for non-admins); "My Notes" panel (private, bilingual EN/Dhivehi toggle per existing convention, visible/editable only to the viewing participant); Lock/Unlock control (creator sees it always; org admin/super admin see an "Override Lock" affordance specifically when viewing a locked meeting they didn't create); a locked-meeting banner shown to everyone.

### 6. Backend service changes
None.

### 7. Notification changes
Optional, not required for parity: `meeting_locked`/`meeting_unlocked`/`minutes_finalized` notification types, for audit visibility only. Recommend deferring unless requested — not part of MeetFlow's own notification set either.

### 8. Permission changes
Introduces the creator/org-admin-in-org/super-admin three-tier override pattern as a reusable helper (`is_meeting_lock_overridable`) — first instance of this specific tier shape in the codebase; worth documenting as a precedent for any future feature needing the same shape.

### 9. Migration strategy
`supabase/patch-meetings-minutes-lock-notes.sql` — additive columns, CHECK additions, `CREATE OR REPLACE` on 4 existing RPCs (body-only), 4 new RPCs, the `meeting_participant_list()` redaction fix. Idempotent throughout.

### 10. Test plan
- Lock blocks supervisor/room-manager/ordinary-staff edit and cancel attempts on a locked meeting.
- Org admin can override within their own org; the same org admin **cannot** override a locked meeting in a different org (explicit cross-org negative test).
- Super admin can override anywhere.
- Creator can always edit/cancel their own meeting regardless of lock state.
- `update_meeting`/`cancel_meeting`/`add_participant`/`remove_participant` are each individually re-tested against a locked meeting — every mutating RPC touching a meeting row must be covered, not just the two most obvious ones.
- `personal_notes` is confirmed redacted for every non-owner caller of `meeting_participant_list()`, including a `can_manage_meeting()`-true caller.
- Minutes: normal manager can edit while not finalized; only org-admin/super-admin can edit once finalized; finalize itself requires supervisor-or-above.

### 11. Dependencies
No hard technical dependency on Phase A. Sequenced after it per `docs/22` §6 to establish review rhythm on the smallest change first, not because of a technical blocker — safe to run in parallel with A if preferred.

### 12. Risks
Moderate. The lock-check must be added to **every** mutating RPC that touches a meeting row (four are listed above) — missing one creates a silent lock-bypass. `meeting_participant_list()`'s redaction fix is genuinely security-sensitive and must be explicitly tested, not assumed correct by inspection.

---

## Phase I — Dashboard integration *(flexible — no dependency on any other phase)*

### 1. Objective
Bring Rooms/Meetings up to CorLink's own existing dashboard convention (Action-Needed rows, matching Entry/Requests) — currently zero presence.

### 2. Database changes
None, if built as client-side bucketing over already-capped, already-RLS-scoped list queries — the same pattern `dashboard.js` already uses for Internal Collaboration rows. (Fallback, only if performance later requires it: a single `rooms_meetings_action_needed_counts(org_id)` RPC mirroring the existing `requests_action_needed_counts` pattern.)

### 3. RLS policy changes
None — reads existing RLS-gated data only.

### 4. RPCs / database functions
None required initially (see §2 fallback).

### 5. Frontend pages and components
`js/views/dashboard.js`: new rows — "Pending Room Bookings" (room-manager-gated), "Meetings Needing RSVP" (caller's own `invitation_status='pending'` rows within a lookahead window), "Draft Meetings Awaiting Completion" (post–Phase F). Zero-count rows hidden per the existing convention.

### 6. Backend service changes
None.

### 7. Notification changes
None.

### 8. Permission changes
None — rows respect whatever the underlying queries already enforce.

### 9. Migration strategy
None (frontend-only), unless the fallback RPC route is taken, in which case a standard additive `patch-rooms-meetings-dashboard-counts.sql`.

### 10. Test plan
Row visibility matches role (only room managers see the pending-approvals row); zero-count rows hidden; each row's link navigates correctly, reusing the existing `record_type`-based special-case routing already in `shell.js`.

### 11. Dependencies
None. Fully independent — can run at any point, in parallel with anything.

### 12. Risks
Low. Main risk is scope creep toward replicating MeetFlow's entire Home tab rather than staying scoped to Action-Needed rows matching the existing Entry/Requests convention.

---

## Phase J — Automatic in-app meeting reminders (`pg_cron`) *(flexible)*

### 1. Objective
Implement the Q1-decided reminder mechanism: a reliable, server-side scheduled job, replacing MeetFlow's browser-tab-dependent reminder polling.

### 2. Database changes
`meetings`: add `reminder_sent_at TIMESTAMPTZ` (idempotency guard against duplicate reminders across cron runs). No new tables.

### 3. RLS policy changes
None — the cron function runs as a scheduled `SECURITY DEFINER` job outside the normal RLS-gated client path, matching the existing `check_deadlines()` precedent.

### 4. RPCs / database functions
`send_meeting_reminders()` SECURITY DEFINER — scans `meetings` with `status='scheduled'`, `start_at` inside the reminder lead window (constant initially, e.g. 30 minutes; org-configurable later per the optional item in §3.4 of `docs/22`), `reminder_sent_at IS NULL`; inserts a `meeting_reminder` notification for the creator and every active participant; sets `reminder_sent_at`.

### 5. Frontend pages and components
None — purely server-side; existing notification bell renders the new type using its existing generic rendering path.

### 6. Backend service changes
`cron.schedule('send-meeting-reminders', '*/5 * * * *', 'SELECT send_meeting_reminders();')` — new scheduled job, idempotent by job name (matches `check_deadlines()`'s existing registration pattern).

### 7. Notification changes
New `notifications.type` value: `meeting_reminder` — the one type CorLink's Meetings migration explicitly deferred in V1 (`docs/12` §2); this phase closes exactly that deferral.

### 8. Permission changes
None — system-triggered, not a user action.

### 9. Migration strategy
`supabase/patch-meetings-reminder-cron.sql` — additive column, new function, new `cron.schedule` call, CHECK-constraint-list extension per §0. Requires `pg_cron` (already installed on staging per `docs/19`).

### 10. Test plan
Manually backdate a test meeting's `start_at` into the reminder window in the local test DB; call `send_meeting_reminders()` directly (not waiting on the real schedule); confirm exactly one notification per active participant + creator; confirm a second manual run produces no duplicate (guard works); confirm meetings outside the window, cancelled, or still `draft` are untouched.

### 11. Dependencies
None hard. Benefits from Phase A/B's RPC conventions being established, but not blocked by them.

### 12. Risks
Low-moderate. Timezone correctness: comparisons must use `start_at` (`TIMESTAMPTZ`, UTC-normalized) — never the display-only `timezone` column — to avoid the exact class of stale/incorrect-comparison bug already found and fixed once in this module's history (`docs/13`). Reminder-window default needs a sensible, documented value even before it's made org-configurable.

---

## Phase E — Meeting groups *(flexible)*

### 1. Objective
Named, reusable, org-scoped invite lists with a separate "who may use this group" permission list — CorLink-native rebuild of MeetFlow's `meeting_groups`/`meeting_group_members`/`meeting_group_access`, with real RLS instead of blanket allow.

### 2. Database changes
- `meeting_groups`: `id UUID PK`, `organization_id UUID NOT NULL REFERENCES organizations(id)`, `name TEXT NOT NULL` (CHECK non-empty), `description TEXT`, `created_by UUID NOT NULL REFERENCES users(id)`, `created_at`, `updated_at`.
- `meeting_group_members`: `group_id UUID NOT NULL REFERENCES meeting_groups(id) ON DELETE CASCADE`, `user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`, `added_by UUID NOT NULL REFERENCES users(id)`, `created_at`. PK `(group_id, user_id)`.
- `meeting_group_access`: same shape as members, PK `(group_id, user_id)`, `granted_by` instead of `added_by`.
- Indexes: `idx_meeting_group_members_group`, `idx_meeting_group_access_group`, `idx_meeting_groups_org`.

### 3. RLS policy changes
- `meeting_groups_select` / `meeting_group_members_select` / `meeting_group_access_select`: `is_super_admin() OR (organization_id = get_my_org_id() AND (is_admin() OR EXISTS (SELECT 1 FROM meeting_group_access WHERE group_id = ... AND user_id = auth.uid())))` — admins see every group in their org for management purposes; ordinary users see only groups they've been explicitly granted access to (this deliberately narrower boundary matches MeetFlow's actual permission model — access-gated, not org-wide-visible — more precisely than a blanket org-wide read would).
- No direct write policy on any of the three tables.

### 4. RPCs / database functions
`create_meeting_group`, `update_meeting_group`, `delete_meeting_group` (hard delete acceptable — cascades via `ON DELETE CASCADE`; groups carry no historical/audit dependency the way bookings do) — all admin/supervisor, org-scoped. `set_group_members(p_group_id, p_user_ids UUID[])` / `set_group_access(p_group_id, p_user_ids UUID[])` — atomic replace-on-edit (deliberately *not* diffed, unlike meeting participants — group membership carries no per-member history worth preserving, so this is an intentional, narrow exception to the general "diff, don't replace" rule in `docs/22` §4 item 11; both `p_user_ids` validated same-org before write, mirroring the cross-tenant check discipline in `create-user`). `add_group_as_participants(p_meeting_id, p_group_id)` — validates caller has `meeting_group_access` (or is admin) for that group, then loops the group's members through the existing `add_participant()` logic (reused, not duplicated), tolerating an already-a-participant unique-violation per member without failing the whole batch.

### 5. Frontend pages and components
A Groups CRUD screen inside the Meetings module's own admin/settings area (not the generic Admin Portal, matching Rooms' own-module precedent) — list, create/edit modal with name/description + two searchable checkbox lists (members, access). Wired into the existing Add Participant modal as a new "Group" option alongside Internal/External.

### 6. Backend service changes
None.

### 7. Notification changes
None new — adding a group's members fires the existing `participant_added` type per member.

### 8. Permission changes
Introduces `meeting_group_access` as the first "who may use this specific record" grant table in this module distinct from role-based gating — a pattern worth reusing if a similar need arises elsewhere.

### 9. Migration strategy
`supabase/patch-meetings-groups.sql` — three new tables, RLS, 6 RPCs, fully additive. Idempotent.

### 10. Test plan
Non-admin cannot create/edit/delete a group. A user without `meeting_group_access` cannot see or select the group. Adding a group with one already-existing participant doesn't fail the whole batch. Cross-org `user_id` in `set_group_members`/`set_group_access` is rejected. RLS confirmed as zero-write-policy on all three tables.

### 11. Dependencies
None — fully independent.

### 12. Risks
Low-moderate. Cross-tenant validation on the two `set_*` RPCs is the main thing to get right — same discipline already established elsewhere in this codebase.

---

## Phase H — Leave management (advisory-only) *(flexible, but must complete before Phase C)*

### 1. Objective
Implement the Q6-decided lightweight, advisory-only, org-scoped leave tracking with org-level configurable leave types — deliberately narrow so a future dedicated HR/Leave module can adopt or replace it without unwinding workflow logic that shouldn't exist here.

### 2. Database changes
- `leave_types`: `id UUID PK`, `organization_id UUID NOT NULL REFERENCES organizations(id)`, `name TEXT NOT NULL` (CHECK non-empty), `is_active BOOLEAN NOT NULL DEFAULT TRUE`, `display_order INTEGER`, `created_at`, `updated_at`. UNIQUE `(organization_id, name)`.
- `staff_leaves`: `id UUID PK`, `organization_id UUID NOT NULL REFERENCES organizations(id)`, `user_id UUID NOT NULL REFERENCES users(id)`, `leave_type_id UUID NOT NULL REFERENCES leave_types(id)`, `date_from DATE NOT NULL`, `date_to DATE NOT NULL` (CHECK `date_to >= date_from`), `notes TEXT`, `created_by UUID NOT NULL REFERENCES users(id)`, `created_at`, `updated_at`.
- Indexes: `idx_staff_leaves_user_dates` (`user_id`, `date_from`, `date_to`), `idx_staff_leaves_org`.

### 3. RLS policy changes
- `leave_types_select`: org-wide read (module-gated) — every staff member needs the list to log their own leave.
- `staff_leaves_select`: `is_super_admin() OR organization_id = get_my_org_id()` — **org-wide read**, not supervisor-gated, because the point of this feature is that *anyone scheduling a meeting* can see the warning, not just supervisors. `notes` is redacted for anyone except the leave's own `user_id` or an org admin — enforced via a safe read function (§4), not the raw table's own SELECT policy, exactly the same redaction pattern used for `personal_notes` in Phase B and `meeting_participant_list()` today.
- No direct write policy on either table.

### 4. RPCs / database functions
`create_leave_type` / `update_leave_type` — org admin only. `create_my_leave` / `update_my_leave` / `delete_my_leave` — self-service, restricted to the caller's own `user_id`. `create_leave_for_user` / `update_leave_for_user` / `delete_leave_for_user` — org admin only, with same-org validation on the target `user_id`. `staff_leave_list(p_from DATE, p_to DATE)` — the safe, `notes`-redacted read used by both the participant-add warning and the future Calendar view. `is_user_on_leave(p_user_id UUID, p_date DATE) RETURNS BOOLEAN` — small STABLE helper specifically for the participant-add warning check.

### 5. Frontend pages and components
"My Leave" self-service screen (profile menu, matching MeetFlow's placement) — list/add/edit/delete own records. An org-admin leave-management screen (view/manage leave on behalf of any staff member in their org, per Q6 requirement 2) and a leave-types management screen, both inside the Meetings module's own admin area. Add Participant modal gets a non-blocking on-leave warning badge using `is_user_on_leave()`.

### 6. Backend service changes
None.

### 7. Notification changes
None — purely advisory/informational, no notification-worthy event by design.

### 8. Permission changes
Introduces the "self OR org-admin-within-org" write pattern for a new table pair — built entirely from existing helpers (`is_admin()`, `get_my_org_id()`), no new flag.

### 9. Migration strategy
`supabase/patch-meetings-leave-management.sql` — two new tables, RLS, 8 RPCs, fully additive. Idempotent.

### 10. Test plan
Staff can edit only their own leave, never another's, via the self-service RPCs. Org admin can manage leave within their own org; cross-org attempt rejected. Leave-type CRUD is admin-only. The on-leave warning fires correctly and is confirmed genuinely non-blocking (the participant can still be added despite the warning). `notes` redaction verified for non-owner/non-admin callers of `staff_leave_list()`.

### 11. Dependencies
None technically for the feature itself. **Hard sequencing requirement: must be complete before Phase C (Calendar)** begins, per `docs/22` §6, since Calendar must render a leave indicator from day one per Q5.

### 12. Risks
Low. Primary risk is scope creep toward an approval workflow (explicitly excluded, `docs/22` §4 item 13) — resist adding any pending/approved state even if it looks like a small addition; the entire point of keeping this narrow is a clean future handoff to a dedicated HR module.

---

## Phase F — Recurring meetings (Phase 1) + Draft/Pre-booked meetings

**This phase gets its own separate design-decision doc before any schema work begins**, mirroring the `docs/09`/`docs/12` precedent, given its size and the Phase-2-readiness requirement. The specification below is the input to that doc, not a replacement for it.

**Status: Recurring Meetings Phase 1 has shipped** (`supabase/patch-meetings-recurring.sql`, single migration file — see §13 below). **The single-draft-meeting workflow half of Draft/Pre-booked Meetings has also since shipped** (`supabase/patch-meetings-drafts.sql`, committed `b6ee08c` — see `docs/27-draft-meetings-design-decisions.md`); **the bulk pre-booking mechanism** (`create_recurring_meeting()` called with `recurrence_pattern='custom_days'`/`is_draft_series`/`days_of_week`) **remains unshipped and pending**. The design-decision doc this section calls for was written retrospectively, after implementation, as `docs/25-recurring-meetings-phase1-design-decisions.md` (Recurring Meetings Phase 1) and `docs/27-draft-meetings-design-decisions.md` (the single-draft-meeting workflow) — see those documents for the full reconciliation between this specification and what actually shipped, including the approved-but-not-yet-implemented consolidated recurring room-booking notification decision (§13 below).

### 1. Objective
Implement Q3's Phase 1 (weekly/biweekly/monthly + end date, single-transaction bulk creation, individually editable/cancellable occurrences) with schema designed for Q3's Phase 2 from day one, and Q4's Draft/Pre-booked Meetings sharing the same bulk-creation engine with a draft flag.

### 2. Database changes
- **New table `meeting_series`**: `id UUID PK`, `organization_id UUID NOT NULL REFERENCES organizations(id)`, `created_by UUID NOT NULL REFERENCES users(id)`, `recurrence_pattern TEXT NOT NULL CHECK (recurrence_pattern IN ('weekly','biweekly','monthly','custom_days'))` (`'custom_days'` is the pre-booking pattern — date range × explicit days-of-week, a superset used only by the pre-booking flow), `interval_count INTEGER NOT NULL DEFAULT 1` (kept generic/forward-compatible even though Phase 1's UI only exposes the three fixed patterns), `days_of_week INTEGER[]` (populated only for `'custom_days'`), `series_start_date DATE NOT NULL`, `series_end_date DATE NOT NULL` (CHECK `series_end_date >= series_start_date`), template fields mirroring `meetings`' own compose-time fields (`template_title`, `template_description`, `template_meeting_type`, `template_visibility`, `template_start_time TIME NOT NULL`, `template_end_time TIME NOT NULL` (CHECK end > start), `template_timezone TEXT NOT NULL DEFAULT 'Indian/Maldives'`, `template_location_mode`, `template_external_location`, `template_virtual_link`, `template_room_id UUID REFERENCES meeting_rooms(id)`), `is_draft_series BOOLEAN NOT NULL DEFAULT FALSE` (the pre-booking flag at the series level), `status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','cancelled'))`, `created_at`, `updated_at`.
- **`meetings` additions**: `series_id UUID REFERENCES meeting_series(id)`, `series_occurrence_date DATE`, `series_detached BOOLEAN NOT NULL DEFAULT FALSE` (set the moment an individual occurrence is edited away from its series template — required now so Phase 2's future "edit all future occurrences" doesn't silently clobber an already-individually-edited one), `is_placeholder BOOLEAN NOT NULL DEFAULT FALSE` (provenance flag only — "this row originated from bulk pre-booking"; the actual lifecycle state continues to use the existing `status='draft'`/`'scheduled'` values exactly as Q4 specifies, `is_placeholder` never drives permission/visibility logic on its own).
- **New table `meeting_series_exceptions`** (schema present now; **zero RPCs write to it and zero UI references it until Phase 2** — created now purely so Phase 2 doesn't require a further migration against already-live Phase 1 data): `id UUID PK`, `series_id UUID NOT NULL REFERENCES meeting_series(id) ON DELETE CASCADE`, `exception_date DATE NOT NULL`, `exception_type TEXT NOT NULL CHECK (exception_type IN ('skipped','modified'))`, `replacement_meeting_id UUID REFERENCES meetings(id)`, `created_by UUID NOT NULL REFERENCES users(id)`, `created_at`. UNIQUE `(series_id, exception_date)`.
- Indexes: `idx_meetings_series` (`series_id`, `series_occurrence_date`), `idx_meeting_series_org`, `idx_meeting_series_exceptions_series`.

### 3. RLS policy changes
- `meeting_series_select`: `is_super_admin() OR (current_user_module_enabled('meetings') AND organization_id = get_my_org_id())` — series-level metadata is less sensitive than an individual meeting's participant list; individual occurrences remain governed entirely by the existing, unchanged `meetings_select`/`can_view_meeting()`.
- `meeting_series_exceptions_select`: same org-scoping (not functionally exercised until Phase 2).
- No direct write policy on either new table.
- **No change** to `meetings_select`/`meeting_participants_select` — occurrences are ordinary rows, already correctly governed.

### 4. RPCs / database functions
- `create_recurring_meeting(...)` — single `SECURITY DEFINER` transaction. Inserts one `meeting_series` row, then generates every occurrence date **server-side** (not a client-side loop, unlike MeetFlow), inserting one `meetings` row per date (`status='draft'` if `p_is_draft`, else `'scheduled'`) with `series_id`/`series_occurrence_date` set, auto-adding the creator as organizer on each (via a shared internal helper factored out of `create_meeting()`, not duplicated). If a room is specified, each occurrence's room booking is created via the existing `create_room_booking`/`submit_booking_request` branching (same logic `assign_room_booking` already uses) **inside the same transaction** — any single occurrence's room conflict rolls back the entire batch (deliberate all-or-nothing safety, improving on MeetFlow's partial-failure-prone client loop). Returns the series id + array of created meeting ids.
- `create_prebooked_slots(...)` — not a separate function; pre-booking is `create_recurring_meeting()` called with `recurrence_pattern='custom_days'`, `p_is_draft=TRUE`, and `days_of_week` set — literally the same engine, per Q4's explicit requirement that these share machinery.
- **Modify** (body-only) `update_meeting()`: when called on a row with `series_id IS NOT NULL`, set `series_detached := TRUE` — the only Phase 1 change this RPC needs. `update_meeting()`'s existing `draft→scheduled` transition support is reused as-is for "complete a draft" — **no new "complete draft" RPC is needed at all**, a deliberate simplification directly following from Q4's "reuse the standard meeting-edit workflow" requirement.
- `cancel_meeting()` — unchanged; already correctly cancels a single occurrence.
- **Explicitly not built in this phase** (schema-ready, RPC/UI deferred): `update_series_this_and_future()`, `update_entire_series()`, `cancel_series_this_and_future()`, `cancel_entire_series()`, `create_series_exception()` — listed here only for traceability against the schema above.

### 5. Frontend pages and components
Create Meeting form: a "Recurring" toggle (pattern: weekly/biweekly/monthly, end date). A separate, admin/supervisor-gated "Pre-book slots" action (date range, days-of-week checkboxes, time window, optional room, optional section) calling the same underlying creation RPC with the draft/custom-days parameters. Individual occurrences render and behave exactly like ordinary meetings everywhere in the app, with a small recurrence indicator icon; draft occurrences get the dashed/draft styling (per `docs/22` §3.2's Calendar item-type table). Opening a draft occurrence opens the ordinary edit-meeting form, pre-filled — not a distinct "complete draft" screen.

### 6. Backend service changes
None — no Edge Function involvement, fully RPC-based.

### 7. Notification changes
A single notification to the creator confirming series creation (not one per occurrence — would be spammy for a multi-month weekly series). Each occurrence's own organizer-participant insert fires the *existing* `meeting_created`/`participant_added` types, unchanged. `series_cancelled` is a Phase 2 concern, not built now.

### 8. Permission changes
Pre-booking specifically (`is_draft_series=TRUE`, `recurrence_pattern='custom_days'`) is supervisor/org-admin/super-admin only. Ordinary (non-draft) recurring-meeting creation uses the same permission as ordinary meeting creation — any module-enabled user. This distinction must be enforced inside `create_recurring_meeting()` itself, not left to the frontend to hide the pre-booking UI from unauthorized users.

### 9. Migration strategy
Split into two ordered patch files for review clarity, applied together: `supabase/patch-meetings-recurring-series-foundation.sql` (tables, indexes, RLS, including the inert `meeting_series_exceptions` table) then `supabase/patch-meetings-recurring-series-rpcs.sql` (the bulk-creation RPC + the two small existing-RPC body modifications). Both additive/idempotent.

### 10. Test plan
- A 12-week weekly series produces exactly 12 correctly-dated occurrences in one transaction.
- A deliberate room conflict on occurrence #7 of a series rolls back the **entire** batch — verify zero partial rows remain.
- Each occurrence is independently editable/cancellable without affecting sibling occurrences.
- Editing a single occurrence sets `series_detached=TRUE` and does not modify the series template row.
- Pre-booking creates `status='draft'`, `is_placeholder=TRUE` rows via `recurrence_pattern='custom_days'`.
- Completing a draft via ordinary `update_meeting(p_status='scheduled', ...)` succeeds and correctly transitions the row.
- A non-admin cannot call the pre-booking path; an ordinary module-enabled user **can** create a plain (non-draft) recurring meeting.
- `meeting_series_exceptions` exists with correct RLS but is confirmed to have zero rows and zero write paths at the end of this phase's test pass — an explicit "prove Phase 2 wasn't accidentally half-built" check.
- Multi-occurrence, same-room series booking is tested specifically against the existing advisory-lock ordering scheme (`room_lock_key`) to confirm no self-deadlock across occurrences of the same series within one transaction.

### 11. Dependencies
Inherits Phase B's lock-check automatically (via the unchanged `update_meeting()`/`cancel_meeting()` call path) — no new lock logic needed here. No hard technical dependency on E or H specifically, but per `docs/22` §6 this phase is sequenced after the smaller wins (A/B/I/J/E) to establish review rhythm before the largest, riskiest phase in the roadmap. **H must still be complete before Phase C**, independent of F's own timing.

### 12. Risks
**Highest in this roadmap.** Two specific risks called out for dedicated attention: (1) transactional multi-occurrence room-booking with per-occurrence advisory locks — must be proven deadlock-free under real testing, not just assumed safe because each individual booking call is already safe in isolation; (2) `series_detached` bookkeeping is easy to get subtly wrong (must fire on every field-changing path through `update_meeting()`, not just some), and a bug here would be invisible in Phase 1's own UI while silently corrupting Phase 2's future correctness — recommend a dedicated code-review pass specifically on this one field's handling before merging, independent of the standard review.

### 13. Implementation status (as shipped)

Full record in `docs/25-recurring-meetings-phase1-design-decisions.md`; summarized here for anyone reading this specification directly.

- **Recurring Meetings Phase 1 is shipped** (`supabase/patch-meetings-recurring.sql`). **The single-draft-meeting workflow (create/edit/activate/delete of one draft at a time, with full RSVP/attendance/minutes/lock rejection and notification suppression) is also shipped** (`supabase/patch-meetings-drafts.sql`, committed `b6ee08c` — see `docs/27-draft-meetings-design-decisions.md`). **The bulk pre-booking mechanism — the other half of "Draft/Pre-booked Meetings" as this section defines it — has not shipped and remains pending**: `is_draft_series`/`days_of_week` exist as inert columns; `custom_days` is rejected as a `create_recurring_meeting()` input. See `docs/27` §1/§5 for the full distinction between these two workflows.
- **The migration shipped as a single file**, not the two-file split §9 above describes.
- **A 260-occurrence cap and a five-year recurrence-range cap are enforced** by `create_recurring_meeting()` — implementation safety controls not called for by this specification's original text.
- **Consolidated recurring room-booking notification — approved, not yet implemented.** Post-ship regression review confirmed that a room-booked series created by a caller who is not a room manager currently sends one `booking_submitted` notification per occurrence to every manager of that room (inherited, unmodified, from `assign_room_booking()`'s existing single-meeting behavior — a real notification-fatigue risk once applied N times in one series-creation action). The approved target behavior — one consolidated per-series notification to each relevant room manager, individual booking rows and audit entries otherwise unchanged, no reliance on `assign_room_booking()`/`add_group_as_participants()` call ordering — is recorded in full in `docs/25` §3. It is not implemented by this specification or by the shipped Phase 1 patch.

---

## Phase C — Calendar module

**Status: SHIPPED** (`js/data/calendar-api.js`, `js/views/calendar.js`, `supabase/patch-calendar-route-activation.sql`, committed `edd02b4` on `feature/corlink-platform-migration`). This phase's own design-decision doc — required below and never written before implementation began — has been written retrospectively: see `docs/26-calendar-design-decisions.md`. The sections below are left as originally specified, with shipped-reality notes added; `docs/26` is authoritative on what was actually built and on every deviation from this text.

**This phase gets its own separate design-decision doc before any schema work begins**, mirroring the `docs/09`/`docs/12` precedent, given it is a genuinely new module. *(Not followed — see status note above.)*

### 1. Objective
Build CorLink's first unified schedule view — meetings, draft meetings, recurring occurrences, standalone room bookings, room blocks, and leave, each visually distinct, each routing to its correct existing detail screen, with a staff-schedule picker built entirely from CorLink's existing role/section scoping (explicitly not MeetFlow's broken per-viewer-grant mechanism, per `docs/22` §3.2). **Shipped scope was narrower: meetings, recurring occurrences, standalone room bookings, and room blocks only — draft/pre-booked meetings, leave, and the staff picker were not built. See `docs/26` §2/§6.**

### 2. Database changes
None anticipated beyond what Phases F and H already added. If cross-source query performance requires it after real testing, a single composed read RPC (§4) is preferred over five separate client-side merges — decide only after measuring, not preemptively. **No cross-source query performance problem was ever measured, so no RPC was built — the client-side merge shipped as-is. See `docs/26` §1.**

### 3. RLS policy changes
None new. Calendar's read path must **reuse** each underlying table's existing, already-correct SELECT policy/visibility function (`can_view_meeting()`, `meeting_room_bookings_select`, the existing block-select rule, Phase H's `staff_leave_list()`) rather than reimplementing visibility logic in a new `SECURITY DEFINER` bypass — this is the specific safeguard against Calendar accidentally widening access beyond what a user could already see in Rooms/Meetings/Leave directly. **This is exactly what shipped: no new RLS policy was written; Calendar reuses `meetings_select`/`meeting_room_bookings_select`/the block-select rule by calling the same `MeetingsAPI`/`RoomsAPI` functions Meetings/Rooms themselves call. Confirmed empirically during the Calendar regression review.**

### 4. RPCs / database functions
**Neither of the below was implemented. Calendar has zero new RPCs. See `docs/26` §1/§6.**
- ~~`calendar_events_for_range(p_from DATE, p_to DATE, p_viewer_user_id UUID DEFAULT NULL)`~~ — defaults to the caller's own schedule; if a different `p_viewer_user_id` is passed, the function itself must independently verify the caller is permitted to view that user's schedule (via the helper below) before returning anything — this check happens inside the RPC, not only in the frontend's staff-picker UI. Returns a normalized item set (type discriminator + id + start/end + minimal type-specific payload) composed from `meetings` (existing visibility), `meeting_room_bookings` (existing visibility), `meeting_room_blocks` (existing visibility), and `staff_leaves` (Phase H's `staff_leave_list()`).
- ~~`who_can_i_view_schedule_for()`~~ — returns the set of user ids the caller may pick in the staff picker, derived entirely from `is_supervisor_or_above()` and section/org membership — the direct, from-scratch replacement for MeetFlow's `ssa_viewer_<id>` mechanism, which this phase exists specifically to avoid replicating.

### 5. Frontend pages and components
New `js/data/calendar-api.js` + `js/views/calendar.js`, new `#calendar` route, new `calendar` module key seeded into `platform_modules` with `route IS NULL` until explicitly activated (identical two-step pattern to `rooms`/`meetings`). Week-grid (desktop) + day-agenda (mobile) shared component; staff picker built from `who_can_i_view_schedule_for()`; section-based color coding; `.ics` export; the six-item-type visual/routing table from `docs/22` §3.2 implemented exactly as specified (each type opens its own existing detail modal — no new detail screens are built by this phase). **Shipped: `calendar-api.js`/`calendar.js`/`#calendar` route/`calendar` module key exactly as specified (the module key was already seeded with `route IS NULL` before this phase began). Shipped instead of a positioned week-grid: day/week/month/agenda list-style views (see `docs/26` §4/§5). Not shipped: staff picker, section-based color coding, `.ics` export. Four of the six item types are supported, not six — see `docs/26` §2.**

### 6. Backend service changes
None. **Confirmed as shipped — none.**

### 7. Notification changes
None. **Confirmed as shipped — none.**

### 8. Permission changes
The staff-picker "whose schedule can I view" rule is new in shape (though built entirely from existing helpers) — this is the direct, purpose-built fix for the specific privilege-escalation-shaped gap found in MeetFlow's research pass (`docs/22` §3.2) and is the single most important thing to verify correct in this phase. **Not applicable as shipped — no staff picker was built, so this permission surface does not exist. Calendar's only participant-scoped filter is a self-scoped "only my meetings" toggle; see `docs/26` §6.**

### 9. Migration strategy
`supabase/patch-calendar-module-foundation.sql` — new module-route seed row (using the existing corrected `route = COALESCE(EXCLUDED.route, platform_modules.route)` seed pattern, not the pre-fix pattern), new read RPCs, no new tables unless §2's fallback is triggered. A separate, later `supabase/patch-calendar-route-activation.sql` mirrors the exact `rooms`/`meetings` route-activation precedent, applied only once the frontend is ready. **As shipped: no foundation migration was needed or written — the `calendar` module key was already seeded (with `route IS NULL`) by the original `patch-platform-module-foundation.sql`, and no RPC was built. `patch-calendar-route-activation.sql` (the one-line route-activation flip) was the only SQL change this phase required. See `docs/26` §6.**

### 10. Test plan
A user viewing their own calendar sees exactly what they're already independently entitled to see across Rooms/Meetings/Leave — nothing more, nothing less (differential test against each source module's own existing test coverage). **The staff-picker permission check is the single most important test in this phase**: explicit attempts to pass an unauthorized `p_viewer_user_id` (a peer in another section, a user in another org) must be rejected by the RPC itself, not merely hidden by the picker UI. Each of the six item types renders with correct styling and correct click-through target. Module-gating verified inert until the route-activation patch is separately applied, exactly matching the `rooms`/`meetings` precedent. **As shipped, the staff-picker test does not apply (no staff picker exists). What was verified instead, per the Calendar regression review: a user's Calendar shows exactly what Meetings/Rooms already show them directly (no RLS widening); the four shipped item types render and click through correctly; module-gating (route activation + per-org enablement) is inert until separately applied, matching the `rooms`/`meetings` precedent.**

### 11. Dependencies
**Hard dependency on Phase F (recurring/draft occurrences must exist to render) and Phase H (leave data must exist to render)**, per `docs/22` §6's explicit resequencing driven directly by the Q5 decision. Do not begin schema work before both are complete. **As shipped: Phase F (Recurring Meetings Phase 1) had completed; Phase H (Leave) had not, and remains unimplemented. Calendar shipped anyway with narrowed scope (leave and draft/pre-booked meetings omitted as data sources) rather than waiting — a deliberate deviation from this stated ordering, recorded in `docs/26` §5/§6.**

### 12. Risks
Moderate-high. The staff-picker permission check is explicitly the mitigation for a real vulnerability class already found in MeetFlow — recommend a dedicated, adversarial test pass (impersonation attempts, cross-org attempts) beyond the standard plan in §10. Composing five different visibility rules into one view risks accidentally over-widening access if any one of them is reimplemented rather than reused as-is — the §3/§9 requirement to call existing policy logic, not bypass it, is the direct mitigation. **As shipped, the primary risk this section anticipated does not apply — there is no staff picker and no reimplemented visibility logic; every visibility rule is reused by construction (§3 above), confirmed by the regression review. Remaining, non-blocking risks recorded in `docs/26` §5: no date-range index yet (confirmed via `EXPLAIN`, not yet addressed), and Calendar's module-enablement gate being independent of Meetings'/Rooms' gates (a UX gap, not a security one).**

---

## Phase D — Rooms visual calendar/week-grid view

### 1. Objective
Replace/augment Rooms' single-day list Schedule tab with the shared week-grid component built in Phase C, scoped to a single room.

### 2. Database changes
None.

### 3. RLS policy changes
None — reuses existing `meeting_room_bookings_select`/block-select policies exactly as today's list view already does.

### 4. RPCs / database functions
None new. Continue using existing `RoomsAPI` queries (`fetchBookings`, `fetchRoomBlocks`), now rendered through the shared grid component rather than a list — deliberately not routed through Phase C's `calendar_events_for_range` RPC, to avoid coupling Rooms to Calendar's own module-activation state.

### 5. Frontend pages and components
`js/views/rooms.js` Schedule tab: swap the single-day list for the shared week-grid component (extracted from Phase C's `js/views/calendar.js` into a reusable module so it is not duplicated). Retain block overlay styling. Recommend keeping the existing list view available as a toggle or mobile fallback rather than removing an already-working, already-tested screen outright.

### 6. Backend service changes
None.

### 7. Notification changes
None.

### 8. Permission changes
None.

### 9. Migration strategy
None — frontend-only phase, no SQL.

### 10. Test plan
Visual/manual verification the grid renders correctly for a single room's data; re-run existing Rooms Schedule-tab test coverage (`docs/15`) to confirm no regression; block overlay renders correctly on the grid exactly as it does today.

### 11. Dependencies
Hard dependency on Phase C (reuses its grid component directly).

### 12. Risks
Low. Primarily a frontend rework of an already-correct data source; main risk is a UX regression if the list view is removed entirely before confirming the grid handles every case (especially mobile) at least as well.

---

## Recurring Meetings — Phase 2 *(specified below for traceability against Phase F's schema; see status note)*

**Status: shipped and approved.** All five RPCs anticipated below were built (`skip_series_occurrence()` was not — its behavior is covered by the "skip an occurrence" workflow already provided by `cancel_meeting()` + `create_series_exception(..., 'skipped')`, per the locked skip-semantics design decision, rather than a sixth dedicated function). `update_entire_series()`, `update_series_this_and_future()`, `cancel_entire_series()`, `cancel_series_this_and_future()`, and `create_series_exception()` (the last of which actually shipped earlier, as part of the series-exceptions foundation patch within this same Phase 2 effort) are all implemented, validated, and pushed. **Update, 2026-07-24: the frontend UI for all of the above — scope-selection dialog, edit/cancel modals, result-summary modal, activity timeline — has since shipped too, along with a follow-up meeting-series audit-visibility fix.** See `docs/28-recurring-meetings-phase2-implementation.md` for the full architecture record, RPC-by-RPC behavior, frontend implementation (§16), known limitations (§17), and validation status — it supersedes this section's §2/§3/§4 as prospective specification; the sections below are retained for traceability against what was originally scoped. A staging migration rehearsal has since validated Phase 2 end to end alongside the rest of the Platform Migration/Rooms/Meetings chain — see `docs/29-recurring-meetings-phase2-production-deployment-runbook.md` for the operator runbook. None of this has yet been applied to production Supabase — staging-validated only, with a multi-persona authorization UAT gap still outstanding (docs/29 §3/§21).

### 1. Objective
Ship the Q3-deferred capabilities once Phase F has been live and stable in real use: this-occurrence / this-and-future / entire-series edit and cancel; exception dates; skipped occurrences.

### 2. Database changes
None beyond what Phase F already created — `meeting_series_exceptions` already exists; this phase activates its write path.

### 3. RLS policy changes
None new — the exceptions table's SELECT policy already exists from Phase F; write access remains RPC-only, matching convention.

### 4. RPCs / database functions
Not built now: `update_series_this_and_future()`, `update_entire_series()`, `cancel_series_this_and_future()`, `cancel_entire_series()`, `create_series_exception()`, `skip_series_occurrence()`.

### 5. Frontend pages and components
Not built now: expanded edit/cancel action sheets ("this occurrence / this and future / entire series"), exception-date UI within the series view.

### 6. Backend service changes
None anticipated.

### 7. Notification changes
Possibly `series_updated`/`series_cancelled` types, to be decided when this phase is actually scoped — bulk operations become more consequential here than in Phase 1.

### 8. Permission changes
None beyond what Phase B/F already established — the same lock-override tiers apply identically to series-wide operations.

### 9. Migration strategy
An RPC-only patch file when scheduled — no table changes, which is the direct payoff of Phase F's forward-designed schema.

### 10. Test plan
To be written when this phase is scoped, but must specifically include a regression check that occurrences created under Phase 1 (before Phase 2 shipped) behave correctly under the new this/future/all operations — i.e., confirm Phase F's `series_detached` bookkeeping was actually sufficient in practice, not just in Phase F's own test pass.

### 11. Dependencies
Hard dependency on Phase F. Should not begin until Phase F has real-world usage history, per `docs/22` §6's stated rationale.

### 12. Risks
Not assessed in detail — this phase is intentionally not being specified for implementation yet. A full risk assessment should accompany its own design-decision doc when the project owner schedules it.

---

## Parallelization: what can run concurrently, what must be sequential

**Hard, structural dependencies (must be sequential):**

| Blocking phase | Blocks | Why |
|---|---|---|
| Phase H (Leave) | Phase C (Calendar) | Calendar must render a leave indicator from day one (Q5). **Not honored as shipped — Calendar shipped before Phase H, without a leave data source. See `docs/26` §5/§6.** |
| Phase F (Recurring/Drafts) | Phase C (Calendar) | Calendar must render draft/recurring items from day one (Q5). **Partially honored — Recurring Meetings Phase 1 had shipped first, so recurring occurrences render; the bulk pre-booking mechanism never shipped, so Calendar has no bulk-draft-slot data source. Calendar has always rendered the single-draft-meeting `status='draft'` state, which has since been fully hardened — see `docs/26` §2/§3/§8 and `docs/27`.** |
| Phase C (Calendar) | Phase D (Rooms grid view) | D directly reuses C's grid component. **Calendar shipped without a positioned grid component (list-style day/week/month/agenda views instead — `docs/26` §4/§5), so this dependency's premise no longer holds as originally stated; Phase D would need its own grid work if pursued.** |
| Phase F (Recurring Phase 1) | Recurring Meetings Phase 2 | Phase 2 activates the schema Phase 1 built — **satisfied; Phase 2 shipped. See `docs/28`.** |

**No hard technical dependency (parallel-safe):**

- Phase A and Phase B have no technical dependency on each other — `docs/22` sequences B after A as a stated *process* preference (establish review rhythm on the smallest change first), not a discovered blocker. Safe to run concurrently if preferred.
- Phase I (Dashboard), Phase J (Reminders), and Phase E (Meeting Groups) each have **zero dependency on any other phase in this roadmap** — all three can start immediately and run fully in parallel with A/B and with each other.
- Phase H (Leave) has no dependency on A/B/E/I/J — it can also run in parallel with all of them; its only constraint is finishing before Phase C starts.

**Recommended concurrent grouping**, consistent with `docs/22` §6's stated rationale (small wins first, biggest/riskiest phase after the team has validated the new direction's review rhythm, Calendar last among the "big" phases because it structurally depends on the most other work):

1. **Concurrent track 1:** A → B (or A ∥ B if preferred)
2. **Concurrent track 2:** I (Dashboard) — anytime
3. **Concurrent track 3:** J (Reminders) — anytime
4. **Concurrent track 4:** E (Meeting Groups) — anytime
5. **Concurrent track 5:** H (Leave) — anytime, but must finish before Phase C starts
6. **Then, once tracks 1–5 are substantially done:** Phase F (Recurring + Drafts) — the largest single effort in this roadmap; not recommended to further parallelize internally given its risk profile (§12 above), though its own two patch files are naturally sequential (foundation, then RPCs).
7. **Then:** Phase C (Calendar) — requires F and H both complete. **As shipped, Calendar went ahead after F alone, with H's leave data and F's bulk pre-booking mechanism both omitted from scope rather than waited on — see `docs/26`. The single-draft-meeting workflow has since shipped separately (`docs/27`) and required no further Calendar change.**
8. **Then:** Phase D (Rooms grid view) — requires C complete. **Not started; Calendar shipped without the positioned grid component this phase was meant to reuse (`docs/26` §5), so Phase D's scope should be revisited before it begins.**
9. **Recurring Meetings Phase 2 — SHIPPED.** Landed after F, ahead of the "not scheduled now" note this list originally carried; see `docs/28-recurring-meetings-phase2-implementation.md`.

---

## Confirmation

No code, SQL, or configuration was changed in the preparation of this specification. No Supabase project (staging, production, or the MeetFlow reference project) was contacted. This file has not been committed.

**Awaiting your approval before any implementation begins.**
