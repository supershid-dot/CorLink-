# 142 — Nav Reorder/Rename + Staff Filter Own-Org Scoping

## 1. UAT

Screenshot of the Staff combobox (docs/141) listing staff from more than one organization, plus a screenshot of the sidebar nav, and:

> "should only show staff who belong to the users organization" / "instead of rooms write meeting rooms" / "calendar should be next to meeting rooms, then meetings"

## 2. Staff filter: own organization only

`viewable_calendar_staff()` (docs/137) gave a super admin every active user across every organization. Calendar's own event feed was already forced to the caller's own org unconditionally in docs/140 ("not needed here, default to the user's own organization") — this closes the matching gap in the Staff picker itself, so a super admin's Calendar experience is org-scoped end to end, not just the default event list. The function's `WHERE u.org_id = v_org` clause (previously only reached for a non-super-admin) is now unconditional; the `is_super_admin()` early-return branch that bypassed it is gone.

`can_view_user_schedule()` (used by `fetch_user_calendar_events()`, and reused here for the colleague/explicit-grant check) is untouched — it's a general-purpose permission check, not the listing itself, and nothing in the UI can pass it a cross-org id anymore once the list no longer offers one.

## 3. Navigation: rename + reorder

- **"Rooms" → "Meeting Rooms"** in the sidebar nav, the desktop topbar nav, and the Rooms page's own `<h2>` title — everywhere the module is named as a destination. Left as "Rooms" in the mobile bottom nav (space-constrained tab bar — this file already shortens other labels there the same way: "Prisoner Letters" → "Letters", "Administration" → "Admin") and in the Rooms page's own internal "Rooms" sub-tab (a different, already-correct meaning there — "the room inventory list", as opposed to "Schedule"/"My Bookings"/"Room Blocks").
- **Reordered**: Meeting Rooms → Calendar → Meetings (previously Meeting Rooms → Meetings → Calendar), in the sidebar, the desktop topbar nav, and the mobile bottom nav.

## 4. Files

- `supabase/patch-calendar-staff-own-org-only.sql` / `validate-…` / `rollback-…` — `viewable_calendar_staff()`'s cross-org super-admin branch removed.
- `js/views/shell.js` — `sidebarHtml()`, `topbarHtml()`, `bottomNavHtml()`: nav order + the two desktop-facing "Rooms" → "Meeting Rooms" renames.
- `js/views/rooms.js` — page `<h2>` title renamed to match.

## 5. Deployment

Migration applied + validated on CorLink Staging. Frontend nav/rename has no dedicated test suite in this repo (a cosmetic label/order change) — full regression sweep otherwise clean, same pre-existing, unrelated failures only.
