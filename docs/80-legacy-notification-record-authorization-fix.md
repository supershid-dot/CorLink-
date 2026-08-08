# CAP-003 Phase 1.0B — Legacy Notification RECORD-Authorization Correction

## Status

This is a focused security correction, not a CAP-003 implementation milestone. It closes a
residual gap left by Phase 1.0A (docs/79); it does not build the transactional outbox, the
new durable notification architecture, or any other piece of docs/78. CAP-003 Phase 1.1
remains fully deferred.

## Residual vulnerability

Phase 1.0A (docs/79) correctly closed cross-organization notification spoofing, but its own
correction contained a documented, intentional simplification: `create_legacy_notification()`
allowed **any** recipient sharing the caller's organization, unconditionally —

```sql
IF v_recipient_org = v_actor_org THEN
  CONTINUE;
END IF;
```

A read-only security review conducted after 1.0A shipped proved this was still exploitable:
an authenticated user could fabricate a notification for **any other user in their own
organization**, using an arbitrary valid notification type, an arbitrary (even nonexistent)
`record_type` string, and a nonexistent `record_id` — with the fabricated notification
persisting and rendering identically to a legitimate one.

## Reproduction

Reproduced directly against disposable local PostgreSQL, running as the `authenticated` role
throughout, at commit `f7572193502ac51e70f23be4c5520ce1691b3ce7` (1.0A's own HEAD), before
writing this correction:

1. User A and User B created in the same organization, with **zero** shared section, role,
   or individual-reference relationship to any record.
2. User A called `create_legacy_notification()` four times, once per record-type shape
   (`task`, `meeting`, `external_correspondence`, `internal_request`), every call using a
   freshly generated, entirely nonexistent `record_id`.
3. All four calls succeeded: `create_legacy_notification` returned `1` each time, and
   4 fabricated notifications were persisted for User B, each referencing a record that does
   not exist, from a caller with no relationship to User B whatsoever.

## Root cause

Same-organization membership was treated as sufficient authorization on its own. It never is
— an organization can contain many sections, cases, and users a given member has no
legitimate connection to. 1.0A's own scope analysis had already proven the inverse case
(same-org-only is *insufficient* to justify cross-org notification), but did not carry that
reasoning through to the same-org case itself.

## Call-site inventory

Every real, raw-client `NotificationsAPI.notify()` call site was re-inspected
(`js/data/requests-api.js`, `prisoner-letters-api.js`, `entry-api.js`,
`internal-requests-api.js`, `review-comments-api.js` — the same ~30 call sites 1.0A already
enumerated). Two findings drove this correction's design:

- **Exactly three `record_type` values are ever used** by real client code: `request`,
  `external_correspondence`, `prisoner_letter`. `task`, `meeting`, and `internal_request` are
  never used as a top-level `record_type` by any real caller — module-level `SECURITY
  DEFINER` RPCs (Meetings, Rooms, Tasks, task-dependencies) insert directly and are
  structurally unaffected by this table's RLS regardless (1.0A §Scope analysis), and
  `internal-requests-api.js` always resolves its own notifications to the **parent**
  request/entry via its own `parentRef()` helper, never `'internal_request'` itself.
- **Every recipient in every real call site is derived from the referenced record's own
  columns**: its section columns (`section_user_ids()`-style membership), its party
  organization(s) (`org_supervisor_user_ids()`-style role membership at a genuine party org),
  specific individual reference columns (`created_by`/`received_by`/`assigned_to`/
  `entered_by`/`submitted_by`), or a section looped in via an `internal_requests` row anchored
  to that same parent record (`requests_select_via_internal_collab`/
  `external_correspondence_select_via_internal_collab`'s own RLS shape).

No real call site ever derives a recipient from "same organization" alone — that check in
1.0A's RPC was strictly *broader* than what any legitimate caller needed.

## Root design: record-authoritative authorization

`create_legacy_notification()` now requires, for every call:

1. **The referenced record exists.** A nonexistent `record_id` is rejected before any
   authorization check runs, with a distinct error.
2. **The caller is authorized for that specific record.** Same organization is no longer, by
   itself, ever sufficient — the caller must be a genuine party to the record (see
   "Recipient derivation" below; the same predicate governs both caller and recipient).
3. **Every recipient is legitimately connected to that specific record.** Each recipient is
   checked individually against the same per-record-type predicate; a single failing
   recipient rejects the entire call (unchanged all-or-nothing behavior from 1.0A).
4. **The `(record_type, type)` combination is on a closed allowlist** derived directly from
   the call-site inventory above.

## Supported record types

Exactly three, matching the call-site inventory: `request`, `external_correspondence`,
`prisoner_letter`. Any other value (`task`, `meeting`, `internal_request`, or anything else)
is rejected outright, before any table is even queried.

## Recipient derivation

"Legitimately connected to record R" reuses the exact recipient-derivation logic real call
sites already use client-side — generalized to an explicit target-user parameter, since none
of the existing RLS helpers in `rls.sql` take one (every one of them is `auth.uid()`-bound by
design, because they only ever need to answer "can the *caller* see this row"). Four small,
narrowly-scoped helper functions were added for this correction's own use, prefixed `notif_`
to keep that boundary explicit — they do not replace, modify, or duplicate any existing RLS
policy:

- `notif_user_org_id(p_user)` — the user's own organization.
- `notif_user_covers_section(p_user, p_section_id)` — generalized `my_section_ids()`
  membership check (same command/department/division/section expansion via
  `scope_section_ids()`), for an explicit user.
- `notif_user_has_notify_role(p_user)` — generalized `org_supervisor_user_ids()` role set
  (`mcs_admin`/`authority_admin`/`supervisor`), for an explicit user, without the org filter
  baked in (callers compose it with their own org-match check).
- `notif_user_is_prisoner_letters_staff(p_user)` — generalized `is_prisoner_letters_staff()`
  flag check.

Three per-record-type predicates compose these into "is this user a legitimate party to
record R", used identically for **both** the caller-authorization check and the per-recipient
legitimacy check — triggering a notification about a record and being a legitimate recipient
of one are the same underlying question for every real call site inventoried:

- **`notif_request_legitimate_recipient(request_id, user)`** — true if the user is the
  request's `created_by`/`received_by`/`assigned_to`; covers `from_section_id`/
  `to_section_id`/`previous_section_id`; holds a notify-role at a genuine party org
  (`from_org_id`/`to_org_id` — this is the preserved cross-organization path, unchanged from
  1.0A); or is tied (by section or `created_by`) to any `internal_requests` row anchored to
  this request via `parent_request_id` (the "Loop in a Section" case).
- **`notif_entry_legitimate_recipient(entry_id, user)`** — true if the user is the entry's
  `entered_by`/`assigned_to`; covers `to_section_id`; is Entry staff or holds a notify-role at
  the entry's single `org_id` (single-organization, matching `external_correspondence`'s own
  schema — no cross-org branch exists here); or is tied to any `internal_requests` row
  anchored via `parent_entry_id`.
- **`notif_prisoner_letter_legitimate_recipient(letter_id, user)`** — true if the user is the
  letter's `submitted_by`/`assigned_to`/`received_by`; covers `to_section_id`; or holds a
  notify-role *or* the prisoner-letters-staff flag at a genuine party org (`from_prison_id`/
  `to_org_id` — the preserved cross-organization path from 1.0A).

`requested_users` must be a subset of each record's own legitimate-party set — "same
organization" never substitutes for it anymore.

## Type/source allowlist

`notif_type_allowed(record_type, type)` — a closed, literal `(record_type, type)` pair list
derived directly from the call-site inventory:

| record_type | allowed types |
|---|---|
| `request` | `approval_requested`, `new_request`, `draft_returned`, `new_response`, `request_cancelled` |
| `external_correspondence` | `new_external_correspondence`, `approval_requested`, `external_correspondence_replied`, `draft_returned`, `new_request`, `new_response` |
| `prisoner_letter` | `new_prisoner_letter`, `letter_replied` |

(`new_request`/`new_response` appear under `external_correspondence` too because
`internal-requests-api.js`'s `parentRef()` resolves to an Entry-anchored parent for
entry-side internal collaboration.) `deadline_warning` is deliberately absent — it is only
ever inserted directly by `check_deadlines()`, a `SECURITY DEFINER` function that never calls
this RPC, so no allowance is needed. The `notifications.type` 30-value `CHECK` constraint
itself remains completely untouched (unchanged from 1.0A) — this allowlist is a strictly
*narrower* filter layered in front of it, not a replacement.

## Same-organization behavior

Same-organization membership is no longer, by itself, ever accepted. A same-org recipient
must additionally satisfy the record-legitimacy predicate above (section tie, individual
reference, notify-role at a party org, or internal-collaboration tie) — closing the exact gap
this milestone targets.

## Cross-organization behavior

Preserved exactly, and re-tested: `request` (`from_org_id`/`to_org_id`) and `prisoner_letter`
(`from_prison_id`/`to_org_id`) still allow a genuine cross-organization party to be notified,
via the same columns 1.0A already validated — now simply one branch of the unified
per-record-type predicate rather than a separate special case. A recipient in a third,
unrelated organization is still rejected exactly as before.

## RLS

Unchanged from 1.0A: `notif_insert` remains absent (no INSERT policy of any kind on
`notifications` for `authenticated`/`anon`); `notif_select`/`notif_update` remain untouched
(`user_id = auth.uid()`); no DELETE policy exists. `create_legacy_notification()` is still the
sole creation path.

## RPC security

`create_legacy_notification(UUID[], TEXT, TEXT, UUID, TEXT)` — same external signature as
1.0A. `SECURITY DEFINER`, pinned `search_path`, `EXECUTE` revoked from `PUBLIC`/`anon`,
granted to `authenticated` only. The new `notif_*` predicate/helper functions follow the same
convention every other internal `STABLE SECURITY DEFINER` predicate helper in `rls.sql`
already follows (e.g. `is_admin()`, `looped_in_via_internal_collab()`) — no explicit
`REVOKE`/`GRANT` beyond Postgres's default, since they reveal only boolean/UUID answers and
are never the actual privilege boundary; `create_legacy_notification()` remains that
boundary.

## Frontend

`js/data/notifications-api.js`'s `notify()` required **zero changes** — its external
signature and fire-and-forget, swallow-errors behavior are unchanged, and every one of its
~30 existing callers continues to work unmodified because every one of them was already,
provably, only ever requesting record-legitimate recipients (§Call-site inventory).

## Testing

- **Structural validator** (`validate-legacy-notification-record-authorization-fix.sql`):
  confirms the unconditional same-org bypass is genuinely gone from the function body (not
  merely undocumented), the closed record_type allowlist and per-record-type dispatch are
  present, the record-existence check and caller-authorization check are present, the
  `(record_type, type)` allowlist function exists and is called with a real combination list,
  every generalized helper exists and is `SECURITY DEFINER`, the preserved cross-organization
  party-org columns still appear, and `notif_select`/`notif_update`/RLS/type-enum/CAP-002
  baseline are all untouched. **PASSED.**
- **Security/regression suite** (`test-legacy-notification-record-authorization-fix.sql`, 20
  scenarios): same-org fabrication rejected for task/meeting/entry/internal-collaboration
  shapes; nonexistent record rejected; unsupported record_type rejected; unsupported
  type/record_type combination rejected; unauthorized caller rejected even with an otherwise-
  legitimate recipient; the core same-org gap (record-unrelated same-org recipient) rejected;
  legitimate same-org Entry/Internal-Collaboration/review-comment notifications succeed;
  legitimate Requests and Prisoner Letters cross-organization notifications succeed;
  cross-org unrelated recipient rejected; anonymous execution denied; direct INSERT denied;
  own SELECT/read-state intact; existing `SECURITY DEFINER` module notification generators
  structurally unaffected; zero fabricated rows ever reach the table. **PASSED: 20/20.**
- **Full regression sweep** (all CAP-002 structural/behavioral/RLS/concurrency/performance
  files, Phase 1 through 5.4, 1.0A's own suite, plus this correction's own two new files):
  **zero failures.**

## Concurrency

No new concurrency surface: the new predicate helpers are pure `STABLE` reads (no `FOR
UPDATE`, no new uniqueness/idempotency constraint), and `create_legacy_notification` itself
still performs only independent per-recipient reads followed by a single multi-row `INSERT` —
identical concurrency shape to 1.0A. The structural validator asserts directly that the RPC
body contains no `FOR UPDATE`.

## Rollback

`rollback-legacy-notification-record-authorization-fix.sql` drops all eight new functions
(three per-record-type predicates, the type allowlist, four generalized helpers) and restores
`create_legacy_notification()` **byte-identical** to its exact 1.0A-era definition. Verified
directly: post-rollback, `validate-legacy-notification-record-authorization-fix-rollback.sql`
passes, 1.0A's own structural validator (`validate-legacy-notification-insert-rls-fix.sql`)
**also** passes (proving the rollback lands exactly on the 1.0A state, not merely "some
earlier state"), and this milestone's own structural validator correctly **fails** for
precisely the expected reasons (`rpc-still-contains-unconditional-same-org-bypass`, every
`notif_*`-missing reason). The patch reapplies cleanly, and both the structural validator and
the full 20-scenario suite pass again after reapplication. No `CASCADE` was used anywhere.

## Limitations

- **The `notifications.type` 30-value closed enum is still untouched.** Unchanged from 1.0A;
  still CAP-003's later migration/cutover concern.
- **The `(record_type, type)` allowlist is closed and manually curated from the current
  call-site inventory.** A future module that legitimately needs a new combination requires
  its own explicit addition here (or, more likely, migration onto CAP-003's own
  recipient-resolution model once it exists) rather than a growing ad hoc list.
- **No CASCADE, no data migration, no historical notification re-validation.** Rows already
  present in `notifications` before this correction are untouched; this fix governs only
  future inserts, same as 1.0A.
- **This is still not the CAP-003 authorization-revalidation model.** docs/78 §8 requires
  authorization revalidation reusing each module's own visibility predicate at *processing*
  time; this correction is a narrower, synchronous, creation-time check — a substantially
  closer approximation of that model than 1.0A's same-org shortcut, but still not that later
  architecture.
- **The generalized `notif_*` predicate helpers are new, narrowly-scoped logic, not a direct
  reuse of the exact RLS policy expressions** (which are structurally `auth.uid()`-bound and
  cannot take an explicit target user). They were derived to be the smallest faithful
  generalization of each policy's own logic and are exercised directly by the 20-scenario
  suite against real fixture data mirroring every real call site, but they are a second,
  parallel implementation of "who can see this record" rather than a single shared source of
  truth with `rls.sql`'s own policies. A future refactor could parameterize the RLS helpers
  themselves (e.g. `my_section_ids(p_user UUID DEFAULT auth.uid())`) to collapse this
  duplication — explicitly out of scope for this security-only correction.

**CAP-003 Phase 1.1 (the transactional outbox and new durable notification architecture)
remains fully deferred** — nothing in this correction begins it.
