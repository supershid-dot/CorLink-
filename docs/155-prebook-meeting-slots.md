# 155 — Pre-book Meeting Slots (MeetFlow parity, admin-only)

## 1. UAT

> "pre book meeting rooms needs to be added to the corlink like in meetflow, this access is given to only admins of the system"

(with MeetFlow screenshots of its Meetings toolbar's "Pre-book" button and its "Pre-book Meeting Slots" modal: title, section, optional room, from/to date, day-of-week checkboxes, start/end time — "Creates placeholder bookings for a section. Section staff can later open each slot to complete the full details.")

## 2. Design

CorLink's `meetings.status` already has a `'draft'` value that is fully editable (title/section/room/time/agenda) and already visible via RLS to a section's own members before they're a participant (`can_view_meeting()`'s `m.section_id IN (SELECT my_section_ids())` branch) — so a "pre-booked slot" is simply a draft meeting tagged to a section with no participants yet. What was missing: a bulk day-of-week × date-range creation RPC (the existing `create_recurring_meeting()` only does weekly/biweekly/monthly single-day patterns and always creates `status='scheduled'`, never `'draft'`), and a way for section staff to *discover* a draft they aren't yet a participant on.

Two pieces:
1. **New RPC `create_prebooked_meeting_slots()`** — admin-only (checked server-side, not just in the UI), bulk-inserts one draft meeting per matching date via the existing `create_meeting()` building block, mirroring `create_recurring_meeting()`'s own structure. A room-booking conflict on any generated slot aborts and rolls back the *entire* batch — one RPC call is one implicit Postgres transaction, same all-or-nothing behavior `create_recurring_meeting()` already has, verified directly on staging (a 3-day batch overlapping an already-booked day rolled back with zero partial rows left behind, even when the conflicting day wasn't first in the loop).
2. **New "Pre-booked" tab** in the Meetings view (visible to everyone, like every other tab) — lists every draft meeting the viewer can see. RLS naturally scopes this: a section member sees their own section's pre-booked slots, an admin sees every draft in their org, a creator sees their own in-progress draft.

No new notification fires when slots are created — MeetFlow's own screenshots show none either, and a draft never notifies regardless (`create_meeting()`'s notification block is gated on `p_status = 'scheduled'`).

## 3. Files

- `supabase/patch-meetings-prebook-slots.sql` (+ `validate-`/`rollback-`) — `create_prebooked_meeting_slots()`; widens `audit_logs_action_check` with `'meeting_prebook_slots_created'`.
- `js/data/meetings-api.js` — `createPrebookedSlots()`, `fetchPrebookedMeetings()`.
- `js/views/meetings.js` — admin-gated "Pre-book" header button; `_openPrebookSlotsModal()`; new "Pre-booked" tab (`validTabs`, tab button, `_renderTab()` dispatch branch); after a successful batch, switches to the "Pre-booked" tab so the admin sees what was just created.
- `css/style.css` — new `.days-of-week-row`, reusing the existing `.checkbox-row` primitive.
- `tests/meetings-prebook-slots-frontend.test.js` (new) — button admin-gating, client-side form validation, RPC payload shape, "Pre-booked" tab wiring.

## 4. Also in this change: removed the redundant "Recurring Series" button

> "recurring series button is not needed now since it is now in new meeting"

The standalone "Recurring Series" button/modal was fully redundant with the "New Meeting" form's own Recurrence tab (same `createRecurringMeeting()` RPC). Removed the button and its `_openRecurringMeetingModal()` method (229 lines) — the New Meeting form's Recurrence tab remains the single way to create a recurring series. See docs/154 for the full write-up.

## 5. Deployment

- Migration applied to CorLink Staging; static `validate-meetings-prebook-slots.sql` checks passed.
- Manual smoke test on staging (as an org admin, via JWT-claims impersonation in the SQL editor): a plain batch produced the expected section-tagged drafts with zero participants; a room-reserved batch produced confirmed bookings; a conflicting batch — including one where the conflict landed *after* two non-conflicting days already in the same call — raised and rolled back with zero partial rows left behind. Test data cleaned up via `delete_draft_meeting()`.
- Full frontend regression sweep (`meeting-detail-modal`, `schedule-meeting-combined-form`, `meetings-notification-integration`, `rooms-calendar-week-grid-integration`, plus the new `meetings-prebook-slots` suite): only the same pre-existing, unrelated date-drift failures already documented in docs/144.
- Verified visually in a headless browser: the "Pre-book" button and "Pre-booked" tab render for an admin, the modal matches MeetFlow's layout in CorLink's own theme, and a created slot renders correctly as a "Draft" card.
