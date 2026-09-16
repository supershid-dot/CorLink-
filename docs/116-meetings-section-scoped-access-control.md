# 116 — Meetings Section-Scoped Access Control

## 1. Requirement

"Meetings can be edited unless it is locked to the staff from same section, command and department heads can see, book and edit meeting under the sections of the command, if a person belong to more than one section or department or command then he should have same access too."

## 2. Root Cause Found

`can_manage_meeting()` and `can_view_meeting()` both used a blanket `is_supervisor_or_above()` term (`is_admin() OR has_role('supervisor')`). `has_role()` checks only whether the caller holds a `user_assignments` row with that role — **it never looks at `scope_id`** — so any user holding a `'supervisor'` assignment anywhere (even scoped to a single, unrelated section) could see and edit **every** meeting in the organization. Meetings also had no `section_id` at all — nothing to scope against even if the check had been narrower.

This is the exact defect shape `supabase/patch-narrow-supervisor-visibility.sql` already fixed for `requests`/`responses` (blanket `has_role('supervisor')` → `my_section_ids()`). Meetings never received that correction. `is_admin()` (`mcs_admin`/`authority_admin`) is a separate, deliberately org-wide role in this codebase and was left untouched, matching every other module.

## 3. What Already Existed (no new hierarchy/membership system built)

`user_assignments(user_id, scope_type ∈ {organization,command,department,division,section}, scope_id, role, is_active)` — already supports a user holding multiple rows at any scope level — plus `scope_section_ids()`, `my_section_ids()`, and `my_supervised_section_ids()` (`supabase/patch-user-assignments-scope.sql`) already do exactly the expansion needed: a command or department assignment already resolves down to every section nested under it, and a user with several assignments already gets the union for free (`my_section_ids()` aggregates every row, at any scope, with `DISTINCT`). No new membership/hierarchy tables were needed — only a `section_id` on `meetings` to scope *against*, and the two authorization functions rewritten to use it.

## 4. Migration (`supabase/patch-meetings-section-scope.sql`)

- `meetings.section_id UUID REFERENCES sections(id)` (nullable — a meeting with no section behaves exactly as before this patch: creator/participants/org-admin/organization-visibility only).
- `meeting_series.template_section_id` (recurring series carry the same tag).
- `can_manage_meeting()` / `can_view_meeting()`: `is_supervisor_or_above()` → `is_admin()` (unchanged, org-wide) `OR m.section_id IN (SELECT my_section_ids())` (new — covers both plain section staff *and* command/department/division heads in one term, since a head's own assignment already expands into `my_section_ids()` via `scope_section_ids()`).
- `create_meeting`/`update_meeting`/`create_recurring_meeting`: new optional `p_section_id` (validated against the caller's own org — cross-org section references are rejected), appended last so no existing positional caller breaks. `update_meeting` also gets `p_clear_section` since a bare `NULL` already means "leave unchanged" for every other field.
- **Locking deliberately untouched**: `is_meeting_lock_overridable()` still only allows creator/org-admin/super-admin to override a lock — matching "edited *unless locked*" literally. A plain supervisor could never override a lock even under the old blanket rule, so section-staff/heads don't gain that either.
- **Bug caught during apply**: `CREATE OR REPLACE FUNCTION` does not replace a function whose parameter list changed shape — a new trailing parameter changes its type-identity, so the three modified functions each briefly existed as **two overloads**, and any named-argument call became ambiguous (`function update_meeting(...) is not unique`). Fixed by explicitly `DROP FUNCTION`-ing the exact pre-patch signatures before recreating them; verified exactly one overload of each remains.

## 5. Behavioral Validation (`supabase/validate-meetings-section-scope.sql`)

Run live against CorLink Staging inside a single transaction that rolls back at the end (disposable fixtures, `set_config('request.jwt.claims', ...)` actor impersonation — the same idiom already used by this repo's own concurrency suites). Confirmed:
- Creator can always manage their own meeting.
- A staff member in a *different* section (even with two other section memberships) gets zero access — can't manage, can't even view.
- A department head (assignment scoped to the department containing the meeting's section) can manage and view it.
- A command head (scoped to the command containing that department) can also manage it.
- An outsider with no assignment anywhere gets zero access.
- An org admin (`mcs_admin`) retains full access regardless of which section their own assignment happens to be scoped to (confirms `is_admin()` is correctly untouched/still org-wide).
- Once locked (by the creator), the department head is rejected from `update_meeting` with the lock-specific error — confirms locking still overrides the new section/head grant, exactly as designed.

Rolled back cleanly; reran with no fixture rows remaining. `get_advisors` (security) shows no new findings — the modified functions do not appear in "Function Search Path Mutable" (all four carry an explicit `SET search_path`), and their appearance in the generic "SECURITY DEFINER function is callable" advisories is the same pre-existing, intentional pattern every RPC in this module already has.

## 6. Frontend

- `js/data/meetings-api.js`: `createMeeting`/`updateMeeting`/`createRecurringMeeting` accept `sectionId` (and `updateMeeting` a `clearSection` flag); `MEETING_SELECT` now embeds `section:sections!meetings_section_id_fkey(id, name)`.
- `MeetingsView._openScheduleMeetingModal()` (the combined booking/scheduling form, docs/115) gains an optional "Section" field, fetched via the same `AdminAPI.listSectionsByOrg()` Rooms' own booking form already uses, with a hint explaining the access it grants.
- `MeetingsView._openEditMeetingModal()` gets the same field (now `async` to fetch sections first), prefilled from the meeting's current `section_id`; the submit only sends `sectionId`/`clearSection` when the field actually rendered (an org with zero sections must never silently wipe an existing `section_id` just because the field wasn't shown).
- The meeting detail view now shows a "Section" row when one is set, and (from docs/115's session) the description field's RTL rendering already covers Dhivehi section-tagged meetings the same as any other.

## 7. Tests

13 checks in `tests/schedule-meeting-combined-form-frontend.test.js` (2 new: Section field renders and is included in the create payload; omitting it sends `sectionId: null`). Full regression sweep (`tests/*.test.js`) run clean; the one pre-existing unrelated failure (`internal-collaboration-notification-integration-frontend.test.js`, CAP003_ROUTES `prisoner_letter` key) predates this work.

## 8. Deployment

Migration applied directly to CorLink Staging (`vjobntuyzymhcuanyeak`) via Supabase MCP and validated live (§5) before any frontend code was written against it. Frontend committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
