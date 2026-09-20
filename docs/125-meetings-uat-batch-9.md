# 125 — UAT Batch 9: Schedule Meeting Layout, Duration Range, Rooms Chips, Agenda/Participants, Minutes Bug, My Notes Flicker

## 1. Requirement

A punch list of 8 items submitted as a Word document with screenshots, covering the Schedule Meeting form, the Rooms week-grid, and the meeting detail view:

1. "Expand the name box to fit to the column"
2. "Expand the agenda note to fit to the whole form and should be able to add supporting multiple files to this window"
3. "Duration should have maximum 8 hours and by default it should show 30 minutes"
4. "When a meeting is scheduled, in rooms it should show, the section name, who booked, and duration"
5. "Instead of description it should be agenda, and this field should have some kind of border drawn"
6. "Organize the participants arrangement to make it easy to read and easy to mark the attendance as well"
7. "Make the minutes form wider and after adding minutes when I click save it does not save and does not appear in minutes"
8. "When a click save in my notes the form disappear for show again, should not happen that"

## 2. Schedule Meeting form (items 1–3)

- **Staff/Group select boxes** (`#sm-staff-select`, `#sm-group-select`) previously sized to their longest option's intrinsic content width, leaving them narrower than the search input directly above them in the same side column. Fixed with `.modal-two-col-side .field-select { width: 100%; }` (css/style.css).
- **Agenda/Notes editor** moved out of `.modal-two-col-main` entirely — it's now a sibling of `.modal-two-col`, spanning the full form width instead of just the 1.3fr details column.
- **Supporting Files**: a new field (drag-and-drop + browse, reusing the existing `.attachment-dropzone`/`.participant-chip` styling) lets the caller queue files before the meeting exists. Since `AttachmentsAPI.upload()` requires a record id, files are queued client-side (`pendingFiles`) the same way participants already are, and uploaded via `AttachmentsAPI.upload('meeting', mid, file)` in the same partial-failure-tolerant loop right after participants, for every meeting created (including every occurrence of a recurring series).
- **Duration**: `MEETING_DURATION_OPTIONS_MIN` extended from 5h (20 steps) to 8h (32 steps of 15 minutes); the Schedule Meeting form's default selection changed from 60 to 30, and the room-availability-capping fallback (`setDurationOptions`) changed its own default-on-cap from 60 to 30 to match.

### A pre-existing scoping bug this surfaced

`_openScheduleMeetingModal` computes `sections` and hands off to `_bindScheduleMeetingModal({ rooms, orgUsers, groups, onSuccess })` — which never received `sections`. This shipped silently in the previous UAT batch (docs/124) because most tests' default single-section fixture meant the `sections.length > 0 && !sectionId` check's `ReferenceError` was thrown and swallowed inside the async submit handler, making every Schedule Meeting submission fail silently. Fixed by passing `sections` through.

## 3. Rooms week-grid booking chips (item 4)

`RoomsView`'s `bookingEvents` mapping (rooms.js) now includes the booking's own `section.name` (already selected by `RoomsAPI`'s `BOOKING_SELECT`, no new query) and an explicit duration label in the chip's `meta` line, alongside the existing organizer name (`title`) and time range:

```js
meta: `${b.section?.name ? b.section.name + ' · ' : ''}${this._timeRange(b.start_at, b.end_at)} · ${this._durationLabel(b.start_at, b.end_at)}`,
```

`_durationLabel()` is a compact local formatter (no space before the unit, e.g. `2h`, `1h30min`) — deliberately not reusing meetings.js's `formatMeetingDuration()`, since these chips are a fraction of the modal's width and every extra character matters.

## 4. Meeting detail: Agenda + participants (items 5–6)

- The meeting's own description field is now labeled **Agenda** (was "Description") and rendered inside a new `.detail-agenda-box` (border + padding + subtle background), distinguishing organizer-authored rich text from the plain facts around it.
- Participant rows: the name line now carries only the name and an Organizer badge — invitation/attendance status badges moved to their own `.detail-participant-badges` row below the role/contact meta, so the name line isn't crowded. The attendance-status badge is now color-coded (`attended`→success, `absent`→error, `excused`→warning) instead of always outline. "Mark attendance" changed from a bare circular icon to a labeled button (`<i class="ti ti-user-check"></i> Attendance`), matching every other primary row action in this app. On phone-width screens (≤480px), the actions row wraps to its own full-width row rather than getting squeezed next to a wrapped badge row.

## 5. Add Minutes — width + a real save bug (item 7)

Two separate problems:

- **Width**: `_openEditMinutesModal` opened with no size modifier (the 440px default meant for "small pick-one forms"), despite being the same kind of writing-heavy rich-text surface as Edit Meeting/Schedule Meeting (which already get `{ large: true }`). Fixed: `{ stack: true, large: true }`.
- **The actual bug** ("does not save and does not appear in minutes"): the RPC succeeded, but the reopen afterward passed the **stale** `meeting` object (captured when the modal was opened, before the save) straight into `_openMeetingDetailModal`, which renders whatever meeting object it's handed — it does not re-fetch the row itself. Every other post-save reopen in this file (`_openEditMeetingModal`, cancel/lock/RSVP/etc.) re-fetches first via `MeetingsAPI.fetchMeeting(meeting.id)`; Add Minutes was the one place that didn't. Fixed by adding the same re-fetch before reopening.

## 6. My Notes save flicker (item 8)

My Notes is an **inline panel inside the base detail-view layer itself** — not a stacked sub-modal like Add Minutes/Add Participant/etc. Its save handler nonetheless called `this._closeModal()` before the (awaited) reopen, exactly copying the pattern used everywhere else in this file. For a stacked sub-modal that's correct — closing pops the top layer and instantly reveals the still-present detail view underneath, with no visible gap, while the reopen's own async data fetches run in the background. But My Notes has only one layer total: calling `_closeModal()` removed it immediately, leaving `#modal-root` genuinely empty for the entire duration of `_openMeetingDetailModal`'s awaited fetches (participants, booking, attachments, tasks) before anything new was rendered — exactly the "form disappear[s] then show[s] again" the user described. Fixed by removing the premature `_closeModal()` call and reopening directly (the same pattern the attachment-upload reopen a few lines below already used) — the old view now stays on screen, unchanged, until the new one is ready to swap in atomically.

## 7. Tests

- `tests/schedule-meeting-combined-form-frontend.test.js`: new tests for the full-width Agenda editor (asserts `#sm-description-body` has no `.modal-two-col` ancestor), the duration range/default (32 options, 15..480, default 30), and the Supporting Files queue-then-upload flow (`page.setInputFiles` + asserting `AttachmentsAPI.upload` fires once per queued file, once per created meeting).
- `tests/rooms-calendar-week-grid-integration-frontend.test.js`: new test asserting a booking chip's title/meta contain the organizer, section name, and a duration string.
- `tests/meeting-detail-modal-frontend.test.js`: new tests for the Agenda label/border, the participant badge-row reorganization and labeled Attendance button, Add Minutes' width and its re-fetch-before-reopen fix (asserts the saved minutes text is actually present in the reopened HTML, not just that `updateMinutes` was called), and the My Notes flicker fix (freezes `fetchMeetingParticipants` mid-reopen and asserts the original detail view is still on screen rather than `#modal-root` going empty).
- `tests/week-grid-frontend.test.js`: two pre-existing, unrelated tests ("bind() wires slot clicks…" and "desktop: slots past bookableUntilMinutes are non-clickable…") were silently relying on the real wall clock instead of freezing it like every sibling test in the same file already does, and started failing on their own once the sandbox's real date advanced past their hardcoded `2026-09-16` fixture (a dormant bug, unrelated to this batch, that this regression sweep happened to expose). Fixed by switching both to the file's own `newPageAt()` frozen-clock helper, matching the pattern already used by every other date-sensitive test here.

Full regression sweep across all 21 test files: 24/24 in the affected files, all others clean (same 4 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change).

## 8. Deployment

Cache-busters bumped: `css/style.css?v=20260920`, `js/views/rooms.js?v=20260920`, `js/views/meetings.js?v=20260920`. Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
