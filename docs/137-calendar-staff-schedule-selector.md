# 137 — Calendar Tab: View a Specific Staff Member's Schedule

## 1. UAT

MeetFlow-parity request, with screenshots of MeetFlow's own Calendar staff picker (a dropdown: "— My schedule —" plus every other staff member, searchable) and its per-user Admin "CAN VIEW SCHEDULE OF (explicit calendar access beyond own section)" permission checklist, alongside CorLink's own current Calendar filter row:

> "in calendar tab should be able to see the schedule of the staff when selected, by default it shows all the meeting scheduled. the section staff can see all the staff in that section, department or command and the staff who is approved by the admin in admin portal"

## 2. Why this needed a genuinely new permission, not just a UI dropdown

`js/data/calendar-api.js`'s own header comment stated a deliberate prior design rule: Calendar's default read path (`fetchEvents()`) never issues a new SECURITY DEFINER read — every event it returns is a row the caller could already see by querying Meetings/Rooms directly, composed client-side over three already-RLS-scoped reads. That same comment explicitly named "show me user X's meetings" as a correctness gap it deliberately avoided rather than solved: `meeting_participants`' own RLS only grants a caller their own row or a meeting they manage, so querying for an arbitrary other user's participant rows would silently return an incomplete result once that user has meetings outside the caller's own visibility (e.g. a different section).

This feature is the first time Calendar deliberately crosses that boundary — behind a new, explicit permission check, not a query-shape workaround.

## 3. Who may view whose schedule

New `can_view_user_schedule(target_user_id)` — TRUE when the caller is:
1. the target themselves;
2. a super admin (any organization);
3. an org admin, for any active user in their own org;
4. a **colleague** of the target — the target holds an active `user_assignments` row whose scope (section/department/division/command, via the existing `scope_section_ids()`) overlaps the caller's own `my_section_ids()` — literally "staff in that section, department or command" from the UAT;
5. **explicitly granted** via the new `user_schedule_grants` table — "the staff who is approved by the admin in admin portal", set by an org admin per-viewer from Admin → Manage User → the new "Calendar Access" section (mirrors MeetFlow's own per-user "CAN VIEW SCHEDULE OF" checklist).

`viewable_calendar_staff()` lists exactly the staff a caller may pick, built from the same predicate so the picker's contents and what it's actually allowed to fetch can never drift apart. `fetch_user_calendar_events(user_id, from, to)` is the actual cross-user read — gated by the same check, SECURITY DEFINER so it can see the target's meetings even where the caller's own RLS-scoped read would have missed them. Deliberately narrow: meetings only (as creator or active participant), each meeting's currently-active room booking if any — nothing about standalone room bookings, room blocks, or any other module.

## 4. Calendar tab UI

The old standalone "Only mine" checkbox is replaced by a "Staff" dropdown (`js/views/calendar.js`), matching MeetFlow's own shape:
- **"— All meetings —"** (default) — unfiltered, exactly today's existing behavior, satisfying "by default it shows all the meeting scheduled".
- **"— My schedule —"** — the same client-side "mine" filter the old checkbox used (no new fetch).
- **Named staff** (from `viewable_calendar_staff()`) — selecting one fetches that person's own schedule via `fetch_user_calendar_events()` and the calendar switches to showing only their meetings; the room/status/org/type filter dropdowns rebuild from that same fetched set so they never offer values from the wrong source. Date navigation while a staff member is selected keeps refetching their schedule for the new range automatically.

Clicking a meeting event sourced from another staff member's schedule opens a small read-only preview (title/time/room/status) instead of navigating straight into the Meetings module — "can see this on the calendar" and "can open its full detail" are deliberately separate permissions (a colleague/admin-granted schedule view does not also grant full meeting access), so navigating directly could hit an RLS-denied error for a meeting outside the caller's own visibility. The preview has its own explicit "Open in Meetings" button for when the caller does also have full access. Events sourced from the normal "All meetings"/"My schedule" views are completely unaffected — they navigate directly, exactly as before.

## 5. Admin portal — Calendar Access

Admin → Manage User gains a new "Calendar Access" section: a searchable checklist of every other active staff member in the org, pre-checked from that user's current grants, saved as a full replace via `admin_set_schedule_grants()`. Colleagues (same section/department/command) need no admin action — this section is only for granting access *beyond* that.

## 6. Files

- `supabase/patch-calendar-staff-schedule-access.sql` / `validate-…` / `rollback-…` — `user_schedule_grants` table (RLS: SELECT-only policy; every write goes through `admin_set_schedule_grants()`, same RPC-only-mutation convention as meetings/meeting_participants) plus the four new functions.
- `js/data/calendar-api.js` — `fetchViewableStaff()`, `fetchUserSchedule()` (normalizes to the same event shape `fetchEvents()` already produces).
- `js/data/admin-api.js` — `fetchScheduleGrants()` (direct table read), `setScheduleGrants()` (RPC wrapper).
- `js/views/calendar.js` — `_state.filters.staffId` replaces `onlyMine`; `_activeSourceEvents()`; Staff dropdown; staff-schedule event preview modal.
- `js/views/admin.js` — `_openManageUserModal()` is now async (awaits current grants before rendering); new "Calendar Access" section + search filter + Save handler.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — Staff dropdown contents, fetching/showing a selected staff's schedule, "My schedule" staying client-side-only, the read-only preview modal.
- `tests/admin-manage-user-modal-frontend.test.js` — checklist rendering, save + reopen-pre-checked, search filter.

## 7. Deployment

Migration applied + validated on CorLink Staging. Full regression sweep: same pre-existing, unrelated failures only.
