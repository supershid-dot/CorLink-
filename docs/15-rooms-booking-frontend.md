# Rooms and Booking Frontend

**Type:** Implementation record for the Phase 4 frontend (`docs/03-migration-architecture.md` §8), built directly against the already-implemented and already-tested database layer (`supabase/patch-rooms-booking-foundation.sql`, `docs/11-rooms-booking-database-foundation.md`). No new database objects were designed in this step — only the exact objects that migration already ships.
**Files:** `js/data/rooms-api.js`, `js/views/rooms.js`, `supabase/patch-rooms-route-activation.sql`, plus surgical edits to `index.html`, `js/app.js`, `js/router.js`, `js/views/shell.js`, `css/style.css`.
**Date:** 2026-07-22
**Scope actually applied:** Local, disposable PostgreSQL instance only (`corlink_meetings_local`, already carrying both the Rooms/Booking and Meetings migrations from prior sessions). **Neither the CorLink nor the MeetFlow hosted Supabase project was accessed or modified.** MeetFlow was not touched. The Meetings frontend was **not** built — `platform_modules.route` for `meetings` remains `NULL` and no Meetings route was registered. Nothing was pushed to any remote branch.

---

## 1. What was built

### Route and navigation

- `#rooms` — a single route, five client-side tabs (Schedule, My Bookings, Rooms, Room Blocks, Pending Approvals — the last shown only to a user who manages at least one room). Mirrors `entry.js`'s single-route/multi-tab shape rather than `requests.js`'s separate list/detail route pair, since there is no natural "detail page" distinct from a booking-details modal reachable from any tab.
- `js/router.js`'s `MODULE_ROUTES['rooms'] = 'rooms'` — direct-URL and nav-link access both gated through the existing `moduleGuardPasses()`/`isModuleEnabled()` machinery, fail-closed exactly like every other module route (`requests`, `entry`, `prisoner-letters`, `admin`). No new gating mechanism was introduced.
- `js/views/shell.js` — a `Rooms` link added to the sidebar, topbar, and mobile bottom-nav, each gated by `AppShell.isModuleEnabled(user, 'rooms')`, matching the existing `showRequests`/`showEntry` pattern exactly.
- `js/app.js` — `Router.register('rooms', RoomsView)`.

### `supabase/patch-rooms-route-activation.sql` (new, small, additive)

`platform_modules.route` for `module_key = 'rooms'` was seeded `NULL` in `patch-platform-module-foundation.sql`, deliberately, per `docs/09`'s own conformance check ("Phase 4 only needs to set `route = 'rooms'` once the frontend ships"). `admin.js`'s Modules tab reads this column directly to decide whether an org's Enable toggle is clickable at all ("No route shipped yet — cannot be enabled") — without flipping it, no organization admin could ever turn Rooms on for their org, regardless of how complete the frontend is. This migration is a single idempotent `UPDATE ... WHERE route IS DISTINCT FROM 'rooms'`, wrapped in `BEGIN`/`COMMIT`, touching no table, RLS policy, trigger, or function. Verified locally: applied cleanly, confirmed the column flipped, re-ran a second time and confirmed zero rows affected (`UPDATE 0`) with the value unchanged.

### `js/data/rooms-api.js`

An IIFE data-layer module, same shape as `entry-api.js`. Every mutation on `meeting_room_bookings`/`meeting_room_blocks` is a bare `db.rpc(name, params)` passthrough using the RPCs' **exact** parameter names — never a direct `.insert()`/`.update()`/`.delete()` against those two tables, matching the reality that they carry SELECT-only RLS with zero write policies (`docs/09` §15). `meeting_rooms`/`meeting_room_managers` are ordinary RLS-gated reference/assignment tables and are written directly, the same shape as every other reference-data table in this codebase (`sections`, `entry_sections`).

Required functions, all present with the exact requested names: `fetchRooms`, `fetchRoomManagers`, `fetchBookings`, `fetchMyBookings`, `fetchPendingBookings`, `fetchRoomBlocks`, `checkRoomAvailability`, `createBookingHold`, `submitBookingRequest`, `createRoomBooking`, `approveBooking`, `rejectBooking`, `cancelBooking`, `rescheduleBooking`, `createRoomBlock`, `cancelRoomBlock`. A few small additions the architecture required beyond that exact list: `createRoom`/`updateRoom` and `addRoomManager`/`removeRoomManager` (direct-write CRUD for the two ordinary RLS-gated tables, needed by the Rooms management tab), `fetchBooking(id)` (single-row read, needed for the booking-detail modal and the notification deep-link), and `fetchMyManagedRoomIds()` (resolves the caller's explicit, non-supervisor `meeting_room_managers` grants, needed for client-side permission mirroring).

**`reschedule_booking` is called with 5 parameters** (`p_booking_id`, `p_new_room_id`, `p_new_start_at`, `p_new_end_at`, `p_new_timezone`) — the current shipped signature after the Meetings migration's additive `p_new_timezone` extension (`supabase/patch-meetings-foundation.sql` §6), not the 4-parameter shape `docs/10`'s original design sketch described. Confirmed against the actual migration file before writing the data layer.

Actor identity for every RPC comes from `auth.uid()` server-side; this file never sends a client-supplied user id as "who did this." Audit rows for the two direct-write tables (`meeting_rooms`, `meeting_room_managers`) are inserted client-side via the ordinary `logAudit()`-style convention used elsewhere in this codebase — booking/block audit rows are inserted **only** by the RPCs themselves (`docs/10` §12/§14) and are never duplicated here.

### `js/views/rooms.js`

- **Schedule** — day navigation (prev/next/today/date picker), room filter, a "show cancelled/rejected/expired" toggle (hidden by default), chronological list for the selected day using `booking_effective_status()`'s client-side mirror (`confirmed` + `end_at` in the past → displayed as `Completed`, never written to the row). "New Booking" opens the compose form.
- **My Bookings** — every booking the signed-in user created (`fetchMyBookings`), most recent first, with a View action into the shared detail modal.
- **Rooms** — read-only room list for ordinary users; supervisors/admins (`meeting_rooms_insert`/`_update`'s exact RLS actor set) additionally get "New Room" and "Edit" using only the fields the migration actually has (`name`, `capacity`, `bookable_until`, `is_active` — no speculative fields). A "Managers" action on every row opens a view of that room's explicit `meeting_room_managers` grants, with add/remove exposed only to supervisors/admins — the same additive-only, non-restricting semantics the database design established (`docs/10` §8 Option D): granting or revoking this table never affects an org-wide supervisor/admin's automatic management of every room in their org.
- **Room Blocks** — active blocks by default, with a toggle to include cancelled ones; "New Block" only lists rooms the current actor actually manages (mirrors `create_room_block`'s own authorization check), Cancel is manager-only. Conflict override is a distinct, explicit second step reachable only after a real conflict response from the server (never a pre-checked default) — see §3 below.
- **Pending Approvals** — shown only to a user who manages at least one room; lists org-wide `pending` bookings (`fetchPendingBookings`), with Approve/Reject actions. The Approve button is disabled with an explanatory `title` for the booking's own creator unless that actor is a super admin, mirroring `approve_booking()`'s own self-approval rule; a super admin approving their own booking is routed through a distinct, mandatory-reason confirmation modal, never the plain one-click path.
- **Booking details modal** — reachable from every tab, shows room/status/window/timezone/requester/section/approval-or-rejection-or-cancellation actor+timestamp/conflict-override detail, and a neutral `<span class="badge badge-outline"><i class="ti ti-link"></i> Linked to a meeting</span>` label when `meeting_id` is set — **with no route or link of any kind**, since the Meetings frontend does not exist yet. Reschedule and Cancel actions are offered from here when the actor/status allow it.
- **Notification bell integration** — `shell.js`'s notification click handler special-cases `record_type === 'meeting_room_booking'` to navigate to `#rooms` with a `bookingId` param (there is no `-detail` route for this module to reuse the existing `routes[recordType]` map's shape); `rooms.js`'s `render()` opens that booking's detail modal directly after the initial tab renders, regardless of which tab a manager vs. a requester would otherwise land on. Only the six notification types the migration actually ships are ever referenced anywhere in this frontend: `booking_submitted`, `booking_approved`, `booking_rejected`, `booking_cancelled`, `booking_changed`, `booking_conflict_attention` — no new type was invented, and `booking_conflict_attention` is correctly never triggered by this frontend either, since (per `docs/11` §1) no RPC in the shipped migration ever fires it.

### Conflict-override reality check (a real design correction made during this step)

The original plan sketched a general "override" affordance on the New Booking form. Re-reading the shipped trigger logic (`meeting_room_bookings_conflict_guard()`) during implementation showed this would have been a dead control: **`create_room_booking`, `submit_booking_request`, and `reschedule_booking` accept no override parameter at all**, and the conflict-guard trigger fires on every write into a blocking status (`hold`/`pending`/`confirmed`) — so by construction, no second row can ever enter a blocking state while a conflicting row already blocks that window, for *any* actor, manager or not. The only two RPCs that genuinely accept `p_override_reason` are `create_room_block` (a real, reachable override — a block can legitimately need to force through an existing booking) and `approve_booking` (whose override path is, in practice, exclusively the super-admin-self-approval case, since a `pending`/`hold` row that would conflict with something else could never have been successfully created in the first place). The frontend was built to match this exactly: no override control exists anywhere on booking creation or reschedule; `approve_booking`'s override reason is offered only inside the self-approval confirmation modal; `create_room_block`'s override reason is offered only as a second step after a real `overlap` error response, with a mandatory, never-pre-filled reason field and an explicit warning that conflicting bookings are **not** cancelled automatically. This mirrors the same "don't expose a parameter that can never do anything" discipline already applied once in this migration's own history (`assign_room_booking`'s removed `p_start_at`/`p_end_at`, `docs/14` §7/§9).

### Hold workflow — deferred, per instruction

No UI creates a `hold` row. `createBookingHold`/`submitBookingRequest(..., holdId)` exist in the data layer (so the RPCs remain fully reachable), but no compose flow in `rooms.js` calls them — every booking request goes straight to `pending` (ordinary staff) or `confirmed` (manager/admin), matching the "defer the visible UI if it adds unacceptable complexity while still supporting the RPC" guidance. A `hold` row created some other way (a future UI, or direct RPC use) still renders correctly wherever a booking might appear, via the existing status-badge map.

---

## 2. Security review

- **No service-role key anywhere** — `rooms-api.js` only ever uses `getSupabase()` (the existing anon/authenticated client) and `Auth.getSession()`.
- **No direct writes to `meeting_room_bookings`/`meeting_room_blocks`** — confirmed by reading the finished file: every mutation on those two tables is a `.rpc()` call; `meeting_rooms`/`meeting_room_managers` correctly use direct `.insert()`/`.update()`/`.delete()`, matching their real (non-SELECT-only) RLS.
- **No client-supplied actor identity** — no RPC call anywhere passes a user id parameter; the two direct-write tables' audit inserts use `session.user.id` only, the same convention already used throughout this codebase.
- **No production secrets added.**
- **Route guard verified** — `#rooms` is fail-closed exactly like every other module route (confirmed by reading `moduleGuardPasses()`; no special-casing was added for `rooms`).
- **Hidden role-specific controls are UX-only** — every gated control (Pending Approvals tab, New Room, Edit Room, Managers add/remove, New Block) was cross-checked against the exact RLS/RPC authorization condition it mirrors; none of them are the real security boundary.
- **No unsanitized `innerHTML` of user-controlled text** — every interpolation of a room name, person's full name, reason, cancellation reason, override reason, section name, or error message in `rooms.js` goes through `_escapeHtml()`; verified by grepping every such interpolation in the finished file.
- **No bare `alert()`** — the one spot that briefly used it during drafting (an approval failure from a plain table-row action, no modal already open) was replaced with a small error-only modal before this step finished; grepped the finished file to confirm zero `alert(` calls remain.
- **Availability checks are advisory only** — `checkRoomAvailability()`'s result is shown to the user before submission as a convenience, never treated as a guarantee; the actual submit always goes through the real RPC, which re-validates and can still reject even after a "available" response (a genuine, if narrow, TOCTOU window that the server — not this frontend — is responsible for closing, exactly as designed).
- **No unintended cross-org data requests** — `fetchRooms(orgId)` is always explicitly scoped; the booking/block reads intentionally carry no `org_id` filter because RLS's own org-wide "availability" visibility is the documented, intentional design (`docs/10` §15) — a room's booking existence must be visible enough to prevent double-booking attempts even to a non-manager of that room.

## 3. Testing performed

**Distinguishing what was actually tested, per this step's own requirement:**

### Tested against a real local PostgreSQL backend (not mocks)

Using `corlink_meetings_local` (already carrying both prior migrations from this session's earlier steps), issuing the **exact RPC names and parameter values `js/data/rooms-api.js` produces** (including JS's `.toISOString()` string format) via `psql` session-variable impersonation (`SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub = '<uuid>'`) — this validates the actual wire format, not just that the SQL text matches what was read:

| # | Scenario | Result |
|---|---|---|
| 1 | `fetchRooms` equivalent (plain `SELECT` scoped to org) | Returned both MCS rooms |
| 2 | `submitBookingRequest` (plain staff) | Succeeded, row created `status = 'pending'` |
| 3 | `createRoomBooking` attempted by the same plain staff member | Correctly rejected: `Not authorized to directly confirm a booking for this room` |
| 4 | `approveBooking` by a different actor (org-wide supervisor) on staff's pending booking | Succeeded, `status = 'confirmed'`, `approved_by` set |
| 5 | `rescheduleBooking` with all 5 parameters including `newTimezone` | Succeeded; `start_at`/`end_at`/`timezone` all updated correctly |
| 6 | `cancelBooking` by the booking's own creator, `reason = null` | Succeeded, no reason required — confirms the UI's "creator never needs a reason" branch matches the server exactly |
| 7 | Self-approval prevention: an actor calling `approveBooking` on their own booking | Correctly rejected with the exact message the UI's disabled-Approve-button `title` attribute assumes: `Cannot approve your own booking request` |
| 8 | `rejectBooking` by a manager, with a reason | Succeeded, `status = 'rejected'` |
| 9 | `createRoomBlock` + `cancelRoomBlock` by a manager | Both succeeded; `is_active` correctly flipped to `false` |
| 10 | `checkRoomAvailability` on a genuinely free window | Returned `true` |
| 11 | Direct `INSERT` into `meeting_rooms` by a plain staff member (simulating a hand-crafted request bypassing the UI gate) | Correctly rejected by RLS: `new row violates row-level security policy for table "meeting_rooms"` |
| 12 | Direct `INSERT` into `meeting_rooms` + `meeting_room_managers` by a supervisor (the `createRoom`/`addRoomManager` path) | Both succeeded |
| 13 | `anon` role reading `meeting_rooms` | 0 rows, as expected |
| 14 | `patch-rooms-route-activation.sql` applied, then re-applied | First run: `UPDATE 1`, route flipped to `'rooms'`. Second run: `UPDATE 0`, value unchanged — confirmed idempotent |

### Tested with a mocked backend (Playwright + a hand-written mock `getSupabase()`/`Auth`/`Router`/`AppShell`/`AdminAPI`, loading the real `rooms-api.js` + `rooms.js` unmodified)

Since the hosted Supabase project deliberately has **not** had the Rooms/Booking migration applied (an intentional, preserved boundary — this step never touched it), and no PostgREST instance was stood up in front of the local database, a genuine live-browser end-to-end session was not possible without either violating that boundary or introducing new untested infrastructure. A mock harness was used instead to catch real DOM/rendering/event-binding bugs that static reading alone would miss:

- Rendered as a plain staff member: Schedule (with two seeded bookings, one pending one confirmed), My Bookings, Rooms (read-only — no New Room/Edit buttons present), booking-details modal, New Booking modal. Zero console errors, zero page errors, zero horizontal overflow at a 390px mobile viewport (confirmed the existing global `data-table` → card responsive conversion applies with no extra work, via the `data-label` attributes already present on every cell).
- Rendered as an org-wide supervisor: confirmed the "approvals" tab **is** present in the tab list (`["schedule","my-bookings","rooms","blocks","approvals"]`), the Approve button on someone else's pending booking is **not** disabled, the New Room/New Block/Managers-add controls **are** present, and the reject/new-room/new-block/managers modals all render without error.

### Static inspection only (no execution)

- Accessibility/responsiveness details not directly exercisable via the mock harness or SQL (screen-reader label semantics, keyboard-only modal traversal, color-independent status legibility) were verified by reading the markup and comparing against this codebase's existing, established patterns (`entry.js`'s identical modal/table/badge/empty-state shapes) rather than by a dedicated accessibility tool pass.
- `node --check` was run against every new/modified JS file (`js/router.js`, `js/app.js`, `js/views/shell.js`, `js/data/rooms-api.js`, `js/views/rooms.js`) — all pass.

### Explicitly not tested

- No live end-to-end session against a real, PostgREST-backed Supabase project (local or hosted) was performed. The RPC/RLS behaviors above were verified directly in PostgreSQL, and the rendering behaviors were verified via the mock harness — these two together cover the same ground a live browser session would, but were not combined into a single live session this step.
- Dark-theme rendering was not screenshotted separately; the view introduces no new colors or overrides outside the existing CSS variable system, so this is treated as low-risk rather than unverified-and-ignored.

---

## 4. Known limitations

- **`checkRoomAvailability` is advisory, not a lock** — a genuine (narrow) TOCTOU window exists between a "this slot is free" response and the actual submit; the RPC itself re-validates and will still reject on a real race, matching `docs/10` §4's own documented design.
- **No live hosted-Supabase verification** — this entire step, like the two database phases before it, was conducted without touching either Supabase project. `docs/11` §5's outstanding hosted-project checklist still applies, plus: confirm `platform_modules.route = 'rooms'` after applying `patch-rooms-route-activation.sql` there, and confirm an org admin can actually enable the module from `admin.js`'s Modules tab once it is.
- **Meetings linkage is display-only** — a booking's "Linked to a meeting" badge carries no route, by design, since the Meetings frontend does not exist yet. Once it does, wiring that badge to a real link is a small, isolated follow-up, not a redesign.

---

## 5. Files changed

- `js/data/rooms-api.js` (new)
- `js/views/rooms.js` (new)
- `supabase/patch-rooms-route-activation.sql` (new)
- `docs/15-rooms-booking-frontend.md` (new, this file)
- `index.html` (script tags for the two new files; cache-buster bump on `css/style.css`, `js/router.js`, `js/views/shell.js`, `js/app.js` — all four changed this step)
- `js/app.js` (route registration)
- `js/router.js` (`MODULE_ROUTES['rooms']`)
- `js/views/shell.js` (nav links in sidebar/topbar/bottom-nav; notification-click routing for `meeting_room_booking`)
- `css/style.css` (`.detail-grid`, a small addition for the booking-details modal's key/value layout — no existing rule changed)
- `docs/03-migration-architecture.md` (surgical update — Phase 4 marked "Implemented (database layer + frontend)")

No MeetFlow file was touched. No Meetings frontend file was created or touched. `platform_modules.route` for `meetings` remains `NULL`. Nothing was pushed.
