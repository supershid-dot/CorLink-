# 152 — Home Tab: New Meeting Button + Clickable Stat Tiles

## 1. UAT

Follow-up to docs/151:

> "Add new meeting button" / "The cards should be clickable and navigate to relevant tab"

## 2. Fixes

- **"New Meeting" button** — added next to the existing "New Request" button in the page header (both now sit inside a new `.page-header-actions` wrapper), gated behind `this._meetingsEnabled`. Opens the same `MeetingsView._openScheduleMeetingModal()` every other entry point (Rooms, Calendar, the Meetings tab itself) already uses; its `onSuccess` refreshes the Home section's meetings data so a newly-created meeting shows up immediately without a manual reload.
- **Stat tiles now navigate** — "Today's Meetings" and "Pending RSVPs" were static, non-interactive `<div>`s (unlike every other dashboard stat card, which is an `<a>`). Both are now `<a href="#meetings">`, matching the existing Inbox/Sent/Overdue pattern exactly (a plain link to the relevant tab, no deep query-string filtering — same as those cards already do). The individual meeting card in the Today's Meetings list was already clickable (opens the meeting detail, docs/151) and is unchanged.

## 3. Files

- `js/views/dashboard.js` — page-header now wraps both buttons in `.page-header-actions`; stat tiles are `<a>` elements; `dashboard-new-meeting-btn` click handler.
- `css/style.css` — new `.page-header-actions` rule; removed the now-unused `.stat-card--static:hover` rule (the tiles are real links now, no longer need a hover override).

## 4. Deployment

Verified in a headless browser: both stat tiles render as `<a href="#meetings">`, and clicking "New Meeting" invokes `MeetingsView._openScheduleMeetingModal()`. Full regression sweep run; only the pre-existing, unrelated date-drift failures already documented in docs/144.
