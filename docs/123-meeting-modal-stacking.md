# 123 — True Modal Stacking: the Detail View Is Never Destroyed Underneath a Sub-Modal

## 1. Requirement

Follow-up to docs/121's fix (Cancel returns to the detail view): "But the original form is not visible when i open a new for[m] from that form." The user wants the meeting detail view to genuinely remain present — not just "get rebuilt afterward" — while a sub-action (Add Participant, Mark Attendance, Edit Minutes, etc.) is open on top of it.

## 2. Why docs/121's fix fell short of this

docs/121 made every sub-modal's Cancel/Keep button close the whole modal stack and then re-fetch + re-render the meeting detail from scratch (`_bindBackToDetail`). That fixed the *end state* (you land back on the detail view) but not the *mechanism* the user was asking about: opening a sub-modal still fully destroyed the detail view's DOM the instant it opened — it only came back via a fresh rebuild afterward, and only on Cancel/Save, never while the sub-modal was actually open.

## 3. Real stacking, not close-and-rebuild

`_openModal`/`_closeModal` (this file's own generic modal helpers) now support genuine layering:

- `_openModal(html, { stack: true, ... })` **appends** a new `.modal-overlay` layer inside `#modal-root` instead of replacing its contents. Every other call site — every `_openModal(...)` in this file that doesn't pass `stack: true` — is completely unchanged: it still clears `#modal-root` first, exactly as before. This covers the detail view's own first render, Meeting Groups, the Schedule Meeting form, and everything else that was never part of this problem.
- `_closeModal()` now removes only the **topmost** layer, revealing whatever is stacked beneath — untouched, still in the DOM, listeners still attached, scroll position and all. When there was only ever one layer (true for every non-stacked call site), this is identical to the old "clear everything" behavior.

Every sub-modal reachable from the meeting detail view now opens with `stack: true`: RSVP, Add/Remove Participant, Mark Attendance, Edit/Finalize Minutes, Lock/Unlock Meeting, Cancel Meeting, Delete Draft, Edit Meeting, the Supporting Tasks Create/Link modals, the recurring-series scope-choice dialog, and the series occurrences browser. Their Cancel/Keep/Close buttons went back to the plain `data-close-modal` attribute (removing docs/121's `_bindBackToDetail` helper entirely) — now correct, since `_closeModal()` pops just that one layer and the detail view underneath reappears exactly as the user left it, with **no re-fetch, no re-render, no flicker**.

The one case that intentionally still pops *two* layers: choosing "This meeting" in the recurring-series scope dialog closes the dialog (revealing the detail view) and then opens Edit/Cancel Meeting stacked directly on the now-revealed detail view — so backing out of that goes straight to the detail view, not back through the scope dialog.

Success paths (something actually changed) are untouched: they still call `this._closeModal()` then `this._openMeetingDetailModal(meeting)` to show fresh data, exactly as before docs/121. That reopen uses the default (non-stacked) `_openModal`, which fully clears `#modal-root` regardless of how many layers were stacked at that point — so a successful save always ends up with exactly one fresh detail-view layer, never an accumulating stack.

Two deeper, less-used recurring-series-specific forms (`_openSeriesEditModal`'s "This and future"/"Entire series" edit, `_openSeriesCancelModal`'s equivalent) were left as a plain, non-stacked, full replace — consistent with docs/121's decision to leave that older flow out of scope for now.

## 4. Tests

`tests/meeting-detail-modal-frontend.test.js`: a new check opens Add Minutes and asserts `#modal-root` holds **two** `.modal-overlay` layers with both the sub-modal's and the detail view's own content simultaneously present in the DOM (not just "the detail view comes back afterward"). The existing cancel-returns-to-detail checks were updated to click the topmost layer's close button (`#modal-root > .modal-overlay:last-of-type [data-close-modal]` — the detail view's own Close button also matches the bare `[data-close-modal]` selector once it's sitting underneath a sub-modal, so the click has to be scoped to the top layer) and gained an assertion that cancelling never calls `MeetingsAPI.fetchMeeting` — proving the revealed detail view is the original, not a re-fetched rebuild. Full regression sweep across all 21 test files run clean (same 4 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change).

## 5. Deployment

Cache-buster bumped (`js/views/meetings.js?v=20260917e`). Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
