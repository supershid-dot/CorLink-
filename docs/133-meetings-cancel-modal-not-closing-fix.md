# 133 — Fix: Cancel Meeting Left the Detail View Open and Stale

## 1. Symptom

User report: clicking "Cancel Meeting" and confirming the cancellation left the meeting detail view open (had to be closed manually), and the Rooms week-grid didn't reflect the cancellation until a manual page refresh.

## 2. Root cause

Two compounding bugs, both in `_openCancelMeetingModal()`'s success handler:

1. **Wrong close call.** The Cancel Meeting confirmation is a `stack: true` sub-modal, layered on top of the meeting detail view by design (docs/123, "true modal stacking") — `_closeModal()` only pops the *top* layer, which is exactly right for non-terminal actions (add a participant, mark attendance) where the user should land back on the detail view. But Cancel Meeting is terminal: the meeting is gone. Popping back onto a stale detail view of an already-cancelled meeting (still offering "Cancel Meeting" as an option) was simply the wrong behavior.

2. **`_renderTab()` assumed the Meetings tab.** The success handler then called `await this._renderTab()`, which targets `#meetings-tab-content`. The same detail view (and everything stacked on it, including Cancel Meeting) can be opened from Rooms' own week-grid instead (`rooms.js` → `_openBookingOrMeetingDetailModal` → `MeetingsView._openMeetingDetailModal`). When opened that way, `#meetings-tab-content` doesn't exist in the DOM at all — `_renderTab()` throws immediately. Because this happened *after* `_closeModal()` had already removed the confirmation modal (and its `.modal-error` div) from the DOM, the thrown error landed in the `catch` block's `errEl.textContent = ...` against a already-detached node — visibly nothing happened, the user saw no error, and the stale detail view (and the Rooms grid underneath it, never told to refresh) just sat there.

`_openDeleteDraftModal()` (the sibling terminal action) and the series-cancel modal had the same `_renderTab()` assumption, though less likely to be hit from Rooms in practice.

## 3. Fix

- New `_closeAllModals()` — clears `#modal-root` entirely (every stacked layer at once), used for Cancel Meeting, Delete Draft, and series cancellation instead of a single `_closeModal()` pop.
- New `_refreshCurrentViews()` — refreshes whichever tab-content root(s) actually exist right now: `_renderTab()` only if `#meetings-tab-content` is present, and `RoomsView._renderTab()` only if `RoomsView` is defined and `#rooms-tab-content` is present. Guards both instead of assuming either one.

## 4. Files

- `js/views/meetings.js` — `_closeAllModals()`, `_refreshCurrentViews()`; `_openCancelMeetingModal()`, `_openDeleteDraftModal()`, and the series-cancel handler updated to use them.
- `tests/meeting-detail-modal-frontend.test.js` — 4 new tests: `_closeAllModals()` clears every layer; cancelling a meeting closes the whole stack (not just the confirmation layer); `_refreshCurrentViews()` calls `RoomsView._renderTab()` when mounted; and doesn't throw when neither view is mounted.

## 5. Deployment

Frontend-only change — no migration, no Edge Function redeploy. Cache-buster bump + regression sweep before commit.
