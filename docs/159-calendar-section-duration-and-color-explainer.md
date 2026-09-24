# 159 — Calendar Grid: Section + Duration (Rooms Parity) + Color-Coding Explainer

## 1. UAT

> "in calendar also display section and duration only, display section, 11:00 - 12:00, 1h like this,"
>
> "how is the color code given here, is it a different color for each section?"

## 2. Fix: Calendar event chips show section + time range + duration

Same underlying change as docs/158 (Rooms Schedule grid), applied to the Calendar tab's own week-grid, but with the fuller format the user asked for here (section, time range, *and* duration — Rooms deliberately kept just section + duration, per that separate, earlier request). A meeting/booking event's title is now its section name (falling back to the meeting's own title when it has no section tagged — a meeting almost always has a real title, unlike a bare room booking, so losing it entirely when untagged would be a regression); its second line is now `{time range} · {duration}`, e.g. "11:00 AM – 12:00 PM · 1h". Room block events (maintenance windows) are unchanged — a block has no section to show.

**Known scope gap, not fixed here**: the "staff schedule" selector's `CalendarAPI.fetchUserSchedule()` calls a Postgres RPC (`fetch_user_calendar_events`) that doesn't return a section field — viewing someone else's schedule through that selector still falls back to the meeting's own title, since `sectionName` is undefined for those rows. Fixing that would need a small RPC migration; out of scope for this UAT, which was about the default "All meetings" grid.

## 3. Answer: how the color-coding works

Not per-section — there's no section-to-color mapping anywhere in the app. Color is keyed to **event type + status**:

- **Calendar tab** (`_eventVisual()`): a scheduled meeting is blue (`--color-secondary`), a draft is dashed grey, a cancelled meeting is red with strikethrough, a standalone room booking is gold/primary, a room block (maintenance) is amber/warning.
- **Meeting Rooms' Schedule tab**: keyed to the booking's own status — hold/pending is amber, confirmed is green, completed is gold, rejected/cancelled/expired is grey/red with strikethrough, a room block is its own amber/warning style.

Every section shares the same status-based palette; two meetings in different sections but the same status (e.g. both "scheduled") render identically in color, distinguished only by their text label.

## 4. Files

- `js/data/calendar-api.js` — `meetingEvents`/`bookingEvents` now include `sectionName`.
- `js/views/calendar.js` — `_renderWeek()` uses `sectionName` (fallback to `title`) + new `_timeRange()`/`_durationLabel()` helpers for meeting/booking events; block events unchanged.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — two new tests (section+time+duration shown; no-section fallback to the meeting's own title).

## 5. Deployment

Full `rooms-calendar-week-grid-integration` suite re-run (30/30 pass, including the two new tests — the 28 pre-existing tests are unaffected since none of their fixtures set `sectionName`, so they fall through to the same title text they asserted before). Verified visually in a headless browser: a section-tagged meeting renders "Offender Records" / "11:00 AM – 12:00 PM · 1h".
