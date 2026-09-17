# 121 — Cancel Returns to Meeting Detail, Agenda Field Gets the Full Rich Editor

## 1. Requirement

Two follow-up UAT items against the meeting detail/edit views (docs/118, docs/120):

1. "When i click add minutes or add participants, the previous window is lost"
2. "Agenda Field should also have the Rich test editor"

## 2. Cancel/Keep buttons now return to the detail view

Every sub-modal reached from the meeting detail view (Add Participant, Edit Minutes, Finalize Minutes, Mark Attendance, Remove Participant, Cancel Meeting, Delete Draft, Lock/Unlock Meeting, RSVP Accept/Decline, the recurring-series scope-choice dialog, Edit Meeting itself, and Create/Link Supporting Task) already reopened the detail view on its **success** path — but its Cancel/"Keep X" button just used the generic `data-close-modal` attribute, which bare-closes the whole modal stack instead. Since the detail view had already been closed to make room for the sub-modal (`#modal-root` only ever holds one modal at a time — there's no modal stack), clicking Cancel dropped the user straight through to whatever page was behind the *entire* flow. Reached from Rooms' linked-meeting routing (docs/117) that page can be the Rooms grid rather than the Meetings list, so backing out of "Add Participant" could land the user somewhere with no easy way back to the meeting at all — exactly the reported "the previous window is lost."

New `_bindBackToDetail(buttonId, meeting)` helper: wires a button to close the current modal and reopen `_openMeetingDetailModal(meeting)`, instead of the generic bare close. Applied to every Cancel/"Keep X" button reachable from the detail view. Two deeper, less-used recurring-series-specific forms (`_openSeriesEditModal`'s "This and future"/"Entire series" edit, `_openSeriesCancelModal`'s equivalent) were left as-is for now — they're a separate, not-yet-modernized flow (still using the pre-docs/115 field set) reached one level further in, and out of scope for this round.

Cancel reopens with the *original* (pre-edit) `meeting` object — correct, since nothing was saved, so there's nothing stale to worry about; only the success paths (already correct before this fix) need a fresh re-fetch.

## 3. Full rich-text editor for the Agenda/Description field

The Agenda/Notes field in both the Schedule Meeting and Edit Meeting forms used the lighter pattern (plain `<textarea>` + `RichEditor.langToggleHtml`/`bindAutoDetect`) that My Notes and Meeting Minutes also used before docs/120 upgraded those two to the full toolbar (`RichEditor.create()`). This brings Agenda/Notes in line with the same full editor, matching the Requests module's compose/reply forms exactly:

- Both forms' Agenda field now renders a `<div class="field-group-row">` (label + language toggle on one line, matching Requests' own layout) followed by a container div that `RichEditor.create()` fills with the toolbar + contenteditable body.
- Edit Meeting's editor is pre-filled via `editor.setHTML(meeting.description || '')`; Schedule Meeting's starts empty.
- Both submit handlers now read `editor.getHTML()` instead of `fd.get('description')`, normalizing an empty editor (`'<p><br></p>'`) to `null` the same way My Notes/Minutes already do.
- The detail view's own Description display switched from `this._escapeHtml(...)` to `RichEditor.sanitize(...)`, matching Minutes/My Notes' read-side treatment.
- No `bindAutoDetect` on the rich body — matching the Requests module's own compose form, which only wires manual toggle clicks for its rich Message field (auto-detect stays on plain single-line inputs like Subject).

## 4. Tests

`tests/meeting-detail-modal-frontend.test.js` gained 3 checks (cancelling Add Minutes returns to the detail view showing the meeting again, not a blank/closed modal; same for Add Participant; same for Remove Participant/Mark Attendance/Lock Meeting in one combined check). `tests/schedule-meeting-combined-form-frontend.test.js` had its old textarea-auto-detect Agenda check replaced with 3 new checks (full toolbar renders instead of a plain textarea; the manual EN/Dhivehi toggle flips the rich body's RTL class; submitting sends the editor's sanitized HTML as `description`) plus one more for Edit Meeting's Agenda editor (prefilled from the existing description). Full regression sweep across all 21 test files run clean (same 4 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change).

## 5. Deployment

Cache-buster bumped (`js/views/meetings.js?v=20260917c`). Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
