# 150 — Meetings List: MeetFlow-Style Cards

## 1. UAT

Two screenshots: CorLink's own Meetings list (a `.data-table` row, collapsed by its own mobile-responsive rules into a stacked TITLE/TYPE/WHEN/STATUS/LOCATION/VISIBILITY/ACTIONS field list — the same responsive pattern every other list view in this codebase already uses) next to MeetFlow's own list — a compact card with a colored left border, a status+category pill row, and icon-prefixed time/location lines.

> "Meetings should be displayed like in meetflow layout"

## 2. Scope decision

This replaces the Meetings list's own `.data-table` with a card layout — a deliberate, scoped deviation; every other list view in this app (Rooms, Requests, Tasks, etc.) keeps its table. Visibility (shown as its own table column before) is dropped from the card to match MeetFlow's more compact card — it's still filterable via the existing filters bar above the list, just not displayed per-row anymore.

Colors are CorLink's own (the gold/olive theme already established for the meeting detail modal in docs/20-23), not MeetFlow's literal teal branding — matching this session's standing convention of following MeetFlow's *layout*, never its literal colors.

## 3. Implementation

`_meetingRow()` (table `<tr>`) → `_meetingCard()`: a single `<button>` per meeting (the whole card is clickable, opening the detail — no separate "View" button, matching MeetFlow's own list), with:
- A `.meeting-list-card--{effectiveStatus}` modifier class driving the left border color (green/scheduled, gold/completed, red/cancelled, muted/draft).
- Title (+ a repeat icon when part of a series) and a "by {creator}" line.
- A pill row: the existing `_statusLabel()` badge + a type pill (reusing `.detail-pill--outline`, the same class the detail modal's own pill row uses).
- Two icon-prefixed rows: time range · date, and format (In person/Online/Hybrid) · location summary.

`_formatLabel(m)` extracted as its own helper (previously computed inline only inside the detail modal) so the list card and the detail modal share one implementation instead of two copies of the same three-way ternary.

## 4. Files

- `js/views/meetings.js` — `_renderList()`, `_meetingRow()` → `_meetingCard()`, new `_formatLabel()` helper (also used by `_renderMeetingDetailModal()`).
- `css/style.css` — new `.meeting-list-card*` rules, placed beside `.data-table`.

## 5. Deployment

Verified by rendering `_renderList()` against sample data in a headless browser and screenshotting the result (scheduled/completed/cancelled cards all correct). Full regression sweep run; only the pre-existing, unrelated date-drift failures already documented in docs/144 (confirmed via `git stash` in that entry) — no test file asserted on the old table structure, so none needed updating.
