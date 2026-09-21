# 136 — Meeting Creator Is No Longer Auto-Added as a Participant

## 1. UAT

Two screenshots (Rooms week-grid, meeting detail Participants list) plus:

> "the section name should be shown in the calendar view as shown in the screenshot, and when a person creates a meeting, that person may not be a participant of that meeting, so he will not be in the participant list unless he selected as a participant, this feature must be added"

(The section-name half of this was docs/135 — a separate, already-shipped bug in `meeting_room_bookings.section_id`. This entry covers the second half only.)

Follow-up clarification (`AskUserQuestion`) on who should show as organizer once the creator isn't automatically one: **"Whoever the admin explicitly marks as organizer in the participant picker."**

## 2. Root cause

`create_meeting()` unconditionally inserted the caller as an `'organizer'` participant on every meeting it created. An admin/secretary scheduling on behalf of a section — never intending to attend — always ended up listed as a participant and as the meeting's Organizer, with no way to avoid it or hand that slot to someone else at creation time.

## 3. Fix

- **`create_meeting()`** gained a trailing parameter, `p_include_creator_as_participant BOOLEAN DEFAULT TRUE`. The creator-as-organizer insert now only runs `IF p_include_creator_as_participant`. The default keeps every existing caller's behavior unchanged.
- **`create_recurring_meeting()`** gained the same parameter and passes it straight through to its own internal `create_meeting()` call (one per occurrence).
- **`add_participant()` needed no change** — it already accepted `p_participant_role` (`'organizer'`/`'attendee'`/`'observer'`) and already rejected a second organizer via its own `unique_violation` handler ("This meeting already has an organizer"). Once `create_meeting()` stops claiming the organizer slot first, the frontend's existing post-creation participant loop can freely designate any one selected participant — who may or may not be the creator — as organizer through that same RPC.
- **Combined Schedule Meeting form** (`js/views/meetings.js`, single meeting or its own recurrence quick-picks):
  - The staff picker (`orgUsers`) no longer excludes the caller — they must now explicitly add themselves like anyone else if they're attending.
  - `createMeeting()`/`createRecurringMeeting()` are now always called with `includeCreatorAsParticipant: false` — this form fully owns participant creation itself.
  - The hardcoded, non-removable "You (organizer)" chip is gone. Each individually-queued participant (staff or guest) now shows a "Set organizer" link; clicking it designates that one participant as organizer (badge replaces the link) and is passed as `participantRole: 'organizer'` in its `add_participant()` call, with every other queued participant defaulting to `'attendee'`. Removing the designated organizer's chip clears the designation. No organizer is required — an admin can submit with none designated (or with only a group added) and assign one later via the meeting detail view's existing "Add Participant" flow, which already offers the same role picker.
- **Standalone "New Recurring Series" modal** (`_openRecurringMeetingModal`, its own "New Recurring Meeting" button) is untouched — it has no per-occurrence participant/organizer picker at all (only a single group selector), so it keeps calling `createRecurringMeeting()` without the new flag and the creator remains each occurrence's organizer, exactly as before. Only a form that actually offers organizer designation suppresses the auto-insert.

## 4. Files

- `supabase/patch-meetings-organizer-designation.sql` / `validate-…` / `rollback-…` — the `create_meeting()`/`create_recurring_meeting()` signature change (bodies reproduced verbatim from the live `patch-meetings-notification-completion.sql` versions, confirmed via `pg_get_functiondef()` on CorLink Staging before writing the migration).
- `js/data/meetings-api.js` — `createMeeting()`/`createRecurringMeeting()` gain `includeCreatorAsParticipant` (default `true`), wired to `p_include_creator_as_participant`.
- `js/views/meetings.js` — `_openScheduleMeetingModal()`: `orgUsers` filter, participant-chip rendering/organizer designation, submit handler.
- `css/style.css` — `.participant-chip-organizer-btn`, restyled `.participant-chip--organizer`.
- `tests/schedule-meeting-combined-form-frontend.test.js` — updated the render/queueing tests for the removed hardcoded chip; added coverage for the caller appearing as a selectable option, `includeCreatorAsParticipant: false` on both create paths, organizer designation via "Set organizer", `participantRole` on every `add_participant()` call, and clearing the designation on removal.

## 5. Deployment

Migration applied + validated on CorLink Staging. Frontend-only otherwise — cache-busters bumped (`js/data/meetings-api.js`, `js/views/meetings.js`, `css/style.css`). Full regression sweep: same pre-existing, unrelated failures only (6 "Edit Meeting" test failures in `schedule-meeting-combined-form-frontend.test.js` and 1 in `meeting-detail-modal-frontend.test.js`, confirmed present on the base commit via `git stash`; 5 files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` not available in this environment).
