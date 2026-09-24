# 156 — Section-Manage Permission Fix + RSVP on the Meeting Card

## 1. UAT

> "i am logged in as a offender record staff, but i cannot schedule a pre booked meeting by admin, no edit button"
>
> "when scheduled meeting are shown, it should show the status of RSVP and can be accept or decline in that window easily"

## 2. Fix: no Edit button for a section-staff member on their own section's pre-booked draft

**Root cause**: `MeetingsView._canManage(meeting)` is a client-side "UX gating only" mirror of the real `can_manage_meeting()` RPC — the actual authorization always happens server-side; this helper only controls whether the Edit button is shown at all. It was never updated when `patch-meetings-section-scope.sql` shipped (docs/116), which corrected `can_manage_meeting()` to (a) grant management to **any member of the meeting's own section**, not just supervisors, and (b) **remove** the old blanket "any 'supervisor'-role user manages every meeting in the org" grant (that blanket grant was itself the bug docs/116 fixed). `_canManage()` still implemented the pre-116 rule — creator, super admin, or a blanket `_isSupervisor` check — so an ordinary section-staff member (not a supervisor) opening a pre-booked draft tagged to their own section saw no Edit button at all, even though the real RPC would have let them edit it.

**Fix**: `_canManage()` now matches the current RPC exactly: super admin, creator, an org-wide admin (same org only), or any member of the meeting's own section — the section-membership check via a new `this._mySectionIds` (populated from `RequestsAPI.mySections()`, the same RPC `my_section_ids()` wraps, already used elsewhere in this file for the Schedule/Edit forms' Section dropdown). Populated in `render()` for the normal Meetings-tab path, and lazily in `_ensureUserContext()` for the cross-view path (opening the detail modal directly from Rooms/Calendar without ever calling `MeetingsView.render()` this session).

This also fixes the opposite, more subtle bug: a plain `'supervisor'`-role user previously saw an Edit button for meetings **outside** their own section/scope too — clicking it would then fail against the real RPC, since that blanket grant had already been removed server-side. `_canManageSeries()` and the minutes-finalization gate were checked against their own real RPCs (`can_manage_series()`, `finalize_minutes()`) and confirmed to genuinely still use the blanket supervisor rule — left untouched.

## 3. Feature: RSVP status + one-click Accept/Decline on the meeting card

Every scheduled-meeting card (Meetings tab's own tabs, and dashboard.js's "Today's Meetings", which reuses the same `_meetingCard()`) now shows the caller's own RSVP status and lets them Accept/Decline right there — one click, no note field (the fuller confirm-with-note flow is still available via the detail view), matching "can be accept or decline in that window easily."

- `MEETING_SELECT` (`js/data/meetings-api.js`) now embeds `participants` (mirrors the existing `bookings` embed's own "embed everything RLS allows, pick the relevant row client-side" shape) — RLS (`meeting_participants_select`) always includes the caller's own row regardless of manage rights, so no extra fetch is needed.
- New `MeetingsAPI.myParticipation(meeting, userId)` — pure helper, same shape as `activeBooking()`.
- `_meetingCard()` — the card's clickable body became its own nested `<button class="meeting-list-card-btn">` inside a non-interactive `<div class="meeting-list-card">` wrapper (was previously a single outer `<button>`), so the new RSVP row's own Accept/Decline `<button>`s can sit alongside it without nesting a button inside a button (invalid HTML). New `_cardRsvpRow()` + shared `_bindCardRsvpButtons(area, onDone)`, called from both `_renderList()` (meetings.js) and `_loadMeetingsHome()` (dashboard.js).

## 4. Files

- `js/views/meetings.js` — `_canManage()` rewritten; `this._mySectionIds` populated in `render()`/`_ensureUserContext()` (now `async`, its 3 call sites updated); `_meetingCard()` restructured; new `_cardRsvpRow()`, `_bindCardRsvpButtons()`.
- `js/views/dashboard.js` — wires `_bindCardRsvpButtons()` alongside the existing `[data-view-meeting]` binding.
- `js/data/meetings-api.js` — `MEETING_SELECT` embeds `participants`; new `myParticipation()`.
- `css/style.css` — `.meeting-list-card` is now the wrapper; new `.meeting-list-card-btn`; new `.meeting-list-card-rsvp` (+ `--accepted`/`--declined` modifiers).
- `tests/meetings-section-manage-permission-frontend.test.js` (new) — section-member/different-section/blanket-supervisor/admin/creator/cross-view-entry coverage.
- `tests/meetings-card-rsvp-frontend.test.js` (new) — card RSVP rendering + one-click respond, on both the Meetings tab and the dashboard's reuse.

## 5. Deployment

Full regression sweep (`meeting-detail-modal`, `schedule-meeting-combined-form`, `meetings-notification-integration`, `rooms-calendar-week-grid-integration`, `meetings-prebook-slots`, plus the two new suites): only the same pre-existing, unrelated date-drift failures already documented in docs/144. Verified visually in a headless browser: a pending RSVP renders "Your RSVP: Pending" with Accept/Decline on the card.
