# Recurring Meetings Phase 2 — Final Architecture and Implementation Record

**Type:** Implementation record, written after Phase 2 shipped and was approved, mirroring `docs/25-recurring-meetings-phase1-design-decisions.md`'s role for Phase 1. This document is the canonical reference for Phase 2's RPC surface, architecture, and validation status; it does not restate Phase 1 material already covered by `docs/25`.
**Date:** 2026-07-24
**Status:** Recurring Meetings Phase 2 backend (§1–§15) is **implemented, validated, and pushed**. The frontend UI for it (§16) and one follow-up backend fix (§14 item 9, §17) were built after this document's original sections were written and are recorded here as later additions to the same document, rather than a new one. All patches listed in §14 are committed and pushed to `feature/corlink-platform-migration`. **None of this — backend or frontend — has yet been applied to the production Supabase project** (`infjjroktzzhaxjvfknr`); every validation claim in this document, including §15's and the closing "Validation" section's, was run against a disposable local PostgreSQL database or a Node.js sandbox, never against production. This document is documentation-only — it changes no SQL, RPC, schema object, or application code.
**Companion documents:** `docs/25-recurring-meetings-phase1-design-decisions.md` (Phase 1 architecture, series/occurrence foundation), `docs/22-rooms-meetings-meetflow-parity-roadmap.md` §3.3/§5 Q3, `docs/23-rooms-meetings-implementation-specification.md` §Phase F.

---

## 1. Scope and completion status

Recurring Meetings Phase 2 is implemented and approved. It adds the series-wide and future-occurrence operations Phase 1 deliberately deferred (`docs/25` §1), built entirely on Phase 1's existing `meeting_series`/`meetings.series_id`/`meetings.series_occurrence_date`/`meetings.series_detached`/`meeting_series_exceptions` schema — no further schema addition beyond what Phase 1 already reserved, aside from the CHECK-constraint value additions listed in §10.

Production capabilities shipped:

- **Update entire series** — edit template fields and time-of-day across every eligible occurrence of a series in one call.
- **Update this and future** — edit an occurrence and every later occurrence of the same series, splitting off a new series to hold them.
- **Cancel entire series** — cancel every eligible occurrence of a series and mark the series `cancelled`.
- **Cancel this and future** — cancel an occurrence and every later occurrence, splitting off a new series that is marked `cancelled`.
- **Preserve series membership during bulk updates** — bulk RPCs no longer falsely detach every occurrence they touch, so a series can be bulk-edited repeatedly without accumulating false detachments.
- **Series authorization** — one centralized `can_manage_series()` helper, reused by every series-level RPC.
- **Series exceptions** — `create_series_exception()` records a skipped or modified occurrence against a series.
- **Notification suppression and consolidation** — per-occurrence notifications are suppressed during bulk operations in favor of one consolidated notification per operation.

## 2. Final RPC inventory

### `update_entire_series(p_series_id, p_title, p_description, p_meeting_type, p_visibility, p_start_time, p_end_time, p_timezone, p_location_mode, p_external_location, p_virtual_link) RETURNS TABLE(meeting_id, occurrence_date, outcome)`

- **Purpose:** edit template fields and/or time-of-day across every eligible occurrence of a series.
- **Authorization:** `auth.uid()` required; `can_manage_series(p_series_id)` — series creator, an org supervisor-or-above in the series' own organization, or a super admin.
- **Module activation:** `meetings_module_active_for(v_series.organization_id)` must be true.
- **Lifecycle exclusions:** an occurrence is skipped (not updated, not erroring) if it is `skipped_cancelled` (`status = 'cancelled'`), `skipped_detached` (`series_detached = TRUE`), `skipped_completed` (`end_at < now()`), or `skipped_locked` (`is_locked` and not overridable by the caller) — checked in that exact order.
- **First-occurrence delegation:** none — this RPC is itself the "entire series" target every this-and-future RPC delegates to.
- **Notification behavior:** one consolidated `meeting_series_updated` notification, one row per distinct affected participant (excluding the actor), sent only if at least one occurrence was updated and the edit was meaningful (title, time-of-day, or location — not description/meeting_type/visibility alone).
- **Audit behavior:** exactly one `audit_logs` row per call (`action='meeting_series_updated'`, `record_type='meeting_series'`), written unconditionally, with a `notes` summary of affected/skipped counts by category. Per-occurrence `edited` audit rows from `update_meeting()` remain intact alongside it.
- **Series-status effects:** none — this RPC never changes `meeting_series.status`, and rejects up front if the series is already `cancelled` ("This series has been cancelled").
- **Rollback behavior:** a genuine runtime failure on any occurrence (most commonly a room-booking conflict surfaced by `reschedule_booking()`'s conflict guard) aborts and rolls back the entire call, including every occurrence already processed in the same transaction.

### `update_series_this_and_future(p_meeting_id, p_title, p_description, p_meeting_type, p_visibility, p_start_time, p_end_time, p_timezone, p_location_mode, p_external_location, p_virtual_link) RETURNS TABLE(meeting_id, occurrence_date, outcome)`

- **Purpose:** edit one occurrence and every later occurrence of its series, splitting the later occurrences onto a new series.
- **Authorization:** same as `update_entire_series()`, checked against the occurrence's own series.
- **Module activation:** same as `update_entire_series()`.
- **Lifecycle exclusions:** identical four categories, applied during pass 1 (see §4) to occurrences on or after the split date.
- **First-occurrence delegation:** if `p_meeting_id` is the series' earliest occurrence, this RPC delegates entirely to `update_entire_series()` and returns its result — no split series is created.
- **Notification behavior:** one consolidated `meeting_series_split` notification per distinct affected participant, same meaningful-change gating as `update_entire_series()`, addressed to the new split series.
- **Audit behavior:** exactly one `audit_logs` row (`action='meeting_series_split'`, `record_type='meeting_series'`, `record_id`=new series id), `notes` additionally recording `source_series` and `split_date`.
- **Series-status effects:** the original series' `series_end_date` is shrunk to `split_date - 1` and it remains `active`. The new split series is created `active`. If zero occurrences turn out eligible after classification, the tentative split series is discarded (`DELETE`) and the call returns with no rows changed.
- **Rollback behavior:** a runtime failure during pass 2's edits rolls back the entire transaction — including the new series `INSERT`, all of pass 1's repointing, and everything already processed — leaving no partial split behind.

### `cancel_entire_series(p_series_id, p_cancellation_reason) RETURNS TABLE(meeting_id, occurrence_date, outcome)`

- **Purpose:** cancel every eligible occurrence of a series and mark the series `cancelled`.
- **Authorization / module activation:** identical to `update_entire_series()`.
- **Lifecycle exclusions:** identical four categories and order.
- **First-occurrence delegation:** none — this is the "entire series" cancellation target.
- **Notification behavior:** one consolidated `meeting_series_cancelled` notification per distinct affected participant, sent only if at least one occurrence was cancelled (cancellation has no "meaningful change" gate — every cancellation is meaningful).
- **Audit behavior:** exactly one `audit_logs` row (`action='meeting_series_cancelled'`), written unconditionally — including when affected = 0. Per-occurrence `cancelled` audit rows from `cancel_meeting()` remain intact alongside it.
- **Series-status effects:** `meeting_series.status` is set to `'cancelled'` unconditionally, even when zero occurrences were eligible for cancellation. A series already `'cancelled'` is rejected up front ("This series has already been cancelled"), before the authorization check.
- **Rollback behavior:** same as `update_entire_series()` — a runtime failure (e.g. a missing required cancellation reason surfaced by `cancel_meeting()`) rolls back the whole call.

### `cancel_series_this_and_future(p_meeting_id, p_cancellation_reason) RETURNS TABLE(meeting_id, occurrence_date, outcome)`

- **Purpose:** cancel one occurrence and every later occurrence of its series, splitting the later occurrences onto a new series that is itself cancelled.
- **Authorization / module activation:** identical to `update_series_this_and_future()`.
- **Lifecycle exclusions:** identical four categories, applied during pass 1 to occurrences on or after the split date.
- **First-occurrence delegation:** if `p_meeting_id` is the series' earliest occurrence, this RPC delegates entirely to `cancel_entire_series()`.
- **Notification behavior:** one consolidated `meeting_series_cancelled` notification per distinct affected participant, gated on affected > 0, addressed to the new split series.
- **Audit behavior:** exactly one `audit_logs` row (`action='meeting_series_cancelled'`, `record_id`=new series id), `notes` recording `source_series` and `split_date`, written unconditionally — including when affected = 0.
- **Series-status effects:** the original series' `series_end_date` is shrunk and it remains `active`. The new split series is **always** created and **always** marked `cancelled`, even when zero occurrences turn out eligible — a deliberate divergence from `update_series_this_and_future()`'s tentative-series-discard behavior (see §7/§9): here the status transition to `cancelled` is the operation's primary effect, not a byproduct of touching at least one occurrence, so there is nothing to discard.
- **Rollback behavior:** a runtime failure during pass 2 (most commonly a missing cancellation reason for a non-creator actor) rolls back the entire transaction — the new series `INSERT`, all of pass 1's repointing, and every cancellation already processed in the same call — leaving no partial split behind.

### `update_meeting()` interaction with `p_preserve_series_membership`

`update_meeting()` gained one trailing parameter, `p_preserve_series_membership BOOLEAN DEFAULT FALSE`. See §3.

## 3. Preserve-series-membership behavior

- `p_preserve_series_membership` defaults to `FALSE`.
- Omitted or `FALSE` preserves the legacy behavior established in Phase 1: any edit to a series-linked occurrence sets `series_detached = TRUE`.
- `TRUE` suppresses only the `FALSE → TRUE` transition of `series_detached` — it never reattaches an occurrence that is already `TRUE`. The exact formula: `series_detached = CASE WHEN series_id IS NOT NULL AND NOT p_preserve_series_membership THEN TRUE ELSE series_detached END`.
- All four bulk RPCs' internal calls to `update_meeting()` pass `p_preserve_series_membership := TRUE`.
- This is what allows a series to be bulk-edited more than once: without it, the first bulk call would detach every occurrence it touched, and a second bulk call would see all of them as `skipped_detached` and update nothing. A genuinely, individually detached occurrence (edited directly, with the parameter omitted or `FALSE`) is still correctly excluded by every later bulk call — the fix narrows the false-positive case, it does not widen what counts as "still eligible."

## 4. Split-series architecture

`update_series_this_and_future()` and `cancel_series_this_and_future()` share the same two-pass design:

- **Pass 1** classifies every occurrence of the source series from the split date forward into one of the four lifecycle categories (§5) or "eligible," and repoints each eligible occurrence's `meetings.series_id` to a newly-inserted `meeting_series` row.
- **Pass 2** performs the actual field edit (via `update_meeting()`) or cancellation (via `cancel_meeting()`) only on occurrences pass 1 actually repointed.
- **Meeting IDs are preserved** — repointing changes only `series_id`; no `meetings` row is ever inserted or deleted by either RPC.
- **Booking IDs are preserved** — an occurrence's existing `meeting_room_bookings` row is rescheduled or cancelled in place through the existing booking primitives; no new booking row is created.
- **Occurrence history is preserved** — per-occurrence `audit_logs` rows from `update_meeting()`/`cancel_meeting()` remain exactly as they were before the split.
- **Detached and modified/moved occurrences are excluded** from repointing in pass 1 (`skipped_detached`) and remain on the original series.
- **Exceptions remain attached to excluded occurrences** — `meeting_series_exceptions` rows are never rewritten by a split; an excluded occurrence's exception row still references its original series.
- **Date ranges are adjusted on both series**: the original series' `series_end_date` is shrunk to `split_date - 1`; the new series' `series_start_date` is the split date and `series_end_date` is the source series' original end date.
- **The original series remains `active`** in both RPCs — only the new split series' status differs between the two RPCs (`active` for the update RPC, `cancelled` for the cancel RPC, per §2 and §9).

## 5. Lifecycle classification

Every bulk RPC classifies each in-scope occurrence into exactly one of five outcomes, checked in this order:

1. `skipped_cancelled` — `status = 'cancelled'`.
2. `skipped_detached` — `series_detached = TRUE`. This single flag covers both an individually-edited occurrence and a "modified" (moved) occurrence recorded via `create_series_exception(..., 'modified')`, since a time-only edit still runs through `update_meeting()`'s own unconditional detachment bookkeeping.
3. `skipped_completed` — `end_at < now()`.
4. `skipped_locked` — `is_locked` and not overridable by the caller (`is_meeting_lock_overridable()`).
5. `updated` / `cancelled` — the occurrence is eligible and the RPC's actual mutation is applied.

An occurrence being skipped for any of these reasons never aborts the call — it is reported as one row in the RPC's result set and the loop continues. Only a genuine runtime error (an unhandled exception from `update_meeting()`, `cancel_meeting()`, or their nested calls — most commonly a room-booking conflict or a missing required cancellation reason) aborts and rolls back the entire transaction.

## 6. Entire-series update behavior

`update_entire_series()`: every eligible occurrence is updated through the existing, unmodified `update_meeting()` (with `p_suppress_notification := TRUE` and, since the preserve-series-membership patch, `p_preserve_series_membership := TRUE`). Room bookings tied to an eligible occurrence are rescheduled through `update_meeting()`'s own nested `reschedule_booking()` call — no direct booking manipulation in this RPC. Because of §3, the same series can be bulk-updated repeatedly without occurrences becoming falsely detached. A genuine room-booking conflict on any occurrence aborts and rolls back the whole call. A series with `status = 'cancelled'` is rejected before authorization is even checked.

## 7. This-and-future update behavior

`update_series_this_and_future()`: if the target occurrence is the series' first occurrence, the call delegates entirely to `update_entire_series()` and returns its result. Otherwise, a middle occurrence triggers the two-pass split (§4): only occurrences pass 1 actually repoints are edited in pass 2. Detached or modified occurrences on or after the split date stay on the original series, untouched. If a runtime failure occurs during pass 2, the entire transaction — including the tentative split series and all of pass 1's repointing — rolls back.

## 8. Entire-series cancellation behavior

`cancel_entire_series()`: every eligible future occurrence is cancelled through the existing, unmodified `cancel_meeting()` (with `p_suppress_notification := TRUE`), which also cancels any linked room booking via its own existing logic. `meeting_series.status` is set to `'cancelled'` unconditionally — including when every occurrence was excluded and zero were actually cancelled. Detached, modified, completed, and locked occurrences are left completely untouched. Once a series is cancelled, any later call to `update_entire_series()` or `update_series_this_and_future()` against it is rejected with "This series has been cancelled"; a second call to `cancel_entire_series()` itself is rejected with "This series has already been cancelled."

## 9. This-and-future cancellation behavior

`cancel_series_this_and_future()`: a first-occurrence target delegates entirely to `cancel_entire_series()`. Otherwise, the two-pass split runs exactly as in §4/§7, except the new split series is **intentionally retained and marked `cancelled` even when zero occurrences turn out eligible** — unlike the update RPC's tentative-series-discard behavior, because here the cancelled-status transition is the operation's entire purpose, not a side effect gated on touching at least one occurrence. The original series remains `active` with its range shrunk. Eligible occurrences are cancelled through the existing `cancel_meeting()`. A runtime failure during pass 2 (for example, a non-creator actor cancelling without a required reason) rolls back the split, the repointing, every cancellation already applied, and the audit/notification inserts that would otherwise follow — nothing partial is left behind.

## 10. Notifications and audits

- Every per-occurrence mutation inside a bulk RPC calls `update_meeting()`/`cancel_meeting()`/`reschedule_booking()` with `p_suppress_notification := TRUE`, so no per-occurrence notification is generated during a bulk operation.
- Each bulk RPC then issues exactly one consolidated notification `INSERT` when its affected count is greater than zero (plus, for the two update RPCs, only when the edit was meaningful). That single `INSERT ... SELECT DISTINCT` can still produce more than one notification **row** — one per distinct intended recipient among the operation's affected participants — which is correct: "one consolidated operation," not "one recipient total."
- Each bulk RPC writes exactly one consolidated `audit_logs` row per successful call, unconditionally for both cancel RPCs and for `update_entire_series()`/`update_series_this_and_future()` alike (an "affected = 0" outcome still writes it). Per-occurrence audit rows written by `update_meeting()`/`cancel_meeting()` themselves are never suppressed or deduplicated — they remain alongside the one consolidated row.
- The first-occurrence delegation paths (`update_series_this_and_future()` → `update_entire_series()`, `cancel_series_this_and_future()` → `cancel_entire_series()`) return the delegate's own result directly and never additionally write their own audit or notification rows — there is exactly one consolidated record per call, never two.
- CHECK-constraint values introduced across Phase 2, each added via a full restatement of the prior list (this codebase's established convention): `meeting_series_updated` and `meeting_series_split` on both `audit_logs.action` and `notifications.type`; `meeting_series_cancelled` on both, introduced once by `cancel_entire_series()` and reused as-is by `cancel_series_this_and_future()`, which adds no new CHECK value of its own. All values previously documented for Phase 1 (`meeting_series_created`, `meeting_draft_deleted`, and the full pre-existing lists) remain unchanged and present.

## 11. Authorization and security

- Every Phase 2 RPC requires `auth.uid() IS NOT NULL`, raising `'<function> requires an authenticated caller'` otherwise.
- `can_manage_series(p_series_id)` is the single authorization foundation every series-level RPC calls: returns `TRUE` for the series' own creator, for a super admin, or for any caller in the series' own organization who is a supervisor or above (`is_supervisor_or_above()`); `FALSE` otherwise (never raises for an unauthorized-but-authenticated caller).
- Because the third branch requires `organization_id = get_my_org_id()`, a caller from a different organization is always rejected, regardless of role.
- Module activation is enforced separately from authorization, via `meetings_module_active_for(v_series.organization_id)`, checked after `can_manage_series()` in every RPC.
- Every Phase 2 function is `SECURITY DEFINER` with `SET search_path = public, pg_temp` — no exceptions.
- A series with `status = 'cancelled'` rejects every further series-level operation (update or cancel) called against it, checked before the authorization check in every case.

## 12. Locking and room-booking interaction

- An occurrence with `is_locked = TRUE` that is not overridable by the caller (`is_meeting_lock_overridable()`, unchanged from Phase 1/meeting-locking) is skipped as `skipped_locked` and never touched by any bulk RPC.
- The existing lock primitives are authoritative and untouched by Phase 2 — no Phase 2 patch modifies `is_meeting_lock_overridable()` or any locking column.
- Both update RPCs reuse `update_meeting()` unmodified (aside from the new trailing parameters) for every per-occurrence edit; both cancel RPCs reuse `cancel_meeting()` unmodified for every per-occurrence cancellation.
- A room-booking conflict on any occurrence propagates from `meeting_room_bookings_conflict_guard()` (an exclusion-constraint-backed trigger) through `reschedule_booking()`, through `update_meeting()`, into the bulk RPC.
- A genuine runtime booking conflict aborts and rolls back the complete bulk transaction — no partial meeting update, no partial booking update, and no consolidated audit or notification row, since the abort happens before the bulk RPC's own post-loop `INSERT` statements are ever reached.

## 13. Series exceptions

- `meeting_series_exceptions` (`series_id`, `exception_date`, `exception_type IN ('skipped', 'modified')`, `replacement_meeting_id`, `UNIQUE(series_id, exception_date)`) records that a specific calendar date within a series was deliberately skipped or its occurrence deliberately modified/moved, written by `create_series_exception()`.
- Detached occurrences and exception-marked occurrences are excluded from every later bulk operation via the `skipped_detached` classification (§5) — the exclusion is driven by `meetings.series_detached`, not by a direct join against `meeting_series_exceptions`.
- A split operation (either this-and-future RPC) never modifies or deletes an excluded occurrence's exception row — it remains attached to the occurrence's original series, since the occurrence itself was never repointed.
- No bulk RPC ever reattaches an already-detached occurrence or reverses an exception — there is no automatic reattachment path anywhere in Phase 2.

## 14. Migration order

Verified directly from `git log` against each patch file (chronological commit order on `feature/corlink-platform-migration`):

1. `patch-meetings-recurring-phase2-notification-suppression.sql` — adds `p_suppress_notification` to `update_meeting()`, `cancel_meeting()`, `reschedule_booking()`.
2. `patch-meetings-recurring-phase2-series-auth.sql` — adds `can_manage_series()`.
3. `patch-meetings-recurring-phase2-series-exceptions.sql` — adds `create_series_exception()`, the first writer of the `meeting_series_exceptions` table (the table itself was created inert by Phase 1's `patch-meetings-recurring.sql`).
4. `patch-meetings-recurring-phase2-update-entire-series.sql` — adds `update_entire_series()`.
5. `patch-meetings-recurring-phase2-update-series-this-and-future.sql` — adds `update_series_this_and_future()`.
6. `patch-meetings-recurring-phase2-preserve-series-membership.sql` — redefines `update_meeting()`, `update_entire_series()`, `update_series_this_and_future()` to add `p_preserve_series_membership`.
7. `patch-meetings-recurring-phase2-cancel-entire-series.sql` — adds `cancel_entire_series()`.
8. `patch-meetings-recurring-phase2-cancel-series-this-and-future.sql` — adds `cancel_series_this_and_future()`.
9. `patch-meetings-recurring-phase2-audit-visibility.sql` — extends `can_view_case_audit_record()` with a `meeting_series` visibility branch (commit `9dfaab8`, added after files 1–8; see §17 for the gap it closes and §11 for the RLS/authorization surface it touches).

Files 1–3 have no functional dependency on each other (each is independently self-contained), but shipped in this order. Files 4 onward each have an explicit, stated dependency on the patches before them (documented in each patch's own header) and must be applied in this order. File 9 has its own explicit dependency, distinct from files 4–8's: it requires `meeting_series` (from file/Phase-1 `patch-meetings-recurring.sql`) and `can_view_meeting()` (from `patch-meetings-foundation.sql`) to already exist, but has no functional dependency on any of files 1–8 themselves — it can be applied any time after those two prerequisites, including before or after files 1–8, though in practice it shipped last.

**File 9 is intentionally not folded into `supabase/rls.sql`.** Every other branch of `can_view_case_audit_record()` (`request`, `response`, `internal_request`, `external_correspondence`) references a table that is part of the core `schema.sql` — that is why those four are safely baked directly into `rls.sql`, which a fresh install applies immediately after `schema.sql`, before any optional module patch. `meeting_series` and `can_view_meeting()` are not core tables/functions — they exist only once the optional Meetings-module patch chain (`patch-meetings-foundation.sql`, `patch-meetings-recurring.sql`) has been applied. This was verified empirically: loading `schema.sql` then a version of `rls.sql` with the `meeting_series` branch inlined directly, against a bare fresh database, failed with `relation "meeting_series" does not exist` — because a fresh `schema.sql → rls.sql` bootstrap happens before any Meetings recurring-series patch is ever applied. File 9 is therefore shipped as its own standalone, additive patch instead, applied only after the Meetings recurring-series prerequisites exist, exactly like `can_manage_series()` (file 2 above) is never baked into `rls.sql` either, for the identical reason. File 9 uses `CREATE OR REPLACE FUNCTION` and is idempotent — safe to re-run.

## 15. Validation status

The Phase 2 final integration review verified, against a freshly rebuilt local PostgreSQL database, applying the full dependency chain (Phase 1 foundation through all eight Phase 2 patches) twice in sequence:

- Clean migration application (0 errors) and idempotency (re-applying the Phase 2 chain a second time produces 0 errors).
- Exactly one live function overload per Phase 2 function, with correct `SECURITY DEFINER`/`search_path`/volatility.
- Repeated bulk updates on the same series (the preserve-series-membership regression).
- Split-series workflows, including cascading splits (a series split more than once) and cross-RPC sequences combining update and cancel operations.
- Cancellation workflows, including the split-and-cancel path and rejection of further action against an already-cancelled series.
- Lifecycle exclusions (`skipped_cancelled`, `skipped_detached`, `skipped_completed`, `skipped_locked`) for all four bulk RPCs.
- Genuine `skipped_completed` fixtures — backdating both `start_at` and `end_at` together under a role permitted to write `meetings` directly, verified to have actually taken effect before invoking the RPC.
- Authorization (anonymous caller, cross-organization caller, authorized creator/supervisor/super admin) and module-activation enforcement (module-disabled organization, and re-enablement) for all four bulk RPCs.
- Locking exclusions.
- Notification suppression during bulk execution and consolidated notification/audit row counts.
- Meeting ID and booking ID preservation across split operations.
- Conflict rollback for both update RPCs and a comparable rollback-risk case for the this-and-future cancellation RPC (missing cancellation reason aborting mid-split).
- No automatic reattachment of a detached or exception-marked occurrence by any later bulk operation.

**Historical validation-fixture issue.** During this review, the `skipped_completed` scenario in three validation files (`validate-meetings-recurring-phase2-update-entire-series.sql`, `validate-meetings-recurring-phase2-update-series-this-and-future.sql`, `validate-meetings-recurring-phase2-preserve-series-membership.sql`) was found to be either missing or described in a way that did not reliably exercise the outcome. The root cause was purely in synthetic test setup: `meetings` has no `UPDATE` RLS policy for the `authenticated` role, so a raw `UPDATE` issued under that role during test-fixture construction silently matched zero rows instead of erroring; and an earlier draft moved only `end_at` into the past, which can violate `meetings_range_check` (`end_at > start_at`) instead of producing a genuinely completed occurrence. This did not affect production RPC logic in any way — the underlying check (`end_at < now()`) is simple, stateless, and identical across every affected RPC, and a real occurrence becomes "completed" purely through the passage of time, a path no test-harness flaw can prevent. The validation files were corrected to genuinely exercise `skipped_completed`: temporarily using a role permitted to write `meetings` directly, backdating both `start_at` and `end_at` together, verifying the backdate took effect, then invoking the RPC under the intended authenticated test role and asserting both the `skipped_completed` outcome and that the occurrence was left untouched.

---

## 16. Frontend implementation

Added after §1–§15 above were originally written and approved. Every commit below is on `feature/corlink-platform-migration`, committed and pushed; none has been applied to production Supabase (see the Status line at the top of this document).

- **`5b7f1f8`** — frontend data-layer methods in `js/data/meetings-api.js`: `updateEntireSeries()`, `updateSeriesThisAndFuture()`, `cancelEntireSeries()`, `cancelSeriesThisAndFuture()`, `fetchSeriesExceptions()`, `fetchSeriesAuditTrail()` — thin wrappers over the RPCs/tables in §2 and §13, no business logic of their own.
- **`0ac8c52`** — `js/views/shell.js` fix: a `meeting_series` notification (the consolidated update/split/cancel notifications from §10) previously fell through to a generic Request Detail navigation branch, since only `meeting`/`meeting_room_booking` had dedicated click-routing. Adds an explicit `meeting_series` branch that resolves the series' earliest occurrence via a plain filtered read and navigates into that occurrence's existing detail modal.
- **`9f23f17`** — `_openSeriesActionScopeDialog(meeting, action, booking)` in `js/views/meetings.js`: for a recurring meeting (`meeting.series_id` set), Edit and Cancel each open a scope-selection dialog ("This meeting" / "This and future" / "Entire series") before proceeding, gated on `can_manage_series(meeting)` for the latter two options. A non-recurring meeting bypasses this dialog entirely and keeps the pre-Phase-2 single-occurrence flow unchanged.
- **`94c6234`** — `_openSeriesEditModal(meeting, 'entire_series')`: calls `MeetingsAPI.updateEntireSeries()`.
- **`def5295`** — extends the same `_openSeriesEditModal()` to also support `scope='this_and_future'`, calling `MeetingsAPI.updateSeriesThisAndFuture()` — one shared modal/form for both scopes, not two.
- **`3bd9cc9`** — `_openSeriesCancelModal(meeting, 'entire_series')`: calls `MeetingsAPI.cancelEntireSeries()`.
- **`ef562d8`** — extends the same `_openSeriesCancelModal()` to also support `scope='this_and_future'`, calling `MeetingsAPI.cancelSeriesThisAndFuture()` — again one shared modal, not two.
- **`bcfe86b`** — `_openSeriesResultSummaryModal({action, scope, rows, summary})`: a single reusable success modal for all four action×scope combinations above, replacing per-workflow `alert()` calls. Shows the scope-specific title ("Series Updated" / "Meetings Updated" / "Series Cancelled" / "Meetings Cancelled"), the existing outcome-summary sentence, and a compact breakdown of the RPC's own `outcome` rows (`updated`/`cancelled`, `skipped_detached`, `skipped_completed`, `skipped_cancelled`, `skipped_locked`) using user-facing labels only — never a raw outcome code, row id, or occurrence UUID.
- **`f8e4fbb`** — read-only Activity section inside the recurring meeting detail modal (described in its own subsection below).

**Single-meeting edit and cancellation are unaffected by any of the above.** `_openMeetingFormModal()`/`_openCancelMeetingModal()` — the pre-existing, pre-Phase-2 forms — remain the only code path for a non-recurring meeting, and for the "This meeting" scope option on a recurring one; none of the nine commits above modifies either function.

**Activity timeline (`f8e4fbb`).** The recurring meeting detail modal (`meeting.series_id` set) gains a read-only "Activity" section, placed after the meeting's main information (status, location, participants, attachments, minutes) and before the personal My Notes panel:

- Loads asynchronously via `Promise.allSettled([MeetingsAPI.fetchSeriesAuditTrail(seriesId), MeetingsAPI.fetchSeriesExceptions(seriesId)])`, fired once, right after the rest of the modal's DOM already exists — the detail modal never waits on it, and it is never re-fetched while the same modal instance stays open.
- Merges `audit_logs` rows (`meeting_series_created`/`meeting_series_updated`/`meeting_series_split`/`meeting_series_cancelled`, scope read from the row's own `notes` field rather than assumed from the action name — see §10) and `meeting_series_exceptions` rows (`exception_type IN ('skipped', 'modified')`) into one list, sorted newest first, with a stable fallback order for any row missing a usable timestamp.
- One source failing does not block the other: the surviving source's events still render, alongside a small "Some activity details could not be loaded." note. Both sources failing shows "Activity could not be loaded." instead of any raw error text. Zero events from two successful, empty responses shows "No activity has been recorded for this recurring series yet."
- Every rendered field (title, scope label, actor name, date, outcome-count summary) is HTML-escaped. No `audit_logs`/`meeting_series_exceptions` row's `id`, `user_id`, `record_id`, `series_id`, `replacement_meeting_id`, `created_by`, raw `action`/`exception_type` code, or raw `notes` string is ever rendered — every user-facing string is a mapped label or a value parsed out of `notes` and re-labeled (e.g. `skipped_locked` → "N locked by another user and left unchanged"). This is the same wording `_summarizeSeriesEditOutcome()`/`_summarizeSeriesCancelOutcome()` already established for the result-summary modal (`_openSeriesResultSummaryModal()`, commit `bcfe86b`, above), reused here rather than reinvented.
- `meeting_series_exceptions` (`exception_type IN ('skipped', 'modified')`, §13) has no column recording *why* an occurrence was skipped, and `fetchSeriesExceptions()` has no join to `users` — `create_series_exception()`'s own header (`patch-meetings-recurring-phase2-series-exceptions.sql`) documents that finer distinction as unimplemented future work. The timeline therefore shows `'modified'` as "Meeting edited individually" and `'skipped'` as the single, honest, generic "Meeting skipped in series" label, with no actor name, rather than inventing a specific reason (completed/locked/cancelled) the data does not carry. See §17.

## 17. Known limitations

- **`meeting_series_exceptions` does not record a skip reason.** The table (§13) distinguishes only `'skipped'` vs `'modified'` — not *why* an occurrence was skipped (completed, locked, already cancelled, or otherwise). The activity timeline (§16) therefore renders every `'skipped'` exception row with the same generic "Meeting skipped in series" label; it cannot say "skipped because completed" or "skipped because locked" for an individual occurrence. (The aggregate per-category counts — how many occurrences in one bulk operation were `skipped_completed`/`skipped_locked`/etc. — are available and shown, since they come from `audit_logs.notes`, a different source; only the per-occurrence exception-row reason is unavailable.)
- **No occurrence badges or calendar exception indicators exist.** Neither `js/views/calendar.js` nor the meeting list/detail views mark an individual occurrence as detached, exception-modified, or skipped anywhere outside the Activity section itself.
- **The Activity section has no filtering, pagination, export, undo, or restore controls.** It is read-only and shows every available event in one unpaginated list.
- **Production Supabase has not been updated.** `patch-meetings-recurring-phase2-audit-visibility.sql` (§14 item 9) and every other Phase 2 patch have been validated locally and pushed to `feature/corlink-platform-migration`, but none has been applied to the production Supabase project (`infjjroktzzhaxjvfknr`). Applying it remains a separate, not-yet-scheduled deployment step.
- **The meeting-series audit-visibility gap is resolved, not outstanding.** An earlier state of this project had no `meeting_series` branch in `can_view_case_audit_record()`, silently hiding all series-level audit rows from everyone but org admins. This is fixed by `patch-meetings-recurring-phase2-audit-visibility.sql` (commit `9dfaab8`, §14 item 9) and is no longer a limitation of the shipped (not-yet-production-applied) implementation.

---

## Validation (performed before committing this document)

- Every architectural claim in §2–§13 was checked directly against the shipped patch files' actual `CREATE OR REPLACE FUNCTION` bodies, not against prior design intent.
- The migration order in §14 was verified via `git log` against each patch file, not reconstructed from memory.
- No implementation file was changed by this document — only this document, plus surgical status updates to `docs/03`, `docs/22`, `docs/23`, and `docs/25` (see each document's own changelog).
- No SQL was written or applied by this document itself. No Supabase project was accessed. Nothing was deployed or pushed.

**§16/§17 addendum, added in a later documentation-only step:** all ten commit hashes cited in §14 item 9 and §16 were confirmed against `git log` (hash, subject line, and file-level diff) before being cited, not reconstructed from memory. Every function, RPC, and file name in §16/§17 (`_openSeriesActionScopeDialog`, `_openSeriesEditModal`, `_openSeriesCancelModal`, `_openSeriesResultSummaryModal`, `_renderActivityPanel`/`_loadSeriesActivity`/related helpers, `fetchSeriesAuditTrail()`, `fetchSeriesExceptions()`, `patch-meetings-recurring-phase2-audit-visibility.sql`) was checked directly against the corresponding source file, not assumed. The bootstrap-ordering claim in §14 (why the audit-visibility patch is not folded into `rls.sql`) restates a finding that was itself verified empirically, against a real local PostgreSQL instance, during that patch's own implementation. This addendum changes no application code, SQL, schema, or RLS object, and does not itself touch Supabase or Cloudflare.

---

*End of document. No database table was created or altered by this document. No RLS was written or changed. No application code was changed. No Supabase project was accessed or modified.*
