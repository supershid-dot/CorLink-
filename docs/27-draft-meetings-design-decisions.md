# 27 — Draft / Pre-booked Meetings: Design Decisions and Implementation Alignment

**Type:** Retrospective design-decision document, following the `docs/25`/`docs/26` precedent for a feature that shipped directly from `docs/22`/`docs/23`'s own specification without a dedicated design-decision doc being written first. This document closes that gap after the fact: it records the decisions actually reflected in the shipped implementation, distinguishes the two workflows `docs/22`/`docs/23` had bundled under one name, and reconciles every point where the implementation differs from those documents' original text.
**Date:** 2026-07-23
**Status:** The single-draft-meeting workflow is **shipped** — `supabase/patch-meetings-drafts.sql`, `js/data/meetings-api.js`, `js/views/meetings.js`, committed `b6ee08c` on `feature/corlink-platform-migration`, pushed to `origin/feature/corlink-platform-migration`. This document is documentation-only: it changes no code, no SQL, and no database object.
**Companion documents:** `docs/22-rooms-meetings-meetflow-parity-roadmap.md` §3.3 Q4 (the original product decision), `docs/23-rooms-meetings-implementation-specification.md` §Phase F (the original technical specification), `docs/25-recurring-meetings-phase1-design-decisions.md` (records that Recurring Meetings Phase 1 and Draft/Pre-booked Meetings shipped as two separable pieces of work, and that the draft half remained pending at that time), `docs/26-calendar-design-decisions.md` (records that Calendar already rendered `meetings.status='draft'` before this implementation, and drew the same shipped/deferred distinction this document formalizes).

---

## 1. Two workflows, one name — the distinction this document exists to formalize

`docs/22` §3.3 Q4 and `docs/23` §Phase F describe "Draft/Pre-booked Meetings" as a single feature: a bulk-creation mechanism, sharing `create_recurring_meeting()`'s engine, that generates a batch of `status='draft'` placeholder meetings across a date range × days-of-week × time window (`recurrence_pattern='custom_days'`, `is_draft_series`, `days_of_week`). That bulk mechanism is what `docs/25` §1 and §2 mean when they say "Draft/Pre-booked Meetings remain pending."

What shipped in `b6ee08c` is a different, narrower thing: **the single-meeting draft lifecycle** — creating one meeting with `status='draft'`, editing it, and later activating or deleting it — hardened to close every gap found when each meeting-mutating RPC was inventoried for draft-awareness. The single-draft mechanism (`create_meeting(p_status:='draft')`, `update_meeting(p_status:='scheduled')`) already existed before this implementation, shipped as part of the original Meetings foundation; what this implementation added was the surrounding correctness — notification suppression, RSVP/attendance/minutes/lock rejection, and a dedicated delete path — not the draft status itself.

**Both statements are true at once and must be read together:**
- The single-draft-meeting workflow (§2 below) is now fully shipped and hardened.
- The bulk pre-booking mechanism tied to the recurring engine (`custom_days`/`is_draft_series`/`days_of_week`) remains entirely unbuilt — `create_recurring_meeting()` has no such parameter, confirmed by inspection.

This document's own scope is the first bullet only. See §5 for exactly what remains deferred.

## 2. Single-draft-meeting workflow — architecture shipped

- **No parallel publish logic was built.** A draft is created via the existing `create_meeting(p_status:='draft')` and activated ("published") via the existing `update_meeting(p_meeting_id, p_status:='scheduled', ...)` — the same RPC used for every other meeting edit. `docs/23` §4's own note that "no new 'complete draft' RPC is needed at all" was followed exactly; this implementation added no new create/activate RPC of any kind.
- **Lifecycle: create → edit → activate → delete.** A draft can be freely edited by anyone who can manage it (`can_manage_meeting()`, unchanged) while still a draft; activation is a status transition on the same row via `update_meeting()`; a draft that should never become a real meeting is removed via the new `delete_draft_meeting()` (§3 below) rather than `cancel_meeting()`, which now rejects drafts outright (§4).
- **Meeting ids are stable across activation.** `update_meeting()` always `UPDATE`s the existing `meetings` row in place — there is no insert-then-delete, no id reassignment. A meeting's id, once created as a draft, is the same id it has for its entire life, including after activation.
- **Participant-facing notifications are suppressed while a meeting is a draft.** `add_participant()`, `remove_participant()`, and `update_meeting()`'s meaningful-change notification branch each gained a `v_meeting.status <> 'draft'` (or equivalent `v_new_status = 'scheduled'`) condition. The draft→scheduled activation transition itself is unaffected and unchanged — that remains the intended "announce now" moment, firing exactly one `meeting_created` notification to every participant, exactly as it did before this implementation (this behavior already existed; it was not added by this patch).
- **Room-manager approval notifications are intentionally preserved, not suppressed.** A draft "may or may not have a room" (`docs/22` §3.3 Q4); once a room *is* requested via `assign_room_booking()`, the manager who must approve or reject it still needs to be told, or the request would sit `pending` forever with no alert ever sent. This was implemented by decoupling the single pre-existing `p_suppress_notification` flag into two independently controlled audiences: `assign_room_booking()`'s own participant-facing `room_assigned` notification gained a new `v_suppress_participant_notification := p_suppress_notification OR (v_meeting.status = 'draft')` condition, while the flag passed through unchanged to `submit_booking_request()` (which fires the room manager's `booking_submitted` notification) was left completely untouched. A plain, non-recurring room request against a draft still notifies the room manager exactly as it would for a scheduled meeting.
- **Existing permission model reused, not replaced.** Every RPC touched by this implementation still gates through the same, unmodified `can_manage_meeting()` (creator, same-organization supervisor-or-above, or super admin) and `can_view_meeting()` — no new permission tier, no new role check, no narrower or wider authorization logic was introduced anywhere in this feature.
- **Existing RLS reused, not replaced.** No new table, no new RLS policy. `meetings` and `meeting_participants` remain SELECT-only for every role, exactly as before — every mutation this implementation adds or changes, including the new hard-delete, continues to go exclusively through a `SECURITY DEFINER` RPC.
- **Existing audit model reused, not replaced.** Every RPC continues writing to the same `audit_logs` table with the same actor-from-`auth.uid()` convention. The only schema change in this implementation is a single `audit_logs.action` CHECK-constraint restatement adding one new value, `meeting_draft_deleted`, for the new delete RPC (§3) — the full accumulated list was restated, not bare-appended, per this project's established convention.
- **Existing Calendar draft rendering reused, not rebuilt.** `docs/26` §2/§3 already recorded that Calendar renders `meetings.status='draft'` with a distinct dashed styling (`calendar-event--draft`) and that `CalendarAPI.fetchMeetingsInRange()` is status-unfiltered by design. Nothing in `js/data/calendar-api.js` or `js/views/calendar.js` needed to change for this implementation — the Calendar-side half of "draft rendering" was already correct before this feature's RPC-hardening work began. See §6 below.

## 3. New RPC: `delete_draft_meeting()`

The only path in this codebase that ever hard-deletes a `meetings` row rather than soft-cancelling it, restricted unconditionally to `status = 'draft'` — a scheduled meeting still only ever cancels, never hard-deletes, via the existing `cancel_meeting()`.

- Authorization is the same `can_manage_meeting()` check every other meeting-management RPC uses — no new, narrower permission model was invented for this one function.
- Any still-active linked room booking (`hold`/`pending`/`confirmed`) is cancelled first, so the room is genuinely freed.
- Because `meeting_room_bookings.meeting_id` has no `ON DELETE` clause (FK RESTRICT, `patch-meetings-foundation.sql`), every booking that ever referenced the draft — active or already cancelled/rejected — has its `meeting_id` set to `NULL` before the `meetings` row is removed. This decouples rather than deletes the booking, reusing the existing "standalone booking" (`meeting_id IS NULL`) shape already modeled elsewhere, so booking history is preserved rather than destroyed.
- Attachment metadata rows for the deleted meeting are removed explicitly — they carry no FK to `meetings` (a generic polymorphic `record_id`) so would not block the delete, but would otherwise become permanently orphaned and inaccessible once the meeting they referenced no longer exists.
- `meeting_participants` rows are not explicitly deleted — they cascade automatically via their own pre-existing `ON DELETE CASCADE` foreign key.

## 4. Draft restrictions — RPCs that now reject a draft outright

Each of the following RPCs gained an explicit `IF v_meeting.status = 'draft' THEN RAISE EXCEPTION ...` guard, with a distinct, specific error message identifying the reason:

- **No RSVP** — `respond_to_invitation()` rejects a draft's participant row ("Cannot respond to an invitation for a draft meeting"). A draft's participant rows exist with `invitation_status` defaulting to `pending` as an ordinary column default, not as an active request anyone should be able to act on yet.
- **No attendance** — `mark_attendance()` rejects a draft ("Cannot mark attendance on a draft meeting").
- **No minutes** — both `update_minutes()` and `finalize_minutes()` reject a draft ("Cannot update/finalize minutes on a draft meeting") — minutes describe what happened at a meeting that, as a draft, has not been confirmed to happen at all yet.
- **No locking** — `lock_meeting()` rejects a draft ("Cannot lock a draft meeting"). `unlock_meeting()` needed no corresponding change: since a draft can never become locked under this new guard, its own pre-existing "is not locked" check already rejects any call against one.
- **No cancel** — `cancel_meeting()` rejects a draft outright ("Cannot cancel a draft meeting — delete it instead using delete_draft_meeting"), redirecting the caller to §3's new RPC. A draft was never announced to anyone; cancelling it through the ordinary path would fire `meeting_cancelled` to every participant via `meeting_participant_recipient_ids()` — the same participant-notification leak the notification-suppression work in §2 exists to prevent, reached through a different RPC.

## 5. Bulk pre-booking — intentionally deferred, not part of this implementation

The bulk date-range × days-of-week pre-booking mechanism `docs/22` §3.3 Q4 and `docs/23` §Phase F describe — `create_recurring_meeting()` called with `recurrence_pattern='custom_days'`, `is_draft_series=TRUE`, and `days_of_week` set, generating a batch of draft placeholder slots in one transaction — was **not built** by this implementation and remains exactly as `docs/25` §1 described it: `is_draft_series` and `days_of_week` exist on `meeting_series` as inert, unused columns, and `custom_days` is rejected as a `create_recurring_meeting()` input. Nothing in `patch-meetings-drafts.sql` adds a parameter, branch, or column to `create_recurring_meeting()` — confirmed by inspection.

This is a deliberate scope boundary, not an oversight: every requirement this implementation was built from describes single-draft-meeting behavior (create/edit/activate/delete of one meeting at a time), and none of them describe bulk generation. Building the bulk mechanism remains future work, sequenced, as `docs/22` §6 already notes, as a specific application of the recurring-meeting creation machinery once undertaken — it is additive to what shipped here, not a rework of it, since the bulk path would still create individual `meetings` rows that immediately inherit every restriction in §4 above with zero further change.

## 6. Relationship to `docs/22`, `docs/23`, `docs/25`, and `docs/26`

This document does not supersede any of the four — it is the retrospective decision record `docs/23`'s own process (§Phase F: "this phase gets its own separate design-decision doc") required, reconciling prospective specification against what was actually built, and drawing the shipped/deferred line that none of the other four documents drew on their own. `docs/22` §3.3/§6 and `docs/23` §Phase F are both updated by this same documentation step to mark the single-draft-meeting workflow complete and to reference this document. `docs/25` is updated to note that its own "Draft/Pre-booked Meetings remain pending" statements refer specifically to the bulk mechanism, not the single-draft workflow this document now records as shipped. `docs/26` is updated with a short note that the draft rendering it already documented is now backed by a fully hardened draft lifecycle, not merely an unmodified status flag.

## 7. Known follow-up (not fixed by this document)

A regression review conducted before this implementation was pushed found that the in-app copy shown for a draft (the compose-form status option and the detail-modal draft alert in `js/views/meetings.js`) states a draft is "not visible to participants," which is not accurate — a participant already added to a draft can see it (title, time, location, other participants) in their own My Meetings list and detail view; only the notification is suppressed, not visibility. This is a wording defect, not a security defect (the underlying RLS/notification behavior recorded in §2 above is correct), and remains open for a future, code-touching fix — it is recorded here for completeness but not corrected by this documentation-only step.

---

## Validation (performed before committing this document)

- **Compared against the actually-shipped `supabase/patch-meetings-drafts.sql`** — every architectural claim in §2/§3/§4 was checked directly against that file's contents, not against `docs/22`/`docs/23`'s prospective text.
- **Compared against `docs/22` §3.3 Q4 and `docs/23` §Phase F line by line** — the shipped/deferred distinction in §1/§5 was independently verified against `create_recurring_meeting()`'s actual signature (no draft/bulk parameter exists) rather than assumed from the specification text.
- **The "known follow-up" note (§7) restates a finding from the regression review that preceded this document's commit** — not newly asserted here.
- **No implementation files were changed** — only this document, plus surgical updates to `docs/22`, `docs/23`, `docs/25`, and `docs/26` (this document's own §6).
- **No SQL was written or applied.** No database object was created, altered, or dropped. No Supabase project was accessed. No frontend or backend application file was changed. Nothing was deployed or pushed.

---

*End of document. No database table was created or altered. No RLS was written or changed. No application code was changed. No Supabase project was accessed or modified. Nothing was deployed or pushed.*
