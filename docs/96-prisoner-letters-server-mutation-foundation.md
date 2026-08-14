# Prisoner Letters — Server-Authoritative Mutation Foundation

## 1. Milestone purpose

Migrates all six evidenced Prisoner Letters business mutations from
direct client `.insert()`/`.update()` calls to focused,
`SECURITY DEFINER` RPCs, mirroring the same "server-authoritative
mutation foundation" pattern already applied to Requests (1.6A), Entry
(1.7A), and Internal Collaboration (1.8A). This is the next approved
milestone after docs/95 (Prisoner Letters Architecture, Confidentiality
& Security Review). It is **not** CAP-003 notification integration, not
digital signatures, and not an unrelated redesign — it is the mutation
boundary and the two approved product decisions only.

## 2. Approved baseline

HEAD at the start of this milestone: `0ddee33e6c1b7966d62364d120e78368bf9a86a5`
(`docs(prisoner-letters): review architecture and security`) — verified
before any change was made.

## 3. Files inspected

`supabase/schema.sql` (prisoner_letters/prisoner_replies/prisoners/
letter_reference_sequences table definitions, audit_logs CHECK
constraints), `supabase/rls.sql` (is_prisoner_letters_staff(),
is_admin(), is_supervisor_or_above(), prisoner_letters_select/_insert/
_update, prisoner_replies_select/_insert, the prisoner_letter/
prisoner_reply branches of attachments_select/_insert/_delete),
`js/data/prisoner-letters-api.js` (full mutation inventory),
`supabase/patch-prisoner-letter-task-integration.sql`
(can_view_prisoner_letter()/can_manage_prisoner_letter_task_link()),
and docs/95 itself (re-verified against the live repository, not
assumed from memory — no material drift found).

## 4. Product decisions (pre-approved)

**Decision A — narrower access model.** docs/95 identified that the
live RLS granted any `is_prisoner_letters_staff`-flagged member of
*either* participating org full access to *every* letter between those
two orgs — broader than the app's own UI copy and its own API file's
header comment claimed. Replacement model, built entirely from
existing columns (no new field invented):
- MCS side (`from_prison_id` = caller's org): `submitted_by` (creator,
  still gated by the flag) OR `is_supervisor_or_above()` (org-wide
  oversight, independent of the flag).
- Authority side (`to_org_id` = caller's org): `assigned_to` (assignee,
  still gated by the flag) OR `is_supervisor_or_above()`.

"Same organization = authorized" is never used alone. Before a letter
is routed/assigned (`assigned_to IS NULL`), only an authority-side
supervisor/admin can see or act on it — this formalizes the role
restriction the frontend already documented ("Route (receiving org,
supervisor/admin)").

Replies are additionally restricted to the **authority side only**
(`to_org_id` match) — the previous RLS allowed either side to insert a
reply, directly contradicting the governing business rule ("the
external authority replies... MCS does not"). This migration corrects
it.

**Known, disclosed consequence:** an MCS/authority admin or supervisor
who lacks the individual `is_prisoner_letters_staff` flag now has
read/oversight access at the RLS/RPC layer that the frontend's own
nav-gating (`AppShell.canAccessPrisonerLetters`, `js/views/shell.js`)
does not yet expose a navigation path to. This milestone does not touch
that frontend gate ("preserve current UI behavior" forbids it) —
documented here as a known limitation for a future frontend milestone.

**Decision B — terminal immutability.** `'delivered'` is the sole
terminal state. Once reached:
- No RPC accepts it as a valid starting state for any further mutation
  (each RPC's own status guard enforces this structurally — no global
  trigger needed, since every mutation already goes through a single
  narrowly-guarded RPC).
- `to_org_id`/`from_prison_id` are never written by any RPC after
  creation (not even `route_prisoner_letter`, which only ever touches
  `to_section_id`/`assigned_to`) — a strictly stronger, whole-lifetime
  immutability property.
- `attachments_insert`/`attachments_delete`'s own `prisoner_letter`/
  `prisoner_reply` branches gain a `pl.status <> 'delivered'`
  condition, mirroring the exact pattern the `request`/
  `external_correspondence` branches of the same two policies already
  use.

No amendment/versioning subsystem is introduced — none is required for
this milestone; a future operational-correction capability is out of
scope.

## 5. Mutation inventory (re-verified against docs/95 — no drift)

| Old client call | New RPC |
|---|---|
| `submitLetter()` | `create_prisoner_letter(p_prisoner_ref, p_from_prison_id, p_to_org_id, p_body)` |
| `markReceived()` | `mark_prisoner_letter_received(p_letter_id)` |
| `routeLetter()` | `route_prisoner_letter(p_letter_id, p_to_section_id, p_assigned_to)` |
| `markSlipGenerated()` | `mark_prisoner_letter_slip_generated(p_letter_id)` |
| `createReply()` | `create_prisoner_letter_reply(p_letter_id, p_body)` — fused atomic |
| `markDelivered()` | `mark_prisoner_letter_delivered(p_letter_id)` |

No approval workflow, draft/review state, cancellation, or
multi-reply-cycle concept exists in the current implementation, so none
was invented — this is the complete, evidenced set of six.

## 6. Lifecycle/status model

`submitted → received → replied → delivered` (4 states, unchanged).
Each RPC guards its own valid starting state(s):
`mark_prisoner_letter_received` requires `'submitted'`;
`route_prisoner_letter`/`mark_prisoner_letter_slip_generated` block
only `'delivered'`; `create_prisoner_letter_reply` requires
`'submitted'` or `'received'`; `mark_prisoner_letter_delivered`
requires `'replied'`.

## 7. Directionality enforcement

`create_prisoner_letter()` independently verifies both organizations'
`type` (`from_prison_id` → `'mcs'`, `to_org_id` → `'authority'`) rather
than trusting the client — an authority-org caller fails on two
independent grounds (not staff-flagged for submission in practice, and
the org-type check). Prisoner identity (`prisoner_id`/`prisoner_name`)
is derived server-side from the `prisoners` registry row (org-matched
to the caller), never trusted from the client — a deliberate tightening
versus the old client-supplied shape.

## 8. RPC inventory

Six RPCs, all `SECURITY DEFINER`, `SET search_path = public, pg_temp`,
actor from `auth.uid()`, `REVOKE ALL FROM PUBLIC, anon` /
`GRANT EXECUTE TO authenticated`. See section 5 above for the full
signature list. `generate_prisoner_letter_reference()` was folded
into `create_prisoner_letter()`'s own transaction (no longer a separate
client RPC round trip) and its own `EXECUTE` grant to
authenticated/anon revoked — internal-only now, callable only via a
nested `SECURITY DEFINER` call. Its previously-missing `search_path`
pin (docs/95 §10) was fixed in the same `CREATE OR REPLACE`.

## 9. Direct-write closure

`REVOKE INSERT, UPDATE, DELETE ON TABLE prisoner_letters, prisoner_replies FROM authenticated`.
`SELECT` is untouched — every read path (`listInbox`/`listSent`/
`globalSearch`/`getLetter`/`listReplies`) remains a direct
`.from(...).select(...)` call, unmigrated, per the governing
instruction. `attachments` remains client-writable (the browser-upload
architecture requires it) — its business-state rules are enforced via
the RLS finalization lock (section 12), not by revoking the table
grant.

## 10. Assignment hardening

`route_prisoner_letter()` validates server-side that a supplied
assignee `is_active`, belongs to the destination (`to_org_id`)
organization, and holds `is_prisoner_letters_staff` — the same three
checks the frontend's own route-modal dropdown already filters for
client-side, now independently enforced server-side. It also validates
the supplied `to_section_id` actually belongs to the destination org
via `scope_org_id('section', p_to_section_id)`.

## 11. Reply atomicity

`create_prisoner_letter_reply()` fuses the previously-separate
`INSERT INTO prisoner_replies` + `UPDATE prisoner_letters SET status='replied'`
into one transaction — the same class of fix already applied to
`approve_response()`/`approve_entry_reply()`/
`approve_internal_request_reply()` elsewhere in this codebase. Reply
immutability is preserved exactly: no new `UPDATE`/`DELETE` policy and
no update RPC were added — `prisoner_replies` remains "immutable by
omission," confirmed by a behavioral test (createReply's replay is
rejected by the status guard) and an RLS test (a direct `UPDATE` by the
reply's own author is rejected).

## 12. Attachment immutability

Scoped **only** to the `prisoner_letter`/`prisoner_reply` branches of
`attachments_insert`/`attachments_delete` — no other `record_type`
branch, and no attachment table/bucket infrastructure, was touched.
`attachments_select`'s own `prisoner_letter`/`prisoner_reply` branches
keep the two-sided (MCS + authority) predicate, since both parties
legitimately need to *view* a reply's attachments; the insert/delete
branches for `prisoner_reply` are authority-side only (matching
`create_prisoner_letter_reply()`'s own directionality) — a genuine bug
found and fixed during implementation (see section 29).

## 13. Storage security

The private `attachments` Storage bucket and its signed-URL access
model are unchanged — RLS on the `attachments` table remains the real
authorization gate (a signed-URL request that resolves no row simply
returns nothing to view/download). No bucket-level policy was touched.

## 14. Server-side audit

Every RPC writes its own `audit_logs` row in the same transaction as
its domain mutation, replacing `js/data/prisoner-letters-api.js`'s own
client-side `logAudit()` calls (removed from the frontend). Notes
preserve the exact existing text from the prior client-side calls
(including `submitLetter`'s inclusion of the prisoner's full name, and
`createReply`'s reuse of the `'created'` action). No letter body, reply
body, or prisoner registry detail beyond the already-evidenced
`full_name` is ever written into `audit_logs`.
`mark_prisoner_letter_slip_generated()` gains an audit write it
previously never had (docs/95 flagged this omission) — action
`'edited'`, matching `mark_prisoner_letter_delivered`'s own existing
choice.

## 15. Access model / RLS alignment

RLS was realigned to the exact same predicate the RPCs enforce (section
4), so RLS and RPC authorization never contradict each other. Verified
by a dedicated RLS test (`prisoner_letters_select` policy body checked
directly for `submitted_by`/`assigned_to`/`is_supervisor_or_above`).

## 16. Concurrency

Nine genuine multi-session race scenarios via `dblink` (the
already-established pattern for this repository's concurrency suites):
two supervisors racing `mark_prisoner_letter_received` (exactly one
wins); two supervisors racing `route_prisoner_letter` with different
assignees (both succeed, serialized, no torn write); the same assignee
racing themself on `create_prisoner_letter_reply` (exactly one wins,
exactly one reply row); the same submitter racing themself on
`mark_prisoner_letter_delivered` (exactly one wins); reference
generation atomicity under a genuine race (two concurrent
`create_prisoner_letter` calls receive unique reference numbers);
route vs. slip-generated on the same letter (different fields, no
deadlock); post-race replay gets the correct business-rule rejection,
not a lock artifact; two unrelated letters progress independently; and
a crossed-order two-row access pattern completes without deadlock. All
nine passed — see `supabase/test-prisoner-letters-server-mutation-
foundation-concurrency.sql`.

## 17. Security testing

Twenty-two scenarios across `supabase/test-prisoner-letters-server-
mutation-foundation-rls.sql` (12 RLS + 10 attachment/storage),
covering: authority-org cannot create a letter; unrelated authority org
has zero visibility and cannot reply; unrelated MCS org has zero
visibility; inactive assignee rejected at route time; direct table
INSERT/UPDATE/DELETE fully closed on both tables; unauthenticated
caller rejected explicitly; no post-creation RPC accepts a
`to_org_id` parameter; reply immutability holds even for its own
author; cross-org assignment denied; cross-org prisoner registry
reference rejected; `prisoner_letters_select` matches the approved
model exactly; supervisor/admin oversight is independent of the flag;
authorized/unauthorized attachment upload; authorized/unauthorized
download; path/id-guessing does not bypass RLS; delete before/after
finalization; upload after finalization denied; original evidence
survives finalization intact; and reply attachments stay authority-side
only. All 22 passed.

## 18. Performance

Nine probes at 5,000-row + 3,000-reply + 2,000-attachment scale (see
`supabase/test-prisoner-letters-server-mutation-foundation-
performance.sql`): `create_prisoner_letter`, `mark_prisoner_letter_
received`, bounded MCS-submitted list, no sequential scan on the
authority-side `to_org_id`+`status` inbox query, `audit_logs` timeline
lookup, `create_prisoner_letter_reply` (atomic composed command),
assigned-to-me lookup, reply-by-letter lookup, and attachment
relationship lookup. All within budget; no speculative index was
added — the pre-existing `idx_prisoner_letters_submitted_by`/
`_assigned_to`/`_org`/`_to_org` and `idx_attachments_record` indexes
proved sufficient.

## 19. Frontend migration

`js/data/prisoner-letters-api.js`: all six mutation methods now call
their RPC instead of a direct table write; the separate client-side
`generate_prisoner_letter_reference` RPC round trip was removed
(reference generation now happens inside `create_prisoner_letter`
itself); the `logAudit()` helper was deleted entirely (no longer
called by anything); `createReply()` calls the single atomic RPC
instead of two separate writes, then does one follow-up read for the
notification recipient (`submitted_by`/`prisoner_name`) since the RPC
returns only the reply row. All six methods' external signatures are
unchanged — zero call-site churn in `js/views/prisoner-letters.js` or
`js/views/prisoner-letter-detail.js`. Legacy `NotificationsAPI.notify()`
calls are preserved exactly as-is, called by the frontend immediately
after each RPC call succeeds. Read-only methods
(`listInbox`/`listSent`/`globalSearch`/`getLetter`/`listReplies`) and
the Task-integration RPC calls are completely untouched. Verified by
`tests/prisoner-letters-server-mutation-foundation-frontend.test.js`
(13 checks, all passing).

## 20. Legacy notification preservation

`NotificationsAPI.notify()` call sites in `submitLetter`/`routeLetter`/
`createReply` are unchanged. The existing prisoner-name leakage in
notification `message` text (e.g. "New prisoner letter from
{full_name}...") is preserved exactly as it existed before this
milestone — not expanded, not newly introduced. A future CAP-003
integration milestone will need to address this leakage as part of its
own confidentiality design; this milestone does not attempt it.

## 21. Digital signature deferral

Nothing in this milestone implements a signer field, signature image,
external PDF signing, or official-letter rendering. The eventual
integration point for a future signature system is
`create_prisoner_letter_reply()` — whichever future command
finalizes/issues an official authority reply will need to be revisited
once that system exists; this milestone's version of that command
remains a plain-text, single-shot, immutable reply exactly as before.

## 22. Task integration preservation

`patch-prisoner-letter-task-integration.sql`'s six pre-existing RPCs
are unchanged. Its two authorization helpers,
`can_view_prisoner_letter()` and `can_manage_prisoner_letter_task_link()`,
explicitly documented (in their own code comments) that they mirror
`prisoner_letters_select` "verbatim" — since this milestone changes
that policy's predicate, these two helpers were updated via
`CREATE OR REPLACE` to the new predicate, a minimal, required change to
keep the Task-integration boundary consistent with the new mutation
boundary (not a redesign of Task integration itself). The existing
Task-integration regression suite (`test-prisoner-letter-task-
integration.sql`, 15 scenarios) was re-run and required two fixture
corrections (an unrealistic unassigned-but-delivered letter, and an
unassigned letter used for an authority-side action) — both fixed to
reflect realistic post-routing state, not weakened assertions. All 15
scenarios pass against the new access model.

## 23. Zero CAP-003 integration

No RPC in this milestone references `platform_enqueue_outbox_event`,
`create_notification_intent`, `resolve_notification_intent`,
`process_platform_outbox_batch`, `user_notifications`,
`notification_intents`, or `platform_outbox_events`. No
`platform_event_type_registry` row was inserted for Prisoner Letters.
Verified structurally (validator section 19) and by the frontend test
(no `platform_enqueue_outbox_event`/`user_notifications`/
`prisoner_letter.*.v1` literal in the JS file).

## 24. Direct-write closure verification

Verified both structurally (`has_table_privilege` checks) and
behaviorally (a direct `UPDATE`/`INSERT`/`DELETE` attempt against
`prisoner_letters`/`prisoner_replies` as `authenticated` fails with
"permission denied for table").

## 25. Rollback

`supabase/rollback-prisoner-letters-server-mutation-foundation.sql`
drops all six RPCs, restores direct `INSERT`/`UPDATE`/`DELETE` grants,
restores `generate_prisoner_letter_reference()` to its exact original
(unpinned, `PUBLIC`-callable) body, and restores every RLS policy this
milestone touched to the exact `CREATE POLICY` bodies already shipped
in `rls.sql` (copied verbatim, not reconstructed from memory). It does
**not** revert the companion Task-integration helper realignment
(section 22) — that must be reverted separately, in the same
maintenance window, per the rollback file's own header. The full cycle
(apply → validate → focused tests → rollback → rollback-validate →
reapply → validate → focused tests) was run and passed at every step.

## 26. Regression results

Full sweep on a freshly rebuilt disposable baseline: CAP-002 (all
workflow phases) + CAP-003 through Internal Collaboration (1.0A/1.0B/
1.1/1.2/1.5/1.6A/1.6B/1.7A/1.7B/1.8A/1.8B) + Requests/Entry/Internal
Collaboration Task integration + this milestone's own structural/
behavioral/RLS/attachment/concurrency/performance suites + the
Prisoner Letter Task-integration suite + the frontend structural test.
All passed. Four pre-existing, unrelated Node test failures
(`entry-notification-integration-frontend.test.js`,
`internal-collaboration-notification-integration-frontend.test.js`,
`notification-realtime-legacy-cutover-frontend.test.js`,
`task-relationships-frontend.test.js`) were confirmed via `git status`
to be files this milestone never touched — a pre-existing environment
issue (`require()` on an unresolved path), left undisturbed per the
governing instruction.

## 27. Architecture gaps disclosed (not fixed here)

The frontend nav-gating (`AppShell.canAccessPrisonerLetters`) does not
yet expose a path for a supervisor/admin who lacks the
`is_prisoner_letters_staff` flag, even though they now have RLS/RPC-
level oversight access (section 4's disclosed consequence) — a future
frontend milestone's responsibility. `record_type='prisoner_letter'`
has no `can_view_case_audit_record()` branch (a pre-existing gap,
documented previously in docs/37/docs/95, not introduced or fixed
here) — audit rows are visible only to org admins via the base
`audit_select` policy, or via superuser bypass in this milestone's own
tests. Legacy notification message text still includes the prisoner's
full name (section 20) — a future CAP-003 milestone's concern.

## 28. Deviations/defects discovered during implementation

Two genuine defects were found and fixed before this milestone's own
tests were considered complete, both caught by the test suites
themselves rather than assumed correct from design:

1. **Authorization fails open on NULL, not closed** — in PL/pgSQL,
   `IF NOT (expr)` silently skips the exception when `expr` evaluates
   to `NULL` rather than `FALSE`. Since `assigned_to` is nullable
   before routing, `assigned_to = v_actor` evaluated to `NULL` for an
   unassigned letter, and `IF NOT (NULL) THEN` never executed —
   letting a flagged-but-unassigned authority staffer through
   `mark_prisoner_letter_received()`/`create_prisoner_letter_reply()`
   unauthorized. Fixed by adding an explicit `assigned_to IS NOT NULL`
   guard to both checks. Caught by behavioral TEST 6a.
2. **Attachment insert/delete for replies used an overly broad
   predicate** — the `prisoner_reply` branch of `attachments_insert`
   read `(pr.replied_by = auth.uid() OR pl.to_org_id = get_my_org_id())`,
   which let *any* member of the destination org (no flag, no
   assignee/supervisor gate) attach files to a reply. Fixed to mirror
   `create_prisoner_letter_reply()`'s own authority-side-only
   predicate exactly, and the matching `attachments_delete` branch was
   narrowed the same way (it had inherited the full two-sided
   `prisoner_letter`-style predicate, which was also too broad for a
   reply that only the authority side can ever author). Caught during
   design review before either reached a committed test run.
3. `patch-entry-task-integration.sql` was found to be missing from
   `/tmp/cap002_build/build_baseline.sh`'s own patch-application loop
   (a pre-existing harness gap, unrelated to this milestone's own
   code, that blocked testing `patch-prisoner-letter-task-
   integration.sql`'s `can_view_task_link()` since it calls
   `can_view_entry()`) — fixed by adding it to the loop.

## 29. Known unrelated findings (not fixed, reported separately)

None beyond what is already disclosed in section 27 and docs/95.

## 30. STOP conditions considered

None were triggered: the approved baseline matched exactly, the
6-command inventory matched docs/95 exactly, the approved access model
was representable with existing schema fields (no invented columns),
no major new responsibility/section model was required, the lifecycle
was already consistent, attachment immutability required no global
storage redesign, authority-reply semantics were not contradicted (this
milestone corrects a contradiction the *old* RLS had), no digital
signature was actually required for today's reply command, and no
protected-baseline security defect was found in the approved parent
commit itself (the two defects in section 28 were introduced and
caught within this milestone's own new code, not present in the
approved baseline).
