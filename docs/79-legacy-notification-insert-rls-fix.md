# CAP-003 Phase 1.0A — Legacy Notification INSERT-RLS Correction

## Status

This is a focused security correction, not a CAP-003 implementation milestone. It does not
build the transactional outbox, the new durable notification architecture, or any other
piece of docs/78. CAP-003 Phase 1.1 remains fully deferred.

## Defect

The legacy `notifications` table's INSERT policy (`supabase/rls.sql`):

```sql
CREATE POLICY "notif_insert" ON notifications
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
```

checks only that the caller is an authenticated CorLink user. It never validates that
`user_id` is the caller, never validates that the caller has any relationship to
`record_type`/`record_id`, and never validates `message` content. Any authenticated user
could insert an arbitrary, fabricated notification for any other user in any organization.

## Reproduction

Reproduced directly against disposable local PostgreSQL, running as the `authenticated`
role (never `postgres`/`service_role`) throughout:

1. User A (organization A) issued `INSERT INTO notifications (user_id, ...) VALUES
   (<User B's id>, ...)` where User B belongs to a different organization, with a
   fabricated message and a `record_id` referencing nothing real. The insert succeeded.
2. Confirmed User A cannot otherwise act as User B (an attempted `UPDATE users SET
   full_name = ... WHERE id = <User B>` as User A affects zero rows) — proving this is
   specifically an INSERT-policy gap, not a broader loss of identity boundary.
3. Confirmed `current_user` was `authenticated` throughout — the insert succeeded purely
   via the RLS policy, never a service-role bypass.
4. Confirmed `notif_select` still correctly scoped User A to zero rows of User B's
   notifications via `SELECT` — the defect is INSERT-only; read visibility was never
   affected.

## Root cause

`notif_insert`'s `WITH CHECK` clause tests caller authentication only. It was written
(per `supabase/rls.sql`'s own history) as part of the original notification feature, before
this table needed to defend against a caller supplying an arbitrary `user_id` — cross-user
notification was the entire point of the feature (a supervisor needs to be notified of a
subordinate's action), and the policy was never tightened to distinguish "authenticated"
from "authorized to notify this specific recipient."

## Scope analysis

Every `INSERT INTO notifications` call site in the repository was inspected:

- **Server-side, inside existing `SECURITY DEFINER` RPCs** (Meetings, Rooms, Tasks,
  task-dependencies, `check_deadlines()`, and every other SQL-embedded notification
  insert): these execute as the function's owning role, which already bypasses this
  table's RLS regardless of the `notif_insert` policy's content (SECURITY DEFINER
  functions run as their owner; RLS is not evaluated for a table's owning role unless
  `FORCE ROW LEVEL SECURITY` is set, which it is not). **These call sites are structurally
  unaffected by this correction** — verified directly by the full CAP-002/module
  regression sweep passing unchanged.
- **Client-side, via `js/data/notifications-api.js`'s `NotificationsAPI.notify()`**: the
  only real exploit surface. Called from `entry-api.js`, `requests-api.js`,
  `prisoner-letters-api.js`, `internal-requests-api.js`, and `review-comments-api.js` — on
  the order of 30 call sites — always for recipients other than the caller (section
  supervisors resolved via `section_user_ids()`, organization supervisors via
  `org_supervisor_user_ids()`, or a specific individual read from data the caller just
  legitimately fetched, e.g. a request's `created_by`).

**`user_id = auth.uid()` alone is proven insufficient** by this same scope analysis:
`requests-api.js` (`data.to_org_id`) and `prisoner-letters-api.js` (`toOrgId` on submit)
both legitimately notify recipients in a *different* organization than the caller —
genuine cross-organization routing, not a bug. `entry-api.js`'s `external_correspondence`
table, by contrast, has no cross-organization column at all (`org_id` only) — Entry never
legitimately notifies across organizations.

## Correction

Per the preferred order (reuse an existing safe RPC; else introduce the minimum narrow one;
else restrict/remove direct INSERT): no existing generic notification-creation RPC existed,
so a new, narrow one was introduced, and the insecure policy was removed entirely rather
than narrowed.

1. **`DROP POLICY "notif_insert"`** — no INSERT policy of any kind remains on
   `notifications` for `authenticated`/`anon`. With RLS enabled and zero matching policy,
   every direct INSERT is denied by default, independent of any table-level grant.
2. **New RPC `create_legacy_notification(p_user_ids UUID[], p_type TEXT, p_record_type
   TEXT, p_record_id UUID, p_message TEXT)`** — `SECURITY DEFINER`, pinned `search_path`,
   granted to `authenticated` only (revoked from `PUBLIC`/`anon`). For every recipient:
   - Caller and recipient must both be active users (`users.is_active = TRUE`).
   - **Same organization as the caller**: always allowed — covers the overwhelming
     majority of evidenced call sites.
   - **Different organization**: allowed only when `p_record_type` is `'request'` or
     `'prisoner_letter'` (the only two tables with genuine cross-organization semantics,
     confirmed by direct schema inspection) **and** the referenced row's own
     `from_org_id`/`to_org_id` (or `from_prison_id`/`to_org_id`) columns place *both* the
     caller's and the recipient's organizations as parties to that specific record. The
     recipient's organization is read from the recipient's own `users` row and the
     record's own stored columns — never accepted as client input.
   - Any recipient failing both checks rejects the entire call (`42501`) — never a silent
     partial insert.
   - `p_type` is not separately allow-listed inside the RPC; the `INSERT` still passes
     through `notifications`'s own existing `notifications_type_check` constraint, so an
     invalid/spoofed type is rejected exactly as it always was — no new type surface is
     introduced, and the 30-value enum itself is untouched (explicitly out of scope, see
     "Limitations").
3. **`js/data/notifications-api.js`'s `notify()`** now calls this RPC instead of
   `db.from('notifications').insert(rows)`. Its own external signature
   (`notify(userIds, {type, recordType, recordId, message})`) and fire-and-forget,
   swallow-errors behavior are completely unchanged, so all ~30 existing callers across
   five modules continue to work with zero changes of their own.

## Legitimate behavior preserved

- Reading one's own notifications (`listMine`, `countUnread`) — untouched, `notif_select`
  unmodified.
- Marking one's own notification read/unread (`markRead`, `markAllRead`) — untouched,
  `notif_update` unmodified.
- The `notifications` table's column shape — completely unchanged, so the Realtime
  `postgres_changes` payload and every frontend data contract built on it (the bell,
  `shell.js`'s `_subscribeRealtime`) are unaffected.
- Every existing module notification caller (Entry, Requests, Prisoner Letters, Internal
  Collaboration, review comments) — unaffected; `NotificationsAPI.notify()`'s public
  surface did not change.
- Every SQL-embedded notification insert inside another module's own `SECURITY DEFINER`
  RPC (Meetings, Rooms, Tasks, `check_deadlines()`) — structurally unaffected (§Scope
  analysis).
- The `notifications.type` closed enum — untouched, not widened, not narrowed, not
  cleaned up (explicitly out of scope for this milestone).

## RLS changes

| Policy | Before | After |
|---|---|---|
| `notif_select` (SELECT) | `user_id = auth.uid()` | **Unchanged** |
| `notif_insert` (INSERT) | `auth.uid() IS NOT NULL` (the defect) | **Removed** — no INSERT policy exists; creation is exclusively via `create_legacy_notification()` |
| `notif_update` (UPDATE) | `user_id = auth.uid()` | **Unchanged** — already correctly scoped; `WITH CHECK` defaults to the same expression when omitted, so a user could never reassign `user_id` via UPDATE either, before or after this correction |
| DELETE | No policy (unsupported) | **Unchanged** — still unsupported; this correction does not add one |

Anonymous access was already denied for every command and remains denied.

## New RPC boundary

`create_legacy_notification(UUID[], TEXT, TEXT, UUID, TEXT)` — see "Correction" above for
its full validation. It is the sole path by which an authenticated client session may
create a notification for a recipient other than themselves.

## Confidentiality review

No payload redesign was performed (out of scope), and none was needed: `message` remains a
plain caller-supplied string, exactly as before. The correction does not add any new path
by which notification metadata could leak cross-organization content — if anything, it
narrows the existing surface, since a recipient's organization must now be independently
justified by real data (their own `users.org_id`, or a real request/prisoner-letter row's
own columns) rather than accepted on faith. No Prisoner Letter body, Request substantive
text, or Case content is read, copied, or exposed by this RPC — it only ever reads
`users.org_id`, `requests.from_org_id`/`to_org_id`, and
`prisoner_letters.from_prison_id`/`to_org_id`, none of which are confidential fields. No
separate payload-confidentiality defect was discovered during this review; none is being
silently folded into this correction.

## Testing

- **Structural validator** (`validate-legacy-notification-insert-rls-fix.sql`): confirms
  the insecure policy is gone with no unrestricted replacement, `notif_select`/
  `notif_update` are byte-identical to their pre-correction definitions, no DELETE policy
  was introduced, the new RPC is `SECURITY DEFINER`/pinned `search_path`/authenticated-only
  with genuine validation logic present in its body (not merely claimed), the
  `notifications.type` enum is untouched, and zero CAP-003 objects were accidentally
  created. **PASSED.**
- **Security/regression suite** (`test-legacy-notification-insert-rls-fix.sql`, 12
  scenarios): all required scenarios — cross-organization raw-INSERT rejection,
  cross-organization RPC rejection even against a real-but-unrelated decoy record,
  anonymous denial (both paths), the legitimate same-org and real-cross-org paths
  succeeding, correct SELECT/UPDATE scoping, absence of DELETE, unaffected data contract,
  an existing-caller-shaped batch call still working, spoofed-type rejection, and CAP-002
  baseline presence. **PASSED: 12/12.**
- **Full regression sweep** (all CAP-002 structural/behavioral/RLS/concurrency/performance
  files, Phase 1 through 5.4, plus this correction's own two new files): **zero failures.**

## Concurrency

This correction is not policy-only (it introduces one new function), but it introduces
**no new concurrency surface**: `create_legacy_notification` takes no row lock (`FOR
UPDATE`), enforces no new uniqueness/idempotency constraint, and performs only independent
per-recipient `SELECT`/`EXISTS` reads followed by a single multi-row `INSERT` — two
concurrent calls (even targeting overlapping recipients) simply produce independent
`notifications` rows with no shared mutable state to race over, exactly as the original raw
multi-row `INSERT` already did. The structural validator asserts directly that the RPC body
contains no `FOR UPDATE`. No concurrency test suite was written, per the governing
instruction's own guidance not to invent concurrency machinery where none is needed.

## Rollback

`rollback-legacy-notification-insert-rls-fix.sql` drops `create_legacy_notification` and
recreates `notif_insert` byte-identical to its original definition
(`WITH CHECK (auth.uid() IS NOT NULL)`). Verified directly: policy/grant equality after
rollback (`notif_select`/`notif_update` untouched throughout, policy count back to exactly
3), the structural (security) validator correctly **fails** after rollback for precisely
the expected reasons (`insecure-notif-insert-policy-still-present`,
`create_legacy_notification-missing`, ...), the patch reapplies cleanly, and both the
structural validator and the full 12-scenario test suite **pass again** after reapplication.
No `CASCADE` was used anywhere in the rollback.

This SQL rollback artifact governs only the database objects it created, exactly like every
other rollback in this repository. `js/data/notifications-api.js`'s `notify()` was updated
in the same commit to call the new RPC — running only the SQL rollback, without also
reverting that JS change (a plain `git revert` of this commit), would leave the frontend
calling an RPC that no longer exists. This is noted directly in the rollback file's own
header comment rather than left implicit.

## Limitations

- **The `notifications.type` 30-value closed enum is untouched.** Cleaning it up is
  CAP-003's later migration/cutover concern, explicitly out of scope here, per the
  governing instruction.
- **Cross-organization justification is limited to `requests` and `prisoner_letters`.**
  These are the only two tables with genuine cross-organization semantics found during
  scope analysis; a future module that legitimately needs the same allowance would require
  its own narrow addition to this RPC (or, more likely, migration onto CAP-003's own
  recipient-resolution and authorization-revalidation model, docs/78 §7–§8, once that
  exists) rather than an ever-growing table list bolted onto this security-only correction.
- **No CASCADE, no data migration, no historical notification re-validation.** Rows already
  present in `notifications` before this correction are untouched; this fix governs only
  future inserts.
- **This is not the CAP-003 authorization-revalidation model.** docs/78 §8 requires
  authorization revalidation reusing each module's *own* visibility predicate at
  *processing* time; this correction is a narrower, synchronous, creation-time check
  sufficient to close the specific reported defect without building that later
  architecture now.

**CAP-003 Phase 1.1 (the transactional outbox and new durable notification architecture)
remains fully deferred** — nothing in this correction begins it.
