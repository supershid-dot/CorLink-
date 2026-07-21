# MeetFlow Booking Schema Analysis

**Type:** Read-only analysis (Step 9 of the MeetFlow → CorLink migration process) — **no SQL applied, no migration created, no application code edited, nothing deployed, nothing pushed**.
**Companion documents:** `docs/01-corlink-meetflow-audit.md` (static repo audit), `docs/02-live-supabase-inventory.md` (Step 4's live inventory — source of the live facts cited below).
**Date:** 2026-07-21
**Target:** MeetFlow Supabase project `xvwileiyquqxxtzqxghm` (not accessed live this step — see §0).

---

## 0. Method note — this analysis is static-only

This step was scoped to include a fresh live-database inspection (`execute_sql`/`list_tables` against `xvwileiyquqxxtzqxghm` — column/constraint/index/trigger/RLS/policy detail and row counts for 10 named tables). The Supabase MCP connector was unavailable for the entire duration of this step (`enabledInChat: false` on every check, despite the org-level connection showing `connected: true`), so **no new live queries were run**.

Two things partially close that gap:

1. **Static code analysis is complete and exhaustive** — the entire tracked schema (`schema_v2.sql`, 342 lines), the entire frontend (`index.html`, 3442 lines, every REST call site enumerated), and the `meetflow-login` Edge Function source were read in full.
2. **`docs/02-live-supabase-inventory.md`**, produced in Step 4 of this same process, already ran a live pass against this exact project and captured facts directly relevant to this step: `bookings`/`pre_bookings` exist live, are untracked in the repo, are at or near 0 rows, carry the same blanket `auth_all` policy as the other 15 tables, and — critically — it already confirmed that `audit_logs` has **RLS fully disabled** live, resolving a drift hypothesis this step would otherwise have needed to re-check.

What remains genuinely unverified and is called out explicitly wherever it matters: the full column list, types, defaults, nullability, PKs, FKs, unique/check constraints, indexes, and triggers specifically for `bookings` and `pre_bookings` (Step 4 captured their existence, row counts, and RLS/policy state, but not their full DDL), and any functions/RPCs that might reference them beyond `rls_auto_enable()` (already known to be unrelated — see docs/02 §3).

---

## A. Executive Summary

- **`bookings` and `pre_bookings` are live-only, untracked tables** — they do not appear anywhere in `schema_v2.sql`, and no `CREATE TABLE` or `ALTER TABLE` statement for either exists in the repository. This was first flagged as drift in `docs/02` (Step 4) and is reconfirmed here by a second, independent method (static code reading) reaching the same conclusion from a different angle.
- **Neither table is referenced anywhere in the live MeetFlow frontend.** An exhaustive `grep` of every `GET`/`POST`/`PATCH`/`PUT`/`DEL` REST call in `index.html` (72 call sites across 15 distinct table names) found **zero** references to `bookings` or `pre_bookings`. The application's actual "pre-booking" feature is implemented entirely inside the `meetings` table via a boolean `is_prebooked` flag (`schema_v2.sql:75`, `openPreBookingModal()`/`savePreBooking()` at `index.html:2285-2328`).
- **They contain no live data**: per `docs/02` §3, both tables are "at or near 0 rows" (MeetFlow's live data is effectively empty across all 17 tables except `audit_logs`, which has 1 row).
- **Conclusion: these tables are legacy/abandoned and are not required for migration.** The strong, converging evidence — absent from tracked schema, zero application references, zero live data — indicates they predate the current `meetings.is_prebooked` design and were never cleaned up. They should be **excluded** from the CorLink target schema entirely; nothing needs to be migrated from them (see §G).
- The real, actively-used booking/scheduling model lives entirely inside `meetings` (+ `rooms`, `room_blocks`), not in any dedicated booking table. Section F's CorLink design recommendation is built around that reality, not around porting `bookings`/`pre_bookings`.

---

## B. Full Schema Inventory

### B.1 — Tables with full static (tracked) definitions

The following are defined in `schema_v2.sql` and were read in full. Live confirmation of exact current state (beyond what `docs/02` already captured — RLS state, policy shape, row counts, table/column/function existence) was not re-run this step.

| Table | PK | Key columns | FKs | RLS (tracked intent) | RLS (live, per docs/02) |
|---|---|---|---|---|---|
| `rooms` | `id` serial | `name`, `capacity`, `end_hour` | — | enabled, blanket `auth_all` (Step 2) | enabled, blanket `auth_all` |
| `meetings` | `id` serial | `title`, `type`, `meeting_mode`, `date`, `start_slot`, `duration`, `room_id`, `section_id`, `created_by`, `is_prebooked`, `recurrence_id`, `recurrence_rule`, `is_cancelled`, `is_locked`, `minutes`, **`attachments`** (live-only column, not in tracked schema) | `room_id→rooms`, `section_id→sections`, `created_by→staff` | enabled, blanket `auth_all` | enabled, blanket `auth_all`; `attachments` column confirmed live |
| `participants` (task calls this `meeting_participants`; actual live/tracked name is `participants`) | `id` serial | `meeting_id`, `staff_id`, `rsvp`, `attendance`, `attendance_marked_by/at` | `meeting_id→meetings ON DELETE CASCADE`, `staff_id→staff` | enabled, blanket `auth_all` | enabled, blanket `auth_all` |
| `meeting_groups` | `id` serial | `name`, `description`, `created_by` | `created_by→staff` | enabled, blanket `auth_all` | enabled, blanket `auth_all` |
| `meeting_group_access` | composite `(group_id, staff_id)` | — | `group_id→meeting_groups ON DELETE CASCADE`, `staff_id→staff ON DELETE CASCADE` | **created with RLS disabled**, but included in Step 2's enable list | enabled, blanket `auth_all` (Step 2 evidently ran) |
| `notifications` | `id` serial | `meeting_id`, `participant_id`, `type`, `status`, `scheduled_for`, `sent_at`, `recipient_chat_id`, `telegram_message_id` | `meeting_id→meetings ON DELETE CASCADE`, `participant_id→participants ON DELETE CASCADE` | enabled, blanket `auth_all` | enabled, blanket `auth_all` |
| `audit_logs` | `id` serial | `actor_id`, `action`, `target_type/id/name`, `details` | `actor_id→staff` | **created with RLS disabled**; Step 2's enable list explicitly includes `audit_logs` | **RLS fully disabled** (per docs/02 §3/§5) — **confirmed drift**, see §D |
| `app_config` | `key` text PK | `value`, `updated_at` | — | **created with RLS disabled**, included in Step 2's enable list | enabled, blanket `auth_all` |

### B.2 — Tables that are live-only / untracked

| Table | Status |
|---|---|
| `bookings` | **Live-only.** No `CREATE TABLE bookings` anywhere in `schema_v2.sql` or any other tracked SQL file. Confirmed present live via `docs/02` (Step 4), carrying RLS "enabled" with the same blanket `auth_all FOR ALL USING (true) WITH CHECK (true)` policy as the other 15 non-disabled tables. Row count: 0 or near-0 (docs/02 §3). **Full column/constraint/index/trigger detail was not captured by docs/02 and could not be re-queried this step** — genuinely unknown without live access. |
| `pre_bookings` | Same status as `bookings` in every respect: live-only, untracked, blanket-policy RLS, 0/near-0 rows, full DDL unknown. |

### B.3 — Naming clarification

The task instruction refers to `meeting_participants`; the actual table (both tracked and live, per `docs/02`) is named `participants`. Treated as the same table throughout this document.

---

## C. Application Workflow (actual booking lifecycle, from code + tracked schema)

MeetFlow's real scheduling model, reconstructed from `index.html` and `schema_v2.sql`:

1. **Room availability** is computed entirely client-side: the frontend fetches `meetings` filtered by `room_id`/`date` (`GET('meetings...)` call sites at `index.html:908,1145,1173,1220`) and renders a half-hour slot grid (`start_slot` 0 = 08:00, one unit = 30 minutes, per `schema_v2.sql:57-58`) up to each room's `end_hour`.
2. **Booking creation** = `POST('meetings', ...)` (e.g. `index.html:1549,1570,2356`). There is no separate reservation/hold step — a meeting row *is* the booking. `room_id` may be null (`no_room` flag) for internal meetings without a room.
3. **Pre-booking** (the closest thing to a "temporary hold"): `openPreBookingModal()`/`savePreBooking()` (`index.html:2285-2328`) creates one or more `meetings` rows with `is_prebooked = true` and minimal fields (room, date, slot, section) — described in-app as "placeholder bookings" that section staff later open to "Complete Details." This is **not** a separate table or a time-boxed hold; it is a `meetings` row missing its full details, with no expiration — it persists until someone fills it in or deletes it.
4. **Conflict detection**: `slotsOverlap(aStart, aDur, bStart, bDur)` (`index.html:699-700`), called before create/edit (call sites `index.html:1452-1454, 1541-1545, 1953-1954`) to warn/block on room double-booking. **Entirely client-side JavaScript** — see §D/§E for the enforcement-gap implications.
5. **Recurring meetings**: client-generated. A `recurrence_id = Date.now().toString(36)` string tags N independently-`POST`ed `meetings` rows created in a client-side date-stepping loop (weekly/biweekly/monthly, `index.html:1559-1570,1983-2002,3065+`). No server-side RRULE engine or generation function.
6. **Cancellation**: soft-delete via `is_cancelled`/`cancelled_at`/`cancelled_reason` on `meetings` (`schema_v2.sql:171-173`). Rows are never hard-deleted. Cancelled meetings are excluded from calendar/room-slot queries — by client-side filtering, not a server-side view or RLS predicate.
7. **Approval**: there is no approval step for bookings/meetings anywhere in the tracked schema or frontend. The only approval-style workflow in MeetFlow at all is `staff_requests.status` (`pending`/`approved`/`rejected`), which governs **staff account creation and password-reset requests only** — unrelated to room/meeting booking. Booking is immediate upon `POST`.
8. **Meeting ↔ room linkage**: direct FK, `meetings.room_id → rooms.id`, nullable (internal meetings can have no room via `no_room`).
9. **Timezone**: no timezone-aware column anywhere — `date` is a plain `date`, `start_slot`/`duration` are integer slot counts. All scheduling is implicitly in whatever single timezone the deployment/organization operates in; there is no per-user or per-org timezone concept.
10. **Attachments**: stored as a JSON-stringified array directly in `meetings.attachments` (a `text` column, parsed/re-serialized client-side, `index.html:3171-3200`) — Supabase Storage is not used at all (0 buckets, per `docs/02`).

---

## D. Schema Drift (live vs. tracked vs. frontend expectations)

| Item | Tracked (`schema_v2.sql`) | Live (per `docs/02`) | Frontend expectation | Drift |
|---|---|---|---|---|
| `bookings` table | Absent | Present, 0/near-0 rows, blanket-RLS | **Never referenced** — zero REST calls to this table anywhere in `index.html` | Untracked, unused legacy table |
| `pre_bookings` table | Absent | Present, 0/near-0 rows, blanket-RLS | **Never referenced** — zero REST calls anywhere; the app's actual "pre-booking" feature writes to `meetings` | Untracked, unused legacy table; name is misleading — suggests it *should* back the pre-booking feature but does not |
| `meetings.attachments` | Absent from `CREATE TABLE meetings` and from every `ALTER TABLE meetings ADD COLUMN` in the file | Present (`text`), confirmed live | Actively read/written (`saveAttachment`/`removeAttachment`, `index.html:3171-3200`) | Live column, actively used, genuinely missing from tracked schema — a real gap, unlike `bookings`/`pre_bookings` |
| `audit_logs` RLS state | Created with RLS disabled (`schema_v2.sql:281`), then **explicitly included** in Step 2's `ENABLE ROW LEVEL SECURITY` list (`schema_v2.sql:316`) and its blanket-policy loop array (`schema_v2.sql:326`) | **RLS fully disabled** (confirmed by `docs/02` §3/§5, listed alongside `staff_requests` as the only 2 of 17 tables with RLS off) | N/A (server-side concern, not frontend-visible) | **Confirmed drift.** Tracked SQL's Step 2 intends `audit_logs` to end up RLS-enabled with the blanket policy, same as 15 other tables. Live reality shows it disabled — meaning either Step 2 was run from an earlier revision of this file that didn't yet include `audit_logs` in its lists, or a subsequent change disabled it again. Net effect: **`audit_logs` is currently readable/writable by anyone holding the anon key, with no policy gate at all** — already flagged as a Critical security finding in `docs/02` §5, reconfirmed here as a genuine tracked-vs-live divergence, not merely "RLS disabled by original design" (that description applies correctly only to `staff_requests`, which is never in Step 2's lists at all). |
| `rls_auto_enable()` function | Absent | Present, `SECURITY DEFINER`, live-only (per `docs/02`) | N/A | Restated from `docs/02` for completeness — its name and the `audit_logs` drift above are plausibly related (a function whose purpose appears to be re-enabling RLS, sitting alongside a table whose RLS is currently off despite tracked SQL saying it should be on), but no causal link can be confirmed without invoking it, which is out of scope for a read-only step. |

No drift was found for `rooms`, `participants`, `meeting_groups`, `meeting_group_access`, `notifications`, or `app_config` — tracked definitions, live state (per `docs/02`), and frontend usage are consistent for all of these.

---

## E. Security Findings — `bookings` / `pre_bookings` specifically

- **Access model**: per `docs/02` §3, both tables carry the same blanket `auth_all FOR ALL TO authenticated USING (true) WITH CHECK (true)` policy as 13 of the other 15 non-RLS-disabled tables. In practice this means **any holder of a valid MeetFlow-issued JWT (i.e., any active staff member, admin or not) can read, insert, update, or delete every row in both tables** — there is no per-row ownership, section-scoping, or role check of any kind, identical to the rest of MeetFlow's "secured" end-state.
- **Ordinary users vs. other users' data**: since there is no owner/section column being enforced by policy (and, per the naming and lack of any application code touching these tables, no clear semantic owner column can even be identified without live DDL), the question "can ordinary users access other users' bookings" is moot in the current state — everyone can access everything in these two tables, the same way they can in `meetings`, `rooms`, `notifications`, etc.
- **MeetFlow's insecure custom JWT model**: yes, both tables sit behind the same `staff_role`-blind, blanket-policy authorization model described in `docs/02` — `staff_role` is minted into every JWT but never referenced by any RLS policy anywhere in the tracked schema, including (presumably) whatever policy governs these two tables live.
- **Service-role Edge Function involvement**: none. `meetflow-login` (the only Edge Function whose source was read) never touches `bookings` or `pre_bookings` — it only reads `staff` and inserts into `staff_requests`. The two duplicate login functions found live (`smooth-service`, `clever-service`, per `docs/02`) are functionally identical to `meetflow-login` and likewise have no relationship to booking tables.
- **Explicit compliance with the task's instruction**: no element of MeetFlow's `bookings`/`pre_bookings` access model (blanket `USING (true)` policies, JWT claims that are minted but never checked, RLS nominally "on" with zero real isolation) is proposed for reuse anywhere in §F below. The CorLink recommendation is built from CorLink's own existing per-row RLS conventions (org/section/role-scoped `SECURITY DEFINER` helper functions, as already used throughout `rls.sql` for Requests/Entry), not from anything observed in MeetFlow.

---

## F. CorLink Target Recommendations

**Recommended design: a single `bookings`-equivalent table with status, not a separate pre-bookings/bookings pair.**

Rationale: MeetFlow's own actively-used implementation already proves this pattern works in practice — the "pre-booking" concept is not a separate table with its own lifecycle, it's a status/flag on the same row that becomes a full meeting once completed. Porting that same shape (one table, a status column) rather than reintroducing a two-table split avoids resurrecting the exact abandoned pattern (`bookings`/`pre_bookings`) that this analysis just confirmed is dead weight in the source system. A two-table split would also duplicate most columns (room, date, time, section, creator) across both tables and require synchronization logic on "complete details" that a single status transition avoids entirely.

Proposed shape (naming illustrative, to be finalized in the actual migration-design step — this step is analysis only):

- **`room_bookings`** (or fold into a broader `meetings` if CorLink's Meetings module and Rooms module end up sharing one underlying table — an architecture decision for a later step, not this one):
  - `id UUID PRIMARY KEY DEFAULT gen_random_uuid()` — matches CorLink's existing UUID-everywhere convention (per `docs/02` §6, a confirmed mismatch to resolve during migration).
  - `room_id UUID REFERENCES rooms(id)`, nullable if CorLink's Meetings module allows room-less meetings (mirrors MeetFlow's `no_room` flag).
  - `start_at TIMESTAMPTZ NOT NULL`, `end_at TIMESTAMPTZ NOT NULL` — **timezone-aware**, replacing MeetFlow's timezone-naive `date` + integer `start_slot`/`duration`. This is a deliberate improvement, not a straight port: MeetFlow's slot-integer model has no timezone concept at all (§C.9), which is a real limitation worth fixing rather than carrying forward.
  - `status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('placeholder','confirmed','cancelled'))` — `'placeholder'` maps to MeetFlow's `is_prebooked = true` (incomplete details, awaiting completion); `'confirmed'` is a normal booking; `'cancelled'` replaces `is_cancelled` boolean + `cancelled_at`/`cancelled_reason` columns (kept as separate columns alongside `status`, same as MeetFlow, since they carry additional detail a status enum alone can't).
  - `org_id UUID NOT NULL REFERENCES organizations(id)`, `section_id UUID REFERENCES sections(id)` — CorLink-native scoping columns with no MeetFlow equivalent (MeetFlow has no organizations concept at all), required for RLS.
  - `meeting_id UUID REFERENCES meetings(id)` — if Rooms/Bookings and Meetings end up as separate CorLink modules/tables rather than one merged table, this FK is the linkage point (mirrors MeetFlow's `meetings.room_id`, just inverted in direction to fit a dedicated bookings table).
  - `created_by UUID NOT NULL REFERENCES users(id)`, `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.
  - `recurrence_id UUID`, `recurrence_rule TEXT` — direct port of MeetFlow's client-generated recurrence tagging; whether to upgrade this to a real server-side RRULE engine is a product decision, not addressed here (see §H).
  - Conflict prevention: unlike MeetFlow (zero DB-level enforcement, §C.4/§E), CorLink should enforce this at the database level — e.g. a `btree_gist` **exclusion constraint** on `(room_id, tsrange(start_at, end_at)) WHERE status <> 'cancelled'`, or at minimum a `BEFORE INSERT/UPDATE` trigger performing the overlap check server-side. This directly closes the single biggest reliability gap found in MeetFlow's live design.
  - Approval: MeetFlow has none for bookings (§C.7) — whether CorLink's version should add one is a genuine open product decision, not something this analysis can resolve from evidence (see §H).

- **RLS**: follow CorLink's existing convention exactly (org-scoped `SECURITY DEFINER` helpers, section-scoped policies for staff, admin-scoped write policies) — the same pattern already used for `requests`/`external_correspondence` per `docs/02` §2. Explicitly **not** a blanket `USING (true)` policy of any kind, per §E's instruction.
- **Audit fields**: `created_at`/`created_by` on the table itself, plus normal coverage via CorLink's existing `audit_logs` table/trigger pattern (already used for Requests/Entry) — not a bespoke audit mechanism.

---

## G. Data Migration Implications

- **Fields migrating directly**: none from `bookings`/`pre_bookings` — per §A, both are empty (0/near-0 rows) and unreferenced by the application. **No live booking data actually needs migration from these two tables.** This is the single most consequential finding for migration planning: the two tables named most suggestively for this migration turn out to require zero data-migration effort.
- **The real migration source is `meetings`** (+ `rooms`, `room_blocks`, `participants`): if MeetFlow's live `meetings` table has real rows (row counts for `meetings` specifically were not itemized in `docs/02`'s summary beyond "all 17 tables are at or near 0 rows except audit_logs" — implying `meetings` is also effectively empty, but this should be re-confirmed with a live row count before finalizing migration scope, since it directly affects the answer to "is there any real MeetFlow booking data to migrate at all").
- **Integer-ID-to-UUID mapping**: every MeetFlow table uses `serial`/bigint identity PKs (`schema_v2.sql`, confirmed throughout); CorLink is UUID-everywhere. A migration would need an ID-mapping table (old integer ID → new UUID) for `meetings`, `rooms`, `participants`, etc., maintained at least through the migration window so FK references can be rewritten consistently.
- **Invalid/duplicate records**: `docs/02` already found 1 duplicate normalized email across MeetFlow's 13 `staff` rows — relevant to any migration of `meetings.created_by`/`participants.staff_id` references if staff identity mapping relies on email matching.
- **Orphaned rows**: not assessable without live data (e.g., `meetings.room_id` pointing at a deleted room would need a live query to detect — FKs would prevent this going forward, but historical data quality wasn't checked this step).
- **Timezone conversion risk**: real and non-trivial. MeetFlow's `date` + integer `start_slot` has no timezone anchor at all; converting to CorLink's proposed `TIMESTAMPTZ` requires an explicit decision about which timezone MeetFlow's slots were implicitly recorded in (almost certainly the deployment's local time, per §C.9) before any conversion arithmetic can be trusted.
- **Rows needing manual review**: any `meetings` row with `is_prebooked = true` and incomplete details (the "placeholder" rows described in §C.3) would need a manual decision — migrate as a `'placeholder'`-status booking, or drop, depending on whether the placeholder was ever completed.
- **`bookings`/`pre_bookings` specifically**: recommend **exclude entirely** from migration scope. They should not be ported to CorLink in any form — not as data, not as schema. This should be flagged to the project owner as legacy cleanup candidates in MeetFlow itself, independent of the migration (mirroring how `docs/02` flagged the undocumented Edge Functions and `rls_auto_enable()` — noted, not silently carried forward, decommissioning decision left to the owner).

---

## H. Open Product Decisions

Genuine decisions requiring the project owner's input — not resolved by evidence gathered in this step:

1. **Should room/meeting bookings require approval before being confirmed?** MeetFlow has no approval step today (§C.7); CorLink's other modules (Requests, Entry) are approval-centric. Whether Meetings/Rooms should follow that same pattern or stay approval-free like MeetFlow is a product choice, not a technical one.
2. **Who may reserve rooms?** MeetFlow: any active staff member, unrestricted (§E). CorLink could scope this by role, section, or leave it org-wide — no evidence in either codebase compels one answer.
3. **Should placeholder/pre-booked entries expire if never completed?** MeetFlow's placeholders (`is_prebooked = true`) never expire today (§C.3) — worth deciding whether CorLink's equivalent should auto-expire or auto-cancel after some period.
4. **Can meetings exist without a room, and can rooms be booked without a meeting?** MeetFlow supports meetings without rooms (`no_room` flag) but has no concept of a room reservation that isn't a meeting. Whether CorLink's Rooms module should support pure room-holds independent of a Meetings-module meeting record is an architecture decision affecting whether "Rooms" and "Meetings" end up as one shared table or two linked ones (see §F).
5. **Should recurring bookings be part of the initial migration scope, or deferred?** MeetFlow's recurring-meeting support is a thin client-side convenience (§C.5) with no server-side guarantees; building a proper recurrence model is materially more work than porting the rest of this design.
6. **Cancellation rules**: who may cancel a booking — creator only, any section member, supervisor override? MeetFlow's `is_locked` flag (creator-only edit/cancel lock, admin-overridable) is a candidate pattern to carry forward, but this is a policy decision, not something derivable from usage evidence (there is effectively no live usage to observe, per §A).
7. **Conflict override permissions**: given §F recommends server-level conflict enforcement (a real change from MeetFlow's client-only, bypassable check), should any role be permitted to override/double-book intentionally (e.g., an admin force-booking over an existing hold)? MeetFlow's client-side check is only ever a warning today, never a hard block — deciding whether CorLink's server-level version should have an override path at all is a new question this migration introduces, not one MeetFlow's current behavior answers.

---

## Confirmation (Part 7 checklist)

- **Every query this step performed was read-only**: true, and more specifically — **no live query was executed against MeetFlow at all this step** (connector unavailable throughout); all MeetFlow-specific facts either came from static file reads (`schema_v2.sql`, `index.html`, `meetflow-login/index.ts`) or were cited from `docs/02`, itself produced by a strictly read-only pass in an earlier step of this same process.
- **No Edge Function was invoked** — none were called this step; `meetflow-login`'s source was read as a file, not executed.
- **No Supabase object was changed** — no write-capable tool was called against either project this step.
- **No personal/meeting content was copied into this document** — only schema/column/policy/function names, aggregate row-count characterizations ("0 or near-0"), and code-structure facts (line numbers, function names) appear above; no staff names, emails, meeting titles, or attachment contents were read or referenced.
- **CorLink production (`infjjroktzzhaxjvfknr`) was not accessed or modified this step.**
- **MeetFlow (`xvwileiyquqxxtzqxghm`) was not accessed live this step** — see §0 for why, and for exactly which conclusions rest on this step's own static analysis vs. Step 4's prior live pass.

---

## Summary for the Requesting Step

- **Purpose of `bookings`**: unknown/unconfirmed by design intent (no tracked schema, no code reference) — functionally, an abandoned legacy table with no current role in the application.
- **Purpose of `pre_bookings`**: same as `bookings`. The application's actual pre-booking feature lives entirely in `meetings.is_prebooked`, not in this table.
- **Do either contain live data?** No — both are at or near 0 rows (per `docs/02`, Step 4's live inventory).
- **Critical schema drift found**: (1) `bookings`/`pre_bookings` themselves (live-only, untracked, unused); (2) `meetings.attachments` (live-only, untracked, but *actively used* — the one genuine "missing from tracked schema" gap with real consequences); (3) `audit_logs` RLS state — tracked SQL's Step 2 intends it enabled with a blanket policy, live reality has it fully disabled, reconfirming/clarifying a Critical finding already raised in `docs/02`.
- **Conflict-checking method**: 100% client-side JavaScript (`slotsOverlap()`), zero database-level enforcement (no unique/exclusion constraints, no triggers) — trivially bypassable via direct REST calls.
- **Security findings**: `bookings`/`pre_bookings` share MeetFlow's blanket `auth_all USING(true)` policy pattern — no per-row isolation of any kind. Nothing from this pattern is recommended for CorLink (see §E).
- **Recommended CorLink design**: a single status-driven `room_bookings`-style table (not a separate pre-bookings/bookings pair), timezone-aware `start_at`/`end_at`, server-level conflict prevention (exclusion constraint or trigger — the one deliberate design improvement over MeetFlow), and CorLink-native org/section-scoped RLS. Full detail in §F.
- **Migration-data implications**: no data needs migrating from `bookings`/`pre_bookings` (both empty). The real migration source, if any, is `meetings`/`rooms`/`participants` — recommend re-confirming `meetings`' exact live row count before finalizing migration scope, since `docs/02`'s summary implies but doesn't itemize it as empty.
- **Decisions requiring owner approval**: 7 open product questions listed in §H (approval requirement, who may book, placeholder expiry, room-less/meeting-less bookings, recurring-booking scope, cancellation rules, conflict-override permissions).
- **Document path**: `docs/08-meetflow-booking-schema-analysis.md` (this file).
- **Commit**: to follow immediately after this document is written (message: `docs: analyze MeetFlow booking schema`) — not amending any Phase 1 commit, not pushed.
- **Both Supabase projects unchanged**: confirmed — this step made no live calls to either project at all.

**Stop after this step**, per the requesting instruction.
