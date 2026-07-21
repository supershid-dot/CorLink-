# Rooms and Booking — CorLink V1 Product Decisions

**Type:** Finalized architecture/decision document (follow-up step to `docs/03-migration-architecture.md` and `docs/08-meetflow-booking-schema-analysis.md`). **No database tables, RLS, or frontend code are created in this step.** No SQL was written or applied. No application code was edited. Neither Supabase project was accessed. Nothing was deployed or pushed.
**Companion documents:** `docs/03-migration-architecture.md` (overall migration architecture — this document finalizes and supersedes that document's previously-open Rooms/Booking items), `docs/08-meetflow-booking-schema-analysis.md` (source analysis — every open question in its §H is resolved below).
**Date:** 2026-07-21
**Status:** Approved product decisions, recorded for implementation. Implementation (schema, RLS, frontend) is a separate, future, explicitly-authorized step.

---

## Conformance check (performed before writing this document)

Every decision below was checked against CorLink's actual, verified schema/RLS conventions (`supabase/schema.sql`, `supabase/rls.sql`, `docs/04-platform-module-foundation.md`) — not assumed. Findings:

- **No conflicts found.** Every approved decision is compatible with CorLink's existing architecture as verified in the codebase.
- The module key `rooms` **already exists** in the `platform_modules` catalogue (seeded in Phase 1, `docs/04` — currently `route IS NULL`, i.e., unshipped/unreachable, exactly as expected before this module is built). No new module key is needed; decision §3's "the Rooms module is active" / "enabled for their active organization" gates map directly onto the already-shipped `is_module_active('rooms')` / `module_enabled_for_org(org_id, 'rooms')` / `current_user_module_enabled('rooms')` helper functions.
- CorLink's existing role set (`user_assignments.role`: `mcs_admin`, `authority_admin`, `supervisor`, `assigned_receiver`, `staff`) has **no existing concept of a per-room "room manager."** This is not a conflict — it's a genuine new grant CorLink doesn't have a slot for yet — but it means "room manager" cannot be a bare addition to the existing `role` CHECK constraint (that column is a single scoped grant per row; a room manager needs a many-to-many room↔person relationship, since one person may manage several rooms and one room may have several managers). §4 below recommends a shape for this, following the precedent CorLink already established for an identical problem (Entry's `entry_sections` table, used to designate which sections may log entries — see `docs/04`/Entry module history). This is flagged as an open item for Phase 4 implementation, not a conflict requiring this step to stop.
- CorLink already has a precedent for exactly the kind of server-side status-transition enforcement decision §10 requires: `trigger_check_request_status()` (`supabase/schema.sql`) is a `BEFORE UPDATE OF status` trigger enforcing valid transitions on `requests.status`. The booking-conflict design below (§7) follows that same "enforce in the database, not just in RLS or the client" discipline, extended with an exclusion constraint for the parts of the check that are naturally expressible that way.
- Naming: the decisions below refer to the canonical table as "a bookings table" and "a room_blocks table." CorLink's own architecture document (`docs/03-migration-architecture.md` §5) already established the collision-avoiding names `meeting_room_bookings` and `meeting_room_blocks` (avoiding a bare `rooms`/`bookings`/`room_blocks` name identical to MeetFlow's own live-only, legacy tables analyzed in `docs/08`). This document uses those already-established names throughout — **not a change to the approved decisions, just applying names CorLink had already settled on** for the same concepts.
- `pgcrypto` is the only Postgres extension currently enabled in CorLink's tracked schema (`supabase/schema.sql:8`). The conflict-prevention design below (§7) recommends an exclusion constraint requiring the `btree_gist` extension, which is **not currently enabled**. This is not a conflict (Supabase projects support enabling it), but it is a genuine new dependency, flagged explicitly in §16 rather than assumed silently available.

No decision below was changed from what was approved. Where CorLink's existing architecture already answers an implementation detail the approved decisions left open, that answer is stated and sourced; where it doesn't, the gap is listed in §16 as an open technical question, not silently resolved.

---

## 1. Decision Summary

| # | Area | Decision |
|---|---|---|
| 1 | Data model | One canonical `meeting_room_bookings` table with a `status` field. No separate hold/pending/confirmed tables. |
| 2 | Approval | V1 supports approval. Ordinary users create pending requests; room managers/admins approve, reject, or create pre-confirmed bookings directly. Enforced server-side. |
| 3 | Who may book | Four-part gate: Rooms module active platform-wide AND enabled for the user's org AND user holds the appropriate role/permission AND user is permitted to use/request the specific room. No MeetFlow auth model reused. |
| 4 | Temporary holds | Same table, `status = 'hold'`, `expires_at`, 10-minute default, evaluated server-side, no continuous worker required. |
| 5 | Meetings without rooms | Supported — `meeting.room_id`/`meeting.booking_id` remain nullable. |
| 6 | Rooms without meetings | Supported — `meeting_room_bookings.meeting_id` is nullable. A confirmed meeting-linked booking and a standalone booking must not conflict with each other. |
| 7 | Recurring bookings | Deferred. V1 ships single bookings only: explicit `start_at`, `end_at`, `timezone`. |
| 8 | Cancellation | Creator may cancel their own upcoming booking; room managers/admins may cancel within scope with a mandatory reason. Status-and-audit update, not row deletion. |
| 9 | Conflict override | Room managers, scoped admins, or super admins only; mandatory reason; actor + timestamp recorded; enforced server-side, not just in the UI. |
| 10 | Conflict enforcement | Enforced in PostgreSQL — hybrid exclusion constraint + trigger design (§7), not client-side-only. |
| 11 | Timezone | `start_at`/`end_at` as `timestamptz`; explicit IANA `timezone` column; V1 application default `Indian/Maldives`; no UTC-offset hardcoding. |
| 12 | Room blocks | Separate `meeting_room_blocks` table for administrative unavailability; conflicts with bookings; soft-deactivation, not hard delete. |
| 13 | Attachments | CorLink's existing `attachments` system for meetings only. Booking attachments and room attachments deferred — not MeetFlow's JSON-array design. |
| 14 | Notifications | CorLink's existing in-app bell. No Telegram. |
| 15 | Audit | CorLink's existing `audit_logs` table and `logAudit()` path. Not MeetFlow's disabled-RLS table. |

---

## 2. Booking Lifecycle

1. **Discovery** — an eligible user (§4) views a room's availability (derived from `meeting_room_bookings` rows in blocking statuses, plus `meeting_room_blocks`).
2. **(Optional) Hold** — the user's booking flow may place a short-lived `hold` row to reserve a slot while completing the request (e.g., a multi-step form, or reserving a slot momentarily while resolving a warned conflict). Holds are not mandatory — a user may submit a `pending` request directly without ever creating a `hold` row.
3. **Request submission** — an ordinary authorized user's booking request enters as `pending` (converted from a `hold`, or created directly). A room manager or admin's booking enters directly as `confirmed`.
4. **Decision** — a room manager or authorized admin approves (`pending → confirmed`) or rejects (`pending → rejected`) the request. The requester may also withdraw it (`pending → cancelled` or `hold → cancelled`).
5. **Expiry** — an unconverted `hold` past its `expires_at` no longer blocks availability and is evaluated as `expired` server-side (§6); confirmation against an expired hold fails.
6. **Active period** — a `confirmed` booking blocks the room for its `[start_at, end_at)` window.
7. **Cancellation** — the creator (before start) or an authorized manager/admin (within scope, with a mandatory reason) may cancel a `pending` or `confirmed` booking (`→ cancelled`). Started/completed bookings are not silently deleted.
8. **Completion** — once a `confirmed` booking's `end_at` has passed without cancellation, it is treated as `completed` (mechanism discussed in §16 — this is an open technical question, not fully specified by the approved decisions).
9. **Conflict override** (exceptional path) — a room manager, scoped admin, or super admin may force a `confirmed` booking into an overlapping slot despite an existing blocking reservation, with a mandatory reason, recorded actor/timestamp, and a clear UI warning (§8).

---

## 3. Approved Statuses and Allowed Transitions

Final status set (unchanged from the starting set — no additional statuses introduced, per the "avoid unnecessary additional statuses" instruction):

| Status | Blocks availability? | Who can create it | Allowed next statuses | Terminal? |
|---|---|---|---|---|
| `hold` | Yes, while not expired | Any user satisfying §4's four-part gate, as an optional first step of the booking flow | `pending`, `confirmed`, `cancelled`, `expired` | No |
| `pending` | Yes (approved rule — prevents multiple users from receiving conflicting approvals) | Any user satisfying §4's gate, directly or by converting their own `hold` | `confirmed`, `rejected`, `cancelled` | No |
| `confirmed` | Yes | A room manager or authorized administrator (directly, or by approving a `pending` request); also the target of a conflict override (§8) | `cancelled`, `completed` | No |
| `rejected` | No | A room manager or authorized administrator, transitioning a `pending` row | — | Yes |
| `cancelled` | No | The booking's own creator (before `start_at`) for their own booking, or a room manager/administrator within their scope (mandatory reason for the latter) | — | Yes |
| `expired` | No | System, server-side evaluation of a `hold` whose `expires_at` has passed (§6) | — | Yes |
| `completed` | No | System, once a `confirmed` booking's `end_at` has passed without cancellation (mechanism: §16 open question) | — | Yes |

No transition skips are permitted outside the table above (e.g., `rejected → confirmed` is not allowed — a rejected request must be resubmitted as a new `pending` row, mirroring how CorLink's existing `requests.status` transitions are enforced by `trigger_check_request_status()` rather than left to application discipline alone).

---

## 4. Role and Permission Expectations

Composes CorLink's existing two-layer model exactly as already shipped in Phase 1 (`docs/04`) — no new layer is introduced:

- **Layer 1 (module enablement)** — `is_module_active('rooms')` AND `module_enabled_for_org(org_id, 'rooms')` (or `current_user_module_enabled('rooms')` for the caller's own org). Both already exist; no schema change needed for this layer.
- **Layer 2 (role/permission)** — composes CorLink's existing `is_admin()` (`is_super_admin() OR has_role('mcs_admin') OR has_role('authority_admin')`) and `is_supervisor_or_above()` with a **new, room-scoped concept CorLink does not have today: "room manager."**

**Recommended shape for "room manager"** (proposed, not yet approved as schema — an implementation-time decision): a new join table, e.g. `meeting_room_managers (room_id, user_id, created_at)`, granting management of specific rooms to specific users — the same shape already used for Entry's `entry_sections` (which section a user must be in to log entries) rather than a bare new value on `user_assignments.role` (which is a single scoped grant per row and cannot naturally express "manages rooms X and Y but not Z"). `is_admin()` users implicitly manage all rooms in their org regardless of this table (matching how admins already bypass section-scoping elsewhere in CorLink), so the table only needs rows for non-admin room managers.

- **Room-level "allowed to use or request"** (§3's fourth gate) — the approved decisions require this as a real, enforced condition, not merely "any staff member of the org." Two shapes are possible and CorLink has no existing precedent to resolve this from: (a) every room is bookable by every user of the org whose Rooms module is enabled (an org-wide allowlist, the simplest shape, mirroring how MeetFlow itself had no per-room restriction beyond org-wide staff access — see `docs/01`/`docs/02`), or (b) specific rooms are restricted to specific sections/roles (e.g. a secure briefing room bookable only by supervisors). This is listed as an open technical/product question in §16 — the approved decisions establish that the gate must exist and be enforced, but do not specify its granularity.
- **Self-approval prevention** — a user cannot approve their own `pending` booking request even if they separately hold a room-manager or admin role for that room (§15's security invariant). This must be enforced as an explicit `created_by <> auth.uid()` (or equivalent) condition in the approval-transition's RLS/trigger logic, mirroring the same discipline CorLink already applies elsewhere to prevent self-service privilege escalation (`users_update_own_prefs`, `docs/02`/session history).

---

## 5. Approval Workflow

- **Default path (ordinary user):** create → `pending`. The booking is **not** visible as blocking-and-authoritative from the requester's perspective until a room manager/admin acts — but it **does** block the room's availability immediately upon creation (§3's approved blocking rule), preventing a second user from being approved into the same slot while the first request is still under review.
- **Fast path (room manager / admin):** create → `confirmed` directly, skipping the approval step entirely. This is the same actor set authorized to approve/reject others' `pending` requests.
- **Decision actions:** approve (`pending → confirmed`) or reject (`pending → rejected`) — both restricted to a room manager for that specific room, or an admin scoped to the booking's organization, or a super admin. Enforced server-side (RLS + any supporting trigger/function), not merely hidden in the UI — matching the approved decision's explicit "must be enforceable server-side and not only in the frontend" requirement.
- **No workflow engine.** V1 is a single approve/reject decision with no multi-step chain, no delegation, no escalation timer — deliberately, per the approved decision ("V1 does not need a complex workflow engine").
- **Forward compatibility.** The approved decisions call for the schema to "leave room for organization-level configuration later" without building it now. The `organization_modules.configuration JSONB` column (already shipped in Phase 1, `docs/04`) is the existing, already-available slot for a future per-org approval-policy setting (e.g. "which rooms require approval," "who approves by default") — no new column is needed on any Rooms/Booking table itself to satisfy this; it can hang off the module's existing configuration slot when that feature is actually built.

---

## 6. Hold-Expiration Behavior

- **Duration:** 10 minutes from creation, as the approved default (not configurable in V1 unless a later decision changes this).
- **Field:** `expires_at TIMESTAMPTZ NOT NULL` on `meeting_room_bookings`, set at hold-creation time (`created_at + interval '10 minutes'`), meaningful only while `status = 'hold'`.
- **Evaluation is server-side and lazy, not a background worker** — per the approved decision, V1 does not require a continuously running cleanup job. A `hold` row's expiry is evaluated at the moments it matters:
  1. **On any conflict check** (creating/approving another booking against the same room/window) — an expired `hold` is treated as non-blocking regardless of its stored `status` value, and is opportunistically flipped to `status = 'expired'` as part of that same operation (closing the gap between "logically expired" and "recorded as expired" without a separate scheduled job).
  2. **On confirmation attempts** — converting a `hold` to `confirmed`/`pending` must fail if `expires_at < now()`, per the approved decision ("confirmation must fail if the hold has expired").
- **Expired holds are retained, not deleted** — per the approved decision ("expired records may remain for audit purposes"), matching CorLink's existing no-hard-delete convention for lifecycle rows elsewhere (e.g. `requests`/`meetings`-style soft states).
- **Optional future backfill:** if a periodic sweep is later wanted for tidiness/reporting (e.g. dashboard counts of "expired holds"), CorLink already has a precedent mechanism for this exact shape (`pg_cron` + `check_deadlines()`, already running daily per `docs/02` §2) — not needed for V1, noted only so a future addition doesn't need a new pattern invented.

---

## 7. Conflict-Prevention Strategy

**Requirement:** prevent overlapping active reservations for the same room, enforced in PostgreSQL, safe under concurrent requests, not bypassable via direct API calls — blocking statuses are `hold` (while not expired), `pending`, and `confirmed`; non-blocking are `rejected`, `cancelled`, `expired`, `completed`.

**Recommended design — hybrid of a database exclusion constraint and a trigger, per the approved decision's own fallback instruction** ("If the expiration condition makes a direct exclusion constraint impractical, propose a transaction-safe database function or trigger-based design"):

1. **Exclusion constraint (primary safety net) covering `status IN ('pending', 'confirmed')`.** These two statuses block unconditionally (no time-dependent expiry logic involved), so they can be expressed directly as a `btree_gist`-backed `EXCLUDE` constraint over `(room_id WITH =, tsrange(start_at, end_at) WITH &&)` filtered to those two statuses. This is enforced by Postgres itself at commit time, immune to any application-level race condition or bypassed API call — the strongest guarantee available, and the reason it's the primary mechanism rather than the trigger.
2. **`hold` rows cannot participate in the same exclusion constraint**, because their blocking-ness depends on a mutable, time-based condition (`expires_at > now()`) — and exclusion-constraint predicates, like index predicates generally, must be immutable. This is exactly the "impractical" case the approved decision anticipates. For `hold` rows specifically, use a `BEFORE INSERT OR UPDATE` trigger on `meeting_room_bookings` that, within the same transaction:
   - takes a transaction-scoped advisory lock keyed by the room (`pg_advisory_xact_lock(hashtext(room_id::text))`), so two concurrent attempts to hold/confirm the same room serialize against each other rather than racing;
   - lazily expires any of that room's own `hold` rows whose `expires_at < now()` (flips them to `status = 'expired'`, per §6);
   - checks the remaining live `hold` rows (not yet expired) for the room for a time-range overlap against the incoming row, raising an exception on conflict.
3. **Net effect:** `pending`/`confirmed` conflicts are caught by the database's own constraint machinery (cannot be bypassed by any client, including a direct REST/API call that skips application code entirely); `hold` conflicts are caught by the trigger's locked, transaction-safe check. Both layers run inside the same `INSERT`/`UPDATE` transaction, so a booking is either fully safe or rejected — no window where a "committed but conflicting" row can exist.
4. **This does not depend on RLS for correctness** — RLS controls *who* may attempt an insert/update; the exclusion constraint and trigger control whether the *attempt* is allowed to succeed at all, regardless of caller identity, closing the exact gap MeetFlow's design left open (§E of `docs/08`: conflict checking was 100% client-side and trivially bypassable via direct REST calls). That gap does not exist in this design by construction.
5. **`meeting_room_blocks` are not part of the same exclusion constraint** (they live in a separate table, per the approved decision, §9 below) — cross-table conflict checking (a booking must not be creatable inside an active block, and vice versa) is handled by the same trigger extended to also query `meeting_room_blocks` for the room/window, or a second trigger — implementation detail for Phase 4, not decided further here.

This design requires enabling the `btree_gist` extension (not currently enabled in CorLink — see §16).

---

## 8. Conflict-Override Behavior

- **Who:** room manager (for that room), an appropriately scoped administrator (`is_admin()` within the booking's organization), or a super administrator (`is_super_admin()`). Ordinary users, including the booking's own creator, cannot override — matching the approved decision exactly.
- **Mandatory fields on an override action:** `override_reason` (required, non-empty), plus the acting user and timestamp — recorded as `overridden_by`/`overridden_at` on the resulting booking row (or via the audit log, §13 — the exact storage location is an implementation detail, but the *fact* must be recorded somewhere queryable, not only inferred from an audit-log entry that could be missed).
- **UI requirement:** the interface must clearly warn the authorized actor that they are about to create a double-booking before they confirm the override — not a silent success.
- **Server-side enforcement:** the same conflict-prevention trigger/constraint from §7 must have an explicit, narrowly-scoped override path — e.g., the trigger checks whether the acting role is override-authorized and an override reason was supplied, and if so, permits the otherwise-conflicting insert/update while still recording the override fields; RLS separately confirms the acting user actually holds one of the three authorized roles for that specific room/org, so an ordinary user cannot forge the override path by supplying a reason string alone.
- **Direct API calls must not bypass this** — since the check lives in a trigger/constraint (§7), not application code, there is no code path (including a direct REST call) that reaches the table without passing through it.

---

## 9. Room-Block Behavior

Table: `meeting_room_blocks` (CorLink's already-established name for this concept, per `docs/03` §5 — same concept the approved decisions call "room_blocks").

- References exactly one room (`room_id`, `NOT NULL`).
- `start_at`, `end_at` — `timestamptz`, same authoritative timestamp model as bookings (§11), not MeetFlow's `date_from`/`date_to` (`date`-only) shape.
- `reason` — required (mirrors bookings' cancellation-reason discipline for administrator actions).
- `created_by`, `created_at` — standard audit columns, matching every other CorLink table's convention.
- **Deactivation, not deletion:** an `is_active BOOLEAN NOT NULL DEFAULT TRUE` (or an equivalent `cancelled_at` timestamp) column supports deactivating/cancelling a block without hard-deleting the row, per the approved decision.
- **Conflicts with bookings both ways:** a new booking cannot be created inside an active block's window (checked by the shared conflict logic, §7.5); whether creating a *new* block that overlaps an *existing* confirmed booking should be blocked outright or allowed with a required resolution step is listed as an open question in §16 — the approved decisions establish that blocks "prevent conflicting bookings" for the forward direction (block-then-book) but don't fully specify the reverse (book-then-block) case.
- **Management restricted to room managers/administrators** — same actor set as §4's room-manager concept, not ordinary users.

---

## 10. Meeting-Linkage Rules

- **`meeting.room_id`** (on CorLink's target `meetings` table, per `docs/03` §5) **remains nullable** — a meeting may exist with no room at all (virtual, external-location, or room-to-be-assigned-later), per the approved decision.
- **`meeting_room_bookings.meeting_id`** is nullable — a room may be booked (training prep, maintenance, interviews, administrative/blocked use) with no formal meeting record at all, per the approved decision.
- **No mandatory 1:1 requirement in either direction** — the relationship between `meetings` and `meeting_room_bookings` is a loose, optional link, not a required pairing.
- **A confirmed meeting-linked booking and a separate standalone booking for the same room/window must not both exist** — this is a direct consequence of §7's conflict design operating at the `meeting_room_bookings` table level regardless of whether a given row happens to carry a `meeting_id` — the exclusion constraint and trigger do not distinguish "linked" from "standalone" bookings, so this requirement is satisfied by construction, not by a separate rule.

---

## 11. Timezone Rules

- **Authoritative columns:** `start_at TIMESTAMPTZ NOT NULL`, `end_at TIMESTAMPTZ NOT NULL` — Postgres stores and compares these consistently regardless of session timezone, per the approved decision.
- **`timezone TEXT NOT NULL`** — the booking's IANA timezone (e.g. `Indian/Maldives`), preserving the *intended local scheduling context* even though the authoritative comparison always happens on the UTC-normalized `timestamptz` values. This mirrors `docs/03` §5's original design intent for `meetings` — this document confirms it applies identically to `meeting_room_bookings`.
- **V1 application default:** `Indian/Maldives`, used whenever the user has not selected a different supported timezone — not a hardcoded UTC offset, per the approved decision.
- **Validation:** `CHECK (end_at > start_at)` — a direct constraint, not merely an application-level check, consistent with CorLink's existing CHECK-constraint-heavy schema style (`supabase/schema.sql`, e.g. `role`/`status`/`record_type` CHECKs throughout).
- **All availability and conflict logic (§7) operates on `start_at`/`end_at` directly** — never on the `timezone` column, which is descriptive/display metadata only, not part of any comparison.
- **Organization-level default timezone configuration** is explicitly deferred (per the approved decision, "may be added later") — V1 uses the single hardcoded application default above for every organization.

---

## 12. Notification Events

Via CorLink's existing in-app bell (`notifications` table, `notifications-api.js`, `record_type`/`record_id` polymorphic pattern) — no Telegram, per the approved decision.

Required V1 events (each needs a new `notifications.type` CHECK value — that column is a closed enum in `supabase/schema.sql`, an implementation-time schema change, not a conceptual gap):

| Event | Likely recipient(s) |
|---|---|
| Booking request submitted | The room's manager(s) / org admins (someone needs to act on the new `pending` row) |
| Booking approved | The requester |
| Booking rejected | The requester |
| Booking cancelled | The other party (requester if a manager cancelled; manager(s) if the requester cancelled) |
| Booking changed by an authorized manager (time/room altered, or overridden) | The requester / affected participants |
| Conflicting request requiring manager attention | Room manager(s), where applicable — e.g. surfacing when a `pending` request's window has since been consumed by a conflicting `confirmed` booking, if that scenario is retained (see §16) |

---

## 13. Audit Requirements

Via CorLink's existing `audit_logs` table and `logAudit()` write path (insert restricted to `user_id = auth.uid()`, per `supabase/rls.sql`) — never MeetFlow's disabled-RLS `audit_logs` table or its blanket-access pattern (`docs/08` §D/§E), per the approved decision.

Required events (each needs a new `audit_logs.action` and/or `record_type` CHECK value — also a closed enum in `supabase/schema.sql`, same implementation-time note as §12):

- Booking created (`pending` or `confirmed`)
- Hold created
- Booking approved
- Booking rejected
- Booking cancelled
- Conflict overridden (must capture the override reason — either inline in `audit_logs.notes` or cross-referenced to the booking row's own override fields, §8)
- Room block created
- Room block cancelled
- Booking time or room changed

`record_type` values needed: `meeting_room_booking`, `meeting_room_block` (following the existing naming pattern already used for `external_correspondence`/`external_correspondence_reply` etc.).

---

## 14. Deferred Features (explicitly out of V1 scope)

Restated clearly per the validation instruction — none of the following ship in V1:

- **Recurring meetings and recurring room bookings** — no recurrence rules, series IDs, or recurring-generation logic in V1. A nullable forward-compatibility field (e.g. a future `recurrence_id`) is *not* added now either, per the approved decision's explicit "avoid speculative fields" instruction — there is no strongly-justified reason to add one yet, so none is added.
- **Telegram notifications** — CorLink's existing in-app bell only.
- **Booking attachments** — deferred; no attachment support on `meeting_room_bookings` in V1.
- **Room attachments** — deferred; no attachment support on `meeting_rooms` in V1.
- **A complex approval workflow engine** — V1 is a single approve/reject decision only (§5); no delegation, escalation, or multi-stage chains.
- **Organization-level approval-policy configuration** — the *slot* for this exists (`organization_modules.configuration`, §5), but the feature itself is not built in V1.
- **A continuously running hold-cleanup worker** — holds expire lazily/on-demand (§6); no scheduled job is required for V1 correctness (an optional future `pg_cron` sweep is noted as a possible tidiness addition only, not required).

---

## 15. Security Invariants

Restated explicitly, as required:

- **No blanket authenticated policies** — every RLS policy on every Rooms/Booking table is scoped (org, section/room, role, ownership) — never MeetFlow's `USING (true) WITH CHECK (true)` pattern (`docs/08` §E, `docs/02` §3/§5).
- **No anonymous access** — every policy requires an authenticated CorLink user; no table is reachable by the `anon` role.
- **Organization isolation is mandatory** — every top-level Rooms/Booking table carries `org_id`, and every policy roots through `get_my_org_id()`/`scope_org_id()`, matching every existing CorLink table.
- **Both module enablement and role permission are required** — Layer 1 (`is_module_active('rooms')` + `module_enabled_for_org()`) and Layer 2 (role/room-manager check, §4) must both pass; neither alone is sufficient, exactly as already implemented for every other module in Phase 1 (`docs/04`).
- **Conflict checks cannot be bypassed through direct API calls** — enforced at the database level (exclusion constraint + trigger, §7), not in application/frontend code, so no REST call — however constructed — can skip it.
- **Approval and override permissions are enforced server-side** — RLS and/or the enforcing trigger check the acting user's actual role/room-manager grant; the frontend UI gating on these actions is UX only, never the real gate (matching CorLink's existing "RLS/route guard is the real gate" convention, `docs/03` §7).
- **Users cannot approve their own pending booking** — even if they separately hold a room-manager or admin role for that room, an explicit `created_by <> auth.uid()` (or equivalent) condition is required on the approval-transition path (§4).
- **External organizations receive no Rooms access by default** — per `docs/03` §6's already-established Layer-1 default table, only MCS (and explicitly per-org-enabled exceptions) get non-`requests`/`prisoner_correspondence` modules; `rooms` is not in any external organization's default-enabled set.
- **Cancelled and rejected bookings remain available for authorized audit viewing** — no row is hard-deleted on cancellation or rejection; they remain queryable by whoever CorLink's existing audit-visibility rules (`can_view_case_audit_record()`-style scoping) already permit.
- **Hard deletion is not part of normal user workflows** — restricted to exceptional platform-level maintenance (matching the approved decision's own wording), never exposed through any normal booking/cancellation/rejection UI action.

---

## 16. Open Technical Questions Implementation Must Validate

These are gaps the approved decisions leave open — not conflicts, and not this document's place to silently resolve. Each should be confirmed before or during Phase 4 implementation (`docs/03` §8):

1. **"Completed" transition mechanism** — is `confirmed → completed` a real, stored transition (e.g. evaluated by a scheduled `pg_cron` job, mirroring `check_deadlines()`) or a value computed at query time and never actually written to `status`? Both satisfy "completed bookings don't block availability," but they have different implications for anything that queries `status` directly (e.g. a dashboard count of "completed bookings this month").
2. **Room-manager grant granularity** — is "allowed to use or request the selected room" an org-wide default (every module-enabled user may request every room in their org) or a per-room restriction (some rooms limited to specific sections/roles)? The approved decisions require the gate to exist; they don't specify its default breadth. Affects whether `meeting_room_managers` (§4) is the *only* new grant table needed, or whether a second table for room-*access* (distinct from room-*management*) is also needed.
3. **`btree_gist` extension availability** — not currently enabled on CorLink's Supabase project (only `pgcrypto` is, per `supabase/schema.sql:8`). Needs to be confirmed enableable (Supabase supports it generally, but this has not been verified against the live project this step, per this step's own "do not access Supabase" boundary) before §7's exclusion-constraint design can be implemented as specified.
4. **Reverse room-block conflict** — if a `meeting_room_block` is created *after* a `confirmed` booking already exists in that window, should block-creation be rejected outright (forcing the admin to resolve/cancel the booking first), or allowed with the conflicting booking(s) surfaced for manual resolution? §9 flags this; the approved decisions specify the forward direction (block-then-book is prevented) but not this reverse case.
5. **Notification recipient resolution for "conflicting request requiring manager attention"** — the approved decision lists this event conditionally ("where applicable"), implying it may not always apply. Needs a concrete trigger condition: does it fire whenever two `pending` requests are submitted for an overlapping window (both still awaiting a decision), or only in some other specific scenario? Not fully specified.
6. **Exact wording/values for the new `audit_logs.action`, `audit_logs.record_type`, and `notifications.type` CHECK-constraint entries** (§12/§13) — the concepts are fixed by this document; the literal string values are a schema-authoring detail for Phase 4, not decided here to avoid pre-committing to exact enum spelling before the actual migration SQL is drafted.
7. **Whether the override-reason and override-actor/timestamp fields live directly on `meeting_room_bookings` or are derived solely from the `audit_logs` entry** (§8) — both are queryable in principle; a directly-stored field is more convenient for UI display (e.g. showing "overridden by X, reason: Y" inline on the booking) without a join, but duplicates what the audit log also records. Recommend storing directly on the row for UI convenience, with the audit log remaining the authoritative historical record — but this is a minor schema-shape decision better made alongside the actual DDL in Phase 4.

---

## Validation (performed before committing this document)

- **Compared against `docs/03`:** every decision above is consistent with `docs/03`'s already-established target naming (`meeting_room_bookings`, `meeting_room_blocks`, `meeting_rooms`), RLS strategy (§7 of that document — deny-by-default, org-scoped, module-gated, no blanket policies), and Layer 1/Layer 2 module model (§6 of that document, already shipped per `docs/04`). No contradiction found; `docs/03` is updated (see below) to reflect that these previously-open items are now resolved.
- **Compared against `docs/08`:** every one of `docs/08` §H's 7 open product questions is answered by the approved decisions and reflected in this document — confirmed individually: (1) approval requirement → §2/§5 yes; (2) who may book → §4; (3) hold expiry → §6 yes, 10 minutes; (4) meetings without rooms → §10 yes; (5) rooms without meetings → §10 yes; (6) recurring bookings → §14 deferred; (7) cancellation rules → restated in §1/§3; conflict-override permissions (also raised in `docs/08` §H item 7's broader framing) → §8. **No item from `docs/08` §H remains accidentally unanswered.**
- **Deferred items labeled explicitly:** recurring bookings, Telegram, booking attachments, and room attachments are each explicitly called out in §14 as deferred, per the validation instruction.
- **No implementation files were changed** — only `docs/03-migration-architecture.md` (updated, see below) and this new document.
- **No Supabase call was made** — this entire step was conducted by reading local repository files only (`supabase/schema.sql`, `supabase/rls.sql`, `docs/03`, `docs/04`, `docs/08`); neither the CorLink nor MeetFlow project was accessed.

---

*End of document. No database tables were created. No RLS was written. No frontend code was changed. No Supabase project was accessed or modified. Nothing was deployed or pushed.*
