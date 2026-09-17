# 122 — Meeting Detail: Drop Redundant Location Date/Time

## 1. Requirement

"In location the date and time is not need to display."

## 2. Fix

`_renderLocationDetail`'s room branch showed the booking's own start/end (`9/20/2026, 9:00:00 AM to 10:00 AM`) next to the room name — redundant with the Date/Time facts already shown right above it in the same modal, since a room is always booked for the meeting's own time window (`_openAssignRoomModal`'s own comment: "Uses this meeting's own time window"). The room name and its Confirmed/Pending status badge now render on their own, without the repeated date/time text.

## 3. Also verified (not a new fix — confirming docs/121's coverage)

The user's screenshots showed "Add Participant" and "Mark Attendance" both reachable from the detail view; both were already fixed in docs/121 (`_bindBackToDetail('add-participant-cancel-btn', ...)` and `_bindBackToDetail('mark-attendance-cancel-btn', ...)`) — Cancel on either already returns to the meeting detail view as of that deploy. If a device still shows the old close-to-underlying-page behavior, it's almost certainly serving a stale cached bundle rather than a remaining gap — this app's own `index.html` documents that mobile browsers can keep serving day-old JS/CSS from disk cache well after a fix ships; a full refresh (or clearing site data for corlink.pages.dev) picks up the new `meetings.js?v=20260917d`.

## 4. Tests

`tests/meeting-detail-modal-frontend.test.js`'s existing Location test gained an assertion that the booking's date/time text no longer appears. Full regression sweep across all 21 test files run clean (same 4 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change).

## 5. Deployment

Cache-buster bumped (`js/views/meetings.js?v=20260917d`). Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
