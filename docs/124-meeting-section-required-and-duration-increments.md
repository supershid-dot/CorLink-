# 124 — Section Is Now Required (Auto-Selected When There's Only One), Duration Offers Every 15 Minutes

## 1. Requirement

UAT feedback on the Schedule Meeting form, from two screenshots (Section dropdown showing "— None —"/"Offender Records", Duration dropdown showing "15 min, 30 min, 45 min, 1h, 1.5h 30min, 2h, 3h, 4h, 5h"):

> "Select a section should be a must field and if assigned to one section the section should be selected by default"
> "Duration should be in every 15 minutes timeline like 15 minutes, 30 minutes, 45 minutes, 1 hour"

Two independent fixes, both in the Schedule Meeting and Edit Meeting forms (`js/views/meetings.js`).

## 2. Section — required, auto-selected when there's exactly one option

Previously the Section `<select>` always offered a "— None —" option, so a meeting could be scheduled with no section at all. Now:

- **Zero sections** (caller has no section assignment): the whole Section field block is hidden, same as before — nothing to require.
- **Exactly one section**: no picker shown at all — that one section's `<option>` is rendered with `selected`, and the field is just an informational single-value `<select required>`. No user action needed.
- **More than one section**: a disabled, non-submittable placeholder (`<option value="" disabled selected>— Select a section —</option>`) forces a deliberate choice. The native `required` attribute on the `<select>` means the browser's own constraint validation blocks submission before the click handler even runs — the same mechanism already relied on for Date/Start Time. Each submit handler (Schedule Meeting, Edit Meeting) also carries its own `sections.length > 0 && !sectionId` guard with an inline "Section is required." message, as defense in depth for anything that reaches the handler with a falsy value despite the native check (e.g. a future non-native submission path).

This applies to both Schedule Meeting (create) and Edit Meeting (update) — Edit Meeting additionally pre-selects the meeting's *existing* `section_id` when it's present among the caller's own sections.

## 3. Duration — every 15-minute increment, correct labels

The old duration list skipped straight from 45min to 1h to a broken "1.5h 30min" label (non-integer hour division plus a hardcoded, always-wrong "30min" suffix) to 2h/3h/4h/5h. Replaced with a single shared source of truth at the top of `js/views/meetings.js`:

```js
const MEETING_DURATION_OPTIONS_MIN = Array.from({ length: 20 }, (_, i) => (i + 1) * 15); // 15..300 by 15
function formatMeetingDuration(totalMinutes) {
  const h = Math.floor(totalMinutes / 60), m = totalMinutes % 60;
  if (h === 0) return `${m} min`;
  if (m === 0) return `${h}h`;
  return `${h}h ${m}min`;
}
```

Both forms' static option lists, and the Schedule Meeting form's own room-availability-capped list (which previously had a third, independently duplicated copy of the same array), now all read from this one constant/formatter — 15, 30, 45, 60(1h), 75(1h 15min), 90(1h 30min), … up to 300(5h), with correct labels throughout.

## 4. A pre-existing scoping bug this surfaced

`_openScheduleMeetingModal` fetches `sections` and then hands off event binding to a separate method, `_bindScheduleMeetingModal({ rooms, orgUsers, groups, onSuccess })` — which did **not** receive `sections`. Adding the new `sections.length > 0 && !sectionId` check into that bound submit handler threw `ReferenceError: sections is not defined` at submit time (caught silently inside the async click handler, so it looked like submission was simply being swallowed — `createMeeting` never got called, with no visible error). Fixed by passing `sections` through: `this._bindScheduleMeetingModal({ rooms, orgUsers, groups, sections, onSuccess })`.

## 5. Tests

`tests/schedule-meeting-combined-form-frontend.test.js`:
- `newPage()`'s `mySections` option now defaults to a single section (`sec-1`/Programs) so the majority of tests — which aren't specifically about the Section picker — keep auto-selecting and submitting without change; tests that exercise the multi-section picker explicitly pass `{ mySections: TWO_SECTIONS }`.
- New: "when the caller has more than one section, none is preselected and submitting without choosing one is rejected client-side" — asserts the initial value is `''`, that `createMeeting` is never called, and that the Section `<select>` fails `checkValidity()` (native blocking, same as Date/Start Time — not a custom `.modal-error` message).
- New: "when the caller has exactly one section, it is preselected automatically" — asserts no "— Select a section —" placeholder renders and the select's value is `'sec-1'`.
- Updated the existing "renders a Section field…" test to assert `required` is present and "— None —" is absent.
- Removed the now-invalid "leaving Section unset sends sectionId: null" test (contradicts the new required-field behavior).
- The three Edit Meeting tests using `fixtureMeeting` (`section_id: 'sec-2'`) now pass `{ mySections: TWO_SECTIONS }` so "Legal" is actually among the caller's sections and gets selected, matching the fixture.

Full regression sweep across all 21 test files: `tests/schedule-meeting-combined-form-frontend.test.js` 24/24, all other files clean (same 4 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change).

## 6. Deployment

Cache-buster bumped (`js/views/meetings.js?v=20260917f`). Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
