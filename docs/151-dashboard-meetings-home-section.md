# 151 — Home Tab: MeetFlow-Style "Next Meeting" + Today's Meetings

## 1. UAT

Screenshot of MeetFlow's own Home tab — a "Next Meeting" hero card (title + start time + countdown), two stat tiles (Today's Meetings, Pending RSVPs), and a "Today's Meetings" section with a "View all" link and a card for each meeting — with the instruction:

> "Add this part to the home tab"

## 2. Scope

Added only when Meetings is enabled for the org (`AppShell.isModuleEnabled(user, 'meetings')`), same module-gate convention `_canLetters`/`_canLogEntries` already use — hidden entirely rather than showing an always-empty block for an org without the module.

Placed above CorLink's own existing Requests-focused stat grid and Action Needed/Workload/Deadlines panels — nothing about the rest of the dashboard changes.

## 3. Data

- **Next Meeting** — the soonest upcoming scheduled meeting that hasn't ended yet (`status = 'scheduled' && end_at >= now`, sorted ascending), from `MeetingsAPI.fetchMyMeetings()` (creator, organizer, or participant — the same "My Meetings" definition the Meetings tab's own tab already uses). The countdown ("3h 36m") is a snapshot computed at render time, not live-ticking — matches the effort level of the MeetFlow screenshot itself. Hidden entirely when there's no upcoming meeting.
- **Today's Meetings** — the same upcoming set, filtered to today's local calendar date. Rendered with `MeetingsView._meetingCard()` (docs/150) — reused directly rather than a second copy of the same card markup.
- **Pending RSVPs** — a new `MeetingsAPI.countMyPendingRsvps()`: the caller's own active `meeting_participants` rows still `invitation_status = 'pending'`, on a meeting that's actually `'scheduled'` (an embedded-join filter, not a separate query) — excludes a stale pending row on a since-cancelled or still-draft meeting.

## 4. Files

- `js/data/meetings-api.js` — new `countMyPendingRsvps()`.
- `js/views/dashboard.js` — new Home section (hero + stat tiles + today's list), `_loadMeetingsHome()`, `_formatHM()`/`_formatCountdown()` helpers.
- `css/style.css` — `.next-meeting-hero*`, `.stat-grid--meetings`, `.stat-card--static`. The hero uses CorLink's own gold gradient (`--color-primary`/`--color-primary-dark`), not MeetFlow's literal teal — same convention the meeting detail modal already established (docs/20-23).

## 5. Deployment

Verified by rendering `DashboardView.render()` against sample data in a headless browser and screenshotting the result (hero, stat tiles, and today's meeting card all correct). Full regression sweep run; only the pre-existing, unrelated date-drift failures already documented in docs/144. No dedicated dashboard test file exists in this repo.
