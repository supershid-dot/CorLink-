# Meetings — CorLink V1 Product Decisions

**Type:** Finalized architecture/decision document (follow-up step to `docs/03-migration-architecture.md`, `docs/01-corlink-meetflow-audit.md`, and the implemented `docs/09-rooms-booking-v1-decisions.md`/`docs/10-rooms-booking-technical-readiness.md` pair). **No database tables, RLS, or frontend code are created in this step.** No SQL was written or applied. No application code was edited. Neither Supabase project was accessed. Nothing was deployed or pushed. This document is the Meetings equivalent of `docs/09` — its companion technical-readiness document is `docs/13-meetings-technical-readiness.md`.
**Date:** 2026-07-22
**Status:** Approved product decisions, recorded for implementation. Implementation (schema, RLS, RPCs, frontend) is a separate, future, explicitly-authorized step.

---

## 0. Preliminary `docs/03` §5 assumptions this document replaces

`docs/03-migration-architecture.md` §5 contains a preliminary, unfinalized sketch of a `meetings` table, written before Rooms/Booking's own design-then-readiness process existed as a precedent to follow. Every field in that sketch is superseded here; none are silently carried forward without comparison:

| `docs/03` §5 preliminary field | Disposition | Reason |
|---|---|---|
| `section_id` | **Dropped.** | No verified V1 requirement for a meeting to belong to a specific section rather than just an organization; `organization_id` (this document's field) is sufficient for V1 scoping. A future section-level filter can be added additively if a real need emerges — not built speculatively now. |
| `type` (`internal`/`external`) | **Replaced by `meeting_type`**, with a different, richer value set (§5 below) — the old two-value set conflated "who's in the meeting" with "what kind of meeting it is," which this design treats as two separate questions (`meeting_type` for the latter; participant composition is simply whatever `meeting_participants` rows exist, internal and external freely mixed). |
| `meeting_mode` (`physical`/`online`/`both`) | **Replaced by `location_mode`** (`room`/`external`/`virtual`) — a genuinely different concept, not a rename. `meeting_mode`'s `both` value implied a meeting could simultaneously be a physical room AND a virtual link with no way to express which is authoritative; `location_mode` is a strict single-mode selector, matching how `docs/09`'s own Rooms/Booking design treats a booking's room as a single, unambiguous resource. |
| `meeting_link` | **Replaced by `virtual_link`** (renamed only) — same field, but this document tightens its validation (§7) to an explicit safe-scheme allowlist, closing the `javascript:`-URI gap the original audit (`docs/01`) flagged. |
| `privacy` (undefined single value) | **Replaced by `visibility`**, a precisely three-valued, precisely defined field (§6) — `docs/03`'s `privacy` was never given concrete values or semantics; this document supplies both. |
| `room_id` (nullable FK directly on `meetings`) | **Dropped, not replaced.** | The already-implemented `meeting_room_bookings.meeting_id` is the sole database pointer between the two domains (§10) — a second, redundant pointer on `meetings` itself would create exactly the kind of dual-source-of-truth problem this document's booking-integration design (§10) is built to avoid. |
| `is_cancelled` (boolean) + `cancelled_at` + `cancelled_reason` | **Replaced by `status` enum** (`draft`/`scheduled`/`cancelled`) + `cancelled_by`/`cancelled_at`/`cancellation_reason` — matches this codebase's general status-enum convention (`requests.status`, `meeting_room_bookings.status`) rather than a boolean flag bolted onto an otherwise-separate lifecycle concept. |
| `is_locked` | **Dropped.** | No defined purpose in `docs/03`'s own sketch beyond a vague "locked" state; nothing in this document's approved V1 scope needs it. Not carried forward speculatively. |
| `recurrence_id` (nullable, Later) | **Dropped entirely — not even as a nullable placeholder column.** | Per this step's own explicit instruction ("no recurrence fields") and `docs/09`'s established discipline against speculative fields for deferred functionality. Recurrence remains `docs/03` §2's own "Later" item; if it ships, it arrives as new columns on a proven table, not a pre-reserved one. |
| `minutes_finalized` | **Dropped from V1.** | Minutes, agenda items, and decisions are explicitly deferred (§2) — no partial scaffolding for them is added to `meetings` in this step. |

Every replacement above was checked against the actually-implemented `supabase/patch-rooms-booking-foundation.sql` (the source of truth wherever it differs from any earlier proposal, per this step's own instruction) and found to have no conflict — this document introduces no field, table, or convention incompatible with what Rooms/Booking already shipped.

---

## 1. Scope

Meetings V1 includes exactly:

- One-off (non-recurring) meetings.
- `draft` and `scheduled` lifecycle states, with a derived (never stored) `completed` projection.
- Internal CorLink participants (real `users` rows) and external participants without accounts (free-text identity).
- Optional room booking, optional external (physical, off-site) location, optional virtual meeting link — exactly one `location_mode` per meeting.
- Meeting attachments through CorLink's existing, canonical `attachments` table/Storage bucket — no new mechanism.
- In-app notifications via CorLink's existing `notifications` bell.
- Canonical audit logging via CorLink's existing `audit_logs` table.
- Organization-scoped access, composed with the already-shipped Layer 1 (platform module + org enablement) / Layer 2 (role/relationship) model.

## 2. Deferred features (explicitly out of V1 scope)

Restated clearly, matching this step's own instruction and mirroring `docs/09` §14's precedent for Rooms/Booking:

- **Recurring meetings and meeting series** — no recurrence rules, series IDs, or recurrence-generation logic; no reserved column either (§0).
- **Meeting groups and custom meeting ACLs** — CorLink's existing role/section/org scoping (already composed into this document's permission model, §12) is a strict superset of a bespoke per-group ACL table, matching the same conclusion `docs/01` and `docs/03` §2 already reached for MeetFlow's `meeting_group_access`.
- **Telegram delivery** — CorLink's existing in-app bell only.
- **Email invitations** — no outbound email integration in this step.
- **External participant portal access** — an external participant is a free-text record on the meeting, never a login-capable account; nothing in this document creates a self-service portal, magic link, or any authentication surface for them.
- **Voting.**
- **Minutes and minutes-approval workflows.**
- **Agenda items and decisions.**
- **Attendance automation** (e.g. auto-marking attendance from some external signal) — `attendance_status` (§8) exists as a field or is manually set; nothing computes it automatically.
- **Reminder cron jobs** — `meeting_reminder` is deliberately not among the six notification types this step adds (§15); no scheduled job of any kind is introduced.
- **Room or booking attachments** — attachments remain meeting-scoped only, exactly as `docs/09`/`docs/10` already established for Rooms/Booking (bookings and rooms get no attachment support).

## 3. Final meeting statuses

Stored: `draft`, `scheduled`, `cancelled`. **`completed` is never stored** — it is a derived, read-time-only projection (§4), computed the same way `docs/10` §6 already established for `meeting_room_bookings.status`.

| Status | Who may create it | Who may update the meeting | Allowed next statuses | Notifies? | Terminal? | Stored or derived? |
|---|---|---|---|---|---|---|
| `draft` | The creating staff member (§12) | Creator, org supervisors/admins, super admins | `scheduled`, `cancelled` | No (drafts are pre-publication, not yet real to participants) | No | Stored |
| `scheduled` | Same actors, either directly or via `draft → scheduled` | Same actors | `cancelled` only (never back to `draft`) | Yes — `meeting_created` on first becoming `scheduled` (whether created directly as `scheduled` or published from `draft`); `meeting_updated` on later meaningful edits (§15) | No | Stored |
| `cancelled` | N/A (only reached via `cancel_meeting`) | No further updates of any kind | None — terminal | Yes — `meeting_cancelled` | Yes | Stored |
| `completed` | N/A | N/A | N/A | No | Yes (once reached, cannot un-complete since it's derived from `end_at < now()`, which is monotonic) | **Derived only** — `meeting_effective_status()` computes it; nothing ever writes it |

## 4. Meeting lifecycle

Allowed **stored**-state transitions, enforced server-side (matching the `valid_request_status_transition()`/`valid_booking_status_transition()` precedent already used twice in this codebase):

```
draft     → scheduled
draft     → cancelled
scheduled → cancelled
```

- **`scheduled` can never return to `draft`.** An ordinary correction to a scheduled meeting (new time, new title, new location) stays `scheduled` — it is not a status transition at all, just a field update via `update_meeting` (§17).
- **`cancelled` is terminal.** No transition leads out of it.
- **`completed` requires no cron job and no database write-back.** `meeting_effective_status(status, end_at)` — `STABLE`, computed at read time: a `scheduled` meeting whose `end_at` has passed reads as `completed`; every other combination reads as its own stored `status` unchanged. Exactly the same shape as `docs/10` §6's `booking_effective_status()`, deliberately reused rather than reinvented.

## 5. Meeting types

Smallest useful `CHECK`-based set, per this step's own "adjust only if a verified CorLink requirement supports a different set" instruction — no such requirement was found in `docs/01`'s audit or anywhere else in this repository, so the suggested minimal set is adopted as-is:

`general`, `interview`, `training`, `operational`, `administrative`, `other`.

Purely descriptive/categorical — no value in this list gates any permission or lifecycle rule. `other` exists so the field is never a forced, meaningless guess.

## 6. Visibility semantics

`visibility IN ('private', 'participants', 'organization')`, default `'participants'` (the middle, most commonly-useful default — a meeting is normally about its named attendees, not blasted org-wide nor hidden from oversight).

| Value | Who may read the meeting |
|---|---|
| `private` | The creator; any listed organizer/participant; org supervisors/admins of the organizing organization; platform super admins. |
| `participants` | Same as `private`, plus every listed participant (organizer or not) — in practice `private` and `participants` differ only in whether *non-organizer* participants can see it, since `private` already includes organizers/creator/supervisors. |
| `organization` | Any authenticated, module-enabled user of the organizing organization (whether or not they are a participant), plus everything `participants` already grants. |

Every tier composes with, and never bypasses, organization isolation (§12) — `visibility` only ever *narrows or widens read access within the organizing org*, never grants cross-organization access. This resolves the one genuinely ambiguous case (`private` vs. `participants`, since both already include organizers/supervisors) precisely: the practical difference is whether an *ordinary, non-participant* member of the meeting's own org can ever see it at all (never, for either tier) versus whether a *listed-but-non-organizer* participant can (no for a meeting the product decision calls `private`... but that's a contradiction with "any listed organizer/participant" above).

**Resolving that contradiction explicitly, since it must have one concrete answer:** `private` means *only the creator, organizers, supervisors, and super admins* — an ordinary (non-organizer) participant added to a `private` meeting can still read it **because they were explicitly invited to it** (participation itself is the access grant, not a bypass of privacy — the same principle already used for `requests`' CC-recipient visibility elsewhere in this codebase), but nobody else in the organization can. `participants` and `private` therefore behave identically in practice for V1 (both: creator + all participants + supervisors + super admins) — the distinction that actually matters, and the one worth keeping as two separate values, is `organization` (org-wide) versus the other two (participant-scoped). Both narrower values are kept as distinct, precisely-documented options rather than collapsed into one, since a future product decision may want to differentiate them further (e.g. restricting `private` to organizers-only, excluding rank-and-file participants) without a schema change — but V1's actual enforced behavior is as stated: **`private` and `participants` are behaviorally identical in V1; `organization` is the one meaningfully broader tier.**

## 7. Location modes

`location_mode IN ('room', 'external', 'virtual')`, nullable (a `draft` meeting may not have decided yet).

- **`room`** — the meeting is intended to happen in a bookable CorLink room. **May exist temporarily with no linked booking** while still `draft` (per this step's own instruction) — a room is assigned via `assign_room_booking` (§17), separately from meeting creation. Once `scheduled`, a `room`-mode meeting is expected to have an active linked booking in ordinary use, but this is a product expectation enforced by the RPC layer's own flow, not a hard `CHECK` (a hard requirement would make `assign_room_booking` impossible to call *after* publishing, which is a real, supported flow).
- **`external`** — requires `external_location` (free-text physical address/description) to be set.
- **`virtual`** — requires `virtual_link` to be set, and that link must use a safe scheme (`https://` only — `http://` is deliberately excluded too, unlike Rooms/Booking's own precedent of allowing any `^https?://`, because a meeting join link is a much higher-value phishing/redirect target than a booking's descriptive metadata; this is a deliberate, documented tightening beyond the pattern used elsewhere in this codebase, not an oversight).

**Validation rules** (server-side, `CHECK`-constraint-backed where the check is a pure function of the row's own columns, RPC-enforced where it requires reading another table):

- `title` must not be blank (`btrim(title) <> ''`).
- `end_at > start_at`.
- `location_mode = 'external'` requires `external_location IS NOT NULL`.
- `location_mode = 'virtual'` requires `virtual_link IS NOT NULL` and `virtual_link ~ '^https://'`.
- Cancellation metadata alignment: `status = 'cancelled'` requires `cancelled_by`/`cancelled_at` both set; a **non**-cancelled row must not carry cancellation metadata (`status <> 'cancelled'` requires both fields `NULL`) — a stricter, bidirectional rule than the one-directional pattern used for `meeting_room_bookings`' approval/rejection fields, because cancellation here is genuinely terminal (nothing legitimately retains stale cancellation metadata after an impossible un-cancel, unlike a booking's `approved_by` surviving a later cancellation as legitimate history) — restated precisely in `docs/13`.
- No recurrence fields, no MeetFlow slot-index fields (`date`/`start_slot`/`duration`) — confirmed absent from this design (§0).

## 8. Participant model

One table, `meeting_participants`, for both internal and external participants — never two parallel tables (matching this step's own instruction and `docs/03`'s original "external participants modeled as rows with `user_id IS NULL`" intent, §5 of that document).

**Identity rule:** `user_id IS NOT NULL AND external_name IS NULL` (internal) **XOR** `user_id IS NULL AND external_name IS NOT NULL` (external) — the same XOR-identity shape already used elsewhere in this schema for polymorphic rows (e.g. `sections.department_id`/`division_id`).

- **Internal participants** reference a real `users` row; `external_*` fields are all `NULL`.
- **External participants** require no CorLink account; `external_name` is mandatory, `external_email`/`external_phone`/`external_organization_name` are optional free text.

### `participant_role`

`organizer`, `attendee`, `observer` (the suggested minimal set — adopted as-is; no verified need for a richer set).

### `invitation_status`

`pending`, `accepted`, `declined`, `not_required` (the last value exists for participants who don't meaningfully RSVP — e.g. an observer added purely for visibility, or an external participant added after the fact for record-keeping).

### `attendance_status`

`unknown` (default — nothing has been recorded), `attended`, `absent`, `excused`.

### Organizer representation — resolved

**Both `is_organizer` (boolean) and `participant_role = 'organizer'` exist, kept in permanent sync by a `CHECK` constraint** (`(participant_role = 'organizer') = is_organizer`). `is_organizer` is the field actually queried by the "at most one active organizer" uniqueness rule (§9) and by permission checks (§12) — a boolean is simpler and more directly indexable for that purpose than a text comparison repeated at every call site. `participant_role` remains the general-purpose, displayable role dimension shared with `attendee`/`observer`, consistent with how `invitation_status`/`attendance_status` are also plain enumerated text fields. Keeping both, synchronized by a constraint rather than collapsing to one, avoids ever having to decide "which field is authoritative" at a call site — the constraint makes that question unaskable.

### The meeting creator is automatically inserted as an organizer participant

**Yes, approved.** `create_meeting` inserts one `meeting_participants` row for the creator (`is_organizer = TRUE`, `participant_role = 'organizer'`, `invitation_status = 'accepted'`, `invited_by = created_by`) in the same transaction as the meeting itself. This avoids the otherwise-real oddity of a meeting's own creator being invisible in its own participant list, and gives `meeting_participants` a single, reliable source of truth for "who organizes this meeting" that composes cleanly with `visibility = 'private'`'s "organizer" grant (§6) without needing a separate `meetings.created_by`-based special case in every RLS policy.

## 9. Participant lifecycle

- **Removal is soft, not a hard delete.** `removed_at`/`removed_by`/`removal_reason` (nullable) — a removed participant's row is retained for audit/history, exactly matching this step's own "prefer soft removal" guidance. `remove_participant` sets these fields rather than issuing a `DELETE`.
- **Internal uniqueness:** a partial unique index on `(meeting_id, user_id) WHERE user_id IS NOT NULL AND removed_at IS NULL` — a user cannot be added twice while an active row already exists, but **can** be re-added after a prior removal (the old, removed row and the new, active row coexist — history is never erased by a re-add).
- **External deduplication:** a partial unique index on `(meeting_id, lower(external_email)) WHERE external_email IS NOT NULL AND removed_at IS NULL` — dedup only applies when a reliable identifier (a normalized email) exists. Two different external people who happen to share a name, with no email or with different emails, are both allowed — matching this step's own explicit requirement.
- **Organizer uniqueness:** a partial unique index on `(meeting_id) WHERE is_organizer = TRUE AND removed_at IS NULL` — at most one active organizer at a time. Removing the sole organizer is refused by `remove_participant` itself (an RPC-level rule, not a `DELETE`-blocking trigger) — a meeting must always have exactly one active organizer while it has any active participants at all; a manager wanting to hand off organizing duty first adds/promotes a new organizer, then removes the old one, never leaving a zero-organizer gap.

## 10. Meeting ↔ booking relationship

`meeting_room_bookings.meeting_id` (already nullable on the implemented Rooms/Booking table, currently with no FK) is the **sole** database pointer between the two domains. `meetings` gets **no** `room_booking_id` or `room_id` column of its own (§0) — this is the single most load-bearing decision in this document, since a second pointer would create an unenforceable dual-source-of-truth problem the moment the two ever disagreed.

Approved rules, precisely:

- A meeting may exist with no room at all (`location_mode` is `external` or `virtual`, or `room` with no booking assigned yet).
- A standalone booking (no meeting) continues to work exactly as Rooms/Booking already shipped it — nothing about this document changes standalone booking behavior.
- **At most one *active* (`hold`/`pending`/`confirmed`) linked booking per meeting** — enforced by a partial unique index on `meeting_room_bookings(meeting_id) WHERE meeting_id IS NOT NULL AND status IN ('hold','pending','confirmed')` (a genuinely new constraint on the existing table, added once `meetings` exists — the future implementation step's job, not this one's).
- **The booking and meeting must share the same organization** — `meeting_room_bookings.org_id = meetings.organization_id` whenever `meeting_id IS NOT NULL`, enforced by a trigger (no cross-table `CHECK` constraint exists in Postgres) extending the already-shipped `meeting_room_bookings_conflict_guard()` — see `docs/13` §10 for the exact mechanism.
- **A linked *active* booking's `start_at`/`end_at`/`timezone` must match its meeting's** — same trigger-based enforcement, activated only when `meeting_id IS NOT NULL` and the booking is in a blocking status. A cancelled/rejected/expired linked booking is exempt (it's history, not a live commitment that needs to stay in sync).
- **Assigning a room always goes through the trusted booking layer** (`create_room_booking`/`submit_booking_request`, already implemented) — `assign_room_booking` (§17) delegates to one of those two RPCs rather than performing a raw `INSERT`, so the conflict engine is never duplicated (per this step's own explicit instruction).
- **Arbitrary linking of an unrelated, pre-existing standalone booking is not supported in V1** — `assign_room_booking` only ever *creates* a fresh booking for the meeting's own window; it never accepts "attach booking X" as an operation. This closes an entire class of confused-deputy problems (linking someone else's unrelated booking to your meeting) without needing a bespoke authorization check for that specific case.
- **Changing meeting time/timezone atomically reschedules the linked booking; if the reschedule fails, the entire meeting update fails and rolls back** — `update_meeting` delegates to `reschedule_booking` (already implemented) inside the same transaction; a PL/pgSQL exception raised by the reschedule aborts the whole function call, including the meeting's own `UPDATE`, by ordinary Postgres transaction semantics — no special two-phase logic is needed, only correct statement ordering (see `docs/13` §13 for the exact ordering, informed directly by a real bug found and fixed in an earlier iteration of a similar function during the Rooms/Booking work — see that step's own testing notes for the precedent this document deliberately avoids repeating).
- **Cancelling a meeting atomically cancels its active linked booking** (§11).
- **Cancelling a booking does not cancel the meeting** (§11) — the one-way asymmetry this step explicitly requires.
- **Detaching a room cancels the linked booking, leaves the meeting active, and clears `location_mode` back to a non-`room` state (or `NULL`)** — never silently converts the booking into an unrelated standalone booking (an orphaned-but-still-live booking with no meeting and no clear owner would be a real, confusing dangling state).

## 11. Cancellation asymmetry

The relationship is deliberately **one-directional**, restated precisely since it's easy to get backwards:

| Event | Effect on the booking | Effect on the meeting |
|---|---|---|
| `cancel_meeting` | Its active linked booking is cancelled, atomically, in the same transaction. | The meeting becomes `cancelled`. |
| A booking is independently cancelled via the Rooms/Booking module's own `cancel_booking` (not through Meetings at all) | The booking becomes `cancelled`. | **Nothing.** The meeting remains exactly as it was (still `scheduled`, still `location_mode = 'room'`). This is a **known, accepted, deliberate limitation, not a bug**: fixing it would require a new trigger reaching from `meeting_room_bookings` back into `meetings`, retroactively modifying the already-shipped, already-tested Rooms/Booking migration — explicitly out of scope for this document and the future implementation step alike. Documented here so it is never mistaken for an oversight; the correct, supported path to keep both records consistent is `detach_room_booking` (which *does* clear `location_mode`), not an independent booking cancellation. |
| `detach_room_booking` | Its active linked booking is cancelled. | The meeting remains active; `location_mode` is cleared to a non-`room` value (or `NULL`) — never left claiming a room it no longer has. |

**Why the asymmetry is correct, not accidental:** a booking is a *scheduling resource claim*; a meeting is the *event itself*. Losing the room (cancelled by a room manager for administrative reasons, for instance) is a reason to find a new room or convert to virtual — it is not, by itself, a reason the meeting stopped needing to happen. The reverse (cancelling the meeting clearly should free the room) has no such ambiguity, which is exactly why only that direction cascades.

## 12. Permission rules

Composes CorLink's existing two-layer model exactly as already shipped (`docs/04`, reused verbatim by Rooms/Booking per `docs/09` §4/`docs/10` §7) — no new layer, no permission-string system, no negative-access assignments:

- **Layer 1 (module + org enablement):** `is_module_active('meetings')` AND `module_enabled_for_org(organization_id, 'meetings')` (or `current_user_module_enabled('meetings')` for the caller's own org) — both already exist from Phase 1 (`meetings` is already seeded in `platform_modules`, `route IS NULL`, unshipped/unreachable exactly as expected). Room assignment additionally requires the **Rooms** module's own equivalent gate (`rooms_module_active_for`, already implemented) — a `room`-mode meeting in an org with Rooms disabled can exist, but cannot have a room assigned to it.
- **Layer 2 (role/relationship):**
  - Any active, authenticated staff member of an org with `meetings` enabled may **create** a meeting in their own organization.
  - The **creator** may manage (`update_meeting`/`cancel_meeting`/participant management) their own `draft` or `scheduled` meeting.
  - An org's **supervisors and admins** (`is_supervisor_or_above()`, org-matched — the identical org-wide, not section-scoped, authority model `docs/10` §8 Option D already established for room management) may manage any meeting in their own organization, regardless of who created it.
  - **Platform super admins** (`is_super_admin()`) may manage meetings across every organization.
  - **Internal participants** may *read* (never manage, unless they are also the creator/a supervisor/a super admin) any meeting they are an active (non-removed) participant of, subject to `visibility` (§6).
  - **External participants without accounts** have no CorLink authentication identity at all — they receive no read access of any kind (§2, restated: no portal).
  - **External organizations** receive no `meetings` module access by default, matching every other non-`requests`/non-`prisoner_correspondence` module's default-disabled posture (`docs/03` §6's already-established default table).

## 13. External contact privacy — resolved

**Evaluated:** raw-table RLS (Postgres has no native column-level masking — a `SELECT` policy is all-or-nothing per row, so any policy permitting a participant to read the row at all would expose `external_email`/`external_phone` too); a restricted view (workable, but views don't compose as cleanly with this codebase's existing "helper function" convention and would be the first view in the schema); a read RPC/function returning redacted fields.

**Approved: a `SECURITY DEFINER` read function** (`meeting_participant_list(meeting_id)`, contract in `docs/13` §8) — the same shape as the already-implemented `check_room_availability`-style read RPCs, and the identical resolution this exact class of problem received in an earlier iteration of this design (external contact fields nulled via a `CASE WHEN <privileged> THEN value ELSE NULL END` inside the function body). The raw `meeting_participants` table's own `SELECT` policy is **narrower** than the safe function on purpose: privileged users (creator/organizer/supervisor/super admin) may read the full raw table directly; an ordinary participant's raw-table access is limited to their own row. The safe function is what the frontend actually calls for "list of everyone in this meeting" — it never nulls a privileged caller's view, and always nulls `external_email`/`external_phone` for a non-privileged caller viewing *other* participants' rows.

## 14. Attachment rules

CorLink's existing `attachments` table/Storage bucket is reused **as-is** — no new bucket, no attachments array/JSON column on `meetings`, no room or booking attachment support (both remain explicitly out of scope, matching `docs/09`/`docs/10`'s own established position).

- `attachments.record_type`'s `CHECK` constraint gains exactly one new value: `'meeting'`.
- **Meeting attachment authorization is based on meeting read/manage authority** — `attachments_select`/`attachments_insert`/`attachments_delete`'s existing per-record-type branch structure (§0's inspection confirmed the exact current shape) is extended with one new branch each, calling into this document's own `can_view_meeting`/`can_manage_meeting` helpers (contracts in `docs/13`).
- **The existing client-controlled `attachments_insert`/`attachments_delete` write path is not specifically insecure for this use case** — it is the same RLS-gated pattern already hardened for 8 existing record types (`request`, `response`, `internal_request`, `prisoner_letter`, `internal_reply`, `prisoner_reply`, `external_correspondence`, `external_correspondence_reply`), and extending it uniformly is consistent, not a weakening. No new trusted RPC is required purely for the attachment write itself.
- **One structurally-forced, deliberate consistency choice, stated explicitly so it is never mistaken for an oversight:** `attachments_delete`'s existing policy wraps every per-record-type branch in a single, table-wide `uploaded_by = auth.uid()` condition — meaning **only the uploader may delete their own upload**, for every record type including this new one, never "any meeting manager may delete anyone's attachment." Widening delete authority specifically for meetings would require restructuring that shared, table-wide condition, which would touch all 8 existing record types' delete behavior too — explicitly out of this document's scope ("do not redesign unrelated attachment behavior"). Meetings follows the same rule everything else already follows.
- Cancelling a meeting does not delete attachment history — attachments are never touched by `cancel_meeting`.
- Authorized meeting readers (per §6/§12) may read attachments; external participants without accounts receive no Storage access at all, consistent with §12.

## 15. Notification rules

CorLink's existing `notifications` table, extended with exactly six new `type` values (no more, no fewer — `meeting_reminder` is explicitly excluded from this step per its own instruction):

| Type | Recipients | Fires on |
|---|---|---|
| `meeting_created` | Every active internal participant except the actor | A meeting first becomes `scheduled` — whether created directly as `scheduled`, or published from `draft` via `update_meeting`. Never fires for a meeting that stays `draft`. |
| `participant_added` | The newly-added participant, if internal and not the actor themselves | `add_participant`, for an internal participant only — an external participant with no account cannot receive an in-app notification, so none is attempted. |
| `meeting_updated` | Every active internal participant except the actor | `update_meeting`, only for a **meaningful** change — title, start/end time, timezone, location mode, external location, or virtual link. A description-only edit does not fire this, to avoid over-notifying on routine drafting/copy-editing. |
| `room_assigned` | Every active internal participant except the actor | `assign_room_booking` succeeding. |
| `meeting_cancelled` | Every active internal participant except the actor | `cancel_meeting`. |
| `participant_removed` | The removed participant, if internal and the removal was not self-initiated (a person removing themselves doesn't need to be told they did so) | `remove_participant`. |

Rules, restated explicitly per this step's instruction:

- Every notification is inserted from within the owning `SECURITY DEFINER` RPC — never from client code — matching the deliberate, narrow deviation from CorLink's general client-insert convention that `docs/10` §11 already established for Rooms/Booking, for the identical reason (closing the gap where a client could otherwise forge an event that never happened).
- Internal users only. No external email or Telegram delivery of any kind.
- The acting user is never notified about their own action.

## 16. Audit rules

CorLink's existing `audit_logs` table. **`record_type = 'meeting'` covers every Meetings-related audit row, including participant and attachment events** (`record_id` is always the *meeting's* id, not a participant or attachment id) — a separate `meeting_participant` record type was considered and rejected: keeping every Meetings event centered on the meeting's own id produces one coherent per-meeting timeline (exactly what a "meeting activity log" UI will eventually want to query), rather than splitting history across two record types that would need to be joined back together for that same view.

`action` values needed (extending the existing enum, reusing wherever an existing value already fits):

| Action | Reused or new | Fires from |
|---|---|---|
| `created` | Reused | `create_meeting` |
| `edited` | Reused | `update_meeting` |
| `cancelled` | Reused | `cancel_meeting` (both the meeting-side and, separately, the booking-side row — the booking-side row already uses `cancelled` with `record_type = 'meeting_room_booking'`, per `docs/10` §12) |
| `rescheduled` | Reused (already added by Rooms/Booking) | `update_meeting`, when it delegates a time/timezone change to the linked booking |
| `assigned` | Reused (already exists in the base enum) | `assign_room_booking` |
| `unassigned` | **New** | `detach_room_booking` |
| `participant_added` | **New** | `add_participant` |
| `participant_removed` | **New** | `remove_participant` |
| `attachment_added` | **New** | Produced by the attachments subsystem's own existing convention (a client-side `logAudit()` call after a successful upload, matching how every other record type's attachment events are already recorded — not a Meetings RPC's job) |
| `attachment_removed` | **New** | Same as above, on delete |

Every audit row records: the actor (`user_id = auth.uid()`, RLS-enforced), the meeting's `record_id`, and (via `notes`, this schema's one free-text detail field, per `docs/10` §12's own established pattern) a human-readable summary of what changed — organization is not stored directly on `audit_logs` (never has been, anywhere in this schema); it is resolved via the existing join-back-to-`users.org_id` convention `audit_select`'s policy already uses. A `rescheduled` audit row for the linked booking cross-references the meeting by virtue of the booking's own `meeting_id` — no duplicate storage of "which meeting this booking event belongs to" is needed.

## 17. Required RPCs

Exactly seven — **no `complete_meeting`** (completion is derived, §4, so there is nothing for such an RPC to do). Full input/output/error contracts are `docs/13` §9's job; this document states the product-level behavior each one must guarantee.

- **`create_meeting`** — creates as `draft` or `scheduled`. **Does not accept an inline participant array** — participants are added only through `add_participant`, resolved here as the "simpler and safer" of the two options this step asked to choose between: a single, uniformly-authorized, uniformly-audited, uniformly-deduplicated code path for every participant addition, whether it happens at creation time or later, rather than two different code paths that both have to independently reimplement the XOR/dedup/organizer rules. Room assignment is likewise a separate, later call (`assign_room_booking`), not an inline parameter.
- **`update_meeting`** — title/description/type/visibility/dates/timezone/location fields. Delegates time/timezone changes on a `room`-mode meeting with an active linked booking to `reschedule_booking`, atomically (§10).
- **`cancel_meeting`** — terminal transition; atomically cancels the active linked booking; preserves participants and attachments; requires a reason when the actor is not the meeting's own creator (matching the exact asymmetry already established for `meeting_room_bookings`' manager-cancellation rule).
- **`add_participant`** — enforces XOR identity, dedup, and the organizer-uniqueness rule; notifies (internal only) and audits.
- **`remove_participant`** — soft removal; refuses to remove the sole active organizer; notifies (internal, non-self-initiated only) and audits.
- **`assign_room_booking`** — creates a fresh booking for the meeting's own window through the trusted booking layer (never links an arbitrary existing one); enforces one-active-booking-per-meeting; audits and notifies.
- **`detach_room_booking`** — cancels the active linked booking; clears `location_mode`; leaves the meeting itself untouched otherwise; audits and notifies.

Every RPC: `SECURITY DEFINER` only where the operation genuinely needs to bypass RLS for a cross-table effect (mirroring exactly which of the nine Rooms/Booking RPCs needed it, per `docs/10` §14's own case-by-case justification — not applied blanket "because it's an RPC"); actor from `auth.uid()` only, refusing a `NULL` actor outright (never treating a null actor as implicit service-role authorization); enforces both module-enablement layers and organization scope; enforces the lifecycle rules in §4; inserts its own audit/notification rows server-side.

## 18. Security invariants

Restated explicitly, mirroring `docs/09` §15's structure for the Meetings domain:

- **No blanket authenticated policies** — every RLS policy is scoped (org, visibility, participant relationship, role, ownership).
- **No anonymous access** — every policy requires an authenticated CorLink user.
- **Organization isolation is mandatory** — `meetings.organization_id` roots every policy; `visibility` only narrows or widens access *within* that boundary, never across it.
- **Both module-enablement layers are required** for every meeting operation; room assignment additionally requires the Rooms module's own layer.
- **No direct mutation of `meetings` or `meeting_participants`** — `SELECT`-only RLS on both tables; every write goes through the seven RPCs (§17), matching the identical "strongest possible guarantee against direct REST bypass" design `docs/10` §14 already established for the two conflict-sensitive booking tables. Hard deletion is not part of V1 for either table.
- **External contact data is not broadly exposed** — resolved via a safe read function, never a broadened raw-table policy (§13).
- **The self-approval-style discipline already established for bookings has a Meetings analogue where it applies**: a meeting's own creator is never blocked from managing their own meeting (there is no "self-approval" concept for meeting creation the way there is for booking approval — a meeting is not something one party requests and another approves), but the *cancellation-reason* asymmetry (§17) plays the equivalent "extra friction for acting on someone else's thing" role.
- **Cancellation is one-directional and atomic** (§10/§11) — a meeting cancellation and its booking's cancellation either both succeed or neither does; a booking's independent cancellation never reaches back into the meeting.
- **Rescheduling is atomic** — a failed booking reschedule aborts the entire `update_meeting` call, including the meeting's own field changes (§10).
- **No recurring objects, no reminder cron** (§2).
- **No hosted Supabase project was touched by this document; MeetFlow was not modified.**

## 19. Approved implementation sequence

1. **This document pair** (`docs/12` + `docs/13`) — documentation only, this step. Complete.
2. **Meetings database implementation** (future, separate, explicitly-authorized step) — `supabase/patch-meetings-foundation.sql`: the `meetings`/`meeting_participants` tables, the `meeting_room_bookings` extensions (FK, one-active-booking constraint, org/time/timezone-match trigger), the seven RPCs, RLS, and the CHECK-constraint extensions this document specifies. Depends on the already-implemented Rooms/Booking foundation (`docs/11`) — sequenced strictly after it, matching `docs/03`'s own phase ordering once updated (§20 below).
3. **Meetings frontend** (future, separate, explicitly-authorized step) — not started, not scoped by this document. `platform_modules.meetings.route` stays `NULL` until then.

## 20. Product questions resolved by this document

- Whether meeting privacy needs a defined, precise semantics beyond a bare `privacy` field — **yes, resolved** as the three-tier `visibility` model (§6), with the `private`/`participants` practical-equivalence question explicitly resolved rather than left ambiguous.
- Whether `meetings` needs its own `room_id`/`room_booking_id` column — **no**, `meeting_room_bookings.meeting_id` remains the sole pointer (§10).
- Whether the meeting creator should be inserted as a participant automatically — **yes** (§8).
- Whether "organizer" should be `is_organizer`, `participant_role`, or both — **both, kept in sync by a `CHECK` constraint** (§8).
- Whether participant removal should be a hard delete or soft — **soft**, with `removed_at`/`removed_by`/`removal_reason` (§9).
- How to deduplicate external participants without a login identity — **normalized-email partial unique index, only when an email is supplied** (§9).
- How to protect external contact fields without native column-level RLS — **a `SECURITY DEFINER` read function**, mirroring the existing `check_room_availability`-style precedent (§13).
- Whether meeting attachments need a new trusted write path — **no**, the existing client-controlled, RLS-gated pattern is not specifically insecure for this use case (§14).
- Whether cancelling a booking should cascade to its meeting — **explicitly no**, documented as a deliberate, known, accepted limitation rather than silently left inconsistent (§11).
- Whether `create_meeting` should accept an inline participant list — **no**, participants are added only through `add_participant` (§17).
- Whether a `complete_meeting` RPC is needed — **no**, completion is derived only (§4/§17).

---

## Validation (performed before committing this document)

- **Compared against `docs/03`:** every preliminary Meetings field in that document's §5 sketch was individually compared and its disposition stated (§0) — nothing was silently carried forward or silently dropped without a documented reason.
- **Compared against `docs/01`:** every relevant MeetFlow concept (`participants`, `meeting_groups`/`meeting_group_access`, the Telegram-shaped `notifications` table, the `attachments` JSON-link column, client-materialized recurrence) was checked against this document's decisions and found consistent with `docs/01`'s own migrate/replace/retire recommendations — no MeetFlow concept is reintroduced in a form `docs/01` already flagged as a regression (e.g. `meeting_group_access` stays replaced by role/org scoping, never rebuilt as a bespoke ACL table).
- **Compared against the implemented Rooms/Booking foundation:** every touchpoint (`meeting_room_bookings.meeting_id`, the conflict engine, the RPC-delegation pattern, the notification/audit server-side-insert convention, the `SECURITY DEFINER`/`search_path`-pinning discipline) was checked against `supabase/patch-rooms-booking-foundation.sql` as the actual, implemented source of truth — not against any earlier proposal — and found fully compatible, with zero required changes to the already-shipped migration (the one addition, the FK + uniqueness constraint + org/time-match trigger, is purely additive and deferred to the future implementation step, §19 item 2).
- **No implementation files were changed** — only this document and its companion `docs/13-meetings-technical-readiness.md` (plus a surgical `docs/03` update, see that document's own final-control section).
- **No SQL was written or applied.** No local database was used for this step. **No Supabase project was accessed.** MeetFlow was not touched. No frontend file was changed.

---

*End of document. No database table was created. No RLS was written. No frontend code was changed. No Supabase project was accessed or modified. Nothing was deployed or pushed.*
