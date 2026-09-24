# 154 — Remove Redundant "Recurring Series" Button

## 1. UAT

> "recurring series button is not needed now since it is now in new meeting"

## 2. Fix

The Meetings tab's header had two separate ways to create a recurring series: the standalone "Recurring Series" button (`_openRecurringMeetingModal()`, a dedicated form with its own title/type/recurrence/location/group fields), and the combined "New Meeting" form's own Recurrence tab (added when the Schedule Meeting modal was built — it already collects a recurrence pattern/interval/series-end-date and calls the same `MeetingsAPI.createRecurringMeeting()` RPC wrapper). The standalone button/modal was fully redundant with functionality the combined form already had.

Removed the "Recurring Series" button and its entire `_openRecurringMeetingModal()` method. The "New Meeting" button and its Recurrence tab remain the single way to create either a one-off or a recurring series.

## 3. Files

- `js/views/meetings.js` — removed the `new-recurring-meeting-btn` header button, its click handler, and the `_openRecurringMeetingModal()` method (229 lines).

## 4. Deployment

`MeetingsAPI.createRecurringMeeting()` is unaffected and remains used by the combined form's recurrence path. Full regression sweep run (`schedule-meeting-combined-form`, `rooms-calendar-week-grid-integration`, `meeting-detail-modal`); only the same pre-existing, unrelated date-drift failures already documented in docs/144.
