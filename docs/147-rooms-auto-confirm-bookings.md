# 147 — Room Bookings Confirm Immediately, No Manager Approval

## 1. UAT

Screenshot of Meeting Rooms' "Pending Approvals" tab (three of Hussain Zareer's own booking requests awaiting a manager's decision), with the instruction:

> "there is no need to approve this requests, once booked the slot is confirmed and room booked for that time unless it is cancelled"

Two follow-up decisions confirmed with the user:
- The 3 requests already pending under the old rule: **auto-confirm them now.**
- The now-permanently-empty "Pending Approvals" tab: **remove it** from Meeting Rooms' nav.

## 2. What changed

- **`create_room_booking()`** previously required the caller to be the room's own manager or an admin (`is_room_manager(...) OR is_admin()`), else `submit_booking_request()` created a `'pending'` row instead. That manager gate is gone — the only remaining check is the same org-membership rule `submit_booking_request()` already used (same org as the room, or super admin, and the room's org must have Rooms enabled). Every booking now inserts as `'confirmed'` directly, regardless of who makes it.
- **`assign_room_booking()`** (used by the Schedule Meeting form's room step) no longer branches on `is_room_manager()` between `create_room_booking()`/`submit_booking_request()` — it always calls `create_room_booking()` now, which enforces its own authorization.
- **Conflict prevention is unaffected.** `meeting_room_bookings_no_overlap` (an `EXCLUDE` constraint) already applied to both `'pending'` and `'confirmed'` rows — the approval step was never what prevented two people double-booking the same slot; it only added friction ahead of an otherwise-uncontested booking.
- **The three already-pending bookings** were auto-confirmed via a one-time data fix in the same migration, mirroring `approve_booking()`'s own write shape exactly (status/approved_by/approved_at, an `'approved'` audit_logs row, a `booking_approved` notification to the requester) — run as a bulk statement since there's no live session to drive `auth.uid()` in a migration.
- **`submit_booking_request()`/`approve_booking()`/`reject_booking()`** are left in the database, unused by the frontend as of this patch — a smaller, safer change than dropping working functions nothing currently calls.

## 3. Frontend

- **"Pending Approvals" tab removed** from Meeting Rooms entirely: the tab button, `_renderApprovalsTab`/`_approvalRow`/`_handleApproveClick`/`_confirmApprove`/`_openSelfApproveOverrideModal`/`_openRejectModal`, the `'approvals'` tab-route guard, and `_hasAnyManagerAuthority()`'s use for gating it (the helper itself stays — still used for the Rooms-tab empty-state hint).
- **Room-only "New Booking" form**: submit button is now always "Confirm Booking" (was "Request Booking" for a non-manager); the submit handler always calls `RoomsAPI.createRoomBooking(...)`, never `submitBookingRequest(...)`.
- **`RoomsAPI`**: removed `fetchPendingBookings`/`submitBookingRequest`/`approveBooking`/`rejectBooking` wrappers (nothing calls them anymore).

## 4. Files

- `supabase/patch-rooms-auto-confirm-bookings.sql` / `validate-…` / `rollback-…` — `create_room_booking()`/`assign_room_booking()` changes, plus the one-time auto-confirm data fix.
- `js/views/rooms.js` — Pending Approvals tab removed; booking form always confirms.
- `js/data/rooms-api.js` — dead wrapper functions removed.
- `js/views/meetings.js` — cross-reference comment updated (no code change — `assign_room_booking` already routes through the same RPC).

## 5. Deployment

Migration applied + validated on CorLink Staging — all 3 previously-pending bookings confirmed (`SELECT count(*) FROM meeting_room_bookings WHERE status = 'pending'` returns 0). Full frontend regression sweep run; only the same pre-existing, unrelated date-drift failures noted in docs/144 (confirmed via `git stash` against the unmodified source before this session began touching these files).
