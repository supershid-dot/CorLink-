# 153 — Fix "New Meeting" Button + Pending RSVPs Tab

## 1. UAT

> "New meeting button is not working"
> "Pending rsvps should be shown in a separate tab in meetings view, it should show all the meetings the user is participating which is not responded accept or decline"

## 2. Fixes

### "New Meeting" button (dashboard.js)

**Root cause**: every view in this app defines its own private `_openModal(innerHtml)`, and every one of them does `document.getElementById('modal-root').innerHTML = ...` — the view's own rendered HTML is required to contain a `<div id="modal-root"></div>` for this to work. `dashboard.js`'s `render()` never included that div (confirmed via `grep -rn "modal-root" js/views/*.js` — every other view had it, dashboard.js had zero matches). Clicking "New Meeting" called `MeetingsView._openScheduleMeetingModal()`, which called `MeetingsView._openModal()`, which read `document.getElementById('modal-root')` — `null` on the dashboard's DOM — and threw a `TypeError` accessing `.innerHTML` on it. That throw happened inside the button's click handler, so the browser silently swallowed it: the button looked completely inert, matching the report exactly.

**Fix**: added `<div id="modal-root"></div>` to `dashboard.js`'s own rendered shell, matching the same pattern every other view (Rooms, Calendar, Requests, etc.) already uses.

Verified in a headless browser: rendering the dashboard now includes `#modal-root`, and clicking "New Meeting" produces a real `.modal-overlay` with the "Schedule Meeting" form inside it (previously zero overlays appeared, with the underlying `TypeError` only visible in the browser console).

### Pending RSVPs tab (meetings.js)

New "Pending RSVPs" tab in the Meetings module's tab bar (between "My Meetings" and "Past"), showing every meeting the caller is a participant on with `invitation_status = 'pending'` (has not yet accepted or declined) and the meeting is still `status = 'scheduled'` — the same MeetFlow-style card list already used by every other tab.

- `MeetingsAPI.fetchMyPendingRsvpMeetings()` — two-step query (participant rows → meeting rows), matching the existing shape of `fetchMyMeetingIds()`/`fetchMyMeetings()` just above it in the same file, rather than a single PostgREST embed.
- The Dashboard's "Pending RSVPs" stat tile (docs/151/152) now deep-links straight to this tab via `#meetings?tab=pending-rsvp` (was a generic `#meetings` link before this).

Verified in a headless browser: rendering `MeetingsView` with `{ tab: 'pending-rsvp' }` calls `fetchMyPendingRsvpMeetings()` (and only that fetch), marks the "Pending RSVPs" tab button active, and renders the returned meeting as a card.

## 3. Files

- `js/views/dashboard.js` — added `#modal-root` to the rendered shell; Pending RSVPs tile now links to `#meetings?tab=pending-rsvp`.
- `js/views/meetings.js` — `pending-rsvp` added to `validTabs`; new tab button; new `_renderTab()` dispatch branch.
- `js/data/meetings-api.js` — new `fetchMyPendingRsvpMeetings()`.

## 4. Deployment

Full regression sweep (`meeting-detail-modal`, `schedule-meeting-combined-form`, `meetings-notification-integration`, `rooms-calendar-week-grid-integration`) run; only the same pre-existing, unrelated date-drift failures already documented in docs/144 (6 in schedule-meeting-combined-form, 1 in meeting-detail-modal — both caused by hardcoded 2026-09-20 test fixtures now being in the past, unrelated to this change). Both fixes additionally verified visually in a headless browser as described above.
